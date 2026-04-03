defmodule MonkeyClawWeb.NotificationController do
  @moduledoc """
  JSON API controller for workspace-scoped notifications.

  Provides read-only access to notifications with status management
  (mark read, dismiss, mark all read). Notifications are created by
  the `NotificationRouter` — not by API requests.

  ## Routes

    * `GET /api/workspaces/:workspace_id/notifications` — List notifications
    * `PATCH /api/workspaces/:workspace_id/notifications/:id/read` — Mark read
    * `PATCH /api/workspaces/:workspace_id/notifications/:id/dismiss` — Dismiss
    * `POST /api/workspaces/:workspace_id/notifications/read_all` — Mark all read

  ## Design

  This is a standard Phoenix controller. It is NOT a process.
  """

  use MonkeyClawWeb, :controller

  alias MonkeyClaw.Notifications

  @doc """
  List notifications for a workspace.

  Supports optional query parameters:

    * `status` — Filter by status (`unread`, `read`, `dismissed`)
    * `category` — Filter by category (`webhook`, `experiment`, `session`, `system`)
    * `limit` — Maximum results (default: 50, max: 200)
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"workspace_id" => workspace_id} = params) do
    filters = parse_filters(params)
    notifications = Notifications.list_notifications(workspace_id, filters)
    unread_count = Notifications.count_unread(workspace_id)

    conn
    |> put_status(200)
    |> json(%{
      notifications: Enum.map(notifications, &serialize_notification/1),
      unread_count: unread_count
    })
  end

  @doc """
  Mark a notification as read.
  """
  @spec mark_read(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mark_read(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    with {:ok, notification} <- Notifications.get_notification(id),
         :ok <- verify_workspace(notification, workspace_id),
         {:ok, updated} <- Notifications.mark_read(notification) do
      conn
      |> put_status(200)
      |> json(%{notification: serialize_notification(updated)})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, :workspace_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, _changeset} ->
        conn |> put_status(422) |> json(%{error: "unprocessable entity"})
    end
  end

  @doc """
  Dismiss a notification.
  """
  @spec dismiss(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dismiss(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    with {:ok, notification} <- Notifications.get_notification(id),
         :ok <- verify_workspace(notification, workspace_id),
         {:ok, updated} <- Notifications.dismiss(notification) do
      conn
      |> put_status(200)
      |> json(%{notification: serialize_notification(updated)})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, :workspace_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, _changeset} ->
        conn |> put_status(422) |> json(%{error: "unprocessable entity"})
    end
  end

  @doc """
  Mark all unread notifications in a workspace as read.
  """
  @spec mark_all_read(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mark_all_read(conn, %{"workspace_id" => workspace_id}) do
    {count, _} = Notifications.mark_all_read(workspace_id)

    conn
    |> put_status(200)
    |> json(%{marked_read: count})
  end

  # ── Private ─────────────────────────────────────────────────

  # Verify the notification belongs to the requested workspace.
  # Returns opaque 404 on mismatch to prevent enumeration.
  @spec verify_workspace(Notifications.Notification.t(), String.t()) ::
          :ok | {:error, :workspace_mismatch}
  defp verify_workspace(notification, workspace_id) do
    if notification.workspace_id == workspace_id do
      :ok
    else
      {:error, :workspace_mismatch}
    end
  end

  defp parse_filters(params) do
    %{}
    |> maybe_put_atom(:status, params, ~w(unread read dismissed))
    |> maybe_put_atom(:category, params, ~w(webhook experiment session system))
    |> maybe_put_limit(params)
  end

  defp maybe_put_atom(filters, key, params, allowed) do
    value = Map.get(params, to_string(key))

    if is_binary(value) and value in allowed do
      Map.put(filters, key, String.to_atom(value))
    else
      filters
    end
  end

  defp maybe_put_limit(filters, %{"limit" => limit}) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 -> Map.put(filters, :limit, n)
      _ -> filters
    end
  end

  defp maybe_put_limit(filters, _params), do: filters

  @spec serialize_notification(Notifications.Notification.t()) :: map()
  defp serialize_notification(notification) do
    %{
      id: notification.id,
      title: notification.title,
      body: notification.body,
      category: notification.category,
      severity: notification.severity,
      status: notification.status,
      metadata: notification.metadata,
      source_id: notification.source_id,
      source_type: notification.source_type,
      read_at: notification.read_at,
      inserted_at: notification.inserted_at,
      updated_at: notification.updated_at
    }
  end
end
