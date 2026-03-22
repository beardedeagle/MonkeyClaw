defmodule MonkeyClawWeb.Markdown do
  @moduledoc """
  Minimal markdown-to-HTML renderer for chat message display.

  Zero-dependency implementation covering the markdown subset
  Claude typically produces: fenced code blocks, inline code,
  bold, italic, headers, lists, and paragraphs.
  """

  @doc """
  Render markdown text to a Phoenix.HTML safe tuple.

  Returns `{:safe, html_string}` suitable for use with `raw/1`
  in HEEx templates.
  """
  @spec render(String.t()) :: Phoenix.HTML.safe()
  def render(markdown) when is_binary(markdown) do
    html =
      markdown
      |> String.trim()
      |> render_fenced_code_blocks()
      |> render_blocks()

    {:safe, html}
  end

  def render(_), do: {:safe, ""}

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

      # Headers
      String.starts_with?(trimmed, "### ") ->
        "<h3>#{inline(String.trim_leading(trimmed, "# "))}</h3>"

      String.starts_with?(trimmed, "## ") ->
        "<h2>#{inline(String.trim_leading(trimmed, "# "))}</h2>"

      String.starts_with?(trimmed, "# ") ->
        "<h1>#{inline(String.trim_leading(trimmed, "# "))}</h1>"

      # Unordered list
      Regex.match?(~r/^[-*] /m, trimmed) ->
        items =
          trimmed
          |> String.split(~r/\n/)
          |> Enum.map(fn line ->
            line
            |> String.replace(~r/^\s*[-*] /, "")
            |> inline()
            |> then(&"<li>#{&1}</li>")
          end)
          |> Enum.join("")

        "<ul>#{items}</ul>"

      # Ordered list
      Regex.match?(~r/^\d+\. /m, trimmed) ->
        items =
          trimmed
          |> String.split(~r/\n/)
          |> Enum.map(fn line ->
            line
            |> String.replace(~r/^\s*\d+\. /, "")
            |> inline()
            |> then(&"<li>#{&1}</li>")
          end)
          |> Enum.join("")

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
