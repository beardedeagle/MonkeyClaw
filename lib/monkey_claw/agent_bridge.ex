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

      # Start a session (returns subscribe token for event authorization)
      {:ok, result} = MonkeyClaw.AgentBridge.start_session(%{
        id: "workspace-123",
        session_opts: %{backend: :claude, model: "opus"}
      })

      # Subscribe to events (requires the token from start_session)
      :ok = MonkeyClaw.AgentBridge.subscribe(result.id, result.subscribe_token)

      # Send a query
      {:ok, messages} = MonkeyClaw.AgentBridge.query("workspace-123", "Hello!")

      # Or stream a query (chunks delivered as messages)
      {:ok, :streaming} = MonkeyClaw.AgentBridge.stream_query("workspace-123", "Hello!")

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
  alias MonkeyClaw.AgentBridge.Telemetry, as: BridgeTelemetry

  @type session_id :: Session.session_id()

  @type session_result :: %{
          pid: pid(),
          id: session_id(),
          subscribe_token: binary()
        }

  # Subscribe token size in bytes (256-bit entropy)
  @subscribe_token_size 32

  # --- Session Lifecycle ---

  @doc """
  Start a new supervised agent session.

  The `config` map must include:

    * `:id` — Unique session identifier (typically a workspace ID)
    * `:session_opts` — Map of options for `BeamAgent.start_session/1`

  Returns `{:ok, session_result()}` on success, where `session_result()`
  includes the `pid`, `id`, and a cryptographic `subscribe_token` required
  for subscribing to session events via `subscribe/2`.

  ## Examples

      {:ok, result} = MonkeyClaw.AgentBridge.start_session(%{
        id: "workspace-123",
        session_opts: %{backend: :claude}
      })

      # Use the token to subscribe to events
      :ok = MonkeyClaw.AgentBridge.subscribe(result.id, result.subscribe_token)
  """
  @spec start_session(Session.config()) :: {:ok, session_result()} | {:error, term()}
  def start_session(%{id: id, session_opts: _opts} = config) do
    subscribe_token = :crypto.strong_rand_bytes(@subscribe_token_size)
    token_hash = :crypto.hash(:sha256, subscribe_token)
    config_with_token = Map.put(config, :subscribe_token, token_hash)

    case SessionSupervisor.start_session(config_with_token) do
      {:ok, pid} ->
        {:ok, %{pid: pid, id: id, subscribe_token: subscribe_token}}

      {:error, _} = error ->
        error
    end
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

  @doc """
  Start a streaming query on a session.

  Spawns a background task that enumerates the response stream.
  Chunks are delivered to the calling process as messages:

    * `{:stream_chunk, session_id, chunk}` — A response fragment
    * `{:stream_done, session_id}` — Stream completed successfully
    * `{:stream_error, session_id, reason}` — Stream failed

  Only one stream may be active per session. Returns
  `{:error, :stream_already_active}` if a stream is in progress.

  ## Options

    * `:timeout` — Timeout for stream initiation (default: 30_000ms)
    * `:stream_to` — PID to receive stream messages (default: `self()`)
  """
  @spec stream_query(session_id(), String.t(), keyword()) ::
          {:ok, :streaming} | {:error, term()}
  def stream_query(session_id, prompt, opts \\ [])
      when is_binary(session_id) and byte_size(session_id) > 0 and
             is_binary(prompt) and byte_size(prompt) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.stream_query(pid, prompt, opts)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  @doc """
  Cancel the active stream on a session, if any.

  Sends an asynchronous signal to kill the stream task and free the
  session for new queries. Safe to call when no stream is active.
  """
  @spec cancel_stream(session_id()) :: :ok | {:error, {:session_not_found, session_id()}}
  def cancel_stream(session_id)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.cancel_stream(pid)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  @doc """
  Change the model used by a session at runtime.

  Looks up the session by ID and sends a control message to the
  underlying agent to switch models. If the session doesn't exist
  (e.g. no messages sent yet), returns `{:error, {:session_not_found, id}}`.
  """
  @spec set_model(session_id(), String.t()) :: {:ok, term()} | {:error, term()}
  def set_model(session_id, model)
      when is_binary(session_id) and byte_size(session_id) > 0 and
             is_binary(model) and byte_size(model) > 0 do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.set_model(pid, model)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  @valid_permission_modes [:default, :accept_edits, :bypass_permissions, :plan, :dont_ask]

  @doc """
  Change the permission mode used by a session at runtime.

  Controls how the agent handles tool execution approvals.
  Valid modes: #{Enum.map_join(@valid_permission_modes, ", ", &"`#{inspect(&1)}`")}.

  Returns `{:error, :invalid_permission_mode}` for unrecognised modes.
  """
  @spec set_permission_mode(session_id(), atom()) :: {:ok, term()} | {:error, term()}
  def set_permission_mode(session_id, mode)
      when is_binary(session_id) and byte_size(session_id) > 0 and
             mode in @valid_permission_modes do
    case Session.lookup(session_id) do
      {:ok, pid} -> Session.set_permission_mode(pid, mode)
      {:error, :not_found} -> {:error, {:session_not_found, session_id}}
    end
  end

  def set_permission_mode(_session_id, _mode) do
    {:error, :invalid_permission_mode}
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

  Requires the `subscribe_token` returned by `start_session/1`.
  The token is verified against the value stored in the session
  Registry using constant-time comparison. This provides
  defense-in-depth within the BEAM — even though mTLS secures
  the transport layer, only processes holding the subscribe token
  can receive session events.

  ## Security

  Three layers of access control protect session events:

    1. **mTLS** — Unauthenticated connections are rejected during
       the TLS handshake before any application code executes
    2. **Token verification** — The subscribe token is generated
       during session creation and must be presented to subscribe.
       Verified via constant-time comparison to prevent timing attacks.
    3. **PubSub isolation** — Each session broadcasts on its own
       topic; subscribers only receive events for their session

  ## Events

  Events are delivered as messages to the subscriber:

    * `{:session_started, id}`
    * `{:session_stopped, id, reason}`
    * `{:session_terminated, id, reason}`
    * `{:beam_agent_event, id, event}`
    * `{:stream_chunk, id, chunk}`
    * `{:stream_done, id}`
    * `{:stream_error, id, reason}`
  """
  @spec subscribe(session_id(), binary()) ::
          :ok
          | {:error,
             {:session_not_found, session_id()} | :unauthorized | {:already_registered, pid()}}
  def subscribe(session_id, subscribe_token)
      when is_binary(session_id) and byte_size(session_id) > 0 and
             is_binary(subscribe_token) and byte_size(subscribe_token) == @subscribe_token_size do
    case Session.lookup_with_token_hash(session_id) do
      {:ok, _pid, stored_hash} when is_binary(stored_hash) ->
        presented_hash = :crypto.hash(:sha256, subscribe_token)

        if Plug.Crypto.secure_compare(stored_hash, presented_hash) do
          BridgeTelemetry.subscribe_success(%{session_id: session_id})
          Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")
        else
          BridgeTelemetry.subscribe_unauthorized(%{session_id: session_id})
          {:error, :unauthorized}
        end

      {:ok, _pid, _no_token} ->
        # Session exists but has no token — reject for defense in depth
        BridgeTelemetry.subscribe_unauthorized(%{session_id: session_id})
        {:error, :unauthorized}

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
