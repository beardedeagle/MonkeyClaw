defmodule MonkeyClaw.Channels.Adapters.WhatsApp do
  @moduledoc """
  WhatsApp channel adapter via Meta's Cloud API.

  Implements bi-directional messaging with WhatsApp:

  - **Inbound**: Receives messages via webhook notifications (HTTP POST)
  - **Outbound**: Sends messages via the WhatsApp Cloud API (`/messages`)

  ## Required Config

    * `access_token` — WhatsApp Business API permanent access token
    * `phone_number_id` — Phone number ID (from Meta Business Suite)
    * `recipient_phone` — Default recipient phone number (E.164 format)
    * `app_secret` — Meta app secret for HMAC-SHA256 signature verification
    * `verify_token` — Token for webhook verification challenge (GET)

  ## Security

  Inbound POST requests are verified using Meta's app secret:
  `sha256=HMAC-SHA256(app_secret, raw_body)` in the `X-Hub-Signature-256`
  header. Webhook verification challenges (GET) compare the `hub.verify_token`
  query parameter against the configured verify token.

  ## Design

  This is a stateless adapter — no persistent connection needed.
  Meta pushes webhook notifications for inbound messages, and the
  Cloud API accepts standard HTTP requests for sending messages.
  """

  @behaviour MonkeyClaw.Channels.Adapter

  require Logger

  @graph_api_version "v21.0"
  @graph_api_base "https://graph.facebook.com/#{@graph_api_version}"

  @impl true
  def validate_config(config) when is_map(config) do
    required = ~w(access_token phone_number_id recipient_phone app_secret verify_token)

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
    token = config_value(config, :access_token)
    phone_number_id = config_value(config, :phone_number_id)
    recipient = config_value(config, :recipient_phone)

    body =
      Jason.encode!(%{
        messaging_product: "whatsapp",
        to: recipient,
        type: "text",
        text: %{body: message.content}
      })

    headers = [
      {~c"authorization", ~c"Bearer #{token}"},
      {~c"content-type", ~c"application/json"}
    ]

    url = ~c"#{@graph_api_base}/#{phone_number_id}/messages"

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"messages" => [_ | _]}} -> :ok
          {:ok, %{"error" => %{"message" => msg}}} -> {:error, {:whatsapp_error, msg}}
          {:ok, _} -> :ok
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
      {:ok, %{"object" => "whatsapp_business_account", "entry" => entries}} ->
        parse_entries(entries)

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
    app_secret = config_value(config, :app_secret)
    signature_header = get_header(conn, "x-hub-signature-256")

    verify_signature(app_secret, raw_body, signature_header)
  end

  @doc """
  Verify a webhook subscription challenge (GET request).

  Meta sends a GET request with `hub.mode`, `hub.verify_token`, and
  `hub.challenge` query parameters. Returns `{:ok, challenge}` if the
  verify token matches, allowing the controller to echo the challenge
  back to Meta.
  """
  @impl true
  @spec verify_webhook(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def verify_webhook(config, params) when is_map(config) and is_map(params) do
    verify_token = config_value(config, :verify_token)

    case params do
      %{"hub.mode" => "subscribe", "hub.verify_token" => token, "hub.challenge" => challenge}
      when is_binary(token) and is_binary(challenge) ->
        if Plug.Crypto.secure_compare(token, verify_token) do
          {:ok, challenge}
        else
          {:error, :invalid_verify_token}
        end

      _ ->
        {:error, :invalid_params}
    end
  end

  @impl true
  def persistent?, do: false

  # ── Private ───────────────────────────────────────────────────

  defp parse_entries([%{"changes" => changes} | _]) do
    parse_changes(changes)
  end

  defp parse_entries(_), do: {:error, :no_entries}

  defp parse_changes([%{"value" => value, "field" => "messages"} | _]) do
    parse_messages_value(value)
  end

  defp parse_changes([_ | rest]), do: parse_changes(rest)
  defp parse_changes([]), do: {:error, :no_message_changes}

  defp parse_messages_value(%{"messages" => [message | _]} = value) do
    metadata = Map.get(value, "metadata", %{})
    parse_message(message, metadata)
  end

  defp parse_messages_value(%{"statuses" => _}) do
    # Delivery/read status updates — not actionable messages
    {:ok, :ignore}
  end

  defp parse_messages_value(_), do: {:error, :unsupported_value}

  defp parse_message(%{"type" => "text", "text" => %{"body" => text}} = msg, metadata) do
    {:ok,
     %{
       content: text,
       metadata: %{
         from: Map.get(msg, "from"),
         phone_number_id: Map.get(metadata, "phone_number_id"),
         display_phone_number: Map.get(metadata, "display_phone_number"),
         timestamp: Map.get(msg, "timestamp")
       },
       external_id: Map.get(msg, "id")
     }}
  end

  defp parse_message(%{"type" => _other}, _metadata) do
    {:error, :unsupported_message_type}
  end

  defp parse_message(_, _), do: {:error, :malformed_message}

  defp config_value(config, key) do
    Map.get(config, to_string(key)) || Map.get(config, key)
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp verify_signature(secret, body, expected) when is_binary(expected) do
    computed =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    expected_hex = String.replace_prefix(expected, "sha256=", "")

    if Plug.Crypto.secure_compare(computed, expected_hex) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_signature(_, _, _), do: {:error, :missing_signature}
end
