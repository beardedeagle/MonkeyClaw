defmodule MonkeyClaw.Webhooks.Verifiers.PagerDuty do
  @moduledoc """
  Verifier for PagerDuty webhook signatures.

  PagerDuty signs webhook payloads with HMAC-SHA256 using the webhook's
  secret. The signature is sent in the `x-pagerduty-signature` header
  with a `v1=` prefix.

  ## Headers

    * `x-pagerduty-signature` — Required. `v1=<hex_hmac_sha256>`
    * `x-webhook-id` — Unique delivery UUID

  ## Event Type

  PagerDuty does not send a dedicated event-type header. The event type
  is extracted from the JSON body at `event.event_type`
  (e.g., `"incident.triggered"`, `"pagey.ping"`). Defaults to
  `"unknown"` when the field is absent or nil.

  ## Signed Message

  The raw request body is signed directly — no timestamp component.
  PagerDuty does not include timestamp-based freshness; replay protection
  relies on the unique delivery UUID.

  Reference: https://developer.pagerduty.com/docs/webhooks/v3-overview/
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "x-pagerduty-signature"
  @delivery_header "x-webhook-id"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  @spec verify(binary(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, provided} <- extract_signature(conn),
         expected = Security.hmac_sha256_hex(secret, raw_body),
         true <- Security.constant_time_compare(expected, provided) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  @spec extract_event_type(Plug.Conn.t()) ::
          {:ok, String.t()} | {:error, :invalid_event_type}
  def extract_event_type(conn) do
    case get_in(conn.body_params, ["event", "event_type"]) do
      value
      when is_binary(value) and byte_size(value) > 0 and
             byte_size(value) <= @max_header_length ->
        {:ok, value}

      nil ->
        {:ok, "unknown"}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  @spec extract_delivery_id(Plug.Conn.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_delivery_id}
  def extract_delivery_id(conn) do
    case Plug.Conn.get_req_header(conn, @delivery_header) do
      [id]
      when is_binary(id) and byte_size(id) > 0 and
             byte_size(id) <= @max_header_length ->
        {:ok, id}

      [] ->
        {:ok, nil}

      _ ->
        {:error, :invalid_delivery_id}
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp extract_signature(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      ["v1=" <> hex_sig] when byte_size(hex_sig) == 64 ->
        {:ok, hex_sig}

      _ ->
        {:error, :missing_signature}
    end
  end
end
