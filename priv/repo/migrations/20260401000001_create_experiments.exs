defmodule MonkeyClaw.Repo.Migrations.CreateExperiments do
  @moduledoc """
  Creates the experiment and experiment iteration tables.

  ## Tables

    * `experiments` — Top-level experiment records with configuration,
      opaque strategy state, and lifecycle metadata.

    * `experiment_iterations` — Immutable records of each iteration
      within an experiment, including evaluation results and state
      snapshots for observability and debugging.

  Both tables use `STRICT` mode for type enforcement at the storage
  layer and `binary_id` primary keys for consistency with the rest
  of the MonkeyClaw schema.

  ## Status Lifecycles

    * Experiment: created → running → evaluating → awaiting_human →
      accepted | rejected | cancelled | halted
    * Iteration: running → evaluating → accepted | rejected | failed

  ## State Versioning

  The `state_version` field on experiments enables migration routing
  when loading old experiments. Strategy-local compatibility is handled
  separately via a `__v__` key inside the opaque state payload.
  """

  use Ecto.Migration

  def change do
    create table(:experiments, primary_key: false, options: "STRICT") do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :type, :string, null: false
      add :status, :string, null: false, default: "created"

      # Strategy configuration — immutable after creation.
      # Stored as JSON text; Ecto handles serialization.
      add :config, :text, null: false, default: "{}"

      # Opaque strategy state — only the strategy reads/writes this.
      # The Runner persists it but never interprets it.
      # Nullable: nil before strategy.init runs.
      add :state, :text

      # Schema-level version for migration routing when loading
      # old experiments. Distinct from the strategy-local __v__
      # inside the state payload.
      add :state_version, :integer, null: false, default: 1

      # Final result summary — nullable until experiment completes.
      add :result, :text

      # Iteration tracking
      add :iteration_count, :integer, null: false, default: 0
      add :max_iterations, :integer, null: false

      # Time budget in milliseconds — nullable means no time limit.
      add :time_budget_ms, :integer

      # Lifecycle timestamps
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      # Why the experiment terminated — nil while running.
      # Values: "timeout" | "user_cancel" | "crash" | "graceful_stop"
      add :termination_reason, :string

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:experiments, [:workspace_id])
    create index(:experiments, [:status])
    create index(:experiments, [:type])

    create table(:experiment_iterations, primary_key: false, options: "STRICT") do
      add :id, :binary_id, primary_key: true

      # Monotonically increasing within the experiment (1-based).
      add :sequence, :integer, null: false

      add :status, :string, null: false

      # Opaque reference linking this iteration to the async task
      # that executed it. Useful for debugging and correlation.
      add :run_ref, :string

      # Strategy evaluation output — serialized as JSON.
      add :eval_result, :text, null: false, default: "{}"

      # Snapshot of strategy state at this iteration — for
      # observability and debugging. Serialized as JSON.
      add :state_snapshot, :text, null: false, default: "{}"

      # Wall-clock duration of this iteration in milliseconds.
      add :duration_ms, :integer

      # Arbitrary metadata (timing, model info, etc.)
      add :metadata, :text, null: false, default: "{}"

      add :experiment_id,
          references(:experiments, type: :binary_id, on_delete: :delete_all),
          null: false

      # Iterations are immutable records — no updated_at needed.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:experiment_iterations, [:experiment_id])
    create unique_index(:experiment_iterations, [:experiment_id, :sequence])
    create index(:experiment_iterations, [:status])
  end
end
