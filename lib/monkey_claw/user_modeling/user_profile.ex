defmodule MonkeyClaw.UserModeling.UserProfile do
  @moduledoc """
  Ecto schema for user profile records.

  A user profile accumulates observations about the user's behavior
  within a workspace — topics of interest, interaction patterns, and
  preferences. The profile is used by the injection plug to provide
  personalized context in agent queries.

  ## Privacy Levels

    * `:full` — All observations recorded and available for injection
    * `:limited` — Only topic frequency observations, no behavioral
      patterns (query timing, response preferences)
    * `:none` — No observations recorded, no injection. Profile exists
      only for display_name and explicit preferences.

  ## Associations

    * `belongs_to :workspace` — Required parent workspace. One profile
      per workspace (enforced by unique index). Profiles are cascade-
      deleted when their workspace is deleted.

  ## Design

  This is NOT a process. User profiles are data entities persisted in
  SQLite3 via Ecto. The `MonkeyClaw.UserModeling.Observer` GenServer
  batches observations and periodically flushes them to profile records.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          display_name: String.t() | nil,
          preferences: map(),
          observed_topics: map(),
          observed_patterns: map(),
          privacy_level: privacy_level() | nil,
          injection_enabled: boolean(),
          last_observed_at: DateTime.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type privacy_level :: :full | :limited | :none

  @privacy_levels [:full, :limited, :none]

  @create_fields [
    :display_name,
    :preferences,
    :privacy_level,
    :injection_enabled
  ]
  @update_fields [
    :display_name,
    :preferences,
    :observed_topics,
    :observed_patterns,
    :privacy_level,
    :injection_enabled,
    :last_observed_at
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_profiles" do
    field :display_name, :string
    field :preferences, :map, default: %{}
    field :observed_topics, :map, default: %{}
    field :observed_patterns, :map, default: %{}
    field :privacy_level, Ecto.Enum, values: @privacy_levels, default: :full
    field :injection_enabled, :boolean, default: true
    field :last_observed_at, :utc_datetime_usec

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid privacy levels.
  """
  @spec privacy_levels() :: [privacy_level(), ...]
  def privacy_levels, do: @privacy_levels

  @doc """
  Returns true if the privacy level allows observations.
  """
  @spec observing?(privacy_level()) :: boolean()
  def observing?(:none), do: false
  def observing?(_level), do: true

  @doc """
  Returns true if the privacy level allows behavioral pattern tracking.
  """
  @spec tracks_patterns?(privacy_level()) :: boolean()
  def tracks_patterns?(:full), do: true
  def tracks_patterns?(_level), do: false

  @doc """
  Changeset for creating a new user profile.

  The `:workspace_id` is set via `Ecto.build_assoc/3` in the
  context module. No required fields beyond the workspace
  association — all profile fields have sensible defaults.

  ## Examples

      workspace
      |> Ecto.build_assoc(:user_profile)
      |> UserProfile.create_changeset(%{
        display_name: "Developer",
        privacy_level: :full
      })
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = profile, attrs) when is_map(attrs) do
    profile
    |> cast(attrs, @create_fields)
    |> validate_length(:display_name, max: 100)
    |> validate_inclusion(:privacy_level, @privacy_levels)
    |> validate_preferences()
    |> assoc_constraint(:workspace)
    |> unique_constraint(:workspace_id)
  end

  @doc """
  Changeset for updating an existing user profile.

  Used both for explicit user updates (display_name, preferences,
  privacy controls) and by the Observer for merging observations.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = profile, attrs) when is_map(attrs) do
    profile
    |> cast(attrs, @update_fields)
    |> validate_length(:display_name, max: 100)
    |> validate_inclusion(:privacy_level, @privacy_levels)
    |> validate_preferences()
  end

  # Validate preferences is a flat map (no nested structures that
  # would complicate JSON round-tripping through SQLite TEXT).
  defp validate_preferences(changeset) do
    case get_field(changeset, :preferences) do
      prefs when is_map(prefs) ->
        if Enum.all?(Map.values(prefs), &serializable_value?/1) do
          changeset
        else
          add_error(changeset, :preferences, "values must be strings, numbers, or booleans")
        end

      _ ->
        changeset
    end
  end

  defp serializable_value?(v) when is_binary(v), do: true
  defp serializable_value?(v) when is_number(v), do: true
  defp serializable_value?(v) when is_boolean(v), do: true
  defp serializable_value?(_), do: false
end
