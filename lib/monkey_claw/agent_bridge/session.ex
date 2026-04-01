defmodule MonkeyClaw.AgentBridge.Session do
  @moduledoc """
  GenServer wrapping a single BeamAgent session.

  Each Session process manages the lifecycle of one BeamAgent session,
  including:

    * Starting and stopping the underlying BeamAgent session
    * Monitoring the session process for unexpected termination
    * Subscribing to BeamAgent events and forwarding via Phoenix.PubSub
    * Emitting telemetry events for observability

  ## Process Design

  A GenServer is the correct abstraction here because sessions are:

    * **Stateful** — they wrap a live BeamAgent session pid
    * **Lifecycle-bound** — start, active, stop, terminated
    * **Monitor-dependent** — must detect BeamAgent crashes
    * **Cleanup-requiring** — graceful shutdown on termination

  Capability queries, scope mappings, and telemetry emission do NOT
  use processes — they are pure functions in their respective modules.

  ## Registration

  Each session is registered in `MonkeyClaw.AgentBridge.SessionRegistry`
  under its `:id`, enabling lookup by name:

      {:via, Registry, {MonkeyClaw.AgentBridge.SessionRegistry, session_id}}

  ## PubSub Topics

  Sessions broadcast events on `"agent_session:<id>"`:

    * `{:session_started, id}` — Session is active
    * `{:session_stopped, id, reason}` — Session was stopped
    * `{:session_terminated, id, reason}` — Session crashed
    * `{:beam_agent_event, id, event}` — Event from BeamAgent
    * `{:stream_chunk, id, chunk}` — Streaming response chunk
    * `{:stream_done, id}` — Stream completed
    * `{:stream_error, id, reason}` — Stream failed
  """

  use GenServer

  require Logger

  alias MonkeyClaw.AgentBridge.CliResolver
  alias MonkeyClaw.AgentBridge.Telemetry, as: BridgeTelemetry

  # Default query timeout: 2 minutes (LLM queries can be slow)
  @default_query_timeout 120_000

  # Maximum events to drain per poll cycle (prevents blocking)
  @max_events_per_poll 100

  # Event polling interval in milliseconds
  @event_poll_interval_ms 100

  # Timeout for initiating a stream (obtaining the Enumerable, not consuming it)
  @default_stream_start_timeout 30_000

  @type session_id :: String.t()

  @type config :: %{
          required(:id) => session_id(),
          required(:session_opts) => map(),
          optional(:backend) => module(),
          optional(:query_timeout) => pos_integer(),
          optional(:subscribe_token) => binary()
        }

  @type t :: %__MODULE__{
          id: session_id(),
          session_pid: pid() | nil,
          beam_session_id: String.t() | nil,
          event_ref: reference() | nil,
          monitor_ref: reference() | nil,
          config: config(),
          backend: module(),
          status: :starting | :active | :stopping | :stopped | :terminated,
          started_at: DateTime.t() | nil,
          telemetry_start: integer() | nil,
          stream_task_ref: reference() | nil,
          stream_task_pid: pid() | nil,
          stream_caller: pid() | nil,
          stream_telemetry_start: integer() | nil
        }

  @enforce_keys [:id, :config]
  defstruct [
    :id,
    :session_pid,
    :beam_session_id,
    :event_ref,
    :monitor_ref,
    :config,
    :started_at,
    :telemetry_start,
    :backend,
    :stream_task_ref,
    :stream_task_pid,
    :stream_caller,
    :stream_telemetry_start,
    status: :starting
  ]

  # --- Child Spec ---

  @doc false
  def child_spec(config) do
    %{
      id: {__MODULE__, config.id},
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary
    }
  end

  # --- Client API ---

  @doc """
  Start a linked Session process.

  The `config` must include:

    * `:id` — Unique session identifier for registry lookup
    * `:session_opts` — Map of options passed to `BeamAgent.start_session/1`

  Optional:

    * `:query_timeout` — Timeout for query calls (default: #{@default_query_timeout}ms)
  """
  @spec start_link(config()) :: GenServer.on_start()
  def start_link(%{id: id} = config)
      when is_binary(id) and byte_size(id) > 0 do
    subscribe_token = Map.get(config, :subscribe_token)
    GenServer.start_link(__MODULE__, config, name: via(id, subscribe_token))
  end

  @doc """
  Send a synchronous query to the session.

  Blocks the caller until the BeamAgent responds or the timeout
  expires. The GenServer is occupied during the query — this is
  by design, as LLM sessions are inherently sequential.

  ## Options

    * `:timeout` — Override query timeout in milliseconds

  Returns `{:ok, messages}` on success or `{:error, reason}` on failure.
  """
  @spec query(GenServer.server(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def query(session, prompt, opts \\ []) when is_binary(prompt) do
    timeout = Keyword.get(opts, :timeout, @default_query_timeout)

    beam_params =
      opts
      |> Keyword.drop([:timeout])
      |> Map.new()

    GenServer.call(session, {:query, prompt, beam_params}, timeout)
  end

  @doc """
  Start a streaming query on the session.

  Spawns a monitored task that enumerates the backend stream.
  Chunks are delivered to the calling process as messages:

    * `{:stream_chunk, session_id, chunk}` — A response fragment
    * `{:stream_done, session_id}` — Stream completed successfully
    * `{:stream_error, session_id, reason}` — Stream failed

  The same events are broadcast on PubSub for other observers.

  Only one stream may be active per session. Returns
  `{:error, :stream_already_active}` if a stream is in progress.

  ## Options

    * `:timeout` — Timeout for stream initiation (default: #{@default_stream_start_timeout}ms)
    * `:stream_to` — PID to receive stream messages (default: `self()`)
  """
  @spec stream_query(GenServer.server(), String.t(), keyword()) ::
          {:ok, :streaming} | {:error, term()}
  def stream_query(session, prompt, opts \\ []) when is_binary(prompt) do
    timeout = Keyword.get(opts, :timeout, @default_stream_start_timeout)
    caller = Keyword.get(opts, :stream_to, self())

    beam_params =
      opts
      |> Keyword.drop([:timeout, :stream_to])
      |> Map.new()

    GenServer.call(session, {:stream_query, prompt, beam_params, caller}, timeout)
  end

  @doc """
  Change the model used by the session at runtime.

  Sends a control message to the underlying agent session to switch
  models. Returns `{:ok, term()}` on success or `{:error, term()}`
  on failure.
  """
  @spec set_model(GenServer.server(), String.t()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) when is_binary(model) and byte_size(model) > 0 do
    GenServer.call(session, {:set_model, model}, 10_000)
  end

  @valid_permission_modes [:default, :accept_edits, :bypass_permissions, :plan, :dont_ask]

  @doc """
  Change the permission mode used by the session at runtime.

  Controls how the agent handles tool execution approvals.
  Valid modes: #{Enum.map_join(@valid_permission_modes, ", ", &"`#{inspect(&1)}`")}.
  """
  @spec set_permission_mode(GenServer.server(), atom()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session, mode) when mode in @valid_permission_modes do
    GenServer.call(session, {:set_permission_mode, mode}, 10_000)
  end

  @doc """
  Get session metadata.

  Returns `{:ok, info_map}` with `:id`, `:status`, `:backend`,
  `:beam_session_id`, `:started_at`, and non-sensitive config.
  """
  @spec info(GenServer.server()) :: {:ok, map()}
  def info(session) do
    GenServer.call(session, :info)
  end

  @doc """
  Start a new thread within the session.

  Creates a BeamAgent thread and sets it as the active thread.
  Thread opts are passed to `BeamAgent.Threads.thread_start/2`.

  ## Options

    * `:name` — Thread name (e.g., channel name)
    * `:metadata` — Arbitrary metadata map

  Returns `{:ok, thread_info}` on success or `{:error, reason}` on failure.
  """
  @spec start_thread(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def start_thread(session, thread_opts \\ %{}) when is_map(thread_opts) do
    GenServer.call(session, {:start_thread, thread_opts})
  end

  @doc """
  Resume an existing thread within the session.

  Makes the specified thread the active thread for subsequent
  queries.
  """
  @spec resume_thread(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume_thread(session, thread_id)
      when is_binary(thread_id) and byte_size(thread_id) > 0 do
    GenServer.call(session, {:resume_thread, thread_id})
  end

  @doc """
  List all threads within the session.

  Returns `{:ok, threads}` with a list of thread info maps.
  """
  @spec list_threads(GenServer.server()) :: {:ok, list()} | {:error, term()}
  def list_threads(session) do
    GenServer.call(session, :list_threads)
  end

  @doc """
  Gracefully stop the session.

  Stops the underlying BeamAgent session and terminates the GenServer.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(session) do
    GenServer.call(session, :stop)
  end

  @doc """
  Build a `{:via, Registry, ...}` tuple for session registration.

  When a `subscribe_token` hash is provided, it is stored as the
  Registry value for later verification in `AgentBridge.subscribe/2`.
  The value is a SHA-256 hash — the raw token is never stored.
  Without a token, the Registry value defaults to `nil`.
  """
  @spec via(session_id(), binary() | nil) ::
          {:via, Registry,
           {MonkeyClaw.AgentBridge.SessionRegistry, session_id()}
           | {MonkeyClaw.AgentBridge.SessionRegistry, session_id(), binary()}}
  def via(id, subscribe_token \\ nil) when is_binary(id) do
    case subscribe_token do
      nil ->
        {:via, Registry, {MonkeyClaw.AgentBridge.SessionRegistry, id}}

      token when is_binary(token) ->
        {:via, Registry, {MonkeyClaw.AgentBridge.SessionRegistry, id, token}}
    end
  end

  @doc """
  Look up a session pid by ID.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` otherwise.
  """
  @spec lookup(session_id()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(id) when is_binary(id) do
    case Registry.lookup(MonkeyClaw.AgentBridge.SessionRegistry, id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Look up a session pid and its stored token hash by ID.

  Returns `{:ok, pid, token_hash}` if found, where `token_hash`
  is the SHA-256 hash stored during registration (or `nil` if no
  token was provided). Returns `{:error, :not_found}` otherwise.

  This keeps all Registry access encapsulated within the Session
  module — callers never need to know about Registry internals.
  """
  @spec lookup_with_token_hash(session_id()) ::
          {:ok, pid(), binary() | nil} | {:error, :not_found}
  def lookup_with_token_hash(id) when is_binary(id) do
    case Registry.lookup(MonkeyClaw.AgentBridge.SessionRegistry, id) do
      [{pid, token_hash}] -> {:ok, pid, token_hash}
      [] -> {:error, :not_found}
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(%{id: id, session_opts: session_opts} = config) do
    backend = Map.get(config, :backend, MonkeyClaw.AgentBridge.Backend.BeamAgent)

    # Generate a fresh UUID for each BeamAgent session. Claude CLI
    # requires --session-id to be a valid UUID (rejects BeamAgent's
    # default "session_<hex>" format with exit code 1). We use a
    # fresh UUID rather than the workspace ID because Claude CLI
    # accumulates conversation state per session_id — reusing a
    # stale ID can cause init failures.
    session_opts =
      session_opts
      |> Map.put_new(:session_id, Ecto.UUID.generate())
      |> CliResolver.resolve()

    state = %__MODULE__{id: id, config: config, status: :starting, backend: backend}

    telemetry_start =
      BridgeTelemetry.session_start(%{session_id: id, config: sanitize_config(config)})

    init_timeout = Map.get(session_opts, :init_timeout, 30_000)

    with {:ok, session_pid} <- backend.start_session(session_opts),
         # Wait for the BeamAgent session engine to reach :ready state.
         # start_session returns as soon as the gen_statem spawns, but
         # the CLI init handshake happens asynchronously. Querying
         # before :ready yields {error, unsupported}.
         :ok <- await_ready(backend, session_pid, init_timeout) do
      monitor_ref = Process.monitor(session_pid)
      beam_session_id = extract_session_id(backend, session_pid)
      event_ref = subscribe_events(backend, session_pid)

      active_state = %{
        state
        | session_pid: session_pid,
          beam_session_id: beam_session_id,
          event_ref: event_ref,
          monitor_ref: monitor_ref,
          status: :active,
          started_at: DateTime.utc_now(),
          telemetry_start: telemetry_start
      }

      _ = if is_reference(event_ref), do: schedule_event_poll()

      _ = broadcast(id, {:session_started, id})
      Logger.info("AgentBridge session #{id} started (beam_agent: #{beam_session_id})")

      {:ok, active_state}
    else
      {:error, reason} ->
        BridgeTelemetry.session_exception(telemetry_start, %{
          session_id: id,
          kind: :start_failure,
          reason: reason
        })

        Logger.error("AgentBridge session #{id} failed to start: #{inspect(reason)}")
        {:stop, {:failed_to_start_session, reason}}
    end
  end

  @impl true
  def handle_call({:query, _prompt, _params}, _from, %{stream_task_ref: ref} = state)
      when not is_nil(ref) do
    {:reply, {:error, :stream_in_progress}, state}
  end

  def handle_call({:query, prompt, beam_params}, _from, %{status: :active} = state) do
    telemetry_start = BridgeTelemetry.query_start(%{session_id: state.id})

    result = state.backend.query(state.session_pid, prompt, beam_params)

    case result do
      {:ok, messages} = result ->
        BridgeTelemetry.query_stop(telemetry_start, %{
          session_id: state.id,
          message_count: length(messages)
        })

        {:reply, result, state}

      {:error, reason} = error ->
        BridgeTelemetry.query_exception(telemetry_start, %{
          session_id: state.id,
          kind: :query_error,
          reason: reason
        })

        {:reply, error, state}
    end
  end

  def handle_call({:query, _prompt, _opts}, _from, state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call({:stream_query, _prompt, _params, _caller}, _from, %{stream_task_ref: ref} = state)
      when not is_nil(ref) do
    {:reply, {:error, :stream_already_active}, state}
  end

  def handle_call({:stream_query, prompt, beam_params, caller}, _from, %{status: :active} = state) do
    telemetry_start = BridgeTelemetry.stream_start(%{session_id: state.id})

    case state.backend.stream(state.session_pid, prompt, beam_params) do
      {:ok, stream} ->
        session_self = self()

        {task_pid, task_ref} =
          spawn_monitor(fn ->
            try do
              Enum.each(stream, fn
                {:ok, chunk} -> send(session_self, {:stream_chunk, chunk})
                {:error, reason} -> send(session_self, {:stream_error, reason})
              end)

              send(session_self, :stream_done)
            rescue
              error ->
                detail = {error.__struct__, Exception.message(error)}
                send(session_self, {:stream_error, detail})
            end
          end)

        new_state = %{
          state
          | stream_task_ref: task_ref,
            stream_task_pid: task_pid,
            stream_caller: caller,
            stream_telemetry_start: telemetry_start
        }

        {:reply, {:ok, :streaming}, new_state}

      {:error, reason} ->
        BridgeTelemetry.stream_exception(telemetry_start, %{
          session_id: state.id,
          kind: :stream_start_error,
          reason: reason
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stream_query, _prompt, _params, _caller}, _from, state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call({:set_model, model}, _from, %{status: :active} = state) do
    result = state.backend.set_model(state.session_pid, model)
    {:reply, result, state}
  end

  def handle_call({:set_model, _model}, _from, state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call({:set_permission_mode, mode}, _from, %{status: :active} = state) do
    result = state.backend.set_permission_mode(state.session_pid, mode)
    {:reply, result, state}
  end

  def handle_call({:set_permission_mode, _mode}, _from, state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call({:start_thread, thread_opts}, _from, %{status: :active} = state) do
    result = state.backend.thread_start(state.session_pid, thread_opts)
    {:reply, result, state}
  end

  def handle_call({:start_thread, _opts}, _from, state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call({:resume_thread, thread_id}, _from, %{status: :active} = state) do
    result = state.backend.thread_resume(state.session_pid, thread_id)
    {:reply, result, state}
  end

  def handle_call({:resume_thread, _thread_id}, _from, state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call(:list_threads, _from, %{status: :active} = state) do
    result = state.backend.thread_list(state.session_pid)
    {:reply, result, state}
  end

  def handle_call(:list_threads, _from, state) do
    {:reply, {:error, :session_unavailable}, state}
  end

  def handle_call(:info, _from, state) do
    info = %{
      id: state.id,
      status: state.status,
      backend: get_in(state.config, [:session_opts, :backend]),
      beam_session_id: state.beam_session_id,
      started_at: state.started_at,
      config: sanitize_config(state.config)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:stop, _from, %{status: :active} = state) do
    new_state = do_stop_session(state, :normal)
    {:stop, :normal, :ok, new_state}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, %{state | status: :stopped}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    Logger.warning("BeamAgent session #{state.id} terminated unexpectedly: #{inspect(reason)}")

    case state.telemetry_start do
      nil ->
        :ok

      start_time ->
        BridgeTelemetry.session_exception(start_time, %{
          session_id: state.id,
          kind: :beam_agent_down,
          reason: reason
        })
    end

    _ = broadcast(state.id, {:session_terminated, state.id, reason})

    {:stop, {:beam_agent_terminated, reason}, %{state | status: :terminated}}
  end

  # Stream task crashed — notify caller if the task didn't send a completion signal
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_task_ref: ref} = state) do
    unless reason == :normal do
      Logger.warning("Stream task for session #{state.id} crashed: #{inspect(reason)}")

      if is_pid(state.stream_caller) do
        send(state.stream_caller, {:stream_error, state.id, {:task_crashed, reason}})
      end

      _ = broadcast(state.id, {:stream_error, state.id, {:task_crashed, reason}})

      emit_stream_exception(state, :stream_task_crash, reason)
    end

    {:noreply, clear_stream_state(state)}
  end

  # Streaming chunk from the enumeration task
  def handle_info({:stream_chunk, chunk}, %{stream_caller: caller} = state)
      when is_pid(caller) do
    send(caller, {:stream_chunk, state.id, chunk})
    _ = broadcast(state.id, {:stream_chunk, state.id, chunk})
    {:noreply, state}
  end

  # Stream completed successfully — demonitor with :flush to prevent
  # a subsequent :DOWN from triggering double-cleanup.
  def handle_info(:stream_done, %{stream_caller: caller, stream_task_ref: ref} = state)
      when is_pid(caller) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    send(caller, {:stream_done, state.id})
    _ = broadcast(state.id, {:stream_done, state.id})

    case state.stream_telemetry_start do
      nil -> :ok
      start_time -> BridgeTelemetry.stream_stop(start_time, %{session_id: state.id})
    end

    {:noreply, clear_stream_state(state)}
  end

  # Stream error from the enumeration task — demonitor with :flush to
  # prevent a subsequent :DOWN from triggering double-cleanup.
  def handle_info({:stream_error, reason}, %{stream_caller: caller, stream_task_ref: ref} = state)
      when is_pid(caller) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    send(caller, {:stream_error, state.id, reason})
    _ = broadcast(state.id, {:stream_error, state.id, reason})

    emit_stream_exception(state, :stream_error, reason)

    {:noreply, clear_stream_state(state)}
  end

  def handle_info(:poll_events, %{status: :active, event_ref: ref} = state)
      when not is_nil(ref) do
    drain_events(state, @max_events_per_poll)
    schedule_event_poll()
    {:noreply, state}
  end

  def handle_info(:poll_events, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("AgentBridge session #{state.id} received unexpected message: #{inspect(msg)}")

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{status: :active} = state) do
    _ = do_stop_session(state, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private Helpers ---

  defp do_stop_session(state, reason) do
    # Kill any active stream task first — it holds a reference to the
    # BeamAgent session pid and would fail mid-enumeration otherwise.
    state = kill_stream_task(state)

    # Demonitor before stopping to prevent {:DOWN} race during shutdown
    if is_reference(state.monitor_ref) do
      Process.demonitor(state.monitor_ref, [:flush])
    end

    # Unsubscribe from events before stopping the session process.
    # This flushes any pending events on the BeamAgent side.
    unsubscribe_events(state)

    case state.session_pid do
      nil ->
        :ok

      pid ->
        try do
          state.backend.stop_session(pid)
        catch
          kind, error ->
            Logger.debug(
              "AgentBridge session #{state.id} stop failed (#{kind}): #{inspect(error)}"
            )
        end
    end

    case state.telemetry_start do
      nil ->
        :ok

      start_time ->
        BridgeTelemetry.session_stop(start_time, %{
          session_id: state.id,
          reason: reason
        })
    end

    _ = broadcast(state.id, {:session_stopped, state.id, reason})
    Logger.info("AgentBridge session #{state.id} stopped: #{inspect(reason)}")

    %{state | status: :stopped, session_pid: nil, monitor_ref: nil, event_ref: nil}
  end

  # Poll session_info until the BeamAgent session engine reaches :ready.
  # Returns :ok on success, {:error, reason} on failure or timeout.
  # Poll interval is 100ms — fast enough for a cold-start handshake,
  # cheap enough to not spin the CPU.
  @ready_poll_interval_ms 100

  defp await_ready(backend, session_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ready(backend, session_pid, deadline)
  end

  defp do_await_ready(backend, session_pid, deadline) do
    case backend.session_info(session_pid) do
      {:ok, %{state: :ready}} ->
        :ok

      {:ok, %{state: :error}} ->
        {:error, :session_entered_error_state}

      {:ok, %{state: state}} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, {:session_not_ready, state}}
        else
          Process.sleep(min(@ready_poll_interval_ms, remaining))
          do_await_ready(backend, session_pid, deadline)
        end

      {:error, reason} ->
        {:error, {:health_check_failed, reason}}
    end
  end

  defp extract_session_id(backend, session_pid) when is_pid(session_pid) do
    case backend.session_info(session_pid) do
      {:ok, info} when is_map(info) -> Map.get(info, :session_id, inspect(session_pid))
      _ -> inspect(session_pid)
    end
  rescue
    error ->
      Logger.debug("Failed to extract beam session id: #{Exception.message(error)}")
      inspect(session_pid)
  end

  defp subscribe_events(backend, session_pid) do
    case backend.event_subscribe(session_pid) do
      {:ok, ref} -> ref
      _ -> nil
    end
  rescue
    error ->
      Logger.debug("Failed to subscribe to beam agent events: #{Exception.message(error)}")
      nil
  end

  defp drain_events(_state, 0), do: :ok

  defp drain_events(
         %{session_pid: pid, event_ref: ref, id: id, backend: backend} = state,
         remaining
       ) do
    case backend.receive_event(pid, ref, 0) do
      {:ok, event} ->
        event_type = Map.get(event, :type, :unknown)

        BridgeTelemetry.event_received(%{session_id: id, event_type: event_type})
        _ = broadcast(id, {:beam_agent_event, id, event})

        drain_events(state, remaining - 1)

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Failed to drain beam agent event: #{Exception.message(error)}")
      :ok
  end

  defp schedule_event_poll do
    Process.send_after(self(), :poll_events, @event_poll_interval_ms)
  end

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(MonkeyClaw.PubSub, "agent_session:#{session_id}", message)
  end

  # Kill an active stream task and clean up its state.
  # Safe to call when no stream is active (returns state unchanged).
  defp kill_stream_task(%{stream_task_pid: pid, stream_task_ref: ref} = state)
       when is_pid(pid) and is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)

    if is_pid(state.stream_caller) do
      send(state.stream_caller, {:stream_error, state.id, :session_stopped})
    end

    emit_stream_exception(state, :stream_killed, :session_stopped)

    clear_stream_state(state)
  end

  defp kill_stream_task(state), do: state

  # Unsubscribe from BeamAgent events. Safe to call when not subscribed.
  defp unsubscribe_events(%{event_ref: ref, session_pid: pid, backend: backend} = state)
       when is_reference(ref) and is_pid(pid) do
    try do
      backend.event_unsubscribe(pid, ref)
    catch
      kind, error ->
        Logger.warning(
          "Failed to unsubscribe events for session #{state.id} (#{kind}): #{inspect(error)}"
        )
    end
  end

  defp unsubscribe_events(_state), do: :ok

  # Reset all stream-related state fields.
  # Callers are responsible for demonitoring before calling this function
  # (either via kill_stream_task or handle_info({:DOWN, ...})).
  defp clear_stream_state(state) do
    %{
      state
      | stream_task_ref: nil,
        stream_task_pid: nil,
        stream_caller: nil,
        stream_telemetry_start: nil
    }
  end

  # Emit a stream exception telemetry event if a start time is available.
  defp emit_stream_exception(%{stream_telemetry_start: nil}, _kind, _reason), do: :ok

  defp emit_stream_exception(state, kind, reason) do
    BridgeTelemetry.stream_exception(state.stream_telemetry_start, %{
      session_id: state.id,
      kind: kind,
      reason: reason
    })
  end

  # Allowlist: only expose known-safe config keys.
  # Never expose session_opts (may contain credentials) or
  # subscribe_token (auth material stored as hash in Registry).
  @safe_config_keys [:id, :query_timeout, :backend]

  defp sanitize_config(config) when is_map(config) do
    Map.take(config, @safe_config_keys)
  end
end
