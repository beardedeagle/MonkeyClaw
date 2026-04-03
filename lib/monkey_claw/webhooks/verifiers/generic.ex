defmodule MonkeyClaw.Webhooks.Verifiers.Generic do
  @moduledoc """
  Verifier for MonkeyClaw's native webhook signature format.

  Uses a Stripe-inspired signature header that binds HMAC-SHA256
  to both the payload content and the time of signing.

  ## Headers

    * `X-MonkeyClaw-Signature` — Required. `t=<unix_ts>,v1=<hex_hmac>`
    * `X-MonkeyClaw-Event` — Optional. Event type (defaults to `"unknown"`)
    * `X-MonkeyClaw-Idempotency-Key` — Optional. Replay detection key

  ## Signed Message

      "<timestamp>.<raw_body>"

  ## Security Properties

    * Constant-time comparison prevents timing attacks
    * Timestamp binding prevents replay with fresh timestamps
    * 5-minute freshness window rejects stale signatures
    * All failures return `:unauthorized` (no information leakage)
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "x-monkeyclaw-signature"
  @event_header "x-monkeyclaw-event"
  @delivery_header "x-monkeyclaw-idempotency-key"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, timestamp, signature} <- parse_signature_header(conn),
         :ok <- Security.verify_timestamp(timestamp),
         expected = Security.compute_signature(secret, timestamp, raw_body),
         true <- Security.constant_time_compare(expected, signature) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  def extract_event_type(conn) do
    case Plug.Conn.get_req_header(conn, @event_header) do
      [] ->
        {:ok, "unknown"}

      [event_type]
      when is_binary(event_type) and byte_size(event_type) > 0 and
             byte_size(event_type) <= @max_header_length ->
        {:ok, event_type}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  def extract_delivery_id(conn) do
    case Plug.Conn.get_req_header(conn, @delivery_header) do
      [] ->
        {:ok, nil}

      [key]
      when is_binary(key) and byte_size(key) > 0 and
             byte_size(key) <= @max_header_length ->
        {:ok, key}

      _ ->
        {:error, :invalid_delivery_id}
    end
  end

  # ── Private — Header Parsing ───────────────────────────────

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
end
