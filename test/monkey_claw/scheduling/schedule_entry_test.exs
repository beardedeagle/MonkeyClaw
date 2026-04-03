defmodule MonkeyClaw.Scheduling.ScheduleEntryTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Scheduling.ScheduleEntry

  import MonkeyClaw.Factory

  describe "create_changeset/2" do
    test "valid attrs produce valid changeset" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      attrs = %{
        name: "Daily run",
        schedule_type: :once,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        experiment_config: %{
          "title" => "Test experiment",
          "type" => "code",
          "max_iterations" => 5
        }
      }

      cs = ScheduleEntry.create_changeset(entry, attrs)
      assert cs.valid?
    end

    test "requires name, schedule_type, next_run_at" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      cs = ScheduleEntry.create_changeset(entry, %{})
      refute cs.valid?
      assert errors_on(cs)[:name]
      assert errors_on(cs)[:schedule_type]
      assert errors_on(cs)[:next_run_at]
    end

    test "validates name max length 200" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      attrs = %{
        name: String.duplicate("a", 201),
        schedule_type: :once,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      cs = ScheduleEntry.create_changeset(entry, attrs)
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "validates schedule_type inclusion" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      attrs = %{
        name: "Test",
        schedule_type: :weekly,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      cs = ScheduleEntry.create_changeset(entry, attrs)
      refute cs.valid?
      assert errors_on(cs)[:schedule_type]
    end

    test ":interval requires interval_ms > 0" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      attrs = %{
        name: "Interval run",
        schedule_type: :interval,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        experiment_config: %{
          "title" => "T",
          "type" => "code",
          "max_iterations" => 1
        }
      }

      cs_missing = ScheduleEntry.create_changeset(entry, attrs)
      refute cs_missing.valid?
      assert errors_on(cs_missing)[:interval_ms]

      cs_zero = ScheduleEntry.create_changeset(entry, Map.put(attrs, :interval_ms, 0))
      refute cs_zero.valid?
      assert errors_on(cs_zero)[:interval_ms]

      cs_valid = ScheduleEntry.create_changeset(entry, Map.put(attrs, :interval_ms, 60_000))
      assert cs_valid.valid?
    end

    test ":once must not have interval_ms set" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      attrs = %{
        name: "Once run",
        schedule_type: :once,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        interval_ms: 60_000
      }

      cs = ScheduleEntry.create_changeset(entry, attrs)
      refute cs.valid?
      assert errors_on(cs)[:interval_ms]
    end

    test "interval_ms max is 604_800_000" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      attrs = %{
        name: "Interval run",
        schedule_type: :interval,
        interval_ms: 604_800_001,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        experiment_config: %{
          "title" => "T",
          "type" => "code",
          "max_iterations" => 1
        }
      }

      cs = ScheduleEntry.create_changeset(entry, attrs)
      refute cs.valid?
      assert errors_on(cs)[:interval_ms]

      cs_max = ScheduleEntry.create_changeset(entry, Map.put(attrs, :interval_ms, 604_800_000))
      assert cs_max.valid?
    end

    test "validates experiment_config has required keys" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      base_attrs = %{
        name: "Test",
        schedule_type: :once,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      cs_missing_type =
        ScheduleEntry.create_changeset(
          entry,
          Map.put(base_attrs, :experiment_config, %{
            "title" => "T",
            "max_iterations" => 3
          })
        )

      refute cs_missing_type.valid?
      assert errors_on(cs_missing_type)[:experiment_config]

      cs_missing_title =
        ScheduleEntry.create_changeset(
          entry,
          Map.put(base_attrs, :experiment_config, %{
            "type" => "code",
            "max_iterations" => 3
          })
        )

      refute cs_missing_title.valid?
      assert errors_on(cs_missing_title)[:experiment_config]

      cs_missing_iterations =
        ScheduleEntry.create_changeset(
          entry,
          Map.put(base_attrs, :experiment_config, %{
            "title" => "T",
            "type" => "code"
          })
        )

      refute cs_missing_iterations.valid?
      assert errors_on(cs_missing_iterations)[:experiment_config]
    end

    test "max_runs must be positive if set" do
      workspace = insert_workspace!()
      entry = Ecto.build_assoc(workspace, :schedule_entries)

      attrs = %{
        name: "Bounded run",
        schedule_type: :once,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        experiment_config: %{
          "title" => "T",
          "type" => "code",
          "max_iterations" => 1
        },
        max_runs: 0
      }

      cs_zero = ScheduleEntry.create_changeset(entry, attrs)
      refute cs_zero.valid?
      assert errors_on(cs_zero)[:max_runs]

      cs_positive = ScheduleEntry.create_changeset(entry, Map.put(attrs, :max_runs, 5))
      assert cs_positive.valid?
    end

    test "assoc_constraint on workspace" do
      entry = %ScheduleEntry{}

      attrs = %{
        name: "Orphan",
        schedule_type: :once,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      cs = ScheduleEntry.create_changeset(entry, attrs)
      # The changeset is structurally valid but the assoc_constraint fires on
      # insert when workspace_id is nil or references a nonexistent workspace.
      assert cs.constraints
             |> Enum.any?(&(&1.field == :workspace && &1.type == :foreign_key))
    end
  end

  describe "update_changeset/2" do
    test "allows updating name, description, next_run_at" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      future = DateTime.add(DateTime.utc_now(), 7200, :second)

      cs =
        ScheduleEntry.update_changeset(entry, %{
          name: "Updated name",
          description: "New description",
          next_run_at: future
        })

      assert cs.valid?
    end

    test "validates status transition active->paused is allowed" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      cs = ScheduleEntry.update_changeset(entry, %{status: :paused})
      assert cs.valid?
    end

    test "validates status transition active->completed is allowed" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      cs = ScheduleEntry.update_changeset(entry, %{status: :completed})
      assert cs.valid?
    end

    test "validates status transition paused->active is allowed" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      {:ok, paused} = MonkeyClaw.Scheduling.update_schedule_entry(entry, %{status: :paused})

      cs = ScheduleEntry.update_changeset(paused, %{status: :active})
      assert cs.valid?
    end

    test "rejects status transition completed->active" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      {:ok, completed} = MonkeyClaw.Scheduling.update_schedule_entry(entry, %{status: :completed})

      cs = ScheduleEntry.update_changeset(completed, %{status: :active})
      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "rejects status transition failed->active" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      {:ok, failed} = MonkeyClaw.Scheduling.update_schedule_entry(entry, %{status: :failed})

      cs = ScheduleEntry.update_changeset(failed, %{status: :active})
      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "rejects status transition paused->failed" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)
      {:ok, paused} = MonkeyClaw.Scheduling.update_schedule_entry(entry, %{status: :paused})

      cs = ScheduleEntry.update_changeset(paused, %{status: :failed})
      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "cannot set interval_ms on :once type via update" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      cs = ScheduleEntry.update_changeset(entry, %{interval_ms: 60_000})
      refute cs.valid?
      assert errors_on(cs)[:interval_ms]
    end

    test "validates run_count >= 0" do
      workspace = insert_workspace!()
      entry = insert_schedule_entry!(workspace)

      cs_negative = ScheduleEntry.update_changeset(entry, %{run_count: -1})
      refute cs_negative.valid?
      assert errors_on(cs_negative)[:run_count]

      cs_zero = ScheduleEntry.update_changeset(entry, %{run_count: 0})
      assert cs_zero.valid?
    end
  end

  describe "terminal?/1" do
    test "returns true for :completed" do
      assert ScheduleEntry.terminal?(:completed)
    end

    test "returns true for :failed" do
      assert ScheduleEntry.terminal?(:failed)
    end

    test "returns false for :active" do
      refute ScheduleEntry.terminal?(:active)
    end

    test "returns false for :paused" do
      refute ScheduleEntry.terminal?(:paused)
    end
  end

  describe "schedule_types/0" do
    test "returns expected list" do
      assert ScheduleEntry.schedule_types() == [:once, :interval]
    end
  end

  describe "statuses/0" do
    test "returns expected list" do
      assert ScheduleEntry.statuses() == [:active, :paused, :completed, :failed]
    end
  end
end
