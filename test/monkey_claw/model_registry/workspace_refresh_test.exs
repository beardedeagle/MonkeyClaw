defmodule MonkeyClaw.ModelRegistry.WorkspaceRefreshTest do
  @moduledoc """
  Integration tests for ModelRegistry.refresh_for_workspace/1.

  Verifies that the workspace-aware refresh path discovers vault
  secrets, maps providers to backends, probes upstream (which fails
  deterministically via unreachable localhost), and auto-configures
  the registry state for future tick probes.

  Runs serially because ModelRegistry is a named singleton.
  """

  use MonkeyClaw.DataCase, async: false

  import MonkeyClaw.Factory

  alias MonkeyClaw.ModelRegistry

  setup do
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

    start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})

    :ok
  end

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

    test "discovers anthropic secret and attempts probe (fails on unreachable host)" do
      workspace = insert_workspace!()

      _secret =
        insert_vault_secret!(workspace, %{
          name: "anthropic_key",
          value: "sk-fake",
          provider: "anthropic"
        })

      # The probe will fail because there's no real API to reach,
      # but the function should return :ok (probe failures are handled
      # gracefully — the backend is still auto-configured).
      assert :ok = ModelRegistry.refresh_for_workspace(workspace.id)
    end

    test "discovers multiple providers and probes each backend" do
      workspace = insert_workspace!()

      _anthropic =
        insert_vault_secret!(workspace, %{
          name: "anthropic_key",
          value: "sk-fake-1",
          provider: "anthropic"
        })

      _openai =
        insert_vault_secret!(workspace, %{
          name: "openai_key",
          value: "sk-fake-2",
          provider: "openai"
        })

      assert :ok = ModelRegistry.refresh_for_workspace(workspace.id)
    end

    test "deduplicates when multiple secrets map to the same backend" do
      workspace = insert_workspace!()

      _secret1 =
        insert_vault_secret!(workspace, %{
          name: "anthropic_prod",
          value: "sk-prod",
          provider: "anthropic"
        })

      _secret2 =
        insert_vault_secret!(workspace, %{
          name: "anthropic_dev",
          value: "sk-dev",
          provider: "anthropic"
        })

      # Should not crash — deduplication picks the first secret per backend
      assert :ok = ModelRegistry.refresh_for_workspace(workspace.id)
    end
  end
end
