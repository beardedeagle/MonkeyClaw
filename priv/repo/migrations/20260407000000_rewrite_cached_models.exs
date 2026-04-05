defmodule MonkeyClaw.Repo.Migrations.RewriteCachedModels do
  @moduledoc """
  Full drop-and-replace cutover of the cached_models table.

  Greenfield project with zero users — no data is preserved. The old
  provider-keyed single-model-per-row shape is dropped and replaced with
  a (backend, provider)-keyed shape storing models as an embedded JSON
  list per row, with a monotonic tiebreaker column for precedence ties.
  """

  use Ecto.Migration

  def up do
    drop_if_exists table(:cached_models)

    create table(:cached_models, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :backend, :string, null: false
      add :provider, :string, null: false
      add :source, :string, null: false
      add :refreshed_at, :utc_datetime_usec, null: false
      add :refreshed_mono, :integer, null: false
      add :models, :text, null: false, default: "[]"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cached_models, [:backend, :provider])
    create index(:cached_models, [:backend])
    create index(:cached_models, [:provider])
  end

  def down do
    drop_if_exists table(:cached_models)

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
