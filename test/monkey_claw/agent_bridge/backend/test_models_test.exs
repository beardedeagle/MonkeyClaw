defmodule MonkeyClaw.AgentBridge.Backend.TestModelsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge.Backend.Test, as: TestBackend

  describe "list_models/1" do
    test "default response returns a canned list" do
      assert {:ok, models} = TestBackend.list_models(%{})
      assert is_list(models)
      assert models != []

      assert Enum.all?(
               models,
               &match?(%{provider: _, model_id: _, display_name: _, capabilities: _}, &1)
             )
    end

    test "configurable success response via :list_models_response" do
      preset = [%{provider: "anthropic", model_id: "x", display_name: "X", capabilities: %{}}]
      assert {:ok, ^preset} = TestBackend.list_models(%{list_models_response: {:ok, preset}})
    end

    test "configurable error response" do
      assert {:error, :boom} = TestBackend.list_models(%{list_models_response: {:error, :boom}})
    end

    test "delay honors probe_deadline_ms when raising too slow" do
      # Simulate a slow probe that exceeds its own deadline.
      assert {:error, :deadline_exceeded} =
               TestBackend.list_models(%{
                 list_models_delay_ms: 50,
                 probe_deadline_ms: 10
               })
    end

    test "crash response raises" do
      assert_raise RuntimeError, fn ->
        TestBackend.list_models(%{list_models_response: {:crash, "boom"}})
      end
    end
  end
end
