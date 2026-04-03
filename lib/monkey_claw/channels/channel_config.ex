defmodule MonkeyClaw.Channels.ChannelConfig do
  @moduledoc """
  Ecto schema for channel adapter configurations.

  Stores connection details for each channel adapter instance
  (Slack workspace, Discord server, Telegram bot, web UI).
  Workspace-scoped — each workspace can have multiple channels.

  ## Fields

    * `adapter_type` — Platform type (`:slack`, `:discord`, `:telegram`, `:web`)
    * `name` — Human-readable name (unique per workspace)
    * `config` — Platform-specific configuration (API tokens, channel IDs, etc.)
    * `enabled` — Whether this channel is active
    * `status` — Connection status (`:disconnected`, `:connected`, `:error`)

  ## Config Field Contents

  The `config` map holds adapter-specific keys:

    * **Slack**: `bot_token`, `signing_secret`, `channel_id`
    * **Discord**: `bot_token`, `application_id`, `public_key`, `channel_id`
    * **Telegram**: `bot_token`, `chat_id`, `secret_token`
    * **WhatsApp**: `access_token`, `phone_number_id`, `recipient_phone`, `app_secret`, `verify_token`
    * **Web**: empty (uses PubSub internally)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type adapter_type :: :slack | :discord | :telegram | :whatsapp | :web
  @type status :: :disconnected | :connected | :error

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          adapter_type: adapter_type(),
          name: String.t() | nil,
          config: map(),
          enabled: boolean(),
          status: status(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @adapter_types ~w(slack discord telegram whatsapp web)a
  @statuses ~w(disconnected connected error)a
  @max_name_length 100

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "channel_configs" do
    field :adapter_type, Ecto.Enum, values: @adapter_types
    field :name, :string
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true
    field :status, Ecto.Enum, values: @statuses, default: :disconnected

    belongs_to :workspace, MonkeyClaw.Workspaces.Workspace

    has_many :messages, MonkeyClaw.Channels.ChannelMessage

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns valid adapter types."
  @spec adapter_types() :: [adapter_type(), ...]
  def adapter_types, do: @adapter_types

  @doc "Returns valid status values."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @doc "Changeset for creating a new channel config."
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = config, attrs) do
    config
    |> cast(attrs, [:adapter_type, :name, :config, :enabled])
    |> validate_required([:adapter_type, :name])
    |> validate_inclusion(:adapter_type, @adapter_types)
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> validate_config_map()
    |> unique_constraint([:workspace_id, :name], error_key: :name)
  end

  @doc "Changeset for updating a channel config."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = config, attrs) do
    config
    |> cast(attrs, [:name, :config, :enabled, :status])
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> validate_inclusion(:status, @statuses)
    |> validate_config_map()
    |> unique_constraint([:workspace_id, :name], error_key: :name)
  end

  @doc "Changeset for updating connection status only."
  @spec status_changeset(t(), status()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = config, status) when status in @statuses do
    change(config, status: status)
  end

  defp validate_config_map(changeset) do
    case get_change(changeset, :config) do
      nil -> changeset
      config when is_map(config) -> changeset
      _ -> add_error(changeset, :config, "must be a map")
    end
  end
end
