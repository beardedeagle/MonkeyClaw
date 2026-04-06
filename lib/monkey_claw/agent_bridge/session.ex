defmodule MonkeyClaw.AgentBridge.Session do
  @moduledoc """
  GenServer wrapping a single BeamAgent session.

  Each Session process manages the lifecycle of one BeamAgent session,
  including:

    * Starting and stopping the underlying BeamAgent session
    * Monitoring the session process for unexpected termination
    * Subscribing to BeamAgent events and forwarding via Phoenix.PubSub
    * Emitting telemetry events for observability
    * Persisting conversation history to SQLite (fire-and-forget)

  ## History Persistence

  On init, the GenServer creates a `MonkeyClaw.Sessions.Session` record in
  SQLite. Query results and accumulated stream content are persisted as
  `MonkeyClaw.Sessions.Message` records after each interaction completes.
  Session status is updated on stop (`:stopped`) or crash (`:crashed`).

  All persistence is wrapped in rescue blocks — storage failures are logged
  but never crash the GenServer. The primary job (BeamAgent session
  management) is never compromised by the secondary job (SQLite persistence).

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
  alias MonkeyClaw.Sessions
  alias MonkeyClaw.Workspaces

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
          stream_telemetry_start: integer() | nil,
          history_session: Sessions.Session.t() | nil,
          stream_content_buffer: String.t() | :overflow | nil,
          stream_metadata: map() | nil
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
    :history_session,
    :stream_content_buffer,
    :stream_metadata,
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

    if is_pid(caller) do
      beam_params =
        opts
        |> Keyword.drop([:timeout, :stream_to])
        |> Map.new()

      GenServer.call(session, {:stream_query, prompt, beam_params, caller}, timeout)
    else
      {:error, :invalid_stream_to}
    end
  end

  @doc """
  Cancel the active stream, if any.

  Sends an asynchronous cast to kill the stream task and clean up
  stream state. Safe to call when no stream is active (no-op).

  This is a cast (fire-and-forget) because the caller has already
  decided to stop consuming chunks and doesn't need a reply.
  """
  @spec cancel_stream(GenServer.server()) :: :ok
  def cancel_stream(session) do
    GenServer.cast(session, :cancel_stream)
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
  @spec set_permission_mode(GenServer.server(), MonkeyClaw.AgentBridge.Backend.permission_mode()) ::
          {:ok, term()} | {:error, term()}
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
          telemetry_start: telemetry_start,
          history_session: create_history_session(state)
      }

      _ = if is_reference(event_ref), do: schedule_event_poll()

      _ = broadcast(id, {:session_started, id})
      Logger.info("AgentBridge session #{id} started (beam_agent: #{beam_session_id})")

      fire_model_hook(backend, session_opts, self())

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
        state = persist_query_messages(state, prompt, messages)

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

  def handle_call(
        {:stream_query, _prompt, _params, _caller},
        _from,
        %{stream_task_ref: ref} = state
      )
      when not is_nil(ref) do
    {:reply, {:error, :stream_already_active}, state}
  end

  def handle_call({:stream_query, prompt, beam_params, caller}, _from, %{status: :active} = state) do
    telemetry_start = BridgeTelemetry.stream_start(%{session_id: state.id})

    case state.backend.stream(state.session_pid, prompt, beam_params) do
      {:ok, stream} ->
        # Persist user message before streaming begins
        _ = persist_user_message(state, prompt)

        session_self = self()

        {task_pid, task_ref} =
          spawn_monitor(fn ->
            try do
              result =
                Enum.reduce_while(stream, :ok, fn
                  {:ok, chunk}, :ok ->
                    send(session_self, {:stream_chunk, chunk})
                    {:cont, :ok}

                  {:error, reason}, :ok ->
                    send(session_self, {:stream_error, reason})
                    {:halt, :error}
                end)

              if result == :ok, do: send(session_self, :stream_done)
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
            stream_telemetry_start: telemetry_start,
            stream_content_buffer: ""
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
      config: sanitize_config(state.config),
      history_session_id: history_session_id(state)
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
  def handle_cast(:cancel_stream, state) do
    {:noreply, kill_stream_task(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    Logger.warning("BeamAgent session #{state.id} terminated unexpectedly: #{inspect(reason)}")

    _ = update_history_status(state, :crashed)

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

  # Stream task exited normally — the in-band :stream_done or :stream_error
  # message handles cleanup and demonitors with :flush. No-op here to
  # prevent clearing state before those messages are processed.
  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{stream_task_ref: ref} = state) do
    {:noreply, state}
  end

  # Stream task crashed — notify caller and clean up since the in-band
  # completion message was likely never sent.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_task_ref: ref} = state) do
    Logger.warning("Stream task for session #{state.id} crashed: #{inspect(reason)}")

    if is_pid(state.stream_caller) do
      send(state.stream_caller, {:stream_error, state.id, {:task_crashed, reason}})
    end

    _ = broadcast(state.id, {:stream_error, state.id, {:task_crashed, reason}})

    emit_stream_exception(state, :stream_task_crash, reason)

    {:noreply, clear_stream_state(state)}
  end

  # Streaming chunk from the enumeration task
  def handle_info({:stream_chunk, chunk}, %{stream_caller: caller} = state)
      when is_pid(caller) do
    send(caller, {:stream_chunk, state.id, chunk})
    _ = broadcast(state.id, {:stream_chunk, state.id, chunk})

    state =
      state
      |> accumulate_chunk(chunk)
      |> capture_stream_metadata(chunk)

    {:noreply, state}
  end

  # Stream completed successfully — demonitor with :flush to prevent
  # a subsequent :DOWN from triggering double-cleanup.
  def handle_info(:stream_done, %{stream_caller: caller, stream_task_ref: ref} = state)
      when is_pid(caller) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    send(caller, {:stream_done, state.id})
    _ = broadcast(state.id, {:stream_done, state.id})

    # Persist accumulated stream content as assistant message
    state = persist_stream_result(state)

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

    _ = update_history_status(state, :stopped)
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

  # Fire an authenticated async cast to ModelRegistry with the freshly
  # observed model list from this session. Runs under TaskSupervisor
  # so adapter latency or crashes never block session lifecycle while
  # retaining OTP-level crash visibility. The session pid is already
  # registered in SessionRegistry by the time init/1 runs (`:via`
  # registration is synchronous before init).
  # The registry verifies the pid before accepting the payload (spec C3).
  @spec fire_model_hook(module(), map(), pid()) :: :ok
  defp fire_model_hook(backend, session_opts, session_pid) do
    _ =
      Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
        try do
          case backend.list_models(session_opts) do
            {:ok, model_attrs_list} when is_list(model_attrs_list) ->
              backend_name = resolve_backend_name(session_opts, backend)
              now = DateTime.utc_now()
              mono = System.monotonic_time()

              payload =
                model_attrs_list
                |> Enum.group_by(& &1.provider)
                |> Enum.map(fn {provider, attrs_list} ->
                  %{
                    backend: to_string(backend_name),
                    provider: provider,
                    source: "session",
                    refreshed_at: now,
                    refreshed_mono: mono,
                    models: Enum.map(attrs_list, &Map.delete(&1, :provider))
                  }
                end)

              GenServer.cast(MonkeyClaw.ModelRegistry, {:session_hook, session_pid, payload})

            _ ->
              :ok
          end
        rescue
          e ->
            Logger.debug("Session: fire_model_hook failed: #{Exception.message(e)}")
            :ok
        end
      end)

    :ok
  end

  # Resolve the backend name for ModelRegistry tagging from the
  # standard `:backend` key produced by `Scope.session_opts/1`
  # (e.g., `:claude`, `:gemini`, `:codex`). Converts the atom to
  # a string for the registry's `(backend, provider)` composite key.
  @spec resolve_backend_name(map(), module()) :: String.t()
  defp resolve_backend_name(session_opts, backend) do
    case Map.get(session_opts, :backend) do
      name when is_atom(name) and not is_nil(name) ->
        Atom.to_string(name)

      _ ->
        Logger.warning(
          "Session: no :backend in session_opts for #{inspect(backend)} in fire_model_hook; " <>
            "ModelRegistry rows will be written under backend \"unknown\"."
        )

        "unknown"
    end
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

    _ = broadcast(state.id, {:stream_error, state.id, :session_stopped})
    emit_stream_exception(state, :stream_killed, :session_stopped)

    clear_stream_state(state)
  end

  defp kill_stream_task(state), do: state

  # Unsubscribe from BeamAgent events. Safe to call when not subscribed.
  defp unsubscribe_events(%{event_ref: ref, session_pid: pid, backend: backend} = state)
       when is_reference(ref) and is_pid(pid) do
    backend.event_unsubscribe(pid, ref)
  catch
    kind, error ->
      Logger.warning(
        "Failed to unsubscribe events for session #{state.id} (#{kind}): #{inspect(error)}"
      )
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
        stream_telemetry_start: nil,
        stream_content_buffer: nil,
        stream_metadata: nil
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

  # ──────────────────────────────────────────────
  # History Persistence (fire-and-forget)
  #
  # All persistence helpers are defensive: failures are logged
  # but never crash the GenServer. The live BeamAgent session
  # is primary; SQLite history is durable secondary storage.
  # ──────────────────────────────────────────────

  # Create a SQLite session record for history persistence.
  # Returns the Session struct on success, nil on failure.
  defp create_history_session(state) do
    workspace_id = state.id
    model = get_in(state.config, [:session_opts, :model])
    attrs = if model, do: %{model: to_string(model)}, else: %{}

    with {:ok, workspace} <- Workspaces.get_workspace(workspace_id),
         {:ok, session} <- Sessions.create_session(workspace, attrs) do
      session
    else
      {:error, reason} ->
        Logger.warning("Failed to create history session for #{workspace_id}: #{inspect(reason)}")

        nil
    end
  rescue
    error ->
      Logger.warning(
        "History session creation crashed for #{state.id}: #{Exception.message(error)}"
      )

      nil
  end

  # Persist the user prompt and all response messages from a synchronous query.
  # Returns updated state (may have derived title).
  defp persist_query_messages(%{history_session: nil} = state, _prompt, _messages), do: state

  defp persist_query_messages(%{history_session: session} = state, prompt, messages) do
    _ = safe_record_message(session, %{role: :user, content: prompt})

    Enum.each(messages, fn msg ->
      role = extract_message_role(msg)
      content = extract_message_content(msg)
      metadata = extract_message_metadata(msg)
      _ = safe_record_message(session, %{role: role, content: content, metadata: metadata})
    end)

    maybe_derive_title(state)
  rescue
    error ->
      Logger.warning("Failed to persist query messages: #{Exception.message(error)}")
      state
  end

  # Persist a single user message (used before streaming begins).
  defp persist_user_message(%{history_session: nil}, _prompt), do: :ok

  defp persist_user_message(%{history_session: session}, prompt) do
    _ = safe_record_message(session, %{role: :user, content: prompt})
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist user message: #{Exception.message(error)}")
      :ok
  end

  # Persist the accumulated stream buffer as an assistant message.
  # Returns updated state (may have derived title).
  defp persist_stream_result(%{history_session: nil} = state), do: state

  defp persist_stream_result(%{history_session: session, stream_content_buffer: buffer} = state)
       when is_binary(buffer) and byte_size(buffer) > 0 do
    metadata = build_persist_metadata(state.stream_metadata)
    _ = safe_record_message(session, %{role: :assistant, content: buffer, metadata: metadata})
    maybe_derive_title(state)
  rescue
    error ->
      Logger.warning("Failed to persist stream result: #{Exception.message(error)}")
      state
  end

  defp persist_stream_result(%{stream_content_buffer: :overflow} = state) do
    Logger.warning("Skipping history persistence for session #{state.id}: stream buffer overflow")
    state
  end

  defp persist_stream_result(state), do: state

  # Maximum stream content buffer size for history persistence.
  # Matches the LiveView cap to prevent unbounded GenServer heap growth
  # from a malicious or malfunctioning backend.
  @max_history_buffer_bytes 2_000_000

  # Append chunk text to the stream content buffer.
  # Only accumulates when a buffer exists (stream was initiated with persistence).
  # Stops accumulating once the buffer exceeds @max_history_buffer_bytes.
  #
  # Note: `buffer <> text` uses BEAM's binary append optimization — when the
  # binary being appended to has no other references, the VM over-allocates
  # and appends in-place (amortized O(1)). This is safe here because the
  # GenServer state is the sole owner of the buffer binary.
  defp accumulate_chunk(%{stream_content_buffer: buffer} = state, chunk)
       when is_binary(buffer) do
    text = extract_chunk_text(chunk)

    if byte_size(buffer) + byte_size(text) > @max_history_buffer_bytes do
      Logger.warning(
        "Stream history buffer exceeded #{@max_history_buffer_bytes} bytes " <>
          "for session #{state.id}, stopping accumulation"
      )

      %{state | stream_content_buffer: :overflow}
    else
      %{state | stream_content_buffer: buffer <> text}
    end
  end

  defp accumulate_chunk(state, _chunk), do: state

  # Update the history session status (e.g., :stopped, :crashed).
  defp update_history_status(%{history_session: nil}, _status), do: :ok

  defp update_history_status(%{history_session: session}, status) do
    case Sessions.update_session(session, %{status: status}) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update history session status: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("History status update crashed: #{Exception.message(error)}")
      :ok
  end

  # Derive session title from first user message if not yet set.
  # Returns updated state with the derived title to avoid redundant derives.
  defp maybe_derive_title(%{history_session: %{title: title}} = state)
       when is_binary(title) and byte_size(title) > 0 do
    state
  end

  defp maybe_derive_title(%{history_session: session} = state) do
    case Sessions.derive_title(session) do
      {:ok, updated_session} -> %{state | history_session: updated_session}
      _ -> state
    end
  rescue
    _ -> state
  end

  # Record a message with error handling. Never raises.
  defp safe_record_message(session, attrs) do
    case Sessions.record_message(session, attrs) do
      {:ok, message} ->
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("Failed to record message: #{inspect(changeset.errors)}")
        :error

      {:error, reason} ->
        Logger.warning("Failed to record message: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("Message recording crashed: #{Exception.message(error)}")
      :error
  end

  # Extract the history session ID from state, or nil.
  defp history_session_id(%{history_session: %{id: id}}), do: id
  defp history_session_id(_), do: nil

  # ──────────────────────────────────────────────
  # Message Content Extraction
  #
  # BeamAgent backends return messages and chunks in varying
  # formats. These extractors handle atom keys, string keys,
  # and plain binaries defensively.
  # ──────────────────────────────────────────────

  defp extract_message_role(%{role: role}), do: normalize_role(role)
  defp extract_message_role(%{"role" => role}), do: normalize_role(role)
  defp extract_message_role(_), do: :assistant

  @role_map %{
    "user" => :user,
    "assistant" => :assistant,
    "system" => :system,
    "tool_use" => :tool_use,
    "tool_result" => :tool_result
  }

  defp normalize_role(role)
       when is_atom(role) and role in [:user, :assistant, :system, :tool_use, :tool_result] do
    role
  end

  defp normalize_role(role) when is_binary(role), do: Map.get(@role_map, role, :assistant)
  defp normalize_role(_), do: :assistant

  defp extract_message_content(%{content: content}) when is_binary(content), do: content
  defp extract_message_content(%{"content" => content}) when is_binary(content), do: content

  defp extract_message_content(%{content_blocks: blocks}) when is_list(blocks),
    do: extract_text_from_blocks(blocks)

  defp extract_message_content(%{"content_blocks" => blocks}) when is_list(blocks),
    do: extract_text_from_blocks(blocks)

  defp extract_message_content(_), do: nil

  defp extract_text_from_blocks(blocks) do
    text =
      blocks
      |> Enum.map(&extract_chunk_text/1)
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.join("")

    if byte_size(text) > 0, do: text, else: nil
  end

  # Capture usage metadata from :assistant / :result chunks during streaming.
  # Later chunks overwrite earlier ones — :result arrives last and carries
  # the most complete usage snapshot.
  defp capture_stream_metadata(state, %{type: type, usage: usage} = chunk)
       when type in [:result, :assistant] and is_map(usage) do
    %{
      state
      | stream_metadata: %{
          "usage" => usage,
          "model" => Map.get(chunk, :model),
          "duration_ms" => Map.get(chunk, :duration_ms)
        }
    }
  end

  defp capture_stream_metadata(state, _chunk), do: state

  # Build a flat metadata map for SQLite persistence from the captured
  # stream metadata.  Keys are strings (JSON column).
  defp build_persist_metadata(nil), do: %{}

  defp build_persist_metadata(%{"usage" => usage} = meta) when is_map(usage) do
    cache_read = Map.get(usage, "cache_read_input_tokens", 0) || 0
    cache_create = Map.get(usage, "cache_creation_input_tokens", 0) || 0
    cached = cache_read + cache_create

    %{
      "input_tokens" => Map.get(usage, "input_tokens"),
      "output_tokens" => Map.get(usage, "output_tokens"),
      "cached_tokens" => if(cached > 0, do: cached),
      "thinking_tokens" => Map.get(usage, "thinking_tokens"),
      "model" => meta["model"],
      "duration_ms" => meta["duration_ms"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_persist_metadata(_), do: %{}

  # Extract metadata from a raw BeamAgent message (non-streaming path).
  defp extract_message_metadata(%{usage: usage} = msg) when is_map(usage) do
    build_persist_metadata(%{
      "usage" => usage,
      "model" => Map.get(msg, :model),
      "duration_ms" => Map.get(msg, :duration_ms)
    })
  end

  defp extract_message_metadata(%{"usage" => usage} = msg) when is_map(usage) do
    build_persist_metadata(%{
      "usage" => usage,
      "model" => Map.get(msg, "model"),
      "duration_ms" => Map.get(msg, "duration_ms")
    })
  end

  defp extract_message_metadata(_), do: %{}

  defp extract_chunk_text(chunk) when is_binary(chunk), do: chunk
  defp extract_chunk_text(%{text: text}) when is_binary(text), do: text
  defp extract_chunk_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_chunk_text(%{content: content}) when is_binary(content), do: content
  defp extract_chunk_text(%{"content" => content}) when is_binary(content), do: content
  defp extract_chunk_text(_), do: ""
end
