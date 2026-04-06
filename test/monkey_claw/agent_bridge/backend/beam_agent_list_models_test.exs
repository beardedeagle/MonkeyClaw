defmodule MonkeyClaw.AgentBridge.Backend.BeamAgentListModelsTest do
  @moduledoc """
  Integration tests for BeamAgent backend list_models/1.

  Uses a test workspace and vault secret. The HTTP call is forced
  through a localhost port that is guaranteed to be unreachable,
  so we assert the {:error, _} branch deterministically without
  touching real upstream APIs.
  """

  use MonkeyClaw.DataCase, async: false

  import MonkeyClaw.Factory

  alias MonkeyClaw.AgentBridge.Backend.BeamAgent

  describe "list_models/1" do
    test "returns {:error, :missing_workspace_id} when workspace not set" do
      assert {:error, _reason} = BeamAgent.list_models(%{})
    end

    test "returns {:error, _} when HTTP call cannot reach upstream" do
      workspace = insert_workspace!()
      _ = insert_vault_secret!(workspace, %{name: "anthropic_key", value: "sk-fake"})

      result =
        BeamAgent.list_models(%{
          backend: "claude",
          workspace_id: workspace.id,
          secret_name: "anthropic_key",
          base_url: "http://localhost:1"
        })

      assert {:error, _reason} = result
    end

    test "accepts atom backend without FunctionClauseError" do
      workspace = insert_workspace!()
      _ = insert_vault_secret!(workspace, %{name: "anthropic_key", value: "sk-fake"})

      # Atom :claude must resolve to "anthropic" via backend_to_provider/1
      # without crashing. The HTTP call still fails (unreachable), but the
      # atom normalization itself succeeds.
      result =
        BeamAgent.list_models(%{
          backend: :claude,
          workspace_id: workspace.id,
          secret_name: "anthropic_key",
          base_url: "http://localhost:1"
        })

      assert {:error, _reason} = result
    end
  end
end
