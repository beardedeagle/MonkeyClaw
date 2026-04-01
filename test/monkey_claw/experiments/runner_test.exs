defmodule MonkeyClaw.Experiments.RunnerTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.AgentBridge.Backend
  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Experiments.Runner

  import MonkeyClaw.Factory

  # ── Test Strategy ─────────────────────────────────────────────
  #
  # A controllable Strategy implementation for Runner integration
  # tests. NOT a mock — a real behaviour implementation whose
  # decisions are driven by experiment config.
  #
  # Config keys (all optional, sensible defaults):
  #   "decisions"  — list of decision strings ["continue", "accept", ...]
  #   "eval_score" — float score returned by evaluate/3 (default: 0.5)
  #   "init_error" — if present, init/2 returns {:error, value}

  defmodule TestStrategy do
    @behaviour MonkeyClaw.Experiments.Strategy

    @decision_map %{
      "continue" => :continue,
      "accept" => :accept,
      "reject" => :reject,
      "halt" => :halt
    }

    @impl true
    def init(experiment, _opts) do
      config = experiment.config || %{}

      case config do
        %{"init_error" => reason} ->
          {:error, reason}

        _ ->
          {:ok,
           %{
             __v__: 1,
             decisions: Map.get(config, "decisions", ["accept"]),
             eval_score: Map.get(config, "eval_score", 0.5),
             iteration_count: 0,
             checkpoint_id: nil
           }}
      end
    end

    @impl true
    def prepare_iteration(state, _iteration, opts) do
      {:ok, %{state | checkpoint_id: Map.get(opts, :checkpoint_id)}}
    end

    @impl true
    def build_prompt(_state, iteration, opts) do
      max = Map.get(opts, :max_iterations, 10)
      {:ok, "Test iteration #{iteration} of #{max}"}
    end

    @impl true
    def evaluate(state, _run_result, _opts) do
      eval_result = %{score: state.eval_score}
      {:ok, eval_result, %{state | iteration_count: state.iteration_count + 1}}
    end

    @impl true
    def decide(state, _eval_result, _iteration, _opts) do
      case state.decisions do
        [decision_str | rest] ->
          decision = Map.fetch!(@decision_map, decision_str)
          {decision, %{state | decisions: rest}}

        [] ->
          {:accept, state}
      end
    end

    @impl true
    def rollback(state, _opts) do
      {:ok, %{state | checkpoint_id: nil}}
    end

    @impl true
    def mutation_scope(_experiment) do
      %{files: ["test/example.ex"]}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp make_experiment(workspace, config_overrides \\ %{}, experiment_overrides \\ %{}) do
    base_config = %{"decisions" => ["accept"], "eval_score" => 0.7}

    attrs =
      Map.merge(
        %{config: Map.merge(base_config, config_overrides)},
        experiment_overrides
      )

    insert_experiment!(workspace, attrs)
  end

  defp runner_config(experiment, extra \\ %{}) do
    Map.merge(
      %{
        experiment_id: experiment.id,
        strategy: TestStrategy,
        backend: Backend.Test
      },
      extra
    )
  end

  defp start_runner(config) do
    pid = start_supervised!({Runner, config})
    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp wait_for_exit(ref, pid, timeout \\ 5000) do
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  defp wait_for_status(server, expected, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(
      fn ->
        try do
          {:ok, %{status: status}} = Runner.info(server)
          status == expected
        catch
          :exit, _ -> false
        end
      end,
      deadline,
      "status #{inspect(expected)}"
    )
  end

  defp wait_for_iteration(server, min_iteration, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(
      fn ->
        try do
          {:ok, %{iteration: i}} = Runner.info(server)
          i >= min_iteration
        catch
          :exit, _ -> false
        end
      end,
      deadline,
      "iteration >= #{min_iteration}"
    )
  end

  defp poll_until(check_fn, deadline, label) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Timed out waiting for #{label}")
    end

    if check_fn.() do
      :ok
    else
      Process.sleep(10)
      poll_until(check_fn, deadline, label)
    end
  end

  # ── Initialization ──────────────────────────────────────────

  describe "initialization" do
    test "initializes, runs iteration, and accepts" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace)
      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :accepted
      assert updated.iteration_count == 1
      assert updated.completed_at != nil
    end

    test "stops on strategy init failure" do
      Process.flag(:trap_exit, true)

      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"init_error" => "bad_config"})
      config = runner_config(experiment)

      {:ok, pid} = Runner.start_link(config)
      assert_receive {:EXIT, ^pid, {:init_failed, "bad_config"}}, 5000

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :cancelled
      assert updated.termination_reason == "init_failed"
    end

    test "records iteration with accepted status" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace)
      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      iterations = Experiments.get_iterations(experiment.id)
      assert length(iterations) == 1
      assert hd(iterations).status == :accepted
      assert hd(iterations).sequence == 1
      assert is_integer(hd(iterations).duration_ms)
    end
  end

  # ── Failure Path 1: Rollback After Reject ───────────────────

  describe "rollback after reject" do
    test "rejects, rolls back, and records rejected iteration" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["reject"]})
      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :rejected
      assert updated.iteration_count == 1

      iterations = Experiments.get_iterations(experiment.id)
      assert length(iterations) == 1
      assert hd(iterations).status == :rejected
      assert hd(iterations).sequence == 1
    end

    test "checkpoint rewind is attempted on reject" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["reject"]})
      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      # The fact that the Runner completed without error proves the
      # rollback path (including checkpoint_rewind via Backend.Test)
      # executed successfully. Backend.Test raises on invalid checkpoint
      # IDs, so a crash here would indicate a broken rollback flow.
      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :rejected
    end
  end

  # ── Failure Path 2: Timeout Mid-Run ─────────────────────────

  describe "timeout mid-run" do
    test "cancels when time budget expires during iteration" do
      workspace = insert_workspace!()

      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["accept"]},
          %{time_budget_ms: 100}
        )

      # Slow query ensures the timer fires before the task completes
      config =
        runner_config(experiment, %{
          session_opts: %{
            query_responses: fn _prompt, _count ->
              Process.sleep(2000)
              {:ok, [%{type: :text, content: "too late"}]}
            end
          }
        })

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid, 10_000)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :cancelled
      assert updated.termination_reason == "timeout"
    end
  end

  # ── Failure Path 3: Backend Session Crash ───────────────────

  describe "backend session crash" do
    test "handles crash with best-effort rollback" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["accept"]})

      # Slow query keeps task running while we kill the session
      config =
        runner_config(experiment, %{
          session_opts: %{
            query_responses: fn _prompt, _count ->
              Process.sleep(2000)
              {:ok, [%{type: :text, content: "never seen"}]}
            end
          }
        })

      {pid, ref} = start_runner(config)
      wait_for_iteration(pid, 1)

      # Kill the backend session process directly
      runner_state = :sys.get_state(pid)
      session_pid = runner_state.session_pid
      assert is_pid(session_pid)
      Process.exit(session_pid, :kill)

      wait_for_exit(ref, pid, 10_000)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :cancelled
      assert updated.termination_reason == "crash"
    end
  end

  # ── Failure Path 4: Human Gate Pause + Resume ───────────────

  describe "human gate pause and resume" do
    test "pauses at :awaiting_human and resumes on human_decision" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["accept"]})
      config = runner_config(experiment, %{human_gate: true})

      {pid, ref} = start_runner(config)
      wait_for_status(pid, :awaiting_human)

      # GenServer stays responsive while paused
      assert {:ok, info} = Runner.info(pid)
      assert info.status == :awaiting_human
      assert info.human_gate == true

      # Resume with human approval
      assert :ok = Runner.human_decision(pid, :accept)

      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :accepted
    end

    test "human can override strategy decision to reject" do
      workspace = insert_workspace!()
      # Strategy says accept, human overrides to reject
      experiment = make_experiment(workspace, %{"decisions" => ["accept"]})
      config = runner_config(experiment, %{human_gate: true})

      {pid, ref} = start_runner(config)
      wait_for_status(pid, :awaiting_human)

      assert :ok = Runner.human_decision(pid, :reject)

      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :rejected
    end

    test "human can continue when strategy wanted to halt" do
      workspace = insert_workspace!()
      # Strategy says halt, human says continue (run another iteration)
      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["halt", "accept"]},
          %{max_iterations: 10}
        )

      config = runner_config(experiment, %{human_gate: true})

      {pid, ref} = start_runner(config)

      # First iteration: strategy decides halt, human overrides to continue
      wait_for_status(pid, :awaiting_human)
      assert :ok = Runner.human_decision(pid, :continue)

      # Second iteration: strategy decides accept, human approves
      wait_for_status(pid, :awaiting_human)
      assert :ok = Runner.human_decision(pid, :accept)

      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :accepted
      assert updated.iteration_count == 2
    end

    test "rejects human_decision when not awaiting" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["accept"]})
      config = runner_config(experiment)

      {pid, _ref} = start_runner(config)

      # Try to send human_decision — Runner may still be processing
      # or may have already exited
      result =
        try do
          Runner.human_decision(pid, :accept)
        catch
          :exit, _ -> :process_exited
        end

      assert result in [{:error, :not_awaiting_human}, :process_exited]
    end
  end

  # ── Failure Path 5: Graceful Stop ───────────────────────────

  describe "graceful stop" do
    test "finishes current iteration before stopping" do
      workspace = insert_workspace!()

      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["continue", "continue", "continue"]},
          %{max_iterations: 10}
        )

      # Moderate delay gives time to send graceful_stop mid-iteration
      config =
        runner_config(experiment, %{
          session_opts: %{
            query_responses: fn _prompt, _count ->
              Process.sleep(300)
              {:ok, [%{type: :text, content: "working"}]}
            end
          }
        })

      {pid, ref} = start_runner(config)
      wait_for_iteration(pid, 1)

      Runner.graceful_stop(pid)
      wait_for_exit(ref, pid, 10_000)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :halted
      assert updated.termination_reason == "graceful_stop"

      # At least one iteration completed before stopping
      iterations = Experiments.get_iterations(experiment.id)
      assert iterations != []
    end

    test "halts immediately when awaiting human" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["accept"]})
      config = runner_config(experiment, %{human_gate: true})

      {pid, ref} = start_runner(config)
      wait_for_status(pid, :awaiting_human)

      # Graceful stop while awaiting human — halts immediately
      Runner.graceful_stop(pid)
      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :halted
      assert updated.termination_reason == "graceful_stop"
    end
  end

  # ── Failure Path 6: Multi-Iteration Decision Logic ──────────

  describe "multi-iteration decision logic" do
    test "continues through iterations then accepts" do
      workspace = insert_workspace!()

      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["continue", "continue", "accept"], "eval_score" => 0.6},
          %{max_iterations: 10}
        )

      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :accepted
      assert updated.iteration_count == 3

      iterations = Experiments.get_iterations(experiment.id)
      assert length(iterations) == 3
      assert Enum.map(iterations, & &1.sequence) == [1, 2, 3]
    end

    test "halts when strategy detects stagnation" do
      workspace = insert_workspace!()

      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["continue", "continue", "halt"], "eval_score" => 0.4},
          %{max_iterations: 10}
        )

      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :halted
      assert updated.iteration_count == 3
    end

    test "halts at max_iterations boundary" do
      workspace = insert_workspace!()

      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["continue", "continue", "continue"]},
          %{max_iterations: 3}
        )

      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :halted
      assert updated.termination_reason == "max_iterations_reached"
      assert updated.iteration_count == 3

      iterations = Experiments.get_iterations(experiment.id)
      assert length(iterations) == 3
    end

    test "persists strategy state on completion" do
      workspace = insert_workspace!()

      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["continue", "accept"], "eval_score" => 0.8},
          %{max_iterations: 10}
        )

      config = runner_config(experiment)

      {pid, ref} = start_runner(config)
      wait_for_exit(ref, pid)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      # Strategy state is persisted as the opaque :state field
      assert is_map(updated.state)
      # Strategy tracked 2 iterations
      assert updated.state["iteration_count"] == 2
    end
  end

  # ── Client API ──────────────────────────────────────────────

  describe "info/1" do
    test "returns current status and metadata" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["accept"]})
      config = runner_config(experiment, %{human_gate: true})

      {pid, ref} = start_runner(config)
      wait_for_status(pid, :awaiting_human)

      {:ok, info} = Runner.info(pid)
      assert info.experiment_id == experiment.id
      assert info.status == :awaiting_human
      assert info.iteration == 1
      assert info.max_iterations == experiment.max_iterations
      assert info.strategy == "teststrategy"
      assert info.human_gate == true

      Runner.cancel(pid)
      wait_for_exit(ref, pid)
    end
  end

  describe "lookup/1" do
    test "finds running runner by experiment_id" do
      workspace = insert_workspace!()
      experiment = make_experiment(workspace, %{"decisions" => ["accept"]})
      config = runner_config(experiment, %{human_gate: true})

      {pid, ref} = start_runner(config)
      wait_for_status(pid, :awaiting_human)

      assert {:ok, ^pid} = Runner.lookup(experiment.id)

      Runner.cancel(pid)
      wait_for_exit(ref, pid)
    end

    test "returns :not_found for unknown experiment" do
      assert {:error, :not_found} = Runner.lookup(Ecto.UUID.generate())
    end
  end

  describe "cancel/1" do
    test "cancels immediately with rollback" do
      workspace = insert_workspace!()

      experiment =
        make_experiment(
          workspace,
          %{"decisions" => ["continue", "continue"]},
          %{max_iterations: 10}
        )

      # Slow query so we can cancel mid-run
      config =
        runner_config(experiment, %{
          session_opts: %{
            query_responses: fn _prompt, _count ->
              Process.sleep(500)
              {:ok, [%{type: :text, content: "working"}]}
            end
          }
        })

      {pid, ref} = start_runner(config)
      wait_for_iteration(pid, 1)

      Runner.cancel(pid)
      wait_for_exit(ref, pid, 10_000)

      {:ok, updated} = Experiments.get_experiment(experiment.id)
      assert updated.status == :cancelled
      assert updated.termination_reason == "user_cancel"
    end
  end
end
