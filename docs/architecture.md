# DevIDE Architecture

> Version: v2.1 (raw + MCP reality; authority and evidence freeze)
>
> This document is the authoritative narrative for the DevIDE workspace
> cockpit. When implementation and docs diverge, the docs win: fix the code.
>
> **History:** earlier versions described a delegated-execution stack —
> fleet coordination, a runner-assignment durable protocol, and a
> governed-command plane. That stack has been removed. The product collapsed
> to a single-runtime workspace cockpit: a durable raw terminal over tmux, an
> MCP tool interface for agents, preview, and an audit/activity feed. The
> first principles and subsystem map below describe what remains.
>
> **2026-07-21 freeze:** authority-per-concern, Audit-first evidence layering,
> decision/effect/outcome flow, reconnect semantics, and explicit non-goals.
> Canonical decision record: [`design/authority-evidence-freeze.md`](design/authority-evidence-freeze.md).

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
| FP-9  | **The cockpit must tolerate disconnect/recovery.** Network drops and server restarts are normal events the UI is designed for — not error states; reattach reauthenticates, reauthorizes, and restores server-owned scrollback from tmux. |
| FP-10 | **Execution leaves reviewable evidence.** Sensitive decisions and effects are recorded as `Audit.Event`. Run ledger and agent activity are projections over that evidence — not independent authorities. |

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

## Authority per concern

One server-side authority per concern; **no client authority**. Do not treat
a single store or event stream as able to reconstruct the whole system.

| Concern | Authority |
|---|---|
| Live process and scrollback | tmux |
| Workspace identity | WorkspaceSource / records |
| Evidence | Audit storage (`Audit.Event`) |
| Admission | Policy |

Events explain and audit the workspace; they do not replace tmux as the
live-execution substrate.

## Evidence layering (Audit-first)

| Layer | Role |
|---|---|
| `Audit.Event` | Canonical durable evidence |
| `Runs.Ledger` | Constrained run/session projection (`run.*` vocabulary) over Audit |
| `AgentEvents` | Operational projection (own dedupe, replay, retention, privacy) |

**Invariant:** Audit is the canonical evidence log. Run ledger and agent
activity are typed projections, never independent authorities. Separate
tables and projections are fine. Shared identity (event / correlation /
causation IDs) and explicit projection ownership prevent duplicated facts
with no reconciliation path.

Do **not** fold every MCP mutation or agent lifecycle event into the `run.*`
vocabulary.

## Decision / effect / outcome flow

Transports are adapters. Cross-subsystem workflows have one explicit
application-layer owner:

```text
LiveView / Channel / MCP
        ↓
resolve scope → decide policy → perform effect → append evidence
```

Preferred mutation shape (migrate domain by domain):

```text
execute(scope, action, input)
  → validate scope
  → decide policy
  → record decision
  → perform effect when allowed
  → record outcome
```

Dependencies remain acyclic. Policy, effect, and evidence orchestration must
not be duplicated inside Phoenix or MCP handlers. `Casein.Terminals.Boundary`
(policy + ledger recording behind one domain boundary) is the reference shape.

## Reconnect semantics

On reconnect a client must:

1. **Reauthenticate** the principal.
2. **Reauthorize** current access to the workspace/session.
3. **Restore** the server-owned view and scrollback (tmux is authority).
4. **Never** replay commands or accept cached client state as truth.

Historical decisions need not be recomputed. Present access is always rechecked.

## Explicit non-goals (architecture freeze)

- **No universal run ledger** — projections stay specialized.
- **No new MCP protocol version** — additive tools and result schemas only.
- **No premature domain `casein_core`** — `dev_ide_core` remains a mechanism package.
- **No tamper-evidence claim** — append-only API is not tamper-evident storage;
  hash chaining or signed checkpoints require an explicit threat model first.

Implementation order and slice definitions:
[`design/authority-evidence-freeze.md`](design/authority-evidence-freeze.md).

## System purpose

DevIDE is a **single-runtime workspace cockpit**. It owns durable terminal
sessions for a workspace, exposes those sessions (and a preview surface) to
external agents over MCP, and records what happened in an audit log and a run
ledger.

It does not execute arbitrary argv on behalf of a remote client. The two
execution paths that exist are deliberately narrow:

- **Raw terminal** — an operator (or an MCP agent) types into a server-side
  PTY backed by tmux. Admission is a `Policy.can_use_raw_terminal?/1` decision.
- **Review-agent runs** — `Casein.Agents.Run` spawns a fixed, allowlisted
  `Casein.Agents.ReviewCommand` argv as a local subprocess. There is no path
  through it to run an arbitrary command or apply a patch.

```text
Browser / MCP agent --attach/input--> DevIDE --PTY--> tmux session
                                         │
                                         └--reads--> workspace source
```

## Subsystem map

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Casein.BEAM                                       │
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
│    • Principal must be resolved server-side; audit must not accept       │
│      caller-forged actor attribution                                     │
│    • Terminal MCP drives tmux on devide_-prefixed sessions only          │
│    • Preview MCP drives a scoped preview session                         │
│    • Agents cannot reach arbitrary tmux sessions or arbitrary argv on    │
│      the host beyond what they type into a guarded session               │
│                                                                          │
│  Boundary 2: Browser → terminal channel / LiveView                       │
│    • CaseinWeb.ChannelAuth signs/verifies a user-socket token            │
│    • Raw input/resize write into the server-side PTY                     │
│    • Raw-terminal admission is gated by Policy.can_use_raw_terminal?/1   │
│                                                                          │
│  Boundary 3: DevIDE → Workspace source                                   │
│    • Pluggable via `Casein.WorkspaceSource` behaviour                    │
│    • Source is the truth for workspace existence and lifecycle           │
│    • DevIDE persists only redacted summaries                             │
│                                                                          │
│  Boundary 4: DevIDE → Host filesystem                                    │
│    • PathSafety validates all paths are under allowed roots              │
│    • No traversal or symlink-escape allowed                              │
│                                                                          │
│  Boundary 5: DevIDE → Audit / projections                                │
│    • Audit.Event is the canonical evidence record                        │
│    • Run ledger (Runs.Ledger) and AgentEvents are projections            │
│    • Audit adapter is swappable: MemoryAdapter → EctoAdapter             │
└────────────────────────────────────────────────────────────────────────┘
```

## Workspace metadata contract

Sources return `%Casein.Workspace{}`. Source-specific data lives under `metadata`.
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
| Apply proposal | DevIDE | `Policy.can_apply_proposal?/1` (operator + `:manual` mode) via `Casein.ProposalApply` | `Audit.Event` (`apply_proposal` decision + `proposal.applied` mutation) |
| Enable agent write (auto-apply) | DevIDE | `Policy.can_enable_agent_write?/1` (`:manual` mode + active `Workspaces.grant_agent_write_unlock/3` unlock) via `Casein.Proposals.AutoApply` | `Audit.Event` (`proposals.auto_apply_authorize`/`proposals.auto_applied`) + `run.approval_granted` ledger event |
| Grant/revoke agent write unlock | DevIDE | `Policy.can_grant_agent_write_unlock?/1` (operator + `:manual` mode) / `Policy.can_revoke_agent_write_unlock?/1` (operator only, no mode gate — the kill switch) | `Audit.Event` (`workspace.agent_write_unlock_granted`/`_revoked`/`_expired`) |
| Set workspace mode | DevIDE | `Policy.can_set_workspace_mode?/1` (operator/owner; not config-pinned) | `Audit.Event` |
| Read workspace status | DevIDE | Auth | `WorkspaceRecord` snapshot |
| Read audit log | DevIDE | Auth | `Audit.Event` |

## Adapter pattern

Persistence and detection boundaries use adapters configurable at runtime:

```elixir
# Workspace state
Application.get_env(:casein, :workspace_state_adapter, Casein.Workspaces.State.MemoryAdapter)

# Audit log
Application.get_env(:casein, :audit_adapter, Casein.Audit.MemoryAdapter)

# Agent detection
Application.get_env(:casein, :agents_adapter, Casein.Agents.LocalAdapter)

# DB isolation probe
Application.get_env(:casein, :isolation_probe, Casein.Workspaces.IsolationProbe.LocalAdapter)
```

## Configuration keys

| Key | Purpose | Default |
|---|---|---|
| `:api_token` / `CASEIN_API_TOKEN` | Bearer auth for API + MCP routes | nil (refuses all requests) |
| `:workspace_source` | Module implementing `Casein.WorkspaceSource` | `Casein.WorkspaceSource.Local` |
| `:workspaces_root` | Allowed filesystem root for workspace paths | `/workspaces` |
| `:workspace_modes` | Per-workid mode overrides | `%{}` |
| `:default_workspace_mode` | Fallback mode | `:manual` |
| `:raw_terminal_everywhere` | Allow raw shell in any workspace/mode/host; otherwise raw requires local host + manual mode | `false` |
| `:mcp_max_body_bytes` / `CASEIN_MCP_MAX_BODY_BYTES` | Max POST body size for terminal/preview/artifact MCP requests before JSON-RPC handling | `1_000_000` |
| `:tmux_idle_seconds` | Idle GC delay before killing an unsubscribed tmux session | disabled in dev, `600` in prod |
| `:shared_db_patterns` | Substrings/regexes for shared-stage DB detection | `[]` |
| `:unsafe_db_patterns` | Substrings/regexes for prod DB detection | `[]` |
| `Casein.Proposals.AutoApply` `enabled:` / `CASEIN_AGENT_AUTO_APPLY_ENABLED` | Deployment-wide kill switch for a review-agent run self-applying its own proposal; independent of any per-workspace unlock | `false` |

## Key design invariants

1. **No arbitrary argv from a remote client.** The browser and MCP agents type
   into a guarded PTY; they do not submit argv to an executor. The one local
   executor (`Casein.Commands`) only runs fixed `ReviewCommand` argv.
2. **Raw-terminal admission is a server decision.** Every raw attach passes
   through `Policy.can_use_raw_terminal?/1`; the verdict (allow or deny) is
   recorded in the run ledger.
3. **MCP tools are scoped.** Terminal tools touch only `devide_`-prefixed tmux
   sessions; preview tools touch only a scoped preview session.
4. **Audit at egress.** Per-subsystem sanitizers strip credentials before JSON
   serialization.
5. **tmux is the persistence boundary.** A session outlives the LiveView socket
   and survives BEAM restarts; reattach restores server-owned scrollback from
   tmux history after reauth/reauthz.
6. **Audit is canonical evidence.** Run ledger and agent activity project from
   it; they are not parallel authorities.

## Event plane

DevIDE operates on three time scales:

| Timescale | Mechanism | Consumers |
|---|---|---|
| Realtime | Phoenix Channels (terminal), LiveView, PubSub (activity feed) | Browser UI |
| Near-realtime | HTTP API + LiveView | Browser UI, status readers |
| Durable | `Audit.Event` (+ run-ledger / agent-activity projections) | Replay, review, post-mortem |

The durable plane is the safety-critical one. Security-relevant review must be
recoverable from `Audit.Event`. Run summaries and agent session replay are
projections with their own retention and privacy rules.

**Append-only is not tamper-evident.** The API may prohibit updates/deletes;
a database operator can still rewrite rows. Tamper evidence requires hash
chaining, signed checkpoints, or an external immutable sink — and an explicit
threat model before any product claim.

## Future extension points (stable interfaces)

| Extension | Current | Future |
|---|---|---|
| Terminal substrate | Local host tmux + Ghostty PTY | SSH-backed `Terminals.Adapter` behaviour |
| Multi-pane terminal | Recursive split tree per LiveView | (already implemented; see terminal.md) |
| Idle session GC | `TmuxJanitor` timer | per-window finer-grained policy |
| Workspace mode enforcement | Deny writes | Fine-grained capability grants |
| Pure policy evaluation | Policy mixes fact gathering + decide | `evaluate(action, facts) → decision` with facts gathered outside |

## Document index

| Document | Purpose |
|---|---|
| [`docs/product.md`](product.md) | What DevIDE is, server/client boundary, decision rules |
| [`docs/glossary.md`](glossary.md) | Operational terminology and event taxonomy |
| [`docs/design/authority-evidence-freeze.md`](design/authority-evidence-freeze.md) | Authority/evidence freeze and vertical-slice order |
| [`docs/terminal.md`](terminal.md) | Terminal subsystem architecture (Ghostty, tmux, multi-pane) |
| [`docs/terminal_mcp.md`](terminal_mcp.md) | Terminal MCP tool surface |
| [`docs/preview_mcp.md`](preview_mcp.md) | Preview MCP tool surface |
| [`docs/tmux_control_plane.md`](tmux_control_plane.md) | tmux topology/templates control plane |
| [`docs/state_machines.md`](state_machines.md) | Session, review-run, mode, and audit lifecycles |
| [`docs/sequence_diagrams.md`](sequence_diagrams.md) | Key interaction flows |
| [`docs/subsystems/audit_activity.md`](subsystems/audit_activity.md) | Audit / ledger / activity subsystem |
