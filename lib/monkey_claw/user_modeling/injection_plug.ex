defmodule MonkeyClaw.UserModeling.InjectionPlug do
  @moduledoc """
  Extension plug that injects user context into agent queries.

  When registered on the `:query_pre` hook, this plug reads the
  user's profile for the current workspace and prepends relevant
  context to the effective prompt.

  ## Composition with Other Plugs

  When UserModeling.InjectionPlug, Skills.Plug, and Recall.Plug
  are all registered on `:query_pre`, they compose by layering
  onto `:effective_prompt`:

      user context → skills context → recall context → original prompt

  InjectionPlug reads `ctx.assigns[:effective_prompt]` — if already
  set by a prior plug, it prepends the user context block before
  the existing value. To ensure correct composition, configure
  `MonkeyClaw.UserModeling.InjectionPlug` to run after all other
  `:query_pre` plugs.

  ## Configuration

  Register in application config AFTER Skills.Plug and Recall.Plug:

      config :monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [
            {MonkeyClaw.Recall.Plug, max_results: 10, max_chars: 4000},
            {MonkeyClaw.Skills.Plug, max_skills: 5, max_chars: 2000},
            {MonkeyClaw.UserModeling.InjectionPlug, min_query_length: 10}
          ]
        }

  ## Options

    * `:min_query_length` — Skip injection for queries shorter than
      this (default: 10)

  ## Design

  This is NOT a process. It implements `MonkeyClaw.Extensions.Plug`
  — `init/1` is called once at pipeline compilation, `call/2` is
  called per query event.
  """

  @behaviour MonkeyClaw.Extensions.Plug

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.UserModeling

  @default_min_query_length 10

  @type opts :: %{min_query_length: non_neg_integer()}

  @doc """
  Initialize the plug with configuration options.

  Called once when the extension pipeline is compiled. Returns
  a map of validated options used by `call/2`.
  """
  @impl true
  @spec init(keyword()) :: opts()
  def init(opts) when is_list(opts) do
    %{
      min_query_length:
        opts
        |> Keyword.get(:min_query_length, @default_min_query_length)
        |> normalize_non_neg_int(@default_min_query_length)
    }
  end

  @doc """
  Inject user context into a `:query_pre` context.

  Skips injection when:

    * The prompt is shorter than `:min_query_length`
    * No workspace ID is available in the context data
    * The user profile has injection disabled
    * No useful context is available for injection

  For non-`:query_pre` events, passes the context through unchanged.
  """
  @impl true
  @spec call(Context.t(), opts()) :: Context.t()
  def call(%Context{event: :query_pre} = ctx, opts) do
    prompt = Map.get(ctx.data, :prompt) || ""
    workspace_id = Map.get(ctx.data, :session_id)

    cond do
      not is_binary(prompt) or String.length(prompt) < opts.min_query_length ->
        ctx

      not is_binary(workspace_id) or byte_size(workspace_id) == 0 ->
        ctx

      true ->
        inject_user_context(ctx, workspace_id, prompt)
    end
  end

  # Pass through non-query_pre events unchanged.
  def call(ctx, _opts), do: ctx

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  defp normalize_non_neg_int(v, _default) when is_integer(v) and v >= 0, do: v
  defp normalize_non_neg_int(_v, default), do: default

  @spec inject_user_context(Context.t(), String.t(), String.t()) :: Context.t()
  defp inject_user_context(ctx, workspace_id, prompt) do
    context_text = UserModeling.get_injectable_context(workspace_id)

    if byte_size(context_text) > 0 do
      # Compose: prepend user context before existing effective_prompt
      # or the original prompt.
      base = ctx.assigns[:effective_prompt] || prompt
      enhanced = context_text <> "\n\n---\n\n" <> base

      ctx
      |> Context.assign(:effective_prompt, enhanced)
      |> Context.assign(:user_context_injected, true)
    else
      ctx
    end
  end
end
