defmodule MonkeyClawWeb.NotificationHook do
  @moduledoc """
  LiveView on_mount hook for global notification support.

  Subscribes the LiveView process to the global notification topic
  and forwards notification messages to the NotificationLive component.
  This ensures notifications are visible on EVERY page — not just the
  chat interface.

  ## Usage

  Applied automatically via `live_session` in the router:

      live_session :default, on_mount: [MonkeyClawWeb.NotificationHook] do
        live "/", DashboardLive
        live "/chat", ChatLive
        # ...
      end

  ## How It Works

  1. On mount, subscribes to `"notifications:global"` PubSub topic
  2. Attaches a `handle_info` hook that intercepts notification messages
  3. Forwards notifications to the NotificationLive component via `send_update/3`

  The global topic receives ALL notifications across all workspaces,
  which is correct for MonkeyClaw's single-user model.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias MonkeyClaw.Notifications

  @doc false
  def on_mount(:default, _params, _session, socket) do
    _ =
      if connected?(socket) do
        Notifications.subscribe_global()
      end

    socket =
      socket
      |> assign(:notification_hook_active, true)
      |> attach_hook(:notification_forwarder, :handle_info, &handle_notification_info/2)

    {:cont, socket}
  end

  defp handle_notification_info({:notification_created, notification}, socket) do
    send_update(MonkeyClawWeb.NotificationLive,
      id: "notifications",
      notification_created: notification
    )

    {:halt, socket}
  end

  defp handle_notification_info(_other, socket) do
    {:cont, socket}
  end
end
