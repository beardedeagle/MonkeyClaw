defmodule MonkeyClawWeb.NotificationLive do
  @moduledoc """
  LiveComponent for real-time notification display.

  Provides a notification bell with unread count badge and a
  dropdown panel showing recent notifications. Subscribes to
  PubSub for real-time updates when new notifications arrive.

  ## Usage

  Include in any LiveView template:

      <.live_component
        module={MonkeyClawWeb.NotificationLive}
        id="notifications"
        workspace_id={@workspace_id}
      />

  ## Features

    * Real-time unread count badge
    * Dropdown panel with recent notifications
    * Mark individual notifications as read
    * Dismiss individual notifications
    * Mark all as read
    * Severity-colored indicators
    * Auto-updates on new notification arrival

  ## Design

  This is a LiveComponent, not a standalone LiveView. It manages
  its own state (unread count, notification list, dropdown state)
  and PubSub subscription. The parent LiveView must pass a
  `workspace_id` assign.
  """

  use MonkeyClawWeb, :live_component

  alias MonkeyClaw.Notifications

  @max_displayed 20

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       notifications: [],
       unread_count: 0,
       subscribed_workspace_id: nil
     )}
  end

  @impl true
  def update(%{workspace_id: workspace_id} = assigns, socket) do
    # Gracefully handle nil workspace_id — pages that haven't resolved
    # a workspace yet will see an empty notification bell.
    if is_nil(workspace_id) do
      {:ok, assign(socket, assigns)}
    else
      update_with_workspace(assigns, workspace_id, socket)
    end
  end

  # Handle incoming notification from PubSub (forwarded by NotificationHook).
  # Single-user model: accept all notifications regardless of workspace
  # when the component has no workspace filter set.
  def update(%{notification_created: notification}, socket) do
    workspace_id = socket.assigns[:workspace_id]

    show? =
      is_nil(workspace_id) or notification.workspace_id == workspace_id

    if show? do
      notifications = [notification | socket.assigns.notifications] |> Enum.take(@max_displayed)
      unread_count = socket.assigns.unread_count + 1

      {:ok, assign(socket, notifications: notifications, unread_count: unread_count)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # ── Workspace-scoped update logic ─────────────────────────────

  defp update_with_workspace(assigns, workspace_id, socket) do
    # Notification delivery uses the global PubSub topic (via
    # NotificationHook), so workspace-scoped subscription is not
    # needed for :notification_created events.
    workspace_changed = Map.get(socket.assigns, :subscribed_workspace_id) != workspace_id

    socket =
      socket
      |> assign(assigns)
      |> assign(:subscribed_workspace_id, workspace_id)

    # Only load from DB on first mount or workspace change to avoid query churn.
    socket =
      if workspace_changed do
        load_notifications(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open)}
  end

  def handle_event("mark_read", %{"id" => id}, socket) do
    workspace_id = socket.assigns.workspace_id

    with {:ok, notification} <- Notifications.get_notification(id),
         true <- notification.workspace_id == workspace_id,
         {:ok, _} <- Notifications.mark_read(notification) do
      {:noreply, load_notifications(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    workspace_id = socket.assigns.workspace_id

    with {:ok, notification} <- Notifications.get_notification(id),
         true <- notification.workspace_id == workspace_id,
         {:ok, _} <- Notifications.dismiss(notification) do
      {:noreply, load_notifications(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("mark_all_read", _params, socket) do
    _ = Notifications.mark_all_read(socket.assigns.workspace_id)
    {:noreply, load_notifications(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative">
      <button
        phx-click="toggle"
        phx-target={@myself}
        class="relative p-2 rounded-lg hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
        aria-label="Notifications"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          stroke-width="1.5"
          stroke="currentColor"
          class="w-6 h-6 text-zinc-600 dark:text-zinc-400"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M14.857 17.082a23.848 23.848 0 0 0 5.454-1.31A8.967 8.967 0 0 1 18 9.75V9A6 6 0 0 0 6 9v.75a8.967 8.967 0 0 1-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 0 1-5.714 0m5.714 0a3 3 0 1 1-5.714 0"
          />
        </svg>
        <span
          :if={@unread_count > 0}
          class="absolute -top-0.5 -right-0.5 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-red-500 rounded-full"
        >
          {if @unread_count > 99, do: "99+", else: @unread_count}
        </span>
      </button>

      <div
        :if={@open}
        class="absolute right-0 mt-2 w-96 max-h-96 overflow-y-auto bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-700 rounded-xl shadow-lg z-50"
      >
        <div class="flex items-center justify-between px-4 py-3 border-b border-zinc-200 dark:border-zinc-700">
          <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Notifications</h3>
          <button
            :if={@unread_count > 0}
            phx-click="mark_all_read"
            phx-target={@myself}
            class="text-xs text-blue-600 dark:text-blue-400 hover:underline"
          >
            Mark all read
          </button>
        </div>

        <div :if={@notifications == []} class="px-4 py-8 text-center text-sm text-zinc-500">
          No notifications
        </div>

        <div
          :for={notification <- @notifications}
          class={[
            "px-4 py-3 border-b border-zinc-100 dark:border-zinc-800 last:border-b-0",
            notification.status == :unread && "bg-blue-50/50 dark:bg-blue-950/20"
          ]}
        >
          <div class="flex items-start gap-2">
            <span class={["mt-1 w-2 h-2 rounded-full shrink-0", severity_color(notification.severity)]} />
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-zinc-900 dark:text-zinc-100 truncate">
                {notification.title}
              </p>
              <p
                :if={notification.body}
                class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5 line-clamp-2"
              >
                {notification.body}
              </p>
              <div class="flex items-center gap-2 mt-1">
                <span class="text-xs text-zinc-400">{format_time(notification.inserted_at)}</span>
                <span class="text-xs px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-400">
                  {notification.category}
                </span>
              </div>
            </div>
            <div class="flex gap-1 shrink-0">
              <button
                :if={notification.status == :unread}
                phx-click="mark_read"
                phx-value-id={notification.id}
                phx-target={@myself}
                class="text-xs text-blue-600 dark:text-blue-400 hover:underline"
                title="Mark read"
              >
                Read
              </button>
              <button
                phx-click="dismiss"
                phx-value-id={notification.id}
                phx-target={@myself}
                class="text-xs text-zinc-400 hover:text-red-500"
                title="Dismiss"
                aria-label="Dismiss notification"
              >
                &times;
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Private ─────────────────────────────────────────────────

  defp load_notifications(socket) do
    workspace_id = socket.assigns.workspace_id
    notifications = Notifications.list_notifications(workspace_id, %{limit: @max_displayed})
    unread_count = Notifications.count_unread(workspace_id)

    assign(socket, notifications: notifications, unread_count: unread_count)
  end

  defp severity_color(:error), do: "bg-red-500"
  defp severity_color(:warning), do: "bg-amber-500"
  defp severity_color(:info), do: "bg-blue-500"
  defp severity_color(_), do: "bg-zinc-400"

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %H:%M")
  end
end
