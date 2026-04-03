defmodule MonkeyClaw.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    # ── Channel Configs ─────────────────────────────────────────
    create table(:channel_configs, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :adapter_type, :string, null: false
      add :name, :string, null: false
      add :config, :text, null: false, default: "{}"
      add :enabled, :boolean, null: false, default: true
      add :status, :string, null: false, default: "disconnected"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:channel_configs, [:workspace_id])
    create unique_index(:channel_configs, [:workspace_id, :name])
    create index(:channel_configs, [:adapter_type])
    create index(:channel_configs, [:enabled])

    # ── Channel Messages ────────────────────────────────────────
    create table(:channel_messages, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true

      add :channel_config_id,
          references(:channel_configs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :direction, :string, null: false
      add :content, :text, null: false
      add :metadata, :text, null: false, default: "{}"
      add :external_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:channel_messages, [:channel_config_id])
    create index(:channel_messages, [:workspace_id])
    create index(:channel_messages, [:workspace_id, :inserted_at])
    create index(:channel_messages, [:channel_config_id, :direction])
    create index(:channel_messages, [:external_id])
  end
end
