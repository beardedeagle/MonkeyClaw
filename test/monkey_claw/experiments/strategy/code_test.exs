defmodule MonkeyClaw.Experiments.Strategy.CodeTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Experiments.Strategy.Code

  # ── Helpers ──────────────────────────────────────────────────

  defp make_experiment(config_overrides \\ %{}) do
    config =
      Map.merge(
        %{
          "scoped_files" => ["lib/parser.ex", "lib/lexer.ex"],
          "optimization_goal" => "Improve parsing speed"
        },
        config_overrides
      )

    %MonkeyClaw.Experiments.Experiment{
      id: Ecto.UUID.generate(),
      title: "Test experiment",
      type: :code,
      status: :created,
      config: config,
      max_iterations: 5,
      state_version: 1,
      iteration_count: 0
    }
  end

  defp make_run_result(overrides \\ %{}) do
    Map.merge(
      %{
        output: "I optimized the parsing function. All tests pass.",
        tool_calls: [
          %{name: "file_edit", input: %{"path" => "lib/parser.ex"}, output: nil}
        ],
        files_changed: ["lib/parser.ex"],
        metadata: %{}
      },
      overrides
    )
  end

  # ── init/2 ───────────────────────────────────────────────────

  describe "init/2" do
    test "initializes state from experiment config" do
      experiment = make_experiment()

      assert {:ok, state} = Code.init(experiment, %{})
      assert state.__v__ == 1
      assert state.scoped_files == ["lib/parser.ex", "lib/lexer.ex"]
      assert state.optimization_goal == "Improve parsing speed"
      assert state.best_score == nil
      assert state.iteration_scores == []
    end

    test "uses default thresholds" do
      experiment = make_experiment()

      {:ok, state} = Code.init(experiment, %{})
      assert state.accept_threshold == 0.8
      assert state.reject_threshold == 0.2
      assert state.stagnation_window == 3
    end

    test "accepts custom thresholds" do
      experiment =
        make_experiment(%{
          "accept_threshold" => 0.9,
          "reject_threshold" => 0.1,
          "stagnation_window" => 5
        })

      {:ok, state} = Code.init(experiment, %{})
      assert state.accept_threshold == 0.9
      assert state.reject_threshold == 0.1
      assert state.stagnation_window == 5
    end

    test "fails with no scoped_files" do
      experiment = make_experiment(%{"scoped_files" => []})
      assert {:error, :no_scoped_files} = Code.init(experiment, %{})
    end

    test "handles nil config gracefully" do
      experiment = %{make_experiment() | config: nil}
      assert {:error, :no_scoped_files} = Code.init(experiment, %{})
    end
  end

  # ── prepare_iteration/3 ─────────────────────────────────────

  describe "prepare_iteration/3" do
    test "stores checkpoint_id from opts" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      {:ok, prepared} = Code.prepare_iteration(state, 1, %{checkpoint_id: "chk-123"})
      assert prepared.checkpoint_id == "chk-123"
    end

    test "handles missing checkpoint_id" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      {:ok, prepared} = Code.prepare_iteration(state, 1, %{})
      assert prepared.checkpoint_id == nil
    end
  end

  # ── build_prompt/3 ──────────────────────────────────────────

  describe "build_prompt/3" do
    test "generates a prompt with scoped files and goal" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      {:ok, prompt} = Code.build_prompt(state, 1, %{max_iterations: 5})

      assert String.contains?(prompt, "lib/parser.ex")
      assert String.contains?(prompt, "lib/lexer.ex")
      assert String.contains?(prompt, "Improve parsing speed")
      assert String.contains?(prompt, "iteration 1 of 5")
    end

    test "includes best score when available" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})
      state = %{state | best_score: 0.75}

      {:ok, prompt} = Code.build_prompt(state, 2, %{max_iterations: 5})
      assert String.contains?(prompt, "0.75")
    end
  end

  # ── evaluate/3 ──────────────────────────────────────────────

  describe "evaluate/3" do
    test "produces score based on output and file changes" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      run_result = make_run_result()

      {:ok, eval_result, updated_state} = Code.evaluate(state, run_result, %{})

      assert is_float(eval_result.score) or is_integer(eval_result.score)
      assert eval_result.score > 0.0
      assert eval_result.in_scope == true
      assert eval_result.has_output == true
      assert updated_state.iteration_scores == [eval_result.score]
    end

    test "penalizes out-of-scope file changes" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      run_result = make_run_result(%{files_changed: ["lib/unrelated.ex"]})

      {:ok, eval_result, _state} = Code.evaluate(state, run_result, %{})

      # Out-of-scope penalty should lower the score
      assert eval_result.in_scope == false
    end

    test "handles empty output" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      run_result = make_run_result(%{output: "", files_changed: [], tool_calls: []})

      {:ok, eval_result, _state} = Code.evaluate(state, run_result, %{})
      assert eval_result.score == 0.0
    end

    test "accumulates scores across iterations" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      run_result = make_run_result()

      {:ok, _eval1, state} = Code.evaluate(state, run_result, %{})
      {:ok, _eval2, state} = Code.evaluate(state, run_result, %{})

      assert length(state.iteration_scores) == 2
    end
  end

  # ── decide/4 ────────────────────────────────────────────────

  describe "decide/4" do
    test "accepts when score above threshold" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      eval_result = %{score: 0.9}

      assert {:accept, updated_state} = Code.decide(state, eval_result, 1, %{})
      assert updated_state.best_score == 0.9
    end

    test "rejects when score below threshold" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      eval_result = %{score: 0.1}

      assert {:reject, _state} = Code.decide(state, eval_result, 1, %{})
    end

    test "continues when score is improving" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})
      state = %{state | best_score: 0.3}

      eval_result = %{score: 0.5}

      assert {:continue, updated_state} = Code.decide(state, eval_result, 1, %{})
      assert updated_state.best_score == 0.5
    end

    test "halts on stagnation" do
      experiment = make_experiment(%{"stagnation_window" => 2})
      {:ok, state} = Code.init(experiment, %{})

      # Simulate stagnation: best is 0.5, recent scores all <= 0.5
      state = %{state | best_score: 0.5, iteration_scores: [0.4, 0.3]}

      eval_result = %{score: 0.4}

      assert {:halt, _state} = Code.decide(state, eval_result, 3, %{})
    end
  end

  # ── rollback/2 ──────────────────────────────────────────────

  describe "rollback/2" do
    test "removes last score and clears checkpoint_id" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      state = %{state | iteration_scores: [0.3, 0.5, 0.4], checkpoint_id: "chk-123"}

      {:ok, rolled_back} = Code.rollback(state, %{})
      assert rolled_back.iteration_scores == [0.3, 0.5]
      assert rolled_back.checkpoint_id == nil
    end

    test "handles empty scores gracefully" do
      experiment = make_experiment()
      {:ok, state} = Code.init(experiment, %{})

      {:ok, rolled_back} = Code.rollback(state, %{})
      assert rolled_back.iteration_scores == []
    end
  end

  # ── mutation_scope/1 ────────────────────────────────────────

  describe "mutation_scope/1" do
    test "returns scoped files from config" do
      experiment = make_experiment()
      scope = Code.mutation_scope(experiment)

      assert scope == %{files: ["lib/parser.ex", "lib/lexer.ex"]}
    end

    test "returns empty files for nil config" do
      experiment = %{make_experiment() | config: nil}
      scope = Code.mutation_scope(experiment)

      assert scope == %{files: []}
    end
  end
end
