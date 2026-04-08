defmodule MonkeyClaw.ModelRegistry.AuthDiscoveryTest do
  @moduledoc """
  Tests auth-based backend discovery and the probe-to-upsert pipeline.

  Uses the `Backend.Test` adapter for probe isolation — no HTTP calls,
  no mocks, deterministic responses. The vault-based `refresh_for_workspace/1`
  path is also exercised since it remains available as a secondary
  discovery mechanism.

  Runs serially because ModelRegistry is a named singleton.
  """

  use MonkeyClaw.DataCase, async: false

  import MonkeyClaw.Factory

  alias MonkeyClaw.AgentBridge.Backend.Test, as: TestBackend
  alias MonkeyClaw.ModelRegistry

  # Suppress log noise from probe failures during tests.
  @moduletag capture_log: true

  setup do
    # Clear baseline so tests start with an empty registry.
    original = Application.get_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
    Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, entries: [])

    on_exit(fn ->
      if original,
        do: Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, original),
        else: Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
    end)

    start_supervised!(
      {MonkeyClaw.ModelRegistry.EtsHeir, [table_name: :monkey_claw_model_registry]}
    )

    # Large delays to prevent auto-tick from interfering with test probes.
    start_supervised!(
      {ModelRegistry,
       [backends: [], default_interval_ms: :timer.hours(24), startup_delay_ms: 600_000]}
    )

    :ok
  end

  # ── Auth-based auto-discovery ──────────────────────────────

  describe "auth-based auto-discovery" do
    test "discovers no backends when no CLI auth is present" do
      # In CI / test, no backends have real CLI auth configured.
      # The registry starts with an empty backend list and auto-discovery
      # finds nothing authenticated.
      assert ModelRegistry.list_for_backend("claude") == []
      assert ModelRegistry.list_for_backend("codex") == []
      assert ModelRegistry.list_for_backend("copilot") == []
      assert ModelRegistry.list_for_backend("opencode") == []
      assert ModelRegistry.list_for_backend("gemini") == []
    end
  end

  # ── Probe pipeline with Test adapter ────────────────────────

  describe "probe pipeline" do
    test "configured backend is probed and models are upserted" do
      :ok =
        ModelRegistry.configure(
          backends: ["claude"],
          backend_configs: %{
            "claude" => %{adapter: TestBackend}
          }
        )

      # TestBackend default response includes anthropic models.
      assert :ok = ModelRegistry.refresh("claude")

      models = ModelRegistry.list_for_backend("claude")
      assert models != []
      assert Enum.all?(models, &(&1.backend == "claude"))
      assert Enum.all?(models, &(&1.provider == "anthropic"))
    end

    test "probe error is handled gracefully — no models cached" do
      :ok =
        ModelRegistry.configure(
          backends: ["codex"],
          backend_configs: %{
            "codex" => %{
              adapter: TestBackend,
              list_models_response: {:error, :not_authenticated}
            }
          }
        )

      assert {:error, :not_authenticated} = ModelRegistry.refresh("codex")
      assert ModelRegistry.list_for_backend("codex") == []
    end

    test "probe upserts custom models into registry" do
      custom_models = [
        %{provider: "openai", model_id: "gpt-4o", display_name: "GPT-4o", capabilities: %{}},
        %{
          provider: "openai",
          model_id: "o3",
          display_name: "O3",
          capabilities: %{reasoning: true}
        }
      ]

      :ok =
        ModelRegistry.configure(
          backends: ["codex"],
          backend_configs: %{
            "codex" => %{
              adapter: TestBackend,
              list_models_response: {:ok, custom_models}
            }
          }
        )

      assert :ok = ModelRegistry.refresh("codex")

      models = ModelRegistry.list_for_backend("codex")
      assert length(models) == 2

      ids = Enum.map(models, & &1.model_id)
      assert "gpt-4o" in ids
      assert "o3" in ids
    end

    test "probe with empty model list marks backend as healthy" do
      :ok =
        ModelRegistry.configure(
          backends: ["gemini"],
          backend_configs: %{
            "gemini" => %{
              adapter: TestBackend,
              list_models_response: {:ok, []}
            }
          }
        )

      assert :ok = ModelRegistry.refresh("gemini")
      assert ModelRegistry.list_for_backend("gemini") == []
    end

    test "multiple backends probed independently" do
      claude_models = [
        %{
          provider: "anthropic",
          model_id: "claude-sonnet-4-6",
          display_name: "Claude Sonnet 4.6",
          capabilities: %{}
        }
      ]

      copilot_models = [
        %{
          provider: "github_copilot",
          model_id: "gpt-4o",
          display_name: "GPT-4o via Copilot",
          capabilities: %{}
        }
      ]

      :ok =
        ModelRegistry.configure(
          backends: ["claude", "copilot"],
          backend_configs: %{
            "claude" => %{adapter: TestBackend, list_models_response: {:ok, claude_models}},
            "copilot" => %{adapter: TestBackend, list_models_response: {:ok, copilot_models}}
          }
        )

      assert :ok = ModelRegistry.refresh("claude")
      assert :ok = ModelRegistry.refresh("copilot")

      claude = ModelRegistry.list_for_backend("claude")
      assert length(claude) == 1
      assert hd(claude).model_id == "claude-sonnet-4-6"

      copilot = ModelRegistry.list_for_backend("copilot")
      assert length(copilot) == 1
      assert hd(copilot).model_id == "gpt-4o"
    end

    test "probe crash applies backoff without crashing the registry" do
      :ok =
        ModelRegistry.configure(
          backends: ["codex"],
          backend_configs: %{
            "codex" => %{
              adapter: TestBackend,
              list_models_response: {:crash, "kaboom"}
            }
          }
        )

      # The probe crashes in a Task — ModelRegistry handles the :DOWN
      # and applies backoff. The GenServer stays alive.
      assert {:error, {:probe_crashed, _}} = ModelRegistry.refresh("codex")

      # Registry is still responsive.
      assert ModelRegistry.list_for_backend("codex") == []
    end
  end

  # ── Vault-based workspace discovery (secondary path) ────────

  describe "refresh_for_workspace/1" do
    test "returns {:error, :no_backends_discovered} when workspace has no secrets" do
      workspace = insert_workspace!()
      assert {:error, :no_backends_discovered} = ModelRegistry.refresh_for_workspace(workspace.id)
    end

    test "returns {:error, :no_backends_discovered} when secrets have no provider" do
      workspace = insert_workspace!()
      _secret = insert_vault_secret!(workspace, %{name: "misc_key"})

      assert {:error, :no_backends_discovered} = ModelRegistry.refresh_for_workspace(workspace.id)
    end

    test "returns {:error, :no_backends_discovered} for unknown provider" do
      workspace = insert_workspace!()
      _secret = insert_vault_secret!(workspace, %{name: "local_key", provider: "local"})

      assert {:error, :no_backends_discovered} = ModelRegistry.refresh_for_workspace(workspace.id)
    end

    test "discovers anthropic secret and probes backend" do
      workspace = insert_workspace!()

      _secret =
        insert_vault_secret!(workspace, %{
          name: "anthropic_key",
          value: "sk-fake",
          provider: "anthropic"
        })

      # The probe will fail because there's no real auth in CI,
      # but refresh_for_workspace returns :ok when at least one
      # backend was discovered (probe failures are handled gracefully).
      assert :ok = ModelRegistry.refresh_for_workspace(workspace.id)
    end
  end
end
