defmodule MonkeyClaw.AgentBridge.CapabilitiesTest do
  # async: false — BeamAgent capabilities touch the globally-named
  # :beam_agent_registry ETS table. Without beam_agent_table_owner
  # initialization, ensure_table/2 creates the table in the calling
  # process (public mode default). Concurrent test processes race on
  # this shared named table: one process creates it, another sees it
  # via ets:whereis, the creator dies (destroying the table), and the
  # other crashes on ets:insert. OTP 28 scheduler changes make this
  # race reliably reproducible.
  use ExUnit.Case, async: false

  alias MonkeyClaw.AgentBridge.Capabilities

  describe "all_ids/0" do
    test "returns a non-empty list of atoms" do
      ids = Capabilities.all_ids()

      assert is_list(ids)
      assert ids != []
      assert Enum.all?(ids, &is_atom/1)
    end

    test "includes known capability IDs" do
      ids = Capabilities.all_ids()

      assert :session_lifecycle in ids
      assert :thread_management in ids
    end
  end

  describe "all/0" do
    test "returns a non-empty list of capability info" do
      caps = Capabilities.all()

      assert is_list(caps)
      assert caps != []
    end
  end

  describe "backends/0" do
    test "returns all five backends" do
      backends = Capabilities.backends()

      assert is_list(backends)
      assert :claude in backends
      assert :codex in backends
      assert :gemini in backends
      assert :opencode in backends
      assert :copilot in backends
    end
  end

  describe "supports?/2" do
    test "returns true for session_lifecycle on claude" do
      assert Capabilities.supports?(:session_lifecycle, :claude)
    end

    test "returns boolean for any valid capability/backend pair" do
      result = Capabilities.supports?(:thread_management, :gemini)
      assert is_boolean(result)
    end

    test "returns false for unknown capability" do
      refute Capabilities.supports?(:nonexistent_capability, :claude)
    end

    test "rejects non-atom capability" do
      assert_raise FunctionClauseError, fn ->
        Capabilities.supports?("string", :claude)
      end
    end

    test "rejects non-atom backend" do
      assert_raise FunctionClauseError, fn ->
        Capabilities.supports?(:session_lifecycle, "claude")
      end
    end
  end

  describe "status/2" do
    test "returns {:ok, info} for valid capability/backend" do
      assert {:ok, info} = Capabilities.status(:session_lifecycle, :claude)
      assert is_map(info)
    end
  end

  describe "for_backend/1" do
    test "returns {:ok, capabilities} for a valid backend" do
      assert {:ok, caps} = Capabilities.for_backend(:claude)
      assert is_list(caps)
    end

    test "rejects non-atom input" do
      assert_raise FunctionClauseError, fn ->
        Capabilities.for_backend("claude")
      end
    end
  end

  describe "for_session/1" do
    test "rejects non-pid input" do
      assert_raise FunctionClauseError, fn ->
        Capabilities.for_session("not-a-pid")
      end
    end
  end
end
