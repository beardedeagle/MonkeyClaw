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
- **Multi-agent** — Five AI backend adapters (Claude, Codex, Gemini,
  OpenCode, Copilot) via BeamAgent, with unified session management.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Workflow Layer                                      │
│  MonkeyClaw.Workflows — conversation recipes         │
├─────────────────────────────────────────────────────┤
│  Product Layer                                      │
│  MonkeyClaw — assistants · workspaces · channels    │
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

Twelve hook points span queries, sessions, workspaces, and channels.
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
collapsible thinking blocks, code copy buttons, and runtime model
selection across all supported backends.

### Persistence

SQLite3 via `ecto_sqlite3`. Embedded and zero-ops — a natural fit
for single-user self-hosted deployments. Tables use STRICT mode and
WITHOUT ROWID for type safety and efficient UUID-keyed lookups.

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

### Quality Gates

```bash
mix compile --warnings-as-errors  # Zero-warning compilation
mix format --check-formatted      # Code formatting
mix test                          # Full test suite
mix credo --strict                # Static analysis
mix dialyzer                      # Type checking
```

All five gates run in CI. The `mix precommit` alias runs compile, format,
and test in sequence for quick local checks.

## License

Private. All rights reserved.
