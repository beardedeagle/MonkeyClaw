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
  """

  use GenServer

  require Logger

  alias MonkeyClaw.AgentBridge.Telemetry, as: BridgeTelemetry

  # Default query timeout: 2 minutes (LLM queries can be slow)
  @default_query_timeout 120_000

  # Maximum events to drain per poll cycle (prevents blocking)
  @max_events_per_poll 100

  # Event polling interval in milliseconds
  @event_poll_interval_ms 100

  @type session_id :: String.t()

  @type config :: %{
          required(:id) => session_id(),
          required(:session_opts) => map(),
          optional(:backend) => module(),
          optional(:query_timeout) => pos_integer()
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
          telemetry_start: integer() | nil
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
    GenServer.start_link(__MODULE__, config, name: via(id))
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
  Get session metadata.

  Returns `{:ok, info_map}` with `:id`, `:status`, `:beam_session_id`,
  `:started_at`, and non-sensitive config.
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
  Build a `{:via, Registry, ...}` tuple for session lookup.
  """
  @spec via(session_id()) :: {:via, Registry, {atom(), session_id()}}
  def via(id) when is_binary(id) do
    {:via, Registry, {MonkeyClaw.AgentBridge.SessionRegistry, id}}
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

  # --- Server Callbacks ---

  @impl true
  def init(%{id: id, session_opts: session_opts} = config) do
    backend = Map.get(config, :backend, MonkeyClaw.AgentBridge.Backend.BeamAgent)
    state = %__MODULE__{id: id, config: config, status: :starting, backend: backend}

    telemetry_start =
      BridgeTelemetry.session_start(%{session_id: id, config: sanitize_config(config)})

    case backend.start_session(session_opts) do
      {:ok, session_pid} ->
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
    # Demonitor before stopping to prevent {:DOWN} race during shutdown
    if is_reference(state.monitor_ref) do
      Process.demonitor(state.monitor_ref, [:flush])
    end

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

    %{state | status: :stopped, session_pid: nil, monitor_ref: nil}
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

  # Allowlist: only expose known-safe config keys (never session_opts which may contain credentials)
  @safe_config_keys [:id, :query_timeout, :backend]

  defp sanitize_config(config) when is_map(config) do
    Map.take(config, @safe_config_keys)
  end
end
