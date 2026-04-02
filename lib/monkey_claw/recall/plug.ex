defmodule MonkeyClaw.Recall.Plug do
  @moduledoc """
  Extension plug that injects cross-session recall into agent queries.

  When registered on the `:query_pre` hook, this plug searches past
  session history for content relevant to the current prompt and
  sets the `:effective_prompt` assign with recalled context prepended.

  ## How It Works

  1. Extracts the prompt and workspace ID from the hook context
  2. Skips recall for short queries (below `:min_query_length`)
  3. Searches past sessions via `MonkeyClaw.Recall.recall/3`
  4. If matches are found, prepends the context block to the prompt
  5. Sets `:effective_prompt` in assigns (consumed by the workflow)
  6. Sets `:recall_result` in assigns (for downstream observability)

  ## Configuration

  Register in application config:

      config :monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [
            {MonkeyClaw.Recall.Plug, max_results: 10, max_chars: 4000}
          ]
        }

  ## Options

    * `:max_results` — Maximum messages to retrieve (default: 10)
    * `:max_chars` — Character budget for context block (default: 4000)
    * `:roles` — Message roles to include (default: `[:user, :assistant]`)
    * `:min_query_length` — Skip queries shorter than this (default: 10)

  ## Design

  This is NOT a process. It implements `MonkeyClaw.Extensions.Plug`
  — `init/1` is called once at pipeline compilation, `call/2` is
  called per query event. The plug is a pure transformation on the
  extension context.
  """

  @behaviour MonkeyClaw.Extensions.Plug

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Recall

  @default_max_results 10
  @default_max_chars 4000
  @default_min_query_length 10
  @default_roles [:user, :assistant]

  @type opts :: %{
          max_results: pos_integer(),
          max_chars: pos_integer(),
          roles: [atom()],
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
      max_results:
        opts
        |> Keyword.get(:max_results, @default_max_results)
        |> normalize_pos_int(@default_max_results),
      max_chars:
        opts
        |> Keyword.get(:max_chars, @default_max_chars)
        |> normalize_pos_int(@default_max_chars),
      roles: opts |> Keyword.get(:roles, @default_roles) |> normalize_roles(),
      min_query_length:
        opts
        |> Keyword.get(:min_query_length, @default_min_query_length)
        |> normalize_non_neg_int(@default_min_query_length)
    }
  end

  @doc """
  Execute recall injection on a `:query_pre` context.

  Skips recall when:

    * The prompt is shorter than `:min_query_length`
    * No workspace ID is available in the context data
    * No usable keywords can be extracted from the prompt
    * No matching messages are found in past sessions

  For non-`:query_pre` events, passes the context through unchanged.
  """
  @impl true
  @spec call(Context.t(), opts()) :: Context.t()
  def call(%Context{event: :query_pre} = ctx, opts) do
    prompt = Map.get(ctx.data, :prompt, "")
    # Conversation.run_query_pre passes workspace.id as :session_id
    # in the hook data map. This is the workspace identifier used
    # to scope recall searches.
    workspace_id = Map.get(ctx.data, :session_id)

    cond do
      String.length(prompt) < opts.min_query_length ->
        ctx

      not is_binary(workspace_id) or byte_size(workspace_id) == 0 ->
        ctx

      true ->
        inject_recall(ctx, workspace_id, prompt, opts)
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

  defp normalize_roles(roles) when is_list(roles) and roles != [] do
    if Enum.all?(roles, &is_atom/1), do: roles, else: @default_roles
  end

  defp normalize_roles(_), do: @default_roles

  @spec inject_recall(Context.t(), String.t(), String.t(), opts()) :: Context.t()
  defp inject_recall(ctx, workspace_id, prompt, opts) do
    recall_opts = %{
      limit: opts.max_results,
      max_chars: opts.max_chars,
      roles: opts.roles
    }

    result = Recall.recall(workspace_id, prompt, recall_opts)

    # Always assign recall_result for observability — even when
    # formatted is empty (e.g., budget too small but matches exist).
    ctx = Context.assign(ctx, :recall_result, result)

    case result do
      %{formatted: ""} ->
        ctx

      %{formatted: context_block} ->
        enhanced = context_block <> "\n\n---\n\n" <> prompt
        Context.assign(ctx, :effective_prompt, enhanced)
    end
  end
end
