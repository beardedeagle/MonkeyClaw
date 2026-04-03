defmodule MonkeyClaw.Webhooks.Verifiers.Vercel do
  @moduledoc """
  Verifier for Vercel webhook signatures.

  Vercel signs webhook payloads with HMAC-SHA1 using the webhook's
  secret. The signature is sent in the `x-vercel-signature` header
  as a bare lowercase hex string (40 characters, no prefix).

  ## Headers

    * `x-vercel-signature` — Required. Bare 40-character hex HMAC-SHA1

  ## Body Fields

    * `type` — Event type (e.g., `"deployment.created"`)
    * `id` — Unique delivery ID

  ## Signed Message

  The raw request body is signed directly — no timestamp component.
  Vercel does not include timestamp-based freshness; replay protection
  relies on the unique delivery ID.

  Reference: https://vercel.com/docs/webhooks/securing-webhooks
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "x-vercel-signature"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  @spec verify(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, provided} <- extract_signature(conn),
         expected = Security.hmac_sha1_hex(secret, raw_body),
         true <- Security.constant_time_compare(expected, provided) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  @spec extract_event_type(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :invalid_event_type}
  def extract_event_type(conn) do
    case conn.body_params["type"] do
      nil ->
        {:ok, "unknown"}

      value
      when is_binary(value) and byte_size(value) > 0 and
             byte_size(value) <= @max_header_length ->
        {:ok, value}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  @spec extract_delivery_id(Plug.Conn.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_delivery_id}
  def extract_delivery_id(conn) do
    case conn.body_params["id"] do
      nil ->
        {:ok, nil}

      value
      when is_binary(value) and byte_size(value) > 0 and
             byte_size(value) <= @max_header_length ->
        {:ok, value}

      _ ->
        {:error, :invalid_delivery_id}
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp extract_signature(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      [hex_sig] when byte_size(hex_sig) == 40 ->
        {:ok, hex_sig}

      _ ->
        {:error, :missing_signature}
    end
  end
end
