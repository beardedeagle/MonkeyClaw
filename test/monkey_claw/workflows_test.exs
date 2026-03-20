defmodule MonkeyClaw.WorkflowsTest do
  # Not async: delegates to Conversation which performs DB operations
  # through the Ecto SQL sandbox.
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Workflows

  describe "send_message/4" do
    test "delegates to Conversation and returns error for unknown workspace" do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:workspace_not_found, ^fake_id}} =
               Workflows.send_message(fake_id, "general", "Hello")
    end

    test "rejects non-binary arguments" do
      assert_raise FunctionClauseError, fn ->
        Workflows.send_message(123, "general", "Hello")
      end
    end
  end
end
