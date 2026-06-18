# Glossary and Operational Terminology

> Version: v2 (raw + MCP reality)
>
> This document has two layers:
>
> - **§Architectural constraints** (below) — load-bearing terms whose
>   meaning must stay stable across UI, API, telemetry, and docs.
>   Each entry includes a "Must not mean" column. Drift here is not
>   pedantry; it is the slow path to product incoherence.
> - **§Core concepts** onward — implementation-level vocabulary used by the
>   terminal, MCP, and audit internals.
>
> **History:** earlier versions defined a delegated-execution vocabulary
> (assignment, lease, claim token, runner, safe action, fleet, coordinator,
> JX, governed command). That subsystem was removed; those terms are no longer
> part of the product and have been dropped from this glossary.
>
> Cross-references: [`product.md`](product.md) §1–§7 introduces these
> terms in narrative form; [`architecture.md`](architecture.md)
> "First principles" is stated in this vocabulary.

## Architectural constraints

The following terms are constraints, not suggestions. APIs, telemetry,
UI labels, log lines, and docs must use them as defined here.
If a new feature needs a meaning that is not in this table, add the
term — do not overload an existing one.

| Term            | Means                                                                                  | Must not mean                                                                  |
|-----------------|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| **DevIDE**      | The product: workspace runtime + cockpit, considered as one named thing                | A specific UI component, a specific process, or the CLI alone                  |
| **Runtime**     | Durable server-side authority for a workspace; owns sessions, raw-terminal admission, audit | The editor UI; a JS event loop; a generic "backend"                       |
| **Cockpit**     | Human-facing interaction surface (browser terminal + cockpit chrome)                   | The execution engine; anything that decides what may run                       |
| **Workspace**   | An isolated environment: git tree + filesystem + session + mode + audit                | An open tab; a directory you happen to have cd'd into; arbitrary project metadata |
| **Operator**    | The human (or agent acting on a human's behalf) interacting through the cockpit        | A sysadmin role title; a process that executes commands                        |
| **Agent**       | A non-human MCP client of the runtime (terminal + preview tools)                       | An in-process actor; a chatbot; the LLM itself; an "AI feature"                |
| **Run**         | Execution lifecycle of a review-agent run                                              | A browser tab; a raw shell session; an arbitrary command                       |
| **Mode**        | A workspace's admission policy level (`:manual` / `:review` / `:agent_write_locked` / `:shared_stage_guarded`) | Network mode; display theme; an "AI on/off" toggle; a user preference          |
| **Policy decision** | Server-side admission evaluation (e.g. raw-terminal admission, review-agent start) | A UI checkbox; a client-side filter; a linter; a feature flag                  |
| **Raw shell**   | Direct Session input into a server-side PTY (tmux), admitted by policy                  | A governed operation; a delegated assignment                                   |
| **Audit**       | The time-ordered event stream of sensitive decisions and agent MCP calls                | A log file; verbose stdout; metrics; a debug channel                           |
| **Replay**      | Reconstruction of session/scrollback state when a client reattaches (from tmux history) | Re-running a command; redo/undo                                                |
| **MCP**         | The agent-facing tool interface (terminal + preview servers DevIDE hosts)               | The agent loop itself; a generic HTTP proxy; arbitrary host shell access       |
| **Capability**  | A boolean or value the runtime advertises, gating which UI surfaces render             | A user role; a permission grant; a feature flag                                |
| **Host**        | The machine a runtime happens to be reachable on                                       | A workspace; an account; an organizational unit                                |
| **Session**     | A live, durable PTY+state attachment to a workspace (tmux underneath, but not "tmux")  | The HTTP/websocket connection; a browser tab; a login                          |
| **Attach**      | A cockpit (or MCP agent) connecting to a running session                               | Starting a new session; logging in; subscribing to telemetry                   |
| **Resume**      | Reattaching after disconnect, with buffered scrollback and reconstructed state         | Re-running a command; restoring from snapshot                                  |

The "Must not mean" column is the load-bearing one. If you find these
words being used in their forbidden senses anywhere in the codebase,
docs, or UI — fix the usage, not the glossary.

## Core concepts

### Session
Interactive attachment to a workspace: direct PTY input into a server-side
tmux session via the Ghostty cell grid. Session must not mean the HTTP
connection or a browser tab. Raw-terminal admission is a `Policy` decision.

### Run
Execution lifecycle of a review-agent run (`DevIDE.Agents.Run`). A run is the
canonical unit in the run ledger. Review runs spawn a fixed, allowlisted
`DevIDE.Agents.ReviewCommand` argv as a local subprocess; there is no arbitrary
command path.

### Raw shell
Direct PTY input to tmux. Raw shell is admitted when
`Policy.can_use_raw_terminal?/1` allows it — universally available by default
(`:raw_terminal_everywhere`), or gated to a local host plus manual workspace
mode when that env is disabled.

### MCP tools
External coding agents drive DevIDE over two MCP surfaces:

- **Terminal MCP** (`DevIDE.Agents.TerminalTools`) — list sessions, read pane
  scrollback, send keys/commands to `devide_`-prefixed tmux sessions.
- **Preview MCP** (`DevIDE.Agents.PreviewTools`) — open/observe/screenshot a
  scoped preview session.

Every mutating MCP call is recorded by `DevIDE.Agents.MCPAudit` (audit + the
live activity feed). MCP gives an agent the same reach a human has from the
CLI — not arbitrary host shell access.

### Workspace
A development environment provided by a `DevIDE.WorkspaceSource`. The source
owns lifecycle truth. DevIDE maintains a redacted, denormalized cache
(`WorkspaceRecord`) for fast API responses.

### Mode
A workspace safety mode (`:manual`, `:review`, `:agent_write_locked`,
`:shared_stage_guarded`). Modes gate agent-write capabilities; DB isolation
(`:shared_stage`, `:unsafe`) forces `:shared_stage_guarded` for agent actors.

### DB isolation
Classification of the workspace's database connection: `:local`, `:ephemeral`,
`:shared_stage`, or `:unsafe`. Detected by `IsolationProbe` from env/config.

### Policy decision
The result of `DevIDE.Policy.can_<action>?/1`: `%Decision{verdict: :allow | :deny, reason: atom, mode: atom}`.
Every blocked decision is audited.

## Event taxonomy

### Run ledger events

The run ledger (`DevIDE.Runs.Ledger`) is stored in audit events with
`metadata.ledger == "run"`. The canonical actions are:

| Action | When | Actor | Target |
|---|---|---|---|
| `run.session_attached` | Raw session attached after explicit policy allow | operator | `session` |
| `run.session_denied` | Raw session refused by policy | operator | `session` |
| `run.started` | Review-agent run started | requester | `run` |
| `run.succeeded` | Review-agent run exited successfully | runtime | `run` |
| `run.failed` | Review-agent run exited unsuccessfully | runtime | `run` |
| `run.timed_out` | Review-agent run hit the hard timeout | runtime | `run` |
| `run.approval_requested` | Human approval requested before execution continues | requester/runtime | `run` |
| `run.approval_granted` | Human approval granted | reviewer/operator | `run` |
| `run.approval_denied` | Human approval denied | reviewer/operator | `run` |

### General audit events

Paths outside the run ledger still produce general audit actions:

| Action | When | Actor | Target |
|---|---|---|---|
| `policy.blocked` | Generic policy denial outside the run ledger | original actor | the blocked target |
| agent MCP tool actions | Mutating terminal/preview MCP calls | agent | session / preview |

## Workspace status payload (summary)

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
  "recent_runs": [...],
  "recent_audit": [...]
}
```

No credentials, no file contents, no terminal scrollback.

## Redaction keys

The following keys are stripped from outbound payloads:

- `database_url`, `postgres_url`, `pg_url`, `db_url`
- `password`, `pgpassword`, `postgres_password`
- `secret`, `token`, `api_key`, `auth`, `bearer`, `cookie`, `session_id`
- Inside `env` / `environment` arrays: values for keys matching the above are replaced with `[REDACTED]`
