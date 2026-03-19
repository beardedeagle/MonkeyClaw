defmodule MonkeyClaw.Assistants.AssistantTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Assistants.Assistant

  # Local helper — avoids pulling in DataCase for pure changeset tests
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # --- create_changeset/2 ---

  describe "create_changeset/2" do
    test "valid with required fields only" do
      changeset = Assistant.create_changeset(%Assistant{}, %{name: "Dev", backend: :claude})
      assert changeset.valid?
    end

    test "valid with all fields" do
      attrs = %{
        name: "Full",
        backend: :claude,
        model: "opus",
        system_prompt: "You are helpful.",
        persona_prompt: "Be concise.",
        context_prompt: "Working on Elixir.",
        cwd: "/home/user",
        max_thinking_tokens: 1000,
        permission_mode: :auto,
        is_default: true,
        description: "A full assistant"
      }

      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end

    test "requires name" do
      changeset = Assistant.create_changeset(%Assistant{}, %{backend: :claude})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "requires backend" do
      changeset = Assistant.create_changeset(%Assistant{}, %{name: "Dev"})
      refute changeset.valid?
    end

    test "validates name max length" do
      attrs = %{name: String.duplicate("a", 101), backend: :claude}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "validates name min length" do
      attrs = %{name: "", backend: :claude}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "validates description max length" do
      attrs = %{name: "Dev", backend: :claude, description: String.duplicate("a", 501)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "allows description at max length" do
      attrs = %{name: "Dev", backend: :claude, description: String.duplicate("a", 500)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end

    test "validates max_thinking_tokens must be positive" do
      attrs = %{name: "Dev", backend: :claude, max_thinking_tokens: 0}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "validates max_thinking_tokens rejects negative" do
      attrs = %{name: "Dev", backend: :claude, max_thinking_tokens: -1}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "accepts valid max_thinking_tokens" do
      attrs = %{name: "Dev", backend: :claude, max_thinking_tokens: 1}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end

    test "rejects invalid backend atom" do
      attrs = %{name: "Dev", backend: :invalid}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "accepts all valid backends" do
      for backend <- [:claude, :codex, :gemini, :opencode, :copilot] do
        changeset = Assistant.create_changeset(%Assistant{}, %{name: "Dev", backend: backend})
        assert changeset.valid?, "expected #{backend} to be valid"
      end
    end

    test "accepts all valid permission modes" do
      for mode <- [:auto, :manual, :accept_edits] do
        attrs = %{name: "Dev", backend: :claude, permission_mode: mode}
        changeset = Assistant.create_changeset(%Assistant{}, attrs)
        assert changeset.valid?, "expected #{mode} to be valid"
      end
    end

    test "rejects invalid permission mode" do
      attrs = %{name: "Dev", backend: :claude, permission_mode: :invalid}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "allows nil optional fields" do
      changeset =
        Assistant.create_changeset(%Assistant{}, %{
          name: "Dev",
          backend: :claude,
          model: nil,
          system_prompt: nil,
          persona_prompt: nil,
          context_prompt: nil,
          cwd: nil,
          max_thinking_tokens: nil,
          permission_mode: nil,
          description: nil
        })

      assert changeset.valid?
    end

    test "ignores is_default in create changeset" do
      changeset =
        Assistant.create_changeset(%Assistant{}, %{
          name: "Dev",
          backend: :claude,
          is_default: true
        })

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :is_default)
    end

    test "rejects non-map attrs" do
      assert_raise FunctionClauseError, fn ->
        Assistant.create_changeset(%Assistant{}, "not a map")
      end
    end

    test "rejects non-struct first argument" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Assistant, :create_changeset, [%{}, %{name: "Dev", backend: :claude}])
      end
    end

    # --- cwd validation ---

    test "accepts valid absolute cwd" do
      attrs = %{name: "Dev", backend: :claude, cwd: "/home/user/projects"}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end

    test "rejects relative cwd" do
      attrs = %{name: "Dev", backend: :claude, cwd: "relative/path"}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
      assert "must be an absolute path" in errors_on(changeset).cwd
    end

    test "rejects cwd with path traversal" do
      attrs = %{name: "Dev", backend: :claude, cwd: "/home/user/../etc/passwd"}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
      assert "path traversal sequences not permitted" in errors_on(changeset).cwd
    end

    test "rejects cwd exceeding max length" do
      long_path = "/" <> String.duplicate("a", 4096)
      attrs = %{name: "Dev", backend: :claude, cwd: long_path}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
      assert "path too long (max 4096 characters)" in errors_on(changeset).cwd
    end

    test "accepts cwd at max length boundary" do
      # 4096 bytes total: "/" + 4095 chars
      path = "/" <> String.duplicate("a", 4095)
      attrs = %{name: "Dev", backend: :claude, cwd: path}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end

    # --- max_thinking_tokens upper bound ---

    test "rejects max_thinking_tokens above upper bound" do
      attrs = %{name: "Dev", backend: :claude, max_thinking_tokens: 100_001}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "accepts max_thinking_tokens at upper bound" do
      attrs = %{name: "Dev", backend: :claude, max_thinking_tokens: 100_000}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end

    # --- prompt length caps ---

    test "rejects system_prompt exceeding max length" do
      attrs = %{name: "Dev", backend: :claude, system_prompt: String.duplicate("a", 32_001)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "accepts system_prompt at max length" do
      attrs = %{name: "Dev", backend: :claude, system_prompt: String.duplicate("a", 32_000)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end

    test "rejects persona_prompt exceeding max length" do
      attrs = %{name: "Dev", backend: :claude, persona_prompt: String.duplicate("a", 16_001)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "rejects context_prompt exceeding max length" do
      attrs = %{name: "Dev", backend: :claude, context_prompt: String.duplicate("a", 16_001)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    # --- model length cap ---

    test "rejects model exceeding max length" do
      attrs = %{name: "Dev", backend: :claude, model: String.duplicate("a", 101)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      refute changeset.valid?
    end

    test "accepts model at max length" do
      attrs = %{name: "Dev", backend: :claude, model: String.duplicate("a", 100)}
      changeset = Assistant.create_changeset(%Assistant{}, attrs)
      assert changeset.valid?
    end
  end

  # --- update_changeset/2 ---

  describe "update_changeset/2" do
    test "allows updating name" do
      assistant = %Assistant{name: "Dev", backend: :claude}
      changeset = Assistant.update_changeset(assistant, %{name: "New Name"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "New Name"
    end

    test "allows updating backend" do
      assistant = %Assistant{name: "Dev", backend: :claude}
      changeset = Assistant.update_changeset(assistant, %{backend: :gemini})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :backend) == :gemini
    end

    test "does not allow is_default to be changed" do
      assistant = %Assistant{name: "Dev", backend: :claude, is_default: false}
      changeset = Assistant.update_changeset(assistant, %{is_default: true})
      refute Map.has_key?(changeset.changes, :is_default)
    end

    test "validates same constraints as create" do
      assistant = %Assistant{name: "Dev", backend: :claude}

      changeset =
        Assistant.update_changeset(assistant, %{
          name: String.duplicate("a", 101)
        })

      refute changeset.valid?
    end
  end

  # --- default_changeset/2 ---

  describe "default_changeset/2" do
    test "sets is_default to true" do
      assistant = %Assistant{name: "Dev", backend: :claude, is_default: false}
      changeset = Assistant.default_changeset(assistant, true)
      assert Ecto.Changeset.get_change(changeset, :is_default) == true
    end

    test "sets is_default to false" do
      assistant = %Assistant{name: "Dev", backend: :claude, is_default: true}
      changeset = Assistant.default_changeset(assistant, false)
      assert Ecto.Changeset.get_change(changeset, :is_default) == false
    end

    test "rejects non-boolean" do
      assistant = %Assistant{name: "Dev", backend: :claude}

      assert_raise FunctionClauseError, fn ->
        Assistant.default_changeset(assistant, "yes")
      end
    end

    test "rejects non-struct" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Assistant, :default_changeset, [%{}, true])
      end
    end
  end
end
