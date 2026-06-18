# DevIDE Architecture

> Version: v2 (raw + MCP reality)
>
> This document is the authoritative narrative for the DevIDE workspace
> cockpit. When implementation and docs diverge, the docs win: fix the code.
>
> **History:** earlier versions described a delegated-execution stack —
> Fleet/JX coordination, a runner-assignment durable protocol, and a
> governed-command plane. That stack has been removed. The product collapsed
> to a single-runtime workspace cockpit: a durable raw terminal over tmux, an
> MCP tool interface for agents, preview, and an audit/activity feed. The
> first principles and subsystem map below describe what remains.

## First principles

These are the invariants the architecture is built to honor. Every section
below — and every future change — is judged against them. Cite by number
in tickets and reviews (e.g. "this violates §FP-3").

| #     | Invariant                                                                          |
|-------|------------------------------------------------------------------------------------|
| FP-1  | **Execution authority lives server-side.** A session writes into a server-side PTY (tmux + Ghostty); the browser is a viewer, not an argv source. Raw-terminal admission is a server-side policy decision. |
| FP-2  | **Sessions are durable by default.** A workspace session outlives the client connection that opened it. tmux is the persistence boundary. |
| FP-3  | **The UI reflects runtime truth.** Capabilities, state, and history are rendered from what the server reports — not assumed, not mocked. |
| FP-5  | **Operators interact with workspaces, not machines.** A workspace is the addressable thing; the host underneath is an implementation detail of where it happens to live. |
| FP-8  | **The server must function without the cockpit.** Sessions persist and audit accrues without any UI client connected; tmux survives BEAM restarts. |
| FP-9  | **The cockpit must tolerate disconnect/recovery.** Network drops and server restarts are normal events the UI is designed for — not error states; reattach replays scrollback from tmux. |
| FP-10 | **Execution leaves reviewable evidence.** Raw-session attaches, agent MCP tool calls, and review-agent runs are traceable through the audit log and the run ledger. |

> Removed invariants (delegated-execution stack): **FP-4** ("local / remote /
> fleet are topology variants") and **FP-7** ("fleet composes runtimes") are
> gone — there is one runtime, no fleet topology. **FP-6** ("runners execute
> policy") is gone — there are no runners.

These invariants are upstream of every other architectural choice in this
document. If a proposed change requires weakening one of them, the change
is the wrong shape — find another way.

See also: [`product.md`](product.md) §4 (server/client boundary) and §13
(decision rules) for product-level enforcement; [`glossary.md`](glossary.md)
for the term constraints these invariants are stated in.

## System purpose

DevIDE is a **single-runtime workspace cockpit**. It owns durable terminal
sessions for a workspace, exposes those sessions (and a preview surface) to
external agents over MCP, and records what happened in an audit log and a run
ledger.

It does not execute arbitrary argv on behalf of a remote client. The two
execution paths that exist are deliberately narrow:

- **Raw terminal** — an operator (or an MCP agent) types into a server-side
  PTY backed by tmux. Admission is a `Policy.can_use_raw_terminal?/1` decision.
- **Review-agent runs** — `DevIDE.Agents.Run` spawns a fixed, allowlisted
  `DevIDE.Agents.ReviewCommand` argv as a local subprocess. There is no path
  through it to run an arbitrary command or apply a patch.

```text
Browser / MCP agent --attach/input--> DevIDE --PTY--> tmux session
                                         │
                                         └--reads--> workspace source
```

## Subsystem map

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DevIDE.BEAM                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Web Tier   │  │  Terminals   │  │    Agents    │  │  Workspaces  │       │
│  │  (Phoenix +  │  │ (tmux +      │  │ (MCP terminal│  │   (State,    │       │
│  │   LiveView)  │  │  Ghostty PTY)│  │  + preview)  │  │  Isolation)  │       │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘       │
│         │                 │                 │                 │               │
│  ┌──────┴───────┐  ┌──────┴───────┐  ┌──────┴───────┐  ┌──────┴───────┐       │
│  │  Audit       │  │  Policy      │  │  Run ledger  │  │  Preview     │       │
│  │  (Events)    │  │  (Decisions) │  │  (Runs.Ledger)│ │  (control)   │       │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘       │
└─────────────────────────────────────────────────────────────────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
   ┌──────────┐          ┌──────────┐          ┌──────────┐
   │   tmux   │          │  Ghostty │          │ Workspace│
   │ (durable)│          │   PTY    │          │  Source  │
   └──────────┘          └──────────┘          └──────────┘
```

## Trust boundaries

```
┌────────────────────────────────────────────────────────────────────────┐
│                         Trust Boundary Map                               │
├────────────────────────────────────────────────────────────────────────┤
│  Boundary 1: MCP agent → DevIDE MCP endpoints                            │
│    • Authenticated via bearer token (ApiAuth plug)                       │
│    • Terminal MCP drives tmux on devide_-prefixed sessions only          │
│    • Preview MCP drives a scoped preview session                         │
│    • Agents cannot reach arbitrary tmux sessions or arbitrary argv on    │
│      the host beyond what they type into a guarded session               │
│                                                                          │
│  Boundary 2: Browser → terminal channel / LiveView                       │
│    • DevIdeWeb.ChannelAuth signs/verifies a user-socket token            │
│    • Raw input/resize write into the server-side PTY                     │
│    • Raw-terminal admission is gated by Policy.can_use_raw_terminal?/1   │
│                                                                          │
│  Boundary 3: DevIDE → Workspace source                                   │
│    • Pluggable via `DevIDE.WorkspaceSource` behaviour                    │
│    • Source is the truth for workspace existence and lifecycle           │
│    • DevIDE persists only redacted summaries                             │
│                                                                          │
│  Boundary 4: DevIDE → Host filesystem                                    │
│    • PathSafety validates all paths are under allowed roots              │
│    • No traversal or symlink-escape allowed                              │
│                                                                          │
│  Boundary 5: DevIDE → Audit / run ledger                                 │
│    • Audit records sensitive decisions and agent MCP calls               │
│    • Run ledger (Runs.Ledger) records raw-session and run events         │
│    • Audit adapter is swappable: MemoryAdapter → EctoAdapter             │
└────────────────────────────────────────────────────────────────────────┘
```

## Workspace metadata contract

Sources return `%DevIDE.Workspace{}`. Source-specific data lives under `metadata`.
Generic code may read these well-known keys:

- `ports` — map of service name → port number
- `domain_base` — used for constructing URLs (e.g. Tidewave)
- `type` — source-specific workspace kind (kept inside the source when possible)

New sources should document any additional keys they populate.

## Authority map

| Action | Authority | Gate | Immutable Record |
|---|---|---|---|
| Create workspace | Manager | Manager API | — |
| Start/stop/delete workspace | Manager | Manager API | — |
| Attach raw terminal | DevIDE | `Policy.can_use_raw_terminal?/1` | `run.session_attached` ledger event |
| Refuse raw terminal | DevIDE | `Policy.can_use_raw_terminal?/1` deny | `run.session_denied` ledger event |
| Start review-agent run | DevIDE | `Policy.can_start_review_agent?/1` + allowlisted `ReviewCommand` | `run.started` / terminal run event |
| MCP terminal tool call | DevIDE | Bearer auth + `devide_`-prefixed session guard | `Audit.Event` + activity feed |
| MCP preview tool call | DevIDE | Bearer auth + scoped preview session | `Audit.Event` + activity feed |
| Apply proposal | — | **Denied** (`:not_implemented`) | — |
| Enable agent write | — | **Denied** (`:agent_write_locked`) | — |
| Set workspace mode | DevIDE | `Policy.can_set_workspace_mode?/1` (operator/owner; not config-pinned) | `Audit.Event` |
| Read workspace status | DevIDE | Auth | `WorkspaceRecord` snapshot |
| Read audit log | DevIDE | Auth | `Audit.Event` |

## Adapter pattern

Persistence and detection boundaries use adapters configurable at runtime:

```elixir
# Workspace state
Application.get_env(:dev_ide, :workspace_state_adapter, DevIDE.Workspaces.State.MemoryAdapter)

# Audit log
Application.get_env(:dev_ide, :audit_adapter, DevIDE.Audit.MemoryAdapter)

# Agent detection
Application.get_env(:dev_ide, :agents_adapter, DevIDE.Agents.LocalAdapter)

# DB isolation probe
Application.get_env(:dev_ide, :isolation_probe, DevIDE.Workspaces.IsolationProbe.LocalAdapter)
```

## Configuration keys

| Key | Purpose | Default |
|---|---|---|
| `:api_token` / `DEV_IDE_API_TOKEN` | Bearer auth for API + MCP routes | nil (refuses all requests) |
| `:workspace_source` | Module implementing `DevIDE.WorkspaceSource` | `DevIDE.WorkspaceSource.Local` |
| `:workspaces_root` | Allowed filesystem root for workspace paths | `/workspaces` |
| `:workspace_modes` | Per-workid mode overrides | `%{}` |
| `:default_workspace_mode` | Fallback mode | `:review` |
| `:raw_terminal_everywhere` | Allow raw shell in any workspace/mode/host | `true` |
| `:tmux_idle_seconds` | Idle GC delay before killing an unsubscribed tmux session | disabled in dev, `600` in prod |
| `:shared_db_patterns` | Substrings/regexes for shared-stage DB detection | `[]` |
| `:unsafe_db_patterns` | Substrings/regexes for prod DB detection | `[]` |

## Key design invariants

1. **No arbitrary argv from a remote client.** The browser and MCP agents type
   into a guarded PTY; they do not submit argv to an executor. The one local
   executor (`DevIDE.Commands`) only runs fixed `ReviewCommand` argv.
2. **Raw-terminal admission is a server decision.** Every raw attach passes
   through `Policy.can_use_raw_terminal?/1`; the verdict (allow or deny) is
   recorded in the run ledger.
3. **MCP tools are scoped.** Terminal tools touch only `devide_`-prefixed tmux
   sessions; preview tools touch only a scoped preview session.
4. **Audit at egress.** Per-subsystem sanitizers strip credentials before JSON
   serialization.
5. **tmux is the persistence boundary.** A session outlives the LiveView socket
   and survives BEAM restarts; reattach replays scrollback from tmux history.

## Event plane

DevIDE operates on three time scales:

| Timescale | Mechanism | Consumers |
|---|---|---|
| Realtime | Phoenix Channels (terminal), LiveView, PubSub (activity feed) | Browser UI |
| Near-realtime | HTTP API + LiveView | Browser UI, status readers |
| Durable | Audit events + run-ledger events | Replay, review, post-mortem |

The durable plane is the safety-critical one. The operational state that
matters for review must be recoverable from `Audit.Event` + the run ledger
(`DevIDE.Runs.Ledger`).

## Future extension points (stable interfaces)

| Extension | Current | Future |
|---|---|---|
| Terminal substrate | Local host tmux + Ghostty PTY | SSH-backed `Terminals.Adapter` behaviour |
| Multi-pane terminal | Recursive split tree per LiveView | (already implemented; see terminal.md) |
| Idle session GC | `TmuxJanitor` timer | per-window finer-grained policy |
| Workspace mode enforcement | Deny writes | Fine-grained capability grants |

## Document index

| Document | Purpose |
|---|---|
| [`docs/product.md`](product.md) | What DevIDE is, server/client boundary, decision rules |
| [`docs/glossary.md`](glossary.md) | Operational terminology and event taxonomy |
| [`docs/terminal.md`](terminal.md) | Terminal subsystem architecture (Ghostty, tmux, multi-pane) |
| [`docs/terminal_mcp.md`](terminal_mcp.md) | Terminal MCP tool surface |
| [`docs/preview_mcp.md`](preview_mcp.md) | Preview MCP tool surface |
| [`docs/tmux_control_plane.md`](tmux_control_plane.md) | tmux topology/templates control plane |
| [`docs/state_machines.md`](state_machines.md) | Session, review-run, mode, and audit lifecycles |
| [`docs/sequence_diagrams.md`](sequence_diagrams.md) | Key interaction flows |
