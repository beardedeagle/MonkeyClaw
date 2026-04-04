defmodule MonkeyClaw.ModelRegistry.CachedModel do
  @moduledoc """
  Ecto schema for cached model records.

  A cached model represents an AI model available from a provider,
  stored locally to avoid repeated API calls to provider model-list
  endpoints. Records are refreshed periodically by the
  `MonkeyClaw.ModelRegistry` GenServer.

  ## Fields

    * `:provider` — Provider identifier (anthropic, openai, google, github_copilot, local)
    * `:model_id` — The provider's identifier for this model
    * `:display_name` — Human-friendly name for UI display
    * `:capabilities` — Provider-specific capability metadata (stored as JSON text in SQLite)
    * `:refreshed_at` — When this record was last refreshed from the provider API

  ## Design

  This is NOT a process. Cached models are data entities persisted
  in SQLite3 via Ecto and served from ETS for low-latency reads.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          provider: String.t() | nil,
          model_id: String.t() | nil,
          display_name: String.t() | nil,
          capabilities: map(),
          refreshed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @providers ~w(anthropic openai google github_copilot local)

  @create_fields [:provider, :model_id, :display_name, :capabilities, :refreshed_at]
  @update_fields [:display_name, :capabilities, :refreshed_at]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cached_models" do
    field :provider, :string
    field :model_id, :string
    field :display_name, :string
    field :capabilities, :map, default: %{}
    field :refreshed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new cached model record.

  Required fields: `:provider`, `:model_id`, `:display_name`, `:refreshed_at`.

  ## Validation

    * Provider: one of #{inspect(@providers)}
    * Model ID: non-empty string
    * Display name: non-empty string
    * Unique constraint on `[:provider, :model_id]`
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = model, attrs) when is_map(attrs) do
    model
    |> cast(attrs, @create_fields)
    |> validate_required([:provider, :model_id, :display_name, :refreshed_at])
    |> validate_provider()
    |> validate_length(:model_id, min: 1)
    |> validate_length(:display_name, min: 1)
    |> unique_constraint([:provider, :model_id])
  end

  @doc """
  Changeset for updating an existing cached model record.

  Only `:display_name`, `:capabilities`, and `:refreshed_at` can be updated.
  Provider and model ID are immutable after creation.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = model, attrs) when is_map(attrs) do
    model
    |> cast(attrs, @update_fields)
    |> validate_required([:refreshed_at])
    |> validate_length(:display_name, min: 1)
  end

  @doc """
  Returns the list of valid provider identifiers.
  """
  @spec valid_providers() :: [String.t()]
  def valid_providers, do: @providers

  # ── Private ─────────────────────────────────────────────────

  defp validate_provider(changeset) do
    case fetch_change(changeset, :provider) do
      :error ->
        changeset

      {:ok, value} when value in @providers ->
        changeset

      {:ok, _} ->
        add_error(changeset, :provider, "must be one of: #{Enum.join(@providers, ", ")}")
    end
  end
end
