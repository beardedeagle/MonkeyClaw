defmodule MonkeyClaw.Channels.Telemetry do
  @moduledoc """
  Telemetry event definitions and emission helpers for the Channels subsystem.

  All events use the `[:monkey_claw, :channel, ...]` prefix.

  ## Message Events

    * `[:monkey_claw, :channel, :message, :inbound]` — Message received from platform.
      * Measurements: `%{count: 1}`
      * Metadata: `%{adapter_type: atom(), workspace_id: String.t(), channel_config_id: String.t()}`

    * `[:monkey_claw, :channel, :message, :outbound]` — Message sent to platform.
      * Measurements: `%{count: 1}`
      * Metadata: `%{adapter_type: atom(), workspace_id: String.t(), channel_config_id: String.t()}`

  ## Connection Events

    * `[:monkey_claw, :channel, :connection, :up]` — Channel connected.
      * Measurements: `%{count: 1}`
      * Metadata: `%{adapter_type: atom(), channel_config_id: String.t()}`

    * `[:monkey_claw, :channel, :connection, :down]` — Channel disconnected.
      * Measurements: `%{count: 1}`
      * Metadata: `%{adapter_type: atom(), channel_config_id: String.t(), reason: term()}`

  ## Delivery Events

    * `[:monkey_claw, :channel, :delivery, :success]` — Message delivered successfully.
      * Measurements: `%{count: 1}`
      * Metadata: `%{adapter_type: atom(), workspace_id: String.t()}`

    * `[:monkey_claw, :channel, :delivery, :failed]` — Message delivery failed.
      * Measurements: `%{count: 1}`
      * Metadata: `%{adapter_type: atom(), workspace_id: String.t(), reason: term()}`
  """

  @prefix [:monkey_claw, :channel]

  @doc "Emit an inbound message event."
  @spec message_inbound(map()) :: :ok
  def message_inbound(metadata) when is_map(metadata) do
    :telemetry.execute(@prefix ++ [:message, :inbound], %{count: 1}, metadata)
  end

  @doc "Emit an outbound message event."
  @spec message_outbound(map()) :: :ok
  def message_outbound(metadata) when is_map(metadata) do
    :telemetry.execute(@prefix ++ [:message, :outbound], %{count: 1}, metadata)
  end

  @doc "Emit a connection up event."
  @spec connection_up(map()) :: :ok
  def connection_up(metadata) when is_map(metadata) do
    :telemetry.execute(@prefix ++ [:connection, :up], %{count: 1}, metadata)
  end

  @doc "Emit a connection down event."
  @spec connection_down(map()) :: :ok
  def connection_down(metadata) when is_map(metadata) do
    :telemetry.execute(@prefix ++ [:connection, :down], %{count: 1}, metadata)
  end

  @doc "Emit a delivery success event."
  @spec delivery_success(map()) :: :ok
  def delivery_success(metadata) when is_map(metadata) do
    :telemetry.execute(@prefix ++ [:delivery, :success], %{count: 1}, metadata)
  end

  @doc "Emit a delivery failure event."
  @spec delivery_failed(map()) :: :ok
  def delivery_failed(metadata) when is_map(metadata) do
    :telemetry.execute(@prefix ++ [:delivery, :failed], %{count: 1}, metadata)
  end
end
