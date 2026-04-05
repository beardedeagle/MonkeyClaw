# Design: List Models Per Backend

**Date:** 2026-04-05
**Status:** Draft — awaiting user review
**Author:** Brainstorming session
**Related:** `BEAM_AGENT_MONKEYCLAW_ARCHITECTURE_PLAN.md`

## Context

MonkeyClaw has two disconnected systems for reasoning about AI models:

1. **`MonkeyClaw.ModelRegistry`** — a provider-keyed cache (`"anthropic"`,
   `"openai"`, `"google"`, `"github_copilot"`, `"local"`) that fetches model
   lists via HTTP from provider APIs using keys from the vault.

2. **`MonkeyClaw.AgentBridge.Backend`** — a backend-keyed behaviour whose
   implementations wrap agentic CLI coders (`:claude`, `:codex`, `:gemini`,
   `:opencode`, `:copilot`) via beam-agent. Each backend's actual model list
   comes from its CLI subprocess's init handshake, not HTTP.

The autonomous agent needs a unified, low-latency way to answer two questions
at any moment, including cold start before any session exists:

- "What models does **this backend** support?" — for routing queries, picking
  sub-agent targets, or presenting options in the TUI/web UI.
- "What models does **this provider** serve?" — for cost/capability-based
  routing when the agent doesn't care which backend delivers it.

Today, neither question can be answered without starting a session, and the
two systems use incompatible keys (provider vs backend). The agent is a
process-boot-driven autonomous system, not a UI-driven one, so the solution
must populate its cache *before* any user interaction and *without* requiring
live sessions on the critical path.

Future inference backends are coming to beam-agent — inference-provider SDKs
(`:anthropic_sdk`, `:openai_sdk`) and local inference backends (`:ollama`,
`:lmstudio`, `:msty`). A single backend may serve models from multiple
providers (e.g., Copilot routes to OpenAI and Anthropic, Ollama runs
whatever local weights the user has pulled). The design must treat backend
and provider as orthogonal dimensions, not collapse them.

## Goals

- Unified cache keyed by `(backend, provider)`, with fast reads along either axis
- Cold-start availability: the agent can list models the instant the app boots,
  without requiring a live session
- Runtime-extensible: users can add custom backends and override defaults via
  config without rebuilding (MonkeyClaw ships as a pre-compiled release)
- Graceful degradation: provider/probe failures never block the agent
- Manual override: users can force-refresh on demand when they install local
  weights or hear of a new model
- Zero mocks in tests; real supervised processes via test backend adapter
- Defense in depth for data crossing trust boundaries (backend subprocesses,
  HTTP responses, session hook casts)

## Non-Goals

- Per-model audit fields (first-seen, last-seen) — deferred as an auxiliary
  table if needed later
- Queryable capability fields (context window, vision support, etc.) —
  deferred as auxiliary table or secondary index if needed later
- Multi-instance / distributed cache — MonkeyClaw is single-instance
- Streaming model discovery — batch refresh is sufficient for the change
  frequency of model lists

## Design Overview

**One cache, three writers, two read projections, one write funnel.**

The cache is a single SQLite table (with ETS read-through) that stores one
row per `(backend, provider)` pair. Each row holds an embedded list of
models. Three independent writers populate it; reads project either by
backend or by provider. All writes are serialized through the
`ModelRegistry` GenServer and validated at the trust boundary before
touching persistent state.

### Writers

1. **Baseline loader** — runs at boot, synchronous. Reads a static list
   from runtime config and seeds SQLite rows that do not already exist.
   Gives the agent a floor of known models the instant the app comes up.

2. **Probe tick** — a `handle_info(:tick, state)` inside `ModelRegistry`
   itself (not a separate GenServer). The tick handler inspects the last
   probe time for each configured backend and dispatches per-backend
   probe tasks to `MonkeyClaw.TaskSupervisor`. Each task calls
   `backend.list_models(opts)` with a deadline, validates the result, and
   hands it back to the registry via a `GenServer.cast`. This is the
   primary discovery mechanism for accurate real-time data.

3. **`AgentBridge.Session` hook** — opportunistic. When a session starts
   for any reason (user query, sub-agent spawn, experiment run), the
   Session process fires an authenticated async cast to `ModelRegistry`
   with the model list it just observed from the CLI handshake. Costs
   nothing, keeps the cache fresh without extra subprocess spawns.

All three writers funnel through a single `ModelRegistry.upsert/1` internal
function that validates the payload, fans out per provider group (one
backend result may span multiple providers), and performs a conditional
upsert. Precedence is by `(refreshed_at, refreshed_mono)` — whichever
writer wrote most recently wins, with a monotonic tiebreaker for same-ms
races. `source` is for audit only.

### Readers

- `list_for_backend(backend)` — "give me the models this backend supports"
- `list_for_provider(provider)` — "give me every model from this provider,
  across all backends"
- `list_all_by_backend/0` / `list_all_by_provider/0` — bulk projections

Reads hit ETS directly for O(1) latency on the hot path. SQLite is only
read at boot and on ETS miss.

## Schema

### `cached_models` table

```elixir
schema "cached_models" do
  field :backend,         :string       # "claude", "codex", "copilot", ...
  field :provider,        :string       # "anthropic", "openai", "meta", ...
  field :source,          :string       # "baseline" | "probe" | "session"
  field :refreshed_at,    :utc_datetime_usec
  field :refreshed_mono,  :integer      # System.monotonic_time/0 tiebreaker

  embeds_many :models, Model, on_replace: :delete do
    field :model_id,     :string
    field :display_name, :string
    field :capabilities, :map, default: %{}
  end

  timestamps(type: :utc_datetime_usec)
end
```

**Constraints:**

- Primary key: `:id` (UUID, binary)
- Unique: `(backend, provider)`
- Indexes: `backend`, `provider`
- `refreshed_mono` is a BEAM `System.monotonic_time/0` snapshot taken when
  the write is enqueued in the registry. It is only semantically meaningful
  relative to other values written during the same BEAM uptime. The
  conditional upsert SQL does compare it across a restart boundary (the
  stored value may be from a prior BEAM), but cross-restart µs collisions
  on `refreshed_at` are statistically impossible in practice (registry
  restart takes seconds, not microseconds), so the mono comparison is
  effectively never the deciding factor across a restart. `refreshed_at`
  remains the primary sort key. Tiebreaker semantics are documented in
  the "Precedence" section below.

**Changeset invariants enforced at the trust boundary:**

- `backend`, `provider`: required, 1–64 bytes, `String.valid?/1`,
  charset `^[a-z][a-z0-9_]*$`
- `source`: required, one of `"baseline" | "probe" | "session"`
- `refreshed_at`: required
- `refreshed_mono`: required integer
- `models`: required list, `length <= 500`
- Each embedded model:
  - `model_id`: required, 1–256 bytes, `String.valid?/1`, printable ASCII
    + limited unicode (`^[\p{L}\p{N}._\-: /]+$`), no control chars
  - `display_name`: required, 1–256 bytes, same validity/charset as
    `model_id`
  - `capabilities`: map, serialized size capped at 8 KiB post-encode

These are hard-fail validations at the boundary where untrusted data
(backend subprocesses, HTTP responses, session hook casts) enters the
registry. A payload that fails validation is rejected with a logged error
and does not touch SQLite or ETS.

**Shape rationale:**

- Models refresh as a set (the probe always replaces the entire list for a
  `(backend, provider)` pair), so list-per-row is the natural write shape.
- Dominant reads are "list for backend" or "list for provider" — set queries
  that map to single-row lookups with this schema.
- Atomic refresh: `embeds_many` with `on_replace: :delete` lets the whole list
  be replaced in one operation, no stale-deletion dance.
- ETS cache mirrors the shape directly — no denormalize/renormalize step.
- Per-model metadata beyond `display_name` and `capabilities` stays deferred;
  richer queries can be added as auxiliary tables without touching this one
  ("system of record + projections" pattern).

### Row cardinality

Row count is bounded by `(backend, provider)` combinations in use. For the
currently-known set of five backends, expected cardinality is ~5–15 rows
total. Multi-provider backends (e.g., Copilot serving OpenAI + Anthropic)
produce multiple rows — one per provider — which is the intended grouping.
SQLite and ETS both handle this with zero concern. The 500-models-per-list
cap is a sanity guard, not an anticipated volume; real lists are ~10–50
models.

## Components

### `MonkeyClaw.ModelRegistry.Baseline` *(new, thin runtime-config reader)*

Reads baseline entries from `Application.get_env/2`. Ships with sane
defaults in `config/runtime.exs`; users override via config without
rebuilding the release.

```elixir
# config/runtime.exs
config :monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
  entries: [
    %{backend: "claude",  provider: "anthropic", models: [...]},
    %{backend: "codex",   provider: "openai",    models: [...]},
    %{backend: "gemini",  provider: "google",    models: [...]},
    # Users add entries for local/custom backends here
  ]
```

**API:**

- `all/0` — returns the validated configured entries
- `load!/0` — invoked once at `ModelRegistry` init, validates every entry
  against the same embedded-changeset rules used for probe writes
  (C2 trust boundary). An invalid baseline is a configuration error and
  is logged with the specific field failure; the affected entry is
  skipped, and the registry continues with the remaining valid entries.

Zero runtime state. Pure config reader with validation. Users override by
editing `runtime.exs` or passing environment-specific config.

### `MonkeyClaw.ModelRegistry` *(existing GenServer, refactored)*

Owns the ETS table ownership (via heir transfer from `Application`, see
C4 below) and SQLite cache. Serializes all writes. Merges the probe
scheduler and the probe dispatcher into a single state machine with one
tick handler — no separate Probe GenServer.

**State:**

```elixir
%State{
  ets_table:         :ets.tid(),
  default_interval:  pos_integer(),
  backend_intervals: %{String.t() => pos_integer()},
  backends:          [String.t()],
  workspace_id:      Ecto.UUID.t() | nil,
  backend_configs:   %{String.t() => map()},
  last_probe_at:     %{String.t() => integer()},   # monotonic ms
  in_flight:         %{reference() => String.t()}, # task ref → backend
  backoff:           %{String.t() => pos_integer()}, # next retry delay ms
  tick_timer_ref:    reference() | nil
}
```

**Boot sequence:**

1. ETS table is already created by `Application.start/2` (see C4); the
   registry takes ownership via the `{'ETS-TRANSFER', tid, _, _}` message
   at the start of `handle_continue(:init_state, ...)`.
2. Attempt to load rows from SQLite via `Repo.all/1`:
   - **Success + rows present** — populate ETS, skip baseline seed.
   - **Success + empty table** — run baseline seed through the normal
     upsert path, populate ETS from the persisted baseline.
   - **Repo unavailable** (C5) — log warning, seed ETS directly from
     `Baseline.load!/0` without going to SQLite, enter a "degraded"
     sub-state; retry the initial SQLite load on the first tick.
3. Seed `last_probe_at` to `:never` for every configured backend.
4. Schedule the first tick at `@startup_delay_ms` (default 5s).

The registry never crashes on a boot-time Repo failure. The agent always
has *some* cache to read, even if it is baseline-only.

**Write API (internal):**

- `upsert(writes :: [upsert_write()])` — the single write funnel. Each
  `upsert_write` is `%{backend, provider, source, refreshed_at,
  refreshed_mono, models}`. The function:
  1. Validates every write via the changeset (C2)
  2. Runs one multi-row transaction against SQLite
  3. For each row, performs a conditional upsert:
     `ON CONFLICT (backend, provider) DO UPDATE SET ... WHERE
     EXCLUDED.refreshed_at > cached_models.refreshed_at
     OR (EXCLUDED.refreshed_at = cached_models.refreshed_at
     AND EXCLUDED.refreshed_mono > cached_models.refreshed_mono)` (C1)
  4. Updates ETS only for rows that actually won the conditional upsert
  5. Returns `{:ok, [applied_write()]}` or `{:error, reason}`

This is the ONLY path into the cache. Every source funnels through it.

**Read API (public):**

- `list_for_backend(backend)` → `[enriched_model()]`
- `list_for_provider(provider)` → `[enriched_model()]`
- `list_all_by_backend/0` → `%{String.t() => [enriched_model()]}`
- `list_all_by_provider/0` → `%{String.t() => [enriched_model()]}`

Where `enriched_model()` is a self-describing map that embeds the backend
and provider alongside the model fields:

```elixir
@type enriched_model :: %{
        backend:      String.t(),
        provider:     String.t(),
        model_id:     String.t(),
        display_name: String.t(),
        capabilities: map()
      }
```

Self-describing return shape avoids tuple destructuring on the caller side
and ensures every returned model carries full provenance. This is
critical for multi-provider backends where a single backend's model list
spans multiple providers (e.g., `list_for_backend("copilot")` returns
both OpenAI and Anthropic models, each correctly tagged).

**Argument normalization:** `backend` arguments accept both atoms
(`:claude`) and strings (`"claude"`); the API normalizes via
`to_string/1` internally before hitting ETS or SQLite (which store
strings per the schema). `provider` arguments are strings only, since
providers are identified by canonical string names and never enumerated
as atoms anywhere in the beam-agent ecosystem.

**Runtime control API (kept, re-keyed from provider to backend):**

- `refresh(backend)` — force-probe one backend on demand; bypasses the
  tick schedule. Blocks the caller (GenServer.call, 30s timeout) until
  the probe task completes or fails.
- `refresh_all/0` — force-probe every configured backend sequentially.
  GenServer.call timeout is computed as
  `length(backends) * per_backend_timeout + buffer` (I5), default ceiling
  120s, so it scales with the configured backend set.
- `configure(opts)` — update runtime config without restart. Validates
  every option before applying (I1): intervals must be positive integers,
  `backends` must be a list of binaries, `backend_intervals` values must
  be `>= default_interval`, `backend_configs` must be a map. Invalid opts
  return `{:error, {:invalid_option, key, reason}}` and leave state
  unchanged.

**Tick handler (`handle_info(:tick, state)`):**

1. For each backend in `state.backends`:
   - Skip if there is already an in-flight probe task for it
   - Compute `elapsed = now_mono - (last_probe_at[backend] || 0)`
   - Compute `personal_interval = backend_intervals[backend] || default_interval`
   - If `elapsed >= personal_interval`: dispatch a probe task
2. Reschedule the next tick at `default_interval`.

**Probe task dispatch:**

```elixir
task =
  Task.Supervisor.async_nolink(MonkeyClaw.TaskSupervisor, fn ->
    deadline_ms = Map.get(state.backend_configs, backend, %{})
                  |> Map.get(:probe_deadline_ms, 15_000)
    do_probe(backend, state.backend_configs[backend], deadline_ms)
  end)
```

The task result is awaited on a separate GenServer flow (`handle_info
{ref, result}` and `handle_info {:DOWN, ref, ...}`) — the registry never
blocks on a probe. Tasks carry a hard deadline (`Task.yield/2` +
`Task.shutdown(task, :brutal_kill)` if exceeded, I3) so a misbehaving
backend cannot stall the scheduler.

**Runtime config:**

```elixir
config :monkey_claw, MonkeyClaw.ModelRegistry,
  # Default interval is the scheduler's tick rate and the FLOOR cadence
  # for every backend — it represents the SHORTEST refresh interval any
  # shipped backend needs. Per-backend overrides can only slow individual
  # backends DOWN from the floor. Ship value is 24h because the initial
  # backend set is cloud-only. When local backends (Ollama, LM Studio,
  # Msty) land, drop this to their shortest interval (likely 1h) and
  # override cloud backends upward below.
  default_interval_ms: :timer.hours(24),
  backend_intervals: %{
    # Optional per-backend overrides. Each value must be
    # >= default_interval_ms (enforced by configure/1 and init).
  },
  backends: ["claude", "codex", "gemini", "opencode", "copilot"],
  backend_configs: %{
    # Per-backend config passed to Backend.list_models/1 in opts.
    # Typically includes :workspace_id and :secret_name for vault
    # resolution, plus optional :probe_deadline_ms override.
    "claude" => %{
      workspace_id: "<UUID>",
      secret_name: "anthropic_key",
      probe_deadline_ms: 15_000
    }
  }
```

### `MonkeyClaw.AgentBridge.Backend` *(existing behaviour, extended)*

Add one new callback that does **not** require a live session pid (D2):

```elixir
@type list_models_opts :: %{
        optional(:workspace_id)     => Ecto.UUID.t(),
        optional(:secret_name)      => String.t(),
        optional(:probe_deadline_ms) => pos_integer(),
        optional(atom())             => term()  # backend-specific keys
      }

@type model_attrs :: %{
        provider:     String.t(),
        model_id:     String.t(),
        display_name: String.t(),
        capabilities: map()
      }

@callback list_models(list_models_opts()) ::
            {:ok, [model_attrs()]} | {:error, term()}
```

The callback:

- Takes an `opts` map, not a session pid. Adapters decide internally how
  to satisfy the request — by calling the provider HTTP API directly, by
  spawning a transient CLI subprocess for an init handshake, or by
  reading a local binary's manifest. The registry does not care.
- Returns a flat list of `model_attrs` maps, each carrying its own
  `provider`. A single backend may return models from multiple providers
  in one list (e.g., Copilot returns OpenAI + Anthropic models). The
  registry groups by `provider` at write time and fans out into multiple
  `(backend, provider)` rows (D3).
- Is expected to respect its own internal deadline. The task wrapper
  enforces a hard outer deadline via `Task.shutdown/2` as a safety net.

**Implementations:**

- `MonkeyClaw.AgentBridge.Backend.BeamAgent` — delegates to
  `BeamAgent.Catalog.supported_models/1` with credentials resolved via
  the vault at call time. Plaintext is scoped to the adapter function
  and never enters the registry state.
- `MonkeyClaw.AgentBridge.Backend.Test` — returns configured stub data.
  Used by all integration tests. Supports per-call programmable
  responses (success, `{:error, _}`, delay, crash) for deterministic
  failure-path testing.

The Session process does not need to know how each backend fetches its
model list — the behaviour abstracts it. Future SDK and local backends
implement the same callback without changing the registry.

### `MonkeyClaw.AgentBridge.Session` *(existing, extended)*

After a successful `start_session`, the Session process fires an
**authenticated** async cast to `ModelRegistry` with the freshly observed
models tagged `source: "session"`.

**Authentication (C3):**

- Sessions register themselves in `MonkeyClaw.AgentBridge.Registry`
  (the existing session registry) at start time.
- The session hook cast carries the session's own pid.
- `ModelRegistry.handle_cast({:session_hook, pid, payload}, state)`
  verifies the pid is a live, registered session via
  `Registry.keys/2`. Unregistered or dead pids are ignored with a debug
  log.
- The payload still goes through the same validation path as probe writes
  (C2). A compromised or buggy session cannot inject arbitrary model
  data; it can only inject *validated* model data tagged against *its
  own* observed handshake.

Fire-and-forget from the Session's perspective — a hook failure never
blocks session start or affects the session lifecycle.

## Supervision Tree

```
MonkeyClaw.Supervisor
├── Repo
├── MonkeyClaw.TaskSupervisor        (existing; probe tasks dispatched here)
├── Vault
├── ModelRegistry                    (GenServer, owns ETS via heir + SQLite)
└── AgentBridge.Supervisor
    ├── AgentBridge.Registry         (session pid registry, existing)
    └── DynamicSupervisor for Sessions
```

**ETS ownership via heir (C4):** `Application.start/2` creates the
`:monkey_claw_model_registry` ETS table with `heir: {self(), :model_registry}`
before starting the supervision tree, then transfers ownership to the
`ModelRegistry` GenServer via `:ets.give_away/3` immediately after the
GenServer starts. If the registry crashes, the ETS table survives (owned
by the Application bootstrap process as heir) and is re-transferred to
the restarted registry via the `{'ETS-TRANSFER', ...}` message. Read
consumers never see a missing table during a registry restart.

**Startup order:** `Repo` → `TaskSupervisor` → `Vault` → `ModelRegistry`
→ `AgentBridge.Supervisor`. The registry must be up before any session
can fire a hook cast. Sessions that start during the brief window before
the registry is ready will skip the hook (their cast to a missing
registered name is a no-op).

## Data Flow

### Cold start (empty SQLite)

1. `Application.start/2` creates ETS table with heir
2. `Repo` starts
3. `ModelRegistry` starts → receives `ETS-TRANSFER` → loads SQLite →
   empty → runs `Baseline.load!/0` → validates every entry → passes to
   `upsert/1` → writes baseline rows to SQLite → populates ETS
4. `AgentBridge.Supervisor` starts → sessions can begin
5. Agent begins operating using baseline data (immediately responsive)
6. +5s: tick fires → dispatches one probe task per backend → each task
   calls `backend.list_models(opts)` → validated results land in ETS
   via conditional upsert (C1). Writers with older timestamps are
   rejected automatically; the most recent probe wins.
7. Every `default_interval_ms` (or per-backend override): periodic tick
   fires, same path.

### Warm start (SQLite has prior data)

Same as cold start except step 3 loads rows from SQLite instead of
seeding baseline. Baseline is then consulted for **delta entries** (I6):
any `(backend, provider)` present in `Baseline.all/0` but absent in
SQLite is inserted via the same conditional upsert. Rows already in
SQLite are never touched by baseline — the conditional upsert rejects
any baseline write whose `refreshed_at` is older than the stored value.

The first tick still fires at +5s to refresh potentially stale data.

### Query path (hot)

```
agent → ModelRegistry.list_for_backend("claude")
     → :ets.lookup(:monkey_claw_model_registry, {:by_backend, "claude"})
     → return [enriched_model, ...]
```

Steady state is O(1) ETS lookup. SQLite is only touched on boot and on
ETS miss (which should only happen during the startup window).

### Write paths

All three writers end at `ModelRegistry.upsert/1`, which:

1. Validates every entry via the embedded changeset (C2). Invalid
   entries are dropped with a logged error; valid entries proceed.
2. Groups entries by `(backend, provider)` — one backend probe can fan
   out into multiple rows (D3).
3. Opens one `Repo.transaction/1`.
4. For each group, performs the conditional upsert (C1). Entries whose
   `(refreshed_at, refreshed_mono)` is not strictly greater than the
   stored tuple are skipped.
5. Returns the list of rows that actually changed.
6. Updates ETS only for changed rows.

**Source tags:**

- **Baseline**: synchronous, one shot at boot (plus delta seeding on
  warm start), `source: "baseline"`. `refreshed_at` is boot time or
  config modification time.
- **Probe**: async via `Task.Supervisor`, per backend, `source: "probe"`.
  `refreshed_at` is the time the probe task completed successfully.
- **Session**: authenticated async cast from `AgentBridge.Session`, per
  session start, `source: "session"`. `refreshed_at` is the time the
  Session observed the handshake.

### Precedence

Strict ordering: `refreshed_at` DESC, then `refreshed_mono` DESC. The
monotonic tiebreaker (I4) only matters when two writes land in the same
`utc_datetime_usec` bucket, which is rare but possible within a single
BEAM uptime under load. The conditional upsert SQL compares `refreshed_mono`
unconditionally whenever `refreshed_at` ties, including across a restart
boundary where the stored value was written by a prior BEAM. This is
safe in practice because cross-restart µs collisions on `refreshed_at`
cannot meaningfully occur: registry restart takes seconds, and any new
write after a restart is strictly later in wall-clock time than the last
pre-restart write. The mono comparison is therefore effectively only
the deciding factor for same-uptime µs collisions. On restart, the
persisted `refreshed_at` remains authoritative and the new in-memory
`refreshed_mono` starts from a fresh `System.monotonic_time/0` origin.

`source` is retained for audit and observability, never for precedence.

### On-demand refresh

```
user → ModelRegistry.refresh("claude")
     → GenServer.call(registry, {:refresh, "claude"}, 30_000)
     → registry dispatches an immediate probe task via TaskSupervisor
     → registry awaits the task result inline (blocking this call only)
     → returns :ok on success, {:error, reason} on failure or timeout
```

`refresh_all/0` iterates all configured backends sequentially via
repeated `refresh/1` calls. Failures are logged but don't abort the
iteration. The GenServer.call timeout is computed from the backend count
times the per-backend timeout plus a buffer (I5).

## Error Handling

| Failure | Response |
| --- | --- |
| `Baseline.load!/0` returns empty | Log warning, proceed with empty cache; probe will populate |
| `Baseline.load!/0` has invalid entry | Log error with field failure, skip entry, continue with remaining valid entries |
| SQLite load at boot | Log warning, fall back to `Baseline.load!/0` seed into ETS only (C5); retry SQLite load on next tick |
| Probe task crash | `async_nolink` prevents propagation; task ref `DOWN` triggers backoff and logging |
| Probe task timeout | `Task.yield` returns `nil` → `Task.shutdown(task, :brutal_kill)` → backoff on that backend (I3) |
| `backend.list_models/1` returns `{:error, _}` | Log warning, keep stale cache, apply exponential backoff 5s→5m cap |
| `backend.list_models/1` raises | Caught by Task, task ref `DOWN` with reason, same backoff path |
| Session hook cast from unregistered pid | Ignored with debug log (C3) |
| Session hook cast with invalid payload | Rejected by changeset validation (C2), logged |
| ETS table missing (registry crash) | Heir owns table; restarted registry receives ETS-TRANSFER (C4) |
| Repo unavailable mid-operation | Write returns `{:error, reason}`; ETS not updated; caller sees failure; retry on next tick |
| `configure/1` with bad opts | `{:error, {:invalid_option, key, reason}}`, state unchanged (I1) |

**Principle:** the agent is never blocked by model discovery. Baseline
guarantees a floor; probe and session hooks refine asynchronously. No
single failure mode can crash the registry or the agent.

Blanket `rescue` is avoided — each failure mode is handled at a specific
trust boundary (Task boundary, GenServer handle_cast boundary, HTTP
client boundary inside the adapter). Supervision handles the rest.

## Security

MonkeyClaw is secure-by-default; model discovery runs early, talks to
untrusted subprocesses, and handles vault-resolved credentials. The
design's security posture rests on four invariants:

**Invariant 1 — Credentials never enter ModelRegistry state.**
The registry state holds `backend_configs: %{backend => %{workspace_id,
secret_name, ...}}` — secret *names*, not plaintext. Plaintext is
resolved inside `Backend.list_models/1` by the adapter, lives only in
the adapter function's lexical scope during the HTTP call, and falls out
of scope when the call returns. This matches the existing vault
invariant ("The AI model never sees plaintext secret values").

**Invariant 2 — All untrusted data is validated at the trust boundary
before touching persistent state.**
Every path into `upsert/1` — baseline config, probe results, session
hook casts — passes through the same `CachedModel` embedded changeset
with its hard-fail length, charset, and structural checks (C2). Data
that does not validate is rejected with a logged error and never
reaches SQLite or ETS. Lengths are bounded so a malicious or buggy
backend cannot exhaust memory via a billion-model response.

**Invariant 3 — Session hook writes are authenticated.**
The registry only accepts session hook casts from pids that are
currently registered in `AgentBridge.Registry` (C3). A random process
cannot inject model data. A compromised session can only inject
*validated* data about its own handshake.

**Invariant 4 — Provider log sites must not leak response bodies
containing credentials** (I8).
`MonkeyClaw.ModelRegistry.Provider` currently logs non-2xx responses
and request failures with `inspect(body)` / `inspect(reason)`. If an
upstream API ever echoes an auth header back in an error body, or if
Req's error struct includes the original request headers, that inspect
call leaks the key. This spec requires the Provider module to redact
response bodies and error reasons through `MonkeyClaw.Vault.SecretScanner`
(or an equivalent header-stripping helper) before logging. This is a
targeted Provider fix — the `%Secret{}` opaque-wrapper approach is
**not** introduced by this spec because ModelRegistry never holds
plaintext in state, so there is no inspect/crash-dump exposure to
guard against. If a future component ever needs to hold plaintext in
process state, an opaque wrapper belongs in `MonkeyClaw.Vault`, not in
a feature module.

## Testing

Integration-first per project standards, zero mocks. All tests use real
supervised processes, real ETS (sandbox via Application-started table),
and sandbox SQLite.

### Unit

- **`Baseline`** — validates config shape, required keys per entry,
  invalid entries rejected by changeset with clear error
- **`CachedModel` changeset** — every invariant from Schema section
  (length caps, charset, embedded list cap, required fields)

### Integration

- **`ModelRegistry` read/write**
  - Sandbox SQLite + real ETS owned by test-spawned `Application`-like
    bootstrap
  - `upsert/1` with each source type; verify conditional precedence by
    `(refreshed_at, refreshed_mono)`
  - Verify stale write is rejected by conditional upsert even when the
    source is higher-prestige (e.g., stale probe does not overwrite
    fresh session hook)
  - All four read projections return expected shape with `enriched_model`
  - Boot with empty SQLite seeds from Baseline
  - Boot with populated SQLite skips existing rows, delta-seeds new
    baseline entries only (I6)
  - Boot with unavailable Repo falls back to baseline-only ETS (C5)
  - `refresh/1`, `refresh_all/0`, `configure/1` all function; bad
    `configure/1` opts are rejected (I1)

- **Probe tick logic (inside `ModelRegistry`)**
  - Real GenServer against `AgentBridge.Backend.Test`
  - Verify first tick fires at `@startup_delay_ms`
  - Verify periodic tick fires at `default_interval_ms`
  - Verify per-backend interval overrides slow backends down (fast tick
    still fires but that backend is skipped)
  - Verify `{:error, _}` from backend triggers backoff, keeps stale cache
  - Verify probe task timeout triggers `Task.shutdown` and backoff (I3)
  - Verify `refresh/1` bypasses schedule and writes immediately
  - Verify in-flight probe deduplication (concurrent tick + refresh for
    the same backend doesn't spawn two tasks)

- **`AgentBridge.Session` hook**
  - Extend existing session test suite
  - Start session via `Backend.Test`, assert hook cast fires with
    authenticated pid
  - Assert rows land in `ModelRegistry` with `source: "session"`
  - Assert session start succeeds even if hook write fails
  - Assert unregistered-pid cast is rejected (C3)

- **ETS heir transfer**
  - Start Application, crash ModelRegistry, verify ETS table survives
    and restarted registry receives `ETS-TRANSFER`
  - Verify read consumers observe continuity across the restart

- **Provider log redaction (I8)**
  - Craft upstream responses containing known secret-like patterns,
    verify `Provider`'s log output is redacted

### End-to-End

- One E2E test boots the full supervision tree with `Backend.Test`
- Asserts `list_for_backend("claude")` returns expected models after
  probe completes
- Asserts `list_for_provider("anthropic")` returns the union across
  backends (multi-provider fan-out from D3)
- Asserts on-demand `refresh("claude")` produces updated rows immediately
- Asserts a crash + restart of `ModelRegistry` leaves the cache intact
  (heir + SQLite)

## Cutover

MonkeyClaw is greenfield with zero users. This section is a full
drop-and-replace cutover, not a transition. **Every item below is a
complete replacement — no code from the current implementation
survives except `MonkeyClaw.ModelRegistry.Provider`, which remains in
place unchanged as the HTTP foundation for the `BeamAgent` adapter
(with log-redaction added per I8). No dual-path code, no compatibility
shims, no deprecated functions left behind. After this cutover lands,
a grep of the codebase must show zero references to the old
provider-keyed API (`list_models/1`, `list_all_models/0`) and zero
dead code from the old schema shape.**

1. **New Ecto schema migration:**
   - Drop current `cached_models` table
   - Create new `cached_models` with schema above
   - Unique constraint on `(backend, provider)`
   - Indexes on `backend` and `provider` individually
   - Add `refreshed_mono :integer NOT NULL` column

2. **Rewrite `MonkeyClaw.ModelRegistry.CachedModel` from scratch:**
   - New field set with `(backend, provider)` as the unique dimension
   - `embeds_many :models` with embedded `Model` schema
   - Changesets enforce every invariant from the Schema section (C2)
   - Delete the `@providers` constant; validation moves to runtime config
   - Delete the old `create_changeset/2` and `update_changeset/2`
     signatures — they are replaced with the new shape, not extended

3. **Rewrite `MonkeyClaw.ModelRegistry` GenServer:**
   - Replace provider-keyed `list_models/1` and `list_all_models/0` with
     backend- and provider-keyed projections
   - Keep `refresh/1`, `refresh_all/0`, `configure/1` with new keying;
     add validation to `configure/1` (I1)
   - Add internal `upsert/1` write funnel with conditional upsert (C1),
     per-provider fan-out (D3), and changeset validation (C2)
   - Add Baseline integration at boot, plus delta seeding on warm start (I6)
   - Add tick handler with per-backend interval logic and in-flight
     deduplication
   - Add `handle_info({ref, result}, ...)` and `handle_info({:DOWN, ...})`
     for probe task result handling with backoff
   - Handle `{'ETS-TRANSFER', ...}` at init for heir-based ETS ownership (C4)
   - Handle Repo-unavailable boot via degraded sub-state (C5)

4. **Add `MonkeyClaw.ModelRegistry.Baseline` module** and its
   `config/runtime.exs` entries with validation via the CachedModel
   changeset

5. **Create ETS table in `Application.start/2`** with heir before
   starting the supervision tree; transfer ownership to the registry
   once it starts (C4)

6. **Extend `MonkeyClaw.AgentBridge.Backend` behaviour** with
   `list_models/1` callback taking an `opts :: map()` (D2); return type
   includes `:provider` on each `model_attrs` (D3); implement in
   `BeamAgent` and `Test` adapters

7. **Extend `MonkeyClaw.AgentBridge.Session`** with authenticated
   post-start hook (C3), fire-and-forget semantics

8. **Update `vault_live.ex`** (current consumer) to use the new reader
   API. Delete every call to the old `ModelRegistry.list_all_models/0`
   and `ModelRegistry.list_models/1` and replace with
   `list_all_by_provider/0` / `list_for_provider/1`. After this change,
   grepping for the old function names must return zero hits outside
   of this spec document.

9. **`MonkeyClaw.ModelRegistry.Provider` HTTP module:**
   - Contract-wise untouched — the `BeamAgent` adapter still uses it for
     HTTP-only backends. Stays in place as the HTTP foundation that
     future SDK backends will reuse or replace at their own pace.
   - **Log redaction added (I8):** all `Logger.warning` sites that
     currently do `inspect(body)` / `inspect(reason)` must sanitize
     through `MonkeyClaw.Vault.SecretScanner` (or an equivalent
     header-stripping helper) before inspection.

## Open Questions

None. Design decisions locked during brainstorming and multi-perspective
review:

- **Schema** keyed on `(backend, provider)` with embedded `models` list,
  plus `refreshed_mono` tiebreaker
- **Three writers, single upsert funnel**, conditional upsert with
  `(refreshed_at, refreshed_mono)` precedence
- **Baseline as runtime config**, validated through the same changeset
  as probe writes
- **Probe merged into `ModelRegistry`** as a tick handler; no separate
  GenServer (D1)
- **`Backend.list_models(opts :: map())`**, not a session pid (D2)
- **`:provider` on each `model_attrs`**, upsert fans out per provider
  group (D3)
- **Tick rate = shortest interval any shipped backend needs** (24h
  initially, cloud-only); per-backend overrides can only slow
  individual backends down, never up
- **Refresh/configure surface retained** for runtime extensibility, with
  validation on configure
- **`ModelRegistry.Provider` HTTP module retained** until SDK backends
  land, with log redaction added
- **ETS via heir pattern** for crash survival; `:protected` access
- **Session hook authenticated via `AgentBridge.Registry`** lookup
- **No `%Secret{}` wrapper in this spec** — not needed because plaintext
  never enters registry state; if a future component needs one, it
  belongs in `MonkeyClaw.Vault`

## Next Steps

1. User review of this revised spec
2. On approval, invoke `writing-plans` skill to produce detailed
   implementation plan
3. Implementation via standard MonkeyClaw task execution workflow
   (branch → implement → verify → PR → monitor)
