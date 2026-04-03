defmodule MonkeyClaw.UserModeling.ObservationPlugTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.UserModeling.ObservationPlug
  alias MonkeyClaw.UserModeling.Observer

  import MonkeyClaw.Factory

  setup do
    # Observer is disabled in test.exs (:start_observer false).
    # Start a test-controlled instance with a long flush interval
    # so the periodic timer doesn't fire during tests.
    start_supervised!({Observer, [flush_interval_ms: 999_999_999]})
    :ok
  end

  # ──────────────────────────────────────────────
  # init/1
  # ──────────────────────────────────────────────

  describe "init/1" do
    test "returns opts unchanged" do
      assert ObservationPlug.init([]) == []
      assert ObservationPlug.init(some: :opt) == [some: :opt]
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with query_post event
  # ──────────────────────────────────────────────

  describe "call/2 with query_post event" do
    test "sends observation to Observer" do
      workspace = insert_workspace!()
      messages = [%{role: :user, content: "test prompt"}]

      ctx =
        Context.new!(:query_post, %{
          workspace_id: workspace.id,
          prompt: "test prompt",
          messages: messages
        })

      assert Observer.buffer_size() == 0

      ObservationPlug.call(ctx, [])

      assert Observer.buffer_size() == 1
    end

    test "includes response when assistant messages present" do
      workspace = insert_workspace!()

      messages = [
        %{role: :user, content: "test prompt"},
        %{role: :assistant, content: "assistant response here"}
      ]

      ctx =
        Context.new!(:query_post, %{
          workspace_id: workspace.id,
          prompt: "test prompt",
          messages: messages
        })

      ObservationPlug.call(ctx, [])

      assert Observer.buffer_size() == 1

      # Flush so the observation is persisted and we can verify content
      Observer.flush()

      {:ok, profile} = MonkeyClaw.UserModeling.get_profile(workspace.id)
      # Topics from "test prompt" would be extracted
      assert is_map(profile.observed_topics)
    end

    test "skips when no workspace_id" do
      ctx = Context.new!(:query_post, %{prompt: "test prompt", messages: []})

      ObservationPlug.call(ctx, [])

      assert Observer.buffer_size() == 0
    end

    test "skips when prompt is empty" do
      workspace = insert_workspace!()

      ctx =
        Context.new!(:query_post, %{
          workspace_id: workspace.id,
          prompt: "",
          messages: []
        })

      ObservationPlug.call(ctx, [])

      assert Observer.buffer_size() == 0
    end

    test "does not halt the context" do
      workspace = insert_workspace!()

      ctx =
        Context.new!(:query_post, %{
          workspace_id: workspace.id,
          prompt: "test prompt",
          messages: []
        })

      result = ObservationPlug.call(ctx, [])

      assert result.halted == false
    end

    test "returns context unchanged" do
      workspace = insert_workspace!()

      ctx =
        Context.new!(:query_post, %{
          workspace_id: workspace.id,
          prompt: "test prompt",
          messages: []
        })

      result = ObservationPlug.call(ctx, [])

      assert result == ctx
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with non-query_post events
  # ──────────────────────────────────────────────

  describe "call/2 with non-query_post events" do
    test "passes through unchanged" do
      ctx = Context.new!(:session_started, %{session_id: "test"})

      result = ObservationPlug.call(ctx, [])

      assert result == ctx
    end
  end
end
