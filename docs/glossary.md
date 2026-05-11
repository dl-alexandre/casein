# Glossary and Operational Terminology

> Version: v1 (aligned with implementation as of M30)
>
> This document has two layers:
>
> - **§Architectural constraints** (below) — load-bearing terms whose
>   meaning must stay stable across UI, API, telemetry, CLI, and docs.
>   Each entry includes a "Must not mean" column. Drift here is not
>   pedantry; it is the slow path to product incoherence.
> - **§Core concepts** onward — protocol- and implementation-level
>   vocabulary (assignment, claim token, safe action, …) used by the
>   runner protocol and internals.
>
> Cross-references: [`product.md`](product.md) §1–§7 introduces these
> terms in narrative form; [`architecture.md`](architecture.md)
> "First principles" is stated in this vocabulary.

## Architectural constraints

The following terms are constraints, not suggestions. APIs, telemetry,
UI labels, log lines, and CLI commands must use them as defined here.
If a new feature needs a meaning that is not in this table, add the
term — do not overload an existing one.

| Term            | Means                                                                                  | Must not mean                                                                  |
|-----------------|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| **DevIDE**      | The product: workspace runtime + cockpit, considered as one named thing                | A specific UI component, a specific process, or the CLI alone                  |
| **Runtime**     | Durable server-side execution authority for a workspace; owns sessions, gate, audit    | The editor UI; a JS event loop; a generic "backend"                            |
| **Cockpit**     | Human-facing interaction surface (browser terminal + cockpit chrome)                   | The execution engine; anything that decides what may run                       |
| **Workspace**   | An isolated execution environment: git tree + filesystem + session + mode + audit      | An open tab; a directory you happen to have cd'd into; arbitrary project metadata |
| **Operator**    | The human (or agent acting on a human's behalf) interacting through the cockpit        | A sysadmin role title; a process that executes commands                        |
| **Agent**       | A non-human client of the runtime contract                                             | An in-process actor; a chatbot; the LLM itself; an "AI feature"                |
| **Runner**      | A worker process that polls assignments, claims a lease, executes, and reports         | A scheduler; a policy engine; a workspace; a runtime                           |
| **Command**     | Requested operation intent                                                            | argv authority; shell input; the execution lifecycle                           |
| **Run**         | Execution lifecycle of a command                                                       | A browser tab; a raw shell session; a runner process                           |
| **Assignment**  | Delegated ownership of a run by a runner                                               | A transient HTTP request; a command; the execution itself                       |
| **Lease**       | Time-bounded execution ownership of an assignment by a specific runner                 | A permanent lock; a workspace mode; an authentication session                  |
| **Mode**        | A workspace's admission policy level: `safe` / `review` / `write`                      | Network mode; display theme; an "AI on/off" toggle; a user preference          |
| **Policy gate** | Server-side admission evaluation: argv against allowlist + workspace mode + lease      | A UI checkbox; a client-side filter; a linter; a feature flag                  |
| **Governed command** | A cockpit command line resolved to a Command before execution authority is granted | Raw shell input; arbitrary argv; a browser-side command parser                 |
| **Raw shell**   | Explicit trusted/local Session input into tmux                                         | The default command plane; a governed operation; a fleet assignment            |
| **Audit**       | The replay-safe, time-ordered event stream of every governed decision                  | A log file; verbose stdout; metrics; a debug channel                           |
| **Replay**      | Reconstruction of session/audit state from the durable log when a client reattaches    | Re-running a command; redo/undo; output buffering alone                        |
| **Fleet**       | A coordinated multi-runtime topology — many DevIDE runtimes under one coordinator      | Many tabs; many workspaces on one runtime; a server cluster behind a load balancer |
| **Coordinator** | The fleet-mode planner/scheduler that routes intent across runtimes (today: JX)        | A runtime; a runner; a policy engine; the cockpit                              |
| **JX**          | The current implementation of Coordinator                                              | A synonym for "DevIDE"; the runtime; the runner                                |
| **Capability**  | A boolean or value the runtime advertises, gating which UI surfaces render             | A user role; a permission grant; a feature flag                                |
| **Host**        | The machine a runtime happens to be reachable on                                       | A workspace; an account; an organizational unit                                |
| **Session**     | A live, durable PTY+state attachment to a workspace (tmux underneath, but not "tmux")  | The HTTP/websocket connection; a browser tab; a login                          |
| **Attach**      | A cockpit connecting to a running session                                              | Starting a new session; logging in; subscribing to telemetry                   |
| **Resume**      | Reattaching after disconnect, with buffered output and reconstructed state             | Re-running a command; restoring from snapshot; replaying audit alone           |

The "Must not mean" column is the load-bearing one. If you find these
words being used in their forbidden senses anywhere in the codebase,
docs, or UI — fix the usage, not the glossary.

## Core concepts

### Session
Interactive attachment to a workspace. A session can be governed (line-oriented
command submission) or raw (direct PTY input to tmux). Session must not mean the
HTTP connection or a browser tab.

### Command
Requested operation intent. A command is what an operator asks DevIDE to do,
such as `mix test`. A command is not argv authority; policy and the allowlist
decide whether it may become a run.

### Run
Execution lifecycle of a command. Runs are the canonical units in the run
ledger. A run can be local, remote, or delegated, but it always represents the
same lifecycle vocabulary.

### Assignment
Delegated ownership of a run by a runner. An assignment is created by DevIDE
(never by a runner), claimed by a runner, reported against, and terminated.

### Claim token
An opaque UUID issued at claim time. The runner must include it in every
subsequent report, complete, or fail call. The claim token is the bearer
credential for the assignment lease.

### Safe action
An entry in `DevIDE.Runners.SafeAction` that maps a stable id (e.g.
`"command:test"`) to an argv list (`["mix", "test", "--color"]`).
Safe actions are derived from `DevIDE.Commands.allowlist/0`. The runner
receives the resolved argv at claim time, never from JX or the runner itself.
Safe action is a derived executable shape, not a fifth operational noun.

### Governed command
An operator-entered terminal line that DevIDE parses into a known command id,
checks against policy, audits, and turns into a safe-action assignment. A
governed command is intent, not argv authority.

### Raw shell
Direct PTY input to tmux. Raw shell is available only when policy allows the
raw terminal action (local host plus manual workspace mode). It is an escape
hatch, not the product proof for governed execution.

### Runner
An external process (human, CI job, or autonomous agent) that polls DevIDE for
assignments, claims one, executes the safe action argv on the target workspace,
and reports progress. Runners are **not** trusted with argv authority.

### JX
The orchestration client that observes DevIDE via the read API and may trigger
reruns via `POST /api/workspaces/:id/runs`. JX does not execute commands
itself; it either triggers an immediate local run or enqueues a durable runner
assignment.

### Workspace
A milc-devbox managed development environment. The manager is the source of truth
for lifecycle. DevIDE maintains a redacted, denormalized cache (`WorkspaceRecord`)
for fast API responses.

### Mode
A workspace safety mode (`:manual`, `:review`, `:agent_write_locked`,
`:shared_stage_guarded`). Modes gate agent write capabilities and command
execution for JX/agent actors.

### DB isolation
Classification of the workspace's database connection: `:local`, `:ephemeral`,
`:shared_stage`, or `:unsafe`. Detected by `IsolationProbe` from env/config.

### Policy decision
The result of `DevIDE.Policy.can_<action>?/1`: `%Decision{verdict: :allow | :deny, reason: atom, mode: atom}`.
Every blocked decision is audited.

## Event taxonomy

### Run ledger events

The run ledger is stored in audit events with `metadata.ledger == "run"`.
The canonical actions are:

| Action | When | Actor | Target |
|---|---|---|---|
| `run.session_attached` | Raw session attached after explicit policy allow | operator | `session` |
| `run.session_denied` | Raw session refused by policy | operator | `session` |
| `run.command_requested` | Governed command accepted as intent | operator/JX | `command` |
| `run.command_denied` | Command refused before it becomes a run | operator/JX | `command` |
| `run.queued` | Run created and queued from a safe action | requester | `run` |
| `run.started` | Immediate local run started | requester | `run` |
| `run.succeeded` | Immediate local run exited successfully | runtime | `run` |
| `run.failed` | Immediate local run exited unsuccessfully | runtime | `run` |
| `run.timed_out` | Immediate local run hit the hard timeout | runtime | `run` |
| `run.approval_requested` | Human approval requested before execution continues | requester/runtime | `run` |
| `run.approval_granted` | Human approval granted | reviewer/operator | `run` |
| `run.approval_denied` | Human approval denied | reviewer/operator | `run` |
| `run.assignment_claimed` | Runner claims delegated ownership | `runner_id` | `assignment` |
| `run.assignment_succeeded` | Runner reports terminal success | `runner_id` | `assignment` |
| `run.assignment_failed` | Runner reports terminal failure | `runner_id` | `assignment` |
| `run.assignment_expired` | Assignment lease expires | runtime | `assignment` |
| `run.assignment_abandoned` | Assignment is abandoned/released | runtime/JX | `assignment` |

### Legacy audit events

General policy paths outside operational execution still produce older audit
actions:

| Action | When | Actor | Target |
|---|---|---|---|
| `policy.blocked` | Generic policy denial outside the run ledger | original actor | the blocked target |

### Progress report events (runner protocol)

| Event | Purpose | State effect |
|---|---|---|
| `started` | Runner began executing argv | `claimed` → `running` |
| `progress` | Arbitrary human-readable progress | `claimed` → `running` if first |
| `stdout` | Captured stdout line/chunk | `claimed` → `running` if first |
| `stderr` | Captured stderr line/chunk | `claimed` → `running` if first |
| `heartbeat` | Liveness ping (no state change) | none |
| `evidence` | Structured output / artifact metadata | `claimed` → `running` if first |
| `completed` | Terminal success (implicit from `POST .../complete`) | → `succeeded` |
| `failed` | Terminal failure (implicit from `POST .../fail`) | → `failed` |

### Capabilities

A capability string declares what a runner can do. The only v1 capability is:

- `workspace-command:v1` — runner can execute workspace safe actions

Future capabilities may include:
- `workspace-command:v2`
- `git:v1`
- `docker:v1`

## Data structures

### Assignment payload (replay)

```json
{
  "id": "uuid",
  "workspace_id": "workspace-name",
  "safe_action_id": "command:test",
  "safe_action_version": 1,
  "action": {
    "id": "command:test",
    "version": 1,
    "kind": "workspace_command",
    "command_id": "test",
    "argv": ["mix", "test", "--color"],
    "requires": ["workspace-command:v1"],
    "description": "Run the allowlisted test workspace command."
  },
  "status": "running",
  "requested_by": "jx",
  "claimed_by": "runner-42",
  "queued_at": "2024-...",
  "claimed_at": "2024-...",
  "lease_expires_at": "2024-...",
  "completed_at": null,
  "failure_reason": null,
  "failure_class": null,
  "evidence": {},
  "metadata": {}
}
```

The `claim_token` is **only** included in the poll response, never in replay.

### Progress report payload

```json
{
  "id": "uuid",
  "assignment_id": "uuid",
  "client_report_id": "runner-local-seq-7",
  "runner_id": "runner-42",
  "position": 3,
  "event": "stdout",
  "stream": "stdout",
  "message": null,
  "data": "...",
  "data_truncated": false,
  "evidence": {},
  "failure_class": null,
  "observed_at": "2024-...",
  "inserted_at": "2024-..."
}
```

### Workspace status payload (summary)

```json
{
  "workspace": {
    "id": "my-app",
    "name": "my-app",
    "status": "running",
    "host_path_present": true,
    "manager_last_seen_at": "2024-..."
  },
  "mode": { "value": "review", "source": "default" },
  "db_isolation": {
    "isolation": "local",
    "source": "config",
    "redacted_summary": "host=localhost db=dev",
    "detected_at": "2024-..."
  },
  "git": { "available": true, "changed_files": 3, "entries": [...] },
  "active_run": { ... } | null,
  "recent_runs": [...],
  "recent_proposals": [...],
  "recent_audit": [...]
}
```

No credentials, no file contents, no terminal scrollback.

## Time fields

| Field | Meaning | Set by |
|---|---|---|
| `queued_at` | Assignment entered the queue | `Runners.enqueue/3` |
| `claimed_at` | Runner claimed assignment | `MemoryAdapter.claim_one/1` |
| `lease_expires_at` | Claim token expires | `MemoryAdapter.claim_one/1` |
| `completed_at` | Terminal report or abandon processed | `MemoryAdapter.complete/3` or `abandon/2` |
| `started_at` | Immediate command process spawned | `Commands.Run.init/1` |
| `finished_at` | Immediate command exited or timed out | `Commands.Run.finish/3` |
| `observed_at` | Runner's claim of when event happened | Runner report payload |
| `inserted_at` | Record persisted in DevIDE | Adapter |
| `updated_at` | Assignment record mutated | Adapter |

## Routing fields (advisory)

Poll requests may include routing hints. DevIDE uses them only for scheduling,
never for authorization:

| Field | Example | Purpose |
|---|---|---|
| `host` | `"host-a"` | Pin to specific host |
| `os` | `"darwin"` | OS compatibility |
| `repo` | `"onebackend-v3"` | Repository filter |
| `branch_isolation` | `"worktree"` | Branch isolation strategy |
| `tools` | `["mix", "git"]` | Required tooling |
| `runtime_id` | `"rt-123"` | Runtime placement hint |
| `runtime_path` | `"/run/rt-123"` | Runtime filesystem path |
| `active_assignments` | `2` | Runner load |
| `concurrency_limit` | `4` | Runner capacity |

## Redaction keys

The following keys are stripped from all outbound payloads:

- `database_url`, `postgres_url`, `pg_url`, `db_url`
- `password`, `pgpassword`, `postgres_password`
- `secret`, `token`, `api_key`, `auth`, `bearer`, `cookie`, `session_id`
- Inside `env` / `environment` arrays: values for keys matching the above are replaced with `[REDACTED]`
