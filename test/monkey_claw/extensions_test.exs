defmodule MonkeyClaw.ExtensionsTest do
  # Not async: tests mutate Application config and :persistent_term
  use ExUnit.Case

  alias MonkeyClaw.Extensions
  alias MonkeyClaw.Extensions.Hook
  alias MonkeyClaw.TestPlugs

  setup do
    Application.delete_env(:monkey_claw, MonkeyClaw.Extensions)
    Extensions.clear_pipelines()

    on_exit(fn ->
      Application.delete_env(:monkey_claw, MonkeyClaw.Extensions)
      Extensions.clear_pipelines()
    end)
  end

  describe "compile_pipelines/0" do
    test "compiles with no config" do
      assert :ok = Extensions.compile_pipelines()
    end

    test "compiles with global plugs" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        global: [{TestPlugs.PassThrough, []}]
      )

      assert :ok = Extensions.compile_pipelines()
      assert Extensions.has_plugs?(:query_pre)
      assert Extensions.has_plugs?(:session_starting)
      assert Extensions.has_plugs?(:channel_deleted)
    end

    test "compiles with hook-specific plugs" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [{TestPlugs.Counter, key: :count}]
        }
      )

      assert :ok = Extensions.compile_pipelines()
      assert Extensions.has_plugs?(:query_pre)
      refute Extensions.has_plugs?(:query_post)
    end

    test "compiles global and hook-specific together" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        global: [{TestPlugs.Assigner, [global: true]}],
        hooks: %{
          query_pre: [{TestPlugs.Counter, key: :count}]
        }
      )

      assert :ok = Extensions.compile_pipelines()

      # Execute to verify global + hook-specific composition
      {:ok, ctx} = Extensions.execute(:query_pre)
      assert ctx.assigns.global == true
      assert ctx.assigns.count == 1

      # query_post has only the global plug
      {:ok, ctx} = Extensions.execute(:query_post)
      assert ctx.assigns.global == true
      refute Map.has_key?(ctx.assigns, :count)
    end

    test "is idempotent" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{query_pre: [{TestPlugs.PassThrough, []}]}
      )

      assert :ok = Extensions.compile_pipelines()
      assert :ok = Extensions.compile_pipelines()
      assert Extensions.has_plugs?(:query_pre)
    end
  end

  describe "execute/2" do
    test "executes pipeline for hook event" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [{TestPlugs.Assigner, [processed: true]}]
        }
      )

      Extensions.compile_pipelines()

      {:ok, ctx} = Extensions.execute(:query_pre, %{prompt: "Hello"})
      assert ctx.event == :query_pre
      assert ctx.data == %{prompt: "Hello"}
      assert ctx.assigns.processed == true
    end

    test "returns error for invalid hook" do
      Extensions.compile_pipelines()
      assert {:error, {:invalid_hook, :not_a_hook}} = Extensions.execute(:not_a_hook)
    end

    test "works with empty pipeline" do
      Extensions.compile_pipelines()
      {:ok, ctx} = Extensions.execute(:query_pre, %{test: true})
      assert ctx.data == %{test: true}
      assert ctx.assigns == %{}
      refute ctx.halted
    end

    test "halted context is returned" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [
            {TestPlugs.Counter, key: :count},
            {TestPlugs.Halter, []},
            {TestPlugs.Counter, key: :count}
          ]
        }
      )

      Extensions.compile_pipelines()

      {:ok, ctx} = Extensions.execute(:query_pre)
      assert ctx.halted
      assert ctx.assigns.count == 1
    end

    test "global plugs execute before hook-specific plugs" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        global: [{TestPlugs.Assigner, [order: "global"]}],
        hooks: %{
          query_pre: [{TestPlugs.Assigner, [order: "hook"]}]
        }
      )

      Extensions.compile_pipelines()

      # The hook-specific Assigner overwrites the global one
      # because it runs second
      {:ok, ctx} = Extensions.execute(:query_pre)
      assert ctx.assigns.order == "hook"
    end

    test "exceptions propagate from pipeline" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [{TestPlugs.Exploder, []}]
        }
      )

      Extensions.compile_pipelines()

      assert_raise RuntimeError, "boom", fn ->
        Extensions.execute(:query_pre)
      end
    end
  end

  describe "active_hooks/0" do
    test "returns empty list when no plugs configured" do
      Extensions.compile_pipelines()
      assert Extensions.active_hooks() == []
    end

    test "returns hooks with configured plugs" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_pre: [{TestPlugs.PassThrough, []}],
          session_starting: [{TestPlugs.PassThrough, []}]
        }
      )

      Extensions.compile_pipelines()

      active = Extensions.active_hooks()
      assert :query_pre in active
      assert :session_starting in active
      refute :query_post in active
    end

    test "includes hooks that only have global plugs" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        global: [{TestPlugs.PassThrough, []}]
      )

      Extensions.compile_pipelines()

      # Every hook should be active because global plugs run on all
      active = Extensions.active_hooks()
      assert length(active) == length(Hook.all())
    end
  end

  describe "has_plugs?/1" do
    test "returns false when no plugs configured" do
      Extensions.compile_pipelines()
      refute Extensions.has_plugs?(:query_pre)
    end

    test "returns true when plugs configured for hook" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{query_pre: [{TestPlugs.PassThrough, []}]}
      )

      Extensions.compile_pipelines()
      assert Extensions.has_plugs?(:query_pre)
    end

    test "returns false for invalid hook" do
      Extensions.compile_pipelines()
      refute Extensions.has_plugs?(:not_a_hook)
    end
  end

  describe "list_plugs/0" do
    test "returns empty list when no plugs configured" do
      assert Extensions.list_plugs() == []
    end

    test "returns configured plug specs" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        global: [{TestPlugs.PassThrough, []}],
        hooks: %{
          query_pre: [{TestPlugs.Counter, key: :count}]
        }
      )

      plugs = Extensions.list_plugs()
      assert {TestPlugs.PassThrough, []} in plugs
      assert {TestPlugs.Counter, [key: :count]} in plugs
    end

    test "deduplicates across global and hooks" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        global: [{TestPlugs.PassThrough, []}],
        hooks: %{
          query_pre: [{TestPlugs.PassThrough, []}]
        }
      )

      plugs = Extensions.list_plugs()
      assert length(plugs) == 1
    end
  end

  describe "clear_pipelines/0" do
    test "clears cached pipelines" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{query_pre: [{TestPlugs.PassThrough, []}]}
      )

      Extensions.compile_pipelines()
      assert Extensions.has_plugs?(:query_pre)

      Extensions.clear_pipelines()
      refute Extensions.has_plugs?(:query_pre)
    end

    test "is safe to call when nothing is compiled" do
      assert :ok = Extensions.clear_pipelines()
    end

    test "is safe to call multiple times" do
      assert :ok = Extensions.clear_pipelines()
      assert :ok = Extensions.clear_pipelines()
    end
  end
end
