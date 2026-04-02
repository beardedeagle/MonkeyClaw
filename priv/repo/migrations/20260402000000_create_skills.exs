defmodule MonkeyClaw.Repo.Migrations.CreateSkills do
  @moduledoc """
  Creates the skills table for storing reusable procedures extracted from
  successful experiments.

  ## Tables

    * `skills` — Reusable procedures with effectiveness scoring
    * `skills_fts` — FTS5 external content table for full-text search

  All data tables use `STRICT, WITHOUT ROWID` for type enforcement and
  clustered UUID primary keys.

  ## FTS5 Integration

  The FTS5 table uses external content mode (`content=`) which
  references the source table via a dedicated `fts_rowid` integer
  column. Unlike session messages (which are immutable), skills are
  mutable — the UPDATE trigger must DELETE the old FTS entry then
  INSERT the new one via the FTS5 delete command.
  """

  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text, null: false
      add :procedure, :text, null: false
      add :tags, :text, null: false, default: "[]"

      add :source_experiment_id,
          references(:experiments, type: :binary_id, on_delete: :nilify_all)

      add :effectiveness_score, :real, null: false, default: 0.5
      add :usage_count, :integer, null: false, default: 0
      add :success_count, :integer, null: false, default: 0
      add :fts_rowid, :integer, null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skills, [:workspace_id])
    create index(:skills, [:source_experiment_id])
    create index(:skills, [:effectiveness_score], comment: "DESC ordering handled at query level")
    create unique_index(:skills, [:fts_rowid])

    execute(
      """
      CREATE VIRTUAL TABLE skills_fts USING fts5(
        title,
        description,
        procedure,
        content='skills',
        content_rowid='fts_rowid'
      )
      """,
      "DROP TABLE IF EXISTS skills_fts"
    )

    execute(
      """
      CREATE TRIGGER skills_fts_insert
      AFTER INSERT ON skills
      BEGIN
        INSERT INTO skills_fts(rowid, title, description, procedure)
        VALUES (new.fts_rowid, new.title, new.description, new.procedure);
      END
      """,
      "DROP TRIGGER IF EXISTS skills_fts_insert"
    )

    execute(
      """
      CREATE TRIGGER skills_fts_update
      AFTER UPDATE ON skills
      BEGIN
        INSERT INTO skills_fts(skills_fts, rowid, title, description, procedure)
        VALUES ('delete', old.fts_rowid, old.title, old.description, old.procedure);
        INSERT INTO skills_fts(rowid, title, description, procedure)
        VALUES (new.fts_rowid, new.title, new.description, new.procedure);
      END
      """,
      "DROP TRIGGER IF EXISTS skills_fts_update"
    )

    execute(
      """
      CREATE TRIGGER skills_fts_delete
      AFTER DELETE ON skills
      BEGIN
        INSERT INTO skills_fts(skills_fts, rowid, title, description, procedure)
        VALUES ('delete', old.fts_rowid, old.title, old.description, old.procedure);
      END
      """,
      "DROP TRIGGER IF EXISTS skills_fts_delete"
    )
  end
end
