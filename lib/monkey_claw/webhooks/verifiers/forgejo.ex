defmodule MonkeyClaw.Webhooks.Verifiers.Forgejo do
  @moduledoc """
  Verifier for Forgejo (and Gitea) webhook signatures.

  Forgejo and Gitea sign webhook payloads with HMAC-SHA256 using
  the webhook's secret. The hex-encoded signature is sent directly
  in the signature header without a prefix.

  Use this source for **Codeberg**, **Forgejo**, and **Gitea**
  instances — they all use the same signing scheme with different
  header names.

  ## Headers (Forgejo / Codeberg)

    * `X-Forgejo-Signature` — Hex-encoded HMAC-SHA256
    * `X-Forgejo-Event` — Event type (e.g., `push`, `pull_request`)
    * `X-Forgejo-Delivery` — Unique delivery UUID

  ## Headers (Gitea fallback)

    * `X-Gitea-Signature` — Hex-encoded HMAC-SHA256
    * `X-Gitea-Event` — Event type
    * `X-Gitea-Delivery` — Unique delivery UUID

  ## Compatibility

  This verifier accepts both `X-Forgejo-*` and `X-Gitea-*` headers,
  preferring the Forgejo variants when both are present. Gitea and
  Forgejo use identical signing schemes with different header names.

  ## Signed Message

  The raw request body is signed directly — no timestamp component.

  Reference: https://forgejo.org/docs/latest/user/webhooks/
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

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
    header_value =
      first_header(conn, "x-forgejo-event") ||
        first_header(conn, "x-gitea-event")

    case header_value do
      nil ->
        {:ok, "unknown"}

      event
      when is_binary(event) and byte_size(event) > 0 and
             byte_size(event) <= @max_header_length ->
        {:ok, event}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  def extract_delivery_id(conn) do
    header_value =
      first_header(conn, "x-forgejo-delivery") ||
        first_header(conn, "x-gitea-delivery")

    case header_value do
      nil ->
        {:ok, nil}

      id
      when is_binary(id) and byte_size(id) > 0 and
             byte_size(id) <= @max_header_length ->
        {:ok, id}

      _ ->
        {:error, :invalid_delivery_id}
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp extract_signature(conn) do
    sig =
      first_header(conn, "x-forgejo-signature") ||
        first_header(conn, "x-gitea-signature")

    case sig do
      hex_sig when is_binary(hex_sig) and byte_size(hex_sig) == 64 ->
        {:ok, hex_sig}

      _ ->
        {:error, :missing_signature}
    end
  end

  defp first_header(conn, header_name) do
    case Plug.Conn.get_req_header(conn, header_name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
