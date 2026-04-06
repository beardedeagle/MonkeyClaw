defmodule MonkeyClaw.Experiments.Runner do
  @moduledoc """
  GenServer driving the experiment iteration loop.

  The Runner is the control-flow layer between the Strategy (domain
  logic) and BeamAgent (execution). It owns the iteration lifecycle,
  time budget, persistence, human gate, and run_result normalization.

  ## Iteration Loop

      :next_iteration →
        prepare_iteration → build_prompt →
        async Task (query via Backend) → {:noreply, state}

      handle_info({ref, result}) →
        normalize_run_result → evaluate → decide pipeline

      handle_info({:DOWN, ref, ...}) →
        handle task crash / session crash

      handle_info(:time_expired) →
        cancel task → rollback → stop

  ## Linear Decision Pipeline

  NOT: strategy.decide OR human gate (parallel, ambiguous)
  YES: strategy.decide THEN optional human override (linear, deterministic)

      run_result = normalize(raw_result)
      {:ok, eval_result, state} = strategy.evaluate(state, run_result, opts)
      auto_decision = strategy.decide(state, eval_result, iteration, opts)
      final_decision = maybe_human_override(auto_decision, eval_result, state)

  ## Human Gate

  When human gating is configured, the Runner enters `:awaiting_human`
  status — a state machine transition, NOT a blocking call. The
  GenServer stays responsive for timeouts, cancellation, and
  supervision signals.

  ## Async Execution

  The Runner NEVER blocks on `Backend.query`. Uses
  `Task.Supervisor.async_nolink` so the GenServer can handle
  `:time_expired`, cancellation, and `:DOWN` messages while the
  agent works.

  ## Three-Layer Ownership

  | Layer        | Owns                                              |
  |--------------|----------------------------------------------------|
  | **Strategy** | Domain: state, prompts, evaluation, rollback, decisions |
  | **Runner**   | Control: iteration loop, time budget, persistence, human gate |
  | **BeamAgent**| Execution: runs, tools, hooks, memory, checkpoints |

  ## Registration

  Each Runner is registered in `MonkeyClaw.Experiments.RunnerRegistry`
  under its experiment ID for lookup:

      {:via, Registry, {MonkeyClaw.Experiments.RunnerRegistry, experiment_id}}

  ## Process Design

  A GenServer is the correct abstraction because experiment runners are:

    * **Stateful** — wrap a live strategy state + session pid
    * **Lifecycle-bound** — init, iterate, evaluate, complete
    * **Monitor-dependent** — detect session/task crashes
    * **Cleanup-requiring** — stop session, cancel timers on termination
  """

  use GenServer

  require Logger

  alias MonkeyClaw.AgentBridge.Backend
  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Experiments.{RunResult, Telemetry}
  alias MonkeyClaw.Extensions

  # ── Types ────────────────────────────────────────────────────

  @type status ::
          :initializing
          | :running
          | :evaluating
          | :awaiting_human
          | :stopping
          | :accepted
          | :rejected
          | :cancelled
          | :halted

  @type config :: %{
          required(:experiment_id) => String.t(),
          required(:strategy) => module(),
          optional(:backend) => module(),
          optional(:session_opts) => map(),
          optional(:opts) => map(),
          optional(:human_gate) => boolean()
        }

  @type t :: %__MODULE__{
          experiment_id: String.t(),
          strategy: module(),
          strategy_name: String.t(),
          strategy_state: term(),
          backend: module(),
          session_pid: pid() | nil,
          session_monitor_ref: reference() | nil,
          task_ref: reference() | nil,
          task_pid: pid() | nil,
          timer_ref: reference() | nil,
          config: config(),
          status: status(),
          iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          human_gate: boolean(),
          pending_decision: atom() | nil,
          pending_eval_result: map() | nil,
          pending_run_ref: String.t() | nil,
          pending_duration_ms: non_neg_integer() | nil,
          experiment_start_time: integer() | nil,
          iteration_start_time: integer() | nil,
          mutation_scope: [String.t()],
          last_eval_result: map() | nil
        }

  @enforce_keys [:experiment_id, :strategy, :strategy_name, :backend, :config, :max_iterations]
  defstruct [
    :experiment_id,
    :strategy,
    :strategy_name,
    :strategy_state,
    :backend,
    :session_pid,
    :session_monitor_ref,
    :task_ref,
    :task_pid,
    :timer_ref,
    :config,
    :pending_decision,
    :pending_eval_result,
    :pending_run_ref,
    :pending_duration_ms,
    :experiment_start_time,
    :iteration_start_time,
    :last_eval_result,
    status: :initializing,
    iteration: 0,
    max_iterations: 10,
    human_gate: false,
    mutation_scope: []
  ]

  @default_backend Backend.BeamAgent

  # M2: Maximum byte length for error reasons persisted to SQLite.
  @max_error_length 2048

  # Strategy modules must export all behaviour callbacks.
  # Validated at init to prevent arbitrary module execution (M1).
  @required_strategy_callbacks [
    {:init, 2},
    {:prepare_iteration, 3},
    {:build_prompt, 3},
    {:evaluate, 3},
    {:decide, 4},
    {:rollback, 2},
    {:mutation_scope, 1}
  ]

  # ── Child Spec ───────────────────────────────────────────────

  @doc false
  def child_spec(config) do
    %{
      id: {__MODULE__, config.experiment_id},
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary
    }
  end

  # ── Client API ───────────────────────────────────────────────

  @doc """
  Start a linked Runner process for an experiment.

  ## Config

    * `:experiment_id` — ID of an existing experiment (required)
    * `:strategy` — Strategy module implementing the behaviour (required)
    * `:backend` — Backend module (default: `Backend.BeamAgent`)
    * `:session_opts` — Options for `Backend.start_session/1`
    * `:opts` — Strategy-specific options
    * `:human_gate` — Enable human decision gate (default: false)
  """
  @spec start_link(config()) :: GenServer.on_start()
  def start_link(%{experiment_id: id} = config)
      when is_binary(id) and byte_size(id) > 0 do
    GenServer.start_link(__MODULE__, config, name: via(id))
  end

  @doc """
  Get Runner status and metadata.
  """
  @spec info(GenServer.server()) :: {:ok, map()}
  def info(server) do
    GenServer.call(server, :info)
  end

  @doc """
  Submit a human decision to override the strategy's auto-decision.

  Only valid when the Runner is in `:awaiting_human` status.
  Valid decisions: `:continue`, `:accept`, `:reject`, `:halt`.
  """
  @spec human_decision(GenServer.server(), atom()) :: :ok | {:error, term()}
  def human_decision(server, decision)
      when decision in [:continue, :accept, :reject, :halt] do
    GenServer.call(server, {:human_decision, decision})
  end

  @doc """
  Request graceful stop — finish current iteration, then stop.

  If an iteration is in progress, it will complete and evaluate
  before the experiment stops. Not a cancellation — the final
  result is based on the last evaluation.
  """
  @spec graceful_stop(GenServer.server()) :: :ok
  def graceful_stop(server) do
    GenServer.cast(server, :graceful_stop)
  end

  @doc """
  Cancel the experiment immediately.

  Rolls back the current iteration and stops the Runner.
  """
  @spec cancel(GenServer.server()) :: :ok
  def cancel(server) do
    GenServer.cast(server, :user_cancel)
  end

  @doc """
  Look up a Runner pid by experiment ID.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(experiment_id) when is_binary(experiment_id) do
    case Registry.lookup(MonkeyClaw.Experiments.RunnerRegistry, experiment_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc false
  def via(experiment_id) do
    {:via, Registry, {MonkeyClaw.Experiments.RunnerRegistry, experiment_id}}
  end

  # ── GenServer Init ───────────────────────────────────────────

  @impl GenServer
  def init(config) do
    {:ok, config, {:continue, :initialize}}
  end

  @impl GenServer
  def handle_continue(:initialize, config) do
    case do_initialize(config) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Experiment #{config.experiment_id} init failed: #{inspect(reason)}")
        _ = mark_cancelled(config.experiment_id, "init_failed")
        {:stop, {:init_failed, reason}, config}
    end
  end

  # ── GenServer Calls ──────────────────────────────────────────

  @impl GenServer
  def handle_call(:info, _from, state) when is_struct(state, __MODULE__) do
    info = %{
      experiment_id: state.experiment_id,
      status: state.status,
      iteration: state.iteration,
      max_iterations: state.max_iterations,
      strategy: state.strategy_name,
      human_gate: state.human_gate
    }

    {:reply, {:ok, info}, state}
  end

  # Fallback for :info during initialization (state is still the config map)
  def handle_call(:info, _from, state) do
    {:reply, {:ok, %{status: :initializing}}, state}
  end

  def handle_call({:human_decision, decision}, _from, %{status: :awaiting_human} = state) do
    eval_result = state.pending_eval_result || %{}
    score = Map.get(eval_result, :score)

    # Use agent-only duration captured at task completion, not wall-clock
    # time which would include human wait time.
    duration_ms = state.pending_duration_ms
    run_ref = state.pending_run_ref

    Telemetry.decision_final(
      state.experiment_id,
      state.iteration,
      state.strategy_name,
      Atom.to_string(decision),
      score
    )

    record_iteration(state, iteration_status(decision), eval_result, duration_ms, run_ref)

    state = %{
      state
      | pending_decision: nil,
        pending_eval_result: nil,
        pending_run_ref: nil,
        pending_duration_ms: nil
    }

    # execute_decision returns GenServer tuples — bridge to handle_call format
    case execute_decision(decision, state) do
      {:noreply, new_state} ->
        {:reply, :ok, new_state}

      {:stop, reason, new_state} ->
        {:stop, reason, :ok, new_state}
    end
  end

  def handle_call({:human_decision, _decision}, _from, state) do
    {:reply, {:error, :not_awaiting_human}, state}
  end

  # ── GenServer Casts ──────────────────────────────────────────

  @impl GenServer
  def handle_cast(:graceful_stop, %{status: :running, task_ref: ref} = state)
      when not is_nil(ref) do
    # Iteration in progress — let it finish, then stop
    {:noreply, %{state | status: :stopping}}
  end

  def handle_cast(:graceful_stop, %{status: :awaiting_human} = state) do
    # Waiting for human — treat as halt
    complete_experiment(state, :halted, "graceful_stop")
  end

  def handle_cast(:graceful_stop, state) do
    complete_experiment(state, :halted, "graceful_stop")
  end

  def handle_cast(:user_cancel, state) do
    cancel_and_rollback(state, "user_cancel")
  end

  # ── GenServer Info: Iteration Loop ───────────────────────────

  @impl GenServer

  # Max iterations reached
  def handle_info(:next_iteration, %{iteration: i, max_iterations: max} = state)
      when i >= max do
    complete_experiment(state, :halted, "max_iterations_reached")
  end

  # Graceful stop requested — don't start new iteration
  def handle_info(:next_iteration, %{status: :stopping} = state) do
    complete_experiment(state, :halted, "graceful_stop")
  end

  # Normal iteration start
  def handle_info(:next_iteration, state) do
    iteration = state.iteration + 1
    now = System.monotonic_time(:millisecond)

    Telemetry.iteration_start(state.experiment_id, iteration, state.strategy_name)

    case state.strategy.prepare_iteration(state.strategy_state, iteration, prepare_opts(state)) do
      {:ok, strategy_state} ->
        # Update state with prepared strategy_state so rollback has access
        # to any checkpoint_id stored during preparation.
        state = %{state | strategy_state: strategy_state, iteration: iteration}

        # Notify observers
        hook_data = %{
          experiment_id: state.experiment_id,
          iteration: iteration,
          strategy: state.strategy_name
        }

        broadcast(state.experiment_id, :iteration_started, hook_data)
        fire_hook(:iteration_started, hook_data)

        build_prompt_and_launch(state, iteration, now)

      {:error, reason} ->
        Logger.error(
          "Experiment #{state.experiment_id} iteration #{iteration} prep failed: #{inspect(reason)}"
        )

        cancel_and_rollback(state, "iteration_prep_failed")
    end
  end

  # ── GenServer Info: Task Results ─────────────────────────────

  # Task completed successfully
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    # Capture run_ref before clearing task_ref — record_iteration needs it
    run_ref = inspect(ref)
    handle_task_result(result, %{state | task_ref: nil, task_pid: nil}, run_ref)
  end

  # Task crashed (no result received)
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.warning(
      "Experiment #{state.experiment_id} task crashed at iteration #{state.iteration}: #{inspect(reason)}"
    )

    run_ref = inspect(ref)
    state = %{state | task_ref: nil, task_pid: nil}
    duration_ms = iteration_duration(state)
    record_iteration(state, :failed, %{error: sanitize_error(reason)}, duration_ms, run_ref)
    # cancel_and_rollback handles rollback + telemetry + completion
    cancel_and_rollback(state, "crash")
  end

  # ── GenServer Info: Session Crash ────────────────────────────

  # BeamAgent session died
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_monitor_ref: ref} = state) do
    Logger.warning("Experiment #{state.experiment_id} session crashed: #{inspect(reason)}")
    state = %{state | session_pid: nil, session_monitor_ref: nil}

    # Cancel in-flight task if any — guard on task_pid (the value we pass)
    _ =
      if state.task_pid,
        do: Task.Supervisor.terminate_child(MonkeyClaw.Experiments.TaskSupervisor, state.task_pid)

    state = %{state | task_ref: nil, task_pid: nil}

    state = do_rollback(state)
    complete_experiment(state, :cancelled, "crash")
  end

  # ── GenServer Info: Timer ────────────────────────────────────

  def handle_info(:time_expired, state) do
    Logger.info(
      "Experiment #{state.experiment_id} time budget expired at iteration #{state.iteration}"
    )

    cancel_and_rollback(state, "timeout")
  end

  # Catch-all for unexpected messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── GenServer Terminate ──────────────────────────────────────

  @impl GenServer
  def terminate(_reason, %__MODULE__{} = state) do
    cleanup(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private: Initialization ──────────────────────────────────

  defp do_initialize(config) do
    strategy = config.strategy
    backend = Map.get(config, :backend, @default_backend)

    with :ok <- validate_strategy(strategy),
         {:ok, experiment} <- Experiments.get_experiment(config.experiment_id),
         {:ok, strategy_state} <- strategy.init(experiment, Map.get(config, :opts, %{})),
         {:ok, session_pid} <- start_experiment_session(backend, experiment, config) do
      strategy_name = strategy_to_name(strategy)
      scope = strategy.mutation_scope(experiment)
      monitor_ref = Process.monitor(session_pid)
      mutation_files = Map.get(scope, :files, [])

      persist_status(experiment.id, :running, %{started_at: DateTime.utc_now()})

      state = %__MODULE__{
        experiment_id: experiment.id,
        strategy: strategy,
        strategy_name: strategy_name,
        strategy_state: strategy_state,
        backend: backend,
        session_pid: session_pid,
        session_monitor_ref: monitor_ref,
        config: config,
        status: :running,
        max_iterations: experiment.max_iterations,
        human_gate: Map.get(config, :human_gate, false),
        mutation_scope: mutation_files,
        experiment_start_time: System.monotonic_time(:millisecond)
      }

      # Schedule time budget if configured
      state =
        case experiment.time_budget_ms do
          ms when is_integer(ms) and ms > 0 ->
            timer_ref = Process.send_after(self(), :time_expired, ms)
            %{state | timer_ref: timer_ref}

          _ ->
            state
        end

      # Notify observers
      hook_data = %{
        experiment_id: experiment.id,
        strategy: strategy_name,
        max_iterations: experiment.max_iterations
      }

      broadcast(experiment.id, :experiment_started, hook_data)
      fire_hook(:experiment_started, hook_data)

      # Kick off the first iteration
      send(self(), :next_iteration)

      {:ok, state}
    end
  end

  # M1: Validates that the strategy module is loaded and exports all
  # required behaviour callbacks. Prevents execution of arbitrary modules.
  defp validate_strategy(strategy) when is_atom(strategy) do
    case Code.ensure_loaded(strategy) do
      {:module, ^strategy} ->
        missing =
          Enum.reject(@required_strategy_callbacks, fn {fun, arity} ->
            function_exported?(strategy, fun, arity)
          end)

        case missing do
          [] -> :ok
          _ -> {:error, {:invalid_strategy, strategy, missing_callbacks: missing}}
        end

      {:error, reason} ->
        {:error, {:strategy_not_loaded, strategy, reason}}
    end
  end

  defp validate_strategy(strategy), do: {:error, {:invalid_strategy_type, strategy}}

  # L3: Builds session opts from experiment metadata and user-provided
  # config, then starts the backend session process.
  defp start_experiment_session(backend, experiment, config) do
    session_opts =
      Map.merge(
        %{workspace_id: experiment.workspace_id, experiment_id: experiment.id},
        Map.get(config, :session_opts, %{})
      )

    backend.start_session(session_opts)
  end

  # ── Private: Iteration Launch ────────────────────────────────

  defp build_prompt_and_launch(state, iteration, now) do
    case state.strategy.build_prompt(state.strategy_state, iteration, build_prompt_opts(state)) do
      {:ok, prompt} ->
        # Launch async agent query — NEVER block the GenServer
        task =
          Task.Supervisor.async_nolink(
            MonkeyClaw.Experiments.TaskSupervisor,
            fn -> state.backend.query(state.session_pid, prompt, %{}) end
          )

        persist_status(state.experiment_id, :running, %{iteration_count: iteration})

        {:noreply,
         %{
           state
           | task_ref: task.ref,
             task_pid: task.pid,
             status: :running,
             iteration_start_time: now
         }}

      {:error, reason} ->
        Logger.error(
          "Experiment #{state.experiment_id} iteration #{iteration} build_prompt failed: #{inspect(reason)}"
        )

        cancel_and_rollback(state, "iteration_prep_failed")
    end
  end

  # ── Private: Task Result Processing ──────────────────────────

  defp handle_task_result({:ok, raw_messages}, state, run_ref) do
    duration_ms = iteration_duration(state)

    # Normalize — strategies NEVER see raw BeamAgent output
    run_result = RunResult.normalize(raw_messages, %{duration_ms: duration_ms})

    # H2 scope check → H1 safe evaluate → H1 safe decide
    with :ok <- check_mutation_scope(run_result, state),
         {:ok, eval_result, eval_strategy_state} <- safe_evaluate(state, run_result),
         eval_state = %{state | strategy_state: eval_strategy_state},
         {:ok, auto_decision, decide_strategy_state} <- safe_decide(eval_state, eval_result) do
      score = Map.get(eval_result, :score)

      Telemetry.iteration_evaluate(
        state.experiment_id,
        state.iteration,
        state.strategy_name,
        score,
        duration_ms
      )

      # Capture last eval_result for experiment.result on completion
      state = %{eval_state | strategy_state: decide_strategy_state, last_eval_result: eval_result}

      # Notify observers — iteration evaluation complete
      iter_hook_data = %{
        experiment_id: state.experiment_id,
        iteration: state.iteration,
        strategy: state.strategy_name,
        score: score,
        decision: Atom.to_string(auto_decision),
        duration_ms: duration_ms
      }

      broadcast(state.experiment_id, :iteration_completed, iter_hook_data)
      fire_hook(:iteration_completed, iter_hook_data)

      # Preserve :stopping set by graceful_stop — don't clobber with :evaluating
      eval_status = if state.status == :stopping, do: :stopping, else: :evaluating
      state = %{state | status: eval_status}

      # :stopping is internal-only, not a persisted status — but we must
      # still persist :evaluating when the human gate will follow, so the
      # DB transition running → evaluating → awaiting_human stays valid.
      persist_eval? =
        eval_status == :evaluating or (eval_status == :stopping and state.human_gate)

      if persist_eval?, do: persist_status(state.experiment_id, :evaluating)

      Telemetry.decision_auto(
        state.experiment_id,
        state.iteration,
        state.strategy_name,
        Atom.to_string(auto_decision),
        score
      )

      # Linear pipeline: strategy decides, then optional human override
      if state.human_gate do
        # Block the experiment, NOT the process
        persist_status(state.experiment_id, :awaiting_human)

        # Park iteration metadata so handle_call({:human_decision, ...})
        # can persist accurate run_ref and agent-only duration_ms.
        {:noreply,
         %{
           state
           | status: :awaiting_human,
             pending_decision: auto_decision,
             pending_eval_result: eval_result,
             pending_run_ref: run_ref,
             pending_duration_ms: duration_ms
         }}
      else
        Telemetry.decision_final(
          state.experiment_id,
          state.iteration,
          state.strategy_name,
          Atom.to_string(auto_decision),
          score
        )

        record_iteration(
          state,
          iteration_status(auto_decision),
          eval_result,
          duration_ms,
          run_ref
        )

        execute_decision(auto_decision, state)
      end
    else
      {:error, :scope_violation, out_of_scope} ->
        Logger.warning(
          "Experiment #{state.experiment_id} iteration #{state.iteration} " <>
            "modified out-of-scope files: #{inspect(out_of_scope)}"
        )

        record_iteration(
          state,
          :failed,
          %{error: "mutation_scope_violation", out_of_scope_files: out_of_scope},
          duration_ms,
          run_ref
        )

        cancel_and_rollback(state, "mutation_scope_violation")

      {:error, :strategy_crashed, callback, reason} ->
        Logger.error(
          "Experiment #{state.experiment_id} strategy.#{callback} crashed: #{inspect(reason)}"
        )

        record_iteration(
          state,
          :failed,
          %{error: sanitize_error("strategy.#{callback} crashed: #{inspect(reason)}")},
          duration_ms,
          run_ref
        )

        cancel_and_rollback(state, "strategy_crashed")
    end
  end

  defp handle_task_result({:error, reason}, state, run_ref) do
    Logger.warning(
      "Experiment #{state.experiment_id} query failed at iteration #{state.iteration}: #{inspect(reason)}"
    )

    duration_ms = iteration_duration(state)
    record_iteration(state, :failed, %{error: sanitize_error(reason)}, duration_ms, run_ref)
    cancel_and_rollback(state, "query_failed")
  end

  # ── Private: Strategy Safety Wrappers ─────────────────────────

  # H1: Wraps strategy.evaluate/3 in try/catch to prevent strategy
  # bugs from crashing the Runner GenServer. Catches raise, exit, and throw.
  defp safe_evaluate(state, run_result) do
    case state.strategy.evaluate(state.strategy_state, run_result, strategy_opts(state)) do
      {:ok, eval_result, strategy_state} ->
        {:ok, eval_result, strategy_state}

      other ->
        {:error, :strategy_crashed, :evaluate, {:unexpected_return, other}}
    end
  catch
    kind, reason ->
      {:error, :strategy_crashed, :evaluate, {kind, reason}}
  end

  # H1: Wraps strategy.decide/4 in try/catch to prevent strategy
  # bugs from crashing the Runner GenServer. Catches raise, exit, and throw.
  defp safe_decide(state, eval_result) do
    case state.strategy.decide(
           state.strategy_state,
           eval_result,
           state.iteration,
           strategy_opts(state)
         ) do
      {decision, strategy_state} when decision in [:continue, :accept, :reject, :halt] ->
        {:ok, decision, strategy_state}

      other ->
        {:error, :strategy_crashed, :decide, {:unexpected_return, other}}
    end
  catch
    kind, reason ->
      {:error, :strategy_crashed, :decide, {kind, reason}}
  end

  # H2: Validates that all files changed by the agent are within the
  # experiment's declared mutation scope. Empty scope = no restriction.
  defp check_mutation_scope(_run_result, %{mutation_scope: []}), do: :ok

  defp check_mutation_scope(run_result, state) do
    changed = run_result.files_changed
    allowed = MapSet.new(state.mutation_scope)
    out_of_scope = Enum.reject(changed, &MapSet.member?(allowed, &1))

    case out_of_scope do
      [] -> :ok
      files -> {:error, :scope_violation, files}
    end
  end

  # ── Private: Decision Execution ──────────────────────────────

  defp execute_decision(:continue, state) do
    send(self(), :next_iteration)

    # Preserve :stopping status set by graceful_stop
    status = if state.status == :stopping, do: :stopping, else: :running

    {:noreply, %{state | status: status, pending_decision: nil, pending_eval_result: nil}}
  end

  defp execute_decision(:accept, state) do
    complete_experiment(state, :accepted, termination_reason_for(state))
  end

  defp execute_decision(:reject, state) do
    state = do_rollback(state)
    complete_experiment(state, :rejected, termination_reason_for(state))
  end

  defp execute_decision(:halt, state) do
    complete_experiment(state, :halted, termination_reason_for(state))
  end

  # Derive termination reason from state — preserves "graceful_stop"
  # through the decision pipeline when status is :stopping.
  defp termination_reason_for(%{status: :stopping}), do: "graceful_stop"
  defp termination_reason_for(_state), do: nil

  # ── Private: Rollback ────────────────────────────────────────

  defp do_rollback(state) do
    Telemetry.rollback(state.experiment_id, state.iteration, state.strategy_name)
    best_effort_rollback(state)
  end

  defp best_effort_rollback(%{strategy_state: strategy_state} = state) do
    # Capture checkpoint_id before rollback — strategy.rollback may clear it
    checkpoint_id =
      case strategy_state do
        %{checkpoint_id: id} -> id
        _ -> nil
      end

    state = try_strategy_rollback(state)
    try_checkpoint_rewind(state, checkpoint_id)
    state
  end

  # Strategy-internal cleanup — capture updated state on success,
  # absorb any crash to keep the Runner alive.
  defp try_strategy_rollback(%{strategy: strategy, strategy_state: strategy_state} = state) do
    case strategy.rollback(strategy_state, strategy_opts(state)) do
      {:ok, new_strategy_state} -> %{state | strategy_state: new_strategy_state}
      _other -> state
    end
  catch
    kind, reason ->
      Logger.warning(
        "Experiment #{state.experiment_id} strategy rollback failed: #{inspect({kind, reason})}"
      )

      state
  end

  # Checkpoint rewind (Runner responsibility, strategy-agnostic).
  # Uses pre-rollback checkpoint_id in case strategy cleared it.
  defp try_checkpoint_rewind(_state, nil), do: :ok
  defp try_checkpoint_rewind(%{session_pid: nil}, _checkpoint_id), do: :ok

  defp try_checkpoint_rewind(state, checkpoint_id) do
    case state.backend.checkpoint_rewind(state.session_pid, checkpoint_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Experiment #{state.experiment_id} checkpoint rewind failed: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "Experiment #{state.experiment_id} checkpoint rewind unavailable: #{Exception.message(e)}"
      )
  end

  # ── Private: Cancel ──────────────────────────────────────────

  defp cancel_and_rollback(state, reason) do
    # Kill in-flight task if any
    _ =
      if state.task_pid do
        Task.Supervisor.terminate_child(MonkeyClaw.Experiments.TaskSupervisor, state.task_pid)
      end

    state = %{state | task_ref: nil, task_pid: nil}
    state = do_rollback(state)
    complete_experiment(state, :cancelled, reason)
  end

  # ── Private: Completion ──────────────────────────────────────

  defp complete_experiment(state, terminal_status, termination_reason) do
    now = DateTime.utc_now()

    duration_ms =
      case state do
        %{experiment_start_time: start} when not is_nil(start) ->
          System.monotonic_time(:millisecond) - start

        _ ->
          nil
      end

    Telemetry.completed(
      state.experiment_id,
      state.iteration,
      state.strategy_name,
      Atom.to_string(terminal_status),
      duration_ms
    )

    # Persist final state + result
    attrs = %{
      status: terminal_status,
      completed_at: now,
      state: scrub_secrets(state.strategy_state),
      result: maybe_scrub_secrets(state.last_eval_result),
      iteration_count: state.iteration
    }

    attrs =
      if termination_reason,
        do: Map.put(attrs, :termination_reason, termination_reason),
        else: attrs

    case Experiments.update_experiment(
           Experiments.get_experiment!(state.experiment_id),
           attrs
         ) do
      {:ok, _} ->
        # Only notify observers after successful persist — consumers
        # should not see :experiment_completed if the DB write failed.
        hook_data = %{
          experiment_id: state.experiment_id,
          status: Atom.to_string(terminal_status),
          iteration: state.iteration,
          strategy: state.strategy_name,
          termination_reason: termination_reason,
          duration_ms: duration_ms
        }

        broadcast(state.experiment_id, :experiment_completed, hook_data)
        fire_hook(:experiment_completed, hook_data)

      {:error, reason} ->
        Logger.error("Experiment #{state.experiment_id} final persist failed: #{inspect(reason)}")
    end

    {:stop, :normal, %{state | status: terminal_status}}
  end

  # ── Private: Cleanup ─────────────────────────────────────────

  defp cleanup(state) do
    _ = if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    _ =
      if state.task_pid do
        Task.Supervisor.terminate_child(MonkeyClaw.Experiments.TaskSupervisor, state.task_pid)
      end

    if state.session_pid do
      try do
        state.backend.stop_session(state.session_pid)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ── Private: Persistence Helpers ─────────────────────────────

  # TOCTOU Safety (M4): This fetch-then-update pattern has an inherent
  # time-of-check-to-time-of-use gap. In MonkeyClaw this is safe because:
  #   1. Each experiment has exactly ONE Runner GenServer (enforced by
  #      Registry). All state mutations flow through this single writer.
  #   2. GenServer message processing is sequential — no concurrent
  #      updates within a single Runner.
  # If multi-writer experiments are ever needed, replace with an atomic
  # Ecto update (e.g., Repo.update_all with a WHERE clause).
  defp persist_status(experiment_id, status, extra_attrs \\ %{}) do
    attrs = Map.put(extra_attrs, :status, status)

    case Experiments.update_experiment(Experiments.get_experiment!(experiment_id), attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Experiment #{experiment_id} status persist failed: #{inspect(reason)}")
    end
  end

  defp mark_cancelled(experiment_id, reason) do
    case Experiments.get_experiment(experiment_id) do
      {:ok, experiment} ->
        Experiments.update_experiment(experiment, %{
          status: :cancelled,
          termination_reason: reason,
          completed_at: DateTime.utc_now()
        })

      _ ->
        :ok
    end
  end

  defp record_iteration(state, status_val, eval_result, duration_ms, run_ref) do
    experiment = Experiments.get_experiment!(state.experiment_id)

    attrs = %{
      sequence: state.iteration,
      status: status_val,
      run_ref: run_ref,
      eval_result: scrub_secrets(eval_result),
      state_snapshot: scrub_secrets(state.strategy_state),
      duration_ms: duration_ms,
      metadata: %{strategy: state.strategy_name, human_gate: state.human_gate}
    }

    case Experiments.record_iteration(experiment, attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Experiment #{state.experiment_id} iteration record failed: #{inspect(reason)}"
        )
    end
  end

  # ── Private: Helpers ─────────────────────────────────────────

  defp strategy_opts(state), do: Map.get(state.config, :opts, %{})
  defp strategy_opts(state, extra), do: Map.merge(strategy_opts(state), extra)

  defp prepare_opts(state) do
    # Trust boundary: the backend adapter may raise if checkpoint
    # support is not yet available (e.g., BeamAgent.Checkpoint).
    # Rescue here and degrade to nil — the nil guard on
    # try_checkpoint_rewind/2 skips rewind when no checkpoint exists.
    checkpoint_id =
      try do
        if state.session_pid do
          case state.backend.checkpoint_save(
                 state.session_pid,
                 "iteration-#{state.iteration + 1}"
               ) do
            {:ok, id} -> id
            {:error, _} -> nil
          end
        end
      rescue
        e ->
          Logger.warning(
            "Experiment #{state.experiment_id} checkpoint save unavailable: #{Exception.message(e)}"
          )

          nil
      end

    strategy_opts(state, %{checkpoint_id: checkpoint_id})
  end

  defp build_prompt_opts(state) do
    strategy_opts(state, %{max_iterations: state.max_iterations})
  end

  defp iteration_duration(%{iteration_start_time: start}) when not is_nil(start) do
    System.monotonic_time(:millisecond) - start
  end

  defp iteration_duration(_state), do: nil

  defp iteration_status(:accept), do: :accepted
  defp iteration_status(:reject), do: :rejected
  defp iteration_status(:continue), do: :continued
  defp iteration_status(:halt), do: :halted

  # M2: Truncates error reasons before DB persistence to prevent
  # unbounded data from being stored in SQLite.
  defp sanitize_error(reason) when is_binary(reason) do
    if byte_size(reason) > @max_error_length do
      binary_part(reason, 0, @max_error_length) <> "...[truncated]"
    else
      reason
    end
  end

  defp sanitize_error(reason) do
    reason
    |> inspect(limit: 50, printable_limit: @max_error_length)
    |> sanitize_error()
  end

  # S1: Scrubs secret-like values from strategy state before DB persistence.
  # Defense-in-depth: even if a strategy violates the "no secrets" contract,
  # sensitive values are redacted before reaching SQLite.
  #
  # Scans map keys (atoms and strings) for patterns matching common credential
  # naming conventions. Matched values are replaced with "[REDACTED]".
  # Logs a warning on first detection so strategy authors can fix the violation.
  @secret_patterns ~w(
    secret password passwd token api_key apikey access_key
    private_key credential auth_token bearer signing_key
    client_secret encryption_key
  )

  # Preserves nil (no result) vs empty map (empty result) distinction.
  # Used for experiment.result where nil means "no evaluation ran".
  defp maybe_scrub_secrets(nil), do: nil
  defp maybe_scrub_secrets(value), do: scrub_secrets(value)

  defp scrub_secrets(nil), do: %{}

  defp scrub_secrets(state) when is_map(state) do
    {scrubbed, violations} = do_scrub_secrets(state, [])

    if violations != [] do
      Logger.warning(
        "Strategy state contains secret-like keys #{inspect(violations)}. " <>
          "Values redacted before persistence. " <>
          "Strategies MUST NOT store secrets in state — use vault references instead."
      )
    end

    scrubbed
  end

  defp scrub_secrets(other), do: other

  defp do_scrub_secrets(map, violations) when is_map(map) do
    Enum.reduce(map, {%{}, violations}, fn {key, value}, {acc, viols} ->
      key_str = safe_key_to_string(key)

      if secret_key?(key_str) do
        {Map.put(acc, key, "[REDACTED]"), [key | viols]}
      else
        {scrubbed_value, viols} = do_scrub_secrets(value, viols)
        {Map.put(acc, key, scrubbed_value), viols}
      end
    end)
  end

  defp do_scrub_secrets(list, violations) when is_list(list) do
    Enum.map_reduce(list, violations, fn item, viols ->
      do_scrub_secrets(item, viols)
    end)
  end

  defp do_scrub_secrets(value, violations), do: {value, violations}

  # Only match atom and binary keys for secret detection.
  # Non-stringable keys (tuples, pids, refs) are skipped — defense-in-depth
  # code must never crash the Runner during persistence.
  defp safe_key_to_string(key) when is_atom(key), do: Atom.to_string(key) |> String.downcase()
  defp safe_key_to_string(key) when is_binary(key), do: String.downcase(key)
  defp safe_key_to_string(_key), do: ""

  defp secret_key?(""), do: false

  defp secret_key?(key_str) do
    Enum.any?(@secret_patterns, &String.contains?(key_str, &1))
  end

  defp strategy_to_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.downcase()
  end

  # ── Private: PubSub Broadcasting ────────────────────────────

  # Broadcasts experiment events on `"experiment:#{id}"` topic.
  # PubSub.broadcast/3 returns :ok — it doesn't raise. If PubSub
  # is dead, that's a supervision tree failure, not something
  # the Runner should swallow.
  defp broadcast(experiment_id, event, payload) do
    message = %{event: event, experiment_id: experiment_id, payload: payload}
    _ = Phoenix.PubSub.broadcast(MonkeyClaw.PubSub, "experiment:#{experiment_id}", message)
    :ok
  end

  # ── Private: Extension Hook Firing ──────────────────────────

  # Fires an extension hook through the plug pipeline.
  # Extensions.execute/2 returns {:ok, ctx} | {:error, reason} in
  # normal operation — we log tagged errors. If a plug raises or
  # exits, that crash propagates and takes down the Runner; the
  # DynamicSupervisor handles restart. This is intentional BEAM
  # semantics — no rescue on internal system calls.
  # Skips execution entirely when no plugs are registered.
  defp fire_hook(hook, data) do
    if Extensions.has_plugs?(hook) do
      case Extensions.execute(hook, data) do
        {:ok, _ctx} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Experiment #{data[:experiment_id]} extension hook #{inspect(hook)} failed: " <>
              inspect(reason)
          )

          :ok
      end
    else
      :ok
    end
  end
end
