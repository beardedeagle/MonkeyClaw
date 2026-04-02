defmodule MonkeyClaw.Skills.Skill do
  @moduledoc """
  Ecto schema for skill records.

  A skill is a reusable procedure extracted from a successful experiment.
  Skills are FTS5-indexed for discovery, cached in ETS for low-latency
  injection, and scored for effectiveness based on usage outcomes.

  ## Associations

    * `belongs_to :workspace` — Required parent workspace. Skills
      are cascade-deleted when their workspace is deleted.

    * `belongs_to :source_experiment` — Optional source experiment from which
      the skill was extracted. Set to nil for manually created skills.

  ## Effectiveness Scoring

  Skills track `usage_count` and `success_count`. The effectiveness
  score is `success_count / usage_count` when usage_count > 0,
  defaulting to 0.5 (neutral prior) otherwise. Clamped to [0.0, 1.0].

  ## Tags

  Tags are stored as a JSON array in a TEXT column and represented
  as a list of strings in Elixir. The `{:array, :string}` Ecto type
  handles JSON serialization via `ecto_sqlite3`; explicit list
  validation in changesets ensures correctness.

  ## Design

  This is NOT a process. Skills are data entities persisted in
  SQLite3 via Ecto.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Experiments.Experiment
  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          procedure: String.t() | nil,
          tags: [String.t()],
          source_experiment_id: Ecto.UUID.t() | nil,
          effectiveness_score: float(),
          usage_count: non_neg_integer(),
          success_count: non_neg_integer(),
          fts_rowid: integer() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @create_fields [:title, :description, :procedure, :tags, :source_experiment_id]
  @update_fields [
    :title,
    :description,
    :procedure,
    :tags,
    :effectiveness_score,
    :usage_count,
    :success_count
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "skills" do
    field :title, :string
    field :description, :string
    field :procedure, :string
    field :tags, {:array, :string}, default: []
    field :effectiveness_score, :float, default: 0.5
    field :usage_count, :integer, default: 0
    field :success_count, :integer, default: 0
    field :fts_rowid, :integer

    belongs_to :workspace, Workspace
    belongs_to :source_experiment, Experiment, foreign_key: :source_experiment_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new skill.

  The `:workspace_id` is set via `Ecto.build_assoc/3` in the
  context module. Required fields: `:title`, `:description`, `:procedure`.

  ## Examples

      workspace
      |> Ecto.build_assoc(:skills)
      |> Skill.create_changeset(%{
        title: "Optimize Parser Performance",
        description: "Steps to profile and optimize Elixir parsers",
        procedure: "1. Profile with :fprof\\n2. Identify hot paths...",
        tags: ["code", "optimization"]
      })
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = skill, attrs) when is_map(attrs) do
    skill
    |> cast(attrs, @create_fields)
    |> validate_required([:title, :description, :procedure])
    |> validate_length(:title, max: 200)
    |> validate_tags()
    |> validate_score_bounds()
    |> generate_fts_rowid()
    |> unique_constraint(:fts_rowid)
    |> assoc_constraint(:workspace)
  end

  @doc """
  Changeset for updating an existing skill.

  Updates title, description, procedure, and tags. Never updates
  `fts_rowid` (immutable after creation) or `workspace_id`.

  ## Examples

      skill
      |> Skill.update_changeset(%{
        title: "Updated Title",
        tags: ["new", "tags"]
      })
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = skill, attrs) when is_map(attrs) do
    skill
    |> cast(attrs, @update_fields)
    |> validate_length(:title, max: 200)
    |> validate_tags()
    |> validate_score_bounds()
  end

  # Tags must be a list of strings.
  defp validate_tags(changeset) do
    case fetch_change(changeset, :tags) do
      {:ok, tags} when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1) do
          changeset
        else
          add_error(changeset, :tags, "must be a list of strings")
        end

      {:ok, _} ->
        add_error(changeset, :tags, "must be a list of strings")

      :error ->
        changeset
    end
  end

  # Effectiveness score must be between 0.0 and 1.0.
  defp validate_score_bounds(changeset) do
    validate_number(changeset, :effectiveness_score,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end

  # Generate a 63-bit random integer for FTS5 external content linkage.
  # Only set on create — fts_rowid is immutable after insertion.
  defp generate_fts_rowid(changeset) do
    if get_field(changeset, :fts_rowid) do
      changeset
    else
      <<int::unsigned-64>> = :crypto.strong_rand_bytes(8)
      masked = Bitwise.band(int, 0x7FFF_FFFF_FFFF_FFFF)
      put_change(changeset, :fts_rowid, max(masked, 1))
    end
  end
end
