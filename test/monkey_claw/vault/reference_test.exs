defmodule MonkeyClaw.Vault.ReferenceTest do
  use MonkeyClaw.DataCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Vault.Reference

  # ──────────────────────────────────────────────
  # valid_reference?/1 — syntax only, no DB
  # ──────────────────────────────────────────────

  describe "valid_reference?/1" do
    test "returns true for a simple lowercase name" do
      assert Reference.valid_reference?("@secret:my_key")
    end

    test "returns true for uppercase letters" do
      assert Reference.valid_reference?("@secret:MY_KEY")
    end

    test "returns true for mixed case with digits, underscores, and hyphens" do
      assert Reference.valid_reference?("@secret:MY-KEY_123")
    end

    test "returns true for single character name" do
      assert Reference.valid_reference?("@secret:a")
    end

    test "returns true for 100 character name (max length)" do
      name = String.duplicate("a", 100)
      assert Reference.valid_reference?("@secret:#{name}")
    end

    test "returns false for empty name after prefix" do
      refute Reference.valid_reference?("@secret:")
    end

    test "returns false for name with space" do
      refute Reference.valid_reference?("@secret:a b")
    end

    test "returns false for name with special character" do
      refute Reference.valid_reference?("@secret:a.b")
    end

    test "returns false for name with at-sign" do
      refute Reference.valid_reference?("@secret:a@b")
    end

    test "returns false for name exceeding 100 characters" do
      name = String.duplicate("a", 101)
      refute Reference.valid_reference?("@secret:#{name}")
    end

    test "returns false for plain string without prefix" do
      refute Reference.valid_reference?("not-a-reference")
    end

    test "returns false for partial prefix" do
      refute Reference.valid_reference?("@secret")
    end

    test "returns false for wrong prefix" do
      refute Reference.valid_reference?("@env:my_key")
    end

    test "returns false for integer" do
      refute Reference.valid_reference?(123)
    end

    test "returns false for atom" do
      refute Reference.valid_reference?(:my_key)
    end

    test "returns false for nil" do
      refute Reference.valid_reference?(nil)
    end

    test "returns false for list" do
      refute Reference.valid_reference?(["@secret:key"])
    end
  end

  # ──────────────────────────────────────────────
  # extract_name/1 — syntax only, no DB
  # ──────────────────────────────────────────────

  describe "extract_name/1" do
    test "returns {:ok, name} for valid reference" do
      assert {:ok, "foo"} = Reference.extract_name("@secret:foo")
    end

    test "returns {:ok, name} for name with hyphens and underscores" do
      assert {:ok, "my-API_key"} = Reference.extract_name("@secret:my-API_key")
    end

    test "returns {:ok, name} for name with digits" do
      assert {:ok, "key123"} = Reference.extract_name("@secret:key123")
    end

    test "returns :error for empty name" do
      assert :error = Reference.extract_name("@secret:")
    end

    test "returns :error for name with space" do
      assert :error = Reference.extract_name("@secret:a b")
    end

    test "returns :error for plain string" do
      assert :error = Reference.extract_name("plain")
    end

    test "returns :error for prefix only" do
      assert :error = Reference.extract_name("@secret")
    end

    test "returns :error for non-binary integer" do
      assert :error = Reference.extract_name(42)
    end

    test "returns :error for nil" do
      assert :error = Reference.extract_name(nil)
    end
  end

  # ──────────────────────────────────────────────
  # resolve/2 — requires DB
  # ──────────────────────────────────────────────

  describe "resolve/2" do
    test "resolves existing secret to plaintext" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "api_key", value: "sk-real-value"})

      assert {:ok, "sk-real-value"} = Reference.resolve(workspace.id, "@secret:api_key")
    end

    test "returns {:error, :not_found} for reference to missing secret" do
      workspace = insert_workspace!()

      assert {:error, :not_found} = Reference.resolve(workspace.id, "@secret:missing_key")
    end

    test "returns {:error, :invalid_reference} for bad syntax" do
      workspace = insert_workspace!()

      assert {:error, :invalid_reference} = Reference.resolve(workspace.id, "not-a-reference")
    end

    test "returns {:error, :invalid_reference} for empty name" do
      workspace = insert_workspace!()

      assert {:error, :invalid_reference} = Reference.resolve(workspace.id, "@secret:")
    end

    test "cross-workspace isolation: workspace A secret not resolvable from workspace B" do
      workspace_a = insert_workspace!()
      workspace_b = insert_workspace!()
      insert_vault_secret!(workspace_a, %{name: "shared_name", value: "secret-for-a"})

      # Workspace B has no secret with this name
      assert {:error, :not_found} =
               Reference.resolve(workspace_b.id, "@secret:shared_name")
    end

    test "same name in different workspaces resolves to each workspace's own value" do
      workspace_a = insert_workspace!()
      workspace_b = insert_workspace!()
      insert_vault_secret!(workspace_a, %{name: "api_key", value: "value-for-a"})
      insert_vault_secret!(workspace_b, %{name: "api_key", value: "value-for-b"})

      assert {:ok, "value-for-a"} = Reference.resolve(workspace_a.id, "@secret:api_key")
      assert {:ok, "value-for-b"} = Reference.resolve(workspace_b.id, "@secret:api_key")
    end
  end

  # ──────────────────────────────────────────────
  # resolve_all/2 — requires DB
  # ──────────────────────────────────────────────

  describe "resolve_all/2" do
    test "resolves map with single reference" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "token", value: "resolved-token"})

      data = %{api_key: "@secret:token"}
      assert {:ok, %{api_key: "resolved-token"}} = Reference.resolve_all(workspace.id, data)
    end

    test "leaves non-reference strings unchanged" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "key", value: "secret"})

      data = %{api_key: "@secret:key", model: "claude-sonnet-4-6"}

      assert {:ok, resolved} = Reference.resolve_all(workspace.id, data)
      assert resolved.api_key == "secret"
      assert resolved.model == "claude-sonnet-4-6"
    end

    test "resolves map with mixed reference and plain values" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "my_key", value: "plaintext-value"})

      data = %{
        secret_ref: "@secret:my_key",
        plain_string: "just a string",
        numeric: 42,
        flag: true
      }

      assert {:ok, resolved} = Reference.resolve_all(workspace.id, data)
      assert resolved.secret_ref == "plaintext-value"
      assert resolved.plain_string == "just a string"
      assert resolved.numeric == 42
      assert resolved.flag == true
    end

    test "resolves nested map references" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "nested_key", value: "nested-value"})

      data = %{outer: %{inner: "@secret:nested_key"}}

      assert {:ok, resolved} = Reference.resolve_all(workspace.id, data)
      assert resolved.outer.inner == "nested-value"
    end

    test "returns {:error, {key_path, reason}} for unresolvable reference" do
      workspace = insert_workspace!()

      data = %{api_key: "@secret:does_not_exist"}
      assert {:error, {key_path, :not_found}} = Reference.resolve_all(workspace.id, data)
      assert :api_key in key_path
    end

    test "returns error on first unresolvable reference (short-circuits)" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "good_key", value: "good-value"})

      data = %{
        good: "@secret:good_key",
        bad: "@secret:missing_key"
      }

      assert {:error, {key_path, :not_found}} = Reference.resolve_all(workspace.id, data)
      assert :bad in key_path
    end

    test "resolves keyword list with references" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "kw_key", value: "kw-value"})

      data = [api_key: "@secret:kw_key", model: "gpt-4"]

      assert {:ok, resolved} = Reference.resolve_all(workspace.id, data)
      assert Keyword.get(resolved, :api_key) == "kw-value"
      assert Keyword.get(resolved, :model) == "gpt-4"
    end

    test "empty map resolves to empty map" do
      workspace = insert_workspace!()

      assert {:ok, %{}} = Reference.resolve_all(workspace.id, %{})
    end
  end
end
