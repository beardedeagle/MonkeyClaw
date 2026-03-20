defmodule MonkeyClaw.Repo.Migrations.CreateWorkspacesAndChannels do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :assistant_id, references(:assistants, type: :binary_id, on_delete: :nilify_all)
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspaces, [:name])
    create index(:workspaces, [:assistant_id])
    create index(:workspaces, [:status])

    create table(:channels, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "open"
      add :pinned, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channels, [:workspace_id, :name])
    create index(:channels, [:status])
  end
end
