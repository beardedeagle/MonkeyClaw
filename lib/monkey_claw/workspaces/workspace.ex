defmodule MonkeyClaw.Workspaces.Workspace do
  @moduledoc """
  Ecto schema for workspace definitions.

  A workspace organizes a single user's projects and contexts.
  It maps 1:1 to a BeamAgent session — the workspace ID becomes
  the session-level identifier and memory scope.

  ## Associations

    * `belongs_to :assistant` — Optional assistant persona for the workspace.
      When set, the assistant's configuration is used to initialize
      BeamAgent sessions. When nil, the caller falls back to the
      system default assistant.

    * `has_many :channels` — Conversation threads within this workspace.
      Channels are deleted when the workspace is deleted (cascading
      enforced at the database level).

  ## Status

  Workspaces have a `:status` field:

    * `:active` — Normal operating state (default)
    * `:archived` — Soft-deleted, excluded from default listings

  ## Design

  This is NOT a process. Workspaces are data entities persisted in
  SQLite3 via Ecto. They are read from the database and rendered
  into BeamAgent session configurations as needed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Assistants.Assistant
  alias MonkeyClaw.Experiments.Experiment
  alias MonkeyClaw.Sessions.Session
  alias MonkeyClaw.Skills.Skill
  alias MonkeyClaw.Workspaces.Channel

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          assistant_id: Ecto.UUID.t() | nil,
          status: status() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type status :: :active | :archived

  @statuses [:active, :archived]

  @create_fields [:name, :description, :assistant_id, :status]
  @update_fields [:name, :description, :assistant_id, :status]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspaces" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :active

    belongs_to :assistant, Assistant
    has_many :channels, Channel
    has_many :experiments, Experiment
    has_many :sessions, Session
    has_many :skills, Skill

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new workspace.

  Required fields: `:name`.

  ## Examples

      Workspace.create_changeset(%Workspace{}, %{name: "My Project"})
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> cast(attrs, @create_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name)
  end

  @doc """
  Changeset for updating an existing workspace.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> cast(attrs, @update_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name)
  end
end
