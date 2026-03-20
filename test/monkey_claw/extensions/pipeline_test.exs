defmodule MonkeyClaw.Extensions.PipelineTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Extensions.{Context, Hook, Pipeline}
  alias MonkeyClaw.TestPlugs

  describe "compile/2" do
    test "compiles empty pipeline" do
      assert {:ok, pipeline} = Pipeline.compile(:query_pre, [])
      assert pipeline.event == :query_pre
      assert Pipeline.empty?(pipeline)
    end

    test "compiles pipeline with plugs" do
      assert {:ok, pipeline} =
               Pipeline.compile(:query_pre, [
                 {TestPlugs.PassThrough, []},
                 {TestPlugs.Assigner, [key: "value"]}
               ])

      assert Pipeline.size(pipeline) == 2
    end

    test "calls init/1 on each plug at compile time" do
      {:ok, pipeline} =
        Pipeline.compile(:query_pre, [
          {TestPlugs.Counter, key: :my_count}
        ])

      # Counter.init/1 extracts the :key value
      [{TestPlugs.Counter, :my_count}] = pipeline.plugs
    end

    test "raises for invalid hook point" do
      assert_raise ArgumentError, ~r/invalid hook/, fn ->
        Pipeline.compile(:not_a_hook, [])
      end
    end

    test "raises for module without init/1" do
      assert_raise ArgumentError, ~r/does not export init\/1/, fn ->
        Pipeline.compile(:query_pre, [{String, []}])
      end
    end

    test "compiles for all valid hook points" do
      for hook <- Hook.all() do
        assert {:ok, _pipeline} = Pipeline.compile(hook, [])
      end
    end
  end

  describe "execute/2" do
    test "threads context through plugs in order" do
      {:ok, pipeline} =
        Pipeline.compile(:query_pre, [
          {TestPlugs.Counter, key: :count},
          {TestPlugs.Counter, key: :count},
          {TestPlugs.Counter, key: :count}
        ])

      ctx = Context.new!(:query_pre)
      {:ok, result} = Pipeline.execute(pipeline, ctx)

      assert result.assigns.count == 3
    end

    test "empty pipeline returns context unchanged" do
      {:ok, pipeline} = Pipeline.compile(:query_pre, [])
      ctx = Context.new!(:query_pre, %{original: true})

      {:ok, result} = Pipeline.execute(pipeline, ctx)
      assert result.data == %{original: true}
      assert result.assigns == %{}
    end

    test "halting stops pipeline execution" do
      {:ok, pipeline} =
        Pipeline.compile(:query_pre, [
          {TestPlugs.Counter, key: :count},
          {TestPlugs.Halter, []},
          {TestPlugs.Counter, key: :count}
        ])

      ctx = Context.new!(:query_pre)
      {:ok, result} = Pipeline.execute(pipeline, ctx)

      assert result.halted
      # Only the first Counter ran, not the one after Halter
      assert result.assigns.count == 1
    end

    test "plugs can set assigns for downstream plugs" do
      {:ok, pipeline} =
        Pipeline.compile(:query_pre, [
          {TestPlugs.Assigner, [source: "plug_1"]},
          {TestPlugs.Assigner, [processed: true]}
        ])

      ctx = Context.new!(:query_pre)
      {:ok, result} = Pipeline.execute(pipeline, ctx)

      assert result.assigns.source == "plug_1"
      assert result.assigns.processed == true
    end

    test "exceptions in plugs propagate to caller" do
      {:ok, pipeline} =
        Pipeline.compile(:query_pre, [
          {TestPlugs.Exploder, []}
        ])

      ctx = Context.new!(:query_pre)

      assert_raise RuntimeError, "boom", fn ->
        Pipeline.execute(pipeline, ctx)
      end
    end

    test "data from context is preserved through pipeline" do
      {:ok, pipeline} =
        Pipeline.compile(:query_pre, [
          {TestPlugs.PassThrough, []}
        ])

      ctx = Context.new!(:query_pre, %{prompt: "Hello", session_id: "ws-1"})
      {:ok, result} = Pipeline.execute(pipeline, ctx)

      assert result.data == %{prompt: "Hello", session_id: "ws-1"}
    end

    test "event is preserved through pipeline" do
      {:ok, pipeline} =
        Pipeline.compile(:session_starting, [
          {TestPlugs.Assigner, [ran: true]}
        ])

      ctx = Context.new!(:session_starting)
      {:ok, result} = Pipeline.execute(pipeline, ctx)

      assert result.event == :session_starting
      assert result.assigns.ran == true
    end
  end

  describe "size/1" do
    test "reports zero for empty pipeline" do
      {:ok, p} = Pipeline.compile(:query_pre, [])
      assert Pipeline.size(p) == 0
    end

    test "reports correct count" do
      {:ok, p} =
        Pipeline.compile(:query_pre, [
          {TestPlugs.PassThrough, []},
          {TestPlugs.Counter, []}
        ])

      assert Pipeline.size(p) == 2
    end
  end

  describe "empty?/1" do
    test "true for no plugs" do
      {:ok, p} = Pipeline.compile(:query_pre, [])
      assert Pipeline.empty?(p)
    end

    test "false when plugs present" do
      {:ok, p} = Pipeline.compile(:query_pre, [{TestPlugs.PassThrough, []}])
      refute Pipeline.empty?(p)
    end
  end
end
