defmodule MonkeyClawWeb.Markdown do
  @moduledoc """
  Minimal markdown-to-HTML renderer for chat message display.

  Zero-dependency implementation covering the markdown subset
  Claude typically produces: fenced code blocks, inline code,
  bold, italic, headers, lists, and paragraphs.

  ## Security

  Content rendered by this module originates from external AI
  backends and is marked `{:safe, html}`, bypassing Phoenix's
  auto-escaping. Two layers of defense prevent XSS:

    1. **Input escaping** — `html_escape/1` runs on all text
       *before* any HTML tags are emitted by the inline renderer.
    2. **Output sanitization** — `sanitize_html/1` runs on the
       final HTML string and escapes any tag not in an explicit
       allowlist. Even if a future code change introduces a
       rendering path that skips input escaping, disallowed tags
       (e.g., `<script>`, `<iframe>`, `<svg>`) are caught here.

  The allowlist contains only the tags this renderer produces:
  `p`, `pre`, `code`, `h1`–`h3`, `ul`, `ol`, `li`, `br`,
  `strong`, and `em`.
  """

  # Tags this renderer produces — everything else gets escaped.
  @allowed_tags MapSet.new(~w(p pre code h1 h2 h3 ul ol li br strong em))

  # Matches HTML tags: opening, closing, or self-closing.
  @html_tag_re ~r/<\/?([a-zA-Z][a-zA-Z0-9]*)[^>]*\/?>/

  # Internal markers used during rendering — stripped from output.
  @marker_re ~r/<!--\/?CODE_BLOCK-->/

  @doc """
  Render markdown text to a Phoenix.HTML safe tuple.

  Returns `{:safe, html_string}` for use in HEEx templates.
  The output is sanitized — only allowlisted HTML tags survive.

  ## Examples

      iex> MonkeyClawWeb.Markdown.render("Hello **world**")
      {:safe, "<p>Hello <strong>world</strong></p>"}

      iex> MonkeyClawWeb.Markdown.render("<script>alert(1)</script>")
      {:safe, "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>"}

  """
  @spec render(String.t()) :: Phoenix.HTML.safe()
  def render(markdown) when is_binary(markdown) do
    html =
      markdown
      |> String.trim()
      |> render_fenced_code_blocks()
      |> render_blocks()
      |> sanitize_html()

    {:safe, html}
  end

  def render(_), do: {:safe, ""}

  # --- Output sanitization (defense-in-depth) ---
  #
  # Escapes any HTML tag not produced by this renderer.
  # This is the last line of defense before {:safe, ...}
  # tells Phoenix to skip auto-escaping.

  defp sanitize_html(html) do
    html
    |> String.replace(@marker_re, "")
    |> sanitize_tags()
  end

  defp sanitize_tags(html) do
    Regex.replace(@html_tag_re, html, fn full_match, tag_name ->
      if allowed_tag?(tag_name), do: full_match, else: escape_tag(full_match)
    end)
  end

  defp allowed_tag?(name), do: MapSet.member?(@allowed_tags, String.downcase(name))

  defp escape_tag(tag) do
    tag
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # --- Fenced code blocks (``` ... ```) ---
  # Must be processed first to protect code content from inline parsing.
  #
  # A regex-based approach cannot reliably match fenced code blocks when the
  # content itself contains triple-backtick lines (e.g., markdown examples in
  # AI responses). The `(.*?)` with the `s` (dotall) flag treats any inner
  # triple-backtick line as a potential closing fence. The stateful line-by-line
  # parser below solves this by recording the exact backtick count and leading
  # indentation of the opening fence and only accepting a closing fence line
  # that matches both, with nothing else on the line.

  # Accumulator: {output_lines_reversed, fence_state | nil, code_lines_reversed}
  # fence_state: %{indent: String.t(), ticks: String.t()}
  @typep fence_state :: %{indent: String.t(), ticks: String.t()}

  @spec render_fenced_code_blocks(String.t()) :: String.t()
  defp render_fenced_code_blocks(text) do
    text
    |> String.split("\n")
    |> parse_fenced_blocks({[], nil, []})
    |> finalize_fenced_output()
  end

  @spec parse_fenced_blocks([String.t()], {[String.t()], fence_state() | nil, [String.t()]}) ::
          {[String.t()], fence_state() | nil, [String.t()]}
  defp parse_fenced_blocks([], acc), do: acc

  defp parse_fenced_blocks([line | rest], {output, nil, _code_acc}) do
    case opening_fence(line) do
      {:ok, state} ->
        parse_fenced_blocks(rest, {output, state, []})

      :not_a_fence ->
        parse_fenced_blocks(rest, {[line | output], nil, []})
    end
  end

  defp parse_fenced_blocks([line | rest], {output, fence_state, code_acc}) do
    if closing_fence?(line, fence_state) do
      code_html = build_code_block(code_acc)
      parse_fenced_blocks(rest, {[code_html | output], nil, []})
    else
      parse_fenced_blocks(rest, {output, fence_state, [line | code_acc]})
    end
  end

  # Matches an opening fence line: optional leading spaces/tabs, then 3+
  # backticks, then an optional info string (language tag).
  # Returns the indent and tick string so the closing fence can be matched
  # exactly.
  @spec opening_fence(String.t()) :: {:ok, fence_state()} | :not_a_fence
  defp opening_fence(line) do
    case Regex.run(~r/^([ \t]*)(```+)(\w*)[ \t]*$/, line) do
      [_full, indent, ticks, _lang] -> {:ok, %{indent: indent, ticks: ticks}}
      _ -> :not_a_fence
    end
  end

  # A closing fence must have the same leading indentation and the same number
  # of backticks as the opening fence, with nothing else on the line.
  @spec closing_fence?(String.t(), fence_state()) :: boolean()
  defp closing_fence?(line, %{indent: indent, ticks: ticks}) do
    expected = indent <> ticks
    stripped = String.trim_trailing(line)
    stripped == expected
  end

  @spec build_code_block([String.t()]) :: String.t()
  defp build_code_block(code_lines_reversed) do
    code =
      code_lines_reversed
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim_trailing()

    escaped = html_escape(code)
    "<!--CODE_BLOCK--><pre><code>#{escaped}</code></pre><!--/CODE_BLOCK-->"
  end

  @spec finalize_fenced_output({[String.t()], fence_state() | nil, [String.t()]}) :: String.t()
  defp finalize_fenced_output({output, nil, _code_acc}) do
    output |> Enum.reverse() |> Enum.join("\n")
  end

  defp finalize_fenced_output({output, %{indent: indent, ticks: ticks}, code_acc}) do
    # Unclosed fence — treat accumulated lines as plain text in original order,
    # including the opening fence line that started code accumulation.
    opening_fence_line = indent <> ticks
    all_lines = Enum.reverse(output) ++ [opening_fence_line] ++ Enum.reverse(code_acc)
    Enum.join(all_lines, "\n")
  end

  # --- Block-level rendering ---

  defp render_blocks(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.map_join("", &render_block/1)
  end

  defp render_block("<!--CODE_BLOCK-->" <> _ = block), do: block

  defp render_block(block) do
    trimmed = String.trim(block)

    cond do
      # Already rendered code block
      String.starts_with?(trimmed, "<pre>") ->
        trimmed

      # Headers — match longest prefix first; replace_prefix
      # removes exactly one occurrence (no over-stripping).
      String.starts_with?(trimmed, "### ") ->
        "<h3>#{inline(String.replace_prefix(trimmed, "### ", ""))}</h3>"

      String.starts_with?(trimmed, "## ") ->
        "<h2>#{inline(String.replace_prefix(trimmed, "## ", ""))}</h2>"

      String.starts_with?(trimmed, "# ") ->
        "<h1>#{inline(String.replace_prefix(trimmed, "# ", ""))}</h1>"

      # Unordered list
      Regex.match?(~r/^[-*] /m, trimmed) ->
        items =
          trimmed
          |> String.split(~r/\n/)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce([], &accumulate_ul_line/2)
          |> Enum.reverse()
          |> Enum.map_join("", fn text -> "<li>#{inline(text)}</li>" end)

        "<ul>#{items}</ul>"

      # Ordered list
      Regex.match?(~r/^\d+\. /m, trimmed) ->
        items =
          trimmed
          |> String.split(~r/\n/)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce([], &accumulate_ol_line/2)
          |> Enum.reverse()
          |> Enum.map_join("", fn text -> "<li>#{inline(text)}</li>" end)

        "<ol>#{items}</ol>"

      # Regular paragraph
      true ->
        inner =
          trimmed
          |> String.split(~r/\n/)
          |> Enum.map_join("<br>", &inline/1)

        "<p>#{inner}</p>"
    end
  end

  # Accumulates lines into unordered list items. Lines starting with a list
  # marker (`- ` or `* `) open a new item; all other non-empty lines are
  # treated as continuation text and appended to the preceding item.
  @spec accumulate_ul_line(String.t(), [String.t()]) :: [String.t()]
  defp accumulate_ul_line(line, acc) do
    if Regex.match?(~r/^\s*[-*] /, line) do
      [String.replace(line, ~r/^\s*[-*] /, "") | acc]
    else
      append_continuation(line, acc)
    end
  end

  # Accumulates lines into ordered list items. Lines starting with a number
  # followed by `. ` open a new item; all other non-empty lines are treated
  # as continuation text and appended to the preceding item.
  @spec accumulate_ol_line(String.t(), [String.t()]) :: [String.t()]
  defp accumulate_ol_line(line, acc) do
    if Regex.match?(~r/^\s*\d+\. /, line) do
      [String.replace(line, ~r/^\s*\d+\. /, "") | acc]
    else
      append_continuation(line, acc)
    end
  end

  # Appends a continuation line to the most recent list item by joining with
  # a space. If the accumulator is empty (orphan continuation with no preceding
  # item), the line is started as a new item.
  @spec append_continuation(String.t(), [String.t()]) :: [String.t()]
  defp append_continuation(line, acc) do
    case acc do
      [current | rest] -> [current <> " " <> String.trim(line) | rest]
      [] -> [String.trim(line)]
    end
  end

  # --- Inline rendering ---

  defp inline(text) do
    text
    |> html_escape()
    |> render_inline_code()
    |> render_bold()
    |> render_italic()
  end

  # Inline code must be rendered before bold/italic to prevent
  # backtick content from being processed as emphasis.
  #
  # The naive regex ``(`[^`\n]+`)`` is ambiguous when there are multiple
  # backtick-delimited spans on the same line: the regex engine can match
  # across span boundaries because `[^`\n]+` is not anchored to the shortest
  # non-backtick run. For example, in:
  #
  #   `a` and `b`
  #
  # a greedy engine could match `` `a` and `b` `` as one span instead of
  # two. The scanner below processes inline code spans in a single
  # left-to-right pass: it finds the first opening backtick, then finds the
  # next backtick on the same line as the closing delimiter, emits one
  # `<code>` span, and continues scanning from after the closing backtick.
  # This prevents cross-boundary matches and handles adjacent spans correctly.
  @spec render_inline_code(String.t()) :: String.t()
  defp render_inline_code(text) do
    scan_inline_code(text, [])
  end

  @spec scan_inline_code(String.t(), [String.t()]) :: String.t()
  defp scan_inline_code("", acc), do: acc |> Enum.reverse() |> Enum.join()

  defp scan_inline_code(text, acc) do
    case :binary.match(text, "`") do
      :nomatch ->
        scan_inline_code("", [text | acc])

      {open_pos, 1} ->
        before = binary_part(text, 0, open_pos)
        after_open = binary_part(text, open_pos + 1, byte_size(text) - open_pos - 1)

        case find_closing_backtick(after_open) do
          {:ok, code_content, rest} ->
            # Safety: code_content is already HTML-escaped because html_escape/1
            # runs on the full text before render_inline_code/1 in the inline/1
            # pipeline. The sanitize_html/1 output layer provides defense-in-depth.
            span = "<code>#{code_content}</code>"
            scan_inline_code(rest, [span, before | acc])

          :not_found ->
            # No closing backtick on the same line — emit the backtick literally.
            scan_inline_code(after_open, ["`", before | acc])
        end
    end
  end

  # Finds the next backtick that closes an inline code span. The closing
  # backtick must appear before any newline (inline code does not span lines).
  # Returns `{:ok, code_content, rest_of_string}` or `:not_found`.
  @spec find_closing_backtick(String.t()) :: {:ok, String.t(), String.t()} | :not_found
  defp find_closing_backtick(text) do
    find_closing_backtick(text, 0, byte_size(text))
  end

  @spec find_closing_backtick(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t(), String.t()} | :not_found
  defp find_closing_backtick(_text, pos, size) when pos >= size, do: :not_found

  defp find_closing_backtick(text, pos, size) do
    <<_head::binary-size(pos), byte, _rest::binary>> = text

    cond do
      byte == ?\n ->
        # Hit a newline — inline code cannot span lines.
        :not_found

      byte == ?` ->
        code_content = binary_part(text, 0, pos)
        rest = binary_part(text, pos + 1, size - pos - 1)
        {:ok, code_content, rest}

      true ->
        find_closing_backtick(text, pos + 1, size)
    end
  end

  defp render_bold(text) do
    text
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/, &1, "<strong>\\1</strong>"))
    |> then(&Regex.replace(~r/__(.+?)__/, &1, "<strong>\\1</strong>"))
  end

  defp render_italic(text) do
    text
    |> then(&Regex.replace(~r/\*(.+?)\*/, &1, "<em>\\1</em>"))
    |> then(&Regex.replace(~r/_(.+?)_/, &1, "<em>\\1</em>"))
  end

  # --- HTML escaping ---

  defp html_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
