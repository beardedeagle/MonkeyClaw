defmodule MonkeyClaw.Skills.FormatterTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Skills.Formatter
  alias MonkeyClaw.Skills.Skill

  defp build_skill(attrs \\ %{}) do
    Map.merge(
      %Skill{
        title: "Test Skill",
        description: "A test skill",
        procedure: "1. First step\n2. Second step",
        tags: ["test", "example"]
      },
      attrs
    )
  end

  # ──────────────────────────────────────────────
  # format/2
  # ──────────────────────────────────────────────

  describe "format/2" do
    test "returns empty for empty list" do
      assert %{text: "", truncated: false} = Formatter.format([], 2000)
    end

    test "formats single skill" do
      skill = build_skill()

      %{text: text, truncated: false} = Formatter.format([skill], 2000)

      assert String.contains?(text, "[Relevant skills from your library]")
      assert String.contains?(text, "--- Skill: Test Skill ---")
      assert String.contains?(text, "Tags: test, example")
      assert String.contains?(text, "Procedure:")
      assert String.contains?(text, "1. First step")
    end

    test "formats multiple skills" do
      s1 = build_skill(%{title: "Skill One"})
      s2 = build_skill(%{title: "Skill Two"})

      %{text: text, truncated: false} = Formatter.format([s1, s2], 4000)

      assert String.contains?(text, "Skill One")
      assert String.contains?(text, "Skill Two")
    end

    test "truncates when budget exceeded" do
      skills =
        Enum.map(1..10, fn i ->
          build_skill(%{
            title: "Skill #{i}",
            procedure: String.duplicate("step ", 50)
          })
        end)

      %{text: text, truncated: true} = Formatter.format(skills, 800)

      assert text != ""
      assert String.contains?(text, "[Relevant skills from your library]")
    end

    test "truncates long procedures at 500 chars" do
      skill = build_skill(%{procedure: String.duplicate("x", 600)})

      %{text: text, truncated: false} = Formatter.format([skill], 4000)

      assert String.contains?(text, "...")
    end

    test "handles nil procedure" do
      skill = build_skill(%{procedure: nil})

      %{text: text, truncated: false} = Formatter.format([skill], 2000)

      assert String.contains?(text, "[no procedure]")
    end

    test "handles empty tags" do
      skill = build_skill(%{tags: []})

      %{text: text, truncated: false} = Formatter.format([skill], 2000)

      refute String.contains?(text, "Tags:")
    end

    test "returns empty when budget too small for header" do
      skill = build_skill()

      %{text: "", truncated: true} = Formatter.format([skill], 10)
    end
  end
end
