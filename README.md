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
│  Product Layer                                      │
│  MonkeyClaw — assistants · workspaces · experiments │
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

Contexts (`MonkeyClaw.Assistants`, `MonkeyClaw.Workspaces`) provide the
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

Configuration is via application config:

    config :monkey_claw, MonkeyClaw.Extensions,
      hooks: %{
        query_pre: [{MonkeyClaw.Recall.Plug, max_results: 10, max_chars: 4000}]
      }

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

An ETS hot cache holds recently used skills, keeping injection latency
low. Effectiveness scores update on each use — accepted outcomes
increment the score, rejected outcomes decrement it — so the library
self-selects toward what actually works over time.

Configuration is via application config:

    config :monkey_claw, MonkeyClaw.Extensions,
      hooks: %{
        query_pre: [
          {MonkeyClaw.Recall.Plug, max_results: 10, max_chars: 4000},
          {MonkeyClaw.Skills.Plug, max_skills: 5, max_chars: 2000}
        ]
      }

All functions are pure (database and ETS I/O aside) — no processes,
no state beyond the cache.

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
