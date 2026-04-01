defmodule MonkeyClaw.Experiments.Iteration do
  @moduledoc """
  Ecto schema for experiment iteration records.

  Each iteration represents one cycle of the experiment loop:
  prepare → build prompt → execute → evaluate → decide.

  Iterations are immutable records — once created, they are never
  updated. The schema enforces this by omitting `updated_at` from
  timestamps. Status is set once at creation time based on the
  outcome of the iteration.

  ## Associations

    * `belongs_to :experiment` — Required parent experiment. Iterations
      are cascade-deleted when their experiment is deleted.

  ## Status

  Each iteration has a status reflecting its outcome:

    * `:running` — Iteration is in progress (async task executing)
    * `:evaluating` — Agent completed, evaluation in progress
    * `:accepted` — Strategy accepted this iteration's result
    * `:rejected` — Strategy rejected this iteration's result
    * `:failed` — Iteration failed (task crash, timeout, etc.)

  ## Ordering

  Iterations are ordered by their `:sequence` field, which is a
  monotonically increasing integer (1-based) within each experiment.

  ## Design

  This is NOT a process. Iterations are data entities persisted in
  SQLite3 via Ecto. The `MonkeyClaw.Experiments.Runner` GenServer
  records these after each iteration completes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Experiments.Experiment

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          sequence: pos_integer() | nil,
          status: status() | nil,
          run_ref: String.t() | nil,
          eval_result: map(),
          state_snapshot: map(),
          duration_ms: non_neg_integer() | nil,
          metadata: map(),
          experiment_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @type status :: :running | :evaluating | :accepted | :rejected | :failed

  @statuses [:running, :evaluating, :accepted, :rejected, :failed]

  @create_fields [
    :sequence,
    :status,
    :run_ref,
    :eval_result,
    :state_snapshot,
    :duration_ms,
    :metadata
  ]

  @doc """
  Returns the list of valid iteration statuses.
  """
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "experiment_iterations" do
    field :sequence, :integer
    field :status, Ecto.Enum, values: @statuses
    field :run_ref, :string
    field :eval_result, :map, default: %{}
    field :state_snapshot, :map, default: %{}
    field :duration_ms, :integer
    field :metadata, :map, default: %{}

    belongs_to :experiment, Experiment

    # Iterations are immutable — no updated_at needed.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Changeset for creating a new iteration record.

  The `:experiment_id` is set via `Ecto.build_assoc/3` in the
  context module. Required fields: `:sequence` and `:status`.

  ## Examples

      experiment
      |> Ecto.build_assoc(:iterations)
      |> Iteration.create_changeset(%{
        sequence: 1,
        status: :accepted,
        eval_result: %{score: 0.85},
        duration_ms: 3200
      })
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = iteration, attrs) when is_map(attrs) do
    iteration
    |> cast(attrs, @create_fields)
    |> validate_required([:sequence, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> normalize_map_fields()
    |> assoc_constraint(:experiment)
    |> unique_constraint([:experiment_id, :sequence],
      name: :experiment_iterations_experiment_id_sequence_index
    )
  end

  # Normalize nil map fields to %{} so DB NOT NULL constraints
  # are never violated. Handles both explicit nil changes and
  # unchanged nil defaults (cast won't register nil → nil as a change).
  defp normalize_map_fields(changeset) do
    Enum.reduce([:eval_result, :state_snapshot, :metadata], changeset, fn field, cs ->
      case fetch_change(cs, field) do
        {:ok, nil} -> put_change(cs, field, %{})
        {:ok, _} -> cs
        :error -> if get_field(cs, field) == nil, do: put_change(cs, field, %{}), else: cs
      end
    end)
  end
end
