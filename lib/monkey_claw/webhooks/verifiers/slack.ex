defmodule MonkeyClaw.Webhooks.Verifiers.Slack do
  @moduledoc """
  Verifier for Slack webhook signatures.

  Slack uses a versioned HMAC-SHA256 scheme. The signing secret
  computes the HMAC of a version-prefixed message that includes
  a timestamp for freshness validation.

  ## Headers

    * `X-Slack-Signature` — Required. `v0=<hex_hmac_sha256>`
    * `X-Slack-Request-Timestamp` — Required. Unix timestamp

  ## Signed Message

      "v0:<timestamp>:<raw_body>"

  The version prefix prevents cross-version signature confusion.
  The timestamp is validated within a 5-minute freshness window,
  matching Slack's own recommendation.

  ## Event Type

  Slack embeds event types in the JSON body, not in headers:

    * Event callbacks: `event.type` (e.g., `"message"`, `"app_mention"`)
    * Other payloads: top-level `type` (e.g., `"url_verification"`)

  ## Delivery ID

  Slack includes `event_id` in the JSON body for event callbacks.

  Reference: https://api.slack.com/authentication/verifying-requests-from-slack
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "x-slack-signature"
  @timestamp_header "x-slack-request-timestamp"

  @max_value_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, provided_sig} <- extract_signature(conn),
         {:ok, timestamp} <- extract_timestamp(conn),
         :ok <- Security.verify_timestamp(timestamp),
         message = "v0:#{timestamp}:#{raw_body}",
         expected = Security.hmac_sha256_hex(secret, message),
         true <- Security.constant_time_compare(expected, provided_sig) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  def extract_event_type(conn) do
    # Slack sends event types in the JSON body, not headers.
    # Nested event.type takes precedence over top-level type.
    conn.body_params
    |> raw_event_type()
    |> validate_value(:invalid_event_type, "unknown")
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  def extract_delivery_id(conn) do
    # Slack includes event_id in the JSON body for event callbacks.
    conn.body_params
    |> raw_delivery_id()
    |> validate_value(:invalid_delivery_id, nil)
  end

  # ── Private — Value Extraction ──────────────────────────────

  # Extract the raw event type string from Slack's nested body format.
  defp raw_event_type(%{"event" => %{"type" => value}}), do: {:some, value}
  defp raw_event_type(%{"type" => value}), do: {:some, value}
  defp raw_event_type(_body), do: :none

  # Extract the raw delivery ID from Slack's body format.
  defp raw_delivery_id(%{"event_id" => value}), do: {:some, value}
  defp raw_delivery_id(_body), do: :none

  # Validate an extracted value against length bounds.
  # Returns {:ok, value} for valid strings, {:ok, default} when absent,
  # or {:error, error} for empty/oversized values.
  @type validation_error :: :invalid_event_type | :invalid_delivery_id

  @spec validate_value({:some, term()} | :none, validation_error(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, validation_error()}
  defp validate_value({:some, value}, _error, _default)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @max_value_length,
       do: {:ok, value}

  defp validate_value({:some, _}, error, _default), do: {:error, error}
  defp validate_value(:none, _error, default), do: {:ok, default}

  # ── Private — Header Parsing ──────────────────────────────

  defp extract_signature(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      ["v0=" <> hex_sig] when byte_size(hex_sig) == 64 ->
        {:ok, hex_sig}

      _ ->
        {:error, :missing_signature}
    end
  end

  defp extract_timestamp(conn) do
    case Plug.Conn.get_req_header(conn, @timestamp_header) do
      [ts_string] ->
        case Integer.parse(ts_string) do
          {timestamp, ""} -> {:ok, timestamp}
          _ -> {:error, :invalid_timestamp}
        end

      _ ->
        {:error, :missing_timestamp}
    end
  end
end
