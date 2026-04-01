defmodule MonkeyClaw.Experiments.Strategy.Code do
  @moduledoc """
  Strategy implementation for code optimization experiments.

  A code experiment starts from a known file state, instructs the
  agent to optimize within a scoped set of files, evaluates the
  result based on test outcomes and observed changes, and decides
  whether to continue iterating, accept, reject, or halt.

  ## Configuration

  The experiment's `config` map must include:

    * `"scoped_files"` — List of file paths the agent may modify
    * `"optimization_goal"` — Description of what to optimize

  Optional config keys:

    * `"accept_threshold"` — Score above which to accept (default: 0.8)
    * `"reject_threshold"` — Score below which to reject (default: 0.2)
    * `"stagnation_window"` — Consecutive non-improving iterations
      before halting (default: 3)

  ## State Shape

  Internal state (opaque to the Runner):

      %{
        __v__: 1,
        scoped_files: [String.t()],
        optimization_goal: String.t(),
        accept_threshold: float(),
        reject_threshold: float(),
        stagnation_window: pos_integer(),
        best_score: float() | nil,
        iteration_scores: [float()],
        checkpoint_id: String.t() | nil
      }

  ## Scoring

  Iteration score is derived from observed agent activity:

    * +0.4 for producing meaningful output
    * +0.3 for modifying files within scope
    * -0.5 penalty for modifying files outside scope
    * +0.3 if output indicates test success

  ## Decision Logic

    * Accept if score >= accept_threshold
    * Reject if score <= reject_threshold
    * Halt if no improvement in `stagnation_window` consecutive iterations
    * Continue otherwise (with best_score tracking)

  ## Rollback

  Clears the current checkpoint_id and removes the last iteration's
  score from the tracking history. The Runner handles the actual
  checkpoint rewind separately.
  """

  @behaviour MonkeyClaw.Experiments.Strategy

  @state_version 1

  @default_accept_threshold 0.8
  @default_reject_threshold 0.2
  @default_stagnation_window 3

  # ── Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(experiment, _opts) do
    config = experiment.config || %{}

    scoped_files = Map.get(config, "scoped_files", [])
    optimization_goal = Map.get(config, "optimization_goal", "general optimization")

    if scoped_files == [] do
      {:error, :no_scoped_files}
    else
      state = %{
        __v__: @state_version,
        scoped_files: scoped_files,
        optimization_goal: optimization_goal,
        accept_threshold: parse_threshold(config, "accept_threshold", @default_accept_threshold),
        reject_threshold: parse_threshold(config, "reject_threshold", @default_reject_threshold),
        stagnation_window:
          parse_positive_int(config, "stagnation_window", @default_stagnation_window),
        best_score: nil,
        iteration_scores: [],
        checkpoint_id: nil
      }

      {:ok, state}
    end
  end

  @impl true
  def prepare_iteration(state, _iteration, opts) do
    # Store checkpoint_id if the Runner provided one.
    checkpoint_id = Map.get(opts, :checkpoint_id)
    {:ok, %{state | checkpoint_id: checkpoint_id}}
  end

  @impl true
  def build_prompt(state, iteration, opts) do
    max_iterations = Map.get(opts, :max_iterations, "unknown")
    files_list = Enum.join(state.scoped_files, "\n  - ")

    best_score_info =
      case state.best_score do
        nil -> "No previous iterations."
        score -> "Previous best score: #{Float.round(score, 3)}."
      end

    prompt = """
    You are running iteration #{iteration} of #{max_iterations} in a code optimization experiment.

    ## Goal
    #{state.optimization_goal}

    ## Files in Scope
    You may ONLY modify these files:
      - #{files_list}

    ## Current State
    #{best_score_info}

    ## Instructions
    1. Read and analyze the target files listed above.
    2. Make focused improvements toward the optimization goal.
    3. Run the test suite to verify your changes don't break anything.
    4. Summarize what you changed and why.

    ## Constraints
    - Only modify files listed in "Files in Scope" above.
    - All existing tests must continue to pass after your changes.
    - Focus on measurable improvements, not cosmetic changes.
    - If you cannot improve further, say so explicitly.
    """

    {:ok, String.trim(prompt)}
  end

  @impl true
  def evaluate(state, run_result, _opts) do
    score = calculate_score(state, run_result)

    eval_result = %{
      score: score,
      files_changed: run_result.files_changed,
      in_scope: files_in_scope?(state.scoped_files, run_result.files_changed),
      has_output: byte_size(run_result.output || "") > 0,
      tool_call_count: length(run_result.tool_calls)
    }

    updated_state = %{state | iteration_scores: state.iteration_scores ++ [score]}
    {:ok, eval_result, updated_state}
  end

  @impl true
  def decide(state, eval_result, _iteration, _opts) do
    score = eval_result.score

    cond do
      score >= state.accept_threshold ->
        {:accept, %{state | best_score: safe_max(state.best_score, score)}}

      score <= state.reject_threshold ->
        {:reject, state}

      stagnating?(state) ->
        {:halt, state}

      true ->
        {:continue, %{state | best_score: safe_max(state.best_score, score)}}
    end
  end

  @impl true
  def rollback(state, _opts) do
    # Remove the last iteration's score (it was rejected/rolled back).
    # Clear the checkpoint_id — the Runner handles the actual rewind.
    updated_scores =
      case state.iteration_scores do
        [] -> []
        scores -> Enum.drop(scores, -1)
      end

    {:ok, %{state | iteration_scores: updated_scores, checkpoint_id: nil}}
  end

  @impl true
  def mutation_scope(experiment) do
    files = get_in(experiment.config, ["scoped_files"]) || []
    %{files: files}
  end

  # ── Scoring ──────────────────────────────────────────────────

  defp calculate_score(state, run_result) do
    output_score = if has_meaningful_output?(run_result.output), do: 0.4, else: 0.0

    scope_score =
      cond do
        run_result.files_changed == [] ->
          0.0

        files_in_scope?(state.scoped_files, run_result.files_changed) ->
          0.3

        true ->
          # Files changed outside scope — penalty
          -0.5
      end

    test_score = if output_indicates_success?(run_result.output), do: 0.3, else: 0.0

    # Clamp to [0.0, 1.0]
    (output_score + scope_score + test_score)
    |> max(0.0)
    |> min(1.0)
  end

  defp has_meaningful_output?(nil), do: false
  defp has_meaningful_output?(output) when is_binary(output), do: byte_size(output) > 20
  defp has_meaningful_output?(_), do: false

  defp files_in_scope?(scoped_files, changed_files) do
    scoped_set = MapSet.new(scoped_files)
    Enum.all?(changed_files, &MapSet.member?(scoped_set, &1))
  end

  defp output_indicates_success?(nil), do: false

  defp output_indicates_success?(output) when is_binary(output) do
    normalized = String.downcase(output)

    Enum.any?(
      ["tests pass", "all tests pass", "test suite pass", "0 failures", "success"],
      &String.contains?(normalized, &1)
    )
  end

  defp output_indicates_success?(_), do: false

  # ── Stagnation Detection ─────────────────────────────────────

  defp stagnating?(state) do
    window = state.stagnation_window
    scores = state.iteration_scores

    if length(scores) < window do
      false
    else
      recent = Enum.take(scores, -window)
      best = state.best_score || 0.0
      Enum.all?(recent, &(&1 <= best))
    end
  end

  # max/2 with nil is unsafe — atoms > numbers in Erlang term ordering
  defp safe_max(nil, score), do: score
  defp safe_max(best, score), do: max(best, score)

  # ── Config Parsing ───────────────────────────────────────────

  defp parse_threshold(config, key, default) do
    case Map.get(config, key) do
      val when is_float(val) and val >= 0.0 and val <= 1.0 -> val
      val when is_integer(val) and val >= 0 and val <= 1 -> val / 1
      _ -> default
    end
  end

  defp parse_positive_int(config, key, default) do
    case Map.get(config, key) do
      val when is_integer(val) and val > 0 -> val
      _ -> default
    end
  end
end
