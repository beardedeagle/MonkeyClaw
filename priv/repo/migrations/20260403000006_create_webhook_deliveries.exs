defmodule MonkeyClaw.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :webhook_endpoint_id,
          references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all),
          null: false

      add :idempotency_key, :string
      add :event_type, :string
      add :status, :string, null: false
      add :rejection_reason, :string
      add :payload_hash, :string, null: false
      add :remote_ip, :string
      add :processed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhook_deliveries, [:webhook_endpoint_id])
    create index(:webhook_deliveries, [:inserted_at])

    # Unique constraint for replay detection: one idempotency key per endpoint.
    # Partial index — only rows with non-null idempotency_key are indexed.
    create unique_index(:webhook_deliveries, [:webhook_endpoint_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL"
           )
  end
end
