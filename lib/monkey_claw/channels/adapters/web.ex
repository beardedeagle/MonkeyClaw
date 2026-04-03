defmodule MonkeyClaw.Channels.Adapters.Web do
  @moduledoc """
  Web UI channel adapter.

  Implements bi-directional messaging through Phoenix PubSub and LiveView.
  This adapter represents the web browser as a channel — messages from
  the chat UI are "inbound" and agent responses are "outbound."

  ## Config

  No external configuration needed. The web adapter uses Phoenix PubSub
  internally and integrates with the existing LiveView infrastructure.

  ## Design

  Unlike external adapters (Slack, Discord, Telegram), the web adapter
  does not use HTTP for communication. Instead:

  - **Inbound**: Messages come directly from LiveView event handlers
  - **Outbound**: Messages are broadcast via PubSub to subscribed LiveViews

  The web adapter is always available and does not require credentials.
  It serves as the default channel for every workspace.
  """

  @behaviour MonkeyClaw.Channels.Adapter

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def send_message(_config, message) when is_map(message) do
    # Web adapter outbound is handled via PubSub broadcast in the context.
    # This callback exists for symmetry but the actual delivery
    # happens through Phoenix.PubSub in the Channels context and
    # the NotificationLive component.
    :ok
  end

  @impl true
  def parse_inbound(_conn, _raw_body) do
    # Web adapter does not receive HTTP webhooks.
    # Inbound messages come directly from LiveView event handlers.
    {:error, :not_applicable}
  end

  @impl true
  def verify_request(_config, _conn, _raw_body) do
    # Web adapter does not receive HTTP webhooks.
    # Authentication is handled by the LiveView session.
    :ok
  end

  @impl true
  def persistent?, do: false
end
