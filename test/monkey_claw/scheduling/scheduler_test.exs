defmodule MonkeyClaw.Scheduling.SchedulerTest do
  use MonkeyClaw.DataCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Scheduling
  alias MonkeyClaw.Scheduling.Scheduler

  setup do
    # Scheduler is disabled in test.exs (:start_scheduler false).
    # Start a test-controlled instance with a long poll interval and initial delay
    # so it does not poll automatically during setup. Individual tests trigger
    # polling explicitly via Scheduler.trigger_poll/0 when needed.
    start_supervised!({Scheduler, [poll_interval: 999_999_999, initial_delay: 999_999_999]})
    :ok
  end

  describe "due entry detection" do
    test "fires a :once entry whose next_run_at is in the past" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert entry.run_count == 0
      assert entry.status == :active

      assert :ok = Scheduler.trigger_poll()

      {:ok, updated} = Scheduling.get_schedule_entry(entry.id)
      assert updated.run_count == 1
      assert updated.status == :completed
    end

    test "records last_run_at after firing" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert is_nil(entry.last_run_at)

      assert :ok = Scheduler.trigger_poll()

      {:ok, updated} = Scheduling.get_schedule_entry(entry.id)
      refute is_nil(updated.last_run_at)
    end

    test "fires multiple due entries in a single poll" do
      workspace = insert_workspace!()

      past = DateTime.add(DateTime.utc_now(), -120, :second)

      entry_a = insert_schedule_entry!(workspace, %{next_run_at: past})
      entry_b = insert_schedule_entry!(workspace, %{next_run_at: past})

      assert :ok = Scheduler.trigger_poll()

      {:ok, updated_a} = Scheduling.get_schedule_entry(entry_a.id)
      {:ok, updated_b} = Scheduling.get_schedule_entry(entry_b.id)

      assert updated_a.run_count == 1
      assert updated_b.run_count == 1
    end
  end

  describe "non-due entry skipping" do
    test "skips an entry whose next_run_at is in the future" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert :ok = Scheduler.trigger_poll()

      {:ok, unchanged} = Scheduling.get_schedule_entry(entry.id)
      assert unchanged.run_count == 0
      assert unchanged.status == :active
    end
  end

  describe "paused entry skipping" do
    test "skips a paused entry even when next_run_at is in the past" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      # Pause the entry after creation (status is not a create field)
      {:ok, paused} = Scheduling.pause_entry(entry)
      assert paused.status == :paused

      assert :ok = Scheduler.trigger_poll()

      {:ok, unchanged} = Scheduling.get_schedule_entry(entry.id)
      assert unchanged.run_count == 0
      assert unchanged.status == :paused
    end
  end

  describe "completed entry skipping" do
    test "skips a completed entry even when next_run_at is in the past" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, completed} = Scheduling.update_schedule_entry(entry, %{status: :completed})
      assert completed.status == :completed

      assert :ok = Scheduler.trigger_poll()

      {:ok, unchanged} = Scheduling.get_schedule_entry(entry.id)
      assert unchanged.run_count == 0
      assert unchanged.status == :completed
    end
  end

  describe "entry failure isolation" do
    test "scheduler marks entry failed when experiment creation fails, without crashing" do
      workspace = insert_workspace!()

      # Create a due entry with an invalid experiment_config that will
      # cause Experiments.create_experiment/2 to return {:error, changeset}.
      # This exercises the error-handling branch in fire_entry/1 and verifies
      # the Scheduler marks the entry as :failed to prevent infinite re-firing.
      entry =
        insert_schedule_entry!(workspace, %{
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      # Corrupt experiment_config directly in the DB to an empty map so it
      # fails validation in Experiments.create_experiment/2. The create
      # changeset requires title, type, and max_iterations.
      # Raw SQL bypasses Ecto's schema-level type casting.
      Ecto.Adapters.SQL.query!(
        MonkeyClaw.Repo,
        "UPDATE schedule_entries SET experiment_config = ? WHERE id = ?",
        ["{}", entry.id]
      )

      {:ok, corrupted} = Scheduling.get_schedule_entry(entry.id)
      assert corrupted.experiment_config == %{}

      # Trigger poll — should not crash
      assert :ok = Scheduler.trigger_poll()

      # The entry should be marked :failed because experiment creation
      # failed, and the Scheduler prevents infinite re-firing.
      {:ok, updated} = Scheduling.get_schedule_entry(entry.id)
      assert updated.status == :failed
    end

    test "one failing entry does not prevent other due entries from firing" do
      workspace = insert_workspace!()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      # Good entry that should fire normally
      good_entry = insert_schedule_entry!(workspace, %{next_run_at: past})

      # Bad entry with corrupted experiment_config
      bad_entry = insert_schedule_entry!(workspace, %{next_run_at: past})

      # Raw SQL bypasses Ecto's schema-level type casting.
      Ecto.Adapters.SQL.query!(
        MonkeyClaw.Repo,
        "UPDATE schedule_entries SET experiment_config = ? WHERE id = ?",
        ["{}", bad_entry.id]
      )

      # Trigger poll — should fire both entries without crashing
      assert :ok = Scheduler.trigger_poll()

      # Good entry should have fired successfully
      {:ok, updated_good} = Scheduling.get_schedule_entry(good_entry.id)
      assert updated_good.run_count == 1
      assert updated_good.status == :completed

      # Bad entry should be marked :failed
      {:ok, updated_bad} = Scheduling.get_schedule_entry(bad_entry.id)
      assert updated_bad.status == :failed
    end
  end

  describe "interval entry scheduling" do
    test "interval entry advances next_run_at after firing" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          schedule_type: :interval,
          interval_ms: 60_000,
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert :ok = Scheduler.trigger_poll()

      {:ok, updated} = Scheduling.get_schedule_entry(entry.id)
      assert updated.run_count == 1
      # Interval entries stay :active unless max_runs is hit
      assert updated.status == :active
      # next_run_at should be in the future
      assert DateTime.compare(updated.next_run_at, DateTime.utc_now()) == :gt
    end

    test "interval entry completes when max_runs is reached" do
      workspace = insert_workspace!()

      entry =
        insert_schedule_entry!(workspace, %{
          schedule_type: :interval,
          interval_ms: 60_000,
          max_runs: 1,
          next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert :ok = Scheduler.trigger_poll()

      {:ok, updated} = Scheduling.get_schedule_entry(entry.id)
      assert updated.run_count == 1
      assert updated.status == :completed
    end
  end
end
