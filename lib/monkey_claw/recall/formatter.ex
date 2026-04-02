defmodule MonkeyClaw.Recall.Formatter do
  @moduledoc """
  Formats cross-session recall results into injectable context blocks.

  Takes a list of `Message` structs from FTS5 search results and
  formats them into a human-readable text block suitable for
  prepending to an agent prompt. Messages are grouped by session
  and truncated to a character budget.

  ## Output Format

      [Recalled from previous sessions]

      --- Session a1b2c3d4 (2026-03-15 14:30 UTC) ---
      USER: How do I deploy to production?
      ASSISTANT: Here are the steps...

      --- Session e5f6g7h8 (2026-03-14 09:15 UTC) ---
      USER: What's the database schema?
      ASSISTANT: The schema has three tables...

  ## Design

  This is NOT a process. All functions are pure — they take data
  in and return formatted data out. No side effects, no I/O.
  """

  alias MonkeyClaw.Sessions.Message

  @type format_result :: %{text: String.t(), truncated: boolean()}

  @header "[Recalled from previous sessions]\n\n"
  @session_separator "\n\n"
  @max_content_length 500

  @doc """
  Format a list of messages into an injectable context block.

  Groups messages by session, formats each group as a block with
  a session header, and concatenates blocks up to `max_chars`.
  Returns the formatted text and whether any content was truncated.

  Returns an empty text with `truncated: false` for an empty list.

  ## Parameters

    * `messages` — List of `Message` structs from FTS5 search
    * `max_chars` — Maximum character budget for the output

  ## Examples

      %{text: text, truncated: false} = Formatter.format(messages, 4000)
  """
  @spec format([Message.t()], pos_integer()) :: format_result()
  def format([], _max_chars), do: %{text: "", truncated: false}

  def format(messages, max_chars)
      when is_list(messages) and is_integer(max_chars) and max_chars > 0 do
    budget = max_chars - String.length(@header)

    if budget <= 0 do
      %{text: "", truncated: true}
    else
      {blocks, truncated} = build_blocks(messages, budget)

      text =
        case blocks do
          [] -> ""
          _ -> @header <> Enum.join(blocks, @session_separator)
        end

      %{text: text, truncated: truncated}
    end
  end

  # Group messages by session in input order and format each group
  # as a block. Stops adding blocks when the character budget is
  # exhausted. Preserves the order sessions appear in the search
  # results for deterministic prompt generation.
  @spec build_blocks([Message.t()], non_neg_integer()) :: {[String.t()], boolean()}
  defp build_blocks(messages, budget) do
    {session_order, session_map} = group_preserving_order(messages)

    session_order
    |> Enum.reduce({[], budget, false}, fn session_id, {acc, remaining, trunc} ->
      msgs = Map.fetch!(session_map, session_id)
      block = format_session_block(session_id, msgs)
      # Only charge separator cost between blocks, not for the first.
      separator_cost = if acc == [], do: 0, else: String.length(@session_separator)
      block_size = String.length(block) + separator_cost

      if block_size <= remaining do
        {[block | acc], remaining - block_size, trunc}
      else
        {acc, remaining, true}
      end
    end)
    |> then(fn {blocks, _remaining, truncated} -> {Enum.reverse(blocks), truncated} end)
  end

  # Group messages by session_id while preserving the order in
  # which session_ids first appear in the input list. Returns
  # {ordered_session_ids, %{session_id => [messages]}}.
  @spec group_preserving_order([Message.t()]) :: {[String.t()], %{String.t() => [Message.t()]}}
  defp group_preserving_order(messages) do
    {order, map} =
      Enum.reduce(messages, {[], %{}}, fn %Message{session_id: sid} = msg, {ord, m} ->
        if Map.has_key?(m, sid) do
          {ord, Map.update!(m, sid, &[msg | &1])}
        else
          {[sid | ord], Map.put(m, sid, [msg])}
        end
      end)

    # Reverse both the session order and each session's message list
    # to restore original input ordering.
    reversed_map = Map.new(map, fn {k, v} -> {k, Enum.reverse(v)} end)
    {Enum.reverse(order), reversed_map}
  end

  # Format a group of messages from a single session as a text block.
  @spec format_session_block(String.t() | nil, [Message.t()]) :: String.t()
  defp format_session_block(session_id, messages) do
    short_id = if is_binary(session_id), do: String.slice(session_id, 0, 8), else: "unknown"
    timestamp = format_timestamp(List.first(messages))
    header = "--- Session #{short_id} (#{timestamp}) ---"

    lines =
      Enum.map(messages, fn msg ->
        role = msg.role |> Atom.to_string() |> String.upcase()
        content = truncate_content(msg.content)
        "#{role}: #{content}"
      end)

    Enum.join([header | lines], "\n")
  end

  @spec format_timestamp(Message.t() | nil) :: String.t()
  defp format_timestamp(%Message{inserted_at: %DateTime{} = dt}) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_timestamp(_), do: "unknown"

  @spec truncate_content(String.t() | nil) :: String.t()
  defp truncate_content(nil), do: "[no content]"

  defp truncate_content(content) when is_binary(content) do
    if String.length(content) <= @max_content_length do
      content
    else
      String.slice(content, 0, @max_content_length) <> "..."
    end
  end
end
