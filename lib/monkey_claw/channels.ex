defmodule MonkeyClaw.Channels do
  @moduledoc """
  Context module for channel adapter management.

  Provides CRUD operations for channel configurations and message
  recording. This module is stateless — all state lives in Ecto/SQLite3.

  ## PubSub Topics

  Channel events are broadcast on workspace-scoped topics:

    * `"channels:{workspace_id}"` — Channel events for a workspace
      * `{:channel_message, direction, message}` — New message sent or received
      * `{:channel_status_changed, config_id, status}` — Connection status changed

  ## Design

  This is a stateless context module, NOT a process. It delegates
  persistence to Ecto and event broadcasting to Phoenix.PubSub.
  """

  import Ecto.Query

  alias MonkeyClaw.Channels.{Adapter, ChannelConfig, ChannelMessage}
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Workspaces.Workspace

  @default_message_limit 50
  @max_message_limit 200

  # ── Channel Config CRUD ───────────────────────────────────────

  @doc "Create a channel config for a workspace."
  @spec create_config(Workspace.t(), map()) ::
          {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t()}
  def create_config(%Workspace{} = workspace, attrs) when is_map(attrs) do
    %ChannelConfig{workspace_id: workspace.id}
    |> ChannelConfig.create_changeset(attrs)
    |> validate_adapter_config(attrs)
    |> Repo.insert()
  end

  @doc "Get a channel config by ID."
  @spec get_config(String.t()) :: {:ok, ChannelConfig.t()} | {:error, :not_found}
  def get_config(id) when is_binary(id) do
    case Repo.get(ChannelConfig, id) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  @doc "List all channel configs for a workspace."
  @spec list_configs(String.t()) :: [ChannelConfig.t()]
  def list_configs(workspace_id) when is_binary(workspace_id) do
    ChannelConfig
    |> where([c], c.workspace_id == ^workspace_id)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc "List enabled channel configs for a workspace."
  @spec list_enabled_configs(String.t()) :: [ChannelConfig.t()]
  def list_enabled_configs(workspace_id) when is_binary(workspace_id) do
    ChannelConfig
    |> where([c], c.workspace_id == ^workspace_id and c.enabled == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc "List all enabled channel configs grouped by adapter type."
  @spec list_enabled_by_adapter() :: %{atom() => [ChannelConfig.t()]}
  def list_enabled_by_adapter do
    ChannelConfig
    |> where([c], c.enabled == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
    |> Enum.group_by(& &1.adapter_type)
  end

  @doc "Update a channel config."
  @spec update_config(ChannelConfig.t(), map()) ::
          {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_config(%ChannelConfig{} = config, attrs) when is_map(attrs) do
    config
    |> ChannelConfig.update_changeset(attrs)
    |> validate_adapter_config(attrs)
    |> Repo.update()
  end

  @doc "Delete a channel config."
  @spec delete_config(ChannelConfig.t()) ::
          {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t()}
  def delete_config(%ChannelConfig{} = config) do
    Repo.delete(config)
  end

  @doc "Update a channel's connection status."
  @spec update_status(ChannelConfig.t(), ChannelConfig.status()) ::
          {:ok, ChannelConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_status(%ChannelConfig{} = config, status) do
    config
    |> ChannelConfig.status_changeset(status)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_status_changed(updated)
      _ -> :ok
    end)
  end

  # ── Channel Messages ──���───────────────────────────────────────

  @doc "Record a channel message (inbound or outbound)."
  @spec record_message(ChannelConfig.t(), map()) ::
          {:ok, ChannelMessage.t()} | {:error, Ecto.Changeset.t()}
  def record_message(%ChannelConfig{} = config, attrs) when is_map(attrs) do
    %ChannelMessage{
      channel_config_id: config.id,
      workspace_id: config.workspace_id
    }
    |> ChannelMessage.create_changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, message} -> broadcast_message(config.workspace_id, message)
      _ -> :ok
    end)
  end

  @doc "List messages for a channel config."
  @spec list_messages(String.t(), map()) :: [ChannelMessage.t()]
  def list_messages(channel_config_id, opts \\ %{}) when is_binary(channel_config_id) do
    limit = clamp_limit(opts)

    ChannelMessage
    |> where([m], m.channel_config_id == ^channel_config_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "List messages for a workspace across all channels."
  @spec list_workspace_messages(String.t(), map()) :: [ChannelMessage.t()]
  def list_workspace_messages(workspace_id, opts \\ %{}) when is_binary(workspace_id) do
    limit = clamp_limit(opts)

    ChannelMessage
    |> where([m], m.workspace_id == ^workspace_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # ── PubSub ────────────────────────────────────────────────────

  @doc "Subscribe to channel events for a workspace."
  @spec subscribe(String.t()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, topic(workspace_id))
  end

  @doc "Unsubscribe from channel events for a workspace."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.unsubscribe(MonkeyClaw.PubSub, topic(workspace_id))
  end

  @doc "Returns the PubSub topic for a workspace's channel events."
  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id) do
    "channels:#{workspace_id}"
  end

  # ── Private ────���────────────────────────────────��─────────────

  defp broadcast_message(workspace_id, %ChannelMessage{} = message) do
    Phoenix.PubSub.broadcast(
      MonkeyClaw.PubSub,
      topic(workspace_id),
      {:channel_message, message.direction, message}
    )
  end

  defp broadcast_status_changed(%ChannelConfig{} = config) do
    Phoenix.PubSub.broadcast(
      MonkeyClaw.PubSub,
      topic(config.workspace_id),
      {:channel_status_changed, config.id, config.status}
    )
  end

  defp validate_adapter_config(changeset, attrs) do
    # Validate adapter config whenever adapter_type or config changes.
    # On create, adapter_type is always a change. On update, adapter_type
    # is not cast (immutable), so we use get_field to read the existing
    # value and validate whenever the config map changes.
    adapter_type = Ecto.Changeset.get_field(changeset, :adapter_type)
    has_config_change = Ecto.Changeset.get_change(changeset, :config) != nil
    has_type_change = Ecto.Changeset.get_change(changeset, :adapter_type) != nil

    if adapter_type && (has_type_change || has_config_change) do
      config = Map.get(attrs, :config, Map.get(attrs, "config", %{}))
      do_validate_adapter_config(changeset, adapter_type, config)
    else
      changeset
    end
  end

  defp do_validate_adapter_config(changeset, adapter_type, config) do
    with {:ok, mod} <- Adapter.for_type(adapter_type),
         :ok <- mod.validate_config(config) do
      changeset
    else
      {:error, :unknown_adapter} ->
        Ecto.Changeset.add_error(changeset, :adapter_type, "unknown adapter type")

      {:error, reason} ->
        Ecto.Changeset.add_error(changeset, :config, reason)
    end
  end

  defp clamp_limit(opts) do
    opts
    |> Map.get(:limit, @default_message_limit)
    |> min(@max_message_limit)
    |> max(1)
  end
end
