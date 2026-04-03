defmodule MonkeyClaw.Channels.ChannelMessage do
  @moduledoc """
  Ecto schema for channel message audit trail.

  Records every message sent or received through a channel adapter.
  Used for debugging, analytics, and conversation history reconstruction.

  ## Fields

    * `direction` — Whether the message is `:inbound` (from platform) or `:outbound` (to platform)
    * `content` — The message text content
    * `metadata` — Platform-specific metadata (user info, thread IDs, etc.)
    * `external_id` — Platform-assigned message identifier for deduplication
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type direction :: :inbound | :outbound

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          channel_config_id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          direction: direction(),
          content: String.t() | nil,
          metadata: map(),
          external_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @directions ~w(inbound outbound)a
  @max_content_length 50_000
  @max_external_id_length 255

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "channel_messages" do
    field :direction, Ecto.Enum, values: @directions
    field :content, :string
    field :metadata, :map, default: %{}
    field :external_id, :string

    belongs_to :channel_config, MonkeyClaw.Channels.ChannelConfig
    belongs_to :workspace, MonkeyClaw.Workspaces.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns valid direction values."
  @spec directions() :: [direction(), ...]
  def directions, do: @directions

  @doc "Changeset for creating a new channel message."
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = message, attrs) do
    message
    |> cast(attrs, [:direction, :content, :metadata, :external_id])
    |> validate_required([:direction, :content])
    |> validate_inclusion(:direction, @directions)
    |> validate_length(:content, min: 1, max: @max_content_length)
    |> validate_length(:external_id, max: @max_external_id_length)
    |> validate_metadata()
  end

  defp validate_metadata(changeset) do
    case get_change(changeset, :metadata) do
      nil -> changeset
      meta when is_map(meta) -> changeset
      _ -> add_error(changeset, :metadata, "must be a map")
    end
  end
end
