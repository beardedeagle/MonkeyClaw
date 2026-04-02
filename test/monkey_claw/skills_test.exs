defmodule MonkeyClaw.SkillsTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Skills
  alias MonkeyClaw.Skills.Cache
  alias MonkeyClaw.Skills.Skill

  import MonkeyClaw.Factory

  setup do
    Cache.init()
    :ok
  end

  # ──────────────────────────────────────────────
  # create_skill/2
  # ──────────────────────────────────────────────

  describe "create_skill/2" do
    test "creates skill within workspace" do
      workspace = insert_workspace!()

      {:ok, skill} =
        Skills.create_skill(workspace, %{
          title: "Deploy Procedure",
          description: "Steps for deployment",
          procedure: "1. Build\n2. Deploy\n3. Verify"
        })

      assert %Skill{} = skill
      assert skill.workspace_id == workspace.id
      assert skill.title == "Deploy Procedure"
      assert skill.effectiveness_score == 0.5
      assert skill.usage_count == 0
    end

    test "requires title, description, procedure" do
      workspace = insert_workspace!()

      {:error, cs} = Skills.create_skill(workspace, %{})
      assert errors_on(cs)[:title]
      assert errors_on(cs)[:description]
      assert errors_on(cs)[:procedure]
    end

    test "accepts tags" do
      workspace = insert_workspace!()

      {:ok, skill} =
        Skills.create_skill(workspace, %{
          title: "T",
          description: "D",
          procedure: "P",
          tags: ["code", "test"]
        })

      assert skill.tags == ["code", "test"]
    end
  end

  # ──────────────────────────────────────────────
  # get_skill/1 and get_skill!/1
  # ──────────────────────────────────────────────

  describe "get_skill/1 and get_skill!/1" do
    test "returns skill by ID" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      assert {:ok, found} = Skills.get_skill(skill.id)
      assert found.id == skill.id
    end

    test "returns error for missing ID" do
      assert {:error, :not_found} = Skills.get_skill(Ecto.UUID.generate())
    end

    test "get_skill! raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        Skills.get_skill!(Ecto.UUID.generate())
      end
    end
  end

  # ──────────────────────────────────────────────
  # list_skills/1 and list_skills/2
  # ──────────────────────────────────────────────

  describe "list_skills/1 and list_skills/2" do
    test "lists skills for workspace ordered by effectiveness" do
      workspace = insert_workspace!()
      s1 = insert_skill!(workspace, %{title: "Low"})
      s2 = insert_skill!(workspace, %{title: "High"})

      {:ok, _} = Skills.update_skill(s1, %{effectiveness_score: 0.2})
      {:ok, _} = Skills.update_skill(s2, %{effectiveness_score: 0.9})

      skills = Skills.list_skills(workspace)
      assert length(skills) == 2
      assert hd(skills).effectiveness_score >= List.last(skills).effectiveness_score
    end

    test "scopes to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_skill!(w1)
      insert_skill!(w2)

      skills = Skills.list_skills(w1)
      assert length(skills) == 1
    end

    test "respects limit" do
      workspace = insert_workspace!()
      Enum.each(1..5, fn _ -> insert_skill!(workspace) end)

      skills = Skills.list_skills(workspace.id, %{limit: 2})
      assert length(skills) == 2
    end
  end

  # ──────────────────────────────────────────────
  # update_skill/2
  # ──────────────────────────────────────────────

  describe "update_skill/2" do
    test "updates skill fields" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      {:ok, updated} = Skills.update_skill(skill, %{title: "Updated Title"})
      assert updated.title == "Updated Title"
    end
  end

  # ──────────────────────────────────────────────
  # delete_skill/1
  # ──────────────────────────────────────────────

  describe "delete_skill/1" do
    test "deletes skill" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      {:ok, _deleted} = Skills.delete_skill(skill)
      assert {:error, :not_found} = Skills.get_skill(skill.id)
    end
  end

  # ──────────────────────────────────────────────
  # search_skills/2
  # ──────────────────────────────────────────────

  describe "search_skills/2" do
    test "finds skills by FTS5 search" do
      workspace = insert_workspace!()

      insert_skill!(workspace, %{
        title: "Parser Optimization",
        description: "Optimize Elixir parsers",
        procedure: "1. Profile with fprof\n2. Identify hot paths"
      })

      results = Skills.search_skills(workspace.id, "parser optimization profile")
      assert results != []
      assert hd(results).title == "Parser Optimization"
    end

    test "scopes search to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_skill!(w1, %{title: "Unique Skillz XYZ", description: "D", procedure: "P"})
      insert_skill!(w2, %{title: "Unique Skillz XYZ", description: "D", procedure: "P"})

      results = Skills.search_skills(w1.id, "unique skillz")
      assert length(results) == 1
    end

    test "returns empty for no matches" do
      workspace = insert_workspace!()
      insert_skill!(workspace, %{title: "Deploy", description: "D", procedure: "P"})

      results = Skills.search_skills(workspace.id, "completely unrelated xyzzy term here")
      assert results == []
    end

    test "returns empty for query with no usable keywords" do
      workspace = insert_workspace!()

      results = Skills.search_skills(workspace.id, "a b c")
      assert results == []
    end
  end

  # ──────────────────────────────────────────────
  # record_usage/2
  # ──────────────────────────────────────────────

  describe "record_usage/2" do
    test "increments usage_count" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      {:ok, updated} = Skills.record_usage(skill)
      assert updated.usage_count == 1
      assert updated.success_count == 0
      assert updated.effectiveness_score == 0.0
    end

    test "increments success_count when success: true" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      {:ok, updated} = Skills.record_usage(skill, success: true)
      assert updated.usage_count == 1
      assert updated.success_count == 1
      assert updated.effectiveness_score == 1.0
    end

    test "recalculates effectiveness_score" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      {:ok, s1} = Skills.record_usage(skill, success: true)
      {:ok, s2} = Skills.record_usage(s1, success: false)
      {:ok, s3} = Skills.record_usage(s2, success: true)

      assert s3.usage_count == 3
      assert s3.success_count == 2
      assert_in_delta s3.effectiveness_score, 2 / 3, 0.01
    end
  end

  # ──────────────────────────────────────────────
  # top_skills/2
  # ──────────────────────────────────────────────

  describe "top_skills/2" do
    test "returns top N skills by effectiveness" do
      workspace = insert_workspace!()
      s1 = insert_skill!(workspace)
      s2 = insert_skill!(workspace)
      s3 = insert_skill!(workspace)

      {:ok, _} = Skills.update_skill(s1, %{effectiveness_score: 0.3})
      {:ok, _} = Skills.update_skill(s2, %{effectiveness_score: 0.9})
      {:ok, _} = Skills.update_skill(s3, %{effectiveness_score: 0.6})

      top = Skills.top_skills(workspace.id, 2)
      assert length(top) == 2
      assert hd(top).effectiveness_score >= List.last(top).effectiveness_score
    end
  end
end
