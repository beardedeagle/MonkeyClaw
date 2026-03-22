defmodule MonkeyClaw.Workspaces do
  @moduledoc """
  Context module for workspace and channel management.

  Provides CRUD operations for workspaces and their channels,
  plus integration functions to render them into BeamAgent session
  and thread configurations. This is the public API for all
  workspace-related operations in MonkeyClaw.

  ## What Is a Workspace

  A workspace organizes a single user's projects and contexts.
  It maps 1:1 to a BeamAgent session — the workspace ID becomes
  the session identifier, and the workspace's optional assistant
  determines the session persona.

  ## What Is a Channel

  A channel is a conversation thread within a workspace. It maps
  1:1 to a BeamAgent thread within the workspace's session. Channel
  names are unique within their workspace.

  ## Integration with AgentBridge

  The `to_session_config/1` function renders a workspace into the
  format expected by `MonkeyClaw.AgentBridge.start_session/1`:

      {:ok, workspace} = Workspaces.get_workspace(id)
      config = Workspaces.to_session_config(workspace)
      AgentBridge.start_session(config)

  The `to_thread_config/1` function renders a channel into thread
  options for `MonkeyClaw.AgentBridge.Scope.thread_opts/1`:

      {:ok, channel} = Workspaces.get_channel(id)
      thread_opts = Workspaces.to_thread_config(channel)

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3) and scope translation to
  `MonkeyClaw.AgentBridge.Scope`.

  ## Related Modules

    * `MonkeyClaw.Workspaces.Workspace` — Workspace Ecto schema
    * `MonkeyClaw.Workspaces.Channel` — Channel Ecto schema
    * `MonkeyClaw.Assistants` — Assistant rendering for session opts
    * `MonkeyClaw.AgentBridge.Scope` — Scope and thread translation
  """

  import Ecto.Query

  alias MonkeyClaw.AgentBridge.Scope
  alias MonkeyClaw.Assistants
  alias MonkeyClaw.Assistants.Assistant
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Workspaces.{Channel, Workspace}

  # ──────────────────────────────────────────────
  # Workspace CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a new workspace.

  Required attributes: `:name`.

  ## Examples

      Workspaces.create_workspace(%{name: "My Project"})
  """
  @spec create_workspace(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs) when is_map(attrs) do
    %Workspace{}
    |> Workspace.create_changeset(attrs)
    |> validate_assistant_exists()
    |> Repo.insert()
  end

  @doc """
  Get a workspace by ID.

  Returns `{:ok, workspace}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_workspace(Ecto.UUID.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def get_workspace(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(Workspace, id) do
      nil -> {:error, :not_found}
      workspace -> {:ok, workspace}
    end
  end

  @doc """
  Get a workspace by ID, raising on not found.
  """
  @spec get_workspace!(Ecto.UUID.t()) :: Workspace.t()
  def get_workspace!(id) when is_binary(id) and byte_size(id) > 0 do
    Repo.get!(Workspace, id)
  end

  @doc """
  List all workspaces, ordered by name.
  """
  @spec list_workspaces() :: [Workspace.t()]
  def list_workspaces do
    Workspace
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Update an existing workspace.
  """
  @spec update_workspace(Workspace.t(), map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def update_workspace(%Workspace{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> Workspace.update_changeset(attrs)
    |> validate_assistant_exists()
    |> Repo.update()
  end

  @doc """
  Delete a workspace.

  Cascades to all channels within the workspace.
  """
  @spec delete_workspace(Workspace.t()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def delete_workspace(%Workspace{} = workspace) do
    Repo.delete(workspace)
  end

  # ──────────────────────────────────────────────
  # Channel CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a new channel within a workspace.

  The workspace association is set automatically via `Ecto.build_assoc/3`.
  Required attributes: `:name`.

  ## Examples

      {:ok, workspace} = Workspaces.get_workspace(workspace_id)
      Workspaces.create_channel(workspace, %{name: "general"})
  """
  @spec create_channel(Workspace.t(), map()) ::
          {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def create_channel(%Workspace{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> Ecto.build_assoc(:channels)
    |> Channel.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a channel by ID.

  Returns `{:ok, channel}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_channel(Ecto.UUID.t()) :: {:ok, Channel.t()} | {:error, :not_found}
  def get_channel(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(Channel, id) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  @doc """
  Get a channel by ID, raising on not found.
  """
  @spec get_channel!(Ecto.UUID.t()) :: Channel.t()
  def get_channel!(id) when is_binary(id) and byte_size(id) > 0 do
    Repo.get!(Channel, id)
  end

  @doc """
  List all channels in a workspace.

  Pinned channels appear first, then alphabetical by name.
  """
  @spec list_channels(Workspace.t() | Ecto.UUID.t()) :: [Channel.t()]
  def list_channels(%Workspace{id: workspace_id}), do: list_channels(workspace_id)

  def list_channels(workspace_id) when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    Channel
    |> where([c], c.workspace_id == ^workspace_id)
    |> order_by([c], desc: c.pinned, asc: c.name)
    |> Repo.all()
  end

  @doc """
  Update an existing channel.
  """
  @spec update_channel(Channel.t(), map()) ::
          {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def update_channel(%Channel{} = channel, attrs) when is_map(attrs) do
    channel
    |> Channel.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a channel.
  """
  @spec delete_channel(Channel.t()) ::
          {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def delete_channel(%Channel{} = channel) do
    Repo.delete(channel)
  end

  # ──────────────────────────────────────────────
  # BeamAgent Integration
  # ──────────────────────────────────────────────

  @doc """
  Render a workspace into a BeamAgent session configuration.

  Returns a map with `:id` and `:session_opts` suitable for
  passing to `MonkeyClaw.AgentBridge.start_session/1`.

  If the workspace has an associated assistant, its persona is
  rendered into session options. If no assistant is set, session
  options default to an empty map — the caller is responsible
  for falling back to the system default assistant.

  Preloads the assistant association if not already loaded.

  ## Examples

      config = Workspaces.to_session_config(workspace)
      AgentBridge.start_session(config)
  """
  @spec to_session_config(Workspace.t()) :: map()
  def to_session_config(%Workspace{} = workspace) do
    workspace = Repo.preload(workspace, :assistant)

    session_opts =
      case workspace.assistant do
        %Assistant{} = assistant ->
          Assistants.to_session_opts(assistant)

        nil ->
          default_session_opts()
      end

    %{id: workspace.id, session_opts: session_opts}
  end

  @doc """
  Render a channel into BeamAgent thread configuration.

  Returns a map suitable for passing to
  `MonkeyClaw.AgentBridge.Scope.thread_opts/1`.

  ## Examples

      thread_opts = Workspaces.to_thread_config(channel)
  """
  @spec to_thread_config(Channel.t()) :: map()
  def to_thread_config(%Channel{} = channel) do
    Scope.thread_opts(%{name: channel.name})
  end

  # ──────────────────────────────────────────────
  # Private Helpers
  # ──────────────────────────────────────────────

  # Returns the default session options for workspaces without an
  # assistant. Configurable via Application env to allow dev/prod
  # to specify different backends (e.g., :claude in dev).
  defp default_session_opts do
    Application.get_env(:monkey_claw, __MODULE__, [])
    |> Keyword.get(:default_session_opts, %{})
  end

  # Validates that the referenced assistant_id exists in the database.
  #
  # SQLite3 does not report named foreign key constraints, so Ecto's
  # `foreign_key_constraint/3` cannot match the DB error. We validate
  # the reference exists before insert/update instead. The DB-level
  # FK constraint remains as defense-in-depth.
  defp validate_assistant_exists(changeset) do
    case Ecto.Changeset.get_change(changeset, :assistant_id) do
      nil ->
        changeset

      assistant_id ->
        case Repo.get(Assistant, assistant_id) do
          nil -> Ecto.Changeset.add_error(changeset, :assistant_id, "does not exist")
          _assistant -> changeset
        end
    end
  end
end
