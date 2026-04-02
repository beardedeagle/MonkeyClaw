defmodule MonkeyClaw.Skills.ExtractorTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Skills.Extractor

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # extract_from_experiment/1
  # ──────────────────────────────────────────────

  describe "extract_from_experiment/1" do
    test "extracts skill from accepted experiment with procedure in state_snapshot" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace, %{title: "Optimize parser", type: :code})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :running})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :evaluating})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :accepted})

      {:ok, _iter} =
        Experiments.record_iteration(experiment, %{
          sequence: 1,
          status: :accepted,
          eval_result: %{"score" => 0.95, "summary" => "Parser optimized successfully"},
          state_snapshot: %{"procedure" => "1. Profile with :fprof\n2. Fix hot paths"},
          duration_ms: 5000
        })

      experiment = Repo.preload(experiment, :iterations)
      {:ok, attrs} = Extractor.extract_from_experiment(experiment)

      assert attrs.title == "Code: Optimize parser"
      assert String.contains?(attrs.description, "Code experiment")
      assert attrs.procedure == "1. Profile with :fprof\n2. Fix hot paths"
      assert "code" in attrs.tags
      assert "extracted" in attrs.tags
    end

    test "extracts from state_snapshot steps list" do
      workspace = insert_workspace!()

      experiment =
        insert_experiment!(workspace, %{title: "Research task", type: :research})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :running})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :accepted})

      {:ok, _iter} =
        Experiments.record_iteration(experiment, %{
          sequence: 1,
          status: :accepted,
          eval_result: %{},
          state_snapshot: %{"steps" => ["Gather data", "Analyze results", "Report findings"]},
          duration_ms: 1000
        })

      experiment = Repo.preload(experiment, :iterations)
      {:ok, attrs} = Extractor.extract_from_experiment(experiment)

      assert String.contains?(attrs.procedure, "1. Gather data")
      assert String.contains?(attrs.procedure, "2. Analyze results")
      assert String.contains?(attrs.procedure, "3. Report findings")
    end

    test "returns error for non-accepted experiment" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)
      experiment = Repo.preload(experiment, :iterations)

      assert {:error, :not_accepted} = Extractor.extract_from_experiment(experiment)
    end

    test "returns error for experiment with no iterations" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :running})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :accepted})

      experiment = Repo.preload(experiment, :iterations)

      assert {:error, :no_iterations} = Extractor.extract_from_experiment(experiment)
    end

    test "uses fallback when no procedure/steps in snapshot" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace, %{title: "Test", type: :code})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :running})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :accepted})

      {:ok, _iter} =
        Experiments.record_iteration(experiment, %{
          sequence: 1,
          status: :accepted,
          eval_result: %{"score" => 0.8},
          state_snapshot: %{"some_key" => "some_value"},
          duration_ms: 1000
        })

      experiment = Repo.preload(experiment, :iterations)
      {:ok, attrs} = Extractor.extract_from_experiment(experiment)

      assert is_binary(attrs.procedure)
      assert attrs.procedure != ""
    end
  end
end
