defmodule MonkeyClaw.AgentBridge do
  @moduledoc """
  Public API for MonkeyClaw's integration with BeamAgent.

  This module is the single entry point for all MonkeyClaw code
  that needs to interact with the BeamAgent runtime. It provides
  a clean, MonkeyClaw-flavored API that hides BeamAgent internals
  and maps between product concepts.

  ## Architecture

  ```
  MonkeyClaw Product Layer
  ─────────────────────────
  MonkeyClaw.AgentBridge     ← you are here
  ─────────────────────────
  beam_agent_ex public API
  ─────────────────────────
  BeamAgent Erlang Core
  ```

  ## Process Architecture

  The bridge manages a supervision subtree within `MonkeyClaw.Supervisor`:

    * `MonkeyClaw.AgentBridge.SessionRegistry` — Registry for session
      lookup by ID (built-in OTP Registry, not a custom process)
    * `MonkeyClaw.AgentBridge.SessionSupervisor` — DynamicSupervisor
      for Session GenServer children
    * One `MonkeyClaw.AgentBridge.Session` GenServer per active session

  ## What Is a Process and What Isn't

    * **Process**: Session (stateful lifecycle), SessionSupervisor
      (manages children), Registry (name lookup)
    * **NOT a process**: This facade module, Capabilities, Scope,
      Telemetry — all pure function modules

  ## Usage

      # Start a session
      {:ok, pid} = MonkeyClaw.AgentBridge.start_session(%{
        id: "workspace-123",
        session_opts: %{backend: :claude, model: "opus"}
      })

      # Subscribe to events
      MonkeyClaw.AgentBridge.subscribe("workspace-123")

      # Send a query
      {:ok, messages} = MonkeyClaw.AgentBridge.query("workspace-123", "Hello!")

      # Stop the session
      :ok = MonkeyClaw.AgentBridge.stop_session("workspace-123")

  ## Related Modules

    * `MonkeyClaw.AgentBridge.Session` — GenServer per session
    * `MonkeyClaw.AgentBridge.SessionSupervisor` — DynamicSupervisor
    * `MonkeyClaw.AgentBridge.Capabilities` — Capability queries
    * `MonkeyClaw.AgentBridge.Scope` — Product concept → BeamAgent scope mapping
    * `MonkeyClaw.AgentBridge.Telemetry` — Telemetry event emission
  """

  alias MonkeyClaw.AgentBridge.{Capabilities, Session, SessionSupervisor}

  @type session_id :: Session.session_id()

  # --- Session Lifecycle ---

  @doc """
  Start a new supervised agent session.

  The `config` map must include:

    * `:id` — Unique session identifier (typically a workspace ID)
    * `:session_opts` — Map of options for `BeamAgent.start_session/1`

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.

  ## Examples

      MonkeyClaw.AgentBridge.start_session(%{
        id: "workspace-123",
        session_opts: %{backend: :claude}
      })
  """
  @spec start_session(Session.config()) :: {:ok, pid()} | {:error, term()}
  def start_session(%{id: _id, session_opts: _opts} = config) do
    SessionSupervisor.start_session(config)
  end

  @doc """
  Stop an agent session by ID.

  Gracefully stops the underlying BeamAgent session and terminates
  the Session GenServer.
  """
  @spec stop_session(session_id()) :: :ok | {:error, {:session_not_found, session_id()}}
  def stop_session(session_id) when is_binary(session_id) and byte_size(session_id) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.stop(pid)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  # --- Queries ---

  @doc """
  Send a synchronous query to a session.

  Blocks until the BeamAgent responds or the timeout expires.
  Default timeout is 120 seconds.

  ## Options

    * `:timeout` — Query timeout in milliseconds (default: 120_000)

  Returns `{:ok, messages}` on success or `{:error, reason}` on failure.
  """
  @spec query(session_id(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def query(session_id, prompt, opts \\ [])
      when is_binary(session_id) and byte_size(session_id) > 0 and
             is_binary(prompt) and byte_size(prompt) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.query(pid, prompt, opts)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  # --- Thread Management ---

  @doc """
  Start a new thread within a session.

  Creates a BeamAgent thread and sets it as the active thread.
  Thread opts are passed through to `BeamAgent.Threads.thread_start/2`.

  ## Options

    * `:name` — Thread name (e.g., channel name)
    * `:metadata` — Arbitrary metadata map

  Returns `{:ok, thread_info}` on success or `{:error, reason}` on failure.
  """
  @spec start_thread(session_id(), map()) :: {:ok, map()} | {:error, term()}
  def start_thread(session_id, thread_opts \\ %{})
      when is_binary(session_id) and byte_size(session_id) > 0 and
             is_map(thread_opts) do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.start_thread(pid, thread_opts)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  @doc """
  Resume an existing thread within a session.

  Makes the specified thread the active thread for subsequent
  queries.
  """
  @spec resume_thread(session_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume_thread(session_id, thread_id)
      when is_binary(session_id) and byte_size(session_id) > 0 and
             is_binary(thread_id) and byte_size(thread_id) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.resume_thread(pid, thread_id)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  @doc """
  List all threads within a session.

  Returns `{:ok, threads}` with a list of thread info maps.
  """
  @spec list_threads(session_id()) :: {:ok, list()} | {:error, term()}
  def list_threads(session_id)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.list_threads(pid)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  # --- Session Info ---

  @doc """
  Get session metadata by ID.

  Returns `{:ok, info_map}` with session status, timestamps, and
  non-sensitive configuration.
  """
  @spec session_info(session_id()) :: {:ok, map()} | {:error, {:session_not_found, session_id()}}
  def session_info(session_id) when is_binary(session_id) and byte_size(session_id) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.info(pid)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  @doc """
  List all active session IDs.

  Returns a list of session IDs currently registered in the
  session registry.
  """
  @spec list_sessions() :: [session_id()]
  def list_sessions do
    MonkeyClaw.AgentBridge.SessionRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Count active sessions.
  """
  @spec session_count() :: non_neg_integer()
  defdelegate session_count(), to: SessionSupervisor, as: :count_sessions

  # --- Event Subscription ---

  @doc """
  Subscribe the calling process to session events via PubSub.

  ## Security

  Access to this function is gated by mTLS at the transport layer.
  Unauthenticated connections are rejected during the TLS handshake
  before any application code executes. The session existence check
  below is defense-in-depth — it ensures the caller cannot subscribe
  to a non-existent session, not that they are authorized (authorization
  is handled by the client certificate). In MonkeyClaw's single-user
  model, all sessions belong to the owner.

  ## Events

  Events are delivered as messages to the subscriber:

    * `{:session_started, id}`
    * `{:session_stopped, id, reason}`
    * `{:session_terminated, id, reason}`
    * `{:beam_agent_event, id, event}`
  """
  @spec subscribe(session_id()) ::
          :ok | {:error, {:session_not_found, session_id()} | {:already_registered, pid()}}
  def subscribe(session_id) when is_binary(session_id) and byte_size(session_id) > 0 do
    case Session.lookup(session_id) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")

      {:error, :not_found} ->
        {:error, {:session_not_found, session_id}}
    end
  end

  @doc """
  Unsubscribe the calling process from session events.
  """
  @spec unsubscribe(session_id()) :: :ok
  def unsubscribe(session_id) when is_binary(session_id) and byte_size(session_id) > 0 do
    Phoenix.PubSub.unsubscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")
  end

  # --- Capability Discovery ---

  @doc """
  List all BeamAgent capabilities.

  Delegates to `MonkeyClaw.AgentBridge.Capabilities.all/0`.
  """
  @spec capabilities() :: [Capabilities.capability_info(), ...]
  defdelegate capabilities(), to: Capabilities, as: :all

  @doc """
  List all supported BeamAgent backends.
  """
  @spec backends() :: [Capabilities.backend(), ...]
  defdelegate backends(), to: Capabilities
end
