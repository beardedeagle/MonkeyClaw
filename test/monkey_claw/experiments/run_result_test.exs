defmodule MonkeyClaw.Experiments.RunResultTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Experiments.RunResult

  # ── Output Extraction ───────────────────────────────────────

  describe "normalize/2 output extraction" do
    test "extracts text from atom-typed messages" do
      messages = [
        %{type: :text, content: "Hello"},
        %{type: :text, content: "World"}
      ]

      result = RunResult.normalize(messages)
      assert result.output == "Hello\nWorld"
    end

    test "extracts text from string-typed messages" do
      messages = [
        %{type: "text", content: "Hello"},
        %{"type" => "text", "content" => "World"}
      ]

      result = RunResult.normalize(messages)
      assert result.output == "Hello\nWorld"
    end

    test "ignores non-text messages in output" do
      messages = [
        %{type: :text, content: "visible"},
        %{type: :tool_use, name: "file_edit", input: %{}},
        %{type: :text, content: "also visible"}
      ]

      result = RunResult.normalize(messages)
      assert result.output == "visible\nalso visible"
    end

    test "returns empty string for no text messages" do
      messages = [%{type: :tool_use, name: "file_edit", input: %{}}]
      result = RunResult.normalize(messages)
      assert result.output == ""
    end
  end

  # ── Tool Call Extraction ────────────────────────────────────

  describe "normalize/2 tool call extraction" do
    test "extracts tool_use messages" do
      messages = [
        %{type: :tool_use, name: "file_edit", input: %{"path" => "lib/foo.ex"}, output: "ok"}
      ]

      result = RunResult.normalize(messages)
      assert length(result.tool_calls) == 1

      tool = hd(result.tool_calls)
      assert tool.name == "file_edit"
      assert tool.input == %{"path" => "lib/foo.ex"}
      assert tool.output == "ok"
    end

    test "handles string-keyed tool_use messages" do
      messages = [
        %{"type" => "tool_use", "name" => "bash", "input" => %{"cmd" => "ls"}}
      ]

      result = RunResult.normalize(messages)
      assert length(result.tool_calls) == 1
      assert hd(result.tool_calls).name == "bash"
    end

    test "defaults missing tool fields" do
      messages = [%{type: :tool_use}]

      result = RunResult.normalize(messages)
      assert length(result.tool_calls) == 1

      tool = hd(result.tool_calls)
      assert tool.name == "unknown"
      assert tool.input == %{}
      assert is_nil(tool.output)
    end
  end

  # ── Files Changed Derivation ────────────────────────────────

  describe "normalize/2 files_changed derivation" do
    test "derives from file mutation tool calls" do
      messages = [
        %{type: :tool_use, name: "file_edit", input: %{"path" => "lib/foo.ex"}},
        %{type: :tool_use, name: "file_write", input: %{"path" => "lib/bar.ex"}}
      ]

      result = RunResult.normalize(messages)
      assert "lib/foo.ex" in result.files_changed
      assert "lib/bar.ex" in result.files_changed
    end

    test "recognizes all file mutation tools" do
      for tool <- ["file_edit", "file_write", "write_file", "edit_file", "create_file"] do
        messages = [
          %{type: :tool_use, name: tool, input: %{"path" => "lib/#{tool}.ex"}}
        ]

        result = RunResult.normalize(messages)

        assert "lib/#{tool}.ex" in result.files_changed,
               "Expected #{tool} to be recognized as file mutation tool"
      end
    end

    test "ignores non-file-mutation tools" do
      messages = [
        %{type: :tool_use, name: "search", input: %{"query" => "foo"}},
        %{type: :tool_use, name: "read_file", input: %{"path" => "lib/read.ex"}},
        %{type: :tool_use, name: "bash", input: %{"command" => "ls lib/"}}
      ]

      result = RunResult.normalize(messages)
      assert result.files_changed == []
    end

    test "deduplicates file paths" do
      messages = [
        %{type: :tool_use, name: "file_edit", input: %{"path" => "lib/foo.ex"}},
        %{type: :tool_use, name: "file_edit", input: %{"path" => "lib/foo.ex"}}
      ]

      result = RunResult.normalize(messages)
      assert result.files_changed == ["lib/foo.ex"]
    end

    test "handles various path input keys" do
      for key <- ["path", "file_path", "filepath", "filename", "file"] do
        messages = [
          %{type: :tool_use, name: "file_edit", input: %{key => "lib/#{key}.ex"}}
        ]

        result = RunResult.normalize(messages)

        assert "lib/#{key}.ex" in result.files_changed,
               "Expected key '#{key}' to extract file path"
      end
    end

    test "handles atom path keys as fallback" do
      messages = [
        %{type: :tool_use, name: "file_edit", input: %{path: "lib/atom_key.ex"}}
      ]

      result = RunResult.normalize(messages)
      assert "lib/atom_key.ex" in result.files_changed
    end

    test "ignores empty and nil file paths" do
      messages = [
        %{type: :tool_use, name: "file_edit", input: %{"path" => ""}},
        %{type: :tool_use, name: "file_edit", input: %{"path" => nil}},
        %{type: :tool_use, name: "file_edit", input: %{}}
      ]

      result = RunResult.normalize(messages)
      assert result.files_changed == []
    end
  end

  # ── Edge Cases ──────────────────────────────────────────────

  describe "normalize/2 edge cases" do
    test "empty message list" do
      result = RunResult.normalize([])
      assert result.output == ""
      assert result.tool_calls == []
      assert result.files_changed == []
      assert result.metadata == %{}
    end

    test "non-list input returns empty result" do
      result = RunResult.normalize(nil)
      assert result.output == ""
      assert result.tool_calls == []
      assert result.files_changed == []
    end

    test "passes metadata through unchanged" do
      metadata = %{duration_ms: 1500, model: "claude"}
      result = RunResult.normalize([], metadata)
      assert result.metadata == metadata
    end

    test "defaults metadata to empty map" do
      result = RunResult.normalize([])
      assert result.metadata == %{}
    end

    test "mixed message types in correct order" do
      messages = [
        %{type: :text, content: "Starting optimization"},
        %{type: :tool_use, name: "file_edit", input: %{"path" => "lib/a.ex"}},
        %{type: :text, content: "Edited file"},
        %{type: :tool_use, name: "search", input: %{"query" => "test"}},
        %{type: :tool_use, name: "file_write", input: %{"path" => "lib/b.ex"}},
        %{type: :text, content: "Done"}
      ]

      result = RunResult.normalize(messages)

      assert result.output == "Starting optimization\nEdited file\nDone"
      assert length(result.tool_calls) == 3
      assert result.files_changed == ["lib/a.ex", "lib/b.ex"]
    end
  end
end
