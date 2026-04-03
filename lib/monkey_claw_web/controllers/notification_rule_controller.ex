defmodule MonkeyClawWeb.NotificationRuleController do
  @moduledoc """
  JSON API controller for workspace-scoped notification rules.

  Provides CRUD operations for notification rules that configure
  how telemetry events are routed to notification channels.

  ## Routes

    * `GET /api/workspaces/:workspace_id/notification_rules` — List rules
    * `POST /api/workspaces/:workspace_id/notification_rules` — Create rule
    * `PATCH /api/workspaces/:workspace_id/notification_rules/:id` — Update rule
    * `DELETE /api/workspaces/:workspace_id/notification_rules/:id` — Delete rule

  ## Design

  This is a standard Phoenix controller. It is NOT a process.
  After mutations (create, update, delete), the controller
  triggers a cache refresh on the NotificationRouter so rule
  changes take effect immediately.
  """

  use MonkeyClawWeb, :controller

  require Logger

  alias MonkeyClaw.Notifications
  alias MonkeyClaw.Notifications.NotificationRule
  alias MonkeyClaw.Notifications.Router, as: NotificationRouter
  alias MonkeyClaw.Workspaces

  @doc """
  List notification rules for a workspace.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"workspace_id" => workspace_id}) do
    case Workspaces.get_workspace(workspace_id) do
      {:ok, _workspace} ->
        rules = Notifications.list_rules(workspace_id)

        conn
        |> put_status(200)
        |> json(%{rules: Enum.map(rules, &serialize_rule/1)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "workspace not found"})
    end
  end

  @doc """
  Create a notification rule.

  After creation, triggers a cache refresh on the NotificationRouter
  so the new rule takes effect immediately.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"workspace_id" => workspace_id} = params) do
    with {:ok, workspace} <- Workspaces.get_workspace(workspace_id),
         {:ok, rule} <- Notifications.create_rule(workspace, rule_params(params)) do
      log_cache_refresh(NotificationRouter.refresh_cache())

      conn
      |> put_status(201)
      |> json(%{rule: serialize_rule(rule)})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "workspace not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  @doc """
  Update a notification rule.
  """
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"workspace_id" => workspace_id, "id" => id} = params) do
    with {:ok, rule} <- Notifications.get_rule(id),
         :ok <- verify_workspace(rule, workspace_id),
         {:ok, updated} <- Notifications.update_rule(rule, rule_params(params)) do
      log_cache_refresh(NotificationRouter.refresh_cache())

      conn
      |> put_status(200)
      |> json(%{rule: serialize_rule(updated)})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, :workspace_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  @doc """
  Delete a notification rule.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"workspace_id" => workspace_id, "id" => id}) do
    with {:ok, rule} <- Notifications.get_rule(id),
         :ok <- verify_workspace(rule, workspace_id),
         {:ok, _deleted} <- Notifications.delete_rule(rule) do
      log_cache_refresh(NotificationRouter.refresh_cache())
      send_resp(conn, 204, "")
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, :workspace_mismatch} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, _changeset} ->
        conn |> put_status(422) |> json(%{error: "unprocessable entity"})
    end
  end

  # ── Private ─────────────────────────────────────────────────

  defp log_cache_refresh(:ok), do: :ok

  defp log_cache_refresh({:error, reason}) do
    Logger.warning("NotificationRouter cache refresh failed: #{inspect(reason)}")
  end

  defp verify_workspace(%NotificationRule{} = rule, workspace_id) do
    if rule.workspace_id == workspace_id do
      :ok
    else
      {:error, :workspace_mismatch}
    end
  end

  @allowed_params ~w(name event_pattern channel enabled min_severity)
  defp rule_params(params) do
    Map.take(params, @allowed_params)
    |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> %{}
  end

  defp serialize_rule(%NotificationRule{} = rule) do
    %{
      id: rule.id,
      name: rule.name,
      event_pattern: rule.event_pattern,
      channel: rule.channel,
      enabled: rule.enabled,
      min_severity: rule.min_severity,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> placeholder_value(key) |> to_string()
      end)
    end)
  end

  defp placeholder_value(opts, key) do
    Enum.find_value(opts, key, fn {opt_key, value} ->
      if to_string(opt_key) == key, do: value
    end)
  end
end
