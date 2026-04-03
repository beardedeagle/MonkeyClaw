defmodule MonkeyClaw.Notifications do
  @moduledoc """
  Context module for notification and notification rule management.

  Provides CRUD operations, status transitions, and query helpers
  for the notification subsystem. Notifications are workspace-scoped
  and represent user-facing alerts generated from system events.

  ## Related Modules

    * `MonkeyClaw.Notifications.Notification` — Notification Ecto schema
    * `MonkeyClaw.Notifications.NotificationRule` — Rule Ecto schema
    * `MonkeyClaw.Notifications.Router` — GenServer that routes events to notifications
    * `MonkeyClaw.Notifications.EventMapper` — Telemetry → notification translation
    * `MonkeyClaw.Notifications.Email` — Swoosh email builder

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3). All functions are stateless
  and operate on the database through Ecto.
  """

  import Ecto.Query

  alias MonkeyClaw.Notifications.Notification
  alias MonkeyClaw.Notifications.NotificationRule
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Workspaces.Workspace

  # Maximum number of notifications returned by list queries.
  # Prevents unbounded result sets on workspaces with heavy activity.
  @default_limit 50
  @max_limit 200

  # ──────────────────────────────────────────────
  # Notification CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a notification within a workspace.

  The workspace association is set via `Ecto.build_assoc/3`.

  ## Examples

      {:ok, notification} = Notifications.create_notification(workspace, %{
        title: "Webhook received",
        category: :webhook,
        severity: :info
      })
  """
  @spec create_notification(Workspace.t(), map()) ::
          {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def create_notification(%Workspace{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> Ecto.build_assoc(:notifications)
    |> Notification.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a notification by workspace ID.

  Convenience function for creating notifications when only the
  workspace ID is available (e.g., from the NotificationRouter).
  Builds the association manually.
  """
  @spec create_notification_by_workspace_id(String.t(), map()) ::
          {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def create_notification_by_workspace_id(workspace_id, attrs)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and is_map(attrs) do
    %Notification{workspace_id: workspace_id}
    |> Notification.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a notification by ID.

  Returns `{:ok, notification}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_notification(Ecto.UUID.t()) :: {:ok, Notification.t()} | {:error, :not_found}
  def get_notification(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(Notification, id) do
      nil -> {:error, :not_found}
      notification -> {:ok, notification}
    end
  end

  @doc """
  List notifications for a workspace, most recent first.

  ## Options

    * `:status` — Filter by status (`:unread`, `:read`, `:dismissed`)
    * `:category` — Filter by category (`:webhook`, `:experiment`, etc.)
    * `:limit` — Maximum results (default: #{@default_limit}, max: #{@max_limit})
  """
  @spec list_notifications(Ecto.UUID.t(), map()) :: [Notification.t()]
  def list_notifications(workspace_id, filters \\ %{})
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and is_map(filters) do
    raw_limit = Map.get(filters, :limit, @default_limit)

    limit =
      if is_integer(raw_limit), do: raw_limit |> min(@max_limit) |> max(1), else: @default_limit

    Notification
    |> where([n], n.workspace_id == ^workspace_id)
    |> apply_notification_filters(filters)
    |> order_by([n], desc: n.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  List unread notifications for a workspace, most recent first.
  """
  @spec list_unread(Ecto.UUID.t()) :: [Notification.t()]
  def list_unread(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    list_notifications(workspace_id, %{status: :unread})
  end

  @doc """
  Count unread notifications for a workspace.
  """
  @spec count_unread(Ecto.UUID.t()) :: non_neg_integer()
  def count_unread(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    Notification
    |> where([n], n.workspace_id == ^workspace_id and n.status == :unread)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Mark a single notification as read.

  Sets status to `:read` and `read_at` to the current time.
  Returns `{:error, :not_found}` if the notification doesn't exist.
  """
  @spec mark_read(Ecto.UUID.t() | Notification.t()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def mark_read(%Notification{} = notification) do
    notification
    |> Notification.update_changeset(%{status: :read})
    |> Repo.update()
  end

  def mark_read(notification_id)
      when is_binary(notification_id) and byte_size(notification_id) > 0 do
    with {:ok, notification} <- get_notification(notification_id) do
      mark_read(notification)
    end
  end

  @doc """
  Mark all unread notifications in a workspace as read.

  Returns the count of updated notifications.
  """
  @spec mark_all_read(Ecto.UUID.t()) :: {non_neg_integer(), nil}
  def mark_all_read(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    now = DateTime.utc_now()

    Notification
    |> where([n], n.workspace_id == ^workspace_id and n.status == :unread)
    |> Repo.update_all(set: [status: :read, read_at: now, updated_at: now])
  end

  @doc """
  Dismiss a notification.

  Sets status to `:dismissed`.
  """
  @spec dismiss(Ecto.UUID.t() | Notification.t()) ::
          {:ok, Notification.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def dismiss(%Notification{} = notification) do
    notification
    |> Notification.update_changeset(%{status: :dismissed})
    |> Repo.update()
  end

  def dismiss(notification_id)
      when is_binary(notification_id) and byte_size(notification_id) > 0 do
    with {:ok, notification} <- get_notification(notification_id) do
      dismiss(notification)
    end
  end

  @doc """
  Delete old notifications beyond a retention limit.

  Deletes dismissed and read notifications older than the given
  number of days. Returns the count of deleted notifications.
  """
  @spec prune(Ecto.UUID.t(), pos_integer()) :: {non_neg_integer(), nil}
  def prune(workspace_id, days_old)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_integer(days_old) and days_old > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days_old, :day)

    Notification
    |> where([n], n.workspace_id == ^workspace_id)
    |> where([n], n.status in [:read, :dismissed])
    |> where([n], n.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  # ──────────────────────────────────────────────
  # Notification Rule CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a notification rule within a workspace.

  ## Examples

      {:ok, rule} = Notifications.create_rule(workspace, %{
        name: "Webhook alerts",
        event_pattern: "monkey_claw.webhook.received",
        channel: :in_app,
        min_severity: :info
      })
  """
  @spec create_rule(Workspace.t(), map()) ::
          {:ok, NotificationRule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(%Workspace{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> Ecto.build_assoc(:notification_rules)
    |> NotificationRule.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a notification rule by ID.
  """
  @spec get_rule(Ecto.UUID.t()) :: {:ok, NotificationRule.t()} | {:error, :not_found}
  def get_rule(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(NotificationRule, id) do
      nil -> {:error, :not_found}
      rule -> {:ok, rule}
    end
  end

  @doc """
  List notification rules for a workspace.
  """
  @spec list_rules(Ecto.UUID.t()) :: [NotificationRule.t()]
  def list_rules(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    NotificationRule
    |> where([r], r.workspace_id == ^workspace_id)
    |> order_by([r], asc: r.event_pattern)
    |> Repo.all()
  end

  @doc """
  List all enabled notification rules, grouped by event pattern.

  Returns a map of `%{event_pattern => [rule]}`. Used by the
  NotificationRouter to build its rule cache.
  """
  @spec list_enabled_rules_by_pattern() :: %{String.t() => [NotificationRule.t()]}
  def list_enabled_rules_by_pattern do
    NotificationRule
    |> where([r], r.enabled == true)
    |> Repo.all()
    |> Enum.group_by(& &1.event_pattern)
  end

  @doc """
  Update an existing notification rule.
  """
  @spec update_rule(NotificationRule.t(), map()) ::
          {:ok, NotificationRule.t()} | {:error, Ecto.Changeset.t()}
  def update_rule(%NotificationRule{} = rule, attrs) when is_map(attrs) do
    rule
    |> NotificationRule.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a notification rule.
  """
  @spec delete_rule(NotificationRule.t()) ::
          {:ok, NotificationRule.t()} | {:error, Ecto.Changeset.t()}
  def delete_rule(%NotificationRule{} = rule) do
    Repo.delete(rule)
  end

  @doc """
  Enable a notification rule.
  """
  @spec enable_rule(NotificationRule.t()) ::
          {:ok, NotificationRule.t()} | {:error, Ecto.Changeset.t()}
  def enable_rule(%NotificationRule{} = rule) do
    update_rule(rule, %{enabled: true})
  end

  @doc """
  Disable a notification rule.
  """
  @spec disable_rule(NotificationRule.t()) ::
          {:ok, NotificationRule.t()} | {:error, Ecto.Changeset.t()}
  def disable_rule(%NotificationRule{} = rule) do
    update_rule(rule, %{enabled: false})
  end

  # ──────────────────────────────────────────────
  # PubSub
  # ──────────────────────────────────────────────

  @doc """
  Subscribe to notification events for a workspace.

  The subscriber will receive messages of the form:

      {:notification_created, %Notification{}}
  """
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, topic(workspace_id))
  end

  @doc """
  Broadcast a notification event to subscribers.

  Called by the NotificationRouter after creating a notification.
  """
  @spec broadcast_created(Notification.t()) :: :ok | {:error, term()}
  def broadcast_created(%Notification{} = notification) do
    Phoenix.PubSub.broadcast(
      MonkeyClaw.PubSub,
      topic(notification.workspace_id),
      {:notification_created, notification}
    )
  end

  @doc """
  Returns the PubSub topic for a workspace's notifications.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id) do
    "notifications:#{workspace_id}"
  end

  # ──────────────────────────────────────────────
  # Private — Filters
  # ──────────────────────────────────────────────

  defp apply_notification_filters(query, filters) do
    query
    |> maybe_filter_status(filters)
    |> maybe_filter_category(filters)
  end

  defp maybe_filter_status(query, %{status: status}) when is_atom(status) do
    where(query, [n], n.status == ^status)
  end

  defp maybe_filter_status(query, _filters), do: query

  defp maybe_filter_category(query, %{category: category}) when is_atom(category) do
    where(query, [n], n.category == ^category)
  end

  defp maybe_filter_category(query, _filters), do: query
end
