defmodule MonkeyClaw.AgentBridge.ScopeTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge.Scope

  # --- memory_scope/1 ---

  describe "memory_scope/1" do
    test "returns workspace ID as session-level scope" do
      assert Scope.memory_scope("workspace-123") == "workspace-123"
    end

    test "accepts any non-empty binary" do
      assert Scope.memory_scope("a") == "a"
      assert Scope.memory_scope("uuid-v4-here") == "uuid-v4-here"
    end

    test "rejects empty string" do
      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope("")
      end
    end

    test "rejects non-binary input" do
      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope(123)
      end

      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope(:atom)
      end

      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope(nil)
      end
    end
  end

  # --- memory_scope/3 ---

  describe "memory_scope/3" do
    test "returns fully-scoped tuple" do
      assert Scope.memory_scope("ws-1", "ch-2", "run-3") == {"ws-1", "ch-2", "run-3"}
    end

    test "rejects empty workspace_id" do
      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope("", "ch", "run")
      end
    end

    test "rejects empty channel_id" do
      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope("ws", "", "run")
      end
    end

    test "rejects empty run_id" do
      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope("ws", "ch", "")
      end
    end

    test "rejects non-binary arguments" do
      assert_raise FunctionClauseError, fn ->
        Scope.memory_scope(1, "ch", "run")
      end
    end
  end

  # --- session_opts/1 ---

  describe "session_opts/1" do
    test "maps :backend" do
      assert Scope.session_opts(%{backend: :claude}) == %{backend: :claude}
    end

    test "maps :model" do
      assert Scope.session_opts(%{model: "opus"}) == %{model: "opus"}
    end

    test "maps :system_prompt including empty string" do
      assert Scope.session_opts(%{system_prompt: "You are helpful."}) ==
               %{system_prompt: "You are helpful."}

      # Empty system prompt is valid (allows clearing)
      assert Scope.session_opts(%{system_prompt: ""}) == %{system_prompt: ""}
    end

    test "maps :cwd" do
      assert Scope.session_opts(%{cwd: "/home/user"}) == %{cwd: "/home/user"}
    end

    test "maps :max_thinking_tokens for positive integers" do
      assert Scope.session_opts(%{max_thinking_tokens: 1000}) ==
               %{max_thinking_tokens: 1000}
    end

    test "maps valid :permission_mode values" do
      assert Scope.session_opts(%{permission_mode: :auto}) == %{permission_mode: :auto}
      assert Scope.session_opts(%{permission_mode: :manual}) == %{permission_mode: :manual}

      assert Scope.session_opts(%{permission_mode: :accept_edits}) ==
               %{permission_mode: :accept_edits}
    end

    test "maps multiple options" do
      opts = Scope.session_opts(%{backend: :claude, model: "opus", cwd: "/tmp"})

      assert opts.backend == :claude
      assert opts.model == "opus"
      assert opts.cwd == "/tmp"
      assert map_size(opts) == 3
    end

    test "ignores nil backend" do
      assert Scope.session_opts(%{backend: nil}) == %{}
    end

    test "ignores empty model string" do
      assert Scope.session_opts(%{model: ""}) == %{}
    end

    test "ignores empty cwd string" do
      assert Scope.session_opts(%{cwd: ""}) == %{}
    end

    test "ignores zero and negative max_thinking_tokens" do
      assert Scope.session_opts(%{max_thinking_tokens: 0}) == %{}
      assert Scope.session_opts(%{max_thinking_tokens: -1}) == %{}
    end

    test "ignores invalid permission_mode" do
      assert Scope.session_opts(%{permission_mode: :invalid}) == %{}
      assert Scope.session_opts(%{permission_mode: "auto"}) == %{}
    end

    test "ignores unknown keys" do
      assert Scope.session_opts(%{unknown: "value", foo: :bar}) == %{}
    end

    test "returns empty map for empty map" do
      assert Scope.session_opts(%{}) == %{}
    end

    test "rejects non-map input" do
      assert_raise FunctionClauseError, fn ->
        Scope.session_opts("not a map")
      end
    end
  end

  # --- thread_opts/1 ---

  describe "thread_opts/1" do
    test "maps :name" do
      assert Scope.thread_opts(%{name: "general"}) == %{name: "general"}
    end

    test "maps :metadata" do
      meta = %{topic: "elixir", priority: 1}
      assert Scope.thread_opts(%{metadata: meta}) == %{metadata: meta}
    end

    test "maps both :name and :metadata" do
      opts = Scope.thread_opts(%{name: "dev", metadata: %{x: 1}})
      assert opts.name == "dev"
      assert opts.metadata == %{x: 1}
    end

    test "ignores empty name" do
      assert Scope.thread_opts(%{name: ""}) == %{}
    end

    test "ignores non-map metadata" do
      assert Scope.thread_opts(%{metadata: "not a map"}) == %{}
      assert Scope.thread_opts(%{metadata: [1, 2]}) == %{}
    end

    test "returns empty map for empty map" do
      assert Scope.thread_opts(%{}) == %{}
    end

    test "ignores unknown keys" do
      assert Scope.thread_opts(%{unknown: "value"}) == %{}
    end
  end
end
