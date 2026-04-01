defmodule MonkeyClaw.Sessions.Session do
  @moduledoc """
  Ecto schema for conversation session records.

  A session represents a single conversation interaction within a
  workspace. Each time a user chats with the agent, a new session
  is created to track that conversation's metadata and messages.

  ## Associations

    * `belongs_to :workspace` — Required parent workspace. Sessions
      are cascade-deleted when their workspace is deleted.

    * `has_many :messages` — Ordered message history for this session.
      Messages are cascade-deleted when the session is deleted.

  ## Status

  Sessions have a `:status` field:

    * `:active` — Conversation currently in progress (default)
    * `:stopped` — Conversation ended gracefully
    * `:crashed` — Session process terminated abnormally

  ## Title Derivation

  The `:title` field is nullable on creation and auto-derived from
  the first user message via `MonkeyClaw.Sessions.derive_title/1`.
  Users cannot edit titles directly (they are system-generated).

  ## Message Count

  The `:message_count` field is a denormalized counter incremented
  atomically by `MonkeyClaw.Sessions.record_message/2`. This avoids
  a COUNT query for every session listing in the sidebar.

  ## Design

  This is NOT a process. Sessions are data entities persisted in
  SQLite3 via Ecto. The `MonkeyClaw.AgentBridge.Session` GenServer
  creates and updates these records as messages flow through.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Sessions.Message
  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          status: status() | nil,
          model: String.t() | nil,
          message_count: non_neg_integer(),
          summary: String.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type status :: :active | :stopped | :crashed

  @statuses [:active, :stopped, :crashed]

  @create_fields [:title, :status, :model, :summary]
  @update_fields [:title, :status, :model, :message_count, :summary]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sessions" do
    field :title, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :model, :string
    field :message_count, :integer, default: 0
    field :summary, :string

    belongs_to :workspace, Workspace
    has_many :messages, Message

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new session.

  The `:workspace_id` is set via `Ecto.build_assoc/3` in the
  context module. Only `:title`, `:status`, `:model`, and
  `:summary` are castable on creation.

  ## Examples

      workspace
      |> Ecto.build_assoc(:sessions)
      |> Session.create_changeset(%{model: "claude-sonnet-4-6"})
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = session, attrs) when is_map(attrs) do
    session
    |> cast(attrs, @create_fields)
    |> validate_length(:title, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:model, max: 100)
    |> assoc_constraint(:workspace)
  end

  @doc """
  Changeset for updating an existing session.

  Allows updating `:title`, `:status`, `:model`, `:message_count`,
  and `:summary`.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = session, attrs) when is_map(attrs) do
    session
    |> cast(attrs, @update_fields)
    |> validate_length(:title, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:model, max: 100)
    |> validate_number(:message_count, greater_than_or_equal_to: 0)
  end
end
