defmodule MonkeyClaw.AssistantsTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Assistants
  alias MonkeyClaw.Assistants.Assistant
  import MonkeyClaw.Factory

  @valid_attrs %{name: "Dev Assistant", backend: :claude}
  @full_attrs %{
    name: "Full Assistant",
    backend: :claude,
    model: "opus",
    system_prompt: "You are helpful.",
    persona_prompt: "Be concise.",
    context_prompt: "Working on Elixir.",
    cwd: "/home/user",
    max_thinking_tokens: 1000,
    permission_mode: :auto,
    description: "A complete assistant"
  }

  # --- create_assistant/1 ---

  describe "create_assistant/1" do
    test "creates with required attrs" do
      assert {:ok, %Assistant{} = assistant} = Assistants.create_assistant(@valid_attrs)
      assert assistant.name == "Dev Assistant"
      assert assistant.backend == :claude
      assert assistant.is_default == false
      assert assistant.id != nil
    end

    test "creates with all fields" do
      assert {:ok, %Assistant{} = assistant} = Assistants.create_assistant(@full_attrs)
      assert assistant.model == "opus"
      assert assistant.system_prompt == "You are helpful."
      assert assistant.persona_prompt == "Be concise."
      assert assistant.context_prompt == "Working on Elixir."
      assert assistant.cwd == "/home/user"
      assert assistant.max_thinking_tokens == 1000
      assert assistant.permission_mode == :auto
      assert assistant.description == "A complete assistant"
    end

    test "fails without name" do
      assert {:error, changeset} = Assistants.create_assistant(%{backend: :claude})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "fails without backend" do
      assert {:error, changeset} = Assistants.create_assistant(%{name: "Dev"})
      assert errors_on(changeset).backend != []
    end

    test "fails with duplicate name" do
      {:ok, _} = Assistants.create_assistant(@valid_attrs)
      assert {:error, changeset} = Assistants.create_assistant(@valid_attrs)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "ignores is_default on create" do
      attrs = Map.put(@valid_attrs, :is_default, true)
      assert {:ok, assistant} = Assistants.create_assistant(attrs)
      refute assistant.is_default
    end

    test "generates binary_id" do
      {:ok, assistant} = Assistants.create_assistant(@valid_attrs)
      assert is_binary(assistant.id)
      assert byte_size(assistant.id) == 36
    end

    test "sets timestamps" do
      {:ok, assistant} = Assistants.create_assistant(@valid_attrs)
      assert %DateTime{} = assistant.inserted_at
      assert %DateTime{} = assistant.updated_at
    end
  end

  # --- get_assistant/1 ---

  describe "get_assistant/1" do
    test "returns assistant by ID" do
      created = insert_assistant!()
      assert {:ok, found} = Assistants.get_assistant(created.id)
      assert found.id == created.id
      assert found.name == created.name
    end

    test "returns error for nonexistent ID" do
      assert {:error, :not_found} = Assistants.get_assistant(Ecto.UUID.generate())
    end

    test "rejects empty string" do
      assert_raise FunctionClauseError, fn ->
        Assistants.get_assistant("")
      end
    end
  end

  # --- get_assistant!/1 ---

  describe "get_assistant!/1" do
    test "returns assistant by ID" do
      created = insert_assistant!()
      found = Assistants.get_assistant!(created.id)
      assert found.id == created.id
    end

    test "raises for nonexistent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Assistants.get_assistant!(Ecto.UUID.generate())
      end
    end
  end

  # --- list_assistants/0 ---

  describe "list_assistants/0" do
    test "returns empty list when no assistants" do
      assert [] = Assistants.list_assistants()
    end

    test "returns all assistants ordered by name" do
      {:ok, _} = Assistants.create_assistant(%{name: "Charlie", backend: :claude})
      {:ok, _} = Assistants.create_assistant(%{name: "Alpha", backend: :gemini})
      {:ok, _} = Assistants.create_assistant(%{name: "Bravo", backend: :codex})

      assistants = Assistants.list_assistants()
      assert length(assistants) == 3
      assert [%{name: "Alpha"}, %{name: "Bravo"}, %{name: "Charlie"}] = assistants
    end
  end

  # --- update_assistant/2 ---

  describe "update_assistant/2" do
    test "updates name" do
      assistant = insert_assistant!()
      assert {:ok, updated} = Assistants.update_assistant(assistant, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "updates backend" do
      assistant = insert_assistant!()
      assert {:ok, updated} = Assistants.update_assistant(assistant, %{backend: :gemini})
      assert updated.backend == :gemini
    end

    test "updates prompt layers" do
      assistant = insert_assistant!()

      assert {:ok, updated} =
               Assistants.update_assistant(assistant, %{
                 system_prompt: "New identity.",
                 persona_prompt: "New personality."
               })

      assert updated.system_prompt == "New identity."
      assert updated.persona_prompt == "New personality."
    end

    test "fails with invalid attrs" do
      assistant = insert_assistant!()
      assert {:error, _} = Assistants.update_assistant(assistant, %{name: ""})
    end

    test "fails with duplicate name" do
      {:ok, _} = Assistants.create_assistant(%{name: "First", backend: :claude})
      {:ok, second} = Assistants.create_assistant(%{name: "Second", backend: :claude})
      assert {:error, changeset} = Assistants.update_assistant(second, %{name: "First"})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "does not change is_default" do
      assistant = insert_assistant!()
      {:ok, updated} = Assistants.update_assistant(assistant, %{is_default: true})
      refute updated.is_default
    end
  end

  # --- delete_assistant/1 ---

  describe "delete_assistant/1" do
    test "deletes the assistant" do
      assistant = insert_assistant!()
      assert {:ok, _} = Assistants.delete_assistant(assistant)
      assert {:error, :not_found} = Assistants.get_assistant(assistant.id)
    end
  end

  # --- get_default_assistant/0 ---

  describe "get_default_assistant/0" do
    test "returns error when no default exists" do
      _assistant = insert_assistant!()
      assert {:error, :no_default} = Assistants.get_default_assistant()
    end

    test "returns the default assistant" do
      created = insert_assistant!()
      {:ok, _} = Assistants.set_default_assistant(created)
      assert {:ok, found} = Assistants.get_default_assistant()
      assert found.id == created.id
    end

    test "returns error when no assistants exist" do
      assert {:error, :no_default} = Assistants.get_default_assistant()
    end
  end

  # --- set_default_assistant/1 ---

  describe "set_default_assistant/1" do
    test "sets assistant as default" do
      assistant = insert_assistant!()
      assert {:ok, updated} = Assistants.set_default_assistant(assistant)
      assert updated.is_default == true
    end

    test "unsets previous default" do
      {:ok, first} = Assistants.create_assistant(%{name: "First", backend: :claude})
      {:ok, _} = Assistants.set_default_assistant(first)

      {:ok, second} = Assistants.create_assistant(%{name: "Second", backend: :gemini})

      assert {:ok, _} = Assistants.set_default_assistant(second)

      # Reload first to verify it's no longer default
      {:ok, reloaded_first} = Assistants.get_assistant(first.id)
      refute reloaded_first.is_default

      # Verify second is now the default
      {:ok, default} = Assistants.get_default_assistant()
      assert default.id == second.id
    end

    test "can re-set same assistant as default" do
      assistant = insert_assistant!()
      {:ok, assistant} = Assistants.set_default_assistant(assistant)

      assert {:ok, updated} = Assistants.set_default_assistant(assistant)
      assert updated.is_default == true
    end
  end

  # --- to_session_opts/1 ---

  describe "to_session_opts/1" do
    test "renders minimal assistant" do
      {:ok, assistant} = Assistants.create_assistant(@valid_attrs)
      opts = Assistants.to_session_opts(assistant)

      assert opts.backend == :claude
      refute Map.has_key?(opts, :model)
      refute Map.has_key?(opts, :system_prompt)
    end

    test "renders full assistant with composed prompt" do
      {:ok, assistant} = Assistants.create_assistant(@full_attrs)
      opts = Assistants.to_session_opts(assistant)

      assert opts.backend == :claude
      assert opts.model == "opus"
      assert opts.cwd == "/home/user"
      assert opts.max_thinking_tokens == 1000
      assert opts.permission_mode == :auto

      # Prompt composed from all three layers
      assert opts.system_prompt =~ "You are helpful."
      assert opts.system_prompt =~ "Be concise."
      assert opts.system_prompt =~ "Working on Elixir."
    end

    test "omits system_prompt when no layers set" do
      {:ok, assistant} = Assistants.create_assistant(@valid_attrs)
      opts = Assistants.to_session_opts(assistant)

      # nil system prompt is omitted by Scope.session_opts/1
      refute Map.has_key?(opts, :system_prompt)
    end

    test "includes composed prompt even with single layer" do
      {:ok, assistant} =
        Assistants.create_assistant(%{
          name: "Prompt Test",
          backend: :claude,
          system_prompt: "You are a coding assistant."
        })

      opts = Assistants.to_session_opts(assistant)
      assert opts.system_prompt == "You are a coding assistant."
    end

    test "rejects non-Assistant struct" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Assistants, :to_session_opts, [%{backend: :claude}])
      end
    end
  end
end
