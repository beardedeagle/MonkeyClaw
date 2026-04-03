defmodule MonkeyClaw.Webhooks.Verifiers.Stripe do
  @moduledoc """
  Verifier for Stripe webhook signatures.

  Implements timestamp-bound HMAC-SHA256 verification using the
  `Stripe-Signature` header. The signed message binds the raw request
  body to a Unix timestamp, preventing replay attacks.

  ## Headers

    * `Stripe-Signature` — Required. `t=<unix_ts>,v1=<hex_hmac>`
      (may contain multiple `v1` values; the first valid one is used)

  ## Signed Message

      "<timestamp>.<raw_body>"

  ## Event Extraction

    * Event type — Read from `conn.body_params["type"]`
      (defaults to `"unknown"` if absent)
    * Delivery ID — Read from `conn.body_params["id"]`
      (returns `{:ok, nil}` if absent)

  ## Security Properties

    * Constant-time comparison prevents timing attacks
    * Timestamp binding prevents replay with fresh timestamps
    * 5-minute freshness window rejects stale signatures
    * All failures return `:unauthorized` (no information leakage)

  ## Reference

  https://docs.stripe.com/webhooks/signatures
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "stripe-signature"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  @doc """
  Verify a Stripe webhook request.

  Parses the `Stripe-Signature` header, validates the timestamp
  freshness, and confirms the HMAC-SHA256 signature matches the
  raw request body.

  Returns `:ok` on success or `{:error, :unauthorized}` for any
  failure (missing header, expired timestamp, wrong secret, etc.).
  """
  @spec verify(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, timestamp, signature} <- parse_signature_header(conn),
         :ok <- Security.verify_timestamp(timestamp),
         expected = Security.hmac_sha256_hex(secret, "#{timestamp}.#{raw_body}"),
         true <- Security.constant_time_compare(expected, signature) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  @doc """
  Extract the Stripe event type from the request body.

  Reads `conn.body_params["type"]` (e.g. `"payment_intent.succeeded"`).
  Returns `{:ok, "unknown"}` when the field is absent.
  Returns `{:error, :invalid_event_type}` for empty or oversized values.
  """
  @spec extract_event_type(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :invalid_event_type}
  def extract_event_type(conn) do
    case conn.body_params["type"] do
      nil ->
        {:ok, "unknown"}

      event_type
      when is_binary(event_type) and byte_size(event_type) > 0 and
             byte_size(event_type) <= @max_header_length ->
        {:ok, event_type}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  @doc """
  Extract the Stripe event ID from the request body.

  Reads `conn.body_params["id"]` (e.g. `"evt_1234..."`).
  Returns `{:ok, nil}` when the field is absent.
  Returns `{:error, :invalid_delivery_id}` for empty or oversized values.
  """
  @spec extract_delivery_id(Plug.Conn.t()) ::
          {:ok, String.t() | nil} | {:error, :invalid_delivery_id}
  def extract_delivery_id(conn) do
    case conn.body_params["id"] do
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
