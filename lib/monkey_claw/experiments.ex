defmodule MonkeyClaw.Experiments do
  @moduledoc """
  Context module for experiments and experiment iterations.

  Provides CRUD operations for experiments and their iterations.
  This is the public API for all experiment persistence operations
  in MonkeyClaw.

  ## What Is an Experiment

  An experiment is a time-bounded, iterative process where an agent
  starts from a known state, applies a constrained mutation, evaluates
  the result, and decides what to do next. "A Task is work. An
  Experiment is a bet."

  ## Related Modules

    * `MonkeyClaw.Experiments.Experiment` — Experiment Ecto schema
    * `MonkeyClaw.Experiments.Iteration` — Iteration Ecto schema
    * `MonkeyClaw.Experiments.Strategy` — Strategy behaviour
    * `MonkeyClaw.Experiments.Runner` — Runner GenServer
    * `MonkeyClaw.Workspaces` — Workspace context (parent entity)

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3). All functions are pure
  (database I/O aside) and safe for concurrent use.
  """

  require Logger

  import Ecto.Query

  alias MonkeyClaw.Experiments.{Experiment, Iteration}
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Workspaces.Workspace

  # ──────────────────────────────────────────────
  # Experiment CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a new experiment within a workspace.

  The workspace association is set automatically via `Ecto.build_assoc/3`.

  ## Examples

      {:ok, experiment} = Experiments.create_experiment(workspace, %{
        title: "Optimize parser",
        type: :code,
        max_iterations: 5,
        config: %{"scoped_files" => ["lib/parser.ex"]}
      })
  """
  @spec create_experiment(Workspace.t(), map()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def create_experiment(%Workspace{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> Ecto.build_assoc(:experiments)
    |> Experiment.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get an experiment by ID.

  Returns `{:ok, experiment}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_experiment(Ecto.UUID.t()) :: {:ok, Experiment.t()} | {:error, :not_found}
  def get_experiment(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(Experiment, id) do
      nil -> {:error, :not_found}
      experiment -> {:ok, experiment}
    end
  end

  @doc """
  Get an experiment by ID, raising on not found.
  """
  @spec get_experiment!(Ecto.UUID.t()) :: Experiment.t()
  def get_experiment!(id) when is_binary(id) and byte_size(id) > 0 do
    Repo.get!(Experiment, id)
  end

  @doc """
  List experiments for a workspace, most recent first.
  """
  @spec list_experiments(Workspace.t() | Ecto.UUID.t()) :: [Experiment.t()]
  def list_experiments(%Workspace{id: workspace_id}), do: list_experiments(workspace_id)

  def list_experiments(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    list_experiments(workspace_id, %{})
  end

  @doc """
  List experiments for a workspace with filtering options.

  ## Options

    * `:limit` — Maximum number of experiments to return
    * `:status` — Filter by experiment status
    * `:type` — Filter by experiment type
  """
  @spec list_experiments(Ecto.UUID.t(), map()) :: [Experiment.t()]
  def list_experiments(workspace_id, opts)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and is_map(opts) do
    Experiment
    |> where([e], e.workspace_id == ^workspace_id)
    |> apply_status_filter(opts)
    |> apply_type_filter(opts)
    |> order_by([e], desc: e.inserted_at)
    |> apply_limit(opts)
    |> Repo.all()
  end

  @doc """
  Update an existing experiment.

  Used by the Runner to persist state transitions, strategy state,
  and completion metadata.
  """
  @spec update_experiment(Experiment.t(), map()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def update_experiment(%Experiment{} = experiment, attrs) when is_map(attrs) do
    experiment
    |> Experiment.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete an experiment and all its iterations.

  Iterations are cascade-deleted by the database foreign key
  constraint.
  """
  @spec delete_experiment(Experiment.t()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t()}
  def delete_experiment(%Experiment{} = experiment) do
    Repo.delete(experiment)
  end

  # ──────────────────────────────────────────────
  # Iteration Operations
  # ──────────────────────────────────────────────

  @doc """
  Record a new iteration within an experiment.

  Iterations are immutable records — once created, they are never
  updated. The sequence number is provided by the Runner (1-based,
  monotonically increasing).

  ## Examples

      {:ok, iteration} = Experiments.record_iteration(experiment, %{
        sequence: 1,
        status: :accepted,
        eval_result: %{score: 0.85},
        state_snapshot: strategy_state,
        duration_ms: 3200
      })
  """
  @spec record_iteration(Experiment.t(), map()) ::
          {:ok, Iteration.t()} | {:error, Ecto.Changeset.t()}
  def record_iteration(%Experiment{} = experiment, attrs) when is_map(attrs) do
    experiment
    |> Ecto.build_assoc(:iterations)
    |> Iteration.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get all iterations for an experiment, ordered by sequence.
  """
  @spec get_iterations(Ecto.UUID.t()) :: [Iteration.t()]
  def get_iterations(experiment_id)
      when is_binary(experiment_id) and byte_size(experiment_id) > 0 do
    Iteration
    |> where([i], i.experiment_id == ^experiment_id)
    |> order_by([i], asc: i.sequence)
    |> Repo.all()
  end

  @doc """
  Get a specific iteration by experiment ID and sequence number.
  """
  @spec get_iteration(Ecto.UUID.t(), pos_integer()) ::
          {:ok, Iteration.t()} | {:error, :not_found}
  def get_iteration(experiment_id, sequence)
      when is_binary(experiment_id) and is_integer(sequence) and sequence > 0 do
    case Repo.one(
           from i in Iteration,
             where: i.experiment_id == ^experiment_id and i.sequence == ^sequence
         ) do
      nil -> {:error, :not_found}
      iteration -> {:ok, iteration}
    end
  end

  @doc """
  Count iterations for an experiment.
  """
  @spec count_iterations(Ecto.UUID.t()) :: non_neg_integer()
  def count_iterations(experiment_id)
      when is_binary(experiment_id) and byte_size(experiment_id) > 0 do
    Iteration
    |> where([i], i.experiment_id == ^experiment_id)
    |> Repo.aggregate(:count, :id)
  end

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  defp apply_status_filter(query, %{status: status}) when is_atom(status) do
    where(query, [e], e.status == ^status)
  end

  defp apply_status_filter(query, _opts), do: query

  defp apply_type_filter(query, %{type: type}) when is_atom(type) do
    where(query, [e], e.type == ^type)
  end

  defp apply_type_filter(query, _opts), do: query

  defp apply_limit(query, %{limit: limit}) when is_integer(limit) and limit > 0 do
    limit(query, ^limit)
  end

  defp apply_limit(query, _opts), do: query
end
