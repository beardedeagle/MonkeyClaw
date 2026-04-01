defmodule MonkeyClaw.ExperimentsTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Experiments.{Experiment, Iteration}

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # Experiment CRUD
  # ──────────────────────────────────────────────

  describe "create_experiment/2" do
    test "creates with required fields" do
      workspace = insert_workspace!()

      assert {:ok, %Experiment{} = experiment} =
               Experiments.create_experiment(workspace, %{
                 title: "Optimize parser",
                 type: :code,
                 max_iterations: 5
               })

      assert experiment.workspace_id == workspace.id
      assert experiment.title == "Optimize parser"
      assert experiment.type == :code
      assert experiment.status == :created
      assert experiment.max_iterations == 5
      assert experiment.iteration_count == 0
      assert experiment.state_version == 1
      assert experiment.id != nil
    end

    test "creates with all optional fields" do
      workspace = insert_workspace!()

      attrs = %{
        title: "Full experiment",
        type: :research,
        max_iterations: 10,
        time_budget_ms: 300_000,
        config: %{"scoped_files" => ["lib/foo.ex"], "optimization_goal" => "speed"}
      }

      assert {:ok, %Experiment{} = experiment} =
               Experiments.create_experiment(workspace, attrs)

      assert experiment.type == :research
      assert experiment.time_budget_ms == 300_000

      assert experiment.config == %{
               "scoped_files" => ["lib/foo.ex"],
               "optimization_goal" => "speed"
             }
    end

    test "generates binary_id" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert is_binary(experiment.id)
      assert {:ok, _} = Ecto.UUID.cast(experiment.id)
    end

    test "rejects invalid type" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Experiments.create_experiment(workspace, %{
                 title: "Bad",
                 type: :nonexistent,
                 max_iterations: 5
               })

      assert errors_on(changeset).type != []
    end
  end

  describe "get_experiment/1" do
    test "returns experiment by ID" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert {:ok, found} = Experiments.get_experiment(experiment.id)
      assert found.id == experiment.id
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Experiments.get_experiment(Ecto.UUID.generate())
    end
  end

  describe "get_experiment!/1" do
    test "returns experiment by ID" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert %Experiment{} = Experiments.get_experiment!(experiment.id)
    end

    test "raises for missing ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Experiments.get_experiment!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_experiments/1" do
    test "returns experiments for a workspace, most recent first" do
      workspace = insert_workspace!()
      e1 = insert_experiment!(workspace, %{title: "First"})
      e2 = insert_experiment!(workspace, %{title: "Second"})

      experiments = Experiments.list_experiments(workspace.id)
      ids = Enum.map(experiments, & &1.id)

      assert e2.id in ids
      assert e1.id in ids
      assert hd(ids) == e2.id
    end

    test "does not return experiments from other workspaces" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_experiment!(w1)
      insert_experiment!(w2)

      experiments = Experiments.list_experiments(w1.id)
      assert length(experiments) == 1
    end

    test "accepts workspace struct" do
      workspace = insert_workspace!()
      insert_experiment!(workspace)

      experiments = Experiments.list_experiments(workspace)
      assert length(experiments) == 1
    end
  end

  describe "list_experiments/2 with options" do
    test "limits results" do
      workspace = insert_workspace!()
      Enum.each(1..5, fn _ -> insert_experiment!(workspace) end)

      experiments = Experiments.list_experiments(workspace.id, %{limit: 3})
      assert length(experiments) == 3
    end

    test "filters by status" do
      workspace = insert_workspace!()
      _created = insert_experiment!(workspace)
      running = insert_experiment!(workspace)
      Experiments.update_experiment(running, %{status: :running})

      running_experiments = Experiments.list_experiments(workspace.id, %{status: :running})
      assert length(running_experiments) == 1
    end

    test "filters by type" do
      workspace = insert_workspace!()
      insert_experiment!(workspace, %{type: :code})
      insert_experiment!(workspace, %{type: :research})

      code_experiments = Experiments.list_experiments(workspace.id, %{type: :code})
      assert length(code_experiments) == 1
      assert hd(code_experiments).type == :code
    end
  end

  describe "update_experiment/2" do
    test "updates status" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert {:ok, updated} = Experiments.update_experiment(experiment, %{status: :running})
      assert updated.status == :running
    end

    test "updates state (opaque strategy state)" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      state = %{"__v__" => 1, "best_score" => 0.85}
      assert {:ok, updated} = Experiments.update_experiment(experiment, %{state: state})
      assert updated.state == state
    end

    test "updates completion fields" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)
      now = DateTime.utc_now()

      # Transition through valid states: created → running → accepted
      {:ok, running} = Experiments.update_experiment(experiment, %{status: :running})

      attrs = %{
        status: :accepted,
        completed_at: now,
        result: %{final_score: 0.92},
        termination_reason: nil
      }

      assert {:ok, updated} = Experiments.update_experiment(running, attrs)
      assert updated.status == :accepted
      assert updated.result == %{final_score: 0.92}
    end

    test "updates iteration_count" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert {:ok, updated} = Experiments.update_experiment(experiment, %{iteration_count: 3})
      assert updated.iteration_count == 3
    end
  end

  describe "delete_experiment/1" do
    test "deletes the experiment" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert {:ok, _} = Experiments.delete_experiment(experiment)
      assert {:error, :not_found} = Experiments.get_experiment(experiment.id)
    end

    test "cascade-deletes iterations" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, _} =
        Experiments.record_iteration(experiment, %{sequence: 1, status: :accepted})

      assert {:ok, _} = Experiments.delete_experiment(experiment)
      assert Experiments.get_iterations(experiment.id) == []
    end
  end

  # ──────────────────────────────────────────────
  # Iteration Operations
  # ──────────────────────────────────────────────

  describe "record_iteration/2" do
    test "inserts an iteration" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert {:ok, %Iteration{} = iteration} =
               Experiments.record_iteration(experiment, %{
                 sequence: 1,
                 status: :accepted,
                 eval_result: %{score: 0.85},
                 duration_ms: 3200
               })

      assert iteration.experiment_id == experiment.id
      assert iteration.sequence == 1
      assert iteration.status == :accepted
      assert iteration.eval_result == %{score: 0.85}
      assert iteration.duration_ms == 3200
    end

    test "enforces unique sequence per experiment" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, _} = Experiments.record_iteration(experiment, %{sequence: 1, status: :accepted})

      assert {:error, _changeset} =
               Experiments.record_iteration(experiment, %{sequence: 1, status: :rejected})
    end

    test "stores state_snapshot and metadata" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      attrs = %{
        sequence: 1,
        status: :accepted,
        state_snapshot: %{__v__: 1, best_score: 0.85},
        metadata: %{strategy: "code", human_gate: false}
      }

      assert {:ok, iteration} = Experiments.record_iteration(experiment, attrs)
      assert iteration.state_snapshot == %{__v__: 1, best_score: 0.85}
      assert iteration.metadata == %{strategy: "code", human_gate: false}
    end

    test "stores run_ref" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert {:ok, iteration} =
               Experiments.record_iteration(experiment, %{
                 sequence: 1,
                 status: :running,
                 run_ref: "#Reference<0.1234>"
               })

      assert iteration.run_ref == "#Reference<0.1234>"
    end
  end

  describe "get_iterations/1" do
    test "returns iterations ordered by sequence" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, _} = Experiments.record_iteration(experiment, %{sequence: 1, status: :accepted})
      {:ok, _} = Experiments.record_iteration(experiment, %{sequence: 2, status: :rejected})
      {:ok, _} = Experiments.record_iteration(experiment, %{sequence: 3, status: :accepted})

      iterations = Experiments.get_iterations(experiment.id)
      assert length(iterations) == 3
      assert Enum.map(iterations, & &1.sequence) == [1, 2, 3]
    end

    test "returns empty list for no iterations" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert Experiments.get_iterations(experiment.id) == []
    end
  end

  describe "get_iteration/2" do
    test "returns iteration by experiment and sequence" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, _} = Experiments.record_iteration(experiment, %{sequence: 1, status: :accepted})

      assert {:ok, iteration} = Experiments.get_iteration(experiment.id, 1)
      assert iteration.sequence == 1
    end

    test "returns {:error, :not_found} for missing sequence" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert {:error, :not_found} = Experiments.get_iteration(experiment.id, 99)
    end
  end

  describe "count_iterations/1" do
    test "counts iterations" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      assert Experiments.count_iterations(experiment.id) == 0

      {:ok, _} = Experiments.record_iteration(experiment, %{sequence: 1, status: :accepted})
      {:ok, _} = Experiments.record_iteration(experiment, %{sequence: 2, status: :rejected})

      assert Experiments.count_iterations(experiment.id) == 2
    end
  end
end
