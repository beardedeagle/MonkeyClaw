defmodule MonkeyClaw.Webhooks.WebhookDelivery do
  @moduledoc """
  Ecto schema for webhook delivery audit records.

  Every webhook request that passes initial endpoint lookup is
  recorded as a delivery, regardless of whether it was accepted,
  rejected, or failed during processing. This provides a complete
  audit trail for security analysis and debugging.

  ## Status Lifecycle

    * `:accepted` — Signature verified, dispatched for processing
    * `:rejected` — Failed verification (HMAC, timestamp, rate limit)
    * `:processed` — Agent successfully processed the webhook
    * `:failed` — Agent processing failed

  ## Security Fields

    * `:payload_hash` — SHA-256 of the raw request body, stored as
      hex. Enables payload correlation without storing sensitive
      webhook content.
    * `:remote_ip` — Client IP address for audit logging. Stored as
      a string to handle both IPv4 and IPv6.
    * `:idempotency_key` — Caller-provided key for replay detection.
      Unique per endpoint to prevent cross-endpoint collision.

  ## Design

  This is NOT a process. Deliveries are data entities persisted
  in SQLite3 via Ecto.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Webhooks.WebhookEndpoint

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          webhook_endpoint_id: Ecto.UUID.t() | nil,
          idempotency_key: String.t() | nil,
          event_type: String.t() | nil,
          status: status() | nil,
          rejection_reason: String.t() | nil,
          payload_hash: String.t() | nil,
          remote_ip: String.t() | nil,
          processed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type status :: :accepted | :rejected | :processed | :failed

  @statuses [:accepted, :rejected, :processed, :failed]

  @create_fields [
    :idempotency_key,
    :event_type,
    :status,
    :rejection_reason,
    :payload_hash,
    :remote_ip
  ]
  @update_fields [:status, :rejection_reason, :processed_at]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_deliveries" do
    field :idempotency_key, :string
    field :event_type, :string
    field :status, Ecto.Enum, values: @statuses
    field :rejection_reason, :string
    field :payload_hash, :string
    field :remote_ip, :string
    field :processed_at, :utc_datetime_usec

    belongs_to :webhook_endpoint, WebhookEndpoint

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new delivery record.

  Required fields: `:status`, `:payload_hash`.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = delivery, attrs) when is_map(attrs) do
    delivery
    |> cast(attrs, @create_fields)
    |> validate_required([:status, :payload_hash])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:event_type, max: 255)
    |> validate_length(:rejection_reason, max: 500)
    |> validate_length(:remote_ip, max: 45)
    |> validate_length(:idempotency_key, max: 255)
    |> unique_constraint([:webhook_endpoint_id, :idempotency_key],
      error_key: :idempotency_key
    )
  end

  @doc """
  Changeset for updating a delivery record (status transition).
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = delivery, attrs) when is_map(attrs) do
    delivery
    |> cast(attrs, @update_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:rejection_reason, max: 500)
  end
end
