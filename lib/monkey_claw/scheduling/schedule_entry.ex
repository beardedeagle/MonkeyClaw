defmodule MonkeyClaw.Scheduling.ScheduleEntry do
  @moduledoc """
  Ecto schema for schedule entry records.

  A schedule entry defines a timed task that creates experiment runs
  when its timer fires. Entries are workspace-scoped and managed by
  the `MonkeyClaw.Scheduling.Scheduler` GenServer.

  ## Schedule Types

    * `:once` — Fires a single time at `next_run_at`, then transitions
      to `:completed` status.
    * `:interval` — Fires every `interval_ms` milliseconds, starting
      at `next_run_at`. Optionally bounded by `max_runs`.

  ## Status Lifecycle

      active → paused
      active → completed
      active → failed
      paused → active
      paused → completed

  Terminal states: `:completed`, `:failed`.

  ## Experiment Config

  The `experiment_config` map contains the attributes passed to
  `MonkeyClaw.Experiments.create_experiment/2` when the schedule
  fires. Required keys: `"title"`, `"type"`, `"max_iterations"`.

  ## Associations

    * `belongs_to :workspace` — Required parent workspace. Entries
      are cascade-deleted when their workspace is deleted.

  ## Design

  This is NOT a process. Schedule entries are data entities persisted
  in SQLite3 via Ecto. The `MonkeyClaw.Scheduling.Scheduler` GenServer
  manages the OTP timers that fire these entries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          schedule_type: schedule_type() | nil,
          interval_ms: pos_integer() | nil,
          next_run_at: DateTime.t() | nil,
          experiment_config: map(),
          status: status() | nil,
          last_run_at: DateTime.t() | nil,
          run_count: non_neg_integer(),
          max_runs: pos_integer() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type schedule_type :: :once | :interval
  @type status :: :active | :paused | :completed | :failed
  @type terminal_status :: :completed | :failed

  @schedule_types [:once, :interval]
  @statuses [:active, :paused, :completed, :failed]
  @terminal_statuses [:completed, :failed]
  @valid_transitions %{
    active: [:paused, :completed, :failed],
    paused: [:active, :completed],
    completed: [],
    failed: []
  }

  @create_fields [
    :name,
    :description,
    :schedule_type,
    :interval_ms,
    :next_run_at,
    :experiment_config,
    :max_runs
  ]
  @update_fields [
    :name,
    :description,
    :interval_ms,
    :next_run_at,
    :experiment_config,
    :status,
    :last_run_at,
    :run_count,
    :max_runs
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "schedule_entries" do
    field :name, :string
    field :description, :string
    field :schedule_type, Ecto.Enum, values: @schedule_types
    field :interval_ms, :integer
    field :next_run_at, :utc_datetime_usec
    field :experiment_config, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :last_run_at, :utc_datetime_usec
    field :run_count, :integer, default: 0
    field :max_runs, :integer

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid schedule types.
  """
  @spec schedule_types() :: [schedule_type(), ...]
  def schedule_types, do: @schedule_types

  @doc """
  Returns the list of valid statuses.
  """
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @doc """
  Returns the list of terminal statuses.

  An entry in a terminal status cannot transition further.
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
  Changeset for creating a new schedule entry.

  The `:workspace_id` is set via `Ecto.build_assoc/3` in the
  context module. Required fields: `:name`, `:schedule_type`,
  `:next_run_at`.

  ## Examples

      workspace
      |> Ecto.build_assoc(:schedule_entries)
      |> ScheduleEntry.create_changeset(%{
        name: "Daily optimization",
        schedule_type: :interval,
        interval_ms: 86_400_000,
        next_run_at: DateTime.utc_now(),
        experiment_config: %{
          "title" => "Auto-optimize parser",
          "type" => "code",
          "max_iterations" => 3
        }
      })
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = entry, attrs) when is_map(attrs) do
    entry
    |> cast(attrs, @create_fields)
    |> validate_required([:name, :schedule_type, :next_run_at, :experiment_config])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:description, max: 1000)
    |> validate_inclusion(:schedule_type, @schedule_types)
    |> validate_interval_ms()
    |> validate_experiment_config()
    |> validate_max_runs()
    |> assoc_constraint(:workspace)
  end

  @doc """
  Changeset for updating an existing schedule entry.

  Validates status transitions and interval constraints.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = entry, attrs) when is_map(attrs) do
    entry
    |> cast(attrs, @update_fields)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:description, max: 1000)
    |> validate_interval_ms_for_update(entry.schedule_type)
    |> maybe_validate_experiment_config()
    |> validate_max_runs()
    |> validate_number(:run_count, greater_than_or_equal_to: 0)
    |> validate_status_transition(entry.status)
  end

  # Interval type requires interval_ms > 0.
  # Once type must not have interval_ms set.
  defp validate_interval_ms(changeset) do
    case get_field(changeset, :schedule_type) do
      :interval ->
        changeset
        |> validate_required([:interval_ms])
        |> validate_number(:interval_ms,
          greater_than: 0,
          less_than_or_equal_to: 604_800_000
        )

      :once ->
        case get_field(changeset, :interval_ms) do
          nil -> changeset
          _ -> add_error(changeset, :interval_ms, "must not be set for :once schedule type")
        end

      _ ->
        changeset
    end
  end

  # On update, validate interval_ms based on the entry's existing schedule_type.
  defp validate_interval_ms_for_update(changeset, schedule_type) do
    case fetch_change(changeset, :interval_ms) do
      {:ok, _} ->
        case schedule_type do
          :interval ->
            validate_number(changeset, :interval_ms,
              greater_than: 0,
              less_than_or_equal_to: 604_800_000
            )

          :once ->
            add_error(changeset, :interval_ms, "cannot set interval_ms on :once schedule type")
        end

      :error ->
        changeset
    end
  end

  # Only validate experiment_config on update when the field is actually
  # being changed. This avoids re-validating the existing config on
  # unrelated updates like record_run (run_count, last_run_at, status).
  defp maybe_validate_experiment_config(changeset) do
    case fetch_change(changeset, :experiment_config) do
      {:ok, _} -> validate_experiment_config(changeset)
      :error -> changeset
    end
  end

  # Validate experiment_config has required keys when set.
  # Normalizes atom keys to strings for consistent JSON storage.
  defp validate_experiment_config(changeset) do
    case get_field(changeset, :experiment_config) do
      config when is_map(config) and map_size(config) > 0 ->
        config = stringify_keys(config)
        changeset = put_change(changeset, :experiment_config, config)
        required_keys = ["title", "type", "max_iterations"]
        missing = Enum.reject(required_keys, &Map.has_key?(config, &1))

        if missing == [] do
          changeset
        else
          add_error(changeset, :experiment_config, "missing required keys: %{keys}",
            keys: Enum.join(missing, ", ")
          )
        end

      _ ->
        add_error(changeset, :experiment_config, "must be a non-empty map")
    end
  end

  # max_runs must be positive if set.
  defp validate_max_runs(changeset) do
    validate_number(changeset, :max_runs, greater_than: 0)
  end

  # Normalize map keys to strings for consistent JSON storage.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # Status transitions must follow the defined state machine.
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
