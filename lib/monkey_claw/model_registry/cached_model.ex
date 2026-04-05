defmodule MonkeyClaw.ModelRegistry.CachedModel do
  @moduledoc """
  Ecto schema for the unified model cache.

  One row per `(backend, provider)` pair. Each row holds an embedded
  list of `Model` structs and the metadata the registry uses to
  arbitrate writes: the `source` tag (audit only), the wall-clock
  `refreshed_at` timestamp, and the BEAM-local `refreshed_mono`
  monotonic tiebreaker for same-microsecond races.

  ## Design

  This is NOT a process. Cached model rows are persisted in SQLite3
  via Ecto and served from ETS for low-latency reads. The
  `MonkeyClaw.ModelRegistry` GenServer owns the lifecycle; this
  module is pure schema + changeset.

  ## Fields

    * `:backend` — Backend identifier (e.g., `"claude"`, `"codex"`)
    * `:provider` — Provider identifier (e.g., `"anthropic"`, `"openai"`)
    * `:source` — Writer tag: `"baseline" | "probe" | "session"` (audit only)
    * `:refreshed_at` — Wall-clock timestamp the write was enqueued
    * `:refreshed_mono` — `System.monotonic_time/0` at enqueue, tiebreaker
    * `:models` — Embedded list of `%Model{}` (replaced atomically on write)

  See spec §Schema for full validation invariants.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          backend: String.t() | nil,
          provider: String.t() | nil,
          source: String.t() | nil,
          refreshed_at: DateTime.t() | nil,
          refreshed_mono: integer() | nil,
          models: [__MODULE__.Model.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @identifier_pattern ~r/\A[a-z][a-z0-9_]*\z/
  @max_identifier_length 64
  @allowed_sources ~w(baseline probe session)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cached_models" do
    field :backend, :string
    field :provider, :string
    field :source, :string
    field :refreshed_at, :utc_datetime_usec
    field :refreshed_mono, :integer

    embeds_many :models, Model, on_replace: :delete do
      @moduledoc false
      @type t :: %__MODULE__{
              model_id: String.t() | nil,
              display_name: String.t() | nil,
              capabilities: map()
            }

      field :model_id, :string
      field :display_name, :string
      field :capabilities, :map, default: %{}
    end

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Build a validated changeset for a cached_models row.

  Enforces the trust-boundary invariants from the spec §Schema:
  identifier charset + length caps on `backend`/`provider`, enum
  constraint on `source`, presence of every required top-level
  field, and cast of the embedded models list through
  `model_changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = row, attrs) when is_map(attrs) do
    row
    |> cast(attrs, [:backend, :provider, :source, :refreshed_at, :refreshed_mono])
    |> validate_required([:backend, :provider, :source, :refreshed_at, :refreshed_mono])
    |> validate_length(:backend, min: 1, max: @max_identifier_length)
    |> validate_length(:provider, min: 1, max: @max_identifier_length)
    |> validate_format(:backend, @identifier_pattern, message: "must match ^[a-z][a-z0-9_]*$")
    |> validate_format(:provider, @identifier_pattern, message: "must match ^[a-z][a-z0-9_]*$")
    |> validate_inclusion(:source, @allowed_sources)
    |> cast_embed(:models, with: &model_changeset/2, required: true)
  end

  @doc """
  Returns the allowed values for the `source` column.
  """
  @spec allowed_sources() :: [String.t()]
  def allowed_sources, do: @allowed_sources

  @doc false
  @spec model_changeset(struct(), map()) :: Ecto.Changeset.t()
  def model_changeset(model, attrs) do
    model
    |> cast(attrs, [:model_id, :display_name, :capabilities])
    |> validate_required([:model_id, :display_name])
  end
end
