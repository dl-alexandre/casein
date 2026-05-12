# DevIDE Architecture

> Version: v1 (aligned with implementation as of M10)
>
> This document is the authoritative narrative for the DevIDE orchestration
> system. When implementation and docs diverge, the docs win: fix the code.

## First principles

These are the invariants the architecture is built to honor. Every section
below — and every future change — is judged against them. Cite by number
in tickets and reviews (e.g. "this violates §FP-6").

| #     | Invariant                                                                          |
|-------|------------------------------------------------------------------------------------|
| FP-1  | **Execution authority lives server-side.** The cockpit cannot run argv. The runtime decides what runs. |
| FP-2  | **Sessions are durable by default.** A workspace session outlives the client connection that opened it. |
| FP-3  | **The UI reflects runtime truth.** Capabilities, state, and history are rendered from what the runtime reports — not assumed, not mocked. |
| FP-4  | **Local / remote / fleet are topology variants, not separate products.** The same client, the same UI shape, the same vocabulary apply to all three. |
| FP-5  | **Operators interact with runtimes, not machines.** A workspace is the addressable thing; the host underneath is an implementation detail of where that runtime happens to live. |
| FP-6  | **Runners execute policy; they do not decide policy.** The gate is enforced before a runner is offered work. Runners stay simple, replaceable, and safe to scale. |
| FP-7  | **Fleet composes runtimes.** JX coordinates intent across DevIDE authorities; it does not bypass any one of them. A fleet is many single-runtime stacks under coordination, not a different runtime. |
| FP-8  | **The runtime must function without the cockpit.** Sessions persist, audit accrues, leases expire and reclaim, all without any UI client connected. |
| FP-9  | **The cockpit must tolerate runtime disconnect/recovery.** Network drops, server restarts, and lease handoffs are normal events the UI is designed for — not error states. |
| FP-10 | **Delegated execution leaves reviewable evidence.** Every delegated execution must be traceable by assignment, execution, runner, workspace, lease, command, exit status, artifacts, failures, and recovery actions. |

These invariants are upstream of every other architectural choice in this
document. If a proposed change requires weakening one of them, the change
is the wrong shape — find another way.

See also: [`product.md`](product.md) §4 (server/client boundary) and §13
(decision rules) for product-level enforcement; [`glossary.md`](glossary.md)
for the term constraints these invariants are stated in.

## System purpose

DevIDE is the **read-only API producer** and **delegated execution authority**
for the JX ↔ milc-devbox integration. It does not embed JX runtime code. It does
not execute workspace commands directly (except in dev fallback mode). It
queues, routes, audits, and replays runner-assigned work.

Dependency direction:

```text
JX --HTTP observe + approved rerun--> DevIDE --wraps--> milc-devbox
                     ^
                     |
              durable runner
              (pull/report/claim)
```

## Subsystem map

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DevIDE.BEAM                                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   Web Tier   │  │   Runners    │  │   Commands   │  │  Workspaces  │      │
│  │  (Phoenix)   │  │   (Protocol) │  │   (Local)    │  │   (State)    │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                 │                 │                 │              │
│  ┌──────┴───────┐  ┌──────┴───────┐  ┌──────┴───────┐  ┌──────┴───────┐  │
│  │  Audit       │  │  Policy      │  │  History     │  │  Isolation   │  │
│  │  (Events)    │  │  (Decisions) │  │  (Records)   │  │  (DB Probe)  │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Adapters / Boundaries                        │   │
│  │  MemoryAdapter ──► EctoAdapter (M11 migration path, no caller change)│   │
│  │  LocalAdapter  ──► HTTP / SSH / External runners                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
         │                      │                      │
         ▼                      ▼                      ▼
   ┌──────────┐          ┌──────────┐          ┌──────────┐
   │    JX    │          │  Runner  │          │ Manager  │
   │ (Client) │          │ (Claim)  │          │(Devbox)  │
   └──────────┘          └──────────┘          └──────────┘
```

## Trust boundaries

```
┌────────────────────────────────────────────────────────────────────────┐
│                         Trust Boundary Map                             │
├────────────────────────────────────────────────────────────────────────┤
│  Boundary 1: JX → DevIDE API                                           │
│    • Authenticated via bearer token (ApiAuth plug)                     │
│    • Read-only GETs are ungated beyond auth                            │
│    • POST /workspaces/:id/runs is gated by Policy + SafeAction         │
│    • JX cannot send arbitrary argv, shell strings, or mutation paths     │
│                                                                        │
│  Boundary 2: Runner → DevIDE Runner API                                │
│    • Authenticated via same bearer token                               │
│    • Runners can only claim and report; cannot create assignments      │
│    • Claim token is a single-use opaque lease                          │
│    • No runner endpoint accepts arbitrary argv or shell strings         │
│                                                                        │
│  Boundary 3: DevIDE → milc-devbox Manager                             │
│    • HTTP client (Req) with 15s timeout, no retry                      │
│    • Manager is the source of truth for workspace lifecycle            │
│    • DevIDE persists only redacted summaries (sanitize_manager_payload)│
│                                                                        │
│  Boundary 4: DevIDE → Host filesystem                                 │
│    • PathSafety validates all paths are under allowed roots            │
│    • No traversal or symlink-escape allowed                            │
│                                                                        │
│  Boundary 5: DevIDE → Audit / History stores                           │
│    • Audit records every policy decision and sensitive action          │
│    • History records every command run with capped output              │
│    • Both swappable: MemoryAdapter → EctoAdapter without caller change │
└────────────────────────────────────────────────────────────────────────┘
```

## Authority map

| Action | Authority | Gate | Immutable Record |
|---|---|---|---|
| Create workspace | Manager | Manager API | — |
| Start/stop/delete workspace | Manager | Manager API | — |
| Queue runner assignment | DevIDE | Policy + SafeAction + `enqueue/3` | `Assignment` |
| Delegate workspace command | DevIDE Fleet | SafeAction + placement + lease + protocol validation | `Assignment` + `Execution` + dossier |
| Place runtime | DevIDE | Host/runtime capability match only | `Runtime` + lifecycle events |
| Claim assignment | DevIDE | Runner poll + capability match + routing | `Assignment` (claim_token) |
| Append progress report | Runner | Claim token + lease validity | `ProgressReport` |
| Complete/fail assignment | Runner | Claim token + evidence required | `Assignment` + `ProgressReport` |
| Expire lease | DevIDE | `expire_leases/1` cron | `Assignment` |
| Abandon assignment | DevIDE | State machine transition | `Assignment` |
| Run immediate command | DevIDE | Policy + `Rerun.start/3` | `History.Record` |
| Apply proposal | — | **Denied** (`:not_implemented`) | — |
| Enable agent write | — | **Denied** (`:agent_write_locked`) | — |
| Read workspace status | DevIDE | Auth | `WorkspaceRecord` snapshot |
| Read audit log | DevIDE | Auth | `Audit.Event` |

## Adapter pattern

Every persistence boundary uses an adapter configurable at runtime:

```elixir
# Runner assignments
Application.get_env(:dev_ide, :runner_protocol_adapter, DevIDE.Runners.MemoryAdapter)

# Runtime orchestration
Application.get_env(:dev_ide, :runtime_orchestration_adapter, DevIDE.Runtimes.MemoryAdapter)

# Workspace state
Application.get_env(:dev_ide, :workspace_state_adapter, DevIDE.Workspaces.State.MemoryAdapter)

# Command history
Application.get_env(:dev_ide, :command_history_adapter, DevIDE.Commands.History.MemoryAdapter)

# Audit log
Application.get_env(:dev_ide, :audit_adapter, DevIDE.Audit.MemoryAdapter)

# Commands spawn
Application.get_env(:dev_ide, :commands_adapter, DevIDE.Commands.LocalAdapter)

# Agent detection
Application.get_env(:dev_ide, :agents_adapter, DevIDE.Agents.LocalAdapter)

# DB isolation probe
Application.get_env(:dev_ide, :isolation_probe, DevIDE.Workspaces.IsolationProbe.LocalAdapter)
```

The M11 migration path is: add Ecto-backed adapter, change config, zero caller changes.

## Configuration keys

| Key | Purpose | Default |
|---|---|---|
| `:api_token` / `DEV_IDE_API_TOKEN` | Bearer auth for all API routes | nil (refuses all requests) |
| `:manager_url` / `MILC_DEVBOX_MANAGER_URL` | milc-devbox Node manager base URL | `http://localhost:9000` |
| `:workspaces_root` | Allowed filesystem root for workspace paths | `/workspaces` |
| `:workspace_modes` | Per-workid mode overrides | `%{}` |
| `:default_workspace_mode` | Fallback mode | `:review` |
| `:runner_assignment_lease_ms` | Claim lease duration | `900_000` (15 min) |
| `:runtime_orchestration_adapter` | Runtime/host/event persistence | `DevIDE.Runtimes.EctoAdapter` |
| `:command_timeout_ms` | Hard timeout for immediate commands | `1_800_000` (30 min) |
| `:shared_db_patterns` | Substrings/regexes for shared-stage DB detection | `[]` |
| `:unsafe_db_patterns` | Substrings/regexes for prod DB detection | `[]` |

## Key design invariants

1. **No arbitrary argv**: `Commands.allowlist/0` is the only source of argv. `SafeAction` derives from it. Runners cannot inject argv.
2. **No generic HTTP proxy action**: No endpoint translates a runner request into an arbitrary HTTP call.
3. **No runner creates assignments**: The `POST /api/runner/v1/assignments/poll` endpoint claims only; `POST /api/workspaces/:id/runs` (JX) enqueues.
4. **Append-only reports**: `ProgressReport` records are never mutated. Replays are stable.
5. **Evidence required for terminals**: `complete` and `fail` require non-empty `evidence` map.
6. **Redaction at egress**: `Export.Sanitizer` + per-subsystem sanitizers strip credentials before JSON serialization.
7. **Policy before work**: Every mutation checks `Policy.Decision` first; blocked decisions are audited.
8. **Replay is read-only**: `GET /api/runner/v1/assignments/:id` returns the exact same payload every time.
9. **Takeover is governed**: Operator takeover preparation is read-only; takeover input is governed safe-command input unless raw mode is explicitly policy-allowed.
10. **Artifacts are observational**: Output and artifact chunks require an active execution but never mutate assignment or lease state.

## Event plane

DevIDE operates on three time scales:

| Timescale | Mechanism | Consumers |
|---|---|---|
| Realtime | Phoenix Channels (terminal), PubSub (future) | Browser UI |
| Near-realtime | HTTP API + LiveView | Browser UI, JX observer |
| Durable | Append-only runner reports + audit events + history records | Replay, reconciliation, post-mortem |

The durable plane is the safety-critical one. All operational state that matters
governance must be recoverable from: `Assignment` + `ProgressReport` + `Audit.Event` + `History.Record`.

## Future extension points (stable interfaces)

| Extension | Current | Future |
|---|---|---|
| Runner substrate | Local host tmux | SSH-backed `Terminals.Adapter` behaviour |
| Fleet scheduling | MemoryAdapter queue | Ecto-backed queue + priority |
| Multi-pane terminal | One session per tab | tmux split surfaced as separate channels |
| Idle session GC | None | Timer in `Session` GenServer |
| Workspace mode enforcement | Deny writes | Fine-grained capability grants |

All of these slot in without changing the authority map or the protocol contract.

## Document index

| Document | Purpose |
|---|---|
| [`docs/jx_devide.md`](jx_devide.md) | Authoritative JX ↔ DevIDE protocol v1 contract |
| [`docs/state_machines.md`](state_machines.md) | Assignment lifecycle, lease lifecycle, command lifecycle |
| [`docs/failure_taxonomy.md`](failure_taxonomy.md) | Failure classes, HTTP mapping, reconciliation |
| [`docs/glossary.md`](glossary.md) | Operational terminology, event taxonomy, payload schemas |
| [`docs/sequence_diagrams.md`](sequence_diagrams.md) | Key interaction flows (8 diagrams) |
| [`docs/protocol_governance.md`](protocol_governance.md) | Version policy, changelog, fixture law, drift test policy |
| [`docs/runtime_orchestration.md`](runtime_orchestration.md) | Runtime lifecycle, placement rules, CLI, recovery |
| [`docs/operator_lifecycle.md`](operator_lifecycle.md) | Delegated execution lifecycle, evidence trail, Mermaid flow |
| [`docs/runtime_orchestration_plan.md`](runtime_orchestration_plan.md) | Historical workspace provisioning plan |
| [`docs/terminal.md`](terminal.md) | Terminal subsystem architecture (xterm.js, tmux, erlexec) |
