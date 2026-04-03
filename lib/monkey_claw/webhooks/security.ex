defmodule MonkeyClaw.Webhooks.Security do
  @moduledoc """
  Webhook request verification: HMAC-SHA256 signature, timestamp
  freshness, and replay detection.

  ## Signature Format

  MonkeyClaw uses a Stripe-inspired signature header:

      X-MonkeyClaw-Signature: t=<unix_timestamp>,v1=<hex_hmac_sha256>

  The signed message is `"<timestamp>.<raw_body>"`, binding the
  signature to both the payload content and the time of signing.
  This prevents an attacker from replaying a captured signature
  with a different payload or at a later time.

  ## Verification Steps

  `verify_request/3` performs these checks in order:

    1. **Parse** — Extract timestamp and signature from the header
    2. **Freshness** — Reject if timestamp is outside the tolerance window
    3. **HMAC** — Compute expected signature and compare (constant-time)

  Replay detection via idempotency keys is handled separately by
  the context module (`MonkeyClaw.Webhooks.check_replay/2`), since
  it requires database access.

  ## Security Properties

    * **Constant-time comparison** — Prevents timing side-channel attacks
    * **Timestamp binding** — HMAC covers timestamp, preventing replay
      with a fresh timestamp
    * **Strict parsing** — Rejects malformed or missing headers
    * **No information leakage** — All failures return `:unauthorized`

  ## Design

  This module is NOT a process. All functions are pure (no side effects)
  except for `System.os_time/1` in timestamp validation.
  """

  @signature_header "x-monkeyclaw-signature"
  @idempotency_header "x-monkeyclaw-idempotency-key"
  @event_header "x-monkeyclaw-event"

  # Maximum age of a webhook signature before rejection (5 minutes).
  @timestamp_tolerance_seconds 300

  # Maximum allowed length for idempotency keys.
  @max_idempotency_key_length 255

  # Maximum allowed length for event type strings.
  @max_event_type_length 255

  @doc """
  Verify a webhook request's HMAC-SHA256 signature and timestamp.

  Parses the signature header, validates the timestamp is within
  the tolerance window, and verifies the HMAC using the endpoint's
  signing secret.

  Returns `:ok` on success, `{:error, :unauthorized}` on any failure.
  The error is intentionally opaque — callers should not distinguish
  between "bad signature" and "expired timestamp" to prevent
  information leakage.

  ## Parameters

    * `signing_secret` — The endpoint's decrypted signing secret
    * `conn` — The Plug.Conn with request headers
    * `raw_body` — The raw request body bytes (pre-parsing)

  ## Examples

      :ok = Security.verify_request(secret, conn, raw_body)
      {:error, :unauthorized} = Security.verify_request(wrong_secret, conn, raw_body)
  """
  @spec verify_request(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify_request(signing_secret, conn, raw_body)
      when is_binary(signing_secret) and byte_size(signing_secret) > 0 and
             is_binary(raw_body) do
    with {:ok, timestamp, signature} <- parse_signature_header(conn),
         :ok <- verify_timestamp(timestamp),
         :ok <- verify_hmac(signing_secret, timestamp, raw_body, signature) do
      :ok
    else
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  @doc """
  Extract the idempotency key from request headers.

  Returns `{:ok, key}` if present and valid, `{:ok, nil}` if absent,
  or `{:error, :invalid_idempotency_key}` if malformed.
  """
  @spec extract_idempotency_key(Plug.Conn.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_idempotency_key}
  def extract_idempotency_key(conn) do
    case Plug.Conn.get_req_header(conn, @idempotency_header) do
      [] ->
        {:ok, nil}

      [key]
      when is_binary(key) and byte_size(key) > 0 and
             byte_size(key) <= @max_idempotency_key_length ->
        {:ok, key}

      _ ->
        {:error, :invalid_idempotency_key}
    end
  end

  @doc """
  Extract the event type from request headers.

  Returns `{:ok, event_type}` if present and valid, or
  `{:ok, "unknown"}` if absent.
  """
  @spec extract_event_type(Plug.Conn.t()) ::
          {:ok, String.t()} | {:error, :invalid_event_type}
  def extract_event_type(conn) do
    case Plug.Conn.get_req_header(conn, @event_header) do
      [] ->
        {:ok, "unknown"}

      [event_type]
      when is_binary(event_type) and byte_size(event_type) > 0 and
             byte_size(event_type) <= @max_event_type_length ->
        {:ok, event_type}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  @doc """
  Compute the HMAC-SHA256 signature for a webhook payload.

  This is the sender-side computation. Use this when generating
  webhook requests (e.g., for testing or forwarding).

  ## Examples

      timestamp = System.os_time(:second)
      signature = Security.compute_signature(secret, timestamp, body)
      header = "t=\#{timestamp},v1=\#{signature}"
  """
  @spec compute_signature(String.t(), integer(), binary()) :: String.t()
  def compute_signature(signing_secret, timestamp, raw_body)
      when is_binary(signing_secret) and is_integer(timestamp) and is_binary(raw_body) do
    message = "#{timestamp}.#{raw_body}"

    :crypto.mac(:hmac, :sha256, signing_secret, message)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Build a complete signature header value.

  Convenience function for constructing the full header value
  from a signing secret, timestamp, and body.
  """
  @spec build_signature_header(String.t(), integer(), binary()) :: String.t()
  def build_signature_header(signing_secret, timestamp, raw_body) do
    signature = compute_signature(signing_secret, timestamp, raw_body)
    "t=#{timestamp},v1=#{signature}"
  end

  @doc """
  Compute the SHA-256 hash of a payload for audit logging.

  Returns a lowercase hex-encoded string.
  """
  @spec hash_payload(binary()) :: String.t()
  def hash_payload(raw_body) when is_binary(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end

  # ── Private — Header Parsing ────────────────────────────────

  @spec parse_signature_header(Plug.Conn.t()) ::
          {:ok, integer(), String.t()} | {:error, :missing_signature}
  defp parse_signature_header(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      [header] when is_binary(header) -> parse_signature_value(header)
      _ -> {:error, :missing_signature}
    end
  end

  @spec parse_signature_value(String.t()) ::
          {:ok, integer(), String.t()} | {:error, :malformed_signature}
  defp parse_signature_value(header) do
    parts =
      header
      |> String.split(",")
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {String.trim(key), String.trim(value)}
          _ -> {part, ""}
        end
      end)

    with {:ok, timestamp_str} <- Map.fetch(parts, "t"),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         {:ok, signature} when byte_size(signature) == 64 <- Map.fetch(parts, "v1") do
      {:ok, timestamp, signature}
    else
      _ -> {:error, :malformed_signature}
    end
  end

  # ── Private — Timestamp Validation ──────────────────────────

  @spec verify_timestamp(integer()) :: :ok | {:error, :expired_timestamp}
  defp verify_timestamp(timestamp) when is_integer(timestamp) do
    now = System.os_time(:second)
    age = abs(now - timestamp)

    if age <= @timestamp_tolerance_seconds do
      :ok
    else
      {:error, :expired_timestamp}
    end
  end

  # ── Private — HMAC Verification ─────────────────────────────

  @spec verify_hmac(String.t(), integer(), binary(), String.t()) ::
          :ok | {:error, :invalid_signature}
  defp verify_hmac(signing_secret, timestamp, raw_body, provided_signature) do
    expected = compute_signature(signing_secret, timestamp, raw_body)

    if Plug.Crypto.secure_compare(expected, provided_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
