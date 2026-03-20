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
│  Product Layer                                      │
│  MonkeyClaw — assistants · workspaces · channels    │
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

Contexts (`MonkeyClaw.Assistants`, `MonkeyClaw.Workspaces`) provide the
public CRUD API. `MonkeyClaw.AgentBridge` translates domain objects into
BeamAgent session and thread configurations.

### Persistence

SQLite3 via `ecto_sqlite3`. Embedded and zero-ops — a natural fit
for single-user self-hosted deployments. Tables use STRICT mode and
WITHOUT ROWID for type safety and efficient UUID-keyed lookups.

## Prerequisites

- Erlang/OTP 28+
- Elixir 1.19+
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
