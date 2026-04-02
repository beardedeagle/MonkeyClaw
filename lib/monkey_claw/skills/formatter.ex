defmodule MonkeyClaw.Skills.Formatter do
  @moduledoc """
  Formats skill records into injectable context blocks.

  Takes a list of `Skill` structs and formats them into a
  human-readable text block suitable for prepending to an agent
  prompt. Skills are formatted with title, tags, and procedure,
  truncated to a character budget.

  ## Output Format

      [Relevant skills from your library]

      --- Skill: Optimize Parser Performance ---
      Tags: code, optimization
      Procedure:
      1. Profile the parser with :fprof
      2. Identify hot paths...

      --- Skill: Deploy to Production ---
      Tags: deployment, ops
      Procedure:
      1. Run test suite...

  ## Design

  This is NOT a process. All functions are pure — they take data
  in and return formatted data out. No side effects, no I/O.
  """

  alias MonkeyClaw.Skills.Skill

  @type format_result :: %{text: String.t(), truncated: boolean()}

  @header "[Relevant skills from your library]\n\n"
  @skill_separator "\n\n"
  @max_procedure_length 500

  @doc """
  Format a list of skills into an injectable context block.

  Builds a text block per skill with title, tags, and procedure.
  Concatenates blocks up to `max_chars`. Returns the formatted
  text and whether any content was truncated.

  Returns empty text with `truncated: false` for an empty list.

  ## Parameters

    * `skills` — List of `Skill` structs
    * `max_chars` — Maximum character budget for the output

  ## Examples

      %{text: text, truncated: false} = Formatter.format(skills, 2000)
  """
  @spec format([Skill.t()], pos_integer()) :: format_result()
  def format([], _max_chars), do: %{text: "", truncated: false}

  def format(skills, max_chars)
      when is_list(skills) and is_integer(max_chars) and max_chars > 0 do
    budget = max_chars - String.length(@header)

    if budget <= 0 do
      %{text: "", truncated: true}
    else
      {blocks, truncated} = build_blocks(skills, budget)

      text =
        case blocks do
          [] -> ""
          _ -> @header <> Enum.join(blocks, @skill_separator)
        end

      %{text: text, truncated: truncated}
    end
  end

  # Build blocks for each skill, tracking character budget.
  # Stops when budget exhausted. Returns {blocks, truncated}.
  @spec build_blocks([Skill.t()], non_neg_integer()) :: {[String.t()], boolean()}
  defp build_blocks(skills, budget) do
    skills
    |> Enum.reduce({[], budget, false}, fn skill, {acc, remaining, trunc} ->
      block = format_skill_block(skill)
      # Only charge separator cost between blocks, not for the first.
      separator_cost = if acc == [], do: 0, else: String.length(@skill_separator)
      block_size = String.length(block) + separator_cost

      if block_size <= remaining do
        {[block | acc], remaining - block_size, trunc}
      else
        {acc, remaining, true}
      end
    end)
    |> then(fn {blocks, _remaining, truncated} -> {Enum.reverse(blocks), truncated} end)
  end

  # Format a single skill as a text block.
  @spec format_skill_block(Skill.t()) :: String.t()
  defp format_skill_block(%Skill{} = skill) do
    title_line = "--- Skill: #{skill.title} ---"

    tags_line =
      case skill.tags do
        tags when is_list(tags) and tags != [] -> "Tags: #{Enum.join(tags, ", ")}"
        _ -> nil
      end

    procedure_line = "Procedure:\n#{truncate_procedure(skill.procedure)}"

    [title_line, tags_line, procedure_line]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @spec truncate_procedure(String.t() | nil) :: String.t()
  defp truncate_procedure(nil), do: "[no procedure]"

  defp truncate_procedure(procedure) when is_binary(procedure) do
    if String.length(procedure) <= @max_procedure_length do
      procedure
    else
      String.slice(procedure, 0, @max_procedure_length) <> "..."
    end
  end
end
