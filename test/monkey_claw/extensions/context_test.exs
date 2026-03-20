defmodule MonkeyClaw.Extensions.ContextTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Extensions.Context

  describe "new/2" do
    test "creates context for valid hook" do
      assert {:ok, ctx} = Context.new(:query_pre, %{prompt: "Hello"})
      assert ctx.event == :query_pre
      assert ctx.data == %{prompt: "Hello"}
      assert ctx.assigns == %{}
      assert ctx.halted == false
      assert ctx.private == %{}
      assert %DateTime{} = ctx.timestamp
    end

    test "returns error for invalid hook" do
      assert {:error, {:invalid_hook, :not_a_hook}} = Context.new(:not_a_hook, %{})
    end

    test "defaults data to empty map" do
      assert {:ok, ctx} = Context.new(:query_pre)
      assert ctx.data == %{}
    end

    test "preserves complex data maps" do
      data = %{session_id: "ws-1", config: %{backend: :claude}, tags: [:test]}
      assert {:ok, ctx} = Context.new(:session_starting, data)
      assert ctx.data == data
    end
  end

  describe "new!/2" do
    test "creates context for valid hook" do
      ctx = Context.new!(:query_pre, %{prompt: "Hello"})
      assert ctx.event == :query_pre
      assert ctx.data == %{prompt: "Hello"}
    end

    test "raises for invalid hook" do
      assert_raise ArgumentError, ~r/invalid hook/, fn ->
        Context.new!(:not_a_hook)
      end
    end

    test "defaults data to empty map" do
      ctx = Context.new!(:session_starting)
      assert ctx.data == %{}
    end
  end

  describe "assign/3" do
    test "stores key-value in assigns" do
      ctx = Context.new!(:query_pre)
      ctx = Context.assign(ctx, :user, "alice")
      assert ctx.assigns.user == "alice"
    end

    test "overwrites existing key" do
      ctx =
        Context.new!(:query_pre)
        |> Context.assign(:user, "alice")
        |> Context.assign(:user, "bob")

      assert ctx.assigns.user == "bob"
    end

    test "preserves other assigns" do
      ctx =
        Context.new!(:query_pre)
        |> Context.assign(:first, 1)
        |> Context.assign(:second, 2)

      assert ctx.assigns == %{first: 1, second: 2}
    end
  end

  describe "halt/1" do
    test "sets halted to true" do
      ctx = Context.new!(:query_pre)
      refute ctx.halted
      ctx = Context.halt(ctx)
      assert ctx.halted
    end

    test "preserves all other fields" do
      ctx =
        Context.new!(:query_pre, %{prompt: "Hello"})
        |> Context.assign(:key, "value")

      halted = Context.halt(ctx)
      assert halted.event == :query_pre
      assert halted.data == %{prompt: "Hello"}
      assert halted.assigns == %{key: "value"}
    end
  end

  describe "put_private/3" do
    test "stores key-value in private" do
      ctx = Context.new!(:query_pre)
      ctx = Context.put_private(ctx, :internal, true)
      assert ctx.private.internal == true
    end

    test "does not affect assigns" do
      ctx =
        Context.new!(:query_pre)
        |> Context.put_private(:key, "private")
        |> Context.assign(:key, "public")

      assert ctx.private.key == "private"
      assert ctx.assigns.key == "public"
    end
  end

  describe "merge_assigns/2" do
    test "merges map into assigns" do
      ctx =
        Context.new!(:query_pre)
        |> Context.assign(:existing, "value")
        |> Context.merge_assigns(%{new_key: "new_value"})

      assert ctx.assigns == %{existing: "value", new_key: "new_value"}
    end

    test "overwrites conflicting keys" do
      ctx =
        Context.new!(:query_pre)
        |> Context.assign(:key, "old")
        |> Context.merge_assigns(%{key: "new"})

      assert ctx.assigns.key == "new"
    end

    test "handles empty map" do
      ctx = Context.new!(:query_pre)
      ctx = Context.merge_assigns(ctx, %{})
      assert ctx.assigns == %{}
    end
  end
end
