defmodule MonkeyClaw.Skills.Plug do
  @moduledoc """
  Extension plug that injects relevant skills into agent queries.

  When registered on the `:query_pre` hook, this plug searches the
  workspace skill library for procedures relevant to the current
  prompt and prepends them to the effective prompt.

  ## Composition with Recall.Plug

  When both Skills.Plug and Recall.Plug are registered on
  `:query_pre`, they compose by layering onto `:effective_prompt`:

      skills context → recall context → original prompt

  Skills.Plug reads `ctx.assigns[:effective_prompt]` — if already
  set by a prior plug (typically `MonkeyClaw.Recall.Plug`), it
  prepends the skills block before the existing value. If not set,
  it prepends before `ctx.data[:prompt]`. To ensure correct
  composition, configure `MonkeyClaw.Skills.Plug` to run after
  `MonkeyClaw.Recall.Plug` on the `:query_pre` hook.

  ## Configuration

  Register in application config AFTER Recall.Plug:

      config :monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [
            {MonkeyClaw.Recall.Plug, max_results: 10, max_chars: 4000},
            {MonkeyClaw.Skills.Plug, max_skills: 5, max_chars: 2000}
          ]
        }

  ## Options

    * `:max_skills` — Maximum skills to inject (default: 5)
    * `:max_chars` — Character budget for skills block (default: 2000)
    * `:min_query_length` — Skip queries shorter than this (default: 10)

  ## Design

  This is NOT a process. It implements `MonkeyClaw.Extensions.Plug`
  — `init/1` is called once at pipeline compilation, `call/2` is
  called per query event.
  """

  @behaviour MonkeyClaw.Extensions.Plug

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Skills
  alias MonkeyClaw.Skills.Formatter

  @default_max_skills 5
  @default_max_chars 2000
  @default_min_query_length 10

  @type opts :: %{
          max_skills: pos_integer(),
          max_chars: pos_integer(),
          min_query_length: non_neg_integer()
        }

  @doc """
  Initialize the plug with configuration options.

  Called once when the extension pipeline is compiled. Returns
  a map of validated and normalized options used by `call/2`.
  Invalid values fall back to defaults rather than crashing
  at query time.
  """
  @impl true
  @spec init(keyword()) :: opts()
  def init(opts) when is_list(opts) do
    %{
      max_skills:
        opts
        |> Keyword.get(:max_skills, @default_max_skills)
        |> normalize_pos_int(@default_max_skills),
      max_chars:
        opts
        |> Keyword.get(:max_chars, @default_max_chars)
        |> normalize_pos_int(@default_max_chars),
      min_query_length:
        opts
        |> Keyword.get(:min_query_length, @default_min_query_length)
        |> normalize_non_neg_int(@default_min_query_length)
    }
  end

  @doc """
  Execute skill injection on a `:query_pre` context.

  Skips injection when:

    * The prompt is shorter than `:min_query_length`
    * No workspace ID is available in the context data
    * No matching skills are found for the prompt
    * The formatted skills block is empty (e.g., budget too small)

  For non-`:query_pre` events, passes the context through unchanged.
  """
  @impl true
  @spec call(Context.t(), opts()) :: Context.t()
  def call(%Context{event: :query_pre} = ctx, opts) do
    prompt = Map.get(ctx.data, :prompt, "")
    workspace_id = Map.get(ctx.data, :workspace_id)

    cond do
      String.length(prompt) < opts.min_query_length ->
        ctx

      not is_binary(workspace_id) or byte_size(workspace_id) == 0 ->
        ctx

      true ->
        inject_skills(ctx, workspace_id, prompt, opts)
    end
  end

  # Pass through non-query_pre events unchanged.
  def call(ctx, _opts), do: ctx

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  defp normalize_pos_int(v, _default) when is_integer(v) and v > 0, do: v
  defp normalize_pos_int(_v, default), do: default

  defp normalize_non_neg_int(v, _default) when is_integer(v) and v >= 0, do: v
  defp normalize_non_neg_int(_v, default), do: default

  @spec inject_skills(Context.t(), String.t(), String.t(), opts()) :: Context.t()
  defp inject_skills(ctx, workspace_id, prompt, opts) do
    skills = fetch_skills(workspace_id, prompt, opts)

    # Always assign skills_result for observability — even when
    # the formatted block is empty (e.g., budget too small but
    # matches exist).
    skills_result = %{
      skill_count: length(skills),
      skills: Enum.map(skills, & &1.title)
    }

    ctx = Context.assign(ctx, :skills_result, skills_result)

    case Formatter.format(skills, opts.max_chars) do
      %{text: ""} ->
        ctx

      %{text: skills_block} ->
        # CRITICAL COMPOSITION: Read existing effective_prompt if set
        # by a prior plug (e.g., Recall.Plug). Prepend skills before it
        # so the final order is: skills context → recall context → prompt.
        base = ctx.assigns[:effective_prompt] || prompt
        enhanced = skills_block <> "\n\n---\n\n" <> base
        Context.assign(ctx, :effective_prompt, enhanced)
    end
  end

  @spec fetch_skills(String.t(), String.t(), opts()) :: [MonkeyClaw.Skills.Skill.t()]
  defp fetch_skills(workspace_id, prompt, opts) do
    # Always use FTS search for query-relevant results. The ETS cache
    # (`MonkeyClaw.Skills.Cache`) stores workspace-wide top skills for
    # non-query contexts (dashboards, listing). It is intentionally NOT
    # used here — injecting cached top skills regardless of the prompt
    # would sacrifice relevance. FTS5 queries are fast enough for
    # single-user workloads.
    Skills.search_skills(workspace_id, prompt, %{limit: opts.max_skills})
  end
end
