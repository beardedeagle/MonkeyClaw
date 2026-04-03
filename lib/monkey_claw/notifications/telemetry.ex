defmodule MonkeyClaw.Notifications.Telemetry do
  @moduledoc """
  Telemetry event emission for the notification subsystem.

  All notification telemetry events use the
  `[:monkey_claw, :notification, ...]` prefix.

  ## Events

      [:monkey_claw, :notification, :created]
      [:monkey_claw, :notification, :delivered]
      [:monkey_claw, :notification, :delivery_failed]

  ## Metadata Shape

  Every event carries:

      %{
        notification_id: String.t(),
        workspace_id: String.t(),
        category: String.t(),
        severity: String.t(),
        channel: String.t() | nil
      }

  The `:channel` field is nil for `:created` events (delivery
  hasn't happened yet) and set for `:delivered`/`:delivery_failed`.

  ## Design

  This is NOT a process. Pure function calls that delegate to
  `:telemetry.execute/3`. Safe for concurrent use.
  """

  @prefix [:monkey_claw, :notification]

  @doc """
  Emit a notification created event.

  Called after a notification is successfully persisted.
  """
  @spec created(String.t(), String.t(), atom(), atom()) :: :ok
  def created(notification_id, workspace_id, category, severity)
      when is_binary(notification_id) and is_binary(workspace_id) and
             is_atom(category) and is_atom(severity) do
    :telemetry.execute(
      @prefix ++ [:created],
      %{count: 1},
      %{
        notification_id: notification_id,
        workspace_id: workspace_id,
        category: category,
        severity: severity,
        channel: nil
      }
    )
  end

  @doc """
  Emit a notification delivered event.

  Called after successful delivery through a channel (in_app or email).
  """
  @spec delivered(String.t(), String.t(), atom(), atom(), atom()) :: :ok
  def delivered(notification_id, workspace_id, category, severity, channel)
      when is_binary(notification_id) and is_binary(workspace_id) and
             is_atom(category) and is_atom(severity) and is_atom(channel) do
    :telemetry.execute(
      @prefix ++ [:delivered],
      %{count: 1},
      %{
        notification_id: notification_id,
        workspace_id: workspace_id,
        category: category,
        severity: severity,
        channel: channel
      }
    )
  end

  @doc """
  Emit a notification delivery failure event.

  Called when delivery through a channel fails.
  """
  @spec delivery_failed(String.t(), String.t(), atom(), atom(), atom()) :: :ok
  def delivery_failed(notification_id, workspace_id, category, severity, channel)
      when is_binary(notification_id) and is_binary(workspace_id) and
             is_atom(category) and is_atom(severity) and is_atom(channel) do
    :telemetry.execute(
      @prefix ++ [:delivery_failed],
      %{count: 1},
      %{
        notification_id: notification_id,
        workspace_id: workspace_id,
        category: category,
        severity: severity,
        channel: channel
      }
    )
  end
end
