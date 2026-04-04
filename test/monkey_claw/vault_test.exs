defmodule MonkeyClaw.VaultTest do
  use MonkeyClaw.DataCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Vault
  alias MonkeyClaw.Vault.{Secret, Token}

  # ──────────────────────────────────────────────
  # create_secret/2
  # ──────────────────────────────────────────────

  describe "create_secret/2" do
    test "creates secret with encrypted value" do
      workspace = insert_workspace!()

      assert {:ok, %Secret{} = secret} =
               Vault.create_secret(workspace, %{name: "api_key", value: "sk-secret"})

      assert secret.workspace_id == workspace.id
      assert secret.name == "api_key"
      # encrypted_value is stored as raw ciphertext, not the original string
      assert is_binary(secret.encrypted_value)
      refute secret.encrypted_value == "sk-secret"
    end

    test "rejects duplicate name in same workspace" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "dup_key", value: "first"})

      assert {:error, changeset} =
               Vault.create_secret(workspace, %{name: "dup_key", value: "second"})

      assert errors_on(changeset)[:name] || errors_on(changeset)[:workspace_id]
    end

    test "allows same name in different workspaces" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()

      assert {:ok, _} = Vault.create_secret(w1, %{name: "shared_name", value: "value-1"})
      assert {:ok, _} = Vault.create_secret(w2, %{name: "shared_name", value: "value-2"})
    end

    test "validates name format — rejects spaces" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Vault.create_secret(workspace, %{name: "bad name", value: "v"})

      assert errors_on(changeset)[:name]
    end

    test "validates name format — rejects dots" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Vault.create_secret(workspace, %{name: "bad.name", value: "v"})

      assert errors_on(changeset)[:name]
    end

    test "validates name format — rejects at-sign" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Vault.create_secret(workspace, %{name: "@bad", value: "v"})

      assert errors_on(changeset)[:name]
    end

    test "validates name length — rejects empty name" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Vault.create_secret(workspace, %{name: "", value: "v"})

      assert errors_on(changeset)[:name]
    end

    test "validates name length — rejects name over 100 characters" do
      workspace = insert_workspace!()
      long_name = String.duplicate("a", 101)

      assert {:error, changeset} =
               Vault.create_secret(workspace, %{name: long_name, value: "v"})

      assert errors_on(changeset)[:name]
    end

    test "accepts name at exactly 100 characters" do
      workspace = insert_workspace!()
      max_name = String.duplicate("a", 100)

      assert {:ok, secret} = Vault.create_secret(workspace, %{name: max_name, value: "v"})
      assert secret.name == max_name
    end

    test "rejects missing name" do
      workspace = insert_workspace!()

      assert {:error, changeset} = Vault.create_secret(workspace, %{value: "sk-secret"})
      assert errors_on(changeset)[:name]
    end

    test "rejects missing value" do
      workspace = insert_workspace!()

      assert {:error, changeset} = Vault.create_secret(workspace, %{name: "my_key"})
      assert errors_on(changeset)[:value]
    end
  end

  # ──────────────────────────────────────────────
  # update_secret/2
  # ──────────────────────────────────────────────

  describe "update_secret/2" do
    test "updates description" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace, %{description: "original"})

      assert {:ok, updated} = Vault.update_secret(secret, %{description: "updated description"})
      assert updated.description == "updated description"
    end

    test "updates provider" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace)

      assert {:ok, updated} = Vault.update_secret(secret, %{provider: "anthropic"})
      assert updated.provider == "anthropic"
    end

    test "clears provider when set to nil" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace, %{})
      {:ok, secret_with_provider} = Vault.update_secret(secret, %{provider: "openai"})

      assert {:ok, cleared} = Vault.update_secret(secret_with_provider, %{provider: nil})
      assert cleared.provider == nil
    end

    test "rejects invalid provider" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace)

      assert {:error, changeset} = Vault.update_secret(secret, %{provider: "unknown_provider"})
      assert errors_on(changeset)[:provider]
    end

    test "does not change name (name is immutable after create)" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace, %{name: "original_name"})

      # update_changeset only accepts :description and :provider — name is ignored
      {:ok, updated} = Vault.update_secret(secret, %{description: "new desc"})
      assert updated.name == "original_name"
    end
  end

  # ──────────────────────────────────────────────
  # delete_secret/1
  # ──────────────────────────────────────────────

  describe "delete_secret/1" do
    test "removes secret from database" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace)

      assert {:ok, _} = Vault.delete_secret(secret)
      assert {:error, :not_found} = Vault.get_secret(secret.id)
    end
  end

  # ──────────────────────────────────────────────
  # get_secret/1
  # ──────────────────────────────────────────────

  describe "get_secret/1" do
    test "returns {:ok, secret} for existing ID" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace)

      assert {:ok, found} = Vault.get_secret(secret.id)
      assert found.id == secret.id
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Vault.get_secret(Ecto.UUID.generate())
    end
  end

  # ──────────────────────────────────────────────
  # get_secret_by_name/2
  # ──────────────────────────────────────────────

  describe "get_secret_by_name/2" do
    test "returns {:ok, secret} for existing name in workspace" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "my_api_key"})

      assert {:ok, found} = Vault.get_secret_by_name(workspace.id, "my_api_key")
      assert found.name == "my_api_key"
      assert found.workspace_id == workspace.id
    end

    test "returns {:error, :not_found} for missing name" do
      workspace = insert_workspace!()

      assert {:error, :not_found} = Vault.get_secret_by_name(workspace.id, "nonexistent")
    end

    test "returns {:error, :not_found} when name exists in different workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_vault_secret!(w1, %{name: "shared"})

      assert {:error, :not_found} = Vault.get_secret_by_name(w2.id, "shared")
    end
  end

  # ──────────────────────────────────────────────
  # list_secrets/1
  # ──────────────────────────────────────────────

  describe "list_secrets/1" do
    test "returns all secrets for workspace ordered by name" do
      workspace = insert_workspace!()
      insert_vault_secret!(workspace, %{name: "beta_key"})
      insert_vault_secret!(workspace, %{name: "alpha_key"})
      insert_vault_secret!(workspace, %{name: "gamma_key"})

      secrets = Vault.list_secrets(workspace.id)
      assert length(secrets) == 3
      names = Enum.map(secrets, & &1.name)
      assert names == Enum.sort(names)
    end

    test "returns [] for workspace with no secrets" do
      workspace = insert_workspace!()

      assert [] = Vault.list_secrets(workspace.id)
    end

    test "scopes to workspace — does not return secrets from other workspaces" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_vault_secret!(w1)
      insert_vault_secret!(w2)

      secrets = Vault.list_secrets(w1.id)
      assert length(secrets) == 1
      assert hd(secrets).workspace_id == w1.id
    end

    test "security: encrypted_value is raw ciphertext binary, not the original plaintext" do
      workspace = insert_workspace!()
      plaintext = "super-secret-api-key"
      insert_vault_secret!(workspace, %{name: "secure_key", value: plaintext})

      [secret] = Vault.list_secrets(workspace.id)

      # The stored value must not equal the original plaintext
      refute secret.encrypted_value == plaintext
      # It must be a binary (ciphertext)
      assert is_binary(secret.encrypted_value)
      # It must be longer than the plaintext due to IV + tag overhead
      assert byte_size(secret.encrypted_value) > byte_size(plaintext)
    end
  end

  # ──────────────────────────────────────────────
  # resolve_secret/2
  # ──────────────────────────────────────────────

  describe "resolve_secret/2" do
    test "returns decrypted plaintext for existing secret" do
      workspace = insert_workspace!()
      plaintext = "sk-ant-api03-test-value"
      insert_vault_secret!(workspace, %{name: "resolve_me", value: plaintext})

      assert {:ok, ^plaintext} = Vault.resolve_secret(workspace.id, "resolve_me")
    end

    test "returns {:error, :not_found} for missing secret name" do
      workspace = insert_workspace!()

      assert {:error, :not_found} = Vault.resolve_secret(workspace.id, "does_not_exist")
    end

    test "cross-workspace isolation: cannot resolve secret from different workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_vault_secret!(w1, %{name: "isolated_key", value: "w1-secret"})

      assert {:error, :not_found} = Vault.resolve_secret(w2.id, "isolated_key")
    end

    test "resolve_secret updates last_used_at" do
      workspace = insert_workspace!()
      secret = insert_vault_secret!(workspace, %{name: "touch_me", value: "value"})
      assert secret.last_used_at == nil

      {:ok, _plaintext} = Vault.resolve_secret(workspace.id, "touch_me")

      # resolve_secret/2 updates last_used_at synchronously.

      {:ok, refreshed} = Vault.get_secret(secret.id)
      assert refreshed.last_used_at != nil
    end
  end

  # ──────────────────────────────────────────────
  # store_token/2
  # ──────────────────────────────────────────────

  describe "store_token/2" do
    test "creates new token" do
      workspace = insert_workspace!()

      assert {:ok, %Token{} = token} =
               Vault.store_token(workspace, %{
                 provider: "anthropic",
                 access_token: "tok-abc123"
               })

      assert token.workspace_id == workspace.id
      assert token.provider == "anthropic"
    end

    test "upserts — updates existing token for same provider" do
      workspace = insert_workspace!()
      {:ok, _first} = Vault.store_token(workspace, %{provider: "openai", access_token: "tok-v1"})

      assert {:ok, updated} =
               Vault.store_token(workspace, %{provider: "openai", access_token: "tok-v2"})

      assert updated.access_token == "tok-v2"

      # Only one token exists for this provider
      tokens = Vault.list_tokens(workspace.id)
      openai_tokens = Enum.filter(tokens, &(&1.provider == "openai"))
      assert length(openai_tokens) == 1
    end

    test "rejects missing required provider" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Vault.store_token(workspace, %{access_token: "tok-abc"})

      assert errors_on(changeset)[:provider]
    end

    test "rejects missing required access_token" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Vault.store_token(workspace, %{provider: "anthropic"})

      assert errors_on(changeset)[:access_token]
    end

    test "rejects invalid provider" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Vault.store_token(workspace, %{
                 provider: "unknown_provider",
                 access_token: "tok-abc"
               })

      assert errors_on(changeset)[:provider]
    end
  end

  # ──────────────────────────────────────────────
  # get_token/2
  # ──────────────────────────────────────────────

  describe "get_token/2" do
    test "returns {:ok, token} for existing provider in workspace" do
      workspace = insert_workspace!()
      insert_vault_token!(workspace, %{provider: "google"})

      assert {:ok, token} = Vault.get_token(workspace.id, "google")
      assert token.provider == "google"
      assert token.workspace_id == workspace.id
    end

    test "returns {:error, :not_found} for missing provider" do
      workspace = insert_workspace!()

      assert {:error, :not_found} = Vault.get_token(workspace.id, "anthropic")
    end

    test "returns {:error, :not_found} when provider exists in different workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_vault_token!(w1, %{provider: "openai"})

      assert {:error, :not_found} = Vault.get_token(w2.id, "openai")
    end

    test "returns {:error, :not_found} for nil provider" do
      workspace = insert_workspace!()

      assert {:error, :not_found} = Vault.get_token(workspace.id, nil)
    end
  end

  # ──────────────────────────────────────────────
  # delete_token/1
  # ──────────────────────────────────────────────

  describe "delete_token/1" do
    test "removes token from database" do
      workspace = insert_workspace!()
      token = insert_vault_token!(workspace, %{provider: "anthropic"})

      assert {:ok, _} = Vault.delete_token(token)
      assert {:error, :not_found} = Vault.get_token(workspace.id, "anthropic")
    end
  end

  # ──────────────────────────────────────────────
  # resolve_token/2
  # ──────────────────────────────────────────────

  describe "resolve_token/2" do
    test "returns access_token plaintext for valid non-expired token" do
      workspace = insert_workspace!()
      access_token = "Bearer-test-access-token-xyz"

      insert_vault_token!(workspace, %{
        provider: "anthropic",
        access_token: access_token
      })

      assert {:ok, ^access_token} = Vault.resolve_token(workspace.id, "anthropic")
    end

    test "returns {:error, :not_found} for missing provider" do
      workspace = insert_workspace!()

      assert {:error, :not_found} = Vault.resolve_token(workspace.id, "openai")
    end

    test "returns {:error, :expired} for expired token" do
      workspace = insert_workspace!()
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      insert_vault_token!(workspace, %{
        provider: "google",
        access_token: "expired-token",
        expires_at: past
      })

      assert {:error, :expired} = Vault.resolve_token(workspace.id, "google")
    end

    test "returns access_token for token with future expiry" do
      workspace = insert_workspace!()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      access_token = "valid-future-token"

      insert_vault_token!(workspace, %{
        provider: "github_copilot",
        access_token: access_token,
        expires_at: future
      })

      assert {:ok, ^access_token} = Vault.resolve_token(workspace.id, "github_copilot")
    end
  end

  # ──────────────────────────────────────────────
  # token_expired?/1
  # ──────────────────────────────────────────────

  describe "token_expired?/1" do
    test "returns false for nil expires_at (token does not expire)" do
      workspace = insert_workspace!()
      token = insert_vault_token!(workspace, %{provider: "anthropic"})
      assert token.expires_at == nil
      refute Vault.token_expired?(token)
    end

    test "returns true for past expires_at" do
      workspace = insert_workspace!()
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      {:ok, token} =
        Vault.store_token(workspace, %{
          provider: "openai",
          access_token: "tok",
          expires_at: past
        })

      assert Vault.token_expired?(token)
    end

    test "returns false for future expires_at" do
      workspace = insert_workspace!()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, token} =
        Vault.store_token(workspace, %{
          provider: "google",
          access_token: "tok",
          expires_at: future
        })

      refute Vault.token_expired?(token)
    end
  end

  # ──────────────────────────────────────────────
  # list_tokens/1
  # ──────────────────────────────────────────────

  describe "list_tokens/1" do
    test "returns tokens ordered by provider" do
      workspace = insert_workspace!()
      insert_vault_token!(workspace, %{provider: "openai"})
      insert_vault_token!(workspace, %{provider: "anthropic"})
      insert_vault_token!(workspace, %{provider: "google"})

      tokens = Vault.list_tokens(workspace.id)
      assert length(tokens) == 3
      providers = Enum.map(tokens, & &1.provider)
      assert providers == Enum.sort(providers)
    end

    test "returns [] for workspace with no tokens" do
      workspace = insert_workspace!()

      assert [] = Vault.list_tokens(workspace.id)
    end

    test "scopes to workspace — does not return tokens from other workspaces" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_vault_token!(w1, %{provider: "anthropic"})
      insert_vault_token!(w2, %{provider: "openai"})

      tokens = Vault.list_tokens(w1.id)
      assert length(tokens) == 1
      assert hd(tokens).workspace_id == w1.id
    end
  end
end
