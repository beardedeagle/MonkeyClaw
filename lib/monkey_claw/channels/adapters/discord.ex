defmodule MonkeyClaw.Channels.Adapters.Discord do
  @moduledoc """
  Discord channel adapter.

  Implements bi-directional messaging with Discord:

  - **Inbound**: Receives events via Discord Interactions endpoint (HTTP POST)
  - **Outbound**: Sends messages via Discord REST API

  ## Required Config

    * `bot_token` — Discord bot token
    * `application_id` — Discord application ID
    * `public_key` — Discord application public key (hex-encoded Ed25519)
    * `channel_id` — Discord channel ID to send messages to

  ## Security

  Inbound requests are verified using Ed25519 signature verification
  with the application's public key, per Discord's requirements.
  Headers: `X-Signature-Ed25519` and `X-Signature-Timestamp`.

  ## Design

  This is a stateless adapter — uses HTTP-based interactions for inbound
  and REST API for outbound. No WebSocket Gateway connection needed for
  the webhook-based interaction model.
  """

  @behaviour MonkeyClaw.Channels.Adapter

  require Logger

  @discord_api_base "https://discord.com/api/v10"

  @impl true
  def validate_config(config) when is_map(config) do
    required = ~w(bot_token application_id public_key channel_id)

    missing =
      Enum.reject(required, fn key ->
        value = Map.get(config, key) || Map.get(config, String.to_atom(key))
        is_binary(value) and byte_size(value) > 0
      end)

    case missing do
      [] -> validate_public_key_format(config)
      keys -> {:error, "missing required config: #{Enum.join(keys, ", ")}"}
    end
  end

  @impl true
  def send_message(config, message) when is_map(config) and is_map(message) do
    token = config_value(config, :bot_token)
    channel = config_value(config, :channel_id)

    body = Jason.encode!(%{content: message.content})
    url = ~c"#{@discord_api_base}/channels/#{channel}/messages"

    headers = [
      {~c"authorization", ~c"Bot #{token}"},
      {~c"content-type", ~c"application/json"}
    ]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        Logger.warning("Discord send failed (#{status}): #{resp_body}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def parse_inbound(_conn, raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"type" => 1}} ->
        # PING — Discord verification handshake. Must respond with
        # {"type": 1} per Discord Interactions spec.
        {:ok, %{challenge: %{"type" => 1}}}

      {:ok, %{"type" => 2, "data" => %{"options" => options}} = interaction} ->
        # APPLICATION_COMMAND — slash command
        content = extract_command_content(options)

        {:ok,
         %{
           content: content,
           metadata: %{
             interaction_id: Map.get(interaction, "id"),
             interaction_token: Map.get(interaction, "token"),
             user: get_in(interaction, ["member", "user", "username"]),
             guild_id: Map.get(interaction, "guild_id"),
             channel_id: Map.get(interaction, "channel_id")
           },
           external_id: Map.get(interaction, "id")
         }}

      {:ok, %{"type" => 3} = interaction} ->
        # MESSAGE_COMPONENT — button/select interaction
        {:ok,
         %{
           content: get_in(interaction, ["data", "custom_id"]) || "",
           metadata: %{
             interaction_id: Map.get(interaction, "id"),
             interaction_token: Map.get(interaction, "token"),
             component_type: get_in(interaction, ["data", "component_type"])
           },
           external_id: Map.get(interaction, "id")
         }}

      {:ok, _} ->
        {:error, :unsupported_interaction}

      {:error, _} ->
        {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  @impl true
  def verify_request(config, conn, raw_body)
      when is_map(config) and is_binary(raw_body) do
    public_key_hex = config_value(config, :public_key)
    signature_hex = get_header(conn, "x-signature-ed25519")
    timestamp = get_header(conn, "x-signature-timestamp")

    with {:ok, public_key} <- decode_hex(public_key_hex, :public_key),
         {:ok, signature} <- decode_hex(signature_hex, :signature),
         {:ok, _ts} <- require_present(timestamp, :timestamp) do
      message = timestamp <> raw_body

      case :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]) do
        true -> :ok
        false -> {:error, :invalid_signature}
      end
    end
  rescue
    _ -> {:error, :verification_failed}
  end

  @impl true
  def persistent?, do: false

  # ── Private ───────────────────────────────────────────────────

  defp config_value(config, key) do
    Map.get(config, to_string(key)) || Map.get(config, key)
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp validate_public_key_format(config) do
    key_hex = config_value(config, :public_key)

    case Base.decode16(key_hex, case: :mixed) do
      {:ok, key} when byte_size(key) == 32 -> :ok
      {:ok, _} -> {:error, "public_key must be 32 bytes (64 hex chars)"}
      :error -> {:error, "public_key must be valid hex"}
    end
  end

  defp decode_hex(nil, field), do: {:error, :"missing_#{field}"}

  defp decode_hex(hex, field) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :"invalid_#{field}"}
    end
  end

  defp require_present(nil, field), do: {:error, :"missing_#{field}"}
  defp require_present(value, _field) when is_binary(value), do: {:ok, value}

  defp extract_command_content(options) when is_list(options) do
    options
    |> Enum.map(fn
      %{"value" => value} -> to_string(value)
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> "/ask"
      content -> content
    end
  end

  defp extract_command_content(_), do: "/ask"
end
