defmodule MonkeyClaw.Skills.Extractor do
  @moduledoc """
  Extracts reusable skill procedures from successful experiments.

  Given an `:accepted` experiment preloaded with its iterations,
  produces a map of skill attributes suitable for creating a new
  `MonkeyClaw.Skills.Skill` record.

  ## Extraction Strategy

  The extractor examines the final iteration's `eval_result` and
  `state_snapshot` to derive:

    * **Title** — From the experiment title, prefixed with the type
    * **Description** — From the experiment's config or eval_result summary
    * **Procedure** — Step-by-step from the final iteration's state_snapshot
    * **Tags** — Derived from experiment type and config

  ## Design

  This is NOT a process. All functions are pure — they take data
  in and return extracted skill attributes out. No side effects,
  no I/O, no database access.
  """

  alias MonkeyClaw.Experiments.Experiment
  alias MonkeyClaw.Experiments.Iteration

  @doc """
  Extract skill attributes from an accepted experiment.

  The experiment must be preloaded with iterations (sorted by
  sequence DESC — most recent first). Returns extracted skill
  attributes or an error.

  ## Return Values

    * `{:ok, attrs}` — Successfully extracted skill attributes
    * `{:error, :not_accepted}` — Experiment is not in `:accepted` status
    * `{:error, :no_iterations}` — Experiment has no iterations

  ## Examples

      experiment = Repo.preload(experiment, iterations: from(i in Iteration, order_by: [desc: i.sequence]))
      {:ok, attrs} = Extractor.extract_from_experiment(experiment)
      attrs
      #=> %{
      #=>   title: "Code: Optimize parser",
      #=>   description: "Procedure extracted from successful experiment...",
      #=>   procedure: "1. Profile with :fprof\\n2. Identify hot paths...",
      #=>   tags: ["code", "extracted"]
      #=> }

  """
  @spec extract_from_experiment(Experiment.t()) ::
          {:ok,
           %{
             title: String.t(),
             description: String.t(),
             procedure: String.t(),
             tags: [String.t()]
           }}
          | {:error, :not_accepted | :no_iterations}
  def extract_from_experiment(%Experiment{} = experiment) do
    with :ok <- validate_accepted(experiment),
         :ok <- validate_iterations(experiment) do
      iteration = final_iteration(experiment.iterations)

      attrs = %{
        title: build_title(experiment),
        description: build_description(experiment, iteration),
        procedure: build_procedure(iteration),
        tags: build_tags(experiment)
      }

      {:ok, attrs}
    end
  end

  defp validate_accepted(%Experiment{status: :accepted}), do: :ok
  defp validate_accepted(%Experiment{}), do: {:error, :not_accepted}

  defp validate_iterations(%Experiment{iterations: iterations})
       when is_list(iterations) and iterations != [],
       do: :ok

  defp validate_iterations(%Experiment{}), do: {:error, :no_iterations}

  defp build_title(%Experiment{} = experiment) do
    label = experiment_type_label(experiment.type)
    "#{label}: #{experiment.title}" |> String.slice(0, 200)
  end

  defp experiment_type_label(:code), do: "Code"
  defp experiment_type_label(:research), do: "Research"
  defp experiment_type_label(:prompt), do: "Prompt"

  defp experiment_type_label(type),
    do: type |> to_string() |> String.capitalize()

  # Get the final iteration (highest sequence number).
  defp final_iteration(iterations) when is_list(iterations) and iterations != [] do
    Enum.max_by(iterations, & &1.sequence)
  end

  # Build description from experiment context.
  defp build_description(%Experiment{} = experiment, %Iteration{} = iteration) do
    base = "Procedure extracted from #{experiment_type_label(experiment.type)} experiment"

    summary =
      case iteration.eval_result do
        %{"summary" => s} when is_binary(s) -> ": #{s}"
        %{"score" => score} -> " (final score: #{score})"
        _ -> ""
      end

    goal =
      case experiment.config do
        %{"optimization_goal" => g} when is_binary(g) -> ". Goal: #{g}"
        _ -> ""
      end

    "#{base}#{summary}#{goal}"
  end

  # Build procedure text from iteration state_snapshot and eval_result.
  defp build_procedure(%Iteration{} = iteration) do
    cond do
      # Prefer explicit steps/procedure in state_snapshot
      is_binary(get_in(iteration.state_snapshot, ["procedure"])) ->
        iteration.state_snapshot["procedure"]

      is_list(get_in(iteration.state_snapshot, ["steps"])) ->
        iteration.state_snapshot["steps"]
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {step, idx} -> "#{idx}. #{safe_to_string(step)}" end)

      is_list(get_in(iteration.state_snapshot, ["actions"])) ->
        iteration.state_snapshot["actions"]
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {action, idx} -> "#{idx}. #{safe_to_string(action)}" end)

      # Fall back to eval_result details
      is_binary(get_in(iteration.eval_result, ["details"])) ->
        iteration.eval_result["details"]

      # Last resort: summarize what we have
      true ->
        build_fallback_procedure(iteration)
    end
  end

  defp build_fallback_procedure(%Iteration{} = iteration) do
    parts = []

    parts =
      case iteration.eval_result do
        %{"score" => score} -> ["Final evaluation score: #{score}" | parts]
        _ -> parts
      end

    parts =
      case iteration.state_snapshot do
        snapshot when map_size(snapshot) > 0 ->
          keys = snapshot |> Map.keys() |> Enum.join(", ")
          ["State tracked: #{keys}" | parts]

        _ ->
          parts
      end

    case parts do
      [] -> "Experiment completed successfully. Review experiment details for procedure."
      _ -> parts |> Enum.reverse() |> Enum.join("\n")
    end
  end

  # Safely convert a value to a string. Binaries pass through,
  # non-binaries (maps, lists, etc.) are inspected to avoid
  # Protocol.UndefinedError from string interpolation.
  defp safe_to_string(val) when is_binary(val), do: val
  defp safe_to_string(val), do: inspect(val)

  # Build tags from experiment type and config.
  defp build_tags(%Experiment{} = experiment) do
    base = [to_string(experiment.type), "extracted"]

    config_tags =
      case experiment.config do
        %{"tags" => tags} when is_list(tags) -> Enum.filter(tags, &is_binary/1)
        _ -> []
      end

    (base ++ config_tags) |> Enum.uniq()
  end
end
