# MonkeyClaw

A secure-by-default personal AI assistant built on the BEAM.
OTP-native, fault-tolerant, and distributed by design.

> A *Claw* clone that utilizes BeamAgent to allow for TOS-compliant,
> subscription-based account usage. A cautionary tale proving that
> technical adherence to the letter of a request is the most effective
> way to subvert its intended restrictions. *"Be careful what you wish
> for..."*

## Why MonkeyClaw?

The AI assistant product category is proven, but existing solutions
have catastrophic security postures. MonkeyClaw delivers the same
capabilities with security built into the platform, not patched on top.

- **Secure by default** — Default-deny policy, process isolation, no
  implicit system access. Security comes from the BEAM, not patches.
- **OTP supervision** — Every agent is a supervised process. Crashes are
  isolated, recovered, and audited automatically.
- **Distributed** — Single user, multiple nodes. Run agents across
  machines with encrypted BEAM distribution.
- **Extensible** — Plug-based extension model for application-level
  capabilities, plus agent-level MCP, skills, and plugins via BeamAgent.
- **Streaming** — Real-time token-by-token response delivery through the
  full stack, from BeamAgent through to LiveView progressive rendering.
- **Multi-agent** — Five AI backend adapters (Claude, Codex, Gemini,
  OpenCode, Copilot) via BeamAgent, with unified session management.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Workflow Layer                                      │
│  MonkeyClaw.Workflows — conversation recipes         │
├─────────────────────────────────────────────────────┤
│  Product Layer                                       │
│  MonkeyClaw — assistants · workspaces · experiments  │
│  scheduling · user modeling �� webhooks · notifs ·    │
│  channels · vault · model registry                   │
├─────────────────────────────────────────────────────┤
│  Extension Layer                                    │
│  Plug pipelines — hooks · contexts · pipelines      │
├─────────────────────────────────────────────────────┤
│  Agent Bridge                                       │
│  Backend behaviour · Session GenServer · Telemetry   │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│  Elixir API                                         │
│  beam_agent_ex — sessions · threads · memory        │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│  Runtime Substrate                                  │
│  BeamAgent — orchestration · audit · transports     │
└─────────────────────────────────────────────────────┘
```

MonkeyClaw is the product layer. BeamAgent is the runtime substrate.
Clean separation of concerns, connected through a public Elixir API.

### Domain Model

| Concept       | Module                            | Purpose                                           |
|---------------|-----------------------------------|---------------------------------------------------|
| **Assistant** | `MonkeyClaw.Assistants.Assistant` | AI persona — name, model, system prompt, provider |
| **Workspace** | `MonkeyClaw.Workspaces.Workspace` | Project container, maps 1:1 to a BeamAgent session |
| **Channel**   | `MonkeyClaw.Workspaces.Channel`   | Conversation thread within a workspace            |
| **Plug**      | `MonkeyClaw.Extensions.Plug`      | Extension behaviour — `init/1` + `call/2` on a context |
| **Context**   | `MonkeyClaw.Extensions.Context`   | Data struct flowing through extension pipelines   |
| **Pipeline**  | `MonkeyClaw.Extensions.Pipeline`  | Compiled, ordered chain of plugs for a hook point |
| **Workflow**  | `MonkeyClaw.Workflows.Conversation` | Product-level orchestration recipe              |
| **Experiment**| `MonkeyClaw.Experiments.Experiment`  | Bounded optimization loop with strategy-driven iteration |
| **Recall**    | `MonkeyClaw.Recall`                  | Cross-session history search and context injection |
| **Skills**    | `MonkeyClaw.Skills`                  | Reusable procedures extracted from successful experiments with FTS5 search and effectiveness scoring |
| **Scheduling**| `MonkeyClaw.Scheduling`              | Timed experiment runs — once or recurring — with status lifecycle and run tracking |
| **UserModeling**| `MonkeyClaw.UserModeling`          | Privacy-aware observation of user interactions, topic extraction, and injectable context for personalized queries |
| **Webhooks**  | `MonkeyClaw.Webhooks`                | Multi-source webhook ingress (16 built-in sources) with source-specific signature verification, replay detection, rate limiting, and async agent dispatch |
| **Notifications** | `MonkeyClaw.Notifications`       | Event-driven notification system — routes telemetry events to user-facing alerts via PubSub (real-time) and email (async), with workspace-scoped rules, severity thresholds, and ETS-cached routing |
| **Channels** | `MonkeyClaw.Channels`                    | Bi-directional platform adapters — Slack, Discord, Telegram, WhatsApp, Web — with adapter behaviour, message recording, webhook verification, and async agent dispatch |
| **Vault** | `MonkeyClaw.Vault`                           | Encrypted secret and OAuth token storage with `@secret:name` opaque references — model never sees plaintext; AES-256-GCM encryption at rest with HKDF-derived keys |
| **ModelRegistry** | `MonkeyClaw.ModelRegistry`             | Periodic provider model list cache — GenServer with SQLite persistence, ETS write-through, and configurable refresh intervals |

Contexts (`MonkeyClaw.Assistants`, `MonkeyClaw.Workspaces`, `MonkeyClaw.Webhooks`, `MonkeyClaw.Notifications`, `MonkeyClaw.Channels`, `MonkeyClaw.Vault`) provide the
public CRUD API. `MonkeyClaw.AgentBridge` translates domain objects into
BeamAgent session and thread configurations. `MonkeyClaw.Workflows`
composes these into user-facing operations.

### Extensions

Plug-based extension system for application-level capabilities. Plugs
use the `init/1` + `call/2` pattern on a context struct — the same
contract as `Plug.Conn`, applied to MonkeyClaw lifecycle events instead
of HTTP requests. Extensions do not replace agent-level MCP, skills, or
plugins, which flow through BeamAgent.

Sixteen hook points span queries, sessions, workspaces, channels,
and experiments.
Global plugs run on every event; hook-specific plugs run only on their
declared hook. Pipelines are compiled once at application start and
cached in `:persistent_term` for zero-overhead runtime lookups.

### Workflows

Workflows are product-level recipes that compose domain entities, agent
sessions, and extension hooks into cohesive user-facing operations. The
`Conversation` workflow implements the canonical "talk to an agent" flow:

1. Load workspace and assistant from the database
2. Ensure a BeamAgent session is running
3. Find or create the conversation channel and thread
4. Fire `:query_pre` extension hooks (plugs can halt or enrich)
5. Send the query through AgentBridge
6. Fire `:query_post` extension hooks
7. Return the result

Workflows are pure function modules — no processes. They orchestrate
existing APIs; generic mechanics stay in BeamAgent.

The `Conversation` workflow also provides `stream_message/4`, which
replaces step 5 with `AgentBridge.stream_query/3` and delivers
response chunks progressively to the caller:

- `{:stream_chunk, session_id, chunk}` — A response fragment
- `{:stream_done, session_id}` — Stream completed successfully
- `{:stream_error, session_id, reason}` — Stream failed

Post-hooks run after the caller has accumulated the full response.

### Experiment Engine

Autonomous, bounded iteration loops for code optimization and other
strategy-driven tasks. The engine runs evaluate-decide cycles over a
BeamAgent session, with full rollback safety and human override gates.

Three-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Strategy** | `MonkeyClaw.Experiments.Strategy` | Domain logic — state, prompts, evaluation, decisions |
| **Runner** | `MonkeyClaw.Experiments.Runner` | Control flow — iteration loop, time budget, persistence |
| **BeamAgent** | `MonkeyClaw.AgentBridge.Backend` | Execution — runs, tools, checkpoints |

Each experiment is a state machine (`created → running → evaluating →
accepted/rejected/halted/cancelled`) driven by a strategy behaviour.
Strategies define how to prepare iterations, build prompts, evaluate
results, and decide whether to continue, accept, reject, or halt.

Features include async execution via `Task.Supervisor.async_nolink`
(GenServer stays responsive for timeouts and cancellation), mutation
scope enforcement (strategy declares allowed files, Runner rejects
out-of-scope changes), optional human decision gates (non-blocking),
automatic BeamAgent checkpoint save/rewind on rollback, configurable
per-experiment time budgets, full telemetry instrumentation, and
defense-in-depth secret scrubbing of strategy state, evaluation
results, and the final experiment result before persistence.

A lifecycle API (`start_experiment/3`, `stop_experiment/1`,
`cancel_experiment/1`, `experiment_status/1`) provides atomic
create-and-start with cleanup on failure, graceful stop, immediate
cancel, and live-or-persisted status queries. Extension hooks fire at
four lifecycle boundaries (`:experiment_started`, `:iteration_started`,
`:iteration_completed`, `:experiment_completed`), and PubSub broadcasts
on `"experiment:#{id}"` topics enable real-time LiveView observation.
The final evaluation result is persisted as `experiment.result` on
completion.

### Cross-Session Recall

Automatic injection of relevant past conversation context into new
agent queries. The recall system searches across all sessions in a
workspace using FTS5, formats matching messages into context blocks,
and prepends them to the agent's prompt.

Three-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Recall** | `MonkeyClaw.Recall` | Query sanitization, search orchestration, result assembly |
| **Formatter** | `MonkeyClaw.Recall.Formatter` | Session-grouped text blocks with character budgets |
| **Plug** | `MonkeyClaw.Recall.Plug` | Extension plug for `:query_pre` automatic injection |

The recall plug hooks into the existing extension pipeline at
`:query_pre`. When a user sends a query, the plug:

1. Extracts keywords from the prompt (sanitized for FTS5)
2. Searches past sessions via FTS5 with temporal/role filtering
3. Formats matches into a context block (grouped by session)
4. Sets `:effective_prompt` with the recalled context prepended

Configuration is via application config alongside other query_pre plugs
(see User Modeling section for the full pipeline configuration).

The search layer supports temporal filtering (`:after`/`:before`),
role filtering (`:roles`), session exclusion (`:exclude_session_id`),
and configurable result limits. All functions are pure (database I/O
aside) — no processes, no state.

### Self-Improving Skills

Reusable procedure library built from accepted experiments. The skills
system extracts proven strategies from the experiment engine, indexes
them for natural language discovery, and injects relevant skills into
agent queries automatically.

Three-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Skills** | `MonkeyClaw.Skills` | Skill CRUD, FTS5 search, effectiveness scoring |
| **Extractor** | `MonkeyClaw.Skills.Extractor` | Auto-extraction from accepted experiments |
| **Plug** | `MonkeyClaw.Skills.Plug` | Extension plug for `:query_pre` automatic injection |

When an experiment is accepted, the extractor derives a named skill
from the strategy and result, stores it with an initial effectiveness
score, and indexes it in FTS5 for full-text search. The skills plug
hooks into `:query_pre` alongside recall:

1. Searches the skill library using FTS5 against the incoming prompt
2. Ranks candidates by effectiveness score
3. Prepends matching skills as reusable context in `:effective_prompt`

An ETS hot cache holds workspace skill sets for non-query contexts
(dashboards, listing). Query-time injection always uses FTS5 search
for relevance. Effectiveness scores update on each use — accepted
outcomes increment the score, rejected outcomes decrement it — so the
library self-selects toward what actually works over time.

Configuration is via application config alongside other query_pre plugs
(see User Modeling section for the full pipeline configuration).

All functions are pure (database and ETS I/O aside) — no processes,
no state beyond the cache.

### Autonomous Scheduling

Pure OTP scheduling for timed experiment runs. Schedule entries define
when and how often to create experiments — no external cron or Quantum
dependency.

Two-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Scheduling** | `MonkeyClaw.Scheduling` | Schedule entry CRUD, status transitions, run tracking, due-entry queries |
| **Scheduler** | `MonkeyClaw.Scheduling.Scheduler` | GenServer poll loop — wakes on interval, fires due entries |

Schedule types:

- **`:once`** — Fires a single time at `next_run_at`, then transitions
  to `:completed`.
- **`:interval`** — Fires every `interval_ms` milliseconds, starting
  at `next_run_at`. Optionally bounded by `max_runs`.

Status lifecycle: `active → paused → active` (toggle), `active →
completed` (done or max_runs reached), `active → failed` (error).
Terminal states (`:completed`, `:failed`) cannot transition further.

The Scheduler GenServer polls every 15 seconds (configurable via
`:scheduler_poll_interval_ms`) for active entries whose `next_run_at`
has passed. For each due entry, it loads the workspace, creates an
experiment from the entry's config, and records the run. Individual
entry failures are logged but do not affect other entries in the same
poll cycle. `trigger_poll/0` forces an immediate poll for testing or
when a newly created entry is already due.

### User Modeling

Privacy-aware observation of user interactions for personalized agent
queries. The user modeling system tracks topic frequencies and
behavioral patterns from conversations, then injects relevant context
into prompts to improve agent response quality.

Four-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **UserModeling** | `MonkeyClaw.UserModeling` | Profile CRUD, topic extraction, pattern merging, context generation |
| **Observer** | `MonkeyClaw.UserModeling.Observer` | GenServer batching — accumulates observations in memory, flushes to DB on timer |
| **ObservationPlug** | `MonkeyClaw.UserModeling.ObservationPlug` | Extension plug for `:query_post` — sends observations to the Observer |
| **InjectionPlug** | `MonkeyClaw.UserModeling.InjectionPlug` | Extension plug for `:query_pre` — prepends personalized context to prompts |

Privacy levels control what gets recorded:

- **`:full`** — Records topic frequencies and behavioral patterns
  (query count, average prompt length, active hours)
- **`:limited`** — Records topic frequencies only (no patterns)
- **`:none`** — Skips all observation recording

The Observer GenServer decouples observation collection from
persistence, accumulating observations in a buffer keyed by workspace
ID and flushing them to the database every 30 seconds (configurable
via `:observer_flush_interval_ms`). This prevents observation
recording from blocking the query pipeline.

Topic extraction downcases text, filters stopwords and short words,
and counts frequencies. All accumulation is bounded: topics capped
at the top 100 by frequency (individual counts capped at 1,000),
query counts capped at 1,000,000, active hour counts capped at
100,000. The injection context summarizes the user's top interests
and explicit preferences, gated by the profile's `injection_enabled`
flag.

Configuration is via application config alongside other plugs:

    config :monkey_claw, MonkeyClaw.Extensions,
      hooks: %{
        query_post: [
          {MonkeyClaw.UserModeling.ObservationPlug, []},
          {MonkeyClaw.Vault.SecretScannerPlug, []}
        ],
        query_pre: [
          {MonkeyClaw.Vault.SecretScannerPlug, []},
          {MonkeyClaw.Recall.Plug, max_results: 10, max_chars: 4000},
          {MonkeyClaw.Skills.Plug, max_skills: 5, max_chars: 2000},
          {MonkeyClaw.UserModeling.InjectionPlug, min_query_length: 10}
        ]
      }

### Webhook Ingress

Secure HTTP endpoint for receiving external webhook deliveries and
routing them to agent workflows. Every incoming request passes through
a defense-in-depth security pipeline before reaching the agent.

Four-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Webhooks** | `MonkeyClaw.Webhooks` | Endpoint CRUD, delivery tracking, replay detection, secret management |
| **Security** | `MonkeyClaw.Webhooks.Security` | Shared crypto utilities, verifier dispatch via `verifier_for/1` |
| **Verifiers** | `MonkeyClaw.Webhooks.Verifiers.*` | Source-specific signature verification (16 built-in sources) |
| **Dispatcher** | `MonkeyClaw.Webhooks.Dispatcher` | Async agent dispatch via `Conversation.send_message/4` |

Built-in webhook sources:

| Source | Scheme | Headers |
|--------|--------|---------|
| `:generic` | HMAC-SHA256 with timestamp (Stripe-style) | `X-MonkeyClaw-Signature` |
| `:github` | HMAC-SHA256 body-only | `X-Hub-Signature-256` |
| `:gitlab` | Plain token comparison (constant-time) | `X-Gitlab-Token` |
| `:slack` | Versioned HMAC-SHA256 with timestamp | `X-Slack-Signature` |
| `:discord` | Ed25519 public-key signatures | `X-Signature-Ed25519` |
| `:bitbucket` | HMAC-SHA256 body-only | `X-Hub-Signature` |
| `:forgejo` | HMAC-SHA256 body-only (Forgejo/Gitea/Codeberg) | `X-Forgejo-Signature` |
| `:stripe` | HMAC-SHA256 with timestamp | `Stripe-Signature` |
| `:twilio` | HMAC-SHA1 URL-based (Base64) | `X-Twilio-Signature` |
| `:linear` | HMAC-SHA256 body-only | `Linear-Signature` |
| `:sentry` | HMAC-SHA256 re-serialized JSON | `Sentry-Hook-Signature` |
| `:pagerduty` | HMAC-SHA256 body-only | `x-pagerduty-signature` |
| `:vercel` | HMAC-SHA1 body-only | `x-vercel-signature` |
| `:netlify` | JWS/HS256 with body hash claim | `X-Webhook-Signature` |
| `:circleci` | HMAC-SHA256 body-only | `circleci-signature` |
| `:mattermost` | Plain token in request body | (body `token` field) |

Each source implements the `MonkeyClaw.Webhooks.Verifier` behaviour
(`verify/3`, `extract_event_type/1`, `extract_delivery_id/1`).

Security pipeline (in order):

1. **Endpoint lookup** — Active endpoints only; missing, paused, and
   revoked return identical 404s (anti-enumeration)
2. **Content-Type** — JSON only (415 for anything else)
3. **Source-dispatched verification** — Each source uses its own signing
   scheme; `Security.verifier_for/1` routes to the correct module
4. **Replay detection** — Delivery IDs checked against delivery
   history; replays return 202 without reprocessing
5. **Rate limiting** — ETS-backed per-endpoint sliding window with
   atomic counters; 429 with Retry-After header
6. **Event filtering** — Optional allowed-events map per endpoint

Signing secrets are encrypted at rest with AES-256-GCM using a key
derived from `secret_key_base` with a domain-specific separator.
Each encryption uses a random 96-bit IV, so ciphertext differs even
for identical secrets. Secrets can be rotated but are never shown to
the user again after creation.

The `CacheBodyReader` preserves raw request bytes in `conn.private`
for HMAC verification, since `Plug.Parsers` consumes the body during
JSON decoding. Verified webhooks are dispatched asynchronously via
`Task.Supervisor` — the controller returns 202 immediately while the
agent processes the event in a dedicated `"webhook:<endpoint_name>"`
channel.

All error responses are deliberately opaque — no endpoint IDs, stack
traces, or distinguishing details. Telemetry counters track received,
rejected, rate-limited, and dispatched events.

### Notifications

Event-driven notification system that routes telemetry events to
user-facing alerts. Connects the existing instrumentation pipeline
(webhooks, experiments, agent sessions) to real-time and email
delivery surfaces.

Four-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Notifications** | `MonkeyClaw.Notifications` | Notification and rule CRUD, status transitions, PubSub, query helpers |
| **Router** | `MonkeyClaw.Notifications.Router` | GenServer — telemetry handler attachment, ETS rule cache, event → notification pipeline |
| **EventMapper** | `MonkeyClaw.Notifications.EventMapper` | Pure event → notification attribute translation with workspace resolution |
| **Email** | `MonkeyClaw.Notifications.Email` | Pure Swoosh email builder for notification delivery |

Notification categories:

- **`:webhook`** — Webhook received, rejected, or dispatched events
- **`:experiment`** — Experiment completed or rolled back
- **`:session`** — Agent session or query exceptions
- **`:system`** — System-level events

Each workspace configures notification rules that map telemetry event
patterns to delivery channels (`:in_app`, `:email`, or `:all`) with a
minimum severity threshold (`:info` < `:warning` < `:error`). Rules
are cached in an application-owned ETS table for zero-overhead lookups
on every telemetry event, with periodic refresh and on-demand refresh
after rule mutations.

The Router GenServer attaches to telemetry events on startup. Handlers
run in the caller's process and immediately cast to the GenServer to
avoid blocking webhook requests, experiment runners, or agent sessions.
The GenServer then maps the event, matches rules, checks severity, and
creates the notification with delivery:

- **In-app** — PubSub broadcast to `"notifications:{workspace_id}"`.
  The ChatLive LiveView subscribes and forwards to the NotificationLive
  component, which renders a real-time notification bell with unread
  count badge and dropdown panel.
- **Email** — Async delivery via `Task.Supervisor` using Swoosh. Email
  subjects include severity prefixes (`[MonkeyClaw ERROR]`,
  `[MonkeyClaw Warning]`).

REST API endpoints provide programmatic access for listing
notifications, marking read/dismissed, bulk mark-all-read, and full
CRUD for notification rules. All endpoints are workspace-scoped with
opaque 404s on workspace mismatch to prevent enumeration.

### Channel Adapters

Bi-directional messaging between external platforms (Slack, Discord,
Telegram, WhatsApp) and BeamAgent-backed workflows. Each platform is a stateless
adapter implementing a common behaviour — no persistent WebSocket
connections required.

Four-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Channels** | `MonkeyClaw.Channels` | Channel config CRUD, message recording, PubSub events |
| **Adapter** | `MonkeyClaw.Channels.Adapter` | Behaviour contract — `validate_config/1`, `send_message/2`, `verify_request/3`, `parse_inbound/2` |
| **Adapters** | `MonkeyClaw.Channels.Adapters.*` | Platform-specific implementations (Slack, Discord, Telegram, WhatsApp, Web) |
| **Dispatcher** | `MonkeyClaw.Channels.Dispatcher` | Inbound routing (platform to agent) and outbound delivery (agent to platform) |

Supported adapters:

| Adapter | Inbound | Outbound | Verification |
|---------|---------|----------|--------------|
| **Slack** | Events API webhook | `chat.postMessage` | HMAC-SHA256 signing secret |
| **Discord** | Interactions endpoint | REST API | Ed25519 public key |
| **Telegram** | Webhook updates | Bot API `sendMessage` | Secret token header |
| **WhatsApp** | Cloud API webhook | Graph API `messages` | HMAC-SHA256 app secret |
| **Web** | LiveView events | PubSub broadcast | Session authentication |

Inbound flow: webhook controller receives HTTP POST, adapter verifies
request signature, adapter parses platform-specific payload, dispatcher
records the message and dispatches to BeamAgent, agent response is sent
back through the adapter. Challenge/verification handshakes (Slack URL
verification, Discord PING, WhatsApp webhook verification) are handled
transparently.

Outbound flow: agent produces output, dispatcher resolves enabled
channels for the workspace, each adapter sends the message to its
platform via supervised async tasks.

Global notifications ensure the user sees agent activity regardless of
current page — a dedicated PubSub topic broadcasts all channel events
to the notification system, visible from both the chat interface and the
dashboard.

Channel configurations are workspace-scoped with adapter-specific config
maps (API tokens, channel IDs, signing secrets). The web adapter is the
default channel for every workspace, requiring no external credentials.
A LiveView management interface provides CRUD for channel configs with
adapter-specific form fields and enable/disable toggling.

### Vault & Secret Management

Encrypted storage for API keys and OAuth tokens with opaque references
that prevent the AI model from ever seeing plaintext secret values.
Configuration references secrets via `@secret:name` strings; resolution
to plaintext occurs only at HTTP call boundaries in the process making
the external API call.

Four-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **Vault** | `MonkeyClaw.Vault` | Secret and token CRUD, encryption, resolution |
| **Crypto** | `MonkeyClaw.Vault.Crypto` | AES-256-GCM encrypt/decrypt with HKDF key derivation from BEAM cookie |
| **Reference** | `MonkeyClaw.Vault.Reference` | `@secret:name` validation, extraction, recursive resolution |
| **SecretScanner** | `MonkeyClaw.Vault.SecretScanner` | 14 regex patterns detecting leaked secrets in prompts and responses |

Security design:

- **Encryption at rest** — AES-256-GCM with random 96-bit IVs. Keys
  derived from the BEAM cookie via HKDF-SHA256 and cached in
  `:persistent_term`.
- **Opaque references** — The model sees `@secret:anthropic_key`, never
  the plaintext. Resolution happens exclusively in
  `Vault.resolve_secret/2`.
- **Secret scanning** — Extension plugs scan both inbound prompts
  (`query_pre`) and outbound responses (`query_post`) for 14 secret
  patterns (AWS, GitHub, Slack, Stripe, OpenAI, Anthropic, etc.),
  redacting matches before they reach the model.
- **OAuth tokens** — Auto-encrypted via `EncryptedField` custom Ecto
  type with expiry tracking and upsert semantics (one token per
  provider per workspace).

Secrets are data entities, not processes. The vault context is a
stateless Ecto-backed module — no GenServer overhead. The secret
scanner runs as extension plugs in the compiled pipeline.

A LiveView management interface at `/vault` provides three tabs:
Secrets (create, list, delete — values never displayed after creation),
Tokens (list with active/expired status, delete), and Models (browse
cached models grouped by provider, trigger refresh).

### Model Registry

Periodic refresh of available AI models from provider APIs, with
SQLite persistence and ETS write-through cache for low-latency reads.

Two-layer architecture:

| Layer | Module | Owns |
|-------|--------|------|
| **ModelRegistry** | `MonkeyClaw.ModelRegistry` | GenServer — ETS table lifecycle, periodic refresh timer, serialized writes |
| **Provider** | `MonkeyClaw.ModelRegistry.Provider` | HTTP fetching via Req for Anthropic, OpenAI, and Google APIs |

The GenServer is justified because it manages concurrent state (ETS
table ownership), periodic work (configurable refresh interval), and
serialized writes (preventing concurrent refresh races). Reads bypass
the GenServer entirely — ETS with `:read_concurrency` enabled.

Graceful degradation: provider API failures log warnings and preserve
stale cache. Vault resolution failures skip that provider. The
GenServer never crashes on refresh failure. The LiveView handles
a missing ModelRegistry process (disabled in test config) by showing
an empty state.

Runtime reconfiguration via `ModelRegistry.configure/1` allows changing
the workspace ID and provider secret mappings without restarting the
process.

### Dashboard

Landing page at `/` with real-time system visibility, refreshing
every 5 seconds. Four panels cover BEAM VM health (memory, processes,
run queue, uptime), active agent sessions (clickable rows navigate
to the session's chat), extension and hook status, and recent
workspaces. Backend badges link directly to a new chat pre-configured
with that backend.

### Web Chat UI

Phoenix LiveView chat interface at `/chat` with real-time streaming,
markdown rendering, and per-message token stats. Features include
multi-conversation management (sidebar with create/switch/delete),
session history (past conversations persisted in SQLite with
full-text search via FTS5), collapsible thinking blocks, code copy
buttons, runtime model selection across all supported backends, and
runtime permission mode control (`:default`, `:accept_edits`,
`:bypass_permissions`, `:plan`, `:dont_ask`).

### Persistence

SQLite3 via `ecto_sqlite3`. Embedded and zero-ops — a natural fit
for single-user self-hosted deployments. Tables use STRICT mode and
WITHOUT ROWID for type safety and clustered UUID primary key lookups.

## Prerequisites

- Erlang/OTP 27+
- Elixir 1.17+
- [BeamAgent](https://github.com/beardedeagle/beam-agent) cloned as a
  sibling directory (`../beam-agent/beam_agent_ex`)

## Setup

```bash
mix setup
```

This runs `deps.get`, creates the database, runs migrations, and builds
assets.

## Development

```bash
# Start the Phoenix server
mix phx.server

# Or inside IEx
iex -S mix phx.server
```

### mTLS Certificates

```bash
mix monkey_claw.gen.certs                         # Generate CA + server + client certs
mix monkey_claw.gen.certs --san my.domain          # Add custom SANs
mix monkey_claw.gen.certs --output-dir /path/to    # Custom output directory
```

Generates a self-signed CA, server certificate with SANs, client
certificate, and a PKCS#12 bundle for browser import — all pure
Elixir, no external dependencies.

### Quality Gates

```bash
mix compile --warnings-as-errors  # Zero-warning compilation
mix format --check-formatted      # Code formatting
mix test                          # Full test suite
mix credo --strict                # Static analysis
mix dialyzer                      # Type checking
```

All five gates run in CI. The `mix precommit` alias runs compile
(warnings-as-errors), `deps.unlock --unused`, format, and test in
sequence for quick local checks.

## License

Private. All rights reserved.
