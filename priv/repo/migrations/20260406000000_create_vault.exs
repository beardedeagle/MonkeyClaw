defmodule MonkeyClaw.Repo.Migrations.CreateVault do
  use Ecto.Migration

  def change do
    # ── Vault Secrets ──────────────────────────────────────────
    create table(:vault_secrets, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :encrypted_value, :binary, null: false
      add :description, :string
      add :provider, :string
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:vault_secrets, [:workspace_id])
    create unique_index(:vault_secrets, [:workspace_id, :name])
    create index(:vault_secrets, [:provider])

    # ── Vault Tokens ───────────────────────────────────────────
    create table(:vault_tokens, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider, :string, null: false
      add :access_token, :binary, null: false
      add :refresh_token, :binary
      add :token_type, :string, null: false, default: "Bearer"
      add :scope, :string
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:vault_tokens, [:workspace_id])
    create unique_index(:vault_tokens, [:workspace_id, :provider])
    create index(:vault_tokens, [:expires_at])

    # ── Cached Models ──────────────────────────────────────────
    create table(:cached_models, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true

      add :provider, :string, null: false
      add :model_id, :string, null: false
      add :display_name, :string, null: false
      add :capabilities, :text, null: false, default: "{}"
      add :refreshed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cached_models, [:provider, :model_id])
    create index(:cached_models, [:provider])
  end
end
