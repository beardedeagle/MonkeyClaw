defmodule MonkeyClaw.Repo.Migrations.CreateUserProfiles do
  @moduledoc """
  Creates the user_profiles table for per-workspace user modeling.

  ## Tables

    * `user_profiles` — One profile per workspace storing accumulated
      observations about user behavior, preferences, and privacy
      controls.

  All data tables use `STRICT, WITHOUT ROWID` for type enforcement and
  clustered UUID primary keys.

  ## Privacy Levels

  Controls what observations are recorded. Injection into the assistant
  context is governed separately by the `injection_enabled` column.

    * `"full"` — All observations recorded (topics and behavioral patterns)
    * `"limited"` — Only topic observations recorded; behavioral patterns skipped
    * `"none"` — No passive observations recorded
  """

  use Ecto.Migration

  def change do
    create table(:user_profiles, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :display_name, :string
      add :preferences, :text, null: false, default: "{}"
      add :observed_topics, :text, null: false, default: "{}"
      add :observed_patterns, :text, null: false, default: "{}"
      add :privacy_level, :string, null: false, default: "full"
      add :injection_enabled, :integer, null: false, default: 1
      add :last_observed_at, :utc_datetime_usec

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_profiles, [:workspace_id],
             comment: "One profile per workspace (single-user model)"
           )
  end
end
