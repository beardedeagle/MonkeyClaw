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

  @fenced_code_re ~r/```(\w*)\n(.*?)```/s

  defp render_fenced_code_blocks(text) do
    Regex.replace(@fenced_code_re, text, fn _full, _lang, code ->
      escaped = html_escape(String.trim_trailing(code))
      "<!--CODE_BLOCK--><pre><code>#{escaped}</code></pre><!--/CODE_BLOCK-->"
    end)
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
          |> Enum.map_join("", fn line ->
            line
            |> String.replace(~r/^\s*[-*] /, "")
            |> inline()
            |> then(&"<li>#{&1}</li>")
          end)

        "<ul>#{items}</ul>"

      # Ordered list
      Regex.match?(~r/^\d+\. /m, trimmed) ->
        items =
          trimmed
          |> String.split(~r/\n/)
          |> Enum.map_join("", fn line ->
            line
            |> String.replace(~r/^\s*\d+\. /, "")
            |> inline()
            |> then(&"<li>#{&1}</li>")
          end)

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
  defp render_inline_code(text) do
    Regex.replace(~r/`([^`]+)`/, text, "<code>\\1</code>")
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
