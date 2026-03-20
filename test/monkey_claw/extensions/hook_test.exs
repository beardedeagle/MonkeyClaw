defmodule MonkeyClaw.Extensions.HookTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Extensions.Hook

  describe "all/0" do
    test "returns all hook points" do
      hooks = Hook.all()
      assert [_ | _] = hooks

      # Verify representative hooks from each category
      assert :query_pre in hooks
      assert :query_post in hooks
      assert :session_starting in hooks
      assert :session_stopped in hooks
      assert :workspace_created in hooks
      assert :channel_deleted in hooks
    end

    test "returns only atoms" do
      assert Enum.all?(Hook.all(), &is_atom/1)
    end

    test "contains no duplicates" do
      hooks = Hook.all()
      assert hooks == Enum.uniq(hooks)
    end
  end

  describe "valid?/1" do
    test "returns true for all defined hooks" do
      for hook <- Hook.all() do
        assert Hook.valid?(hook), "expected #{inspect(hook)} to be valid"
      end
    end

    test "returns false for unknown atoms" do
      refute Hook.valid?(:not_a_hook)
      refute Hook.valid?(:made_up_event)
    end

    test "returns false for non-atoms" do
      refute Hook.valid?("query_pre")
      refute Hook.valid?(42)
      refute Hook.valid?(nil)
    end
  end
end
