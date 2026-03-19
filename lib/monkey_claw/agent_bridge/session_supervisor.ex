defmodule MonkeyClaw.AgentBridge.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for `MonkeyClaw.AgentBridge.Session` processes.

  Each supervised child is a Session GenServer wrapping a live
  BeamAgent session. Sessions use `:temporary` restart strategy —
  failed sessions require explicit re-creation with valid
  configuration rather than automatic restart.

  ## Supervision Design

  This supervisor is part of the MonkeyClaw application tree:

      MonkeyClaw.Supervisor
      ├── ...
      ├── {Registry, name: MonkeyClaw.AgentBridge.SessionRegistry}
      ├── MonkeyClaw.AgentBridge.SessionSupervisor  ← this module
      └── MonkeyClawWeb.Endpoint
  """

  use DynamicSupervisor

  alias MonkeyClaw.AgentBridge.Session

  # Maximum concurrent sessions per node (single-user model)
  @max_sessions 10

  @doc "Start the session supervisor as a linked process."
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Start a new supervised Session process.

  The session will be registered in `MonkeyClaw.AgentBridge.SessionRegistry`
  under the provided `:id` in the config.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_session(Session.config()) ::
          DynamicSupervisor.on_start_child() | {:error, :session_limit_reached}
  def start_session(config) when is_map(config) do
    case count_sessions() do
      count when count >= @max_sessions ->
        {:error, :session_limit_reached}

      _count ->
        child_spec = {Session, config}
        DynamicSupervisor.start_child(__MODULE__, child_spec)
    end
  end

  @doc """
  Terminate a supervised Session process.

  The session is stopped and removed from supervision.
  """
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Count the number of active supervised sessions.
  """
  @spec count_sessions() :: non_neg_integer()
  def count_sessions do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
