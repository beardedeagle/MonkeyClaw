defmodule MonkeyClaw.Repo.Migrations.AddLockVersionToScheduleEntries do
  @moduledoc """
  Adds a `lock_version` column to `schedule_entries` for optimistic
  concurrency control via `Ecto.Changeset.optimistic_lock/3`.

  The column defaults to `0` and is incremented on each update through
  the `record_run/1` path, preventing lost updates if entry firing is
  ever parallelized beyond a single GenServer.
  """

  use Ecto.Migration

  def change do
    alter table(:schedule_entries) do
      add :lock_version, :integer, null: false, default: 0
    end
  end
end
