defmodule MonkeyClaw.SchedulingTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Scheduling
  alias MonkeyClaw.Scheduling.ScheduleEntry

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # create_schedule_entry/2
  # ──────────────────────────────────────────────

  describe "create_schedule_entry/2" do
    test "creates entry within workspace with valid attrs" do
      workspace = insert_workspace!()

      {:ok, entry} =
        Scheduling.create_schedule_entry(workspace, %{
          name: "Daily optimization",
          schedule_type: :once,
          next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          experiment_config: %{
            "title" => "Auto-optimize parser",
            "type" => "code",
            "max_iterations" => 3
          }
        })

      assert %ScheduleEntry{} = entry
      assert entry.name == "Daily optimization"
      assert entry.schedule_type == :once
    end

    test "sets workspace_id automatically" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      assert entry.workspace_id == workspace.id
    end

    test "defaults status to :active and run_count to 0" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      assert entry.status == :active
      assert entry.run_count == 0
    end

    test "rejects missing required fields" do
      workspace = insert_workspace!()

      {:error, cs} = Scheduling.create_schedule_entry(workspace, %{})
      assert errors_on(cs)[:name]
      assert errors_on(cs)[:schedule_type]
      assert errors_on(cs)[:next_run_at]
    end
  end

  # ──────────────────────────────────────────────
  # get_schedule_entry/1 and get_schedule_entry!/1
  # ──────────────────────────────────────────────

  describe "get_schedule_entry/1 and get_schedule_entry!/1" do
    test "returns entry by ID" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      assert {:ok, found} = Scheduling.get_schedule_entry(entry.id)
      assert found.id == entry.id
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Scheduling.get_schedule_entry(Ecto.UUID.generate())
    end

    test "get_schedule_entry! raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        Scheduling.get_schedule_entry!(Ecto.UUID.generate())
      end
    end
  end

  # ──────────────────────────────────────────────
  # list_schedule_entries/1 and list_schedule_entries/2
  # ──────────────────────────────────────────────

  describe "list_schedule_entries/1 and list_schedule_entries/2" do
    test "lists entries for workspace ordered by next_run_at" do
      workspace = insert_workspace!()
      now = DateTime.utc_now()

      insert_schedule_entry!(workspace, %{next_run_at: DateTime.add(now, 7200, :second)})
      insert_schedule_entry!(workspace, %{next_run_at: DateTime.add(now, 3600, :second)})

      entries = Scheduling.list_schedule_entries(workspace.id)
      assert length(entries) == 2

      [first, second] = entries
      assert DateTime.compare(first.next_run_at, second.next_run_at) in [:lt, :eq]
    end

    test "scopes to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_schedule_entry!(w1)
      insert_schedule_entry!(w2)

      entries = Scheduling.list_schedule_entries(w1.id)
      assert length(entries) == 1
      assert hd(entries).workspace_id == w1.id
    end

    test "filters by status when status filter provided" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      {:ok, _paused} = Scheduling.pause_entry(entry)
      insert_schedule_entry!(workspace)

      active_entries = Scheduling.list_schedule_entries(workspace.id, %{status: :active})
      paused_entries = Scheduling.list_schedule_entries(workspace.id, %{status: :paused})

      assert length(active_entries) == 1
      assert length(paused_entries) == 1
      assert hd(active_entries).status == :active
      assert hd(paused_entries).status == :paused
    end
  end

  # ──────────────────────────────────────────────
  # update_schedule_entry/2
  # ──────────────────────────────────────────────

  describe "update_schedule_entry/2" do
    test "updates entry fields" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      {:ok, updated} =
        Scheduling.update_schedule_entry(entry, %{
          name: "Renamed Entry",
          description: "A useful description"
        })

      assert updated.name == "Renamed Entry"
      assert updated.description == "A useful description"
    end
  end

  # ──────────────────────────────────────────────
  # delete_schedule_entry/1
  # ──────────────────────────────────────────────

  describe "delete_schedule_entry/1" do
    test "deletes entry, get returns :not_found after" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      {:ok, _deleted} = Scheduling.delete_schedule_entry(entry)
      assert {:error, :not_found} = Scheduling.get_schedule_entry(entry.id)
    end
  end

  # ──────────────────────────────────────────────
  # pause_entry/1 and activate_entry/1
  # ──────────────────────────────────────────────

  describe "pause_entry/1 and activate_entry/1" do
    test "pause_entry transitions active to paused" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      assert entry.status == :active

      {:ok, paused} = Scheduling.pause_entry(entry)
      assert paused.status == :paused
    end

    test "activate_entry transitions paused to active" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      {:ok, paused} = Scheduling.pause_entry(entry)
      assert paused.status == :paused

      {:ok, activated} = Scheduling.activate_entry(paused)
      assert activated.status == :active
    end

    test "pause_entry fails on completed entry (terminal)" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      {:ok, _} = Scheduling.record_run(entry)

      {:ok, completed} = Scheduling.get_schedule_entry(entry.id)
      assert completed.status == :completed

      {:error, cs} = Scheduling.pause_entry(completed)
      assert errors_on(cs)[:status]
    end

    test "activate_entry fails on completed entry (terminal)" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      {:ok, _} = Scheduling.record_run(entry)

      {:ok, completed} = Scheduling.get_schedule_entry(entry.id)
      assert completed.status == :completed

      {:error, cs} = Scheduling.activate_entry(completed)
      assert errors_on(cs)[:status]
    end
  end

  # ──────────────────────────────────────────────
  # record_run/1
  # ──────────────────────────────────────────────

  describe "record_run/1" do
    test ":once entry increments run_count, sets last_run_at, transitions to :completed" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace, %{schedule_type: :once})
      assert entry.run_count == 0
      assert entry.last_run_at == nil

      {:ok, updated} = Scheduling.record_run(entry)

      assert updated.run_count == 1
      assert updated.last_run_at != nil
      assert updated.status == :completed
    end

    test ":interval entry increments run_count, sets last_run_at, computes next next_run_at" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          schedule_type: :interval,
          interval_ms: 60_000,
          next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, updated} = Scheduling.record_run(entry)

      assert updated.run_count == 1
      assert updated.last_run_at != nil
      assert updated.status == :active

      # next_run_at is computed as last_run_at + interval_ms (60s), so it must be after last_run_at
      assert DateTime.compare(updated.next_run_at, updated.last_run_at) == :gt
    end

    test ":interval entry with max_runs transitions to :completed when run_count reaches max_runs" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          schedule_type: :interval,
          interval_ms: 60_000,
          next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          max_runs: 2
        })

      {:ok, after_first} = Scheduling.record_run(entry)
      assert after_first.run_count == 1
      assert after_first.status == :active

      {:ok, after_second} = Scheduling.record_run(after_first)
      assert after_second.run_count == 2
      assert after_second.status == :completed
    end

    test "record_run on already-completed :once entry is a no-op status transition" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace, %{schedule_type: :once})

      # First run completes it
      {:ok, completed} = Scheduling.record_run(entry)
      assert completed.status == :completed
      assert completed.run_count == 1

      # Second record_run: status stays :completed (no-op transition), run_count still increments.
      # In practice the Scheduler only fires :active entries, so this path is unreachable,
      # but we document the behaviour for safety.
      {:ok, again} = Scheduling.record_run(completed)
      assert again.status == :completed
      assert again.run_count == 2
    end

    test "record_run on :interval entry with invalid interval_ms marks entry failed" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          schedule_type: :interval,
          interval_ms: 60_000,
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      # Corrupt interval_ms directly in the DB to simulate a broken record.
      # This bypasses Ecto validations — the only way this state can occur.
      import Ecto.Query

      MonkeyClaw.Repo.update_all(
        from(e in ScheduleEntry, where: e.id == ^entry.id),
        set: [interval_ms: nil]
      )

      {:ok, corrupted} = Scheduling.get_schedule_entry(entry.id)
      assert is_nil(corrupted.interval_ms)

      {:ok, updated} = Scheduling.record_run(corrupted)
      assert updated.status == :failed
      assert updated.run_count == 1
    end
  end

  # ──────────────────────────────────────────────
  # due_entries/0
  # ──────────────────────────────────────────────

  describe "due_entries/0" do
    test "returns active entries where next_run_at is in the past" do
      workspace = insert_workspace!()
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      entry = insert_schedule_entry!(workspace, %{next_run_at: past})

      due = Scheduling.due_entries()
      ids = Enum.map(due, & &1.id)
      assert entry.id in ids
    end

    test "does not return paused entries even if next_run_at is past" do
      workspace = insert_workspace!()
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      entry = insert_schedule_entry!(workspace, %{next_run_at: past})
      {:ok, _paused} = Scheduling.pause_entry(entry)

      due = Scheduling.due_entries()
      ids = Enum.map(due, & &1.id)
      refute entry.id in ids
    end

    test "does not return future entries" do
      workspace = insert_workspace!()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      entry = insert_schedule_entry!(workspace, %{next_run_at: future})

      due = Scheduling.due_entries()
      ids = Enum.map(due, & &1.id)
      refute entry.id in ids
    end

    test "orders due entries by next_run_at ascending" do
      workspace = insert_workspace!()
      now = DateTime.utc_now()

      e1 = insert_schedule_entry!(workspace, %{next_run_at: DateTime.add(now, -30, :second)})
      e2 = insert_schedule_entry!(workspace, %{next_run_at: DateTime.add(now, -120, :second)})
      e3 = insert_schedule_entry!(workspace, %{next_run_at: DateTime.add(now, -60, :second)})

      due = Scheduling.due_entries()
      due_ids = Enum.map(due, & &1.id)

      e1_pos = Enum.find_index(due_ids, &(&1 == e1.id))
      e2_pos = Enum.find_index(due_ids, &(&1 == e2.id))
      e3_pos = Enum.find_index(due_ids, &(&1 == e3.id))

      assert e2_pos < e3_pos
      assert e3_pos < e1_pos
    end
  end
end
