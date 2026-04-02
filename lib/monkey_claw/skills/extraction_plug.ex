defmodule MonkeyClaw.Skills.ExtractionPlug do
  @moduledoc """
  Extension plug that auto-extracts skills from accepted experiments.

  When registered on the `:experiment_completed` hook, this plug
  checks if the completed experiment was accepted, and if so,
  extracts a reusable skill procedure from its final iteration
  and persists it to the workspace's skill library.

  ## How It Works

  1. Receives an `:experiment_completed` context with experiment data
  2. Checks if the experiment status is `:accepted`
  3. Preloads the experiment's iterations (sorted by sequence DESC)
  4. Calls `Extractor.extract_from_experiment/1` to derive skill attributes
  5. On success, calls `Skills.create_skill/2` to persist the skill
  6. Logs extraction outcomes via Logger

  ## Configuration

  Register in application config:

      config :monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          experiment_completed: [
            {MonkeyClaw.Skills.ExtractionPlug, []}
          ]
        }

  ## Design

  This is NOT a process. It implements `MonkeyClaw.Extensions.Plug`
  and runs inline with the extension pipeline. Extraction failures
  are logged but never halt the pipeline — skill extraction is
  best-effort.
  """

  @behaviour MonkeyClaw.Extensions.Plug

  require Logger

  import Ecto.Query

  alias MonkeyClaw.Experiments.Iteration
  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Skills
  alias MonkeyClaw.Skills.Extractor

  @doc """
  Initialize the extraction plug.

  No configuration required. Options are accepted for
  compatibility with the plug interface.
  """
  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts) when is_list(opts), do: opts

  @doc """
  Extract a skill from a completed experiment.

  Only processes `:experiment_completed` events where the
  experiment has `:accepted` status. Non-accepted experiments
  and non-experiment events pass through unchanged.

  Extraction failures are logged but never halt the pipeline.
  """
  @impl true
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{event: :experiment_completed} = ctx, _opts) do
    experiment = ctx.data[:experiment] || ctx.data["experiment"]

    case experiment do
      %{status: :accepted, workspace_id: workspace_id} when is_binary(workspace_id) ->
        attempt_extraction(ctx, experiment, workspace_id)

      %{status: status} when status != :accepted ->
        Logger.debug("Skipping skill extraction for non-accepted experiment (status: #{status})")
        ctx

      _ ->
        Logger.debug("Skipping skill extraction: no experiment in context data")
        ctx
    end
  end

  # Pass through non-experiment_completed events unchanged.
  def call(ctx, _opts), do: ctx

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  @spec attempt_extraction(Context.t(), map(), String.t()) :: Context.t()
  defp attempt_extraction(ctx, experiment, workspace_id) do
    experiment =
      Repo.preload(experiment, iterations: from(i in Iteration, order_by: [desc: i.sequence]))

    case Extractor.extract_from_experiment(experiment) do
      {:ok, attrs} ->
        create_skill_from_extraction(ctx, workspace_id, experiment, attrs)

      {:error, reason} ->
        Logger.info("Skill extraction skipped for experiment #{experiment.id}: #{reason}")
        ctx
    end
  end

  @spec create_skill_from_extraction(Context.t(), String.t(), map(), map()) :: Context.t()
  defp create_skill_from_extraction(ctx, workspace_id, experiment, attrs) do
    case Repo.get(MonkeyClaw.Workspaces.Workspace, workspace_id) do
      nil ->
        Logger.warning("Skill extraction failed: workspace #{workspace_id} not found")
        ctx

      workspace ->
        skill_attrs = Map.put(attrs, :source_experiment_id, experiment.id)

        case Skills.create_skill(workspace, skill_attrs) do
          {:ok, skill} ->
            Logger.info("Extracted skill '#{skill.title}' from experiment #{experiment.id}")
            Context.assign(ctx, :extracted_skill, skill)

          {:error, changeset} ->
            Logger.warning(
              "Skill extraction failed for experiment #{experiment.id}: " <>
                "#{inspect(changeset.errors)}"
            )

            ctx
        end
    end
  end
end
