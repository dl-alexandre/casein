# DevIDE

> **A workspace runtime — local, remote, or fleet-coordinated — with a
> programmable editor surface as its cockpit.**
>
> The runtime is the engine: it owns sessions, decides what may execute,
> records what happened, and survives disconnects. The cockpit is a
> browser terminal attached to a workspace, plus the affordances an
> operator needs to trust the runtime under it.

## Product & docs

Start here. These are canonical and citable by section number in tickets.

- **[`docs/product.md`](docs/product.md)** — what this is, who it is for,
  the server/client boundary, three deployment modes (local / remote /
  fleet), the user promise, the UI and runtime contracts, decision rules.
- **[`docs/glossary.md`](docs/glossary.md)** — load-bearing vocabulary
  table with explicit "Must not mean" columns.
- **[`docs/architecture.md`](docs/architecture.md)** — system internals
  + nine numbered first-principles invariants (FP-1 … FP-9).
- **[`docs/audit_local.md`](docs/audit_local.md)** — Local-mode truth-table
  audit. 6/7 works · 1 partial.
- **[`docs/audit_remote.md`](docs/audit_remote.md)** — Remote-mode truth-table
  audit. 4 works · 3 ready (awaiting first prod run).
- **[`docs/audit_fleet.md`](docs/audit_fleet.md)** — Fleet-mode truth-table
  audit. 7/10 works · 2 out-of-scope (coordinator's job).
- **[`docs/deploy.md`](docs/deploy.md)** — operator runbook for a Remote-mode
  deployment (Dockerfile, env vars, TLS fronting options, upgrade procedure).

## What it does

- **Browser terminal attached to a workspace.** xterm.js → Phoenix Channel
  → tmux session via erlexec PTY. Sessions are durable across reconnect
  and survive server restarts (in-state buffer + tmux scrollback recovery).
- **Policy-gated execution.** Every command is checked against
  `DevIDE.Commands.allowlist/0` and the workspace's mode before spawning
  or queueing. Refusals are visible and audited.
- **Durable runner protocol v1.** External workers poll for assignments,
  claim them with a time-bounded lease token, execute, and report.
  DevIDE replays the full history idempotently. Leases expire on a
  supervised 30-second tick (`Runners.ExpiryScheduler`).
- **Connection picker.** `/workspaces` is a host-grouped picker with
  derived mode badges and capability chips per host (mode is computed
  from capabilities, never declared).
- **Evidence drawer.** A right-side drawer beside each workspace
  terminal, showing the audit stream as a single time-ordered feed
  (allow / deny / mode change / other) — closed by default, reachable
  not advertised.
- **Workspace observation.** Mirrors milc-devbox manager state, DB
  isolation, git status, active runs, proposals.
- **Audit trail.** Every governed decision is recorded (Ecto-durable
  in prod, in-memory in dev/test).

## What it does NOT do

- Not a code editor (no buffer, no LSP, no file tree as primary UI).
- Not an SSH client wrapper (transport is HTTPS + websockets; the
  authority is the server, not the shell).
- Not an agent framework (agents are clients of the runtime contract a
  human uses).
- Not a terminal multiplexer (tmux is an implementation detail).
- Not a dashboard (operational state is reachable, not advertised).

See [`docs/product.md`](docs/product.md) §6 for the full non-goals list.

## Quick start (development)

```bash
# Install dependencies and set up database
mix setup

# Start the Phoenix server
mix phx.server
# or inside IEx
iex -S mix phx.server
```

The server runs at [`localhost:4000`](http://localhost:4000). The picker
is the first screen; click a workspace to attach a terminal.

## Quick start (production / Remote mode)

See [`docs/deploy.md`](docs/deploy.md) for the full runbook. Short
version:

```bash
docker build -t dev_ide:latest .
docker run --rm <env...> dev_ide:latest /app/bin/migrate
docker run -d --name dev_ide -p 4000:4000 <env...> dev_ide:latest
```

Required env: `SECRET_KEY_BASE`, `DATABASE_URL`, `PHX_HOST`,
`DEV_IDE_API_TOKEN`, `MILC_DEVBOX_MANAGER_URL`,
`DEV_IDE_WORKSPACES_ROOT`.

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

## Architecture & protocol docs

Protocol- and subsystem-level detail (the canonical product/audit docs
are linked at the top of this file).

- [`docs/jx_devide.md`](docs/jx_devide.md) — JX ↔ DevIDE protocol v1
  contract, runner endpoints, state machine, replay semantics,
  failure classes.
- [`docs/state_machines.md`](docs/state_machines.md) — Assignment,
  claim-lease, immediate-command, workspace-mode, and audit-event
  lifecycles.
- [`docs/failure_taxonomy.md`](docs/failure_taxonomy.md) — Failure
  class map, HTTP status mapping, duplicate-report semantics,
  reconciliation scenarios, forbidden-payload protection.
- [`docs/sequence_diagrams.md`](docs/sequence_diagrams.md) — JX
  immediate run, durable runner assignment, policy deny + audit,
  claim rejected, lease expiration, duplicate terminal report,
  workspace status read, terminal reconnect.
- [`docs/terminal.md`](docs/terminal.md) — Terminal subsystem
  architecture, erlexec PTY quirks, auth, bundle size notes.
- [`docs/runtime_orchestration.md`](docs/runtime_orchestration.md) —
  Runtime lifecycle, placement rules, CLI, and recovery.
- [`docs/protocol_governance.md`](docs/protocol_governance.md) —
  Policy for evolving the JX ↔ DevIDE runner protocol.

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
