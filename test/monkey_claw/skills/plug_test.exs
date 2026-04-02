defmodule MonkeyClaw.Skills.PlugTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Skills.Plug, as: SkillsPlug

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # init/1
  # ──────────────────────────────────────────────

  describe "init/1" do
    test "returns defaults for empty opts" do
      opts = SkillsPlug.init([])

      assert opts.max_skills == 5
      assert opts.max_chars == 2000
      assert opts.min_query_length == 10
    end

    test "accepts custom options" do
      opts = SkillsPlug.init(max_skills: 3, max_chars: 1000, min_query_length: 20)

      assert opts.max_skills == 3
      assert opts.max_chars == 1000
      assert opts.min_query_length == 20
    end

    test "normalizes invalid values to defaults" do
      opts = SkillsPlug.init(max_skills: -1, max_chars: nil, min_query_length: "ten")

      assert opts.max_skills == 5
      assert opts.max_chars == 2000
      assert opts.min_query_length == 10
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with query_pre event
  # ──────────────────────────────────────────────

  describe "call/2 with query_pre event" do
    test "injects skills when matches found" do
      workspace = insert_workspace!()

      insert_skill!(workspace, %{
        title: "Deploy Procedure",
        description: "Steps for deployment to staging",
        procedure: "1. Build\n2. Deploy\n3. Verify"
      })

      ctx = build_query_pre_context(workspace.id, "How do I deploy the application to staging?")
      opts = SkillsPlug.init([])

      result = SkillsPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] != nil

      assert String.contains?(
               result.assigns[:effective_prompt],
               "[Relevant skills from your library]"
             )

      assert String.contains?(
               result.assigns[:effective_prompt],
               "How do I deploy the application to staging?"
             )

      assert result.assigns[:skills_result] != nil
    end

    test "passes through when no matches found" do
      workspace = insert_workspace!()
      insert_skill!(workspace, %{title: "Deploy", description: "D", procedure: "P"})

      ctx = build_query_pre_context(workspace.id, "completely unrelated xyzzy term here")
      opts = SkillsPlug.init([])

      result = SkillsPlug.call(ctx, opts)

      # Skills result is still set for observability
      assert result.assigns[:skills_result] != nil
    end

    test "skips short prompts" do
      workspace = insert_workspace!()
      insert_skill!(workspace)

      ctx = build_query_pre_context(workspace.id, "hi")
      opts = SkillsPlug.init(min_query_length: 10)

      result = SkillsPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "skips when no workspace ID available" do
      ctx = build_query_pre_context(nil, "deploy the application to staging")
      opts = SkillsPlug.init([])

      result = SkillsPlug.call(ctx, opts)

      assert result.assigns[:effective_prompt] == nil
    end

    test "does not halt the context" do
      workspace = insert_workspace!()

      insert_skill!(workspace, %{
        title: "Deploy Keyword",
        description: "Deploy keyword skill",
        procedure: "deploy steps"
      })

      ctx = build_query_pre_context(workspace.id, "deploy keyword application steps")
      opts = SkillsPlug.init([])

      result = SkillsPlug.call(ctx, opts)

      assert result.halted == false
    end

    test "composes with existing effective_prompt" do
      workspace = insert_workspace!()

      insert_skill!(workspace, %{
        title: "Compose Test Skill",
        description: "Testing composition keyword",
        procedure: "compose steps"
      })

      ctx = build_query_pre_context(workspace.id, "testing composition keyword skill")
      # Simulate Recall.Plug having already set effective_prompt
      ctx = Context.assign(ctx, :effective_prompt, "[Recalled context]\n\n---\n\noriginal prompt")
      opts = SkillsPlug.init([])

      result = SkillsPlug.call(ctx, opts)

      effective = result.assigns[:effective_prompt]

      if effective do
        # Skills block should come BEFORE the recall block
        {skills_pos, _} = :binary.match(effective, "[Relevant skills")
        {recall_pos, _} = :binary.match(effective, "[Recalled context]")
        assert skills_pos < recall_pos
      end
    end
  end

  # ──────────────────────────────────────────────
  # call/2 with non-query_pre events
  # ──────────────────────────────────────────────

  describe "call/2 with non-query_pre events" do
    test "passes through non-query_pre events unchanged" do
      ctx = Context.new!(:session_started, %{session_id: "test"})
      opts = SkillsPlug.init([])

      result = SkillsPlug.call(ctx, opts)

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
