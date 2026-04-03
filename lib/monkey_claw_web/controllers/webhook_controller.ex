defmodule MonkeyClawWeb.WebhookController do
  @moduledoc """
  HTTP controller for receiving webhook deliveries.

  Implements the single `receive/2` action that processes incoming
  webhook POST requests through the full security pipeline:

    1. Endpoint lookup (active only)
    2. Content-Type validation
    3. Source-dispatched signature verification
    4. Replay detection (delivery ID)
    5. Rate limit enforcement
    6. Event type filtering
    7. Delivery recording (audit)
    8. Async dispatch to agent

  Signature verification is delegated to source-specific verifier
  modules via `Security.verifier_for/1`. Each source (GitHub, Slack,
  Discord, etc.) implements the `MonkeyClaw.Webhooks.Verifier`
  behaviour with its own signing scheme.

  ## Error Response Design

  All error responses are deliberately opaque to prevent information
  leakage:

    * **404** — Endpoint not found, inactive, or revoked (identical)
    * **401** — Any authentication failure (HMAC, timestamp, header)
    * **415** — Wrong Content-Type
    * **422** — Invalid event type or payload
    * **429** — Rate limit exceeded (includes Retry-After header)

  An attacker cannot distinguish between "endpoint doesn't exist"
  and "endpoint exists but is paused" from the response alone.

  ## Replay Handling

  If a request carries a delivery ID that was already processed,
  the controller returns `202 Accepted` without reprocessing. This
  provides idempotent behavior — the sender can safely retry without
  causing duplicate processing.

  ## Design

  This is a standard Phoenix controller. It is NOT a process. Each
  request runs in the Bandit connection process.
  """

  use MonkeyClawWeb, :controller

  require Logger

  alias MonkeyClaw.Webhooks
  alias MonkeyClaw.Webhooks.Dispatcher
  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClawWeb.CacheBodyReader

  @doc """
  Receive and process an incoming webhook delivery.

  Runs the full security pipeline and dispatches valid webhooks
  to the agent workflow asynchronously. Returns `202 Accepted`
  on success.
  """
  @spec receive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive(conn, %{"endpoint_id" => endpoint_id}) do
    with {:ok, endpoint} <- lookup_endpoint(endpoint_id),
         :ok <- verify_content_type(conn),
         raw_body = CacheBodyReader.get_raw_body(conn),
         verifier = Security.verifier_for(endpoint.source),
         :ok <- verifier.verify(endpoint.signing_secret, conn, raw_body),
         {:ok, delivery_id} <- verifier.extract_delivery_id(conn),
         :ok <- check_replay(endpoint, delivery_id),
         :ok <- Webhooks.check_rate_limit(endpoint),
         {:ok, event_type} <- verifier.extract_event_type(conn),
         :ok <- verify_event_allowed(endpoint, event_type) do
      payload_hash = Security.hash_payload(raw_body)
      payload = conn.body_params

      emit_received_telemetry(endpoint, event_type)

      delivery_attrs = %{
        idempotency_key: delivery_id,
        event_type: event_type,
        status: :accepted,
        payload_hash: payload_hash,
        remote_ip: format_remote_ip(conn)
      }

      case Webhooks.record_delivery(endpoint, delivery_attrs) do
        {:ok, delivery} ->
          _task = Dispatcher.dispatch_async(endpoint, event_type, payload, delivery)
          send_accepted(conn, delivery.id)

        {:error, changeset} ->
          Logger.warning("Failed to record webhook delivery: #{inspect(changeset.errors)}")
          send_error(conn, 500)
      end
    else
      {:error, :not_found} -> send_error(conn, 404)
      {:error, :unauthorized} -> send_error(conn, 401)
      {:error, :invalid_delivery_id} -> send_error(conn, 401)
      {:error, :invalid_event_type} -> send_error(conn, 422)
      {:error, :invalid_content_type} -> send_error(conn, 415)
      {:error, :event_not_allowed} -> send_error(conn, 422)
      {:error, :rate_limited} -> send_rate_limited(conn)
      {:error, :replay_detected} -> send_accepted_replay(conn)
    end
  end

  # ── Private — Verification Steps ────────────────────────────

  @spec lookup_endpoint(String.t()) :: {:ok, Webhooks.WebhookEndpoint.t()} | {:error, :not_found}
  defp lookup_endpoint(endpoint_id) do
    # Returns :not_found for missing, paused, AND revoked — no enumeration.
    Webhooks.get_active_endpoint(endpoint_id)
  end

  @spec verify_content_type(Plug.Conn.t()) :: :ok | {:error, :invalid_content_type}
  defp verify_content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [content_type] ->
        if String.starts_with?(content_type, "application/json") do
          :ok
        else
          {:error, :invalid_content_type}
        end

      _ ->
        {:error, :invalid_content_type}
    end
  end

  @spec check_replay(Webhooks.WebhookEndpoint.t(), String.t() | nil) ::
          :ok | {:error, :replay_detected}
  defp check_replay(endpoint, idempotency_key) do
    Webhooks.check_replay(endpoint, idempotency_key)
  end

  @spec verify_event_allowed(Webhooks.WebhookEndpoint.t(), String.t()) ::
          :ok | {:error, :event_not_allowed}
  defp verify_event_allowed(endpoint, event_type) do
    if Webhooks.event_allowed?(endpoint, event_type) do
      :ok
    else
      {:error, :event_not_allowed}
    end
  end

  # ── Private — Response Helpers ──────────────────────────────

  # All response bodies are minimal and opaque. No internal details,
  # no stack traces, no endpoint IDs in error responses.

  @spec send_accepted(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp send_accepted(conn, delivery_id) do
    conn
    |> put_status(202)
    |> json(%{status: "accepted", delivery_id: delivery_id})
  end

  @spec send_accepted_replay(Plug.Conn.t()) :: Plug.Conn.t()
  defp send_accepted_replay(conn) do
    # Idempotent: return success for replays without reprocessing.
    conn
    |> put_status(202)
    |> json(%{status: "accepted", note: "already processed"})
  end

  @spec send_rate_limited(Plug.Conn.t()) :: Plug.Conn.t()
  defp send_rate_limited(conn) do
    emit_rate_limited_telemetry(conn)

    conn
    |> put_resp_header("retry-after", "60")
    |> put_status(429)
    |> json(%{error: "rate limit exceeded"})
  end

  @spec send_error(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  defp send_error(conn, status) do
    message =
      case status do
        401 -> "unauthorized"
        404 -> "not found"
        415 -> "unsupported media type"
        422 -> "unprocessable entity"
        500 -> "internal error"
      end

    emit_rejected_telemetry(conn, status)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  # ── Private — Telemetry ─────────────────────────────────────

  defp emit_received_telemetry(endpoint, event_type) do
    :telemetry.execute(
      [:monkey_claw, :webhook, :received],
      %{count: 1},
      %{
        endpoint_id: endpoint.id,
        source: endpoint.source,
        event_type: event_type
      }
    )
  end

  defp emit_rejected_telemetry(conn, status) do
    :telemetry.execute(
      [:monkey_claw, :webhook, :rejected],
      %{count: 1},
      %{
        status: status,
        remote_ip: format_remote_ip(conn)
      }
    )
  end

  defp emit_rate_limited_telemetry(conn) do
    :telemetry.execute(
      [:monkey_claw, :webhook, :rate_limited],
      %{count: 1},
      %{remote_ip: format_remote_ip(conn)}
    )
  end

  # Format the remote IP as a string for logging and audit.
  @spec format_remote_ip(Plug.Conn.t()) :: String.t()
  defp format_remote_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> List.to_string()
  end
end
