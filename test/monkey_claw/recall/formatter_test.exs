defmodule MonkeyClaw.Recall.FormatterTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Recall.Formatter
  alias MonkeyClaw.Sessions.Message

  # ──────────────────────────────────────────────
  # format/2
  # ──────────────────────────────────────────────

  describe "format/2" do
    test "returns empty text for empty list" do
      assert Formatter.format([], 4000) == %{text: "", truncated: false}
    end

    test "formats a single message" do
      msg = build_message(:user, "Hello world", "session-1")

      %{text: text, truncated: truncated} = Formatter.format([msg], 4000)

      assert truncated == false
      assert String.contains?(text, "[Recalled from previous sessions]")
      assert String.contains?(text, "--- Session session-")
      assert String.contains?(text, "USER: Hello world")
    end

    test "formats multiple messages from same session" do
      msgs = [
        build_message(:user, "What is deployment?", "session-1"),
        build_message(:assistant, "Deployment is the process of...", "session-1")
      ]

      %{text: text, truncated: false} = Formatter.format(msgs, 4000)

      assert String.contains?(text, "USER: What is deployment?")
      assert String.contains?(text, "ASSISTANT: Deployment is the process of...")
    end

    test "groups messages by session" do
      msgs = [
        build_message(:user, "Question one", "session-aaa"),
        build_message(:user, "Question two", "session-bbb")
      ]

      %{text: text, truncated: false} = Formatter.format(msgs, 4000)

      assert String.contains?(text, "--- Session session-")
      # Both session blocks should appear
      assert String.contains?(text, "Question one")
      assert String.contains?(text, "Question two")
    end

    test "truncates when budget is exceeded" do
      msgs =
        Enum.map(1..10, fn i ->
          content = "message number #{i} with " <> String.duplicate("x", 200)
          build_message(:user, content, "session-#{i}")
        end)

      # Very small budget — can't fit all 10 sessions
      %{text: _text, truncated: truncated} = Formatter.format(msgs, 300)

      assert truncated == true
    end

    test "returns truncated true when budget too small for header" do
      msg = build_message(:user, "Hello", "session-1")

      %{text: text, truncated: truncated} = Formatter.format([msg], 10)

      # Budget of 10 is smaller than the header
      assert truncated == true
      assert text == ""
    end

    test "handles nil content in messages" do
      msg = build_message(:tool_use, nil, "session-1")

      %{text: text, truncated: false} = Formatter.format([msg], 4000)

      assert String.contains?(text, "TOOL_USE: [no content]")
    end

    test "truncates long message content" do
      long_content = String.duplicate("a", 1000)
      msg = build_message(:user, long_content, "session-1")

      %{text: text, truncated: false} = Formatter.format([msg], 4000)

      # Content should be truncated to 500 chars + "..."
      assert String.contains?(text, "...")
      # The full 1000-char content should NOT appear
      refute String.contains?(text, long_content)
    end

    test "includes timestamp in session header" do
      dt = ~U[2026-03-15 14:30:00Z]
      msg = build_message(:user, "Hello", "session-1", dt)

      %{text: text, truncated: false} = Formatter.format([msg], 4000)

      assert String.contains?(text, "2026-03-15 14:30 UTC")
    end

    test "handles messages with no timestamp" do
      msg = %Message{
        role: :user,
        content: "Hello",
        session_id: "session-1",
        inserted_at: nil
      }

      %{text: text, truncated: false} = Formatter.format([msg], 4000)

      assert String.contains?(text, "unknown")
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp build_message(role, content, session_id, inserted_at \\ nil) do
    %Message{
      role: role,
      content: content,
      session_id: session_id,
      inserted_at: inserted_at || DateTime.utc_now()
    }
  end
end
