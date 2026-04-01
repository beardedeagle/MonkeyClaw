defmodule MonkeyClaw.Experiments.Telemetry do
  @moduledoc """
  Telemetry event emission for the experiment subsystem.

  All experiment telemetry events use a standardized metadata shape
  for consistent observability. Fields are nil when not yet available
  (e.g., `:iteration_start` has no decision or score yet).

  ## Events

      [:monkey_claw, :experiment, :iteration, :start]
      [:monkey_claw, :experiment, :iteration, :evaluate]
      [:monkey_claw, :experiment, :decision, :auto]
      [:monkey_claw, :experiment, :decision, :final]
      [:monkey_claw, :experiment, :rollback]
      [:monkey_claw, :experiment, :completed]

  ## Metadata Shape

  Every event carries the same shape:

      %{
        experiment_id: String.t(),
        iteration: non_neg_integer(),
        strategy: String.t(),
        decision: String.t() | nil,
        score: float() | nil,
        duration_ms: non_neg_integer() | nil
      }

  Consistent shape means dashboards are trivial to build later —
  no per-event parsing required.

  ## Design

  This is NOT a process. Pure function calls that delegate to
  `:telemetry.execute/3`. Safe for concurrent use.
  """

  @typedoc "Standardized metadata for all experiment telemetry events."
  @type metadata :: %{
          experiment_id: String.t(),
          iteration: non_neg_integer(),
          strategy: String.t(),
          decision: String.t() | nil,
          score: float() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @doc """
  Emit `[:monkey_claw, :experiment, :iteration, :start]`.

  Called at the beginning of each iteration before the agent runs.
  """
  @spec iteration_start(String.t(), non_neg_integer(), String.t()) :: :ok
  def iteration_start(experiment_id, iteration, strategy) do
    execute(
      [:monkey_claw, :experiment, :iteration, :start],
      %{system_time: System.system_time()},
      base_metadata(experiment_id, iteration, strategy)
    )
  end

  @doc """
  Emit `[:monkey_claw, :experiment, :iteration, :evaluate]`.

  Called after the strategy evaluates the run result.
  """
  @spec iteration_evaluate(
          String.t(),
          non_neg_integer(),
          String.t(),
          float() | nil,
          non_neg_integer() | nil
        ) ::
          :ok
  def iteration_evaluate(experiment_id, iteration, strategy, score, duration_ms) do
    execute(
      [:monkey_claw, :experiment, :iteration, :evaluate],
      %{system_time: System.system_time()},
      base_metadata(experiment_id, iteration, strategy)
      |> Map.merge(%{score: score, duration_ms: duration_ms})
    )
  end

  @doc """
  Emit `[:monkey_claw, :experiment, :decision, :auto]`.

  Called when the strategy makes its automated decision.
  """
  @spec decision_auto(String.t(), non_neg_integer(), String.t(), String.t(), float() | nil) :: :ok
  def decision_auto(experiment_id, iteration, strategy, decision, score) do
    execute(
      [:monkey_claw, :experiment, :decision, :auto],
      %{system_time: System.system_time()},
      base_metadata(experiment_id, iteration, strategy)
      |> Map.merge(%{decision: decision, score: score})
    )
  end

  @doc """
  Emit `[:monkey_claw, :experiment, :decision, :final]`.

  Called after human override (if any). This is the decision
  that actually gets executed.
  """
  @spec decision_final(String.t(), non_neg_integer(), String.t(), String.t(), float() | nil) ::
          :ok
  def decision_final(experiment_id, iteration, strategy, decision, score) do
    execute(
      [:monkey_claw, :experiment, :decision, :final],
      %{system_time: System.system_time()},
      base_metadata(experiment_id, iteration, strategy)
      |> Map.merge(%{decision: decision, score: score})
    )
  end

  @doc """
  Emit `[:monkey_claw, :experiment, :rollback]`.

  Called when a rollback is triggered (reject, timeout, crash).
  """
  @spec rollback(String.t(), non_neg_integer(), String.t()) :: :ok
  def rollback(experiment_id, iteration, strategy) do
    execute(
      [:monkey_claw, :experiment, :rollback],
      %{system_time: System.system_time()},
      base_metadata(experiment_id, iteration, strategy)
    )
  end

  @doc """
  Emit `[:monkey_claw, :experiment, :completed]`.

  Called when the experiment reaches a terminal state.
  """
  @spec completed(String.t(), non_neg_integer(), String.t(), String.t(), non_neg_integer() | nil) ::
          :ok
  def completed(experiment_id, iteration, strategy, decision, duration_ms) do
    execute(
      [:monkey_claw, :experiment, :completed],
      %{system_time: System.system_time()},
      base_metadata(experiment_id, iteration, strategy)
      |> Map.merge(%{decision: decision, duration_ms: duration_ms})
    )
  end

  # ── Private ──────────────────────────────────────────────────

  defp base_metadata(experiment_id, iteration, strategy) do
    %{
      experiment_id: experiment_id,
      iteration: iteration,
      strategy: strategy,
      decision: nil,
      score: nil,
      duration_ms: nil
    }
  end

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
