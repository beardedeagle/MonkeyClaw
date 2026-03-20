defmodule MonkeyClaw.Workspaces.Channel do
  @moduledoc """
  Ecto schema for channel definitions.

  A channel is a conversation thread within a workspace. It maps
  1:1 to a BeamAgent thread within the workspace's session.

  ## Associations

    * `belongs_to :workspace` — Required parent workspace. The channel
      cannot exist without a workspace. Channels are cascade-deleted
      when their workspace is deleted.

  ## Status

  Channels have a `:status` field:

    * `:open` — Active conversation (default)
    * `:archived` — Closed conversation, excluded from default listings

  ## Pinning

  Channels can be pinned for quick access. Pinned channels sort
  before unpinned channels in listing queries.

  ## Naming

  Channel names are unique within their workspace — enforced by a
  composite unique index on `(workspace_id, name)`.

  ## Design

  This is NOT a process. Channels are data entities persisted in
  SQLite3 via Ecto. They are read from the database and rendered
  into BeamAgent thread configurations as needed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          pinned: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type status :: :open | :archived

  @statuses [:open, :archived]

  @create_fields [:name, :description, :status, :pinned]
  @update_fields [:name, :description, :status, :pinned]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "channels" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :pinned, :boolean, default: false

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new channel.

  Required fields: `:name`. The `:workspace_id` is set via
  `Ecto.build_assoc/3` in the context module — it is not
  included in the cast fields to prevent callers from
  overriding the workspace association.

  ## Examples

      workspace
      |> Ecto.build_assoc(:channels)
      |> Channel.create_changeset(%{name: "general"})
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = channel, attrs) when is_map(attrs) do
    channel
    |> cast(attrs, @create_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :name])
  end

  @doc """
  Changeset for updating an existing channel.

  The `:workspace_id` cannot be changed after creation.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = channel, attrs) when is_map(attrs) do
    channel
    |> cast(attrs, @update_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint([:workspace_id, :name])
  end
end
