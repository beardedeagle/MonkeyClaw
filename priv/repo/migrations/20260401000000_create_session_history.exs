defmodule MonkeyClaw.Repo.Migrations.CreateSessionHistory do
  @moduledoc """
  Creates the session history tables for persisting conversation data.

  ## Tables

    * `sessions` — Conversation metadata (one per chat interaction)
    * `session_messages` — Individual messages within a session
    * `session_messages_fts` — FTS5 external content table for full-text search

  All data tables use `STRICT` mode for type enforcement at the storage
  layer. The FTS5 table uses external content mode (`content=`) which
  references the source table via rowid — no data duplication. Database
  triggers keep the FTS index in sync automatically on INSERT and DELETE.

  Messages are immutable so no UPDATE trigger is needed.
  """

  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false, options: "STRICT") do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :status, :string, null: false, default: "active"
      add :model, :string
      add :message_count, :integer, null: false, default: 0
      add :summary, :text

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:workspace_id])
    create index(:sessions, [:status])
    create index(:sessions, [:inserted_at])

    create table(:session_messages, primary_key: false, options: "STRICT") do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false
      add :content, :text
      add :sequence, :integer, null: false
      add :metadata, :text, null: false, default: "{}"

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:session_messages, [:session_id])
    create unique_index(:session_messages, [:session_id, :sequence])

    # FTS5 external content table — references session_messages via rowid.
    # No data duplication; the index stores only the tokenized content.
    # Joins back to source rows via rowid for full metadata access.
    execute(
      """
      CREATE VIRTUAL TABLE session_messages_fts USING fts5(
        content,
        content='session_messages',
        content_rowid='rowid'
      )
      """,
      "DROP TABLE IF EXISTS session_messages_fts"
    )

    # INSERT trigger — index new message content automatically.
    # Only fires for the FTS-indexed column (content).
    execute(
      """
      CREATE TRIGGER session_messages_fts_insert
      AFTER INSERT ON session_messages
      BEGIN
        INSERT INTO session_messages_fts(rowid, content)
        VALUES (new.rowid, new.content);
      END
      """,
      "DROP TRIGGER IF EXISTS session_messages_fts_insert"
    )

    # DELETE trigger — remove from FTS index when source row is deleted.
    # Uses the FTS5 'delete' command to remove the entry by rowid.
    execute(
      """
      CREATE TRIGGER session_messages_fts_delete
      AFTER DELETE ON session_messages
      BEGIN
        INSERT INTO session_messages_fts(session_messages_fts, rowid, content)
        VALUES ('delete', old.rowid, old.content);
      END
      """,
      "DROP TRIGGER IF EXISTS session_messages_fts_delete"
    )
  end
end
