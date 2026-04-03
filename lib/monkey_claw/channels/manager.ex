defmodule MonkeyClaw.Channels.Manager do
  @moduledoc """
  Manages channel adapter lifecycle via DynamicSupervisor.

  Provides start/stop operations for persistent channel connections.
  Non-persistent adapters (Slack, Discord, Telegram in webhook mode)
  do not require managed connections — they handle inbound via the
  webhook controller and outbound via direct HTTP calls.

  Persistent adapters (e.g., a future Discord Gateway WebSocket adapter)
  are supervised here with fault isolation per connection.

  ## Process Justification

  DynamicSupervisor is justified because:

    * Each channel connection has independent lifecycle (connect/disconnect)
    * Connections need fault isolation (one bad adapter must not crash others)
    * Connections may hold state (WebSocket handles, auth tokens)
    * The set of active connections changes at runtime (user adds/removes channels)

  ## Design

  This module is both a DynamicSupervisor and a convenience API.
  It supervises `MonkeyClaw.Channels.Connection` GenServer children.
  """

  use DynamicSupervisor

  alias MonkeyClaw.Channels.{ChannelConfig, Connection}

  @doc "Start the channel manager supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a persistent connection for a channel config.

  Only call this for adapters where `persistent?/0` returns `true`.
  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_connection(ChannelConfig.t()) :: DynamicSupervisor.on_start_child()
  def start_connection(%ChannelConfig{} = config) do
    DynamicSupervisor.start_child(__MODULE__, {Connection, config})
  end

  @doc """
  Stop a persistent connection.

  Gracefully terminates the connection process, which triggers the
  adapter's `disconnect/1` callback.
  """
  @spec stop_connection(pid()) :: :ok | {:error, :not_found}
  def stop_connection(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Look up the connection process for a channel config.

  Returns `{:ok, pid}` if the connection is active, or `{:error, :not_found}`.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(channel_config_id) when is_binary(channel_config_id) do
    case Registry.lookup(MonkeyClaw.Channels.ConnectionRegistry, channel_config_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all active channel connection PIDs."
  @spec list_connections() :: [{String.t(), pid()}]
  def list_connections do
    Registry.select(MonkeyClaw.Channels.ConnectionRegistry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
