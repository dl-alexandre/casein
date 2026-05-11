# DevIde

DevIDE is the **read-only API producer** and **delegated execution authority**
for JX integration with milc-devbox workspaces. It exposes workspace status,
terminal control, command history, and a durable runner protocol for executing
allowlisted commands on external runners.

## What it does

- **Workspace observation**: Mirrors milc-devbox manager state, DB isolation,
  git status, active runs, proposals, and audit history.
- **Policy-gated commands**: Validates every command execution against an
  allowlist and workspace safety mode before spawning or queuing.
- **Durable runner protocol v1**: External runners poll for assignments, claim
  them with a lease token, execute safe actions, and report progress. DevIDE
  replays the full history idempotently.
- **Runtime orchestration v1**: DevIDE records host capability inventory,
  branch-isolated worktree placement, tmux bindings, stale runtime detection,
  and lifecycle events for runner assignments.
- **Audit trail**: Every policy decision and sensitive action is recorded.
- **Live terminal**: Per-tab xterm.js → Phoenix Channel → tmux session via
  erlexec PTY.
- **Agent read-only detection**: Inspects workspace filesystem for agent
  capabilities without starting or mutating anything.

## What it does NOT do

- It does not embed JX runtime code.
- It does not execute workspace commands on remote runners directly.
- It does not allow arbitrary argv, shell strings, or HTTP proxy actions.
- It does not apply proposals or enable agent writes (both are policy-denied as
  of M10).

## Quick start

```bash
# Install dependencies and set up database
mix setup

# Start the Phoenix server
mix phx.server
# or inside IEx
iex -S mix phx.server
```

The server runs at [`localhost:4000`](http://localhost:4000).

## Configuration

Create a `.env` or set in `config/runtime.exs`:

```bash
# Required: API bearer token (requests without it are rejected)
export DEV_IDE_API_TOKEN="secure-random-string"

# milc-devbox manager URL
export MILC_DEVBOX_MANAGER_URL="http://localhost:9000"

# Filesystem root for workspace path validation
export DEV_IDE_WORKSPACES_ROOT="/workspaces"
```

## Architecture docs

- [`docs/architecture.md`](docs/architecture.md) — System diagrams, trust boundaries, authority map, adapter pattern, configuration keys, design invariants.
- [`docs/jx_devide.md`](docs/jx_devide.md) — Authoritative JX ↔ DevIDE protocol v1 contract, runner endpoints, state machine, replay semantics, failure classes.
- [`docs/state_machines.md`](docs/state_machines.md) — Assignment lifecycle, claim lease lifecycle, immediate command lifecycle, workspace mode lifecycle, audit event lifecycle.
- [`docs/glossary.md`](docs/glossary.md) — Core concepts, event taxonomy, data structure schemas, time fields, routing fields, redaction keys.
- [`docs/failure_taxonomy.md`](docs/failure_taxonomy.md) — Failure class map, HTTP status mapping, duplicate report semantics, replay semantics, reconciliation scenarios, forbidden payload protection.
- [`docs/sequence_diagrams.md`](docs/sequence_diagrams.md) — JX immediate run, durable runner assignment, policy deny + audit, claim rejected, lease expiration, exact duplicate terminal report, workspace status read, terminal reconnect.
- [`docs/terminal.md`](docs/terminal.md) — Terminal subsystem architecture, erlexec PTY quirks, auth, bundle size notes, open issues.
- [`docs/runtime_orchestration.md`](docs/runtime_orchestration.md) — Runtime lifecycle, placement rules, CLI, and recovery.

## API overview

### Read API (M19)

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/api/workspaces` | Bearer | Workspace summaries |
| `GET` | `/api/workspaces/:id/status` | Bearer | Full status + mode + git + runs + proposals + audit |
| `GET` | `/api/workspaces/:id/runs` | Bearer | Command run history |
| `GET` | `/api/workspaces/:id/proposals` | Bearer | Proposal metadata + conflict risk |
| `GET` | `/api/workspaces/:id/audit` | Bearer | Audit events |

### Action endpoint (M30)

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/api/workspaces/:id/runs` | Bearer | Queue immediate run or durable runner assignment |

### Runner protocol v1

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/api/runner/v1/assignments/poll` | Bearer | Claim one compatible assignment |
| `GET` | `/api/runner/v1/assignments/:id` | Bearer | Replay assignment + reports |
| `POST` | `/api/runner/v1/assignments/:id/reports` | Bearer | Append progress report |
| `POST` | `/api/runner/v1/assignments/:id/complete` | Bearer | Terminal success |
| `POST` | `/api/runner/v1/assignments/:id/fail` | Bearer | Terminal failure |

## Safety model

DevIDE operates under explicit safety invariants:

1. **No arbitrary argv**: All command argv comes from `DevIDE.Commands.allowlist/0`.
2. **No generic HTTP proxy**: No endpoint translates requests into arbitrary HTTP.
3. **No runner creates assignments**: Runners can only claim and report.
4. **Append-only reports**: Progress reports are immutable. Replays are stable.
5. **Evidence required**: Terminal reports require non-empty evidence.
6. **Redaction at egress**: Credentials are stripped before any JSON response.
7. **Policy before work**: Every mutation checks policy first; blocks are audited.
8. **Replay is read-only**: No side effects on replay.

## Testing

```bash
# Run tests
mix test

# Run precommit checks (compile with warnings-as-errors, unlock unused deps, format, test)
mix precommit
```

## Learn more

- Phoenix framework: https://www.phoenixframework.org/
- Elixir: https://elixir-lang.org/
- Ecto: https://hexdocs.pm/ecto
