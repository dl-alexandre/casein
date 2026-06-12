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
  + ten numbered first-principles invariants (FP-1 … FP-10).
- **[`docs/audit_local.md`](docs/audit_local.md)** — Local-mode truth-table
  audit. 6/7 works · 1 partial.
- **[`docs/audit_remote.md`](docs/audit_remote.md)** — Remote-mode truth-table
  audit. 4 works · 3 ready (awaiting first prod run).
- **[`docs/audit_fleet.md`](docs/audit_fleet.md)** — Fleet-mode truth-table
  audit. 7/10 works · 2 out-of-scope (coordinator's job).
- **[`docs/deploy.md`](docs/deploy.md)** — operator runbook for a Remote-mode
  deployment (Dockerfile, env vars, TLS fronting options, upgrade procedure).
- **[`docs/operator_lifecycle.md`](docs/operator_lifecycle.md)** — delegated
  execution trace from delegate through placement, lease, execution, evidence,
  review queue, approval-gated recovery, runbook actions, notifications,
  takeover, and dossier review.
- **[`docs/remote_execution_substrate.md`](docs/remote_execution_substrate.md)** —
  M61-M80 runner process, channel transport, SSH/tmux infrastructure,
  runner identity, attach/reconnect, scheduling, dashboards, and replay
  inspection, plus the repeatable dogfood demo script and dossier export.
- **[`docs/v0_1_release_candidate.md`](docs/v0_1_release_candidate.md)** —
  v0.1 internal release boundary, startup flow, operator guide, packaging
  checks, known limitations, and release-candidate evidence.

## What it does

- **Browser terminal attached to a workspace.** Governed mode uses a custom
  prompt UI over Phoenix Channel; raw mode uses Ghostty + tmux via
  LiveView. Sessions are durable across reconnect and survive server
  restarts (in-state buffer + tmux scrollback recovery).
- **Policy-gated execution.** Every command is checked against
  `DevIDE.Commands.allowlist/0` and the workspace's mode before spawning
  or queueing. Refusals are visible and audited.
- **Durable runner protocol v1.** External workers poll for assignments,
  claim them with a time-bounded lease token, execute, and report.
  DevIDE replays the full history idempotently. Leases expire on a
  supervised 30-second tick (`Runners.ExpiryScheduler`).
- **Real runner substrate.** `mix jx.runner.start` runs a standalone
  runner process with heartbeat, lease renewal, assignment polling,
  protocol-envelope validation, artifact upload, and terminal reporting.
  Runners can use HTTP or the Phoenix Channel transport; orchestration
  truth still lives in DevIDE.
- **Connection picker.** `/workspaces` is a host-grouped picker with
  derived mode badges and capability chips per host (mode is computed
  from capabilities, never declared).
- **Workspace observation.** Surfaces workspace state, DB isolation,
  git status, active runs, proposals.
- **Audit trail.** Every governed decision is recorded (Ecto-durable
  in prod, in-memory in dev/test); run-scoped audit appears in the
  Run ledger and agent MCP activity appears in the Agents panel.

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
`DEV_IDE_API_TOKEN`, `DEV_IDE_WORKSPACES_ROOT`.

For fleet dogfood, also set `DEV_IDE_RUNNER_TOKEN` and pass that token to
`mix jx.runner.start`; keep `DEV_IDE_API_TOKEN` for operator/controller calls.

## Configuration

Create a `.env` or set in `config/runtime.exs`:

```bash
# Required: API bearer token (requests without it are rejected)
export DEV_IDE_API_TOKEN="secure-random-string"

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
- [`docs/operator_lifecycle.md`](docs/operator_lifecycle.md) — Full
  operator lifecycle trace and Mermaid flow for delegated execution.
- [`docs/remote_execution_substrate.md`](docs/remote_execution_substrate.md) —
  M61-M80 multi-runner substrate runbook, lifecycle trace, and Mermaid flow.
- [`docs/v0_1_release_candidate.md`](docs/v0_1_release_candidate.md) —
  v0.1 internal release candidate notes and gates.

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

### Fleet runner protocol v1

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/api/fleet/v1/runners/register` | Bearer | Register runner identity/capabilities |
| `POST` | `/api/fleet/v1/runners/:runner_id/heartbeat` | Bearer | Refresh runner liveness |
| `POST` | `/api/fleet/v1/runners/:runner_id/offers/poll` | Bearer | Long-poll for one assignment offer |
| `POST` | `/api/fleet/v1/runners/:runner_id/drain` | Bearer | Stop placing new work on the runner |
| `POST` | `/api/fleet/v1/runners/:runner_id/shutdown` | Bearer | Mark a drained runner offline |
| `POST` | `/api/fleet/v1/messages` | Bearer | Submit versioned protocol envelope |

### Operator CLI

| Command | Description |
|---|---|
| `mix jx.runner.start --endpoint http://localhost:4000` | Start a standalone fleet runner process |
| `mix jx.attach <execution_id>` | Replay durable execution output and show live attach metadata |
| `mix jx.dossier.export <assignment_id> --output tmp/dossier.json` | Export a complete assignment dossier bundle |
| `bash scripts/dogfood_remote_fleet.sh` | Run the two-process controller/runner dogfood demo |

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
9. **Delegated evidence is complete**: Every delegated execution leaves a
   dossier trail with assignment, execution, runner, workspace, lease,
   command, exit status, artifacts, failures, and recovery actions.
10. **Risky operator actions require approval**: Retry, recovery, and takeover
    input require a granted approval matching the assignment and action.
11. **Runbooks stay inside boundaries**: Operator runbook commands use safe
    command ids and the fleet execution loop, not raw argv.
12. **Notifications are hints**: Operator notifications are post-commit and
    non-authoritative; dossiers and event stores remain the source of truth.
13. **Transport is not authority**: HTTP, Phoenix Channels, SSH, and tmux only
    move or attach to protocol state; they do not decide orchestration truth.
14. **Runner identity is governed**: Runner trust state can drain,
    maintenance-hold, or revoke a node before it receives new work.
15. **Runner tokens are least-privilege**: `DEV_IDE_RUNNER_TOKEN` is accepted
    only on runner transport routes and the runner channel.
16. **Operator output is redacted**: obvious token/password/bearer material in
    runner output is redacted before durable storage and live broadcast.

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
