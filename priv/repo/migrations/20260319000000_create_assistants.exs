defmodule MonkeyClaw.Repo.Migrations.CreateAssistants do
  use Ecto.Migration

  def change do
    create table(:assistants, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :backend, :string, null: false
      add :model, :string
      add :system_prompt, :text
      add :persona_prompt, :text
      add :context_prompt, :text
      add :cwd, :string
      add :max_thinking_tokens, :integer
      add :permission_mode, :string
      add :is_default, :boolean, default: false, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:assistants, [:name])

    create unique_index(:assistants, [:is_default],
             where: "is_default = 1",
             name: :assistants_single_default_index
           )
  end
end
