defmodule MonkeyClaw.Webhooks do
  @moduledoc """
  Context module for webhook endpoint management and delivery tracking.

  Provides CRUD operations for webhook endpoints, delivery audit
  logging, rate limit checking, replay detection, and secret
  management for workspace-scoped webhook receivers.

  ## Security Model

  Every webhook endpoint has a unique signing secret encrypted at
  rest with AES-256-GCM. Incoming requests are verified using
  HMAC-SHA256 signatures (see `MonkeyClaw.Webhooks.Security`),
  rate-limited per endpoint, and checked for replay attacks via
  idempotency keys.

  ## Related Modules

    * `MonkeyClaw.Webhooks.WebhookEndpoint` — Endpoint Ecto schema
    * `MonkeyClaw.Webhooks.WebhookDelivery` — Delivery audit schema
    * `MonkeyClaw.Webhooks.Security` — HMAC/timestamp verification
    * `MonkeyClaw.Webhooks.RateLimiter` — ETS sliding window limiter
    * `MonkeyClaw.Webhooks.Dispatcher` — Agent workflow dispatch

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3). All functions are stateless
  and safe for concurrent use.
  """

  require Logger

  import Ecto.Query

  alias MonkeyClaw.Repo
  alias MonkeyClaw.Webhooks.RateLimiter
  alias MonkeyClaw.Webhooks.WebhookDelivery
  alias MonkeyClaw.Webhooks.WebhookEndpoint
  alias MonkeyClaw.Workspaces.Workspace

  # ──────────────────────────────────────────────
  # Secret Generation
  # ──────────────────────────────────────────────

  @doc """
  Generate a cryptographically secure signing secret.

  Returns a URL-safe Base64-encoded string derived from 32 bytes
  of cryptographic randomness (256 bits of entropy).

  The returned secret should be passed to `create_endpoint/2` and
  shown to the user exactly once. It cannot be retrieved after
  creation — only rotated.

  ## Examples

      secret = Webhooks.generate_signing_secret()
      # => "dGhpcyBpcyBhIHRlc3Qgc2VjcmV0IGtleQ..."
  """
  @spec generate_signing_secret() :: String.t()
  def generate_signing_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # ──────────────────────────────────────────────
  # Endpoint CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a new webhook endpoint for a workspace.

  Generates a signing secret automatically if not provided in attrs.
  The plaintext secret is included in the returned endpoint struct
  (decrypted on load). Show it to the user once — it cannot be
  retrieved after this response.

  ## Examples

      {:ok, endpoint} = Webhooks.create_endpoint(workspace, %{
        name: "GitHub CI",
        source: :github
      })
      endpoint.signing_secret  # => "abc123..." (show to user once)
  """
  @spec create_endpoint(Workspace.t(), map()) ::
          {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}
  def create_endpoint(%Workspace{} = workspace, attrs) when is_map(attrs) do
    attrs = Map.put_new_lazy(attrs, :signing_secret, &generate_signing_secret/0)

    workspace
    |> Ecto.build_assoc(:webhook_endpoints)
    |> WebhookEndpoint.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a webhook endpoint by ID.

  Returns `{:ok, endpoint}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_endpoint(Ecto.UUID.t()) :: {:ok, WebhookEndpoint.t()} | {:error, :not_found}
  def get_endpoint(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(WebhookEndpoint, id) do
      nil -> {:error, :not_found}
      endpoint -> {:ok, endpoint}
    end
  end

  @doc """
  Get an active webhook endpoint by ID.

  Returns `{:ok, endpoint}` if found and active.
  Returns `{:error, :not_found}` for missing, paused, or revoked
  endpoints — intentionally identical to prevent enumeration.
  """
  @spec get_active_endpoint(Ecto.UUID.t()) :: {:ok, WebhookEndpoint.t()} | {:error, :not_found}
  def get_active_endpoint(id) when is_binary(id) and byte_size(id) > 0 do
    query = from(e in WebhookEndpoint, where: e.id == ^id and e.status == :active)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      endpoint -> {:ok, endpoint}
    end
  end

  @doc """
  List webhook endpoints for a workspace.

  Returns endpoints ordered by name ascending.
  """
  @spec list_endpoints(Ecto.UUID.t()) :: [WebhookEndpoint.t()]
  def list_endpoints(workspace_id) when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    WebhookEndpoint
    |> where([e], e.workspace_id == ^workspace_id)
    |> order_by([e], asc: e.name)
    |> Repo.all()
  end

  @doc """
  Update an existing webhook endpoint.

  Does not accept signing secret changes — use `rotate_secret/1`.
  """
  @spec update_endpoint(WebhookEndpoint.t(), map()) ::
          {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}
  def update_endpoint(%WebhookEndpoint{} = endpoint, attrs) when is_map(attrs) do
    endpoint
    |> WebhookEndpoint.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a webhook endpoint and all associated deliveries.

  Cascading delete is enforced at the database level.
  """
  @spec delete_endpoint(WebhookEndpoint.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}
  def delete_endpoint(%WebhookEndpoint{} = endpoint) do
    Repo.delete(endpoint)
  end

  # ──────────────────────────────────────────────
  # Status Transitions
  # ──────────────────────────────────────────────

  @doc """
  Pause an active webhook endpoint.

  Paused endpoints reject all incoming requests with the same
  response as non-existent endpoints (no enumeration).
  """
  @spec pause_endpoint(WebhookEndpoint.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}
  def pause_endpoint(%WebhookEndpoint{} = endpoint) do
    update_endpoint(endpoint, %{status: :paused})
  end

  @doc """
  Activate a paused webhook endpoint.
  """
  @spec activate_endpoint(WebhookEndpoint.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}
  def activate_endpoint(%WebhookEndpoint{} = endpoint) do
    update_endpoint(endpoint, %{status: :active})
  end

  @doc """
  Permanently revoke a webhook endpoint.

  Revoked endpoints cannot be reactivated. The signing secret is
  retained for audit purposes.
  """
  @spec revoke_endpoint(WebhookEndpoint.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}
  def revoke_endpoint(%WebhookEndpoint{} = endpoint) do
    update_endpoint(endpoint, %{status: :revoked})
  end

  # ──────────────────────────────────────────────
  # Secret Management
  # ──────────────────────────────────────────────

  @doc """
  Rotate the signing secret for a webhook endpoint.

  Generates a new signing secret and returns the updated endpoint.
  The new plaintext secret is in `endpoint.signing_secret`. Show it
  to the user once — the old secret is permanently replaced.
  """
  @spec rotate_secret(WebhookEndpoint.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, Ecto.Changeset.t()}
  def rotate_secret(%WebhookEndpoint{} = endpoint) do
    new_secret = generate_signing_secret()

    endpoint
    |> WebhookEndpoint.rotate_secret_changeset(%{signing_secret: new_secret})
    |> Repo.update()
  end

  # ──────────────────────────────────────────────
  # Rate Limiting
  # ──────────────────────────────────────────────

  @doc """
  Check whether a webhook endpoint is within its rate limit.

  Delegates to `MonkeyClaw.Webhooks.RateLimiter`.

  Returns `:ok` if allowed, `{:error, :rate_limited}` if exceeded.
  """
  @spec check_rate_limit(WebhookEndpoint.t()) :: :ok | {:error, :rate_limited}
  def check_rate_limit(%WebhookEndpoint{id: id, rate_limit_per_minute: limit}) do
    RateLimiter.check(id, limit)
  end

  # ──────────────────────────────────────────────
  # Event Filtering
  # ──────────────────────────────────────────────

  @doc """
  Check whether an event type is allowed by an endpoint's filter.

  An empty `allowed_events` map accepts all events. A non-empty map
  accepts only events whose type is a key in the map.

  ## Examples

      Webhooks.event_allowed?(%WebhookEndpoint{allowed_events: %{}}, "push")
      #=> true

      Webhooks.event_allowed?(%WebhookEndpoint{allowed_events: %{"push" => true}}, "release")
      #=> false
  """
  @spec event_allowed?(WebhookEndpoint.t(), String.t()) :: boolean()
  def event_allowed?(%WebhookEndpoint{allowed_events: allowed}, event_type)
      when is_binary(event_type) do
    map_size(allowed) == 0 or Map.get(allowed, event_type) == true
  end

  # ──────────────────────────────────────────────
  # Delivery Tracking
  # ──────────────────────────────────────────────

  @doc """
  Record a webhook delivery for audit logging.

  Every incoming request that passes endpoint lookup is recorded,
  regardless of verification outcome. This provides a complete
  audit trail.
  """
  @spec record_delivery(WebhookEndpoint.t(), map()) ::
          {:ok, WebhookDelivery.t()} | {:error, Ecto.Changeset.t()}
  def record_delivery(%WebhookEndpoint{} = endpoint, attrs) when is_map(attrs) do
    result =
      endpoint
      |> Ecto.build_assoc(:webhook_deliveries)
      |> WebhookDelivery.create_changeset(attrs)
      |> Repo.insert()

    # Increment the endpoint's delivery counter.
    case result do
      {:ok, delivery} ->
        increment_delivery_count(endpoint)
        {:ok, delivery}

      error ->
        error
    end
  end

  @doc """
  Update a delivery record (typically status transition after processing).
  """
  @spec update_delivery(WebhookDelivery.t(), map()) ::
          {:ok, WebhookDelivery.t()} | {:error, Ecto.Changeset.t()}
  def update_delivery(%WebhookDelivery{} = delivery, attrs) when is_map(attrs) do
    delivery
    |> WebhookDelivery.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  List recent deliveries for an endpoint, newest first.

  ## Options

    * `:limit` — Maximum number of deliveries (default: 50, max: 200)
  """
  @spec list_deliveries(Ecto.UUID.t(), keyword()) :: [WebhookDelivery.t()]
  def list_deliveries(endpoint_id, opts \\ [])
      when is_binary(endpoint_id) and byte_size(endpoint_id) > 0 do
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)

    WebhookDelivery
    |> where([d], d.webhook_endpoint_id == ^endpoint_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # ──────────────────────────────────────────────
  # Replay Detection
  # ──────────────────────────────────────────────

  @doc """
  Check for replay attacks using idempotency keys.

  Returns `:ok` if the key is new (not a replay), or
  `{:error, :replay_detected}` if this key was already used
  for this endpoint.

  A `nil` idempotency key always returns `:ok` (no replay check).
  """
  @spec check_replay(WebhookEndpoint.t(), String.t() | nil) ::
          :ok | {:error, :replay_detected}
  def check_replay(_endpoint, nil), do: :ok

  def check_replay(%WebhookEndpoint{id: endpoint_id}, idempotency_key)
      when is_binary(idempotency_key) and byte_size(idempotency_key) > 0 do
    query =
      from(d in WebhookDelivery,
        where:
          d.webhook_endpoint_id == ^endpoint_id and
            d.idempotency_key == ^idempotency_key,
        select: d.id,
        limit: 1
      )

    case Repo.one(query) do
      nil -> :ok
      _id -> {:error, :replay_detected}
    end
  end

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  @spec increment_delivery_count(WebhookEndpoint.t()) :: :ok
  defp increment_delivery_count(%WebhookEndpoint{id: id}) do
    now = DateTime.utc_now()

    from(e in WebhookEndpoint, where: e.id == ^id)
    |> Repo.update_all(inc: [delivery_count: 1], set: [last_received_at: now])

    :ok
  end
end
