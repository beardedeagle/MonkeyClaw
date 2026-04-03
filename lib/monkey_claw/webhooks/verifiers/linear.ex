defmodule MonkeyClaw.Webhooks.Verifiers.Linear do
  @moduledoc """
  Verifier for Linear webhook signatures.

  Linear signs webhook payloads with HMAC-SHA256 using the webhook's
  secret. The signature is sent in the `Linear-Signature` header as a
  bare lowercase hex string (no prefix).

  ## Headers

    * `Linear-Signature` — Required. `<hex_hmac_sha256>` (64 hex characters, no prefix)
    * `Linear-Event` — Event type (e.g., `"Issue"`, `"Comment"`)
    * `Linear-Delivery` — Unique delivery UUID

  ## Signed Message

  The raw request body is signed directly — no timestamp component.
  Linear does not include timestamp-based freshness; replay protection
  relies on the unique delivery UUID.

  Reference: https://linear.app/docs/webhooks
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "linear-signature"
  @event_header "linear-event"
  @delivery_header "linear-delivery"

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
    extract_bounded_header(conn, @event_header)
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
      [hex_sig] when byte_size(hex_sig) == 64 ->
        {:ok, hex_sig}

      _ ->
        {:error, :missing_signature}
    end
  end

  defp extract_bounded_header(conn, header_name) do
    case Plug.Conn.get_req_header(conn, header_name) do
      [value]
      when is_binary(value) and byte_size(value) > 0 and
             byte_size(value) <= @max_header_length ->
        {:ok, value}

      [] ->
        {:ok, "unknown"}

      _ ->
        {:error, :invalid_event_type}
    end
  end
end
