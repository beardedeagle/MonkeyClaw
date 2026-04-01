defmodule MonkeyClaw.Experiments.Strategy do
  @moduledoc """
  Behaviour defining the contract for experiment strategies.

  A strategy encapsulates all domain-specific logic for a particular
  experiment type. The Runner GenServer drives the iteration loop
  and calls strategy callbacks at each stage — but NEVER interprets
  the strategy's internal state (it's an opaque map).

  ## The Seven Callbacks

    * `init/2` — Initialize strategy state from experiment config
    * `prepare_iteration/3` — Per-iteration setup (checkpointing, etc.)
    * `build_prompt/3` — Generate the agent prompt for this iteration
    * `evaluate/3` — Judge the normalized run result
    * `decide/4` — Decide what to do next (continue, accept, reject, halt)
    * `rollback/2` — Revert the most recent unaccepted mutation
    * `mutation_scope/1` — Define what the agent is allowed to touch

  ## Three-Layer Ownership

  | Layer        | Owns                                                    |
  |--------------|---------------------------------------------------------|
  | **Strategy** | Domain: state shape, prompts, evaluation, rollback, decisions |
  | **Runner**   | Control: iteration loop, time budget, persistence, human gate |
  | **BeamAgent**| Execution: runs, tools, hooks, memory, checkpoints     |

  ## Boundary Rules

  These boundaries are enforced without exception:

    * Strategy NEVER touches Runner internals
    * Strategy NEVER sees raw BeamAgent output (only normalized `run_result`)
    * Runner NEVER contains domain-specific evaluation or prompt logic
    * Runner NEVER interprets strategy state (opaque map, just persists)
    * BeamAgent is called through the Backend behaviour, NEVER directly

  ## Implementing a Strategy

  Implement all 7 callbacks. The `state` parameter is your domain —
  store whatever you need. The Runner will persist it but never read it.

      defmodule MyStrategy do
        @behaviour MonkeyClaw.Experiments.Strategy

        @impl true
        def init(experiment, _opts) do
          {:ok, %{__v__: 1, my_data: experiment.config["my_key"]}}
        end

        # ... remaining callbacks
      end

  ## State Versioning

  Use the `__v__` key inside your state map for strategy-local
  compatibility. When your state shape changes, bump `__v__` and
  handle migration in `init/2` or `prepare_iteration/3`.

  ## Security

  Strategy state is persisted to the database at experiment completion and
  in each iteration snapshot. Implementations MUST NOT store secrets,
  credentials, API keys, or other sensitive values in the state map.

  If external credentials are needed, store a reference (e.g., a vault
  key or config path) rather than the credential itself.
  """

  alias MonkeyClaw.Experiments.Experiment

  @typedoc """
  Opaque strategy state — owned entirely by the strategy.

  The Runner persists this as a JSON map but never reads or
  interprets its contents.
  """
  @type state :: map()

  @typedoc """
  The iteration sequence number (1-based).
  """
  @type iteration :: pos_integer()

  @typedoc """
  Normalized run result from agent execution.

  Strategies NEVER see raw BeamAgent output — only this normalized
  form. This prevents beam-agent internals from leaking into domain
  logic.
  """
  @type run_result :: %{
          output: term(),
          tool_calls: [map()],
          files_changed: [String.t()],
          metadata: map()
        }

  @typedoc """
  Evaluation result produced by `evaluate/3`.

  Must be serializable (stored in experiment_iterations.eval_result
  as JSON). Contains domain-specific evaluation data.
  """
  @type eval_result :: map()

  @typedoc """
  Strategy options passed through from the Runner config.
  """
  @type opts :: map()

  @typedoc """
  Decision returned by `decide/4`.
  """
  @type decision :: :continue | :accept | :reject | :halt

  # ── Callbacks ──────────────────────────────────────────────────

  @doc """
  Initialize strategy state from experiment configuration.

  Called once when the Runner starts. Extract what you need from
  `experiment.config` and return your initial state.

  Return `{:error, reason}` to abort experiment startup.
  """
  @callback init(experiment :: Experiment.t(), opts()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Per-iteration setup before the agent runs.

  Called at the start of each iteration. Use this for checkpoint
  preparation, counter updates, or any pre-mutation bookkeeping.

  The `opts` map may contain `:checkpoint_id` if the Runner
  successfully saved a checkpoint before this iteration.

  Return `{:error, reason}` to abort the current iteration's
  preparation phase.
  """
  @callback prepare_iteration(state(), iteration(), opts()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Generate the agent prompt for this iteration.

  Strategy-owned prompt generation. Different experiment types need
  fundamentally different agent instructions — code experiments
  prompt for optimization, research experiments prompt for
  information gathering.

  Return `{:error, reason}` to abort the current iteration.
  """
  @callback build_prompt(state(), iteration(), opts()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Evaluate the normalized run result.

  Judge the agent's output and return an eval_result (stored in the
  iteration record) plus updated state. The eval_result must be
  JSON-serializable.
  """
  @callback evaluate(state(), run_result(), opts()) ::
              {:ok, eval_result(), state()}

  @doc """
  Decide what to do next based on the evaluation.

  Strategy owns the decision logic: "improve over previous",
  "stop on diminishing returns", "accept above threshold", etc.

  Decisions:
    * `:continue` — Run another iteration
    * `:accept` — Accept the current result as the winner
    * `:reject` — Reject and rollback the current mutation
    * `:halt` — Stop without accepting (inconclusive)
  """
  @callback decide(state(), eval_result(), iteration(), opts()) ::
              {:continue, state()}
              | {:accept, state()}
              | {:reject, state()}
              | {:halt, state()}

  @doc """
  Revert the most recent unaccepted mutation.

  Called when the strategy decides to reject, or when the Runner
  needs to clean up (timeout, crash, cancellation).

  **Critical safety rule:** Rollback MUST NEVER invalidate an
  already-accepted experiment result. It applies only to the
  current tentative mutation, not the "best accepted state."

  The Runner handles checkpoint rewind separately — this callback
  is for strategy-internal state cleanup only.
  """
  @callback rollback(state(), opts()) :: {:ok, state()}

  @doc """
  Define what the agent is allowed to touch.

  Returns a map describing the mutation scope. For code experiments,
  this is typically `%{files: ["lib/parser.ex", ...]}`. The Runner
  uses this to configure agent session permissions.
  """
  @callback mutation_scope(experiment :: Experiment.t()) :: map()
end
