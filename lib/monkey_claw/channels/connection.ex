defmodule MonkeyClaw.Channels.Connection do
  @moduledoc """
  GenServer for persistent channel connections.

  Wraps a persistent adapter (one where `persistent?/0` returns `true`)
  and manages its connection lifecycle. Subscribes to workspace PubSub
  for outbound event delivery.

  ## Process Justification

  GenServer is justified because:

    * Holds connection state (WebSocket handle, auth state, etc.)
    * Lifecycle-bound (connect on init, disconnect on terminate)
    * Needs PubSub subscription for outbound event forwarding
    * Each connection is independently supervised

  ## Design

  Registers in `MonkeyClaw.Channels.ConnectionRegistry` by channel
  config ID for lookup. Subscribes to the workspace's channel PubSub
  topic and forwards relevant events through the adapter.

  Currently no adapters require persistent connections (all use
  webhook-based inbound), so this module is infrastructure for
  future WebSocket-based adapters (e.g., Discord Gateway).
  """

  use GenServer, restart: :transient

  require Logger

  alias MonkeyClaw.Channels
  alias MonkeyClaw.Channels.{Adapter, ChannelConfig, Telemetry}

  defstruct [:config, :adapter_mod, :connection_state]

  @type t :: %__MODULE__{
          config: ChannelConfig.t(),
          adapter_mod: module(),
          connection_state: term()
        }

  # ── Client API ────────────────────────────────────────────────

  @doc "Start a connection process for a channel config."
  @spec start_link(ChannelConfig.t()) :: GenServer.on_start()
  def start_link(%ChannelConfig{} = config) do
    GenServer.start_link(__MODULE__, config, name: via_registry(config.id))
  end

  def child_spec(%ChannelConfig{} = config) do
    %{
      id: {__MODULE__, config.id},
      start: {__MODULE__, :start_link, [config]},
      restart: :transient,
      type: :worker
    }
  end

  # ── Server Callbacks ──────────────────────────────────────────

  @impl true
  def init(%ChannelConfig{} = config) do
    case Adapter.for_type(config.adapter_type) do
      {:ok, adapter_mod} ->
        if adapter_mod.persistent?() do
          init_persistent(config, adapter_mod)
        else
          {:stop, :not_persistent}
        end

      {:error, :unknown_adapter} ->
        {:stop, :unknown_adapter}
    end
  end

  @impl true
  def handle_info({:channel_message, :outbound, _message}, state) do
    # Outbound messages from other sources — already handled by dispatcher
    {:noreply, state}
  end

  def handle_info(msg, %{adapter_mod: adapter_mod, connection_state: conn_state} = state) do
    case adapter_mod.handle_connection_message(msg, conn_state) do
      {:message, message, new_conn_state} ->
        _ = handle_inbound_message(state.config, message)
        {:noreply, %{state | connection_state: new_conn_state}}

      {:noop, new_conn_state} ->
        {:noreply, %{state | connection_state: new_conn_state}}

      {:error, reason, new_conn_state} ->
        Logger.warning(
          "Channel connection error for #{state.config.adapter_type}:#{state.config.name}: #{inspect(reason)}"
        )

        {:noreply, %{state | connection_state: new_conn_state}}
    end
  end

  @impl true
  def terminate(_reason, %{adapter_mod: adapter_mod, connection_state: conn_state} = state) do
    if function_exported?(adapter_mod, :disconnect, 1) do
      adapter_mod.disconnect(conn_state)
    end

    Telemetry.connection_down(%{
      adapter_type: state.config.adapter_type,
      channel_config_id: state.config.id,
      reason: :shutdown
    })

    _ = Channels.update_status(state.config, :disconnected)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private ───────────────────────────────────────────────────

  defp init_persistent(config, adapter_mod) do
    case adapter_mod.connect(config.config) do
      {:ok, conn_state} ->
        _ = Channels.subscribe(config.workspace_id)
        _ = Channels.update_status(config, :connected)

        Telemetry.connection_up(%{
          adapter_type: config.adapter_type,
          channel_config_id: config.id
        })

        state = %__MODULE__{
          config: config,
          adapter_mod: adapter_mod,
          connection_state: conn_state
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "Failed to connect channel #{config.adapter_type}:#{config.name}: #{inspect(reason)}"
        )

        _ = Channels.update_status(config, :error)
        {:stop, reason}
    end
  end

  defp handle_inbound_message(config, message) do
    alias MonkeyClaw.Channels.Dispatcher
    Dispatcher.handle_persistent_message(config, message)
  end

  defp via_registry(channel_config_id) do
    {:via, Registry, {MonkeyClaw.Channels.ConnectionRegistry, channel_config_id}}
  end
end
