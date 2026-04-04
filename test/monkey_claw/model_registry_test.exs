defmodule MonkeyClaw.ModelRegistryTest do
  @moduledoc """
  Integration tests for ModelRegistry and its sub-modules.

  Tests run serially (async: false) because:
    - ModelRegistry registers under __MODULE__ (a fixed atom name)
    - ETS table uses the hardcoded :monkey_claw_model_registry atom
    - start_supervised! tears the process down after each test,
      releasing both the name and the ETS table for the next test
  """

  use MonkeyClaw.DataCase, async: false

  import MonkeyClaw.Factory

  alias MonkeyClaw.ModelRegistry
  alias MonkeyClaw.ModelRegistry.CachedModel
  alias MonkeyClaw.ModelRegistry.Provider
  alias MonkeyClaw.Repo

  # ──────────────────────────────────────────────
  # CachedModel changeset tests
  # ──────────────────────────────────────────────

  describe "CachedModel.create_changeset/2" do
    test "valid attrs produces a valid changeset" do
      attrs = %{
        provider: "anthropic",
        model_id: "claude-3-opus-20240229",
        display_name: "Claude 3 Opus",
        capabilities: %{"context_window" => 200_000},
        refreshed_at: DateTime.utc_now()
      }

      changeset = CachedModel.create_changeset(%CachedModel{}, attrs)
      assert changeset.valid?
    end

    test "requires provider" do
      attrs = %{
        model_id: "gpt-4",
        display_name: "GPT-4",
        refreshed_at: DateTime.utc_now()
      }

      changeset = CachedModel.create_changeset(%CachedModel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:provider]
    end

    test "requires model_id" do
      attrs = %{
        provider: "openai",
        display_name: "GPT-4",
        refreshed_at: DateTime.utc_now()
      }

      changeset = CachedModel.create_changeset(%CachedModel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:model_id]
    end

    test "requires display_name" do
      attrs = %{
        provider: "openai",
        model_id: "gpt-4",
        refreshed_at: DateTime.utc_now()
      }

      changeset = CachedModel.create_changeset(%CachedModel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:display_name]
    end

    test "requires refreshed_at" do
      attrs = %{
        provider: "openai",
        model_id: "gpt-4",
        display_name: "GPT-4"
      }

      changeset = CachedModel.create_changeset(%CachedModel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:refreshed_at]
    end

    test "rejects unknown provider" do
      attrs = %{
        provider: "unknown_provider",
        model_id: "some-model",
        display_name: "Some Model",
        refreshed_at: DateTime.utc_now()
      }

      changeset = CachedModel.create_changeset(%CachedModel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:provider]
    end

    test "accepts all valid providers" do
      now = DateTime.utc_now()

      for provider <- CachedModel.valid_providers() do
        attrs = %{
          provider: provider,
          model_id: "model-#{provider}",
          display_name: "Model #{provider}",
          refreshed_at: now
        }

        changeset = CachedModel.create_changeset(%CachedModel{}, attrs)
        assert changeset.valid?, "expected valid changeset for provider #{provider}"
      end
    end

    test "unique constraint on [:provider, :model_id]" do
      now = DateTime.utc_now()

      attrs = %{
        provider: "anthropic",
        model_id: "claude-3-opus-20240229",
        display_name: "Claude 3 Opus",
        refreshed_at: now
      }

      {:ok, _} =
        %CachedModel{}
        |> CachedModel.create_changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %CachedModel{}
        |> CachedModel.create_changeset(attrs)
        |> Repo.insert()

      assert errors_on(changeset)[:model_id] || errors_on(changeset)[:provider]
    end
  end

  describe "CachedModel.update_changeset/2" do
    test "updates display_name and capabilities" do
      now = DateTime.utc_now()

      {:ok, model} =
        %CachedModel{}
        |> CachedModel.create_changeset(%{
          provider: "openai",
          model_id: "gpt-4",
          display_name: "GPT-4",
          capabilities: %{},
          refreshed_at: now
        })
        |> Repo.insert()

      {:ok, updated} =
        model
        |> CachedModel.update_changeset(%{
          display_name: "GPT-4 Turbo",
          capabilities: %{"context_window" => 128_000},
          refreshed_at: DateTime.utc_now()
        })
        |> Repo.update()

      assert updated.display_name == "GPT-4 Turbo"
      assert updated.capabilities == %{"context_window" => 128_000}
    end

    test "update_changeset requires refreshed_at" do
      now = DateTime.utc_now()

      {:ok, model} =
        %CachedModel{}
        |> CachedModel.create_changeset(%{
          provider: "openai",
          model_id: "gpt-4-update-required",
          display_name: "GPT-4",
          capabilities: %{},
          refreshed_at: now
        })
        |> Repo.insert()

      # Explicitly pass refreshed_at: nil so cast clears the existing value,
      # causing validate_required to reject the changeset.
      changeset =
        CachedModel.update_changeset(model, %{display_name: "New Name", refreshed_at: nil})

      refute changeset.valid?
      assert errors_on(changeset)[:refreshed_at]
    end
  end

  describe "CachedModel.valid_providers/0" do
    test "returns the expected provider list" do
      providers = CachedModel.valid_providers()
      assert is_list(providers)
      assert "anthropic" in providers
      assert "openai" in providers
      assert "google" in providers
      assert "github_copilot" in providers
      assert "local" in providers
    end
  end

  # ──────────────────────────────────────────────
  # GenServer lifecycle tests
  # ──────────────────────────────────────────────

  describe "ModelRegistry GenServer lifecycle" do
    setup do
      # ModelRegistry is disabled in test.exs (:start_model_registry false).
      # Start a test-controlled instance with a very long refresh interval
      # so the periodic timer never fires during the test.
      start_supervised!({ModelRegistry, [refresh_interval_ms: :timer.hours(24)]})

      :ok
    end

    test "starts and the ETS table is accessible" do
      assert :ets.whereis(:monkey_claw_model_registry) != :undefined
    end

    test "list_models/1 returns empty list when no cached models exist" do
      assert ModelRegistry.list_models("anthropic") == []
      assert ModelRegistry.list_models("openai") == []
      assert ModelRegistry.list_models("google") == []
      assert ModelRegistry.list_models("local") == []
    end

    test "list_all_models/0 returns empty map when no cached models exist" do
      assert ModelRegistry.list_all_models() == %{}
    end

    test "list_models/1 returns models seeded in DB on startup load" do
      now = DateTime.utc_now()

      {:ok, model} =
        %CachedModel{}
        |> CachedModel.create_changeset(%{
          provider: "anthropic",
          model_id: "claude-test-model",
          display_name: "Claude Test",
          capabilities: %{},
          refreshed_at: now
        })
        |> Repo.insert()

      # Force ETS to reflect the DB state by stopping and restarting the registry.
      # The init callback calls load_all_from_sqlite/1, which populates ETS from DB.
      stop_supervised!(ModelRegistry)

      start_supervised!({ModelRegistry, [refresh_interval_ms: :timer.hours(24)]})

      models = ModelRegistry.list_models("anthropic")
      assert length(models) == 1
      assert hd(models).id == model.id
      assert hd(models).model_id == "claude-test-model"
    end

    test "list_all_models/0 groups models by provider after DB seed" do
      now = DateTime.utc_now()

      Repo.insert!(
        CachedModel.create_changeset(%CachedModel{}, %{
          provider: "anthropic",
          model_id: "claude-a",
          display_name: "Claude A",
          capabilities: %{},
          refreshed_at: now
        })
      )

      Repo.insert!(
        CachedModel.create_changeset(%CachedModel{}, %{
          provider: "openai",
          model_id: "gpt-a",
          display_name: "GPT A",
          capabilities: %{},
          refreshed_at: now
        })
      )

      # Restart to pick up the DB rows via load_all_from_sqlite.
      stop_supervised!(ModelRegistry)

      start_supervised!({ModelRegistry, [refresh_interval_ms: :timer.hours(24)]})

      result = ModelRegistry.list_all_models()

      assert Map.has_key?(result, "anthropic")
      assert Map.has_key?(result, "openai")
      assert length(result["anthropic"]) == 1
      assert length(result["openai"]) == 1
    end

    test "configure/1 updates workspace_id in state" do
      workspace = insert_workspace!()
      :ok = ModelRegistry.configure(workspace_id: workspace.id)
      # configure/1 returns :ok — verify by calling it again with the same value
      assert :ok = ModelRegistry.configure(workspace_id: workspace.id)
    end

    test "configure/1 updates provider_secrets in state" do
      :ok = ModelRegistry.configure(provider_secrets: %{"anthropic" => "my_key"})
      assert :ok = ModelRegistry.configure(provider_secrets: %{})
    end

    test "configure/1 accepts partial opts (only workspace_id)" do
      assert :ok = ModelRegistry.configure(workspace_id: nil)
    end

    test "configure/1 accepts partial opts (only provider_secrets)" do
      assert :ok = ModelRegistry.configure(provider_secrets: %{"openai" => "oai_key"})
    end

    test "GenServer handles unexpected messages without crashing" do
      pid = Process.whereis(ModelRegistry)
      assert is_pid(pid)

      send(pid, :unexpected_message_that_should_be_ignored)

      # Give the GenServer a moment to process the message, then confirm alive.
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "GenServer does not crash when refresh is called with bad provider config" do
      # Configure with a secret name that does not exist in the vault.
      # do_refresh_provider rescues errors and logs a warning — never crashes.
      :ok =
        ModelRegistry.configure(
          workspace_id: Ecto.UUID.generate(),
          provider_secrets: %{"anthropic" => "nonexistent_secret"}
        )

      # refresh/1 returns {:error, _} but the GenServer stays alive.
      result = ModelRegistry.refresh("anthropic")
      assert {:error, _reason} = result

      pid = Process.whereis(ModelRegistry)
      assert Process.alive?(pid)
    end

    test "refresh/1 returns :ok for local provider (no-op fetch)" do
      # Provider.fetch_models("local", _) always returns {:ok, []}
      # so a refresh succeeds and clears any stale rows.
      assert :ok = ModelRegistry.refresh("local")
    end
  end

  # ──────────────────────────────────────────────
  # Provider module tests (no GenServer required)
  # ──────────────────────────────────────────────

  describe "Provider.fetch_models/2" do
    test "fetch_models for github_copilot returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Provider.fetch_models("github_copilot")
    end

    test "fetch_models for local returns {:ok, []}" do
      assert {:ok, []} = Provider.fetch_models("local")
    end

    test "fetch_models for unknown provider returns {:error, {:unknown_provider, _}}" do
      assert {:error, {:unknown_provider, "fantasy_ai"}} =
               Provider.fetch_models("fantasy_ai")
    end

    test "fetch_models for anthropic without api_key or workspace_id returns error" do
      assert {:error, :missing_workspace_id} = Provider.fetch_models("anthropic")
    end

    test "fetch_models for anthropic with workspace_id but no secret_name returns error" do
      assert {:error, :missing_secret_name} =
               Provider.fetch_models("anthropic", workspace_id: Ecto.UUID.generate())
    end

    test "fetch_models for openai without api_key or workspace_id returns error" do
      assert {:error, :missing_workspace_id} = Provider.fetch_models("openai")
    end

    test "fetch_models for google without api_key or workspace_id returns error" do
      assert {:error, :missing_workspace_id} = Provider.fetch_models("google")
    end

    test "fetch_models for anthropic with unreachable base_url returns {:error, _}" do
      # Port 1 is reserved and unreachable — confirms the HTTP error path
      # without hitting the real Anthropic API.
      result =
        Provider.fetch_models("anthropic",
          api_key: "test-key",
          base_url: "http://localhost:1"
        )

      assert {:error, _reason} = result
    end

    test "fetch_models for openai with unreachable base_url returns {:error, _}" do
      result =
        Provider.fetch_models("openai",
          api_key: "test-key",
          base_url: "http://localhost:1"
        )

      assert {:error, _reason} = result
    end

    test "fetch_models for google with unreachable base_url returns {:error, _}" do
      result =
        Provider.fetch_models("google",
          api_key: "test-key",
          base_url: "http://localhost:1"
        )

      assert {:error, _reason} = result
    end

    test "fetch_models for anthropic with invalid api_key returns error" do
      # An empty string is not a valid api_key — resolve_api_key rejects it.
      assert {:error, :invalid_api_key} =
               Provider.fetch_models("anthropic", api_key: "")
    end
  end

  # ──────────────────────────────────────────────
  # Vault-backed provider resolution
  # ──────────────────────────────────────────────

  describe "Provider with vault-resolved api_key" do
    test "fetch_models for anthropic resolves secret and attempts HTTP call" do
      workspace = insert_workspace!()
      _secret = insert_vault_secret!(workspace, %{name: "anthropic_api_key", value: "sk-fake"})

      # The vault resolves the secret successfully, but the HTTP call will fail
      # because "sk-fake" is not a real Anthropic key. The result is an HTTP
      # error (401 or connection error), not a vault error.
      result =
        Provider.fetch_models("anthropic",
          workspace_id: workspace.id,
          secret_name: "anthropic_api_key",
          base_url: "http://localhost:1"
        )

      assert {:error, _reason} = result
    end
  end

  # ──────────────────────────────────────────────
  # ETS cache coherence
  # ──────────────────────────────────────────────

  describe "ETS cache coherence" do
    setup do
      start_supervised!({ModelRegistry, [refresh_interval_ms: :timer.hours(24)]})

      :ok
    end

    test "list_models/1 populates ETS on DB fallback" do
      now = DateTime.utc_now()

      Repo.insert!(
        CachedModel.create_changeset(%CachedModel{}, %{
          provider: "google",
          model_id: "gemini-pro",
          display_name: "Gemini Pro",
          capabilities: %{},
          refreshed_at: now
        })
      )

      # ETS starts empty (registry started before DB insert).
      # list_models triggers the SQLite fallback and populates ETS.
      models = ModelRegistry.list_models("google")
      assert length(models) == 1
      assert hd(models).model_id == "gemini-pro"

      # Second call hits ETS (cache hit) — result is identical.
      models_cached = ModelRegistry.list_models("google")
      assert models_cached == models
    end

    test "list_models/1 returns empty list for provider with no DB rows" do
      assert ModelRegistry.list_models("github_copilot") == []
    end
  end
end
