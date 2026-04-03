defmodule MonkeyClaw.Recall.PlugTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Recall.Plug, as: RecallPlug

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # init/1
  # ──────────────────────────────────────────────

  describe "init/1" do
    test "returns defaults for empty opts" do
      opts = RecallPlug.init([])

      assert opts.max_results == 10
      assert opts.max_chars == 4000
      assert opts.roles == [:user, :assistant]
      assert opts.min_query_length == 10
    end

    test "accepts custom options" do
      opts = RecallPlug.init(max_results: 5, max_chars: 2000, min_query_length: 20)

      assert opts.max_results == 5
      assert opts.max_chars == 2000
      assert opts.min_query_length == 20
    end

    test "accepts custom roles" do
      opts = RecallPlug.init(roles: [:user])

      assert opts.roles == [:user]
    end

    test "normalizes nil max_chars to default" do
      opts = RecallPlug.init(max_chars: nil)

      assert opts.max_chars == 4000
    end

    test "normalizes negative max_results to default" do
      opts = RecallPlug.init(max_results: -1)

      assert opts.max_results == 10
    end

    test "normalizes zero max_chars to default" do
      opts = RecallPlug.init(max_chars: 0)

      assert opts.max_chars == 4000
    end

    test "normalizes non-atom roles to default" do
      opts = RecallPlug.init(roles: ["user", "assistant"])

      assert opts.roles == [:user, :assistant]
    end

    test "normalizes empty roles to default" do
      opts = RecallPlug.init(roles: [])

      assert opts.roles == [:user, :assistant]
    end

    test "normalizes non-integer min_query_length to default" do
      opts = RecallPlug.init(min_query_length: "ten")

      assert opts.min_query_length == 10
    end
  end

  # ──────────────────────────────────────────────
  # call/2
  # ──────────────────────────────────────────────

  describe "call/2 with query_pre event" do
    test "injects recall context when matches found" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "deploy the application to staging"})

      ctx = build_query_pre_context(workspace.id, "How do I deploy the application?")
      opts = RecallPlug.init([])

      result = RecallPlug.call(ctx, opts)

      # Should have set effective_prompt with recall context
      assert result.assigns[:effective_prompt] != nil

      assert String.contains?(
               result.assigns[:effective_prompt],
               "[Recalled from previous sessions]"
             )

      assert String.contains?(
               result.assigns[:effective_prompt],
               "How do I deploy the application?"
             )

      # Should have set recall_result for observability
      assert result.assigns[:recall_result] != nil
      assert result.assigns[:recall_result].match_count > 0
    end

    test "passes through when no matches found" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "hello world"})

      ctx = build_query_pre_context(workspace.id, "completely unrelated xyzzy term here")
      opts = RecallPlug.init([])

      result = RecallPlug.call(ctx, opts)

      # No effective_prompt should be set, but recall_result is
      # always assigned for observability when recall runs.
      assert result.assigns[:effective_prompt] == nil
      assert result.assigns[:recall_result] != nil
      assert result.assigns[:recall_result].match_count == 0
    end

    test "skips short prompts" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "deploy the application"})

      ctx = build_query_pre_context(workspace.id, "hi")
      opts = RecallPlug.init(min_query_length: 10)

      result = RecallPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "skips when no workspace ID available" do
      ctx = build_query_pre_context(nil, "deploy the application to staging")
      opts = RecallPlug.init([])

      result = RecallPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "skips when prompt has no usable keywords" do
      workspace = insert_workspace!()

      ctx = build_query_pre_context(workspace.id, "a b c d e f g")
      opts = RecallPlug.init(min_query_length: 1)

      result = RecallPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "does not halt the context" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "deploy application keyword"})

      ctx = build_query_pre_context(workspace.id, "deploy the application keyword")
      opts = RecallPlug.init([])

      result = RecallPlug.call(ctx, opts)

      assert result.halted == false
    end

    test "respects custom roles filter" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "deploy the feature"})
      insert_message!(session, %{role: :system, content: "deploy system event triggered"})

      ctx = build_query_pre_context(workspace.id, "deploy system feature event")
      opts = RecallPlug.init(roles: [:user])

      result = RecallPlug.call(ctx, opts)

      recall_result = result.assigns[:recall_result]
      assert recall_result != nil
      assert recall_result.match_count > 0
      assert Enum.all?(recall_result.matches, &(&1.role == :user))
    end
  end

  describe "call/2 with non-query_pre events" do
    test "passes through non-query_pre events unchanged" do
      ctx = Context.new!(:session_started, %{session_id: "test"})
      opts = RecallPlug.init([])

      result = RecallPlug.call(ctx, opts)

      assert result == ctx
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp build_query_pre_context(workspace_id, prompt) do
    data =
      case workspace_id do
        nil -> %{prompt: prompt}
        id -> %{workspace_id: id, prompt: prompt}
      end

    Context.new!(:query_pre, data)
  end
end
