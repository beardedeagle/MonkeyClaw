# MonkeyClaw ↔ beam-agent Integration Gap Analysis & Parity Roadmap

> Updated 2026-04-01 — reflects beam-agent post-Phase 7 (domain collapses, structured
> errors, redaction hardening, ETS inventory) and MonkeyClaw's current integration surface.
> Phase 1 Table Stakes: All 4 items implemented (S1 Streaming, S2 Session History,
> S3 Permission Mode, S4 Event Unsubscribe).
> Phase 2 Agent Autonomy: S1 Experiment Runs implemented (Strategy behaviour +
> Runner GenServer + iteration persistence + security hardening).
> S2 Experiment Loops implemented (lifecycle API, extension hooks,
> PubSub broadcasting, result population).

## The Numbers

- **beam-agent exposes**: ~160+ public Elixir functions across 31 submodules
- **MonkeyClaw currently uses**: **20 function calls** from **4 modules** (`BeamAgent`, `BeamAgent.Threads`, `BeamAgent.Capabilities`)
- **Integration surface**: ~4% of available API
- **Competing \*Claw implementations**: 20+ (see competitive landscape)

---

## Resolved

### `:beam_agent_core.set_model/2` → `BeamAgent.set_model/2`

**Fixed 2026-03-31.** `Backend.BeamAgent.set_model/2` was bypassing the Elixir
public API and calling the raw Erlang core module directly. Now delegates through
`BeamAgent.set_model/2` like every other call in the adapter.

### Stale `beam_agent_error_core` doc references

**Fixed 2026-03-31.** `ErrorFormatter` moduledoc referenced `beam_agent_error_core`
which was absorbed into `beam_agent_core` during beam-agent Phase 7. Updated to
reference `beam_agent_core`.

### S1. Streaming Responses

**Implemented 2026-03-31.** Full streaming pipeline from `Backend.stream/3` through
`Session` GenServer (spawn_monitor pattern) to `ChatLive` (progressive rendering).

- `Backend` behaviour: `stream/3` callback added
- `Backend.BeamAgent`: delegates to `BeamAgent.stream/3` (tagged tuples)
- `Backend.Test`: real GenServer with configurable `stream_responses`
- `Session`: spawns monitored task to enumerate stream, delivers chunks via
  direct `send/2` to caller + PubSub broadcast for observers. Guards against
  concurrent queries during active stream. Clean teardown on session stop.
- `Conversation.stream_message/4`: workflow entry point (pre-hooks run, post-hooks
  are caller's responsibility after accumulating full response)
- `ChatLive`: progressive chunk accumulation, streaming/done/error states
- Telemetry: `stream_start/1`, `stream_stop/2`, `stream_exception/2`

### S2. Session History

**Implemented 2026-04-01.** SQLite-backed conversation persistence with FTS5 search,
integrated as a fire-and-forget secondary layer in the Session GenServer.

- **Persistence layer**: `Sessions` context with `Session` and `Message` Ecto schemas
  backed by SQLite3 STRICT-mode tables. Denormalized `message_count` on sessions
  avoids `COUNT(*)` in sidebar listings.
- **FTS5 search**: External-content FTS5 index (`session_messages_fts`) with DB-level
  INSERT/DELETE triggers for automatic sync. Enables cross-session recall via
  `Sessions.search_messages/2,3`.
- **Session GenServer integration**: `create_history_session/1` on init,
  `persist_query_messages/3` and `persist_stream_result/1` on query/stream
  completion, `update_history_status/2` on stop/crash. All persistence wrapped
  in rescue blocks — GenServer primary job never compromised by storage failures.
- **Stream accumulation**: `stream_content_buffer` in GenServer state accumulates
  chunks during streaming, persists on `stream_done`. Incomplete streams are not
  persisted (accurate representation of what happened).
- **AgentBridge facade**: `list_session_history/1,2`, `get_session_history/1`,
  `get_session_messages/1,2`, `search_session_messages/2,3`,
  `delete_session_history/2` — all delegating to `Sessions` context.
- **ChatLive UI**: Sidebar "Past sessions" section with session title, message
  count, and timestamp. Read-only history viewing mode with banner and disabled
  input. One-click "Back to current" to restore active conversation.
- **Title derivation**: Auto-derives session title from first user message
  (truncated to 100 chars) after first query completes.
- **Test coverage**: 50 tests covering CRUD, messages, FTS5 search, title
  derivation, sequence numbering, and factory helpers.

### S3. Permission Mode Switching

**Implemented 2026-03-31.** `set_permission_mode/2` wired through the full stack.

- `Backend` behaviour: `set_permission_mode/2` callback (same pattern as `set_model/2`)
- `Backend.BeamAgent`: delegates to `BeamAgent.set_permission_mode/2`
- `Backend.Test`: returns `{:ok, :noop}` for deterministic testing
- `Session`: `handle_call({:set_permission_mode, mode}, ...)`
- `AgentBridge`: facade function with session lookup

### S4. Event Unsubscribe

**Implemented 2026-03-31.** Clean event teardown on session stop.

- `Backend` behaviour: `event_unsubscribe/2` callback
- `Backend.BeamAgent`: delegates to `BeamAgent.event_unsubscribe/2`
- `Backend.Test`: validates ref, clears event state
- `Session.do_stop_session/1`: calls `unsubscribe_events/1` before stopping
  the BeamAgent process, ensuring no leaked subscriptions

### S2-Autonomy. Experiment Loops (Integration Wiring)

**Implemented 2026-04-02.** Lifecycle API, extension hooks, PubSub broadcasting,
and result population — completing the experiment engine's integration surface.

- **Lifecycle API**: `Experiments.start_experiment/3` (create + start runner),
  `stop_experiment/1` (graceful stop via Runner), `cancel_experiment/1`
  (immediate cancel via Runner), `experiment_status/1` (live Runner info
  with DB fallback). Atomic create-and-start with cleanup on Runner failure.
- **Extension hooks**: Four new hook points in `Extensions.Hook`:
  `:experiment_started`, `:experiment_completed`, `:iteration_started`,
  `:iteration_completed`. Fired from Runner at lifecycle boundaries.
  Best-effort — hook failures never crash the Runner.
- **PubSub broadcasting**: Runner broadcasts on `"experiment:#{id}"` topics
  (matching `"agent_session:#{id}"` pattern). Events: `:experiment_started`,
  `:iteration_started`, `:iteration_completed`, `:experiment_completed`.
  Best-effort — broadcast failures never crash the Runner.
- **Result population**: `last_eval_result` tracked in Runner state, persisted
  as `experiment.result` on completion (scrubbed through same secret filter
  as strategy state). Previously only strategy state was persisted.
- **Test coverage**: 13 new tests — PubSub event assertions, result population
  (accept/reject/cancel/secrets), lifecycle API (start/stop/cancel/status).
  All tests use real GenServer processes (Backend.Test), zero mocks.

---

## Parity Framework

Features are grouped by competitive urgency:

- **Phase 1 — Table Stakes**: Every \*Claw ships these. Without them MonkeyClaw is a demo.
- **Phase 2 — Feature Parity**: Most mainstream \*Claws have these. Closes the gap with OpenClaw.
- **Phase 3 — Differentiation**: Few or no \*Claws have these. BEAM-native advantages.

---

## Phase 1 — Table Stakes

> **Status**: 4 of 4 items implemented.

### S1. Streaming Responses ✅ IMPLEMENTED

See [Resolved → S1](#s1-streaming-responses) above.

### S2. Session History ✅ IMPLEMENTED

See [Resolved → S2](#s2-session-history) above.

### S3. Permission Mode Switching ✅ IMPLEMENTED

See [Resolved → S3](#s3-permission-mode-switching) above.

### S4. Event Unsubscribe ✅ IMPLEMENTED

See [Resolved → S4](#s4-event-unsubscribe) above.

---

## Phase 2 — Feature Parity

These close the gap with mainstream \*Claws (OpenClaw, LobsterAI, CoPaw).

### P1. Extended Thread Operations

**Currently**: `thread_start/2`, `thread_resume/2`, `thread_list/1` only.

**Available** (all via `BeamAgent`):
- `thread_fork/2,3` — fork a conversation thread
- `thread_read/2,3` — read thread metadata (option: `:include_messages`)
- `thread_archive/2` / `thread_unarchive/2` — archive management
- `thread_rollback/3` — revert thread visible history via selector
- `thread_name_set/3` — rename threads
- `thread_metadata_update/3` — custom metadata
- `thread_compact/2` — compact message history
- `thread_loaded_list/1,2` — list loaded threads with active state
- `thread_unsubscribe/2` — clear active thread

**Implementation plan**:
1. Expand `Backend` behaviour with high-value subset: fork, archive, rollback, name_set, read
2. Wire through `AgentBridge` → `Session`
3. Surface thread management in ChatLive sidebar (rename, archive, fork as actions)

### P2. Context Management

**Currently**: MonkeyClaw's `ErrorFormatter` handles `context_exceeded` errors
reactively. No proactive management.

**Available** (`BeamAgent.Context`):
- `context_status/1` — get context usage status
- `budget_estimate/1` — estimate remaining context budget
- `compact_now/2` — compact context immediately
- `maybe_compact/2` — conditionally compact if pressure exceeds threshold

**Implementation plan**:
1. Create `AgentBridge.Context` facade (like `AgentBridge.Capabilities`)
2. Show context pressure indicator in chat UI (e.g., progress bar)
3. Auto-compact via `maybe_compact/2` when approaching limits
4. Prevents `context_exceeded` errors rather than reacting to them

### P3. Checkpoint / Undo

**Currently**: No undo capability for agent file changes.

**Available** (`BeamAgent.Checkpoint`):
- `snapshot/3` — snapshot file content, permissions, existence for checkpoint UUID
- `rewind/2` — restore files to checkpointed state
- `list_checkpoints/1` — list all checkpoints for a session
- `extract_file_paths/2` — extract files a tool will modify from tool_name and tool_input

**Implementation plan**:
1. Create `AgentBridge.Checkpoint` facade
2. Hook into tool execution pipeline — auto-snapshot before file-mutating tools
3. Surface "Undo" button in chat when agent makes file changes
4. Aligns with MonkeyClaw's security-first posture

### P4. Session Fork / Revert / Share

**Currently**: Not exposed.

**Available**:
- `BeamAgent.fork_session/2` — copy session metadata + message history
- `BeamAgent.revert_session/2` — revert to prior boundary (preserves append-only store)
- `BeamAgent.unrevert_session/1` — restore full visible history
- `BeamAgent.share_session/1,2` / `unshare_session/1` — shareable session links

**Implementation plan**:
1. Wire fork/revert through `AgentBridge`
2. "Branch conversation" and "Go back to..." UX in chat
3. Share is lower priority (single-user model) but useful for exporting

### P5. Hooks Integration

**Currently**: MonkeyClaw has its own extension hooks system (`Extensions.Hook`).
beam-agent has a separate hook system for session lifecycle events.

**Available** (`BeamAgent.Hooks`):
- `hook/2,3` — create hook definition (event + callback + optional matcher)
- `register_hook/2` / `register_hooks/2` — register into registry
- `fire/2,3` — fire event with context
- `register_global/1` — persist across sessions
- Events: `:session_start`, `:query_start`, `:query_complete`, `:tool_use`,
  `:message_record`, `:error`, `:permission_request`, `:stream_event`

**Implementation plan**:
1. Bridge MonkeyClaw extension hooks → beam-agent hooks at session start
2. Pass `sdk_hooks` in session opts built from active workspace extensions
3. Enables MonkeyClaw extensions to intercept beam-agent lifecycle events
4. Powers the mid-term autonomy layer (experiment loops via `:query_complete` hooks)

### P6. Account & Auth Management

**Currently**: Auth errors handled reactively via `ErrorFormatter`.

**Available** (`BeamAgent.Account`):
- `info/1` — account information (plan, email)
- `login/2` / `logout/1` — auth flow
- `cancel/2` — cancel auth flow
- `rate_limits/1` — rate limit status

**Implementation plan**:
1. Surface auth status in session footer or settings panel
2. Show rate limit status alongside context pressure
3. Proactive re-auth flow when `auth_expired` is detected

---

## Phase 3 — Differentiation

These go beyond parity. Most \*Claws DON'T have these. beam-agent hands them
to MonkeyClaw for free, and BEAM/OTP makes them better than any competing
implementation could.

### D1. Memory System

**Available** (`BeamAgent.Memory`):
- `remember/2,3` — record fact/note/summary with auto or explicit scope
- `recall/2` — lexical recall by scope + query
- `search/1,2` — full-text search across all memories
- `forget/1` / `update/2` — CRUD
- `pin/1` / `unpin/1` — prevent/allow expiry
- `expire/0,1` — TTL-based cleanup

**MonkeyClaw mapping**: Workspace-scoped memory. Users pin important context,
system auto-recalls relevant memories for new conversations. Maps directly to
roadmap items: "user modeling", "cross-session recall", "self-improving skills".

**BEAM advantage**: Memory GenServer per workspace with ETS hot path, future
Mnesia distribution across cluster nodes.

### D2. MCP Tool Registration

**Available** (`BeamAgent.MCP`):
- `tool/4` — define tool (name, description, input_schema, handler callback)
- `server/2,3` — define MCP server with tools
- `register_server/2` — register into session
- `call_tool_by_name/3,4` — invoke tool by name
- `handle_mcp_message/3,4` — JSON-RPC 2.0 handling
- `set_servers/2` — runtime server toggling

**MonkeyClaw mapping**: Workspace-specific custom tools. Users configure
tools (DB queries, API calls, file operations) that the agent can invoke.
Powers the autonomy layer.

### D3. Multi-Backend Routing

**Available** (`BeamAgent.Routing`):
- `select_backend/1,2` — policy-driven backend selection
- Full session lifecycle (start, stop, query, stream) with routing
- Policies: `:preferred_then_fallback`, `:round_robin`, `:sticky`, `:failover`, `:capability_first`

**MonkeyClaw mapping**: "Claude is rate-limited? Auto-route to Gemini." Transparent
backend fallback with no user intervention. No other \*Claw does this natively.

**BEAM advantage**: Routing supervisor can monitor backend health across the
cluster, not just the local node.

### D4. Runs & Steps

**Available** (`BeamAgent.Runs`):
- `start_run/2` / `complete_run/2` / `fail_run/2` / `cancel_run/2` — run lifecycle
- `start_step/2` / `complete_step/3` / `fail_step/3` / `cancel_step/3` — step lifecycle
- `get_run/1` / `list_runs/0,1` / `get_step/2` / `list_steps/1` — introspection

**MonkeyClaw mapping**: Track multi-step agent operations ("implement feature X"
= 5 steps). Powers "bounded experiment loops" from the roadmap. Step-level
progress visible in UI.

### D5. Artifacts

**Available** (`BeamAgent.Artifacts`):
- `put/1,2` / `get/1` / `list/0,1` / `search/1,2` / `attach/3` / `delete/1`
- Typed: plans, diffs, reviews, summaries, approvals, benchmarks, transcripts

**MonkeyClaw mapping**: First-class code diffs, plans, summaries alongside
chat messages. Rich UI beyond just text bubbles.

### D6. Skills Management

**Available** (`BeamAgent.Skills`):
- `list/1,2` / `remote_list/1,2` — local and remote skill listing
- `register_global/2` / `unregister_global/1` — global skill registry
- `config_write/3` — enable/disable skills
- `remote_export/2` — export to remote registry

**MonkeyClaw mapping**: Agent extracts reusable procedures from successful tasks,
registers as skills per-workspace. Maps to roadmap "self-improving skills."

### D7. Journal / Audit Trail

**Available** (`BeamAgent.Journal`):
- `append/2` — append domain event
- `list/0,1` / `stream_from/1,2` — list/stream events
- `get/1` / `ack/2` — retrieve and acknowledge events

**MonkeyClaw mapping**: Append-only audit trail for all agent actions. Powers
activity feed, compliance logging. Security differentiator.

### D8. Policy Engine

**Available** (`BeamAgent.Policy`):
- `put_profile/2` — create/update policy profile
- `evaluate/3` — evaluate action (`:tool_use`, `:file_edit`, `:shell_command`, `:model_switch`)
- `get_profile/1` / `list_profiles/0` — introspection

**MonkeyClaw mapping**: Workspace-level permission policies. "This workspace
can't write outside its directory." Aligns with security-first posture and
the workspace filesystem design (explicit fs permissions).

### D9. Catalog / Discovery

**Available** (`BeamAgent.Catalog`):
- `list_tools/1` / `list_skills/1` / `list_plugins/1` / `list_mcp_servers/1` / `list_agents/1`
- `get_tool/2` / `get_skill/2` / `get_plugin/2` / `get_agent/2`
- `current_agent/1` / `set_default_agent/2`

**MonkeyClaw mapping**: Discoverable tools/skills UI. Users browse what the
agent can do and configure their workspace toolset.

### D10. Routines (Scheduled Execution)

**Available** (`BeamAgent.Routines`):
- `create/1` / `run_now/1` / `run_due/0` / `list_due/0` / `next_due_at/0`

**MonkeyClaw mapping**: Scheduled agent tasks via OTP `:timer`. Roadmap item
"autonomous scheduling" — unattended task execution supervised per workspace.
Uniquely BEAM-native: hot code reload + supervision + distribution.

---

## Roadmap Alignment

| Roadmap Item | beam-agent Capability | Phase | Status |
|-------------|----------------------|-------|--------|
| Model selector | `set_model/2` | — | **Done** |
| Streaming responses | `BeamAgent.stream/3` | S1 | **Done** |
| Permission mode switching | `BeamAgent.set_permission_mode/2` | S3 | **Done** |
| Event cleanup | `BeamAgent.event_unsubscribe/2` | S4 | **Done** |
| Thinking blocks display | `:thinking` message type in stream | S1 | Unlocked (streaming infra in place) |
| Settings panel | `BeamAgent.Config`, `BeamAgent.Control` | P2/P6 | Planned |
| Chat history / SQLite | `list_sessions`, `get_session_messages`, `summarize_session` | S2 | **Done** |
| Experiment engine (autonomy foundation) | `BeamAgent.query`, `BeamAgent.Checkpoint` | Phase 2 S1 | **Done** |
| Experiment loops (integration wiring) | Lifecycle API, Extension hooks, PubSub | Phase 2 S2 | **Done** |
| Bounded experiment loops (deep integration) | `BeamAgent.Runs` + `BeamAgent.Hooks` | D4 + P5 | Planned |
| Self-improving skills | `BeamAgent.Skills` + `BeamAgent.Memory` | D1 + D6 | Planned |
| User modeling | `BeamAgent.Memory.remember/recall` | D1 | Planned |
| Cross-session recall | `BeamAgent.Memory.recall/2`, `search/1,2` | D1 | Planned |
| Autonomous scheduling | `BeamAgent.Routines` | D10 | Planned |
| Multi-platform gateway | Extension hooks (already architected) | — | Existing |

---

## Current API Usage (Complete Inventory)

### Direct BeamAgent Calls (from `Backend.BeamAgent` — the ONLY call site)

| # | Module | Function | Arity | Purpose |
|---|--------|----------|-------|---------|
| 1 | `BeamAgent` | `start_session` | 1 | Start agent session |
| 2 | `BeamAgent` | `stop` | 1 | Stop agent session |
| 3 | `BeamAgent` | `query` | 2 | Query (no params) |
| 4 | `BeamAgent` | `query` | 3 | Query (with params) |
| 5 | `BeamAgent` | `stream` | 3 | Stream query (tagged tuples) |
| 6 | `BeamAgent` | `set_model` | 2 | Runtime model change |
| 7 | `BeamAgent` | `set_permission_mode` | 2 | Runtime permission mode change |
| 8 | `BeamAgent` | `session_info` | 1 | Get session metadata/state |
| 9 | `BeamAgent` | `event_subscribe` | 1 | Subscribe to session events |
| 10 | `BeamAgent` | `receive_event` | 3 | Poll for buffered event |
| 11 | `BeamAgent` | `event_unsubscribe` | 2 | Unsubscribe + flush events |
| 12 | `BeamAgent.Threads` | `thread_start` | 2 | Create thread |
| 13 | `BeamAgent.Threads` | `thread_resume` | 2 | Resume thread |
| 14 | `BeamAgent.Threads` | `thread_list` | 1 | List threads |

### Capability Discovery (from `AgentBridge.Capabilities`)

| # | Module | Function | Arity | Purpose |
|---|--------|----------|-------|---------|
| 15 | `BeamAgent.Capabilities` | `capability_ids` | 0 | List capability IDs |
| 16 | `BeamAgent.Capabilities` | `all` | 0 | List all capability details |
| 17 | `BeamAgent.Capabilities` | `backends` | 0 | List backend atoms |
| 18 | `BeamAgent.Capabilities` | `status` | 2 | Get capability support for backend |
| 19 | `BeamAgent.Capabilities` | `for_backend` | 1 | List capabilities for backend |
| 20 | `BeamAgent.Capabilities` | `for_session` | 1 | List capabilities for live session |

### BeamAgent Data Structures Consumed

- **Session info map**: `%{state: :ready | :error | atom(), session_id: String.t(), ...}`
- **Message maps**: `%{type: :assistant | :thinking | :tool_use | ..., content_blocks: [...], usage: %{...}, model: "..."}`
- **Stream items**: `{:ok, %{type: atom(), content: term()}} | {:error, reason}` — tagged tuples from `BeamAgent.stream/3`
- **Error maps**: `%{type: :error, category: error_category(), retry_after: integer()}` (from `beam_agent_core:categorize/1`)
- **Error categories**: `:rate_limit | :subscription_exhausted | :context_exceeded | :auth_expired | :server_error | :unknown`
- **Event ref**: opaque `reference()` from `event_subscribe`
- **Thread info**: `map()` (opaque to MonkeyClaw)
- **Capability info**: `%{id: atom(), title: String.t(), support: %{claude: map(), ...}}`
- **PubSub stream events**: `{:stream_chunk, session_id, chunk}`, `{:stream_done, session_id}`, `{:stream_error, session_id, reason}`

---

## Proposed Implementation Order

| Phase | Items | Effort | Impact | Dependencies | Status |
|-------|-------|--------|--------|-------------|--------|
| **Phase 1** | S1 (streaming), S3 (permission mode), S4 (unsubscribe) | Medium | Table stakes — usable product | None | ✅ **Complete** |
| **Phase 1→2** | S2 (session history) | Medium | Table stakes — SQLite persistence layer | Persistence layer | ✅ **Complete** |
| **Phase 2** | P1 (threads), P2 (context), P3 (checkpoint), P4 (fork/revert), P5 (hooks bridge), P6 (account) | Large | Feature parity with OpenClaw | Phase 1 ✅ | Next |
| **Phase 3** | D1-D10 (memory, MCP, routing, runs, artifacts, skills, journal, policy, catalog, routines) | XL | Beyond parity — BEAM differentiation | Phase 2 (hooks bridge enables autonomy) | Planned |

### Recommended Next Step

**Phase 2 Feature Parity, starting with P1 (Extended Threads) or P2 (Context Management).**
Phase 1 is complete (S1-S4). Phase 2 Agent Autonomy S1 (Experiment Runs) and
S2 (Experiment Loops) are both implemented — the experiment engine now provides:
Strategy behaviour, Runner GenServer, iteration persistence, security hardening,
lifecycle API (`start_experiment/3`, `stop_experiment/1`, `cancel_experiment/1`,
`experiment_status/1`), extension hooks (`:experiment_started`, `:experiment_completed`,
`:iteration_started`, `:iteration_completed`), PubSub broadcasting on
`"experiment:#{id}"` topics for LiveView, and result population (final eval_result
persisted as `experiment.result`). Next: P1 (Extended Threads) and P2 (Context
Management) for beam-agent feature parity.
