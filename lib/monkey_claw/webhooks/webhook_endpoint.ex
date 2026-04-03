defmodule MonkeyClaw.Webhooks.WebhookEndpoint do
  @moduledoc """
  Ecto schema for webhook endpoint definitions.

  A webhook endpoint is a workspace-scoped receiver that accepts
  incoming HTTP POST requests from external services. Each endpoint
  has a unique signing secret used for HMAC-SHA256 verification.

  ## Security Model

  Every incoming request is verified against the endpoint's signing
  secret using HMAC-SHA256. The secret is encrypted at rest using
  AES-256-GCM (see `MonkeyClaw.Webhooks.EncryptedBinary`).

  ## Status Lifecycle

      :active → :paused → :active   (reversible)
      :active → :revoked            (terminal)
      :paused → :revoked            (terminal)

  Revoked endpoints cannot be reactivated. The signing secret is
  retained for audit trail purposes but the endpoint rejects all
  incoming requests.

  ## Sources

  The `:source` field categorizes the webhook origin:

    * `:generic` — Default; uses MonkeyClaw's standard signature format
    * `:github` — GitHub webhook events
    * `:gitlab` — GitLab webhook events
    * `:slack` — Slack event subscriptions
    * `:discord` — Discord interaction webhooks (Ed25519)
    * `:bitbucket` — Bitbucket Cloud webhook events
    * `:forgejo` — Forgejo, Codeberg, and Gitea webhook events
    * `:stripe` — Stripe webhook events (timestamp-bound HMAC-SHA256)
    * `:twilio` — Twilio webhook events (HMAC-SHA1, URL-based)
    * `:linear` — Linear webhook events (HMAC-SHA256)
    * `:sentry` — Sentry webhook events (HMAC-SHA256, re-serialized)
    * `:pagerduty` — PagerDuty v3 webhook events (HMAC-SHA256)
    * `:vercel` — Vercel webhook events (HMAC-SHA1)
    * `:netlify` — Netlify deploy notifications (JWS/HS256)
    * `:circleci` — CircleCI webhook events (HMAC-SHA256)
    * `:mattermost` — Mattermost outgoing webhooks (token)

  Each source has a dedicated verifier module implementing the
  `MonkeyClaw.Webhooks.Verifier` behaviour. See
  `MonkeyClaw.Webhooks.Security.verifier_for/1` for dispatch.

  ## Event Filtering

  The `:allowed_events` map controls which event types are accepted.
  An empty map (default) accepts all events. A non-empty map accepts
  only events whose type is a key in the map:

      %{}                                  # accept all
      %{"push" => true, "release" => true} # accept only push and release

  ## Design

  This is NOT a process. Webhook endpoints are data entities persisted
  in SQLite3 via Ecto.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Webhooks.EncryptedBinary
  alias MonkeyClaw.Webhooks.WebhookDelivery
  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          source: source() | nil,
          signing_secret: String.t() | nil,
          status: status() | nil,
          allowed_events: map() | nil,
          rate_limit_per_minute: pos_integer() | nil,
          metadata: map() | nil,
          last_received_at: DateTime.t() | nil,
          delivery_count: non_neg_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type source ::
          :generic
          | :github
          | :gitlab
          | :slack
          | :discord
          | :bitbucket
          | :forgejo
          | :stripe
          | :twilio
          | :linear
          | :sentry
          | :pagerduty
          | :vercel
          | :netlify
          | :circleci
          | :mattermost
  @type status :: :active | :paused | :revoked

  @sources [
    :generic,
    :github,
    :gitlab,
    :slack,
    :discord,
    :bitbucket,
    :forgejo,
    :stripe,
    :twilio,
    :linear,
    :sentry,
    :pagerduty,
    :vercel,
    :netlify,
    :circleci,
    :mattermost
  ]
  @statuses [:active, :paused, :revoked]

  @valid_transitions %{
    active: [:paused, :revoked],
    paused: [:active, :revoked]
  }

  @create_fields [
    :name,
    :source,
    :signing_secret,
    :allowed_events,
    :rate_limit_per_minute,
    :metadata
  ]
  @update_fields [:name, :status, :allowed_events, :rate_limit_per_minute, :metadata]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_endpoints" do
    field :name, :string
    field :source, Ecto.Enum, values: @sources, default: :generic
    field :signing_secret, EncryptedBinary
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :allowed_events, :map, default: %{}
    field :rate_limit_per_minute, :integer, default: 60
    field :metadata, :map, default: %{}
    field :last_received_at, :utc_datetime_usec
    field :delivery_count, :integer, default: 0

    belongs_to :workspace, Workspace
    has_many :webhook_deliveries, WebhookDelivery

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new webhook endpoint.

  Required fields: `:name`, `:signing_secret`.
  The `:signing_secret` should be a freshly generated random value —
  see `MonkeyClaw.Webhooks.generate_signing_secret/0`.

  ## Examples

      WebhookEndpoint.create_changeset(
        %WebhookEndpoint{},
        %{name: "CI notifications", signing_secret: secret}
      )
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = endpoint, attrs) when is_map(attrs) do
    endpoint
    |> cast(attrs, @create_fields)
    |> validate_required([:name, :signing_secret])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:rate_limit_per_minute, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_allowed_events()
    |> unique_constraint([:workspace_id, :name])
  end

  @doc """
  Changeset for updating an existing webhook endpoint.

  Does NOT accept `:signing_secret` — use `rotate_secret_changeset/2`
  for secret rotation. Status transitions are validated against the
  lifecycle state machine.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = endpoint, attrs) when is_map(attrs) do
    endpoint
    |> cast(attrs, @update_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:rate_limit_per_minute, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_status_transition(endpoint)
    |> validate_allowed_events()
    |> unique_constraint([:workspace_id, :name])
  end

  @doc """
  Changeset for rotating a webhook endpoint's signing secret.

  ## Examples

      WebhookEndpoint.rotate_secret_changeset(endpoint, %{signing_secret: new_secret})
  """
  @spec rotate_secret_changeset(t(), map()) :: Ecto.Changeset.t()
  def rotate_secret_changeset(%__MODULE__{} = endpoint, attrs) when is_map(attrs) do
    endpoint
    |> cast(attrs, [:signing_secret])
    |> validate_required([:signing_secret])
  end

  @doc """
  Changeset for recording a webhook delivery (counter + timestamp).

  Internal use only — called by the context module after a webhook
  is accepted.
  """
  @spec record_delivery_changeset(t(), map()) :: Ecto.Changeset.t()
  def record_delivery_changeset(%__MODULE__{} = endpoint, attrs) when is_map(attrs) do
    cast(endpoint, attrs, [:last_received_at, :delivery_count])
  end

  @doc """
  Check whether a status transition is valid.

  ## Examples

      iex> WebhookEndpoint.valid_transition?(:active, :paused)
      true

      iex> WebhookEndpoint.valid_transition?(:revoked, :active)
      false
  """
  @spec valid_transition?(status(), status()) :: boolean()
  def valid_transition?(from, to) when is_atom(from) and is_atom(to) do
    to in Map.get(@valid_transitions, from, [])
  end

  # ── Private Validations ─────────────────────────────────────

  # Validate that allowed_events is a map with string keys and boolean values.
  defp validate_allowed_events(changeset) do
    validate_change(changeset, :allowed_events, fn :allowed_events, events ->
      cond do
        not is_map(events) ->
          [allowed_events: "must be a map"]

        map_size(events) > 100 ->
          [allowed_events: "cannot have more than 100 event types"]

        not Enum.all?(events, fn {k, v} -> is_binary(k) and is_boolean(v) end) ->
          [allowed_events: "must have string keys and boolean values"]

        true ->
          []
      end
    end)
  end

  # Validate status transitions against the lifecycle state machine.
  # New endpoints (nil current status) accept any valid status.
  defp validate_status_transition(changeset, endpoint) do
    case fetch_change(changeset, :status) do
      {:ok, new_status} ->
        current = endpoint.status

        if current == nil or valid_transition?(current, new_status) do
          changeset
        else
          add_error(changeset, :status, "cannot transition from #{current} to #{new_status}")
        end

      :error ->
        changeset
    end
  end
end
