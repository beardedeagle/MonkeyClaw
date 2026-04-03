defmodule MonkeyClaw.Webhooks.Verifiers.Sentry do
  @moduledoc """
  Verifier for Sentry webhook signatures.

  Sentry signs webhook payloads with HMAC-SHA256 using the client
  secret from the integration. The signature is sent in the
  `sentry-hook-signature` header as a lowercase hex string.

  ## Headers

    * `sentry-hook-signature` — Required. Lowercase hex HMAC-SHA256
      (64 hex characters, no prefix)
    * `sentry-hook-resource` — Event type (e.g., `"issue"`,
      `"event_alert"`, `"metric_alert"`)
    * `request-id` — Unique delivery identifier

  ## Signed Message

  **Sentry does NOT sign the raw request body bytes.** Instead, Sentry
  signs the re-serialized JSON of the parsed body — equivalent to
  `JSON.stringify(body)` in JavaScript. This means the signed string
  may differ from the raw bytes received on the wire due to key
  ordering, whitespace normalization, and encoding differences.

  To reproduce Sentry's signature, the body parameters are re-encoded
  via `Jason.encode!/1` before computing the HMAC. The `raw_body`
  parameter passed to `verify/3` is intentionally ignored.

  Reference: https://docs.sentry.io/organization/integrations/integration-platform/webhooks/
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "sentry-hook-signature"
  @event_header "sentry-hook-resource"
  @delivery_header "request-id"

  @max_header_length 255

  # Expected HMAC-SHA256 hex string length (32 bytes × 2 hex chars).
  @signature_hex_length 64

  # ── verify ─────────────────────────────────────────────────

  @doc """
  Verify the Sentry webhook signature.

  Computes HMAC-SHA256 over the re-serialized JSON body
  (`Jason.encode!(conn.body_params)`) and compares it in constant
  time against the `sentry-hook-signature` header value. The
  `raw_body` argument is ignored — Sentry signs re-serialized JSON,
  not the raw bytes on the wire.

  Returns `:ok` on success, `{:error, :unauthorized}` for any
  failure (missing header, wrong length, signature mismatch, encoding
  error).
  """
  @impl true
  @spec verify(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, _raw_body)
      when is_binary(secret) and byte_size(secret) > 0 do
    with {:ok, provided} <- extract_signature(conn),
         {:ok, message} <- encode_body(conn),
         expected = Security.hmac_sha256_hex(secret, message),
         true <- Security.constant_time_compare(expected, provided) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @doc """
  Extract the Sentry event type from the `sentry-hook-resource` header.

  Returns `{:ok, event_type}` when the header is present and valid,
  `{:ok, "unknown"}` when absent, or `{:error, :invalid_event_type}`
  for malformed values.
  """
  @impl true
  @spec extract_event_type(Plug.Conn.t()) ::
          {:ok, String.t()} | {:error, :invalid_event_type}
  def extract_event_type(conn) do
    extract_bounded_header(conn, @event_header, :invalid_event_type)
  end

  # ── extract_delivery_id ────────────────────────────────────

  @doc """
  Extract the delivery ID from the `request-id` header.

  Returns `{:ok, id}` when the header is present and valid, `{:ok,
  nil}` when absent, or `{:error, :invalid_delivery_id}` for
  malformed values.
  """
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
      [hex_sig]
      when is_binary(hex_sig) and byte_size(hex_sig) == @signature_hex_length ->
        {:ok, hex_sig}

      _ ->
        {:error, :missing_signature}
    end
  end

  defp encode_body(conn) do
    {:ok, Jason.encode!(conn.body_params)}
  rescue
    _ -> {:error, :encode_failed}
  end

  defp extract_bounded_header(conn, header_name, error_tag) do
    case Plug.Conn.get_req_header(conn, header_name) do
      [value]
      when is_binary(value) and byte_size(value) > 0 and
             byte_size(value) <= @max_header_length ->
        {:ok, value}

      [] ->
        {:ok, "unknown"}

      _ ->
        {:error, error_tag}
    end
  end
end
