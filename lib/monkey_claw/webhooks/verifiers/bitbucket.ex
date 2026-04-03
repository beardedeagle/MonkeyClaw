defmodule MonkeyClaw.Webhooks.Verifiers.Bitbucket do
  @moduledoc """
  Verifier for Bitbucket Cloud webhook signatures.

  Bitbucket Cloud signs webhook payloads with HMAC-SHA256 using
  the webhook's secret. The signature is sent in the
  `X-Hub-Signature` header with a `sha256=` prefix.

  ## Headers

    * `X-Hub-Signature` — Required. `sha256=<hex_hmac_sha256>`
    * `X-Event-Key` — Event type (e.g., `repo:push`,
      `pullrequest:created`)
    * `X-Request-UUID` — Unique delivery UUID
    * `X-Hook-UUID` — Webhook configuration UUID

  ## Signed Message

  The raw request body is signed directly — no timestamp component.

  Reference: https://support.atlassian.com/bitbucket-cloud/docs/manage-webhooks/
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "x-hub-signature"
  @event_header "x-event-key"
  @delivery_header "x-request-uuid"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
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
  def extract_event_type(conn) do
    case Plug.Conn.get_req_header(conn, @event_header) do
      [event]
      when is_binary(event) and byte_size(event) > 0 and
             byte_size(event) <= @max_header_length ->
        {:ok, event}

      [] ->
        {:ok, "unknown"}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
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
      ["sha256=" <> hex_sig] when byte_size(hex_sig) == 64 ->
        {:ok, hex_sig}

      _ ->
        {:error, :missing_signature}
    end
  end
end
