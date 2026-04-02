defmodule MonkeyClaw.Recall do
  @moduledoc """
  Cross-session recall for MonkeyClaw.

  Searches past session history via FTS5 and formats results
  into injectable context blocks for agent queries. This enables
  agents to reference information from previous conversations
  within the same workspace.

  ## How It Works

  1. The caller provides a workspace ID and a search query
  2. The query is sanitized for FTS5 syntax safety
  3. Messages matching the query are retrieved via FTS5
  4. Results are formatted into a context block with session grouping
  5. The formatted block can be prepended to an agent prompt

  ## Query Sanitization

  User prompts are not valid FTS5 queries — they contain
  punctuation, special characters, and syntax that would cause
  FTS5 MATCH errors. `sanitize_query/1` extracts meaningful
  keywords (3+ characters, deduplicated) and combines them with
  OR for broad recall.

  ## Character Budget

  Results are truncated to a configurable character budget
  (default: 4000 chars) to avoid overwhelming the agent's
  context window. The `:truncated` flag in the result indicates
  whether any matches were dropped.

  ## Design

  This is NOT a process. All functions are pure (database I/O
  aside) and safe for concurrent use. No state, no lifecycle.

  ## Related Modules

    * `MonkeyClaw.Recall.Formatter` — Formats results into text blocks
    * `MonkeyClaw.Recall.Plug` — Extension plug for automatic injection
    * `MonkeyClaw.Sessions` — Underlying FTS5 search
  """

  alias MonkeyClaw.Recall.Formatter
  alias MonkeyClaw.Sessions
  alias MonkeyClaw.Sessions.Message

  @default_limit 10
  @default_max_chars 4000
  @min_keyword_length 3
  @max_keywords 8

  # Strip everything that is not a word character or whitespace.
  # This is safer than enumerating FTS5 special characters —
  # punctuation like ?, !, ., commas, and any future FTS5 syntax
  # are all removed, leaving only alphanumeric tokens and spaces.
  @non_word_chars ~r/[^\w\s]/u
  # FTS5 query operators that must not appear as search terms.
  # These are case-insensitive in FTS5 and would change query
  # semantics or produce syntax errors if included as keywords.
  @fts5_reserved MapSet.new(~w(and or not near))

  @type recall_opts :: %{
          optional(:limit) => pos_integer(),
          optional(:max_chars) => pos_integer(),
          optional(:after) => DateTime.t(),
          optional(:before) => DateTime.t(),
          optional(:roles) => [Message.role()],
          optional(:exclude_session_id) => Ecto.UUID.t()
        }

  @type recall_result :: %{
          matches: [Message.t()],
          formatted: String.t(),
          match_count: non_neg_integer(),
          truncated: boolean()
        }

  @doc """
  Search past sessions and return formatted recall context.

  Sanitizes the query for FTS5, searches across all sessions in
  the workspace, and formats matching messages into an injectable
  context block.

  Returns a map with the raw matches, formatted text, match count,
  and whether results were truncated to fit the character budget.

  ## Options

    * `:limit` — Maximum number of messages to retrieve (default: 10)
    * `:max_chars` — Character budget for formatted output (default: 4000)
    * `:after` — Only messages inserted at or after this `DateTime`
    * `:before` — Only messages inserted at or before this `DateTime`
    * `:roles` — Only messages with these roles (list of atoms)
    * `:exclude_session_id` — Exclude messages from this session

  ## Examples

      result = Recall.recall(workspace_id, "How do I deploy?")
      result.formatted
      #=> "[Recalled from previous sessions]\\n\\n--- Session a1b2..."
      result.match_count
      #=> 3
  """
  @spec recall(Ecto.UUID.t(), String.t(), recall_opts()) :: recall_result()
  def recall(workspace_id, query, opts \\ %{})
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(query) and is_map(opts) do
    case sanitize_query(query) do
      nil ->
        empty_result()

      sanitized ->
        search_opts = build_search_opts(sanitized, opts)
        matches = Sessions.search_messages(workspace_id, sanitized, search_opts)
        max_chars = clamp_pos_integer(Map.get(opts, :max_chars), @default_max_chars)
        %{text: formatted, truncated: truncated} = Formatter.format(matches, max_chars)

        %{
          matches: matches,
          formatted: formatted,
          match_count: length(matches),
          truncated: truncated
        }
    end
  end

  @doc """
  Sanitize a user prompt for use as an FTS5 MATCH query.

  Strips FTS5 special characters, extracts keywords of 3+
  characters, deduplicates, takes the first 8, and combines
  with OR for broad matching.

  Returns `nil` if no usable keywords remain after sanitization.

  ## Examples

      Recall.sanitize_query("How do I deploy to production?")
      #=> "how OR deploy OR production"

      Recall.sanitize_query("a b")
      #=> nil
  """
  @spec sanitize_query(String.t()) :: String.t() | nil
  def sanitize_query(text) when is_binary(text) do
    text
    |> String.replace(@non_word_chars, " ")
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(byte_size(&1) < @min_keyword_length or MapSet.member?(@fts5_reserved, &1)))
    |> Enum.uniq()
    |> Enum.take(@max_keywords)
    |> case do
      [] -> nil
      terms -> Enum.join(terms, " OR ")
    end
  end

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  @spec empty_result() :: recall_result()
  defp empty_result do
    %{matches: [], formatted: "", match_count: 0, truncated: false}
  end

  # Build the opts map for Sessions.search_messages/3.
  # The sanitized query replaces the original; other opts
  # are forwarded as-is if present.
  @spec build_search_opts(String.t(), recall_opts()) :: search_opts_map()
  defp build_search_opts(_sanitized, opts) do
    base = %{limit: clamp_pos_integer(Map.get(opts, :limit), @default_limit)}

    base
    |> maybe_put(:after, opts)
    |> maybe_put(:before, opts)
    |> maybe_put(:roles, opts)
    |> maybe_put(:exclude_session_id, opts)
  end

  @filter_keys [:after, :before, :roles, :exclude_session_id]
  @type filter_key :: :after | :before | :roles | :exclude_session_id
  @type search_opts_map :: %{:limit => pos_integer(), optional(filter_key()) => term()}

  defp clamp_pos_integer(v, _default) when is_integer(v) and v > 0, do: v
  defp clamp_pos_integer(_v, default), do: default

  @spec maybe_put(search_opts_map(), filter_key(), map()) :: search_opts_map()
  defp maybe_put(target, key, source) when key in @filter_keys do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(target, key, value)
      :error -> target
    end
  end
end
