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

      Scheduler.trigger_poll()

      # Give the cast time to complete
      :timer.sleep(100)

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

      Scheduler.trigger_poll()
      :timer.sleep(100)

      {:ok, updated} = Scheduling.get_schedule_entry(entry.id)
      refute is_nil(updated.last_run_at)
    end

    test "fires multiple due entries in a single poll" do
      workspace = insert_workspace!()

      past = DateTime.add(DateTime.utc_now(), -120, :second)

      entry_a = insert_schedule_entry!(workspace, %{next_run_at: past})
      entry_b = insert_schedule_entry!(workspace, %{next_run_at: past})

      Scheduler.trigger_poll()
      :timer.sleep(100)

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

      Scheduler.trigger_poll()
      :timer.sleep(100)

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

      Scheduler.trigger_poll()
      :timer.sleep(100)

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

      Scheduler.trigger_poll()
      :timer.sleep(100)

      {:ok, unchanged} = Scheduling.get_schedule_entry(entry.id)
      assert unchanged.run_count == 0
      assert unchanged.status == :completed
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

      Scheduler.trigger_poll()
      :timer.sleep(100)

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

      Scheduler.trigger_poll()
      :timer.sleep(100)

      {:ok, updated} = Scheduling.get_schedule_entry(entry.id)
      assert updated.run_count == 1
      assert updated.status == :completed
    end
  end
end
