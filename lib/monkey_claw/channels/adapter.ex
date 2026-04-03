defmodule MonkeyClaw.Channels.Adapter do
  @moduledoc """
  Behaviour for channel adapters.

  Each adapter implements platform-specific logic for sending and receiving
  messages through an external channel (Slack, Discord, Telegram, Web).

  ## Required Callbacks

  All adapters must implement:

    * `validate_config/1` — Validate adapter-specific config fields
    * `send_message/2` — Send a message to the external platform
    * `parse_inbound/2` — Parse a webhook payload into a normalized message
    * `verify_request/3` — Verify webhook request authenticity
    * `persistent?/0` — Whether this adapter needs a persistent connection

  ## Optional Callbacks (Persistent Adapters)

  Adapters where `persistent?/0` returns `true` must also implement:

    * `connect/1` — Establish persistent connection
    * `handle_connection_message/2` — Handle messages from the connection
    * `disconnect/1` — Tear down the connection

  ## Normalized Message Format

  All adapters produce and consume messages as maps with:

    * `:content` — The message text content
    * `:metadata` — Platform-specific metadata (user info, thread IDs, etc.)
    * `:external_id` — Platform-assigned message identifier (for deduplication)
  """

  @type config :: map()
  @type message :: %{
          content: String.t(),
          metadata: map(),
          external_id: String.t() | nil
        }
  @type connection_state :: term()

  @doc "Validate adapter-specific configuration."
  @callback validate_config(config()) :: :ok | {:error, String.t()}

  @doc "Send a message to the external platform."
  @callback send_message(config(), message()) :: :ok | {:error, term()}

  @doc "Parse an inbound webhook payload into a normalized message."
  @callback parse_inbound(Plug.Conn.t(), binary()) :: {:ok, message()} | {:error, term()}

  @doc "Verify the authenticity of an inbound webhook request."
  @callback verify_request(config(), Plug.Conn.t(), binary()) :: :ok | {:error, term()}

  @doc "Whether this adapter requires a persistent connection (WebSocket, long-poll)."
  @callback persistent?() :: boolean()

  @doc "Establish a persistent connection. Only called if `persistent?/0` returns `true`."
  @callback connect(config()) :: {:ok, connection_state()} | {:error, term()}

  @doc "Handle a message from the persistent connection."
  @callback handle_connection_message(term(), connection_state()) ::
              {:message, message(), connection_state()}
              | {:noop, connection_state()}
              | {:error, term(), connection_state()}

  @doc "Tear down the persistent connection."
  @callback disconnect(connection_state()) :: :ok

  @doc """
  Verify a webhook subscription challenge (GET request).

  Some platforms (e.g., WhatsApp) verify webhook URLs by sending a GET
  request with a challenge token. The adapter must validate the token
  and return the challenge to confirm ownership.
  """
  @callback verify_webhook(config(), map()) :: {:ok, binary()} | {:error, term()}

  @optional_callbacks [verify_webhook: 2, connect: 1, handle_connection_message: 2, disconnect: 1]

  @doc """
  Resolve the adapter module for a given adapter type atom.

  Returns `{:ok, module}` or `{:error, :unknown_adapter}`.
  """
  @spec for_type(atom()) :: {:ok, module()} | {:error, :unknown_adapter}
  def for_type(:slack), do: {:ok, MonkeyClaw.Channels.Adapters.Slack}
  def for_type(:discord), do: {:ok, MonkeyClaw.Channels.Adapters.Discord}
  def for_type(:telegram), do: {:ok, MonkeyClaw.Channels.Adapters.Telegram}
  def for_type(:whatsapp), do: {:ok, MonkeyClaw.Channels.Adapters.WhatsApp}
  def for_type(:web), do: {:ok, MonkeyClaw.Channels.Adapters.Web}
  def for_type(_), do: {:error, :unknown_adapter}
end
