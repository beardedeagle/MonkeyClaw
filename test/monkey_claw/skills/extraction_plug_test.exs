defmodule MonkeyClaw.Skills.ExtractionPlugTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Skills.Cache
  alias MonkeyClaw.Skills.ExtractionPlug

  import MonkeyClaw.Factory

  setup do
    Cache.init()
    :ok
  end

  # ──────────────────────────────────────────────
  # init/1
  # ──────────────────────────────────────────────

  describe "init/1" do
    test "returns opts unchanged" do
      assert ExtractionPlug.init([]) == []
      assert ExtractionPlug.init(foo: :bar) == [foo: :bar]
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with experiment_completed event
  # ──────────────────────────────────────────────

  describe "call/2 with experiment_completed event" do
    test "extracts skill from accepted experiment" do
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
          eval_result: %{"score" => 0.95, "summary" => "Parser optimized"},
          state_snapshot: %{"procedure" => "1. Profile\n2. Fix"},
          duration_ms: 5000
        })

      ctx =
        Context.new!(:experiment_completed, %{experiment: experiment})

      result = ExtractionPlug.call(ctx, [])

      assert result.assigns[:extracted_skill] != nil
      skill = result.assigns[:extracted_skill]
      assert String.contains?(skill.title, "Optimize parser")
      assert skill.source_experiment_id == experiment.id
      assert skill.workspace_id == workspace.id
    end

    test "skips non-accepted experiments" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :running})

      {:ok, experiment} =
        Experiments.update_experiment(experiment, %{status: :rejected})

      ctx =
        Context.new!(:experiment_completed, %{experiment: experiment})

      result = ExtractionPlug.call(ctx, [])

      assert result.assigns[:extracted_skill] == nil
    end

    test "skips when no experiment in context" do
      ctx = Context.new!(:experiment_completed, %{})

      result = ExtractionPlug.call(ctx, [])

      assert result.assigns[:extracted_skill] == nil
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with non-experiment events
  # ──────────────────────────────────────────────

  describe "call/2 with non-experiment events" do
    test "passes through non-experiment_completed events unchanged" do
      ctx = Context.new!(:query_pre, %{prompt: "test"})

      result = ExtractionPlug.call(ctx, [])

      assert result == ctx
    end
  end
end
