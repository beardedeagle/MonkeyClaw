defmodule MonkeyClaw.Channels.Adapters.Telegram do
  @moduledoc """
  Telegram channel adapter.

  Implements bi-directional messaging with Telegram:

  - **Inbound**: Receives updates via Telegram webhook (HTTP POST)
  - **Outbound**: Sends messages via Telegram Bot API (`sendMessage`)

  ## Required Config

    * `bot_token` — Telegram Bot API token (from @BotFather)
    * `chat_id` — Target chat ID for outbound messages
    * `secret_token` — Secret token for webhook verification

  ## Security

  Inbound requests are verified using the `X-Telegram-Bot-Api-Secret-Token`
  header, which Telegram includes with every webhook delivery when a secret
  token is configured via `setWebhook`.

  ## Design

  This is a stateless adapter — uses webhook mode for inbound (no long-polling
  process needed) and standard HTTP for outbound via the Bot API.
  """

  @behaviour MonkeyClaw.Channels.Adapter

  require Logger

  @telegram_api_base "https://api.telegram.org"

  @impl true
  def validate_config(config) when is_map(config) do
    required = ~w(bot_token chat_id secret_token)

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
    chat_id = config_value(config, :chat_id)

    body =
      Jason.encode!(%{
        chat_id: chat_id,
        text: message.content,
        parse_mode: "Markdown"
      })

    url = ~c"#{@telegram_api_base}/bot#{token}/sendMessage"

    headers = [
      {~c"content-type", ~c"application/json"}
    ]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"ok" => true}} -> :ok
          {:ok, %{"ok" => false, "description" => desc}} -> {:error, {:telegram_error, desc}}
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
      {:ok, %{"message" => %{"text" => text} = msg}} ->
        {:ok,
         %{
           content: text,
           metadata: %{
             chat_id: get_in(msg, ["chat", "id"]),
             message_id: Map.get(msg, "message_id"),
             from: extract_sender(msg),
             date: Map.get(msg, "date")
           },
           external_id: msg |> Map.get("message_id") |> to_string()
         }}

      {:ok, %{"message" => %{}}} ->
        # Non-text message (photo, sticker, etc.)
        {:ok, :ignore}

      {:ok, %{"edited_message" => _}} ->
        {:ok, :ignore}

      {:ok, _} ->
        {:ok, :ignore}

      {:error, _} ->
        {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  @impl true
  def verify_request(config, conn, _raw_body) when is_map(config) do
    expected_token = config_value(config, :secret_token)
    actual_token = get_header(conn, "x-telegram-bot-api-secret-token")

    cond do
      is_nil(expected_token) or expected_token == "" ->
        {:error, :secret_token_not_configured}

      is_nil(actual_token) ->
        {:error, :missing_secret_token}

      Plug.Crypto.secure_compare(actual_token, expected_token) ->
        :ok

      true ->
        {:error, :invalid_secret_token}
    end
  end

  @impl true
  def persistent?, do: false

  # ── Private ──────────��────────────────────────────────────────

  defp config_value(config, key) do
    Map.get(config, to_string(key)) || Map.get(config, key)
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp extract_sender(%{"from" => from}) when is_map(from) do
    %{
      id: Map.get(from, "id"),
      first_name: Map.get(from, "first_name"),
      username: Map.get(from, "username")
    }
  end

  defp extract_sender(_), do: nil
end
