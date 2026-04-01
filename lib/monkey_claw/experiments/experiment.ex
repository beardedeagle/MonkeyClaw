defmodule MonkeyClaw.Experiments.Experiment do
  @moduledoc """
  Ecto schema for experiment records.

  An experiment is a time-bounded, iterative process where the agent
  starts from a known state, applies a constrained mutation, evaluates
  the result, and decides what to do next. If any of these steps are
  missing, it's not an experiment — it's just a task.

  **"A Task is work. An Experiment is a bet."**

  ## Associations

    * `belongs_to :workspace` — Required parent workspace. Experiments
      are cascade-deleted when their workspace is deleted.

    * `has_many :iterations` — Ordered iteration records for this
      experiment. Iterations are cascade-deleted when the experiment
      is deleted.

  ## Status Lifecycle

  Experiments follow a state-machine lifecycle:

      created → running → evaluating → awaiting_human →
        accepted | rejected | cancelled | halted

  Terminal states: `:accepted`, `:rejected`, `:cancelled`, `:halted`.

  ## Types

  Each experiment type uses a different strategy implementation:

    * `:code` — File checkpoint refs + metrics (optimization)
    * `:research` — Memory graph + gathered knowledge
    * `:prompt` — Prompt versions + response outputs

  ## State Versioning

  Two version indicators with distinct responsibilities:

    * `state_version` (schema field) — Persisted schema version for
      migration routing when loading old experiments.
    * `__v__` (key inside `:state` map) — Strategy-local compatibility
      marker for internal format changes.

  ## Termination Reasons

  When an experiment reaches a terminal state, `termination_reason`
  records why:

    * `"timeout"` — Time budget expired
    * `"user_cancel"` — User explicitly cancelled
    * `"crash"` — Agent session crashed
    * `"graceful_stop"` — User requested graceful stop (finish
      current iteration, then accept/halt based on final result)
    * `"max_iterations_reached"` — Hit the iteration limit
    * `"init_failed"` — Strategy initialization failed at startup
    * `"iteration_prep_failed"` — Iteration preparation failed
      (strategy.prepare_iteration or strategy.build_prompt errored)
    * `"query_failed"` — Agent query returned an error
    * `"mutation_scope_violation"` — Agent modified files outside allowed scope
    * `"strategy_crashed"` — Strategy callback crashed during evaluate/decide
    * `nil` — Normal completion (accepted/rejected by strategy)

  ## Design

  This is NOT a process. Experiments are data entities persisted in
  SQLite3 via Ecto. The `MonkeyClaw.Experiments.Runner` GenServer
  creates and updates these records as the experiment progresses.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Experiments.Iteration
  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          type: experiment_type() | nil,
          status: status() | nil,
          config: map(),
          state: map() | nil,
          state_version: pos_integer(),
          result: map() | nil,
          iteration_count: non_neg_integer(),
          max_iterations: pos_integer() | nil,
          time_budget_ms: pos_integer() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          termination_reason: String.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type experiment_type :: :code | :research | :prompt
  @type status ::
          :created
          | :running
          | :evaluating
          | :awaiting_human
          | :accepted
          | :rejected
          | :cancelled
          | :halted
  @type terminal_status :: :accepted | :rejected | :cancelled | :halted

  @experiment_types [:code, :research, :prompt]
  @statuses [
    :created,
    :running,
    :evaluating,
    :awaiting_human,
    :accepted,
    :rejected,
    :cancelled,
    :halted
  ]
  @terminal_statuses [:accepted, :rejected, :cancelled, :halted]
  @valid_transitions %{
    created: [:running, :cancelled],
    running: [:evaluating, :cancelled, :halted, :accepted, :rejected],
    evaluating: [:awaiting_human, :running, :accepted, :rejected, :halted, :cancelled],
    awaiting_human: [:running, :accepted, :rejected, :halted, :cancelled],
    accepted: [],
    rejected: [],
    cancelled: [],
    halted: []
  }
  @valid_termination_reasons [
    "timeout",
    "user_cancel",
    "crash",
    "graceful_stop",
    "max_iterations_reached",
    "init_failed",
    "iteration_prep_failed",
    "query_failed",
    "mutation_scope_violation",
    "strategy_crashed"
  ]

  @create_fields [:title, :type, :config, :max_iterations, :time_budget_ms]
  @update_fields [
    :title,
    :status,
    :config,
    :state,
    :state_version,
    :result,
    :iteration_count,
    :max_iterations,
    :time_budget_ms,
    :started_at,
    :completed_at,
    :termination_reason
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "experiments" do
    field :title, :string
    field :type, Ecto.Enum, values: @experiment_types
    field :status, Ecto.Enum, values: @statuses, default: :created
    field :config, :map, default: %{}
    field :state, :map
    field :state_version, :integer, default: 1
    field :result, :map
    field :iteration_count, :integer, default: 0
    field :max_iterations, :integer
    field :time_budget_ms, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :termination_reason, :string

    belongs_to :workspace, Workspace
    has_many :iterations, Iteration

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid experiment types.
  """
  @spec experiment_types() :: [experiment_type(), ...]
  def experiment_types, do: @experiment_types

  @doc """
  Returns the list of valid experiment statuses.
  """
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @doc """
  Returns the list of terminal statuses.

  An experiment in a terminal status cannot transition further.
  """
  @spec terminal_statuses() :: [terminal_status(), ...]
  def terminal_statuses, do: @terminal_statuses

  @doc """
  Returns true if the given status is terminal.
  """
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when status in @terminal_statuses, do: true
  def terminal?(_status), do: false

  @doc """
  Changeset for creating a new experiment.

  The `:workspace_id` is set via `Ecto.build_assoc/3` in the
  context module. Required fields: `:title`, `:type`, `:max_iterations`.

  ## Examples

      workspace
      |> Ecto.build_assoc(:experiments)
      |> Experiment.create_changeset(%{
        title: "Optimize parser",
        type: :code,
        max_iterations: 5,
        config: %{scoped_files: ["lib/parser.ex"]}
      })
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = experiment, attrs) when is_map(attrs) do
    experiment
    |> cast(attrs, @create_fields)
    |> validate_required([:title, :type, :max_iterations])
    |> validate_length(:title, max: 200)
    |> validate_inclusion(:type, @experiment_types)
    |> validate_number(:max_iterations, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_time_budget()
    |> assoc_constraint(:workspace)
  end

  @doc """
  Changeset for updating an existing experiment.

  Used by the Runner to persist state transitions, strategy state,
  and completion metadata. Validates status transitions and
  termination reason consistency.

  ## Examples

      experiment
      |> Experiment.update_changeset(%{
        status: :running,
        started_at: DateTime.utc_now()
      })
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = experiment, attrs) when is_map(attrs) do
    experiment
    |> cast(attrs, @update_fields)
    |> validate_length(:title, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:max_iterations, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:iteration_count, greater_than_or_equal_to: 0)
    |> validate_number(:state_version, greater_than: 0)
    |> validate_time_budget()
    |> validate_termination_reason()
    |> validate_status_transition(experiment.status)
  end

  # Time budget must be positive if set.
  defp validate_time_budget(changeset) do
    validate_number(changeset, :time_budget_ms,
      greater_than: 0,
      less_than_or_equal_to: 86_400_000
    )
  end

  # Termination reason must be from the known set if present.
  defp validate_termination_reason(changeset) do
    validate_inclusion(changeset, :termination_reason, @valid_termination_reasons ++ [nil])
  end

  # Status transition must follow the defined state machine.
  defp validate_status_transition(changeset, current_status) do
    case fetch_change(changeset, :status) do
      {:ok, new_status} ->
        allowed = Map.get(@valid_transitions, current_status, [])

        if new_status in allowed do
          changeset
        else
          add_error(changeset, :status, "invalid transition from %{from} to %{to}",
            from: current_status,
            to: new_status
          )
        end

      :error ->
        changeset
    end
  end
end
