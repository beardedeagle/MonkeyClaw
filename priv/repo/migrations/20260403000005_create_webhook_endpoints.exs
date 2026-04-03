defmodule MonkeyClaw.Repo.Migrations.CreateWebhookEndpoints do
  use Ecto.Migration

  def change do
    create table(:webhook_endpoints, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :source, :string, null: false, default: "generic"
      add :signing_secret, :binary, null: false
      add :status, :string, null: false, default: "active"
      add :allowed_events, :text, null: false, default: "{}"
      add :rate_limit_per_minute, :integer, null: false, default: 60
      add :metadata, :text, null: false, default: "{}"
      add :last_received_at, :utc_datetime_usec
      add :delivery_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhook_endpoints, [:workspace_id])
    create unique_index(:webhook_endpoints, [:workspace_id, :name])
  end
end
