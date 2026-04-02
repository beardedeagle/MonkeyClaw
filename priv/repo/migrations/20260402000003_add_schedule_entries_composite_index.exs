defmodule MonkeyClaw.Repo.Migrations.AddScheduleEntriesCompositeIndex do
  @moduledoc """
  Adds a composite index on `[:status, :next_run_at]` for efficient
  scheduler poll queries and drops the now-redundant single-column
  `status` index.

  The scheduler's `due_entries/0` query filters on `status = 'active'`
  and orders by `next_run_at`. A composite index satisfies both the
  filter and sort in a single index scan.
  """

  use Ecto.Migration

  def change do
    create index(:schedule_entries, [:status, :next_run_at],
             comment: "Composite index for scheduler poll queries"
           )

    drop index(:schedule_entries, [:status])
  end
end
