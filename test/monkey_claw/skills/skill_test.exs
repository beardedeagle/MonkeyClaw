defmodule MonkeyClaw.Skills.SkillTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Skills.Cache
  alias MonkeyClaw.Skills.Skill

  import MonkeyClaw.Factory

  setup do
    Cache.init()
    :ok
  end

  describe "create_changeset/2" do
    test "valid attrs produce valid changeset" do
      workspace = insert_workspace!()
      skill = Ecto.build_assoc(workspace, :skills)
      attrs = %{title: "Test Skill", description: "A test", procedure: "1. Do stuff"}

      cs = Skill.create_changeset(skill, attrs)
      assert cs.valid?
      assert get_change(cs, :fts_rowid) != nil
    end

    test "requires title, description, procedure" do
      workspace = insert_workspace!()
      skill = Ecto.build_assoc(workspace, :skills)

      cs = Skill.create_changeset(skill, %{})
      refute cs.valid?
      assert errors_on(cs)[:title]
      assert errors_on(cs)[:description]
      assert errors_on(cs)[:procedure]
    end

    test "validates title max length 200" do
      workspace = insert_workspace!()
      skill = Ecto.build_assoc(workspace, :skills)
      attrs = %{title: String.duplicate("a", 201), description: "d", procedure: "p"}

      cs = Skill.create_changeset(skill, attrs)
      refute cs.valid?
      assert errors_on(cs)[:title]
    end

    test "validates tags must be list of strings" do
      workspace = insert_workspace!()
      skill = Ecto.build_assoc(workspace, :skills)
      attrs = %{title: "T", description: "D", procedure: "P", tags: [1, 2, 3]}

      cs = Skill.create_changeset(skill, attrs)
      refute cs.valid?
      assert errors_on(cs)[:tags]
    end

    test "accepts valid tags list" do
      workspace = insert_workspace!()
      skill = Ecto.build_assoc(workspace, :skills)
      attrs = %{title: "T", description: "D", procedure: "P", tags: ["code", "test"]}

      cs = Skill.create_changeset(skill, attrs)
      assert cs.valid?
    end

    test "generates unique fts_rowid" do
      workspace = insert_workspace!()
      skill1 = Ecto.build_assoc(workspace, :skills)
      skill2 = Ecto.build_assoc(workspace, :skills)
      attrs = %{title: "T", description: "D", procedure: "P"}

      cs1 = Skill.create_changeset(skill1, attrs)
      cs2 = Skill.create_changeset(skill2, attrs)

      assert get_change(cs1, :fts_rowid) != get_change(cs2, :fts_rowid)
    end

    test "fts_rowid is 63-bit positive integer" do
      workspace = insert_workspace!()
      skill = Ecto.build_assoc(workspace, :skills)
      attrs = %{title: "T", description: "D", procedure: "P"}

      cs = Skill.create_changeset(skill, attrs)
      fts_rowid = get_change(cs, :fts_rowid)

      assert is_integer(fts_rowid)
      assert fts_rowid > 0
      assert fts_rowid <= 0x7FFF_FFFF_FFFF_FFFF
    end
  end

  describe "update_changeset/2" do
    test "allows updating title, description, procedure, tags" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      cs = Skill.update_changeset(skill, %{title: "Updated", tags: ["new"]})
      assert cs.valid?
    end

    test "validates effectiveness_score bounds on update" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      cs = Skill.update_changeset(skill, %{effectiveness_score: -0.1})
      refute cs.valid?
      assert errors_on(cs)[:effectiveness_score]

      cs = Skill.update_changeset(skill, %{effectiveness_score: 1.1})
      refute cs.valid?
      assert errors_on(cs)[:effectiveness_score]
    end

    test "does not change fts_rowid" do
      workspace = insert_workspace!()
      skill = insert_skill!(workspace)

      # fts_rowid is not in @update_fields, so it's ignored
      cs = Skill.update_changeset(skill, %{fts_rowid: 999})
      refute Map.has_key?(cs.changes, :fts_rowid)
    end
  end
end
