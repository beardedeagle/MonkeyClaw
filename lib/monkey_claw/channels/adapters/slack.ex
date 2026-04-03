defmodule MonkeyClaw.Channels.Adapters.Slack do
  @moduledoc """
  Slack channel adapter.

  Implements bi-directional messaging with Slack:

  - **Inbound**: Receives events via Slack Events API (HTTP POST webhooks)
  - **Outbound**: Sends messages via Slack Web API (`chat.postMessage`)

  ## Required Config

    * `bot_token` — Slack Bot User OAuth Token (xoxb-...)
    * `signing_secret` — Slack app signing secret for request verification
    * `channel_id` — Slack channel ID to send messages to

  ## Security

  Inbound requests are verified using Slack's signing secret:
  `v0=HMAC-SHA256(signing_secret, "v0:{timestamp}:{body}")`.
  Timestamp tolerance is 5 minutes to prevent replay attacks.

  ## Design

  This is a stateless adapter — no persistent connection needed.
  Slack's Events API pushes events via webhook, and the Web API
  accepts standard HTTP requests for sending messages.
  """

  @behaviour MonkeyClaw.Channels.Adapter

  require Logger

  @slack_api_base "https://slack.com/api"
  @timestamp_tolerance 300

  @impl true
  def validate_config(config) when is_map(config) do
    required = ~w(bot_token signing_secret channel_id)

    missing =
      Enum.reject(required, fn key ->
        value = Map.get(config, key) || Map.get(config, String.to_atom(key))
        is_binary(value) and byte_size(value) > 0
      end)

    case missing do
      [] -> :ok
      keys -> {:error, "missing required config: #{Enum.join(keys, ", ")}"}
    end
  end

  @impl true
  def send_message(config, message) when is_map(config) and is_map(message) do
    token = config_value(config, :bot_token)
    channel = config_value(config, :channel_id)

    body =
      Jason.encode!(%{
        channel: channel,
        text: message.content
      })

    headers = [
      {~c"authorization", ~c"Bearer #{token}"},
      {~c"content-type", ~c"application/json; charset=utf-8"}
    ]

    url = ~c"#{@slack_api_base}/chat.postMessage"

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"ok" => true}} -> :ok
          {:ok, %{"ok" => false, "error" => error}} -> {:error, {:slack_error, error}}
          _ -> {:error, :invalid_response}
        end

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def parse_inbound(_conn, raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}} ->
        # Return the full response body Slack expects — the controller
        # will JSON-encode this map directly.
        {:ok, %{challenge: %{"challenge" => challenge}}}

      {:ok, %{"event" => %{"type" => "message", "text" => text} = event}} ->
        # Ignore bot messages to prevent loops
        if Map.has_key?(event, "bot_id") do
          {:ok, :ignore}
        else
          {:ok,
           %{
             content: text,
             metadata: %{
               user: Map.get(event, "user"),
               channel: Map.get(event, "channel"),
               ts: Map.get(event, "ts"),
               thread_ts: Map.get(event, "thread_ts")
             },
             external_id: Map.get(event, "ts")
           }}
        end

      {:ok, %{"event" => %{"type" => _other}}} ->
        {:ok, :ignore}

      {:ok, _} ->
        {:error, :unrecognized_payload}

      {:error, _} ->
        {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  @impl true
  def verify_request(config, conn, raw_body)
      when is_map(config) and is_binary(raw_body) do
    signing_secret = config_value(config, :signing_secret)
    timestamp = get_header(conn, "x-slack-request-timestamp")
    signature = get_header(conn, "x-slack-signature")

    with {:ok, ts} <- parse_timestamp(timestamp),
         :ok <- check_timestamp_freshness(ts) do
      verify_signature(signing_secret, ts, raw_body, signature)
    end
  end

  @impl true
  def persistent?, do: false

  # ── Private ──────────────────────────────────────────────────

  defp config_value(config, key) do
    Map.get(config, to_string(key)) || Map.get(config, key)
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp parse_timestamp(nil), do: {:error, :missing_timestamp}

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp check_timestamp_freshness(ts) do
    now = System.system_time(:second)

    if abs(now - ts) <= @timestamp_tolerance do
      :ok
    else
      {:error, :expired_timestamp}
    end
  end

  defp verify_signature(secret, timestamp, body, expected) when is_binary(expected) do
    basestring = "v0:#{timestamp}:#{body}"

    computed =
      :crypto.mac(:hmac, :sha256, secret, basestring)
      |> Base.encode16(case: :lower)

    expected_hex = String.replace_prefix(expected, "v0=", "")

    if Plug.Crypto.secure_compare(computed, expected_hex) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_signature(_, _, _, _), do: {:error, :missing_signature}
end
