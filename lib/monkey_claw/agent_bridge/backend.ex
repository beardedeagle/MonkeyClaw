defmodule MonkeyClaw.AgentBridge.Backend do
  @moduledoc """
  Behaviour defining the contract between the Session GenServer and the
  underlying agent runtime.

  MonkeyClaw never calls `BeamAgent` functions directly from the Session
  process. Instead, Session delegates all agent interactions through a
  backend adapter module that implements this behaviour.

  ## Implementations

    * `MonkeyClaw.AgentBridge.Backend.BeamAgent` — Production adapter
      wrapping the real BeamAgent runtime
    * `MonkeyClaw.AgentBridge.Backend.Test` — Test stub providing a
      real GenServer process for deterministic testing (test/support only)

  ## Why a Behaviour?

  The Session GenServer must interact with an external agent process
  (BeamAgent `gen_statem`). By defining a behaviour:

    * Tests use a real process stub — no mocks, no side effects
    * The adapter is injected via config, not global state
    * Each test can configure independent backend behaviour
    * Session tests can run `async: true`

  ## Configuration

  The backend module is passed in the session config map:

      %{
        id: "workspace-123",
        backend: MonkeyClaw.AgentBridge.Backend.BeamAgent,
        session_opts: %{backend: :claude, model: "opus"}
      }

  If `:backend` is omitted, `Session` defaults to
  `MonkeyClaw.AgentBridge.Backend.BeamAgent`.
  """

  @type session_pid :: pid()
  @type event_ref :: reference()
  @type message :: map()
  @type thread_info :: map()
  @type permission_mode :: :default | :accept_edits | :bypass_permissions | :plan | :dont_ask

  @doc """
  Start a new agent session.

  Returns `{:ok, pid}` where the pid is a monitorable BEAM process.
  The Session GenServer will call `Process.monitor/1` on this pid.
  """
  @callback start_session(opts :: map()) :: {:ok, session_pid()} | {:error, term()}

  @doc """
  Stop an agent session.

  Must be safe to call even if the session process has already exited.
  """
  @callback stop_session(session_pid()) :: :ok

  @doc """
  Send a synchronous query to the agent session.

  When `params` is an empty map, implementations may call the
  underlying 2-arity form if one exists.
  """
  @callback query(session_pid(), prompt :: String.t(), params :: map()) ::
              {:ok, [message()]} | {:error, term()}

  @doc """
  Retrieve session metadata.

  The returned map must include at least `:session_id` (binary).
  """
  @callback session_info(session_pid()) :: {:ok, map()} | {:error, term()}

  @doc """
  Subscribe the calling process to session events.

  Returns an opaque reference used with `receive_event/3`.
  """
  @callback event_subscribe(session_pid()) :: {:ok, event_ref()} | {:error, term()}

  @doc """
  Poll for a buffered event.

  Called with `timeout: 0` for non-blocking drain. Returns
  `{:error, :timeout}` when no events are buffered.
  """
  @callback receive_event(session_pid(), event_ref(), timeout :: non_neg_integer()) ::
              {:ok, message()} | {:error, term()}

  @doc """
  Return a lazy stream of response messages for a query.

  The returned `Enumerable.t()` yields `{:ok, message()}` tuples
  for each streaming chunk and `{:error, reason}` on failure.
  The stream halts naturally when the query completes.

  The caller is responsible for enumerating the stream — typically
  a spawned task within the Session GenServer.
  """
  @callback stream(session_pid(), prompt :: String.t(), params :: map()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Change the model used by the session at runtime.

  Sends a control message to the underlying agent session to switch
  models for all subsequent queries.
  """
  @callback set_model(session_pid(), model :: String.t()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Change the permission mode at runtime.

  Controls how the agent handles tool execution approvals:

    * `:default` — Prompt the user for approval
    * `:accept_edits` — Auto-approve file mutations
    * `:bypass_permissions` — Approve everything
    * `:plan` — Read-only mode
    * `:dont_ask` — Never prompt
  """
  @callback set_permission_mode(session_pid(), mode :: permission_mode()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Unsubscribe from session events and flush pending events.

  Called during session teardown to clean up the event subscription
  created by `event_subscribe/1`.
  """
  @callback event_unsubscribe(session_pid(), event_ref()) :: :ok | {:error, term()}

  @doc """
  Start a new conversation thread within the session.
  """
  @callback thread_start(session_pid(), opts :: map()) ::
              {:ok, thread_info()} | {:error, term()}

  @doc """
  Resume an existing thread, making it the active thread.
  """
  @callback thread_resume(session_pid(), thread_id :: String.t()) ::
              {:ok, thread_info()} | {:error, term()}

  @doc """
  List all threads within the session.
  """
  @callback thread_list(session_pid()) :: {:ok, [thread_info()]} | {:error, term()}
end
