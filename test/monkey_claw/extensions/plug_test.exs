defmodule MonkeyClaw.Extensions.PlugTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.TestPlugs

  describe "PassThrough plug" do
    test "returns context unchanged" do
      ctx = Context.new!(:query_pre, %{prompt: "Hello"})
      opts = TestPlugs.PassThrough.init([])
      result = TestPlugs.PassThrough.call(ctx, opts)

      assert result.event == ctx.event
      assert result.data == ctx.data
      assert result.assigns == ctx.assigns
    end
  end

  describe "Assigner plug" do
    test "merges assigns from init opts" do
      ctx = Context.new!(:query_pre)
      opts = TestPlugs.Assigner.init(source: "test", count: 42)
      result = TestPlugs.Assigner.call(ctx, opts)

      assert result.assigns.source == "test"
      assert result.assigns.count == 42
    end

    test "init converts keyword list to map" do
      opts = TestPlugs.Assigner.init(key: "value")
      assert opts == %{key: "value"}
    end
  end

  describe "Halter plug" do
    test "halts the context" do
      ctx = Context.new!(:query_pre)
      opts = TestPlugs.Halter.init([])
      result = TestPlugs.Halter.call(ctx, opts)

      assert result.halted
    end
  end

  describe "Counter plug" do
    test "increments counter in assigns" do
      ctx = Context.new!(:query_pre)
      opts = TestPlugs.Counter.init(key: :hits)

      ctx = TestPlugs.Counter.call(ctx, opts)
      assert ctx.assigns.hits == 1

      ctx = TestPlugs.Counter.call(ctx, opts)
      assert ctx.assigns.hits == 2
    end

    test "defaults to :count key" do
      ctx = Context.new!(:query_pre)
      opts = TestPlugs.Counter.init([])

      ctx = TestPlugs.Counter.call(ctx, opts)
      assert ctx.assigns.count == 1
    end
  end

  describe "Exploder plug" do
    test "raises RuntimeError" do
      ctx = Context.new!(:query_pre)
      opts = TestPlugs.Exploder.init([])

      assert_raise RuntimeError, "boom", fn ->
        TestPlugs.Exploder.call(ctx, opts)
      end
    end
  end
end
