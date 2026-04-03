defmodule MonkeyClaw.Webhooks.Verifiers.Discord do
  @moduledoc """
  Verifier for Discord interaction webhook signatures.

  Discord uses Ed25519 public-key signatures rather than HMAC.
  The application's public key verifies the signature over the
  concatenation of the timestamp and request body.

  ## Headers

    * `X-Signature-Ed25519` — Required. Hex-encoded Ed25519 signature
      (128 hex chars = 64 bytes)
    * `X-Signature-Timestamp` — Required. Timestamp string

  ## Signed Message

      <timestamp><raw_body>

  Direct concatenation, no separator character.

  ## Key Storage

  The endpoint's `signing_secret` field stores the application's
  **public key** (hex-encoded, 64 characters = 32 bytes). This is
  NOT a shared secret — it is the public half of Discord's Ed25519
  keypair for signature verification.

  ## Event Type

  Discord sends event types in the JSON body:

    * Gateway events: `t` field (e.g., `"MESSAGE_CREATE"`)
    * Interaction types: `type` field as integer (1 = PING, etc.)

  Reference: https://discord.com/developers/docs/interactions/receiving-and-responding
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  @signature_header "x-signature-ed25519"
  @timestamp_header "x-signature-timestamp"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  def verify(public_key_hex, conn, raw_body)
      when is_binary(public_key_hex) and byte_size(public_key_hex) > 0 and
             is_binary(raw_body) do
    with {:ok, signature} <- extract_signature(conn),
         {:ok, timestamp} <- extract_timestamp(conn),
         {:ok, public_key} <- decode_hex(public_key_hex),
         message = timestamp <> raw_body,
         true <- ed25519_verify(public_key, message, signature) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  def extract_event_type(conn) do
    # Discord gateway events use the "t" field (string name).
    # Interactions use "type" (integer code).
    case conn.body_params do
      %{"t" => event_name}
      when is_binary(event_name) and byte_size(event_name) > 0 and
             byte_size(event_name) <= @max_header_length ->
        {:ok, event_name}

      %{"type" => type} when is_integer(type) ->
        {:ok, Integer.to_string(type)}

      _ ->
        {:ok, "unknown"}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  def extract_delivery_id(conn) do
    # Discord interaction payloads include a top-level "id" field.
    case conn.body_params do
      %{"id" => id}
      when is_binary(id) and byte_size(id) > 0 and
             byte_size(id) <= @max_header_length ->
        {:ok, id}

      _ ->
        {:ok, nil}
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp extract_signature(conn) do
    # Ed25519 signatures are 64 bytes = 128 hex characters
    case Plug.Conn.get_req_header(conn, @signature_header) do
      [hex_sig] when is_binary(hex_sig) and byte_size(hex_sig) == 128 ->
        decode_hex(hex_sig)

      _ ->
        {:error, :missing_signature}
    end
  end

  defp extract_timestamp(conn) do
    case Plug.Conn.get_req_header(conn, @timestamp_header) do
      [ts] when is_binary(ts) and byte_size(ts) > 0 ->
        {:ok, ts}

      _ ->
        {:error, :missing_timestamp}
    end
  end

  defp decode_hex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_hex}
    end
  end

  # Ed25519 verification via OTP :crypto.
  # Rescue at trust boundary: user-supplied hex could decode to
  # structurally invalid key material that :crypto rejects.
  defp ed25519_verify(public_key, message, signature)
       when byte_size(public_key) == 32 and byte_size(signature) == 64 do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  defp ed25519_verify(_public_key, _message, _signature), do: false
end
