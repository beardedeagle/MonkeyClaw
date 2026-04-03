defmodule MonkeyClaw.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    # ── Notifications ────────────────────────────────────────────
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, null: false
      add :body, :text
      add :category, :string, null: false
      add :severity, :string, null: false, default: "info"
      add :status, :string, null: false, default: "unread"
      add :metadata, :map, default: %{}
      add :source_id, :string
      add :source_type, :string
      add :read_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:notifications, [:workspace_id])
    create index(:notifications, [:workspace_id, :status])
    create index(:notifications, [:workspace_id, :category])
    create index(:notifications, [:inserted_at])

    # ── Notification Rules ──────���────────────────────────────────
    create table(:notification_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :event_pattern, :string, null: false
      add :channel, :string, null: false, default: "in_app"
      add :enabled, :boolean, null: false, default: true
      add :min_severity, :string, null: false, default: "info"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:notification_rules, [:workspace_id])
    create unique_index(:notification_rules, [:workspace_id, :event_pattern])
    create index(:notification_rules, [:enabled])
  end
end
