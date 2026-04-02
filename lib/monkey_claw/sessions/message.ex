defmodule MonkeyClaw.Sessions.Message do
  @moduledoc """
  Ecto schema for individual messages within a conversation session.

  Messages are immutable records — once persisted, they are never
  updated (only inserted or deleted with their parent session).
  The schema enforces this by omitting `updated_at` from timestamps.

  ## Roles

  Each message has a `:role` that identifies its source:

    * `:user` — Message sent by the human user
    * `:assistant` — Response from the AI agent
    * `:system` — System-generated message (e.g., session start)
    * `:tool_use` — Agent invoking a tool
    * `:tool_result` — Result returned from a tool invocation

  ## Ordering

  Messages are ordered by their `:sequence` field, which is a
  monotonically increasing integer within each session. This is
  set by the context module on insertion, not by the caller.

  ## Metadata

  The `:metadata` field stores structured data as a JSON map:

    * Tool messages: `%{"tool_name" => "read_file", ...}`
    * Assistant messages: `%{"model" => "claude-sonnet-4-6", ...}`
    * Content blocks: `%{"content_blocks" => [...], ...}`

  ## FTS5 Integration

  Message content is indexed in an FTS5 external content table
  (`session_messages_fts`). The `fts_rowid` field is an
  application-generated unique integer (63-bit random via
  `:crypto.strong_rand_bytes/1`) that bridges the WITHOUT ROWID
  source table to the FTS5 index — FTS5 external content mode
  requires an integer key for linkage. Database triggers keep the
  index in sync automatically on INSERT and DELETE — no
  application-level sync needed beyond generating the `fts_rowid`
  at changeset time.

  ## Design

  This is NOT a process. Messages are data entities persisted in
  SQLite3 via Ecto.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Sessions.Session

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          role: role() | nil,
          content: String.t() | nil,
          sequence: non_neg_integer() | nil,
          fts_rowid: integer() | nil,
          metadata: map(),
          session_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @type role :: :user | :assistant | :system | :tool_use | :tool_result

  @roles [:user, :assistant, :system, :tool_use, :tool_result]

  @doc """
  Returns the list of valid message roles.
  """
  @spec roles() :: [role(), ...]
  def roles, do: @roles

  @create_fields [:role, :content, :sequence, :metadata]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "session_messages" do
    field :role, Ecto.Enum, values: @roles
    field :content, :string
    field :sequence, :integer
    field :fts_rowid, :integer
    field :metadata, :map, default: %{}

    belongs_to :session, Session

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Changeset for creating a new message.

  The `:session_id` is set via `Ecto.build_assoc/3` in the
  context module. Required fields: `:role` and `:sequence`.
  The `:content` field is optional (tool_use messages may have
  no text content). The `:metadata` field defaults to an empty map.

  ## Examples

      session
      |> Ecto.build_assoc(:messages)
      |> Message.create_changeset(%{
        role: :user,
        content: "Hello!",
        sequence: 1
      })
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = message, attrs) when is_map(attrs) do
    message
    |> cast(attrs, @create_fields)
    |> validate_required([:role, :sequence])
    |> validate_inclusion(:role, @roles)
    |> validate_number(:sequence, greater_than_or_equal_to: 0)
    |> assign_fts_rowid()
    |> unique_constraint(:fts_rowid)
    |> normalize_metadata()
    |> assoc_constraint(:session)
  end

  # Generate a restart-safe integer for FTS5 external content linkage.
  # WITHOUT ROWID tables have no implicit rowid, so this bridges
  # the source table to the FTS5 index. Uses a cryptographically
  # random 63-bit positive integer; the unique DB index on fts_rowid
  # plus unique_constraint/3 ensures any extremely unlikely collision
  # is surfaced as a changeset error instead of raising.
  defp assign_fts_rowid(changeset) do
    case get_field(changeset, :fts_rowid) do
      nil -> put_change(changeset, :fts_rowid, random_fts_rowid())
      _existing -> changeset
    end
  end

  defp random_fts_rowid do
    <<int::unsigned-64>> = :crypto.strong_rand_bytes(8)
    Bitwise.band(int, 0x7FFF_FFFF_FFFF_FFFF)
  end

  # Normalize nil metadata to %{} so the DB NOT NULL constraint is
  # never violated. This handles callers that explicitly pass
  # metadata: nil without requiring metadata in validate_required
  # (since it's genuinely optional with a default).
  defp normalize_metadata(changeset) do
    case fetch_change(changeset, :metadata) do
      {:ok, nil} -> put_change(changeset, :metadata, %{})
      _ -> changeset
    end
  end
end
