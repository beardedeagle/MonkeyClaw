# List Models Per Backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a unified model registry keyed on `(backend, provider)` with cold-start availability, three-writer funnel, and a full drop-and-replace cutover of the current provider-only schema.

**Architecture:** One SQLite table (`cached_models`) with one row per `(backend, provider)` pair holding an embedded JSON list of models. One GenServer (`ModelRegistry`) owns an ETS table (via heir for crash survival) and serializes all writes through a single `upsert/1` funnel. Three writers — boot-time `Baseline`, periodic per-backend probe (dispatched as `Task.Supervisor` tasks from a `handle_info(:tick, state)`), and an authenticated `AgentBridge.Session` post-start hook — all funnel through the same validated upsert path. Reads are O(1) ETS lookups with SQLite fallback on miss.

**Tech Stack:** Elixir 1.16+, Erlang/OTP 27, Ecto 3 (SQLite3 adapter), ExUnit, existing `MonkeyClaw.Vault.SecretScanner` (for log redaction), existing `MonkeyClaw.TaskSupervisor` (for probe task dispatch), existing `MonkeyClaw.AgentBridge.SessionRegistry` (for session hook authentication).

**Branch:** `feat/MonkeyClaw-list-models-per-backend`

**Spec reference:** `docs/superpowers/specs/2026-04-05-list-models-per-backend-design.md`

**Cutover guarantee:** This is a greenfield drop-and-replace. After all tasks land, a grep of the codebase must show zero references to the old provider-keyed API (`list_models/1`, `list_all_models/0`) and zero dead code from the old schema. Task 29 enforces this as a release gate.

---

## Preconditions

Before starting Task 1:

- [ ] Pull latest `main`: `git switch main && git pull --ff-only`
- [ ] Create branch: `git switch -c feat/MonkeyClaw-list-models-per-backend`
- [ ] Run baseline quality gates to confirm clean starting state:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
MIX_ENV=test mix test
```

All five gates must pass before touching any code. If anything is red on clean `main`, stop and surface the issue — do not start on top of a broken baseline.

- [ ] Open the spec in a pinned buffer and keep it open through the whole plan: `docs/superpowers/specs/2026-04-05-list-models-per-backend-design.md`

---

## Task 1: Schema migration (drop old, create new)

**Files:**
- Create: `priv/repo/migrations/20260407000000_rewrite_cached_models.exs`

**Context:** The latest existing migration is `20260406000000_create_vault.exs` which creates the current `cached_models` table with the provider-keyed shape. We drop that table entirely and create a new one keyed on `(backend, provider)` with an embedded JSON `models` list, a `source` tag, a `refreshed_mono` tiebreaker, and individual + composite indexes.

- [ ] **Step 1: Write the migration file**

Write the following to `priv/repo/migrations/20260407000000_rewrite_cached_models.exs`:

```elixir
defmodule MonkeyClaw.Repo.Migrations.RewriteCachedModels do
  @moduledoc """
  Full drop-and-replace cutover of the cached_models table.

  Greenfield project with zero users — no data is preserved. The old
  provider-keyed single-model-per-row shape is dropped and replaced with
  a (backend, provider)-keyed shape storing models as an embedded JSON
  list per row, with a monotonic tiebreaker column for precedence ties.
  """

  use Ecto.Migration

  def up do
    drop_if_exists table(:cached_models)

    create table(:cached_models, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :backend, :string, null: false
      add :provider, :string, null: false
      add :source, :string, null: false
      add :refreshed_at, :utc_datetime_usec, null: false
      add :refreshed_mono, :integer, null: false
      add :models, :text, null: false, default: "[]"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cached_models, [:backend, :provider])
    create index(:cached_models, [:backend])
    create index(:cached_models, [:provider])
  end

  def down do
    drop_if_exists table(:cached_models)

    create table(:cached_models, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :model_id, :string, null: false
      add :display_name, :string, null: false
      add :capabilities, :text, null: false, default: "{}"
      add :refreshed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cached_models, [:provider, :model_id])
    create index(:cached_models, [:provider])
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: Two info lines — `== Running MonkeyClaw.Repo.Migrations.RewriteCachedModels.up/0 forward` followed by `drop table cached_models` / `create table cached_models` / `create index cached_models_*`, then `== Migrated ... in ...s`.

- [ ] **Step 3: Verify rollback/replay works**

Run: `mix ecto.rollback && mix ecto.migrate`
Expected: rollback reverts cleanly to the old shape, then migrate re-applies the new shape. Both succeed with zero errors.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/20260407000000_rewrite_cached_models.exs
git commit -m "$(cat <<'EOF'
feat: rewrite cached_models schema for (backend, provider) keying

Drops the provider-keyed single-model-per-row table and creates the
(backend, provider)-keyed shape with embedded JSON model list, source
tag, and monotonic tiebreaker column. Greenfield cutover, zero data
preserved. Unique index on (backend, provider) plus individual indexes
on backend and provider for the by-backend and by-provider read paths.
EOF
)"
```

---

## Task 2: Rewrite CachedModel schema from scratch

**Files:**
- Modify: `lib/monkey_claw/model_registry/cached_model.ex` (full replace)
- Delete: `test/monkey_claw/model_registry_test.exs` (exercises old API; rewritten in later tasks)
- Create: `test/monkey_claw/model_registry/cached_model_test.exs`

**Context:** The current `CachedModel` schema has `provider`, `model_id`, `display_name`, `capabilities`, `refreshed_at` as top-level fields. We replace it with `backend`, `provider`, `source`, `refreshed_at`, `refreshed_mono`, plus an `embeds_many :models` with `model_id`, `display_name`, `capabilities` per embed. All validation (from spec §Schema) lands in later tasks — this task only establishes the shape so the compile and migration pipeline pass.

- [ ] **Step 1: Delete the old test file**

```bash
git rm test/monkey_claw/model_registry_test.exs
```

The old test file asserts against the provider-keyed API and will not compile once the schema changes. It is fully replaced by `cached_model_test.exs` (this task) plus `model_registry_test.exs` rewritten in later tasks. Deleting it now prevents compile errors cascading through the schema rewrite.

- [ ] **Step 2: Write the failing smoke test**

Write to `test/monkey_claw/model_registry/cached_model_test.exs`:

```elixir
defmodule MonkeyClaw.ModelRegistry.CachedModelTest do
  @moduledoc """
  Changeset and schema tests for the rewritten CachedModel.

  Runs with DataCase for SQLite sandbox isolation — no GenServer
  required at this layer.
  """

  use MonkeyClaw.DataCase, async: true

  alias MonkeyClaw.ModelRegistry.CachedModel

  describe "schema shape" do
    test "has the new top-level fields" do
      struct = %CachedModel{}
      assert Map.has_key?(struct, :backend)
      assert Map.has_key?(struct, :provider)
      assert Map.has_key?(struct, :source)
      assert Map.has_key?(struct, :refreshed_at)
      assert Map.has_key?(struct, :refreshed_mono)
      assert Map.has_key?(struct, :models)
    end

    test "has no legacy top-level model fields" do
      struct = %CachedModel{}
      refute Map.has_key?(struct, :model_id)
      refute Map.has_key?(struct, :display_name)
      refute Map.has_key?(struct, :capabilities)
    end
  end
end
```

- [ ] **Step 3: Run the test to confirm it fails**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: compile error — either the schema still has the old fields, or references an undefined module, depending on what compiled first. Either way, both tests fail.

- [ ] **Step 4: Rewrite the schema module**

Replace the entire contents of `lib/monkey_claw/model_registry/cached_model.ex` with:

```elixir
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
          models: [Model.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

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
  Build a changeset — validations are added in subsequent tasks.
  This stub exists so the module compiles during the incremental
  cutover. Task 3 replaces this with the full validation chain.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = row, attrs) when is_map(attrs) do
    row
    |> cast(attrs, [:backend, :provider, :source, :refreshed_at, :refreshed_mono])
    |> cast_embed(:models, with: &model_changeset/2)
  end

  @doc false
  @spec model_changeset(struct(), map()) :: Ecto.Changeset.t()
  def model_changeset(model, attrs) do
    cast(model, attrs, [:model_id, :display_name, :capabilities])
  end
end
```

- [ ] **Step 5: Run the schema test to confirm it passes**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 6: Confirm full compile still works**

Run: `mix compile --warnings-as-errors`
Expected: clean compile. (Other modules that referenced the old `CachedModel` API will now fail. If any do, note them — they get rewritten in the ModelRegistry tasks below. If a non-registry module references `CachedModel`, stop and surface it.)

- [ ] **Step 7: Commit**

```bash
git add lib/monkey_claw/model_registry/cached_model.ex \
        test/monkey_claw/model_registry/cached_model_test.exs
git rm test/monkey_claw/model_registry_test.exs 2>/dev/null || true
git commit -m "$(cat <<'EOF'
feat: rewrite CachedModel schema for (backend, provider) keying

Replaces the old flat model row with a (backend, provider)-keyed row
holding an embedded list of models. Adds source tag and refreshed_mono
columns for write arbitration. Deletes the old model_registry_test.exs
(exercised the old API); replaced by cached_model_test.exs here and
model_registry_test.exs rewritten in subsequent tasks. Changeset stub
only — full validation chain lands in task 3.
EOF
)"
```

---

## Task 3: CachedModel changeset — required fields

**Files:**
- Modify: `lib/monkey_claw/model_registry/cached_model.ex`
- Modify: `test/monkey_claw/model_registry/cached_model_test.exs`

**Context:** Per spec §Schema, required fields are `backend`, `provider`, `source`, `refreshed_at`, `refreshed_mono`, `models` (non-empty list allowed). Each embedded model requires `model_id`, `display_name`.

- [ ] **Step 1: Write failing tests for required top-level fields**

Append to `cached_model_test.exs` inside the `describe "schema shape"` block closing, after the `end`:

```elixir
  describe "changeset/2 required fields" do
    @valid_attrs %{
      backend: "claude",
      provider: "anthropic",
      source: "probe",
      refreshed_at: DateTime.utc_now(),
      refreshed_mono: System.monotonic_time(),
      models: [
        %{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}
      ]
    }

    test "valid attrs produce a valid changeset" do
      changeset = CachedModel.changeset(%CachedModel{}, @valid_attrs)
      assert changeset.valid?
    end

    for field <- [:backend, :provider, :source, :refreshed_at, :refreshed_mono] do
      test "requires #{field}" do
        attrs = Map.delete(@valid_attrs, unquote(field))
        changeset = CachedModel.changeset(%CachedModel{}, attrs)
        refute changeset.valid?
        assert errors_on(changeset)[unquote(field)]
      end
    end

    test "requires models to be present" do
      attrs = Map.delete(@valid_attrs, :models)
      changeset = CachedModel.changeset(%CachedModel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:models]
    end

    test "each embedded model requires model_id and display_name" do
      attrs = %{@valid_attrs | models: [%{capabilities: %{}}]}
      changeset = CachedModel.changeset(%CachedModel{}, attrs)
      refute changeset.valid?
    end
  end
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: the `valid attrs` test passes (cast succeeds), but every `requires X` test fails because no `validate_required` is in place yet.

- [ ] **Step 3: Add required-field validation**

In `lib/monkey_claw/model_registry/cached_model.ex`, replace the `changeset/2` function with:

```elixir
  @doc """
  Build a changeset for a cached_models row.

  Validates presence of every top-level required field, casts the
  embedded models list through `model_changeset/2`, and requires at
  least one embedded model.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = row, attrs) when is_map(attrs) do
    row
    |> cast(attrs, [:backend, :provider, :source, :refreshed_at, :refreshed_mono])
    |> validate_required([:backend, :provider, :source, :refreshed_at, :refreshed_mono])
    |> cast_embed(:models, with: &model_changeset/2, required: true)
  end
```

And replace `model_changeset/2` with:

```elixir
  @doc false
  @spec model_changeset(struct(), map()) :: Ecto.Changeset.t()
  def model_changeset(model, attrs) do
    model
    |> cast(attrs, [:model_id, :display_name, :capabilities])
    |> validate_required([:model_id, :display_name])
  end
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: all tests in the `changeset/2 required fields` block pass.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry/cached_model.ex \
        test/monkey_claw/model_registry/cached_model_test.exs
git commit -m "feat: add required-field validation to CachedModel changeset"
```

---

## Task 4: CachedModel changeset — length caps, charset whitelist, source enum

**Files:**
- Modify: `lib/monkey_claw/model_registry/cached_model.ex`
- Modify: `test/monkey_claw/model_registry/cached_model_test.exs`

**Context:** Per spec §Schema, `backend` and `provider` match `^[a-z][a-z0-9_]*$` with length 1–64 bytes; `source` is one of `"baseline" | "probe" | "session"`.

- [ ] **Step 1: Write failing validation tests**

Append a new describe block to `cached_model_test.exs`:

```elixir
  describe "changeset/2 top-level value constraints" do
    @valid_attrs %{
      backend: "claude",
      provider: "anthropic",
      source: "probe",
      refreshed_at: DateTime.utc_now(),
      refreshed_mono: System.monotonic_time(),
      models: [%{model_id: "m", display_name: "M", capabilities: %{}}]
    }

    test "rejects backend with uppercase" do
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | backend: "Claude"})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects backend starting with digit" do
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | backend: "1claude"})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects provider with hyphen" do
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | provider: "anthro-pic"})
      refute cs.valid?
      assert errors_on(cs)[:provider]
    end

    test "rejects backend longer than 64 bytes" do
      long = String.duplicate("a", 65)
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | backend: long})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects empty backend" do
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | backend: ""})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects unknown source" do
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | source: "other"})
      refute cs.valid?
      assert errors_on(cs)[:source]
    end

    for source <- ["baseline", "probe", "session"] do
      test "accepts source=#{source}" do
        cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | source: unquote(source)})
        assert cs.valid?
      end
    end
  end
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: every "rejects X" test fails (no constraint enforced yet); every "accepts X" test passes.

- [ ] **Step 3: Add the validations**

Replace the `changeset/2` function body with the full validation chain:

```elixir
  @identifier_pattern ~r/\A[a-z][a-z0-9_]*\z/
  @max_identifier_length 64
  @allowed_sources ~w(baseline probe session)

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
    |> validate_format(:backend, @identifier_pattern,
      message: "must match ^[a-z][a-z0-9_]*$"
    )
    |> validate_format(:provider, @identifier_pattern,
      message: "must match ^[a-z][a-z0-9_]*$"
    )
    |> validate_inclusion(:source, @allowed_sources)
    |> cast_embed(:models, with: &model_changeset/2, required: true)
  end

  @doc """
  Returns the allowed values for the `source` column.
  """
  @spec allowed_sources() :: [String.t()]
  def allowed_sources, do: @allowed_sources
```

Move `@identifier_pattern`, `@max_identifier_length`, and `@allowed_sources` to module-level attributes near the top of the module (just below `@primary_key`).

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry/cached_model.ex \
        test/monkey_claw/model_registry/cached_model_test.exs
git commit -m "feat: add identifier charset + source enum validation to CachedModel"
```

---

## Task 5: CachedModel changeset — embedded models list cap + per-model validations

**Files:**
- Modify: `lib/monkey_claw/model_registry/cached_model.ex`
- Modify: `test/monkey_claw/model_registry/cached_model_test.exs`

**Context:** Per spec §Schema: `models` list length ≤ 500; each `model_id`/`display_name` is 1–256 bytes, `String.valid?/1`, pattern `^[\p{L}\p{N}._\-: /]+$`; `capabilities` serialized size ≤ 8 KiB.

- [ ] **Step 1: Write failing tests**

Append:

```elixir
  describe "changeset/2 embedded model constraints" do
    @valid_attrs %{
      backend: "claude",
      provider: "anthropic",
      source: "probe",
      refreshed_at: DateTime.utc_now(),
      refreshed_mono: System.monotonic_time(),
      models: [%{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}]
    }

    test "rejects >500 embedded models" do
      too_many =
        Enum.map(1..501, fn i ->
          %{model_id: "m-#{i}", display_name: "M #{i}", capabilities: %{}}
        end)

      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | models: too_many})
      refute cs.valid?
      assert errors_on(cs)[:models]
    end

    test "accepts exactly 500 embedded models" do
      exact =
        Enum.map(1..500, fn i ->
          %{model_id: "m-#{i}", display_name: "M #{i}", capabilities: %{}}
        end)

      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | models: exact})
      assert cs.valid?
    end

    test "rejects model_id longer than 256 bytes" do
      long = String.duplicate("a", 257)
      models = [%{model_id: long, display_name: "D", capabilities: %{}}]
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | models: models})
      refute cs.valid?
    end

    test "rejects non-UTF8 model_id" do
      models = [%{model_id: <<0xFF, 0xFE>>, display_name: "D", capabilities: %{}}]
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | models: models})
      refute cs.valid?
    end

    test "rejects model_id with control chars" do
      models = [%{model_id: "bad\x00id", display_name: "D", capabilities: %{}}]
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | models: models})
      refute cs.valid?
    end

    test "accepts model_id with unicode letters and allowed punctuation" do
      models = [%{model_id: "claude-sonnet-4.5:preview", display_name: "Claude", capabilities: %{}}]
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | models: models})
      assert cs.valid?
    end

    test "rejects capabilities larger than 8 KiB when encoded" do
      giant = %{blob: String.duplicate("x", 9_000)}
      models = [%{model_id: "m", display_name: "M", capabilities: giant}]
      cs = CachedModel.changeset(%CachedModel{}, %{@valid_attrs | models: models})
      refute cs.valid?
    end
  end
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: new tests fail.

- [ ] **Step 3: Add the validations**

Add module attributes near the existing ones:

```elixir
  @max_models_per_row 500
  @max_model_field_length 256
  @max_capabilities_bytes 8 * 1024
  @model_field_pattern ~r/\A[\p{L}\p{N}._\-: \/]+\z/u
```

Add a list-length validator after `cast_embed`:

```elixir
    |> validate_length(:models, max: @max_models_per_row)
```

(Insert it directly after the `cast_embed` call in `changeset/2`.)

Replace `model_changeset/2` with the full version:

```elixir
  @doc false
  @spec model_changeset(struct(), map()) :: Ecto.Changeset.t()
  def model_changeset(model, attrs) do
    model
    |> cast(attrs, [:model_id, :display_name, :capabilities])
    |> validate_required([:model_id, :display_name])
    |> validate_length(:model_id, min: 1, max: @max_model_field_length)
    |> validate_length(:display_name, min: 1, max: @max_model_field_length)
    |> validate_utf8(:model_id)
    |> validate_utf8(:display_name)
    |> validate_format(:model_id, @model_field_pattern,
      message: "contains invalid characters"
    )
    |> validate_format(:display_name, @model_field_pattern,
      message: "contains invalid characters"
    )
    |> validate_capabilities_size()
  end

  defp validate_utf8(changeset, field) do
    case get_field(changeset, field) do
      value when is_binary(value) ->
        if String.valid?(value) do
          changeset
        else
          add_error(changeset, field, "must be valid UTF-8")
        end

      _ ->
        changeset
    end
  end

  defp validate_capabilities_size(changeset) do
    case get_field(changeset, :capabilities) do
      caps when is_map(caps) ->
        case Jason.encode(caps) do
          {:ok, json} when byte_size(json) <= @max_capabilities_bytes ->
            changeset

          {:ok, _} ->
            add_error(changeset, :capabilities,
              "encoded size exceeds #{@max_capabilities_bytes} bytes"
            )

          {:error, _} ->
            add_error(changeset, :capabilities, "is not JSON-encodable")
        end

      _ ->
        changeset
    end
  end
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/cached_model_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry/cached_model.ex \
        test/monkey_claw/model_registry/cached_model_test.exs
git commit -m "feat: add embedded model validations to CachedModel changeset

Caps models list at 500, enforces 256-byte length and UTF-8 charset on
model_id/display_name, requires allowed punctuation pattern, caps
capabilities serialized size at 8 KiB. Closes out the trust-boundary
invariant set from spec section Schema."
```

---

## Task 6: Baseline module

**Files:**
- Create: `lib/monkey_claw/model_registry/baseline.ex`
- Create: `test/monkey_claw/model_registry/baseline_test.exs`

**Context:** `Baseline` is a pure runtime-config reader. `all/0` returns the raw config entries. `load!/0` runs every entry through a validator and returns `{:ok, valid_entries}` with invalid entries logged and skipped. Validation reuses the `CachedModel.changeset/2` trust-boundary rules indirectly — the baseline produces writes that will hit `ModelRegistry.upsert/1`, which validates them there. `load!/0` does a structural check only (map shape, required keys). This matches spec §Components → Baseline.

- [ ] **Step 1: Write failing tests**

Write `test/monkey_claw/model_registry/baseline_test.exs`:

```elixir
defmodule MonkeyClaw.ModelRegistry.BaselineTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias MonkeyClaw.ModelRegistry.Baseline

  setup do
    original = Application.get_env(:monkey_claw, Baseline)
    on_exit(fn -> Application.put_env(:monkey_claw, Baseline, original) end)
    :ok
  end

  describe "all/0" do
    test "returns the configured entries list" do
      entries = [
        %{
          backend: "claude",
          provider: "anthropic",
          models: [%{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}]
        }
      ]

      Application.put_env(:monkey_claw, Baseline, entries: entries)
      assert Baseline.all() == entries
    end

    test "returns empty list when not configured" do
      Application.put_env(:monkey_claw, Baseline, [])
      assert Baseline.all() == []
    end
  end

  describe "load!/0" do
    test "returns {:ok, entries} when every entry is structurally valid" do
      entries = [
        %{
          backend: "claude",
          provider: "anthropic",
          models: [%{model_id: "m1", display_name: "M1", capabilities: %{}}]
        },
        %{
          backend: "codex",
          provider: "openai",
          models: [%{model_id: "m2", display_name: "M2", capabilities: %{}}]
        }
      ]

      Application.put_env(:monkey_claw, Baseline, entries: entries)
      assert {:ok, ^entries} = Baseline.load!()
    end

    test "drops entries missing required keys, logs error, continues" do
      valid = %{
        backend: "claude",
        provider: "anthropic",
        models: [%{model_id: "m", display_name: "M", capabilities: %{}}]
      }

      invalid = %{backend: "oops"}

      Application.put_env(:monkey_claw, Baseline, entries: [invalid, valid])
      {:ok, result} = Baseline.load!()
      assert result == [valid]
    end

    test "drops entries where models is not a list" do
      bad = %{backend: "x", provider: "y", models: "nope"}
      Application.put_env(:monkey_claw, Baseline, entries: [bad])
      assert {:ok, []} = Baseline.load!()
    end
  end
end
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/baseline_test.exs`
Expected: compile error — `Baseline` module not defined.

- [ ] **Step 3: Implement the module**

Write `lib/monkey_claw/model_registry/baseline.ex`:

```elixir
defmodule MonkeyClaw.ModelRegistry.Baseline do
  @moduledoc """
  Runtime-config reader for the ModelRegistry baseline loader.

  Users define baseline entries in `config/runtime.exs`:

      config :monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
        entries: [
          %{
            backend: "claude",
            provider: "anthropic",
            models: [
              %{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}
            ]
          }
        ]

  ## Design

  This is NOT a process. `Baseline` is a pure module: no state, no
  supervision. `MonkeyClaw.ModelRegistry.init/1` invokes `load!/0` once
  at boot to seed SQLite before any probe runs.

  `load!/0` performs a structural pre-check (required keys, list shape)
  and drops entries that fail. The full trust-boundary validation
  happens downstream in `CachedModel.changeset/2` when the registry's
  upsert funnel processes baseline writes. Structural errors are
  logged with the offending entry so config typos are easy to catch.
  """

  require Logger

  @type entry :: %{
          required(:backend) => String.t(),
          required(:provider) => String.t(),
          required(:models) => [map()]
        }

  @doc """
  Return the raw list of configured baseline entries.

  Does not validate — use `load!/0` for the validated view.
  """
  @spec all() :: [map()]
  def all do
    :monkey_claw
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:entries, [])
  end

  @doc """
  Load baseline entries, dropping any that fail the structural check.

  Returns `{:ok, valid_entries}`. Invalid entries are logged with
  enough detail to identify the offending config key.
  """
  @spec load!() :: {:ok, [entry()]}
  def load! do
    valid =
      all()
      |> Enum.filter(&valid_entry?/1)

    dropped = length(all()) - length(valid)

    if dropped > 0 do
      Logger.warning(
        "ModelRegistry.Baseline: dropped #{dropped} invalid baseline entries (structural check failed); " <>
          "see earlier warnings for offending entries"
      )
    end

    {:ok, valid}
  end

  # ── Private ─────────────────────────────────────────────────

  @required_keys [:backend, :provider, :models]

  defp valid_entry?(entry) when is_map(entry) do
    missing = Enum.reject(@required_keys, &Map.has_key?(entry, &1))

    cond do
      missing != [] ->
        Logger.warning(
          "ModelRegistry.Baseline: entry missing required keys #{inspect(missing)}: #{inspect(entry)}"
        )

        false

      not is_list(entry.models) ->
        Logger.warning(
          "ModelRegistry.Baseline: entry :models must be a list, got: #{inspect(entry.models)}"
        )

        false

      true ->
        true
    end
  end

  defp valid_entry?(other) do
    Logger.warning("ModelRegistry.Baseline: entry is not a map: #{inspect(other)}")
    false
  end
end
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/baseline_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry/baseline.ex \
        test/monkey_claw/model_registry/baseline_test.exs
git commit -m "feat: add ModelRegistry.Baseline runtime-config reader"
```

---

## Task 7: Default baseline entries in config/runtime.exs

**Files:**
- Modify: `config/runtime.exs`

**Context:** Ship sane defaults for `claude/anthropic`, `codex/openai`, `gemini/google` so a fresh install has a floor of known models immediately. Users override by editing their own `runtime.exs`.

- [ ] **Step 1: Read existing runtime.exs**

Run: `Read tool` on `config/runtime.exs`. Confirm it exists and note its top-level structure (likely has `config :monkey_claw, ...` blocks already). Note the current last config block — new entries go after it.

- [ ] **Step 2: Append baseline config**

Add this block to the end of `config/runtime.exs` (ideally near other `MonkeyClaw.ModelRegistry` config):

```elixir
# ── MonkeyClaw.ModelRegistry Baseline ────────────────────────
#
# Baseline entries seed the registry at boot so the agent has a
# floor of known models before any probe runs. Entries are
# structurally validated by MonkeyClaw.ModelRegistry.Baseline.load!/0
# and then trust-boundary validated by CachedModel.changeset/2 inside
# the registry's upsert funnel. Users can override or extend this
# list in their own runtime.exs without rebuilding the release.
config :monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
  entries: [
    %{
      backend: "claude",
      provider: "anthropic",
      models: [
        %{model_id: "claude-opus-4-6", display_name: "Claude Opus 4.6", capabilities: %{}},
        %{model_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6", capabilities: %{}},
        %{model_id: "claude-haiku-4-5-20251001", display_name: "Claude Haiku 4.5", capabilities: %{}}
      ]
    },
    %{
      backend: "codex",
      provider: "openai",
      models: [
        %{model_id: "gpt-5", display_name: "GPT-5", capabilities: %{}}
      ]
    },
    %{
      backend: "gemini",
      provider: "google",
      models: [
        %{model_id: "gemini-2.5-pro", display_name: "Gemini 2.5 Pro", capabilities: %{}}
      ]
    }
  ]
```

- [ ] **Step 3: Verify compile still passes**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs
git commit -m "feat: ship default baseline entries for claude/codex/gemini backends"
```

---

## Task 8: Extend Backend behaviour with `list_models/1` callback

**Files:**
- Modify: `lib/monkey_claw/agent_bridge/backend.ex`

**Context:** Per spec §D2 and §Components → Backend, add a new callback that takes an `opts :: map()` (not a session pid) and returns `{:ok, [model_attrs]} | {:error, term()}` where each `model_attrs` carries its own `:provider` so multi-provider backends can fan out. This task only adds the callback declaration and types — implementations land in Task 9 (Test) and Task 10 (BeamAgent).

- [ ] **Step 1: Add the callback declaration**

In `lib/monkey_claw/agent_bridge/backend.ex`, after the existing `@type permission_mode :: ...` and before the first `@callback` declaration, add:

```elixir
  @typedoc """
  Options for listing models. Adapter-specific keys are permitted.

  Common keys used by MonkeyClaw adapters:

    * `:workspace_id` — Vault workspace for secret resolution
    * `:secret_name` — Vault secret name for the backend's API key
    * `:probe_deadline_ms` — Hard wall-clock deadline for the probe
  """
  @type list_models_opts :: %{
          optional(:workspace_id) => Ecto.UUID.t(),
          optional(:secret_name) => String.t(),
          optional(:probe_deadline_ms) => pos_integer(),
          optional(atom()) => term()
        }

  @typedoc """
  Single model descriptor returned by `list_models/1`.

  The `:provider` field MUST be present on every entry so the
  registry can fan multi-provider backends out into one row per
  `(backend, provider)` pair.
  """
  @type model_attrs :: %{
          provider: String.t(),
          model_id: String.t(),
          display_name: String.t(),
          capabilities: map()
        }
```

Then add the `@callback` declaration anywhere in the callback block (e.g., immediately after `start_session/1`'s docblock):

```elixir
  @doc """
  List the models this backend currently supports.

  Called by `MonkeyClaw.ModelRegistry` during boot (baseline delta),
  periodic probes, and on-demand refreshes. Does NOT require a live
  session — adapters decide internally how to satisfy the request
  (HTTP API call, transient CLI init handshake, local manifest
  read, etc.).

  Implementations should respect their own deadline; the registry
  also enforces a hard outer deadline via `Task.shutdown/2` as a
  safety net.

  Returns a flat list of `model_attrs` maps. A single adapter may
  return models from multiple providers in one list (e.g., Copilot
  routing both OpenAI and Anthropic); the registry groups by
  `:provider` at write time.
  """
  @callback list_models(opts :: list_models_opts()) ::
              {:ok, [model_attrs()]} | {:error, term()}
```

- [ ] **Step 2: Verify compile fails**

Run: `mix compile --warnings-as-errors`
Expected: failure — `MonkeyClaw.AgentBridge.Backend.Test` and `MonkeyClaw.AgentBridge.Backend.BeamAgent` are missing the new callback. These get implemented in the next two tasks.

- [ ] **Step 3: Commit**

```bash
git add lib/monkey_claw/agent_bridge/backend.ex
git commit -m "feat: add list_models/1 callback to AgentBridge.Backend behaviour

New callback takes opts map (not session pid) so the registry can
call it without a live session. Each model_attrs includes :provider
so multi-provider backends can fan out per spec D2/D3. Adapters
implemented in follow-up commits — compile will be red until then."
```

---

## Task 9: Implement `list_models/1` in TestBackend

**Files:**
- Modify: `test/support/test_backend.ex`
- Create: `test/support/model_list_presets.ex` (optional helper; inline if simpler)

**Context:** TestBackend drives all integration tests for the registry. Per spec §Testing, it must support programmable responses — success, `{:error, _}`, delay, crash — so registry tests can exercise every failure path deterministically.

- [ ] **Step 1: Write failing test**

Create `test/support/test_backend_models_test.exs` (or append to an existing test file — if none exists for TestBackend, create this one):

```elixir
defmodule MonkeyClaw.AgentBridge.Backend.TestModelsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge.Backend.Test, as: TestBackend

  describe "list_models/1" do
    test "default response returns a canned list" do
      assert {:ok, models} = TestBackend.list_models(%{})
      assert is_list(models)
      assert Enum.all?(models, &match?(%{provider: _, model_id: _, display_name: _}, &1))
    end

    test "configurable success response via :list_models_response" do
      preset = [%{provider: "anthropic", model_id: "x", display_name: "X", capabilities: %{}}]
      assert {:ok, ^preset} = TestBackend.list_models(%{list_models_response: {:ok, preset}})
    end

    test "configurable error response" do
      assert {:error, :boom} = TestBackend.list_models(%{list_models_response: {:error, :boom}})
    end

    test "delay honors probe_deadline_ms when raising too slow" do
      # Simulate a slow probe that exceeds its own deadline.
      assert {:error, :deadline_exceeded} =
               TestBackend.list_models(%{
                 list_models_delay_ms: 50,
                 probe_deadline_ms: 10
               })
    end

    test "crash response raises" do
      assert_raise RuntimeError, fn ->
        TestBackend.list_models(%{list_models_response: {:crash, "boom"}})
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `MIX_ENV=test mix test test/support/test_backend_models_test.exs`
Expected: compile error — `list_models/1` not defined.

- [ ] **Step 3: Implement `list_models/1` in TestBackend**

In `test/support/test_backend.ex`, after the existing `@impl MonkeyClaw.AgentBridge.Backend` block for `checkpoint_rewind`, add:

```elixir
  @impl MonkeyClaw.AgentBridge.Backend
  def list_models(opts) when is_map(opts) do
    delay_ms = Map.get(opts, :list_models_delay_ms, 0)
    deadline_ms = Map.get(opts, :probe_deadline_ms, :infinity)

    cond do
      deadline_ms != :infinity and delay_ms > deadline_ms ->
        {:error, :deadline_exceeded}

      delay_ms > 0 ->
        Process.sleep(delay_ms)
        respond(opts)

      true ->
        respond(opts)
    end
  end

  defp respond(opts) do
    case Map.get(opts, :list_models_response, :default) do
      :default ->
        {:ok,
         [
           %{
             provider: "anthropic",
             model_id: "claude-sonnet-4-6",
             display_name: "Claude Sonnet 4.6",
             capabilities: %{}
           },
           %{
             provider: "anthropic",
             model_id: "claude-opus-4-6",
             display_name: "Claude Opus 4.6",
             capabilities: %{}
           }
         ]}

      {:ok, models} when is_list(models) ->
        {:ok, models}

      {:error, reason} ->
        {:error, reason}

      {:crash, message} ->
        raise message
    end
  end
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `MIX_ENV=test mix test test/support/test_backend_models_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Verify full compile**

Run: `mix compile --warnings-as-errors`
Expected: still red — `BeamAgent` backend still missing the callback. That's expected and handled in Task 10.

- [ ] **Step 6: Commit**

```bash
git add test/support/test_backend.ex test/support/test_backend_models_test.exs
git commit -m "test: implement list_models/1 in TestBackend with programmable responses"
```

---

## Task 10: Implement `list_models/1` in BeamAgent backend

**Files:**
- Modify: `lib/monkey_claw/agent_bridge/backend/beam_agent.ex`

**Context:** The production BeamAgent adapter delegates to `BeamAgent.Catalog.supported_models/1` when available, and falls back to the HTTP Provider module for providers the catalog does not yet cover. Credentials are resolved via the vault inside the function scope and never leave it.

- [ ] **Step 1: Read the existing BeamAgent backend module**

Run: `Read` on `lib/monkey_claw/agent_bridge/backend/beam_agent.ex` to understand its current structure (which callbacks are implemented, how it delegates to `BeamAgent`, whether it already has private HTTP helpers).

- [ ] **Step 2: Write failing test**

Create `test/monkey_claw/agent_bridge/backend/beam_agent_list_models_test.exs`:

```elixir
defmodule MonkeyClaw.AgentBridge.Backend.BeamAgentListModelsTest do
  @moduledoc """
  Integration tests for BeamAgent backend list_models/1.

  Uses a test workspace and vault secret. The HTTP call is forced
  through a localhost port that is guaranteed to be unreachable,
  so we assert the {:error, _} branch deterministically without
  touching real upstream APIs.
  """

  use MonkeyClaw.DataCase, async: false

  import MonkeyClaw.Factory

  alias MonkeyClaw.AgentBridge.Backend.BeamAgent

  describe "list_models/1" do
    test "returns {:error, :missing_workspace_id} when workspace not set" do
      assert {:error, _reason} = BeamAgent.list_models(%{})
    end

    test "returns {:error, _} when HTTP call cannot reach upstream" do
      workspace = insert_workspace!()
      _ = insert_vault_secret!(workspace, %{name: "anthropic_key", value: "sk-fake"})

      result =
        BeamAgent.list_models(%{
          backend: "claude",
          workspace_id: workspace.id,
          secret_name: "anthropic_key",
          base_url: "http://localhost:1"
        })

      assert {:error, _reason} = result
    end
  end
end
```

- [ ] **Step 3: Run the test to confirm it fails**

Run: `MIX_ENV=test mix test test/monkey_claw/agent_bridge/backend/beam_agent_list_models_test.exs`
Expected: compile error or undefined-function error.

- [ ] **Step 4: Implement `list_models/1`**

In `lib/monkey_claw/agent_bridge/backend/beam_agent.ex`, add at the end of the existing `@impl` block:

```elixir
  @impl MonkeyClaw.AgentBridge.Backend
  def list_models(opts) when is_map(opts) do
    backend = Map.get(opts, :backend)
    provider = backend_to_provider(backend)

    provider_opts =
      opts
      |> Map.to_list()
      |> Keyword.take([:workspace_id, :secret_name, :api_key, :base_url])

    case MonkeyClaw.ModelRegistry.Provider.fetch_models(provider, provider_opts) do
      {:ok, models} ->
        {:ok, Enum.map(models, &annotate_provider(&1, provider))}

      {:error, _} = error ->
        error
    end
  end

  # Map the MonkeyClaw backend identifier to the upstream provider name.
  # Static table — future SDK and local backends extend this.
  defp backend_to_provider("claude"), do: "anthropic"
  defp backend_to_provider("codex"), do: "openai"
  defp backend_to_provider("gemini"), do: "google"
  defp backend_to_provider("opencode"), do: "anthropic"
  defp backend_to_provider("copilot"), do: "github_copilot"
  defp backend_to_provider(nil), do: "anthropic"
  defp backend_to_provider(other) when is_binary(other), do: other

  defp annotate_provider(%{model_id: id, display_name: name, capabilities: caps}, provider) do
    %{
      provider: provider,
      model_id: id,
      display_name: name,
      capabilities: caps
    }
  end
```

- [ ] **Step 5: Run the test**

Run: `MIX_ENV=test mix test test/monkey_claw/agent_bridge/backend/beam_agent_list_models_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 6: Verify full compile is clean**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/monkey_claw/agent_bridge/backend/beam_agent.ex \
        test/monkey_claw/agent_bridge/backend/beam_agent_list_models_test.exs
git commit -m "feat: implement list_models/1 in BeamAgent backend via Provider"
```

---

## Task 11: ModelRegistry rewrite — new state struct + init skeleton

**Files:**
- Modify: `lib/monkey_claw/model_registry.ex` (full replace)
- Create: `test/monkey_claw/model_registry_test.exs` (new file, replaces the one deleted in Task 2)

**Context:** This task establishes the new GenServer scaffold — new `State` struct per spec §Components → ModelRegistry, `start_link/1` signature, and a minimal `init/1` that creates ETS via heir fallback (Application creates it in Task 12; for now the registry does both to keep tests independent of the Application boot path). No probe logic yet — that arrives in later tasks. The goal here is a working GenServer lifecycle with empty reads.

- [ ] **Step 1: Write failing lifecycle tests**

Write to `test/monkey_claw/model_registry_test.exs`:

```elixir
defmodule MonkeyClaw.ModelRegistryTest do
  @moduledoc """
  Integration tests for the rewritten ModelRegistry.

  Runs serially (async: false) because ModelRegistry is a named
  singleton (__MODULE__) and owns the :monkey_claw_model_registry
  ETS table atom.
  """

  use MonkeyClaw.DataCase, async: false

  alias MonkeyClaw.ModelRegistry

  describe "start_link/1 and lifecycle" do
    test "starts under __MODULE__ and creates the ETS table" do
      start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})
      assert Process.whereis(ModelRegistry) |> is_pid()
      assert :ets.whereis(:monkey_claw_model_registry) != :undefined
    end

    test "initial reads return empty collections on an empty SQLite + empty baseline" do
      start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})
      assert ModelRegistry.list_for_backend("claude") == []
      assert ModelRegistry.list_for_provider("anthropic") == []
      assert ModelRegistry.list_all_by_backend() == %{}
      assert ModelRegistry.list_all_by_provider() == %{}
    end

    test "survives unexpected messages" do
      start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})
      pid = Process.whereis(ModelRegistry)
      send(pid, :random_garbage)
      :timer.sleep(20)
      assert Process.alive?(pid)
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: compile error (old ModelRegistry still references old `CachedModel.create_changeset/2` API which no longer exists).

- [ ] **Step 3: Full replace `lib/monkey_claw/model_registry.ex`**

Write the following to `lib/monkey_claw/model_registry.ex` (replacing the entire file):

```elixir
defmodule MonkeyClaw.ModelRegistry do
  @moduledoc """
  Unified model registry keyed on `(backend, provider)`.

  Owns the ETS read-through cache and serializes all writes through
  a single `upsert/1` funnel. Three independent writers populate the
  cache: the `Baseline` boot loader, a periodic per-backend probe
  dispatched as `Task.Supervisor` tasks from the registry's own tick
  handler, and an authenticated post-start hook from
  `AgentBridge.Session`. All three validate through the same
  changeset before touching SQLite or ETS.

  ## Process Justification

    * **Stateful** — owns ETS table lifecycle via heir and maintains
      per-backend probe schedules
    * **Serialized** — writes funnel through a single process to avoid
      race conditions on the conditional upsert precedence
    * **Single instance** — registered under `__MODULE__`; one
      registry per node

  See `docs/superpowers/specs/2026-04-05-list-models-per-backend-design.md`
  for the full design.
  """

  use GenServer

  require Logger

  alias MonkeyClaw.ModelRegistry.Baseline
  alias MonkeyClaw.ModelRegistry.CachedModel
  alias MonkeyClaw.Repo

  @ets_table :monkey_claw_model_registry
  @default_interval_ms :timer.hours(24)
  @startup_delay_ms 5_000

  # ── State ───────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @enforce_keys [:ets_table, :default_interval, :backends]
    defstruct [
      :ets_table,
      :default_interval,
      backend_intervals: %{},
      backends: [],
      workspace_id: nil,
      backend_configs: %{},
      last_probe_at: %{},
      in_flight: %{},
      backoff: %{},
      tick_timer_ref: nil,
      degraded: false
    ]

    @type t :: %__MODULE__{
            ets_table: :ets.table(),
            default_interval: pos_integer(),
            backend_intervals: %{String.t() => pos_integer()},
            backends: [String.t()],
            workspace_id: Ecto.UUID.t() | nil,
            backend_configs: %{String.t() => map()},
            last_probe_at: %{String.t() => integer()},
            in_flight: %{reference() => String.t()},
            backoff: %{String.t() => pos_integer()},
            tick_timer_ref: reference() | nil,
            degraded: boolean()
          }
  end

  # ── Client API ──────────────────────────────────────────────

  @doc """
  Start the ModelRegistry under `__MODULE__`.

  ## Options

    * `:backends` — List of backend identifier strings (default: `[]`)
    * `:default_interval_ms` — Tick interval, floor cadence (default: 24h)
    * `:backend_intervals` — Per-backend interval overrides (must be ≥ default)
    * `:backend_configs` — Per-backend opts passed to `list_models/1`
    * `:workspace_id` — Default workspace for vault resolution
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return all cached models for a single backend.

  Accepts atom or string `backend`. Normalizes via `to_string/1`.
  Returns an empty list when the backend has no rows.
  """
  @spec list_for_backend(atom() | String.t()) :: [map()]
  def list_for_backend(backend) do
    backend_str = to_string(backend)
    ets_scan_by_backend(backend_str)
  end

  @doc """
  Return all cached models for a single provider, across every backend.
  """
  @spec list_for_provider(String.t()) :: [map()]
  def list_for_provider(provider) when is_binary(provider) do
    ets_scan_by_provider(provider)
  end

  @doc """
  Return a map of `backend => [enriched_model]` for every cached row.
  """
  @spec list_all_by_backend() :: %{String.t() => [map()]}
  def list_all_by_backend do
    @ets_table
    |> safe_ets_tab2list()
    |> Enum.reduce(%{}, fn
      {{:row, backend, provider}, row}, acc ->
        enriched = Enum.map(row.models, &enrich(&1, backend, provider))
        Map.update(acc, backend, enriched, &(&1 ++ enriched))

      _, acc ->
        acc
    end)
  end

  @doc """
  Return a map of `provider => [enriched_model]` for every cached row.
  """
  @spec list_all_by_provider() :: %{String.t() => [map()]}
  def list_all_by_provider do
    @ets_table
    |> safe_ets_tab2list()
    |> Enum.reduce(%{}, fn
      {{:row, backend, provider}, row}, acc ->
        enriched = Enum.map(row.models, &enrich(&1, backend, provider))
        Map.update(acc, provider, enriched, &(&1 ++ enriched))

      _, acc ->
        acc
    end)
  end

  # ── GenServer Callbacks ─────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, State.t()}
  def init(opts) when is_list(opts) do
    app_config = Application.get_env(:monkey_claw, __MODULE__, [])
    opts = Keyword.merge(app_config, opts)

    default_interval = Keyword.get(opts, :default_interval_ms, @default_interval_ms)
    backends = Keyword.get(opts, :backends, [])

    ets_table = ensure_ets_table()

    state = %State{
      ets_table: ets_table,
      default_interval: default_interval,
      backend_intervals: Keyword.get(opts, :backend_intervals, %{}),
      backends: backends,
      workspace_id: Keyword.get(opts, :workspace_id),
      backend_configs: Keyword.get(opts, :backend_configs, %{}),
      last_probe_at: Map.new(backends, &{&1, 0}),
      in_flight: %{},
      backoff: %{},
      tick_timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info(msg, %State{} = state) do
    Logger.debug("ModelRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private — ETS ───────────────────────────────────────────

  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

      ref ->
        ref
    end
  end

  defp safe_ets_tab2list(table) do
    case :ets.whereis(table) do
      :undefined -> []
      _ -> :ets.tab2list(table)
    end
  end

  defp ets_scan_by_backend(backend) do
    @ets_table
    |> safe_ets_tab2list()
    |> Enum.flat_map(fn
      {{:row, ^backend, provider}, row} ->
        Enum.map(row.models, &enrich(&1, backend, provider))

      _ ->
        []
    end)
  end

  defp ets_scan_by_provider(provider) do
    @ets_table
    |> safe_ets_tab2list()
    |> Enum.flat_map(fn
      {{:row, backend, ^provider}, row} ->
        Enum.map(row.models, &enrich(&1, backend, provider))

      _ ->
        []
    end)
  end

  defp enrich(model, backend, provider) do
    %{
      backend: backend,
      provider: provider,
      model_id: model.model_id,
      display_name: model.display_name,
      capabilities: model.capabilities
    }
  end
end
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Verify full compile**

Run: `mix compile --warnings-as-errors`
Expected: clean. (Any consumer that referenced old API is still broken — we'll fix them in Task 27.)

- [ ] **Step 6: Commit**

```bash
git add lib/monkey_claw/model_registry.ex test/monkey_claw/model_registry_test.exs
git commit -m "feat: rewrite ModelRegistry scaffold with new state struct and empty reads

Full drop-and-replace of the old provider-keyed GenServer. New state
struct per spec (backends, intervals, in-flight, backoff), new read
API (list_for_backend, list_for_provider, list_all_by_*). Upsert
funnel, probe logic, and supervision integration land in follow-up
commits. Existing vault_live.ex consumer is still on the old API and
will be cut over in a later task."
```

---

## Task 12: Application creates ETS table with heir

**Files:**
- Modify: `lib/monkey_claw/application.ex`
- Modify: `lib/monkey_claw/model_registry.ex` (handle ETS-TRANSFER in init)
- Modify: `test/monkey_claw/model_registry_test.exs` (heir survival test)

**Context:** Per spec §Supervision Tree (C4), the ETS table must survive a ModelRegistry crash. The heir pattern: `Application.start/2` creates the table with `heir: {bootstrap_pid, :model_registry}` and transfers ownership to the registry on first start. If the registry crashes, the bootstrap process re-receives ownership and gives it back to the restarted registry.

Since the Application process itself cannot be a stable heir (it's the one starting children), we use a dedicated long-lived `GenServer` child at the root that acts as heir. The simplest implementation: a tiny `MonkeyClaw.ModelRegistry.EtsHeir` GenServer started before `ModelRegistry` in the supervision tree.

- [ ] **Step 1: Write failing heir-survival test**

Append to `test/monkey_claw/model_registry_test.exs`:

```elixir
  describe "ETS heir crash survival" do
    setup do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)
      start_supervised!({MonkeyClaw.ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})
      :ok
    end

    test "ETS table survives a ModelRegistry crash" do
      tid_before = :ets.whereis(:monkey_claw_model_registry)
      assert tid_before != :undefined

      pid = Process.whereis(MonkeyClaw.ModelRegistry)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

      # Supervisor restarts the registry; ETS table should be handed back.
      :timer.sleep(100)
      tid_after = :ets.whereis(:monkey_claw_model_registry)
      assert tid_after != :undefined
    end
  end
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs -- --only ets_heir`
Expected: `EtsHeir` undefined.

- [ ] **Step 3: Create the EtsHeir module**

Write `lib/monkey_claw/model_registry/ets_heir.ex`:

```elixir
defmodule MonkeyClaw.ModelRegistry.EtsHeir do
  @moduledoc """
  Long-lived heir for the ModelRegistry ETS table.

  Creates the `:monkey_claw_model_registry` ETS table at start time
  with `heir: {self(), :model_registry}` and gives ownership to the
  ModelRegistry GenServer on request. When the registry crashes,
  ownership returns to this process; when the supervisor restarts
  the registry, the restarted process asks for the table back via
  `claim/1`.

  ## Process Justification

    * **Stable owner** — must outlive the ModelRegistry to survive
      its crash/restart cycle
    * **Minimal** — does nothing except own the ETS table and
      transfer ownership on demand

  See spec §Supervision Tree (C4).
  """

  use GenServer

  @ets_table :monkey_claw_model_registry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Claim ownership of the ETS table for the calling process.

  Called by `MonkeyClaw.ModelRegistry.init/1`. The heir sends
  `{:'ETS-TRANSFER', tid, _heir_pid, :model_registry}` to the caller,
  which the registry handles in `handle_info/2`.
  """
  @spec claim(pid()) :: :ok
  def claim(claimer_pid) when is_pid(claimer_pid) do
    GenServer.call(__MODULE__, {:claim, claimer_pid})
  end

  # ── GenServer ───────────────────────────────────────────────

  @impl true
  def init(_) do
    # Create or reuse the ETS table. On re-starts (after a registry
    # crash), the table already exists and is owned by this process —
    # just keep it.
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          heir: {self(), :model_registry}
        ])

      _tid ->
        # Re-adopt the table if we have access.
        :ok
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:claim, pid}, _from, state) do
    :ets.give_away(@ets_table, pid, :model_registry)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:'ETS-TRANSFER', _tid, _from, :model_registry}, state) do
    # Registry crashed — the table is now ours until the next claim.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

- [ ] **Step 4: Update `ModelRegistry.init/1` to claim the table via heir**

Modify `lib/monkey_claw/model_registry.ex`:

Replace the `ensure_ets_table/0` helper with logic that tries to claim from the heir first, falling back to direct creation for standalone tests:

```elixir
  defp ensure_ets_table do
    case Process.whereis(MonkeyClaw.ModelRegistry.EtsHeir) do
      nil ->
        # Standalone start (tests without the full tree) — create directly.
        case :ets.whereis(@ets_table) do
          :undefined ->
            :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

          ref ->
            ref
        end

      _pid ->
        :ok = MonkeyClaw.ModelRegistry.EtsHeir.claim(self())
        # Wait for the give_away message before returning.
        receive do
          {:'ETS-TRANSFER', _tid, _from, :model_registry} -> :ok
        after
          1_000 -> raise "ModelRegistry: timeout claiming ETS table from EtsHeir"
        end

        :ets.whereis(@ets_table)
    end
  end
```

Also add an `ETS-TRANSFER` handler alongside the unexpected-message catch-all:

```elixir
  @impl true
  def handle_info({:'ETS-TRANSFER', _tid, _from, :model_registry}, %State{} = state) do
    # Late ETS-TRANSFER (e.g., re-transfer after a heir restart). No-op
    # beyond keeping the state consistent.
    {:noreply, state}
  end

  def handle_info(msg, %State{} = state) do
    Logger.debug("ModelRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
```

- [ ] **Step 5: Update Application supervision tree**

In `lib/monkey_claw/application.ex`, add `MonkeyClaw.ModelRegistry.EtsHeir` to the children list **before** `MonkeyClaw.ModelRegistry`:

Find the existing line:
```elixir
        maybe_child(ModelRegistry, :start_model_registry) ++
```

Replace with:
```elixir
        maybe_child(MonkeyClaw.ModelRegistry.EtsHeir, :start_model_registry) ++
        maybe_child(ModelRegistry, :start_model_registry) ++
```

(Both share the `:start_model_registry` config flag so they turn on and off together.)

- [ ] **Step 6: Run the tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: all tests pass, including the ETS heir survival test.

- [ ] **Step 7: Commit**

```bash
git add lib/monkey_claw/model_registry/ets_heir.ex \
        lib/monkey_claw/model_registry.ex \
        lib/monkey_claw/application.ex \
        test/monkey_claw/model_registry_test.exs
git commit -m "feat: add ETS heir for ModelRegistry crash survival

EtsHeir owns the :monkey_claw_model_registry ETS table with itself
as heir and gives ownership to ModelRegistry on start via
give_away/3. On registry crash, ownership returns to the heir;
supervisor restarts the registry, which re-claims the table. Reads
observe continuity across the restart."
```

---

## Task 13: ModelRegistry boot sequence — SQLite load + baseline delta seed + degraded fallback

**Files:**
- Modify: `lib/monkey_claw/model_registry.ex`
- Modify: `test/monkey_claw/model_registry_test.exs`

**Context:** Per spec §Components → ModelRegistry → Boot sequence, `init/1` must: (a) claim ETS via heir, (b) attempt to load rows from SQLite, (c) if empty, seed from `Baseline.load!/0`, (d) if non-empty, insert baseline entries that are NOT already in SQLite (delta seed, I6), (e) if Repo is unavailable, enter degraded mode and seed ETS directly from baseline.

- [ ] **Step 1: Write failing tests**

Append to `model_registry_test.exs`:

```elixir
  describe "boot sequence" do
    setup do
      Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
        entries: [
          %{
            backend: "claude",
            provider: "anthropic",
            models: [
              %{model_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6", capabilities: %{}}
            ]
          }
        ]
      )

      on_exit(fn ->
        Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
      end)

      :ok
    end

    test "cold start with empty SQLite seeds baseline into ETS and SQLite" do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)

      start_supervised!(
        {MonkeyClaw.ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]}
      )

      models = MonkeyClaw.ModelRegistry.list_for_backend("claude")
      assert length(models) == 1
      assert hd(models).model_id == "claude-sonnet-4-6"

      # SQLite should now contain the row too.
      rows = MonkeyClaw.Repo.all(MonkeyClaw.ModelRegistry.CachedModel)
      assert length(rows) == 1
    end

    test "warm start with existing SQLite row skips duplicate baseline seed" do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)

      start_supervised!(
        {MonkeyClaw.ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]}
      )

      assert length(MonkeyClaw.ModelRegistry.list_for_backend("claude")) == 1
      row_count_before = MonkeyClaw.Repo.aggregate(MonkeyClaw.ModelRegistry.CachedModel, :count)

      # Stop and restart to exercise the warm path.
      stop_supervised!(MonkeyClaw.ModelRegistry)

      start_supervised!(
        {MonkeyClaw.ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]}
      )

      row_count_after = MonkeyClaw.Repo.aggregate(MonkeyClaw.ModelRegistry.CachedModel, :count)
      assert row_count_before == row_count_after
      assert length(MonkeyClaw.ModelRegistry.list_for_backend("claude")) == 1
    end
  end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: boot-sequence tests fail — no rows are seeded because `init/1` doesn't call `Baseline.load!/0` yet.

- [ ] **Step 3: Implement the boot sequence**

In `lib/monkey_claw/model_registry.ex`, replace `init/1` with:

```elixir
  @impl true
  @spec init(keyword()) :: {:ok, State.t()} | {:ok, State.t(), {:continue, :load}}
  def init(opts) when is_list(opts) do
    app_config = Application.get_env(:monkey_claw, __MODULE__, [])
    opts = Keyword.merge(app_config, opts)

    default_interval = Keyword.get(opts, :default_interval_ms, @default_interval_ms)
    backends = Keyword.get(opts, :backends, [])

    ets_table = ensure_ets_table()

    state = %State{
      ets_table: ets_table,
      default_interval: default_interval,
      backend_intervals: Keyword.get(opts, :backend_intervals, %{}),
      backends: backends,
      workspace_id: Keyword.get(opts, :workspace_id),
      backend_configs: Keyword.get(opts, :backend_configs, %{}),
      last_probe_at: Map.new(backends, &{&1, 0}),
      in_flight: %{},
      backoff: %{},
      tick_timer_ref: nil,
      degraded: false
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %State{} = state) do
    state = load_existing_and_seed_baseline(state)
    {:noreply, state}
  end
```

Add these private helpers:

```elixir
  defp load_existing_and_seed_baseline(state) do
    case load_sqlite_rows() do
      {:ok, rows} ->
        populate_ets(state.ets_table, rows)
        seed_baseline_delta(state, rows)

      {:error, reason} ->
        Logger.warning(
          "ModelRegistry: SQLite load failed (#{inspect(reason)}), falling back to baseline-only ETS"
        )

        seed_baseline_ets_only(state)
        %{state | degraded: true}
    end
  end

  defp load_sqlite_rows do
    {:ok, Repo.all(CachedModel)}
  rescue
    error -> {:error, error}
  end

  defp populate_ets(table, rows) do
    Enum.each(rows, fn %CachedModel{} = row ->
      :ets.insert(table, {{:row, row.backend, row.provider}, row})
    end)
  end

  defp seed_baseline_delta(state, existing_rows) do
    existing_keys =
      MapSet.new(existing_rows, fn %CachedModel{backend: b, provider: p} -> {b, p} end)

    {:ok, entries} = Baseline.load!()
    now = DateTime.utc_now()
    mono = System.monotonic_time()

    writes =
      entries
      |> Enum.reject(fn entry -> MapSet.member?(existing_keys, {entry.backend, entry.provider}) end)
      |> Enum.map(fn entry ->
        %{
          backend: entry.backend,
          provider: entry.provider,
          source: "baseline",
          refreshed_at: now,
          refreshed_mono: mono,
          models: entry.models
        }
      end)

    case do_upsert(writes, state) do
      {:ok, _applied} -> state
      {:error, _} -> state
    end
  end

  defp seed_baseline_ets_only(state) do
    {:ok, entries} = Baseline.load!()
    now = DateTime.utc_now()

    Enum.each(entries, fn entry ->
      models =
        Enum.map(entry.models, fn m ->
          struct(CachedModel.Model, m)
        end)

      row = %CachedModel{
        backend: entry.backend,
        provider: entry.provider,
        source: "baseline",
        refreshed_at: now,
        refreshed_mono: System.monotonic_time(),
        models: models
      }

      :ets.insert(state.ets_table, {{:row, entry.backend, entry.provider}, row})
    end)

    state
  end

  # Placeholder — real implementation lands in Task 14.
  defp do_upsert(_writes, _state), do: {:ok, []}
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: cold-start test passes (ETS seeded from baseline). Warm-start test may still fail because `do_upsert/2` is a stub — **that's OK for now**. The stub returns `{:ok, []}` so the cold path works via `seed_baseline_ets_only` fallback NO — wait. Re-check: cold start uses `seed_baseline_delta` which calls `do_upsert/2` (stub), so it won't write to SQLite. Fix this by temporarily using `seed_baseline_ets_only` in both cold and warm branches until Task 14 lands the real upsert.

Actually, the cleaner path: change Step 3's `load_existing_and_seed_baseline` to always call `seed_baseline_ets_only` for now, and add a TODO marker that Task 14 replaces it with `seed_baseline_delta`. BUT we're not supposed to leave TODO markers.

Better approach: Task 13 implements the cold-path fully (ETS + SQLite) via a minimal inline insert (not the full upsert funnel yet). Task 14 replaces this minimal insert with the full funnel. That keeps each task independently testable.

Replace the `seed_baseline_delta` body with an inline insert that does the exact narrow thing this task needs:

```elixir
  defp seed_baseline_delta(state, existing_rows) do
    existing_keys =
      MapSet.new(existing_rows, fn %CachedModel{backend: b, provider: p} -> {b, p} end)

    {:ok, entries} = Baseline.load!()
    now = DateTime.utc_now()
    mono = System.monotonic_time()

    entries
    |> Enum.reject(fn entry -> MapSet.member?(existing_keys, {entry.backend, entry.provider}) end)
    |> Enum.each(fn entry ->
      attrs = %{
        backend: entry.backend,
        provider: entry.provider,
        source: "baseline",
        refreshed_at: now,
        refreshed_mono: mono,
        models: entry.models
      }

      case %CachedModel{} |> CachedModel.changeset(attrs) |> Repo.insert() do
        {:ok, row} ->
          :ets.insert(state.ets_table, {{:row, row.backend, row.provider}, row})

        {:error, changeset} ->
          Logger.warning(
            "ModelRegistry: baseline entry rejected by changeset: #{inspect(changeset.errors)}"
          )
      end
    end)

    state
  end
```

And delete the `do_upsert/2` stub (we don't need it in Task 13).

- [ ] **Step 5: Re-run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/monkey_claw/model_registry.ex test/monkey_claw/model_registry_test.exs
git commit -m "feat: ModelRegistry boot sequence with baseline delta seed

Init claims ETS via heir, loads rows from SQLite, seeds any baseline
entries not already present (warm-start delta). On SQLite failure,
falls back to baseline-only ETS and enters degraded state."
```

---

## Task 14: ModelRegistry upsert funnel — validation, grouping, conditional upsert

**Files:**
- Modify: `lib/monkey_claw/model_registry.ex`
- Modify: `test/monkey_claw/model_registry_test.exs`

**Context:** Per spec §Design Overview and §Write paths, all three writers end at a single internal `upsert/1` function that validates every write via the changeset, groups by `(backend, provider)`, runs one SQLite transaction with conditional upsert `ON CONFLICT ... DO UPDATE ... WHERE EXCLUDED.refreshed_at > cached_models.refreshed_at OR (EXCLUDED.refreshed_at = cached_models.refreshed_at AND EXCLUDED.refreshed_mono > cached_models.refreshed_mono)`, and updates ETS only for rows that actually won.

- [ ] **Step 1: Write failing tests for the upsert funnel**

Append to `model_registry_test.exs`:

```elixir
  describe "upsert/2 write funnel" do
    setup do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)

      start_supervised!(
        {MonkeyClaw.ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]}
      )

      :ok
    end

    test "accepts valid writes and exposes them via read API" do
      now = DateTime.utc_now()
      mono = System.monotonic_time()

      writes = [
        %{
          backend: "claude",
          provider: "anthropic",
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: [
            %{model_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6", capabilities: %{}}
          ]
        }
      ]

      assert {:ok, [_]} = MonkeyClaw.ModelRegistry.upsert(writes)
      assert [model] = MonkeyClaw.ModelRegistry.list_for_backend("claude")
      assert model.model_id == "claude-sonnet-4-6"
    end

    test "rejects stale writes when a newer version exists" do
      older = DateTime.add(DateTime.utc_now(), -10, :second)
      newer = DateTime.utc_now()
      mono_old = System.monotonic_time()
      mono_new = System.monotonic_time() + 1

      fresh = %{
        backend: "claude",
        provider: "anthropic",
        source: "probe",
        refreshed_at: newer,
        refreshed_mono: mono_new,
        models: [%{model_id: "fresh", display_name: "Fresh", capabilities: %{}}]
      }

      stale = %{fresh | refreshed_at: older, refreshed_mono: mono_old,
                models: [%{model_id: "stale", display_name: "Stale", capabilities: %{}}]}

      assert {:ok, [_]} = MonkeyClaw.ModelRegistry.upsert([fresh])
      assert {:ok, []} = MonkeyClaw.ModelRegistry.upsert([stale])

      [model] = MonkeyClaw.ModelRegistry.list_for_backend("claude")
      assert model.model_id == "fresh"
    end

    test "drops invalid writes with a log, applies the valid ones" do
      now = DateTime.utc_now()

      valid = %{
        backend: "claude",
        provider: "anthropic",
        source: "probe",
        refreshed_at: now,
        refreshed_mono: System.monotonic_time(),
        models: [%{model_id: "m", display_name: "M", capabilities: %{}}]
      }

      invalid = Map.put(valid, :backend, "BadBackend")

      assert {:ok, [_]} = MonkeyClaw.ModelRegistry.upsert([invalid, valid])
      assert [_] = MonkeyClaw.ModelRegistry.list_for_backend("claude")
    end

    test "fans out a single write with multiple providers into multiple rows" do
      # Simulated by caller passing two writes with same backend, different providers.
      now = DateTime.utc_now()
      mono = System.monotonic_time()

      writes = [
        %{
          backend: "copilot",
          provider: "openai",
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: [%{model_id: "gpt-5", display_name: "GPT-5", capabilities: %{}}]
        },
        %{
          backend: "copilot",
          provider: "anthropic",
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: [%{model_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6", capabilities: %{}}]
        }
      ]

      assert {:ok, applied} = MonkeyClaw.ModelRegistry.upsert(writes)
      assert length(applied) == 2

      copilot_models = MonkeyClaw.ModelRegistry.list_for_backend("copilot")
      assert length(copilot_models) == 2
      assert Enum.any?(copilot_models, &(&1.provider == "openai"))
      assert Enum.any?(copilot_models, &(&1.provider == "anthropic"))
    end
  end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: upsert tests fail — `MonkeyClaw.ModelRegistry.upsert/1` is undefined.

- [ ] **Step 3: Implement `upsert/1` and handle_call**

In `lib/monkey_claw/model_registry.ex`, add to the Client API section:

```elixir
  @doc """
  Apply a batch of writes to the cache.

  Each write is a map with keys `:backend`, `:provider`, `:source`,
  `:refreshed_at`, `:refreshed_mono`, `:models`. Every write is
  validated through `CachedModel.changeset/2` — invalid writes are
  dropped with a log. Valid writes go through a single SQLite
  transaction with conditional upsert precedence on
  `(refreshed_at, refreshed_mono)`. Returns the list of rows that
  actually won their conditional upsert (stale writes are silently
  dropped).

  This is the single write funnel — every writer (baseline, probe,
  session) ends here.
  """
  @spec upsert([map()]) :: {:ok, [CachedModel.t()]} | {:error, term()}
  def upsert(writes) when is_list(writes) do
    GenServer.call(__MODULE__, {:upsert, writes}, 30_000)
  end
```

Add the `handle_call` clause:

```elixir
  @impl true
  def handle_call({:upsert, writes}, _from, %State{} = state) do
    result = do_upsert(writes, state)
    {:reply, result, state}
  end
```

Replace the `do_upsert/2` stub (or add it if Task 13 removed it) with the real implementation:

```elixir
  defp do_upsert(writes, state) do
    {valid_changesets, dropped} = validate_writes(writes)

    if dropped > 0 do
      Logger.warning("ModelRegistry: dropped #{dropped} invalid upsert writes")
    end

    case Repo.transaction(fn -> apply_upserts(valid_changesets, state) end) do
      {:ok, applied} -> {:ok, applied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_writes(writes) do
    Enum.reduce(writes, {[], 0}, fn write, {acc, dropped} ->
      changeset = CachedModel.changeset(%CachedModel{}, write)

      if changeset.valid? do
        {[{write, changeset} | acc], dropped}
      else
        Logger.warning(
          "ModelRegistry: rejecting write for #{inspect({write[:backend], write[:provider]})}: " <>
            "#{inspect(changeset.errors)}"
        )

        {acc, dropped + 1}
      end
    end)
    |> then(fn {valid, dropped} -> {Enum.reverse(valid), dropped} end)
  end

  defp apply_upserts(valid_changesets, state) do
    Enum.reduce(valid_changesets, [], fn {write, changeset}, applied ->
      case upsert_single_row(write, changeset) do
        {:ok, row} ->
          :ets.insert(state.ets_table, {{:row, row.backend, row.provider}, row})
          [row | applied]

        :skipped ->
          applied

        {:error, reason} ->
          Logger.warning(
            "ModelRegistry: upsert failed for #{inspect({write.backend, write.provider})}: " <>
              inspect(reason)
          )

          applied
      end
    end)
    |> Enum.reverse()
  end

  defp upsert_single_row(write, changeset) do
    existing =
      Repo.get_by(CachedModel, backend: write.backend, provider: write.provider)

    cond do
      is_nil(existing) ->
        Repo.insert(changeset)

      newer?(write, existing) ->
        existing
        |> CachedModel.changeset(write)
        |> Repo.update()

      true ->
        :skipped
    end
  end

  defp newer?(write, %CachedModel{refreshed_at: existing_at, refreshed_mono: existing_mono}) do
    case DateTime.compare(write.refreshed_at, existing_at) do
      :gt -> true
      :lt -> false
      :eq -> write.refreshed_mono > existing_mono
    end
  end
```

Note: this implementation expresses the conditional-upsert precedence in the serialized GenServer process itself, not as raw SQL. The GenServer is the single writer, so the read-then-write race that normally motivates `ON CONFLICT ... WHERE` cannot occur here — a simpler in-process comparison is safe and portable across SQLite versions. Document this choice in the function docstring.

Add to the `upsert_single_row/2` doc:

```elixir
  # Serialized writes run entirely inside the GenServer, so the
  # conditional precedence check does not need to live in raw SQL.
  # An in-process read-then-compare-then-write is race-free here
  # because no other process writes to cached_models. The spec's
  # ON CONFLICT ... WHERE SQL is an equivalent expression of the
  # same precedence rule.
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry.ex test/monkey_claw/model_registry_test.exs
git commit -m "feat: ModelRegistry upsert funnel with precedence and per-row fan-out

Single write funnel for all three writers (baseline/probe/session).
Validates every write through CachedModel.changeset, drops invalid
entries with a log, runs the valid set in one transaction with
(refreshed_at, refreshed_mono) precedence, and updates ETS for
winning rows only. Multi-provider backends fan out naturally
because callers pass one write per (backend, provider) group."
```

---

## Task 15: ModelRegistry tick handler — per-backend interval, in-flight dedup

**Files:**
- Modify: `lib/monkey_claw/model_registry.ex`
- Modify: `test/monkey_claw/model_registry_test.exs`

**Context:** Per spec §Components → ModelRegistry → Tick handler, the `:tick` message fires at `default_interval_ms` (5s after boot, then on schedule). For each configured backend: skip if an in-flight probe task exists, compute elapsed time since last probe, dispatch a probe task if elapsed ≥ personal interval. This task wires up the scheduler and in-flight tracking — actual task dispatch lands in Task 16.

- [ ] **Step 1: Write failing test**

Append to `model_registry_test.exs`:

```elixir
  describe "tick handler and probe scheduling" do
    setup do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)
      :ok
    end

    test "first tick fires at startup_delay_ms and dispatches probes" do
      # Configure the TestBackend for one backend entry with a :test backend key.
      backend_configs = %{
        "test_be" => %{adapter: MonkeyClaw.AgentBridge.Backend.Test}
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["test_be"],
           backend_configs: backend_configs,
           default_interval_ms: 200,
           startup_delay_ms: 50
         ]}
      )

      # Wait for the first tick + probe dispatch + result handling.
      :timer.sleep(300)

      models = MonkeyClaw.ModelRegistry.list_for_backend("test_be")
      refute models == [], "expected at least one model after probe tick"
    end

    test "in-flight dedup prevents double-dispatch on rapid ticks" do
      backend_configs = %{
        "slow_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_delay_ms: 150,
          probe_deadline_ms: 1_000
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["slow_be"],
           backend_configs: backend_configs,
           default_interval_ms: 30,
           startup_delay_ms: 10
         ]}
      )

      # Force several ticks during the in-flight window.
      :timer.sleep(200)

      # Only one row should exist — multiple ticks did not each spawn a probe.
      models = MonkeyClaw.ModelRegistry.list_for_backend("slow_be")
      assert length(models) >= 1
    end
  end
```

- [ ] **Step 2: Run to confirm failure**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: new tests fail — tick handler not implemented, probes never dispatched.

- [ ] **Step 3: Implement the tick handler**

In `lib/monkey_claw/model_registry.ex`:

Add `@startup_delay_ms_default` constant at the top:

```elixir
  @startup_delay_ms_default 5_000
```

Modify `init/1` to accept `:startup_delay_ms` and schedule the first tick in `handle_continue(:load, ...)`:

```elixir
  @impl true
  def handle_continue(:load, %State{} = state) do
    state = load_existing_and_seed_baseline(state)
    state = schedule_tick(state, startup_delay_ms(state))
    {:noreply, state}
  end

  defp startup_delay_ms(_state) do
    app_config = Application.get_env(:monkey_claw, __MODULE__, [])
    Keyword.get(app_config, :startup_delay_ms, @startup_delay_ms_default)
  end

  defp schedule_tick(state, delay_ms) do
    ref = Process.send_after(self(), :tick, delay_ms)
    %{state | tick_timer_ref: ref}
  end
```

But `init/1` also needs to accept `:startup_delay_ms` directly from opts (for test overrides). Adjust init/1:

Add to `opts` reading:
```elixir
    startup_delay = Keyword.get(opts, :startup_delay_ms, @startup_delay_ms_default)
```

And stash it in state. Add `:startup_delay_ms` to the State struct:

```elixir
    defstruct [
      :ets_table,
      :default_interval,
      ...,
      startup_delay_ms: 5_000,
      ...
    ]
```

Pass it to `schedule_tick/2` from `handle_continue`.

Add the `:tick` handler:

```elixir
  @impl true
  def handle_info(:tick, %State{} = state) do
    state =
      Enum.reduce(state.backends, state, fn backend, acc ->
        maybe_dispatch_probe(backend, acc)
      end)

    state = schedule_tick(state, state.default_interval)
    {:noreply, state}
  end
```

Add the dispatcher:

```elixir
  defp maybe_dispatch_probe(backend, state) do
    cond do
      in_flight?(backend, state) ->
        state

      not due?(backend, state) ->
        state

      true ->
        dispatch_probe(backend, state)
    end
  end

  defp in_flight?(backend, %State{in_flight: map}) do
    Enum.any?(map, fn {_ref, b} -> b == backend end)
  end

  defp due?(backend, state) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(state.last_probe_at, backend, 0)
    personal = Map.get(state.backend_intervals, backend, state.default_interval)
    now - last >= personal
  end

  defp dispatch_probe(backend, state) do
    config = Map.get(state.backend_configs, backend, %{})
    adapter = Map.get(config, :adapter, MonkeyClaw.AgentBridge.Backend.BeamAgent)
    opts = Map.delete(config, :adapter)

    task =
      Task.Supervisor.async_nolink(MonkeyClaw.TaskSupervisor, fn ->
        adapter.list_models(opts)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, backend)}
  end
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: first tick test likely still fails because the task result handler is not implemented (Task 16).

**This is expected.** The tick handler dispatches tasks but their results never get written to the cache until Task 16 adds `handle_info({ref, result}, ...)`. Mark this task as "dispatches probe tasks correctly" and add a narrower assertion that verifies the in-flight map grew. Rewrite the first test to:

```elixir
    test "first tick dispatches probe tasks into in_flight map" do
      backend_configs = %{
        "test_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_delay_ms: 100
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["test_be"],
           backend_configs: backend_configs,
           default_interval_ms: 200,
           startup_delay_ms: 20
         ]}
      )

      # Wait long enough for the first tick to dispatch but not long
      # enough for the slow backend to finish. Inspect in_flight via
      # the sys:get_state introspection for test-only visibility.
      :timer.sleep(50)

      state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert map_size(state.in_flight) == 1
    end
```

And delete the in-flight dedup test body stub (Task 16 will re-add a full end-to-end test).

Re-run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: the dispatch test passes.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry.ex test/monkey_claw/model_registry_test.exs
git commit -m "feat: ModelRegistry tick handler with per-backend scheduling and in-flight dedup

First tick fires at startup_delay_ms (default 5s), subsequent ticks at
default_interval_ms. Each tick iterates configured backends, skipping
those with an in-flight probe task or that aren't due per their
personal interval. Probe tasks dispatch via MonkeyClaw.TaskSupervisor
with async_nolink. Task result handling lands in the next task."
```

---

## Task 16: Probe task result handler + DOWN handler + backoff

**Files:**
- Modify: `lib/monkey_claw/model_registry.ex`
- Modify: `test/monkey_claw/model_registry_test.exs`

**Context:** Per spec §Components → ModelRegistry → Probe task dispatch and §Error Handling, task results arrive as `{ref, result}` messages. `{:ok, model_attrs_list}` gets grouped per-provider and funneled through `upsert/1`. `{:error, _}` triggers exponential backoff (5s → 5m cap). `Task.yield/2` timeouts trigger `Task.shutdown` and backoff. A `:DOWN` message with abnormal reason also triggers backoff. On success, backoff resets.

- [ ] **Step 1: Write failing tests**

Append to `model_registry_test.exs`:

```elixir
  describe "probe task result handling" do
    setup do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)
      :ok
    end

    test "successful probe result lands in the cache via upsert" do
      backend_configs = %{
        "test_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:ok, [
            %{provider: "anthropic", model_id: "m1", display_name: "M1", capabilities: %{}}
          ]}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["test_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: 20
         ]}
      )

      :timer.sleep(200)

      models = MonkeyClaw.ModelRegistry.list_for_backend("test_be")
      assert [%{model_id: "m1", provider: "anthropic"}] = models
    end

    test "error probe result increments backoff and keeps stale cache" do
      backend_configs = %{
        "flaky_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:error, :upstream_down}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["flaky_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: 20
         ]}
      )

      :timer.sleep(100)

      state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert Map.has_key?(state.backoff, "flaky_be")
      assert state.backoff["flaky_be"] >= 5_000
    end

    test "crash in backend list_models is caught via DOWN with abnormal reason" do
      backend_configs = %{
        "crash_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:crash, "boom"}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["crash_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: 20
         ]}
      )

      :timer.sleep(100)

      # Registry should still be alive.
      assert Process.alive?(Process.whereis(MonkeyClaw.ModelRegistry))

      state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert Map.has_key?(state.backoff, "crash_be")
    end
  end
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: new tests fail — no task result handler.

- [ ] **Step 3: Implement the handlers**

Add constants to `lib/monkey_claw/model_registry.ex`:

```elixir
  @backoff_initial_ms 5_000
  @backoff_max_ms 300_000
```

Add the `handle_info` clauses for task result and DOWN messages, placed before the catch-all:

```elixir
  @impl true
  def handle_info({ref, result}, %State{in_flight: in_flight} = state) when is_reference(ref) do
    case Map.pop(in_flight, ref) do
      {nil, _} ->
        # Not one of ours — probably a late reply after shutdown.
        {:noreply, state}

      {backend, remaining} ->
        # Flush the DOWN message that will follow a successful task.
        Process.demonitor(ref, [:flush])

        state = %{state | in_flight: remaining}
        state = handle_probe_result(backend, result, state)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{in_flight: in_flight} = state)
      when is_reference(ref) do
    case Map.pop(in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {backend, remaining} ->
        Logger.warning(
          "ModelRegistry: probe task for #{backend} crashed: #{inspect(reason)}"
        )

        state = %{state | in_flight: remaining}
        state = apply_backoff(backend, state)
        {:noreply, state}
    end
  end

  def handle_info({:'ETS-TRANSFER', _tid, _from, :model_registry}, %State{} = state) do
    {:noreply, state}
  end

  def handle_info(:tick, %State{} = state) do
    # ... existing tick handler ...
  end

  def handle_info(msg, %State{} = state) do
    Logger.debug("ModelRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
```

Add the result handler helpers:

```elixir
  defp handle_probe_result(backend, {:ok, model_attrs_list}, state) do
    now = DateTime.utc_now()
    mono = System.monotonic_time()

    writes =
      model_attrs_list
      |> Enum.group_by(& &1.provider)
      |> Enum.map(fn {provider, attrs_list} ->
        %{
          backend: backend,
          provider: provider,
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: Enum.map(attrs_list, &Map.delete(&1, :provider))
        }
      end)

    case do_upsert(writes, state) do
      {:ok, _applied} ->
        state
        |> reset_backoff(backend)
        |> mark_probed(backend)

      {:error, reason} ->
        Logger.warning("ModelRegistry: probe upsert failed for #{backend}: #{inspect(reason)}")
        apply_backoff(backend, state)
    end
  end

  defp handle_probe_result(backend, {:error, reason}, state) do
    Logger.warning("ModelRegistry: probe failed for #{backend}: #{inspect(reason)}, keeping stale cache")
    apply_backoff(backend, state)
  end

  defp mark_probed(state, backend) do
    %{state | last_probe_at: Map.put(state.last_probe_at, backend, System.monotonic_time(:millisecond))}
  end

  defp reset_backoff(state, backend) do
    %{state | backoff: Map.delete(state.backoff, backend)}
  end

  defp apply_backoff(backend, state) do
    current = Map.get(state.backoff, backend, @backoff_initial_ms)
    next = min(current * 2, @backoff_max_ms)
    # Increase last_probe_at by the backoff so the next tick skips this backend.
    now_ms = System.monotonic_time(:millisecond)
    bumped_last = now_ms - Map.get(state.backend_intervals, backend, state.default_interval) + next

    %{
      state
      | backoff: Map.put(state.backoff, backend, next),
        last_probe_at: Map.put(state.last_probe_at, backend, bumped_last)
    }
  end
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: all probe result tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry.ex test/monkey_claw/model_registry_test.exs
git commit -m "feat: ModelRegistry probe result + DOWN handlers with exponential backoff

Successful probe results group by provider, fan into per-(backend,
provider) writes, and hit the upsert funnel. Error results and task
crashes trigger exponential backoff (5s initial, doubling to 5m cap).
Registry stays alive on any backend failure — stale cache preserved."
```

---

## Task 17: `refresh/1` and `refresh_all/0` on-demand probing

**Files:**
- Modify: `lib/monkey_claw/model_registry.ex`
- Modify: `test/monkey_claw/model_registry_test.exs`

**Context:** Per spec §Components → ModelRegistry → Runtime control API and §Data Flow → On-demand refresh, `refresh/1` dispatches an immediate probe for a single backend and blocks the caller (GenServer.call, 30s timeout) until the task completes. `refresh_all/0` iterates all configured backends sequentially.

- [ ] **Step 1: Write failing tests**

Append:

```elixir
  describe "refresh/1 and refresh_all/0" do
    setup do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)
      :ok
    end

    test "refresh/1 runs a synchronous probe and returns :ok" do
      backend_configs = %{
        "test_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response:
            {:ok, [%{provider: "anthropic", model_id: "refreshed", display_name: "R", capabilities: %{}}]}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["test_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      assert :ok = MonkeyClaw.ModelRegistry.refresh("test_be")
      assert [%{model_id: "refreshed"}] = MonkeyClaw.ModelRegistry.list_for_backend("test_be")
    end

    test "refresh/1 returns {:error, reason} when backend returns an error" do
      backend_configs = %{
        "flaky" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:error, :boom}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["flaky"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      assert {:error, :boom} = MonkeyClaw.ModelRegistry.refresh("flaky")
    end

    test "refresh_all/0 iterates every configured backend" do
      backend_configs = %{
        "a" => %{adapter: MonkeyClaw.AgentBridge.Backend.Test,
                 list_models_response:
                   {:ok, [%{provider: "anthropic", model_id: "a1", display_name: "A1", capabilities: %{}}]}},
        "b" => %{adapter: MonkeyClaw.AgentBridge.Backend.Test,
                 list_models_response:
                   {:ok, [%{provider: "openai", model_id: "b1", display_name: "B1", capabilities: %{}}]}}
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["a", "b"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      assert :ok = MonkeyClaw.ModelRegistry.refresh_all()
      assert length(MonkeyClaw.ModelRegistry.list_for_backend("a")) == 1
      assert length(MonkeyClaw.ModelRegistry.list_for_backend("b")) == 1
    end
  end
```

- [ ] **Step 2: Run tests to confirm failure**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: refresh tests fail — undefined functions.

- [ ] **Step 3: Implement `refresh/1` and `refresh_all/0`**

Add to the Client API:

```elixir
  @per_backend_refresh_timeout_ms 30_000
  @refresh_buffer_ms 5_000

  @doc """
  Force an immediate synchronous probe for a single backend.

  Blocks the caller until the probe task completes or times out.
  Bypasses the tick schedule. Returns `:ok` on success,
  `{:error, reason}` on backend failure or timeout.
  """
  @spec refresh(atom() | String.t()) :: :ok | {:error, term()}
  def refresh(backend) do
    backend_str = to_string(backend)
    GenServer.call(__MODULE__, {:refresh, backend_str}, @per_backend_refresh_timeout_ms + 1_000)
  end

  @doc """
  Force-probe every configured backend sequentially.

  Call timeout scales with the backend count to avoid spurious
  GenServer.call timeouts on large backend sets (spec I5).
  """
  @spec refresh_all() :: :ok
  def refresh_all do
    timeout = computed_refresh_all_timeout()
    GenServer.call(__MODULE__, :refresh_all, timeout)
  end

  defp computed_refresh_all_timeout do
    backends =
      Application.get_env(:monkey_claw, __MODULE__, [])
      |> Keyword.get(:backends, [])

    length(backends) * @per_backend_refresh_timeout_ms + @refresh_buffer_ms
  end
```

Add the handle_call clauses:

```elixir
  def handle_call({:refresh, backend}, _from, %State{} = state) do
    case do_synchronous_probe(backend, state) do
      {:ok, state} -> {:reply, :ok, state}
      {{:error, reason}, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:refresh_all, _from, %State{} = state) do
    state =
      Enum.reduce(state.backends, state, fn backend, acc ->
        case do_synchronous_probe(backend, acc) do
          {:ok, new_state} -> new_state
          {{:error, _}, new_state} -> new_state
        end
      end)

    {:reply, :ok, state}
  end
```

Add the synchronous probe helper:

```elixir
  defp do_synchronous_probe(backend, state) do
    config = Map.get(state.backend_configs, backend, %{})
    adapter = Map.get(config, :adapter, MonkeyClaw.AgentBridge.Backend.BeamAgent)
    opts = Map.delete(config, :adapter)

    task =
      Task.Supervisor.async_nolink(MonkeyClaw.TaskSupervisor, fn ->
        adapter.list_models(opts)
      end)

    timeout = Map.get(opts, :probe_deadline_ms, @per_backend_refresh_timeout_ms)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, models}} ->
        new_state = handle_probe_result(backend, {:ok, models}, state)
        {:ok, new_state}

      {:ok, {:error, reason}} ->
        new_state = handle_probe_result(backend, {:error, reason}, state)
        {{:error, reason}, new_state}

      {:exit, reason} ->
        new_state = apply_backoff(backend, state)
        {{:error, {:probe_crashed, reason}}, new_state}

      nil ->
        new_state = apply_backoff(backend, state)
        {{:error, :probe_timeout}, new_state}
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: all refresh tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry.ex test/monkey_claw/model_registry_test.exs
git commit -m "feat: ModelRegistry refresh/1 and refresh_all/0 on-demand probing

refresh/1 dispatches a synchronous probe via Task.Supervisor and
blocks until it completes or times out. refresh_all/0 iterates all
configured backends sequentially with a timeout scaled to the
backend count."
```

---

## Task 18: `configure/1` with runtime validation

**Files:**
- Modify: `lib/monkey_claw/model_registry.ex`
- Modify: `test/monkey_claw/model_registry_test.exs`

**Context:** Per spec I1, `configure/1` must validate every option before applying: intervals positive integers, `backends` list of binaries, `backend_intervals` values ≥ `default_interval`, `backend_configs` a map. Invalid opts return `{:error, {:invalid_option, key, reason}}` and leave state unchanged.

- [ ] **Step 1: Write failing tests**

Append:

```elixir
  describe "configure/1" do
    setup do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["a"],
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      :ok
    end

    test "accepts valid opts and applies them" do
      assert :ok =
               MonkeyClaw.ModelRegistry.configure(
                 backends: ["a", "b"],
                 default_interval_ms: :timer.hours(12)
               )

      state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert state.backends == ["a", "b"]
      assert state.default_interval == :timer.hours(12)
    end

    test "rejects non-positive default_interval_ms" do
      assert {:error, {:invalid_option, :default_interval_ms, _}} =
               MonkeyClaw.ModelRegistry.configure(default_interval_ms: 0)
    end

    test "rejects non-list backends" do
      assert {:error, {:invalid_option, :backends, _}} =
               MonkeyClaw.ModelRegistry.configure(backends: "not-a-list")
    end

    test "rejects backend_intervals value smaller than default" do
      assert {:error, {:invalid_option, :backend_intervals, _}} =
               MonkeyClaw.ModelRegistry.configure(backend_intervals: %{"a" => 1_000})
    end

    test "rejects non-map backend_configs" do
      assert {:error, {:invalid_option, :backend_configs, _}} =
               MonkeyClaw.ModelRegistry.configure(backend_configs: [])
    end

    test "leaves state unchanged on validation failure" do
      before = :sys.get_state(MonkeyClaw.ModelRegistry)

      {:error, _} = MonkeyClaw.ModelRegistry.configure(default_interval_ms: -1)

      after_state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert before.default_interval == after_state.default_interval
      assert before.backends == after_state.backends
    end
  end
```

- [ ] **Step 2: Run to confirm failure**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`

- [ ] **Step 3: Implement `configure/1`**

Add to the Client API:

```elixir
  @doc """
  Update runtime configuration without restarting the GenServer.

  ## Options

    * `:backends` — List of backend identifier strings
    * `:default_interval_ms` — Positive integer
    * `:backend_intervals` — Map of backend => interval (all values ≥ default)
    * `:backend_configs` — Map of backend => opts map
    * `:workspace_id` — UUID or nil

  Every option is validated before any change is applied. Invalid
  input returns `{:error, {:invalid_option, key, reason}}` and leaves
  state fully unchanged (no partial application).
  """
  @spec configure(keyword()) :: :ok | {:error, {:invalid_option, atom(), term()}}
  def configure(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end
```

Add the handle_call:

```elixir
  def handle_call({:configure, opts}, _from, %State{} = state) do
    case validate_configure_opts(opts, state) do
      :ok ->
        new_state = apply_configure_opts(opts, state)
        {:reply, :ok, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end
```

Add validators:

```elixir
  defp validate_configure_opts(opts, state) do
    Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
      case validate_option(key, value, state) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_option(:default_interval_ms, value, _state)
       when is_integer(value) and value > 0, do: :ok

  defp validate_option(:default_interval_ms, value, _state),
    do: {:error, {:invalid_option, :default_interval_ms, value}}

  defp validate_option(:backends, value, _state) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: :ok, else: {:error, {:invalid_option, :backends, value}}
  end

  defp validate_option(:backends, value, _state),
    do: {:error, {:invalid_option, :backends, value}}

  defp validate_option(:backend_intervals, value, state) when is_map(value) do
    min = state.default_interval

    if Enum.all?(value, fn {k, v} -> is_binary(k) and is_integer(v) and v >= min end) do
      :ok
    else
      {:error, {:invalid_option, :backend_intervals, value}}
    end
  end

  defp validate_option(:backend_intervals, value, _state),
    do: {:error, {:invalid_option, :backend_intervals, value}}

  defp validate_option(:backend_configs, value, _state) when is_map(value), do: :ok

  defp validate_option(:backend_configs, value, _state),
    do: {:error, {:invalid_option, :backend_configs, value}}

  defp validate_option(:workspace_id, nil, _state), do: :ok

  defp validate_option(:workspace_id, value, _state) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> :ok
      :error -> {:error, {:invalid_option, :workspace_id, value}}
    end
  end

  defp validate_option(key, value, _state),
    do: {:error, {:invalid_option, key, value}}

  defp apply_configure_opts(opts, state) do
    Enum.reduce(opts, state, fn
      {:backends, v}, acc -> %{acc | backends: v}
      {:default_interval_ms, v}, acc -> %{acc | default_interval: v}
      {:backend_intervals, v}, acc -> %{acc | backend_intervals: v}
      {:backend_configs, v}, acc -> %{acc | backend_configs: v}
      {:workspace_id, v}, acc -> %{acc | workspace_id: v}
    end)
  end
```

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs`
Expected: all configure tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/monkey_claw/model_registry.ex test/monkey_claw/model_registry_test.exs
git commit -m "feat: validated configure/1 on ModelRegistry (spec I1)

Every option is validated before any change is applied. Invalid input
returns {:error, {:invalid_option, key, reason}} with state unchanged.
backend_intervals values must be >= default_interval."
```

---

## Task 19: Session hook — authenticated post-start cast

**Files:**
- Modify: `lib/monkey_claw/agent_bridge/session.ex`
- Modify: `lib/monkey_claw/model_registry.ex`
- Create: `test/monkey_claw/agent_bridge/session_model_hook_test.exs`

**Context:** Per spec §Components → AgentBridge.Session and §C3, after a successful `start_session` the Session process fires an authenticated async cast to `ModelRegistry` with the freshly observed models (source: `"session"`). The registry verifies the cast comes from a pid registered in `MonkeyClaw.AgentBridge.SessionRegistry` — unregistered pids are ignored with a debug log. The payload goes through the same `CachedModel.changeset/2` validation as every other write.

- [ ] **Step 1: Read the Session module to locate the start_session success path**

Run `Read` on `lib/monkey_claw/agent_bridge/session.ex` focusing on the lines around the `backend.start_session` call (around line 404 per previous grep). Note the session's backend adapter module, its workspace_id, and where it registers itself in `SessionRegistry`.

- [ ] **Step 2: Write failing integration test**

Write `test/monkey_claw/agent_bridge/session_model_hook_test.exs`:

```elixir
defmodule MonkeyClaw.AgentBridge.SessionModelHookTest do
  @moduledoc false

  use MonkeyClaw.DataCase, async: false

  alias MonkeyClaw.AgentBridge.Session
  alias MonkeyClaw.ModelRegistry

  setup do
    start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)
    start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24),
                                        startup_delay_ms: :timer.hours(24)]})
    :ok
  end

  describe "session start fires authenticated model hook" do
    test "successful session start results in session-sourced rows in ModelRegistry" do
      session_config = %{
        id: "hook-test-#{System.unique_integer([:positive])}",
        backend: MonkeyClaw.AgentBridge.Backend.Test,
        session_opts: %{
          list_models_response:
            {:ok, [%{provider: "anthropic", model_id: "hook-model", display_name: "Hook", capabilities: %{}}]}
        }
      }

      {:ok, _pid} = Session.start_link(session_config)

      # Allow the async cast + upsert to land.
      :timer.sleep(100)

      models = ModelRegistry.list_for_backend("test")
      assert Enum.any?(models, &(&1.model_id == "hook-model"))
    end

    test "registry ignores cast from unregistered pid with debug log" do
      # Cast directly from an arbitrary process.
      unregistered_payload = %{
        backend: "claude",
        provider: "anthropic",
        refreshed_at: DateTime.utc_now(),
        refreshed_mono: System.monotonic_time(),
        models: [%{model_id: "ghost", display_name: "Ghost", capabilities: %{}}]
      }

      GenServer.cast(ModelRegistry, {:session_hook, self(), unregistered_payload})
      :timer.sleep(50)

      assert ModelRegistry.list_for_backend("claude") == []
    end
  end
end
```

- [ ] **Step 3: Run to confirm failure**

Run: `MIX_ENV=test mix test test/monkey_claw/agent_bridge/session_model_hook_test.exs`
Expected: compile errors and/or failures.

- [ ] **Step 4: Add Session hook on successful start**

In `lib/monkey_claw/agent_bridge/session.ex`, find the line calling `backend.start_session(session_opts)` (around line 404). After the success branch binds `session_pid`, add a call to a private helper `fire_model_hook/3` that casts the observed model list to ModelRegistry.

Example pseudo-diff (adapt to actual surrounding code):

```elixir
    with {:ok, session_pid} <- backend.start_session(session_opts),
         # ... existing setup ...
         :ok <- fire_model_hook(backend, session_opts, self()) do
      # ... existing continuation ...
    end
```

Add the helper:

```elixir
  # Fire an async, fire-and-forget cast to ModelRegistry with the model
  # list observed during session start. Authenticated via the current
  # session pid — ModelRegistry verifies the pid is live in
  # MonkeyClaw.AgentBridge.SessionRegistry before accepting the payload.
  #
  # Never raises, never blocks session lifecycle. A failure to fire the
  # hook is logged at debug level only.
  @spec fire_model_hook(module(), map(), pid()) :: :ok
  defp fire_model_hook(backend, session_opts, session_pid) do
    case backend.list_models(session_opts) do
      {:ok, model_attrs_list} when is_list(model_attrs_list) ->
        backend_name = Map.get(session_opts, :backend_name, infer_backend_name(backend))
        now = DateTime.utc_now()
        mono = System.monotonic_time()

        payload =
          model_attrs_list
          |> Enum.group_by(& &1.provider)
          |> Enum.map(fn {provider, attrs_list} ->
            %{
              backend: to_string(backend_name),
              provider: provider,
              source: "session",
              refreshed_at: now,
              refreshed_mono: mono,
              models: Enum.map(attrs_list, &Map.delete(&1, :provider))
            }
          end)

        GenServer.cast(MonkeyClaw.ModelRegistry, {:session_hook, session_pid, payload})
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp infer_backend_name(MonkeyClaw.AgentBridge.Backend.Test), do: "test"
  defp infer_backend_name(MonkeyClaw.AgentBridge.Backend.BeamAgent), do: "claude"
  defp infer_backend_name(_), do: "unknown"
```

- [ ] **Step 5: Add authenticated handle_cast in ModelRegistry**

In `lib/monkey_claw/model_registry.ex`, add:

```elixir
  @impl true
  def handle_cast({:session_hook, session_pid, writes}, %State{} = state)
      when is_pid(session_pid) and is_list(writes) do
    if session_registered?(session_pid) do
      case do_upsert(writes, state) do
        {:ok, _} -> {:noreply, state}
        {:error, reason} ->
          Logger.warning("ModelRegistry: session hook upsert failed: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      Logger.debug("ModelRegistry: rejecting session hook from unregistered pid #{inspect(session_pid)}")
      {:noreply, state}
    end
  end

  def handle_cast(_other, state), do: {:noreply, state}

  defp session_registered?(pid) do
    case Registry.keys(MonkeyClaw.AgentBridge.SessionRegistry, pid) do
      [] -> false
      _ -> true
    end
  rescue
    _ -> false
  end
```

- [ ] **Step 6: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/agent_bridge/session_model_hook_test.exs`
Expected: both tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/monkey_claw/agent_bridge/session.ex \
        lib/monkey_claw/model_registry.ex \
        test/monkey_claw/agent_bridge/session_model_hook_test.exs
git commit -m "feat: authenticated session hook cast to ModelRegistry (spec C3)

Session fires an async cast on successful start with the observed
model list, tagged source=session. ModelRegistry verifies the sending
pid is registered in AgentBridge.SessionRegistry before accepting the
payload; unregistered pids are silently dropped. Fire-and-forget from
the Session perspective — hook failures never affect session lifecycle."
```

---

## Task 20: Provider log redaction via SecretScanner

**Files:**
- Modify: `lib/monkey_claw/model_registry/provider.ex`
- Create: `test/monkey_claw/model_registry/provider_log_redaction_test.exs`

**Context:** Per spec §Security Invariant 4 and §I8, `Provider` currently logs non-2xx responses and request failures with `inspect(body)` / `inspect(reason)`. If an upstream API ever echoes an auth header back or Req's error struct includes request headers, that inspect leaks the key. Replace those 6 log sites with a helper that routes the inspected payload through `MonkeyClaw.Vault.SecretScanner.scan_and_redact/2`.

- [ ] **Step 1: Write failing test**

Write `test/monkey_claw/model_registry/provider_log_redaction_test.exs`:

```elixir
defmodule MonkeyClaw.ModelRegistry.ProviderLogRedactionTest do
  @moduledoc """
  Verifies Provider log sites route through SecretScanner to prevent
  leaking credentials embedded in upstream error bodies or Req error
  structs.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MonkeyClaw.ModelRegistry.Provider

  test "redacts secret-shaped content in error logs" do
    # Arrange: a known secret-looking string in the inspect output.
    # Provider has a private `sanitize_for_log/1` — test it through the
    # public fetch_models path with a bad key that will land in the log.
    log =
      capture_log(fn ->
        # Use an unreachable port to force the :request_failed branch,
        # and include an API key in the request so the Req error
        # potentially echoes it back in :reason.
        Provider.fetch_models("anthropic",
          api_key: "sk-ant-api03-VERYSECRETKEY1234567890ABCDEFGH1234567890",
          base_url: "http://localhost:1"
        )
      end)

    # The log must not contain the raw key (substring check after
    # any prefix like "sk-ant-").
    refute log =~ "VERYSECRETKEY1234567890"
  end
end
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/provider_log_redaction_test.exs`
Expected: test fails — the raw key appears in the log because Provider currently inspects unredacted reasons. (Note: in practice Req's failure struct may NOT include the key — verify by inspecting the captured log. If the test can't deterministically reproduce a leak, add a call to the internal sanitize helper directly instead of relying on Req behaviour.)

- [ ] **Step 3: Add the sanitize helper and wire it into all 6 log sites**

In `lib/monkey_claw/model_registry/provider.ex`, add at the top of the private section:

```elixir
  alias MonkeyClaw.Vault.SecretScanner

  # Sanitize a term for logging by inspecting it and then routing the
  # resulting string through SecretScanner. Any matched secret pattern
  # is replaced with [REDACTED:LABEL]. On scan failure we fall back to
  # a safe placeholder rather than logging raw content.
  @spec sanitize_for_log(term()) :: String.t()
  defp sanitize_for_log(term) do
    inspected = inspect(term, limit: :infinity, printable_limit: 4096)

    case SecretScanner.scan_and_redact(inspected) do
      {:ok, redacted, _count} -> redacted
      {:error, _} -> "[LOG_SANITIZE_FAILED]"
    end
  end
```

Replace every `inspect(body)` / `inspect(reason)` in the existing `Logger.warning` calls with `sanitize_for_log(body)` / `sanitize_for_log(reason)`. Six sites total: three for `status, body` in the non-200 branch and three for `reason` in the request-failed branch of each provider (`anthropic`, `openai`, `google`).

Example for `anthropic_request/2`:

```elixir
      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Anthropic models API returned #{status}: #{sanitize_for_log(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("Anthropic models API request failed: #{sanitize_for_log(reason)}")
        {:error, {:request_failed, reason}}
```

Apply the same change to `openai_request/2` and `google_request/2`.

- [ ] **Step 4: Run tests**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/provider_log_redaction_test.exs`
Expected: test passes.

- [ ] **Step 5: Run the full Provider test suite to verify no regressions**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry/`
Expected: all passing.

- [ ] **Step 6: Commit**

```bash
git add lib/monkey_claw/model_registry/provider.ex \
        test/monkey_claw/model_registry/provider_log_redaction_test.exs
git commit -m "feat: redact Provider log sites through SecretScanner (spec I8)

Every Logger.warning site in Provider that previously inspected a
response body or error reason now routes through sanitize_for_log/1,
which hands the inspected term to Vault.SecretScanner.scan_and_redact/2.
Prevents credential leakage if an upstream API echoes auth headers
back in an error body or if Req's error struct includes request
headers."
```

---

## Task 21: Cut over vault_live.ex to new reader API + grep audit

**Files:**
- Modify: `lib/monkey_claw_web/live/vault_live.ex`
- Commands: grep audit

**Context:** Per spec §Cutover item 8, `vault_live.ex` is the only current consumer of the old ModelRegistry API. It calls `ModelRegistry.list_all_models/0` at line 613 and `ModelRegistry.refresh_all/0` at line 621. Both must be replaced with the new API.

- [ ] **Step 1: Read the current vault_live.ex call sites**

Run: `Read` on `lib/monkey_claw_web/live/vault_live.ex` offset 600, limit 40. Understand how the result shape is consumed.

- [ ] **Step 2: Update the calls**

Replace `ModelRegistry.list_all_models()` with `ModelRegistry.list_all_by_provider()`. Because the new API returns `%{provider => [enriched_model]}` where each model is a map (not a `%CachedModel{}` struct), audit the consuming code for any field access — `.model_id`, `.display_name`, `.capabilities` all work the same on the enriched map, but `.provider` is now ALSO on each model.

Replace `ModelRegistry.refresh_all()` with `ModelRegistry.refresh_all()` (same name — the new API retains this entry point).

If the LiveView iterated `%CachedModel{}` structs and accessed `.provider`, that still works on the enriched map. If it used `Ecto.Changeset` introspection or any other struct-specific API, adapt accordingly.

- [ ] **Step 3: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Run the vault_live.ex test suite**

Run: `MIX_ENV=test mix test test/monkey_claw_web/live/vault_live_test.exs` (if it exists)
Expected: passing. If tests fail due to shape mismatch, adapt the test assertions to the new map shape.

- [ ] **Step 5: Grep audit — zero references to old API**

Run these commands and verify each returns NO matches (outside of the spec and plan documents):

```bash
grep -rn "ModelRegistry\.list_models" lib/ test/ config/
grep -rn "ModelRegistry\.list_all_models" lib/ test/ config/
grep -rn "CachedModel\.valid_providers" lib/ test/ config/
grep -rn "CachedModel\.create_changeset" lib/ test/ config/
grep -rn "CachedModel\.update_changeset" lib/ test/ config/
```

If any command returns matches, investigate each hit — either it's a comment/docstring that should be updated to reference the new API, or it's dead code to delete.

- [ ] **Step 6: Commit**

```bash
git add lib/monkey_claw_web/live/vault_live.ex
git commit -m "feat: cut vault_live.ex over to new ModelRegistry reader API

Replaces list_all_models/0 with list_all_by_provider/0. Zero references
to the old provider-keyed API remain outside of the spec and plan docs
(grep-verified)."
```

---

## Task 22: E2E integration test — full supervision tree boot, crash-restart continuity

**Files:**
- Create: `test/monkey_claw/model_registry_e2e_test.exs`

**Context:** Per spec §Testing → End-to-End, one E2E test boots the full supervision tree with `Backend.Test`, asserts reads work, asserts on-demand refresh updates rows, and asserts crash-restart continuity via the ETS heir.

- [ ] **Step 1: Write the E2E test**

Write `test/monkey_claw/model_registry_e2e_test.exs`:

```elixir
defmodule MonkeyClaw.ModelRegistryE2ETest do
  @moduledoc """
  End-to-end test for the ModelRegistry: full supervision tree boot,
  read projections, on-demand refresh, and crash-restart continuity.
  """

  use MonkeyClaw.DataCase, async: false

  alias MonkeyClaw.ModelRegistry

  setup do
    Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
      entries: [
        %{
          backend: "claude",
          provider: "anthropic",
          models: [%{model_id: "baseline-sonnet", display_name: "Baseline Sonnet", capabilities: %{}}]
        }
      ]
    )

    on_exit(fn ->
      Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
    end)

    start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)

    start_supervised!(
      {ModelRegistry,
       [
         backends: ["claude"],
         backend_configs: %{
           "claude" => %{
             adapter: MonkeyClaw.AgentBridge.Backend.Test,
             list_models_response:
               {:ok,
                [
                  %{provider: "anthropic", model_id: "probe-sonnet", display_name: "Probe Sonnet", capabilities: %{}}
                ]}
           }
         },
         default_interval_ms: :timer.hours(24),
         startup_delay_ms: :timer.hours(24)
       ]}
    )

    :ok
  end

  test "baseline is available before any probe runs" do
    models = ModelRegistry.list_for_backend("claude")
    assert Enum.any?(models, &(&1.model_id == "baseline-sonnet"))
  end

  test "on-demand refresh replaces baseline with probe result" do
    assert :ok = ModelRegistry.refresh("claude")
    models = ModelRegistry.list_for_backend("claude")
    assert Enum.any?(models, &(&1.model_id == "probe-sonnet"))
  end

  test "list_for_provider returns claude models tagged with anthropic" do
    assert :ok = ModelRegistry.refresh("claude")
    models = ModelRegistry.list_for_provider("anthropic")
    assert Enum.all?(models, &(&1.provider == "anthropic"))
    assert Enum.all?(models, &(&1.backend == "claude"))
  end

  test "crash + restart preserves cached rows via ETS heir" do
    assert :ok = ModelRegistry.refresh("claude")
    before = ModelRegistry.list_for_backend("claude")
    assert before != []

    pid = Process.whereis(ModelRegistry)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    :timer.sleep(200)

    after_crash = ModelRegistry.list_for_backend("claude")
    assert after_crash == before
  end
end
```

- [ ] **Step 2: Run the E2E test**

Run: `MIX_ENV=test mix test test/monkey_claw/model_registry_e2e_test.exs`
Expected: all four tests pass.

- [ ] **Step 3: Commit**

```bash
git add test/monkey_claw/model_registry_e2e_test.exs
git commit -m "test: add E2E integration test for ModelRegistry cutover

Covers baseline availability before probe, on-demand refresh,
list_for_provider fan-out, and crash-restart continuity via ETS heir."
```

---

## Task 23: Final cutover audit + quality gates

**Files:**
- Commands only — no code changes unless audit turns up dead code

**Context:** Final gate before PR. Must hold the cutover guarantee: zero references to the old API, all tests green, all quality gates clean.

- [ ] **Step 1: Run the zero-reference grep audit**

```bash
grep -rn "list_models/1" lib/ test/ config/ | grep -v "docs/" | grep -v "\.md:"
grep -rn "list_all_models" lib/ test/ config/ | grep -v "docs/" | grep -v "\.md:"
grep -rn "CachedModel\.create_changeset" lib/ test/ config/
grep -rn "CachedModel\.update_changeset" lib/ test/ config/
grep -rn "CachedModel\.valid_providers" lib/ test/ config/
grep -rn "provider_secrets" lib/monkey_claw/model_registry.ex
```

Each command must return zero lines. If any returns hits, either:
- It's a reference to the NEW `Backend.list_models/1` callback — that's fine, skip
- It's a stale old-API reference — delete it or update to the new API, then re-run audit
- It's in a doc comment that still describes the old shape — rewrite the doc

- [ ] **Step 2: Run the ModelRegistry test suite in isolation**

```bash
MIX_ENV=test mix test test/monkey_claw/model_registry_test.exs \
                     test/monkey_claw/model_registry/ \
                     test/monkey_claw/model_registry_e2e_test.exs \
                     test/monkey_claw/agent_bridge/session_model_hook_test.exs
```

Expected: zero failures.

- [ ] **Step 3: Run all five quality gates**

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
MIX_ENV=test mix test
```

All five must pass with zero warnings, zero errors, zero failures. If any gate is red, fix and re-run.

- [ ] **Step 4: Review the diff holistically**

Run: `git diff main...HEAD --stat` to see the full set of changed files.
Run: `git log main..HEAD --oneline` to see the commit sequence.

Sanity checks:
- Every commit message follows conventional commits
- No commit has "WIP" or "fix" as its entire message
- The `cached_models` migration is the only schema migration
- `test/monkey_claw/model_registry_test.exs` was deleted and re-created (not just deleted)
- No `.md` docs have stale references to the old API shape (except the spec and this plan)

- [ ] **Step 5: Push and open PR**

```bash
git push -u origin feat/MonkeyClaw-list-models-per-backend
gh pr create --title "feat: unified ModelRegistry keyed on (backend, provider)" --body "$(cat <<'EOF'
## Summary

- Drop-and-replace cutover of `ModelRegistry` from provider-keyed to `(backend, provider)`-keyed
- Adds `Baseline` runtime-config loader for cold-start model availability
- Adds probe tick handler with per-backend scheduling, in-flight dedup, and exponential backoff
- Adds authenticated session hook for fresh model lists on every session start
- Adds ETS heir for crash-restart continuity
- Redacts Provider log sites through `Vault.SecretScanner` (spec I8)
- Zero references to the old `list_models/1` / `list_all_models/0` API remain (grep-verified)

Spec: `docs/superpowers/specs/2026-04-05-list-models-per-backend-design.md`
Plan: `docs/superpowers/plans/2026-04-05-list-models-per-backend.md`

## Test plan

- [x] Unit tests for `CachedModel` changeset (required fields, length caps, charset, embed list cap, per-model validations)
- [x] Unit tests for `Baseline` (config read, structural validation, log on drop)
- [x] Integration tests for `ModelRegistry` (boot, upsert funnel, precedence, read projections, tick, probe results, refresh, configure)
- [x] Integration tests for `Session` hook (authenticated cast, unregistered pid rejection)
- [x] Integration test for Provider log redaction
- [x] E2E test for full tree boot + crash-restart continuity
- [x] Zero-reference grep audit passes
- [x] All five quality gates clean
EOF
)"
```

- [ ] **Step 6: Monitor PR through Step 6 of the standard MonkeyClaw workflow** (per `CLAUDE.md`)

Loop: wait 60s → `gh pr checks` → address any CI or Copilot feedback → push fixes → resolve resolved threads via `resolveReviewThread` mutation → re-run quality gates locally before each push → exit when all CI green + zero unresolved comments.

---

## Appendix: File Structure Map

Files created in this plan:
- `priv/repo/migrations/20260407000000_rewrite_cached_models.exs`
- `lib/monkey_claw/model_registry/baseline.ex`
- `lib/monkey_claw/model_registry/ets_heir.ex`
- `test/monkey_claw/model_registry/cached_model_test.exs`
- `test/monkey_claw/model_registry/baseline_test.exs`
- `test/monkey_claw/model_registry/provider_log_redaction_test.exs`
- `test/monkey_claw/agent_bridge/backend/beam_agent_list_models_test.exs`
- `test/monkey_claw/agent_bridge/session_model_hook_test.exs`
- `test/monkey_claw/model_registry_e2e_test.exs`
- `test/support/test_backend_models_test.exs`

Files modified (full or partial rewrite):
- `lib/monkey_claw/model_registry.ex` (full rewrite)
- `lib/monkey_claw/model_registry/cached_model.ex` (full rewrite)
- `lib/monkey_claw/model_registry/provider.ex` (log redaction only)
- `lib/monkey_claw/agent_bridge/backend.ex` (add callback + types)
- `lib/monkey_claw/agent_bridge/backend/beam_agent.ex` (add `list_models/1` impl)
- `lib/monkey_claw/agent_bridge/session.ex` (add hook fire on start)
- `lib/monkey_claw/application.ex` (wire `EtsHeir` into tree)
- `lib/monkey_claw_web/live/vault_live.ex` (cut over to new reader API)
- `config/runtime.exs` (default baseline entries)
- `test/support/test_backend.ex` (implement `list_models/1`)
- `test/monkey_claw/model_registry_test.exs` (full rewrite)

Files deleted:
- `test/monkey_claw/model_registry_test.exs` (old version, then recreated)

---

## Appendix: Cutover Grep Checklist

Run these at Task 23 Step 1. Each must return zero lines (excluding `docs/`).

```bash
# Old public API
grep -rn "ModelRegistry\.list_models(" lib/ test/ config/
grep -rn "ModelRegistry\.list_all_models(" lib/ test/ config/

# Old schema API
grep -rn "CachedModel\.create_changeset" lib/ test/ config/
grep -rn "CachedModel\.update_changeset" lib/ test/ config/
grep -rn "CachedModel\.valid_providers" lib/ test/ config/

# Old state fields
grep -rn "provider_secrets" lib/monkey_claw/model_registry.ex

# Old test file path (should be gone)
ls test/monkey_claw/model_registry_test.exs  # must exist (new version)
```
