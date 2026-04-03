defmodule MonkeyClaw.Repo.Migrations.CreateScheduleEntries do
  @moduledoc """
  Creates the schedule_entries table for autonomous task scheduling.

  ## Tables

    * `schedule_entries` — Workspace-scoped scheduled tasks that create
      experiment runs when their timer fires.

  All data tables use `STRICT, WITHOUT ROWID` for type enforcement and
  clustered UUID primary keys.

  ## Schedule Types

    * `:once` — Fires a single time at `next_run_at`, then transitions
      to `:completed`.
    * `:interval` — Fires repeatedly every `interval_ms` milliseconds.
      Optionally bounded by `max_runs`.
  """

  use Ecto.Migration

  def change do
    create table(:schedule_entries, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :schedule_type, :string, null: false
      add :interval_ms, :integer
      add :next_run_at, :utc_datetime_usec, null: false
      add :experiment_config, :text, null: false, default: "{}"
      add :status, :string, null: false, default: "active"
      add :last_run_at, :utc_datetime_usec
      add :run_count, :integer, null: false, default: 0
      add :max_runs, :integer

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:schedule_entries, [:workspace_id])
    create index(:schedule_entries, [:status])
    create index(:schedule_entries, [:next_run_at], comment: "For scheduler poll queries")
  end
end
