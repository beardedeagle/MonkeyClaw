defmodule MonkeyClaw.UserModeling.InjectionPlugTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.UserModeling.InjectionPlug

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # init/1
  # ──────────────────────────────────────────────

  describe "init/1" do
    test "returns defaults for empty opts" do
      opts = InjectionPlug.init([])

      assert opts.min_query_length == 10
    end

    test "accepts custom min_query_length" do
      opts = InjectionPlug.init(min_query_length: 20)

      assert opts.min_query_length == 20
    end

    test "normalizes invalid values to defaults" do
      opts = InjectionPlug.init(min_query_length: "ten")

      assert opts.min_query_length == 10

      opts = InjectionPlug.init(min_query_length: -5)

      assert opts.min_query_length == 10
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with query_pre event
  # ──────────────────────────────────────────────

  describe "call/2 with query_pre event" do
    test "injects user context when profile has topics" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        observed_topics: %{"elixir" => 10, "deploy" => 5, "testing" => 3},
        injection_enabled: true
      })

      ctx = build_query_pre_context(workspace.id, "How do I deploy?")
      opts = InjectionPlug.init([])

      result = InjectionPlug.call(ctx, opts)

      effective = result.assigns[:effective_prompt]
      assert is_binary(effective)
      assert String.contains?(effective, "[User context]")
      assert String.contains?(effective, "How do I deploy?")
    end

    test "skips short prompts" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        observed_topics: %{"elixir" => 10},
        injection_enabled: true
      })

      ctx = build_query_pre_context(workspace.id, "short")
      opts = InjectionPlug.init(min_query_length: 10)

      result = InjectionPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "skips when no workspace_id" do
      ctx = build_query_pre_context(nil, "How do I deploy the application?")
      opts = InjectionPlug.init([])

      result = InjectionPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "skips when profile has no useful data" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        observed_topics: %{},
        preferences: %{},
        injection_enabled: true
      })

      ctx = build_query_pre_context(workspace.id, "How do I deploy the application?")
      opts = InjectionPlug.init([])

      result = InjectionPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "skips when injection_enabled is false on profile" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        observed_topics: %{"elixir" => 10, "deploy" => 5},
        injection_enabled: false
      })

      ctx = build_query_pre_context(workspace.id, "How do I deploy the application?")
      opts = InjectionPlug.init([])

      result = InjectionPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "does not halt the context" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        observed_topics: %{"elixir" => 10},
        injection_enabled: true
      })

      ctx = build_query_pre_context(workspace.id, "How do I deploy the application?")
      opts = InjectionPlug.init([])

      result = InjectionPlug.call(ctx, opts)

      assert result.halted == false
    end

    test "composes with existing effective_prompt" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        observed_topics: %{"elixir" => 10, "deploy" => 5},
        injection_enabled: true
      })

      ctx = build_query_pre_context(workspace.id, "How do I deploy the application?")
      ctx = Context.assign(ctx, :effective_prompt, "[Recalled context]\n\n---\n\noriginal prompt")
      opts = InjectionPlug.init([])

      result = InjectionPlug.call(ctx, opts)

      effective = result.assigns[:effective_prompt]
      assert is_binary(effective)

      # User context block must come before the recalled context block
      {user_ctx_pos, _} = :binary.match(effective, "[User context]")
      {recall_pos, _} = :binary.match(effective, "[Recalled context]")
      assert user_ctx_pos < recall_pos

      # Original recalled prompt is preserved
      assert String.contains?(effective, "[Recalled context]")
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with non-query_pre events
  # ──────────────────────────────────────────────

  describe "call/2 with non-query_pre events" do
    test "passes through unchanged" do
      ctx = Context.new!(:session_started, %{session_id: "test"})
      opts = InjectionPlug.init([])

      result = InjectionPlug.call(ctx, opts)

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
        id -> %{session_id: id, prompt: prompt}
      end

    Context.new!(:query_pre, data)
  end
end
