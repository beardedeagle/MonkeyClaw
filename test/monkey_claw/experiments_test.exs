defmodule MonkeyClaw.ExperimentsTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.AgentBridge.Backend
  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Experiments.{Experiment, Iteration, Runner}

  import MonkeyClaw.Factory

  # ── Test Strategy for Lifecycle Tests ──────────────────────────
  #
  # Minimal strategy implementation for lifecycle API tests.
  # NOT a mock — a real behaviour implementation.

  defmodule LifecycleStrategy do
    @behaviour MonkeyClaw.Experiments.Strategy

    @impl true
    def init(_experiment, _opts), do: {:ok, %{__v__: 1}}

    @impl true
    def prepare_iteration(state, _iteration, _opts), do: {:ok, state}

    @impl true
    def build_prompt(_state, iteration, _opts), do: {:ok, "lifecycle test #{iteration}"}

    @impl true
    def evaluate(state, _run_result, _opts), do: {:ok, %{score: 0.75}, state}

    @impl true
    def decide(state, _eval_result, _iteration, _opts), do: {:accept, state}

    @impl true
    def rollback(state, _opts), do: {:ok, state}

    @impl true
    def mutation_scope(_experiment), do: %{files: []}
  end

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

  # ──────────────────────────────────────────────
  # Experiment Lifecycle
  # ──────────────────────────────────────────────

  describe "start_experiment/3" do
    test "creates experiment and starts runner" do
      workspace = insert_workspace!()

      attrs = %{title: "Lifecycle test", type: :code, max_iterations: 3}
      runner_config = %{strategy: LifecycleStrategy, backend: Backend.Test}

      assert {:ok, %Experiment{} = experiment, pid} =
               Experiments.start_experiment(workspace, attrs, runner_config)

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert experiment.title == "Lifecycle test"
      assert experiment.status == :created

      # Runner is registered and reachable
      assert {:ok, ^pid} = Runner.lookup(experiment.id)

      # Wait for completion
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :accepted
    end

    test "returns changeset error for invalid attrs" do
      workspace = insert_workspace!()

      # Missing required :title
      attrs = %{type: :code, max_iterations: 3}
      runner_config = %{strategy: LifecycleStrategy, backend: Backend.Test}

      assert {:error, %Ecto.Changeset{}} =
               Experiments.start_experiment(workspace, attrs, runner_config)
    end

    test "runner marks experiment cancelled on strategy init failure" do
      workspace = insert_workspace!()

      attrs = %{title: "Doomed", type: :code, max_iterations: 3}

      # Invalid strategy module — Runner.handle_continue(:initialize)
      # will fail. Runner.start_link succeeds immediately (async init
      # is the correct OTP pattern), so start_experiment returns
      # {:ok, experiment, pid}. The Runner then dies during init and
      # marks the experiment as :cancelled.
      runner_config = %{strategy: NonExistentModule, backend: Backend.Test}

      assert {:ok, experiment, pid} =
               Experiments.start_experiment(workspace, attrs, runner_config)

      # Wait for the Runner to die from async init failure
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5000

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :cancelled
      assert updated.termination_reason == "init_failed"
    end
  end

  describe "stop_experiment/1" do
    test "gracefully stops a running experiment" do
      workspace = insert_workspace!()

      attrs = %{title: "Stop test", type: :code, max_iterations: 10}

      runner_config = %{
        strategy: LifecycleStrategy,
        backend: Backend.Test,
        session_opts: %{
          query_responses: fn _prompt, _count ->
            Process.sleep(200)
            {:ok, [%{type: :text, content: "working"}]}
          end
        }
      }

      {:ok, experiment, pid} =
        Experiments.start_experiment(workspace, attrs, runner_config)

      ref = Process.monitor(pid)

      # Wait for first iteration to start, then stop
      Process.sleep(100)
      assert :ok = Experiments.stop_experiment(experiment.id)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status in [:halted, :accepted]
    end

    test "returns error for non-running experiment" do
      assert {:error, :not_running} = Experiments.stop_experiment(Ecto.UUID.generate())
    end
  end

  describe "cancel_experiment/1" do
    test "cancels a running experiment immediately" do
      workspace = insert_workspace!()

      attrs = %{title: "Cancel test", type: :code, max_iterations: 10}

      runner_config = %{
        strategy: LifecycleStrategy,
        backend: Backend.Test,
        session_opts: %{
          query_responses: fn _prompt, _count ->
            Process.sleep(500)
            {:ok, [%{type: :text, content: "working"}]}
          end
        }
      }

      {:ok, experiment, pid} =
        Experiments.start_experiment(workspace, attrs, runner_config)

      ref = Process.monitor(pid)

      # Wait for iteration to start, then cancel
      Process.sleep(100)
      assert :ok = Experiments.cancel_experiment(experiment.id)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :cancelled
      assert updated.termination_reason == "user_cancel"
    end

    test "returns error for non-running experiment" do
      assert {:error, :not_running} = Experiments.cancel_experiment(Ecto.UUID.generate())
    end
  end

  describe "experiment_status/1" do
    test "returns live status from running Runner" do
      workspace = insert_workspace!()

      attrs = %{title: "Status test", type: :code, max_iterations: 10}

      runner_config = %{
        strategy: LifecycleStrategy,
        backend: Backend.Test,
        human_gate: true
      }

      {:ok, experiment, pid} =
        Experiments.start_experiment(workspace, attrs, runner_config)

      ref = Process.monitor(pid)

      # Wait for human gate pause
      deadline = System.monotonic_time(:millisecond) + 5000

      poll_status = fn ->
        case Experiments.experiment_status(experiment.id) do
          {:ok, %{status: :awaiting_human}} -> true
          _ -> false
        end
      end

      poll_until_true(poll_status, deadline)

      {:ok, status} = Experiments.experiment_status(experiment.id)
      assert status.status == :awaiting_human
      assert status.experiment_id == experiment.id
      assert status.iteration == 1

      Runner.cancel(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end

    test "falls back to DB status when no Runner active" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, status} = Experiments.experiment_status(experiment.id)
      assert status.status == :created
      assert status.experiment_id == experiment.id
    end

    test "returns not_found for missing experiment" do
      assert {:error, :not_found} = Experiments.experiment_status(Ecto.UUID.generate())
    end
  end

  # ── Private Helpers ──────────────────────────────────────────

  defp poll_until_true(check_fn, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Timed out waiting for condition")
    end

    if check_fn.() do
      :ok
    else
      Process.sleep(10)
      poll_until_true(check_fn, deadline)
    end
  end
end
