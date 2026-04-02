defmodule MonkeyClaw.Scheduling do
  @moduledoc """
  Context module for schedule entry management.

  Provides CRUD operations, status transitions, run tracking, and
  due-entry queries for autonomous scheduling of experiment runs.
  Schedule entries are workspace-scoped and define timed tasks that
  create experiments when their timer fires.

  ## Related Modules

    * `MonkeyClaw.Scheduling.ScheduleEntry` — Schedule entry Ecto schema
    * `MonkeyClaw.Scheduling.Scheduler` — GenServer polling for due entries

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3). All functions are pure
  (database I/O aside) and safe for concurrent use.
  """

  import Ecto.Query

  alias MonkeyClaw.Repo
  alias MonkeyClaw.Scheduling.ScheduleEntry
  alias MonkeyClaw.Workspaces.Workspace

  # ──────────────────────────────────────────────
  # Schedule Entry CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a new schedule entry within a workspace.

  The workspace association is set automatically via `Ecto.build_assoc/3`.

  ## Examples

      {:ok, entry} = Scheduling.create_schedule_entry(workspace, %{
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
  @spec create_schedule_entry(Workspace.t(), map()) ::
          {:ok, ScheduleEntry.t()} | {:error, Ecto.Changeset.t()}
  def create_schedule_entry(%Workspace{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> Ecto.build_assoc(:schedule_entries)
    |> ScheduleEntry.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a schedule entry by ID.

  Returns `{:ok, entry}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_schedule_entry(Ecto.UUID.t()) :: {:ok, ScheduleEntry.t()} | {:error, :not_found}
  def get_schedule_entry(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(ScheduleEntry, id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Get a schedule entry by ID, raising on not found.
  """
  @spec get_schedule_entry!(Ecto.UUID.t()) :: ScheduleEntry.t()
  def get_schedule_entry!(id) when is_binary(id) and byte_size(id) > 0 do
    Repo.get!(ScheduleEntry, id)
  end

  @doc """
  List schedule entries for a workspace, ordered by next_run_at ascending.
  """
  @spec list_schedule_entries(Ecto.UUID.t()) :: [ScheduleEntry.t()]
  def list_schedule_entries(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    list_schedule_entries(workspace_id, %{})
  end

  @doc """
  List schedule entries for a workspace with optional filtering.

  ## Options

    * `:status` — Filter by status (e.g., `:active`, `:paused`)
  """
  @spec list_schedule_entries(Ecto.UUID.t(), map()) :: [ScheduleEntry.t()]
  def list_schedule_entries(workspace_id, filters)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and is_map(filters) do
    ScheduleEntry
    |> where([e], e.workspace_id == ^workspace_id)
    |> apply_status_filter(filters)
    |> order_by([e], asc: e.next_run_at)
    |> Repo.all()
  end

  @doc """
  Update an existing schedule entry.
  """
  @spec update_schedule_entry(ScheduleEntry.t(), map()) ::
          {:ok, ScheduleEntry.t()} | {:error, Ecto.Changeset.t()}
  def update_schedule_entry(%ScheduleEntry{} = entry, attrs) when is_map(attrs) do
    entry
    |> ScheduleEntry.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a schedule entry.
  """
  @spec delete_schedule_entry(ScheduleEntry.t()) ::
          {:ok, ScheduleEntry.t()} | {:error, Ecto.Changeset.t()}
  def delete_schedule_entry(%ScheduleEntry{} = entry) do
    Repo.delete(entry)
  end

  # ──────────────────────────────────────────────
  # Status Transitions
  # ──────────────────────────────────────────────

  @doc """
  Pause an active schedule entry.

  Transitions the entry status from `:active` to `:paused`.
  Returns `{:error, changeset}` if the transition is invalid.

  ## Examples

      {:ok, paused} = Scheduling.pause_entry(active_entry)
  """
  @spec pause_entry(ScheduleEntry.t()) ::
          {:ok, ScheduleEntry.t()} | {:error, Ecto.Changeset.t()}
  def pause_entry(%ScheduleEntry{} = entry) do
    update_schedule_entry(entry, %{status: :paused})
  end

  @doc """
  Activate a paused schedule entry.

  Transitions the entry status from `:paused` to `:active`.
  Returns `{:error, changeset}` if the transition is invalid.

  ## Examples

      {:ok, active} = Scheduling.activate_entry(paused_entry)
  """
  @spec activate_entry(ScheduleEntry.t()) ::
          {:ok, ScheduleEntry.t()} | {:error, Ecto.Changeset.t()}
  def activate_entry(%ScheduleEntry{} = entry) do
    update_schedule_entry(entry, %{status: :active})
  end

  # ──────────────────────────────────────────────
  # Run Tracking
  # ──────────────────────────────────────────────

  @doc """
  Record a completed run for a schedule entry.

  Increments `run_count`, sets `last_run_at` to the current UTC time.
  For `:once` entries, transitions status to `:completed`. For `:interval`
  entries, computes `next_run_at` as `now + interval_ms`. If `max_runs`
  is set and `run_count` reaches the limit, transitions to `:completed`.

  ## Examples

      {:ok, updated} = Scheduling.record_run(entry)
  """
  @spec record_run(ScheduleEntry.t()) ::
          {:ok, ScheduleEntry.t()} | {:error, Ecto.Changeset.t()}
  def record_run(%ScheduleEntry{} = entry) do
    now = DateTime.utc_now()
    new_run_count = entry.run_count + 1

    attrs = %{
      run_count: new_run_count,
      last_run_at: now
    }

    attrs = compute_post_run_attrs(entry, attrs, now, new_run_count)

    update_schedule_entry(entry, attrs)
  end

  # ──────────────────────────────────────────────
  # Queries
  # ──────────────────────────────────────────────

  @doc """
  Query schedule entries that are due for execution.

  Returns entries where status is `:active` and `next_run_at` is at
  or before the current UTC time, ordered by `next_run_at` ascending.

  ## Examples

      due = Scheduling.due_entries()
  """
  @spec due_entries() :: [ScheduleEntry.t()]
  def due_entries do
    now = DateTime.utc_now()

    ScheduleEntry
    |> where([e], e.status == :active)
    |> where([e], e.next_run_at <= ^now)
    |> order_by([e], asc: e.next_run_at)
    |> Repo.all()
  end

  # ──────────────────────────────────────────────
  # Private — Filters
  # ──────────────────────────────────────────────

  defp apply_status_filter(query, %{status: status}) when is_atom(status) do
    where(query, [e], e.status == ^status)
  end

  defp apply_status_filter(query, _filters), do: query

  # ──────────────────────────────────────────────
  # Private — Run Computation
  # ──────────────────────────────────────────────

  # :once entries complete immediately after firing.
  defp compute_post_run_attrs(%ScheduleEntry{schedule_type: :once}, attrs, _now, _run_count) do
    Map.put(attrs, :status, :completed)
  end

  # :interval entries compute the next run time. If max_runs is reached,
  # they transition to :completed instead of scheduling another run.
  defp compute_post_run_attrs(
         %ScheduleEntry{schedule_type: :interval, interval_ms: interval_ms, max_runs: max_runs},
         attrs,
         now,
         new_run_count
       )
       when is_integer(interval_ms) and interval_ms > 0 do
    if is_integer(max_runs) and new_run_count >= max_runs do
      Map.put(attrs, :status, :completed)
    else
      next = DateTime.add(now, interval_ms, :millisecond)
      Map.put(attrs, :next_run_at, next)
    end
  end

  # Guard: interval entry with missing/invalid interval_ms cannot compute
  # the next run time. Mark as failed to prevent infinite re-firing.
  defp compute_post_run_attrs(
         %ScheduleEntry{schedule_type: :interval},
         attrs,
         _now,
         _new_run_count
       ) do
    Map.put(attrs, :status, :failed)
  end
end
