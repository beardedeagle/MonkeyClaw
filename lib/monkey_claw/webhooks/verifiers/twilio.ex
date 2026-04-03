defmodule MonkeyClaw.Webhooks.Verifiers.Twilio do
  @moduledoc """
  Verifier for Twilio webhook signatures.

  Twilio signs webhook requests with HMAC-SHA1 using the account's
  auth token. The signature is sent in the `X-Twilio-Signature`
  header as a Base64-encoded string.

  ## Headers

    * `X-Twilio-Signature` — Required. Base64-encoded HMAC-SHA1

  ## Signed Message

  For JSON webhooks (`application/json`), the signed message is the
  full webhook URL concatenated with the raw request body:

      signed_message = url <> raw_body

  The URL is reconstructed from the connection fields: scheme, host,
  port, request path, and query string. Standard ports (80 for HTTP,
  443 for HTTPS) are omitted from the URL.

  ## Event and Delivery IDs

  Twilio does not provide a standard event type header — `extract_event_type/1`
  always returns `{:ok, "unknown"}`. Twilio does not provide a delivery
  ID header — `extract_delivery_id/1` always returns `{:ok, nil}`.

  Reference: https://www.twilio.com/docs/usage/webhooks/webhooks-security
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "x-twilio-signature"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  @spec verify(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, provided} <- extract_signature(conn),
         url = reconstruct_url(conn),
         expected = Security.hmac_sha1_base64(secret, url <> raw_body),
         true <- Security.constant_time_compare(expected, provided) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  @spec extract_event_type(Plug.Conn.t()) :: {:ok, String.t()}
  def extract_event_type(_conn) do
    {:ok, "unknown"}
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  @spec extract_delivery_id(Plug.Conn.t()) :: {:ok, nil}
  def extract_delivery_id(_conn) do
    {:ok, nil}
  end

  # ── Private ────────────────────────────────────────────────

  defp extract_signature(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      [sig]
      when is_binary(sig) and byte_size(sig) > 0 and
             byte_size(sig) <= @max_header_length ->
        {:ok, sig}

      _ ->
        {:error, :missing_signature}
    end
  end

  defp reconstruct_url(conn) do
    scheme = to_string(conn.scheme)
    host = conn.host
    port = conn.port
    path = conn.request_path
    query = conn.query_string

    port_suffix =
      case {conn.scheme, port} do
        {:https, 443} -> ""
        {:http, 80} -> ""
        _ -> ":#{port}"
      end

    query_suffix =
      if query == "" do
        ""
      else
        "?#{query}"
      end

    "#{scheme}://#{host}#{port_suffix}#{path}#{query_suffix}"
  end
end
