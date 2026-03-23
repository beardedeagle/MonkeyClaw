defmodule MonkeyClawWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias MonkeyClawWeb.Markdown

  # --- XSS Defense ---

  describe "XSS defense" do
    test "escapes script tags in paragraph text" do
      {:safe, html} = Markdown.render("<script>alert(1)</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes script tags in headers" do
      {:safe, html} = Markdown.render("# <script>alert(1)</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes iframe tags" do
      {:safe, html} = Markdown.render("<iframe src=evil></iframe>")
      refute html =~ "<iframe"
      assert html =~ "&lt;iframe"
    end

    test "escapes svg with event handler" do
      {:safe, html} = Markdown.render("<svg onload=alert(1)>")
      refute html =~ "<svg"
      assert html =~ "&lt;svg"
    end

    test "escapes img with onerror" do
      {:safe, html} = Markdown.render("<img src=x onerror=alert(1)>")
      refute html =~ "<img"
      assert html =~ "&lt;img"
    end

    test "escapes nested script in bold" do
      {:safe, html} = Markdown.render("**<script>xss</script>**")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "escapes javascript: protocol in link-like text" do
      {:safe, html} = Markdown.render("<a href=\"javascript:alert(1)\">click</a>")
      refute html =~ "<a "
      assert html =~ "&lt;a"
    end

    test "escapes object/embed tags" do
      {:safe, html} = Markdown.render("<object data=evil></object>")
      refute html =~ "<object"
      assert html =~ "&lt;object"
    end

    test "escapes form tags" do
      {:safe, html} = Markdown.render("<form action=evil><input></form>")
      refute html =~ "<form"
      assert html =~ "&lt;form"
    end

    test "preserves allowlisted tags" do
      {:safe, html} = Markdown.render("**bold** and *italic*")
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
    end
  end

  # --- Basic Rendering ---

  describe "render/1" do
    test "renders plain text as paragraph" do
      assert {:safe, "<p>Hello world</p>"} = Markdown.render("Hello world")
    end

    test "renders non-binary input as empty" do
      assert {:safe, ""} = Markdown.render(nil)
      assert {:safe, ""} = Markdown.render(42)
    end

    test "trims whitespace" do
      assert {:safe, "<p>hello</p>"} = Markdown.render("  hello  ")
    end

    test "renders line breaks within a paragraph" do
      {:safe, html} = Markdown.render("line one\nline two")
      assert html =~ "<br>"
    end
  end

  # --- Headers ---

  describe "headers" do
    test "renders h1" do
      assert {:safe, "<h1>Title</h1>"} = Markdown.render("# Title")
    end

    test "renders h2" do
      assert {:safe, "<h2>Subtitle</h2>"} = Markdown.render("## Subtitle")
    end

    test "renders h3" do
      assert {:safe, "<h3>Section</h3>"} = Markdown.render("### Section")
    end

    test "renders inline formatting in headers" do
      {:safe, html} = Markdown.render("## **Bold** header")
      assert html =~ "<strong>Bold</strong>"
      assert html =~ "<h2>"
    end
  end

  # --- Inline Formatting ---

  describe "inline formatting" do
    test "renders bold with **" do
      {:safe, html} = Markdown.render("**bold text**")
      assert html =~ "<strong>bold text</strong>"
    end

    test "renders bold with __" do
      {:safe, html} = Markdown.render("__bold text__")
      assert html =~ "<strong>bold text</strong>"
    end

    test "renders italic with *" do
      {:safe, html} = Markdown.render("*italic text*")
      assert html =~ "<em>italic text</em>"
    end

    test "renders italic with _" do
      {:safe, html} = Markdown.render("_italic text_")
      assert html =~ "<em>italic text</em>"
    end

    test "renders inline code" do
      {:safe, html} = Markdown.render("`some code`")
      assert html =~ "<code>some code</code>"
    end

    test "escapes HTML inside inline code" do
      {:safe, html} = Markdown.render("`<div>tag</div>`")
      assert html =~ "<code>&lt;div&gt;tag&lt;/div&gt;</code>"
    end
  end

  # --- Lists ---

  describe "lists" do
    test "renders unordered list with -" do
      {:safe, html} = Markdown.render("- item one\n- item two")
      assert html =~ "<ul>"
      assert html =~ "<li>item one</li>"
      assert html =~ "<li>item two</li>"
    end

    test "renders unordered list with *" do
      {:safe, html} = Markdown.render("* alpha\n* beta")
      assert html =~ "<ul>"
      assert html =~ "<li>alpha</li>"
    end

    test "renders ordered list" do
      {:safe, html} = Markdown.render("1. first\n2. second")
      assert html =~ "<ol>"
      assert html =~ "<li>first</li>"
      assert html =~ "<li>second</li>"
    end

    test "renders inline formatting in list items" do
      {:safe, html} = Markdown.render("- **bold** item\n- `code` item")
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<code>code</code>"
    end
  end

  # --- Fenced Code Blocks ---

  describe "fenced code blocks" do
    test "renders fenced code block" do
      md = "```\nfoo()\nbar()\n```"
      {:safe, html} = Markdown.render(md)
      assert html =~ "<pre><code>"
      assert html =~ "foo()"
    end

    test "escapes HTML inside fenced code blocks" do
      md = "```\n<script>alert(1)</script>\n```"
      {:safe, html} = Markdown.render(md)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end

    test "strips internal code block markers" do
      md = "```\ncode\n```"
      {:safe, html} = Markdown.render(md)
      refute html =~ "<!--CODE_BLOCK-->"
      refute html =~ "<!--/CODE_BLOCK-->"
    end

    test "renders fenced code block with language specifier" do
      md = "```elixir\nIO.puts(\"hello\")\n```"
      {:safe, html} = Markdown.render(md)
      assert html =~ "<pre><code>"
      assert html =~ "IO.puts"
    end
  end

  # --- Sanitizer ---

  describe "sanitizer" do
    test "allows all tags the renderer produces" do
      md = """
      # Header

      **bold** *italic* `code`

      - list item

      1. ordered item

      ```
      fenced
      ```
      """

      {:safe, html} = Markdown.render(md)

      assert html =~ "<h1>"
      assert html =~ "<strong>"
      assert html =~ "<em>"
      assert html =~ "<code>"
      assert html =~ "<ul>"
      assert html =~ "<li>"
      assert html =~ "<ol>"
      assert html =~ "<pre>"
    end

    test "escapes unknown tags even if they look benign" do
      {:safe, html} = Markdown.render("<div>content</div>")
      refute html =~ "<div>"
      assert html =~ "&lt;div&gt;"
    end

    test "escapes tags with attributes" do
      {:safe, html} = Markdown.render("<span style=\"color:red\">red</span>")
      refute html =~ "<span"
      assert html =~ "&lt;span"
    end
  end
end
