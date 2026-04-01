defmodule MonkeyClaw.Experiments.Supervisor do
  @moduledoc """
  DynamicSupervisor for `MonkeyClaw.Experiments.Runner` processes.

  Each supervised child is a Runner GenServer driving one experiment's
  iteration loop. Runners use `:temporary` restart strategy — failed
  experiments require explicit re-creation with valid configuration
  rather than automatic restart.

  ## Supervision Design

  This supervisor is part of the MonkeyClaw application tree:

      MonkeyClaw.Supervisor
      ├── ...
      ├── {Registry, name: MonkeyClaw.Experiments.RunnerRegistry}
      ├── {Task.Supervisor, name: MonkeyClaw.Experiments.TaskSupervisor}
      ├── MonkeyClaw.Experiments.Supervisor  ← this module
      └── MonkeyClawWeb.Endpoint

  The RunnerRegistry and TaskSupervisor must start before this
  supervisor, since Runner processes register themselves and use
  the TaskSupervisor for async agent queries.
  """

  use DynamicSupervisor

  alias MonkeyClaw.Experiments.Runner

  # Maximum concurrent experiments per node (single-user model,
  # but experiments are resource-intensive).
  @max_experiments 5

  @doc "Start the experiment supervisor as a linked process."
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Start a new supervised Runner process for an experiment.

  The Runner will be registered in `MonkeyClaw.Experiments.RunnerRegistry`
  under the experiment ID.

  ## Config

  See `MonkeyClaw.Experiments.Runner.start_link/1` for required
  and optional config keys.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_runner(Runner.config()) ::
          DynamicSupervisor.on_start_child() | {:error, :experiment_limit_reached}
  def start_runner(config) when is_map(config) do
    case count_experiments() do
      count when count >= @max_experiments ->
        {:error, :experiment_limit_reached}

      _count ->
        DynamicSupervisor.start_child(__MODULE__, {Runner, config})
    end
  end

  @doc """
  Terminate a supervised Runner process.

  The experiment is stopped and removed from supervision.
  """
  @spec stop_runner(pid()) :: :ok | {:error, :not_found}
  def stop_runner(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Count the number of active supervised experiments.
  """
  @spec count_experiments() :: non_neg_integer()
  def count_experiments do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
