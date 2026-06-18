# DevIDE

> **A single-runtime workspace cockpit: a durable terminal over a
> server-side runtime, with MCP as the interface coding agents use to
> drive it.**
>
> The runtime is the engine: it owns durable sessions, decides what may
> attach, records what happened, and survives disconnects. The cockpit is
> a browser terminal attached to a workspace, plus the surfaces an
> operator needs to see what an agent did.

## Product & docs

Start here. These are canonical and citable by section number in tickets.

- **[`docs/product.md`](docs/product.md)** — what this is, who it is for,
  the server/client boundary, the user promise, the UI and runtime
  contracts, decision rules.
- **[`docs/glossary.md`](docs/glossary.md)** — load-bearing vocabulary
  table with explicit "Must not mean" columns.
- **[`docs/architecture.md`](docs/architecture.md)** — system internals
  + the numbered first-principles invariants (FP-1 … FP-10).
- **[`docs/deploy.md`](docs/deploy.md)** — operator runbook for a
  deployment (Dockerfile, env vars, TLS fronting options, upgrade
  procedure).

## What it does

- **Browser terminal attached to a workspace.** Raw mode is Ghostty +
  tmux driven over LiveView. Sessions are durable across reconnect and
  survive server restarts (server-side Ghostty cell grid + tmux
  scrollback recovery).
- **Server-side execution authority.** The browser is a viewer, not an
  argv source. Raw-terminal admission is a server-side
  `Policy.can_use_raw_terminal?/1` decision; the verdict (allow or deny)
  is recorded in the run ledger.
- **Agents over MCP.** Coding agents drive the same tmux sessions a human
  uses through the terminal MCP, and a scoped preview session through the
  preview MCP. Every mutating tool call is audited and surfaced in the
  live activity feed.
- **Review-agent runs.** `DevIDE.Agents.Run` spawns a fixed, allowlisted
  `DevIDE.Agents.ReviewCommand` argv as a local subprocess — one per
  workspace. It cannot run arbitrary argv or apply a patch.
- **Workspace picker.** `/workspaces` lists the workspaces the server
  knows about with capability chips per workspace (capabilities are
  computed, never declared).
- **Workspace observation.** Surfaces workspace state, DB isolation, git
  status, and active sessions.
- **Audit trail.** Every sensitive decision and agent MCP call is recorded
  (Ecto-durable in prod, in-memory in dev/test); session and review-run
  events appear in the run ledger (`DevIDE.Runs.Ledger`), live agent MCP
  activity in the Agents panel.

## What it does NOT do

- Not a code editor (no buffer, no LSP, no file tree as primary UI).
- Not an SSH client wrapper (transport is HTTPS + websockets; the
  authority is the server, not the shell).
- Not an agent framework (agents are MCP clients of the runtime, not
  things the runtime defines or schedules).
- Not a multi-runtime fleet (one runtime, no scheduler, no cross-host
  placement, no runner pool).
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

## Quick start (production)

See [`docs/deploy.md`](docs/deploy.md) for the full runbook. Short
version:

```bash
docker build -t dev_ide:latest .
docker run --rm <env...> dev_ide:latest /app/bin/migrate
docker run -d --name dev_ide -p 4000:4000 <env...> dev_ide:latest
```

Required env: `SECRET_KEY_BASE`, `DATABASE_URL`, `PHX_HOST`,
`DEV_IDE_API_TOKEN`, `DEV_IDE_WORKSPACES_ROOT`.

## Configuration

Create a `.env` or set in `config/runtime.exs`:

```bash
# Required: API bearer token (requests without it are rejected)
export DEV_IDE_API_TOKEN="secure-random-string"

# Filesystem root for workspace path validation
export DEV_IDE_WORKSPACES_ROOT="/workspaces"
```

## Subsystem docs

Subsystem-level detail (the canonical product/architecture docs are
linked at the top of this file).

- [`docs/terminal.md`](docs/terminal.md) — terminal subsystem
  architecture (Ghostty raw PTY, tmux persistence, multi-pane, auth,
  bundle size notes).
- [`docs/terminal_mcp.md`](docs/terminal_mcp.md) — terminal MCP tool
  surface and agent-pairing quickstart.
- [`docs/preview_mcp.md`](docs/preview_mcp.md) — preview MCP tool surface.
- [`docs/tmux_control_plane.md`](docs/tmux_control_plane.md) — tmux
  topology/templates control plane.
- [`docs/state_machines.md`](docs/state_machines.md) — session,
  review-run, workspace-mode, and audit-event lifecycles.
- [`docs/sequence_diagrams.md`](docs/sequence_diagrams.md) — key
  interaction flows (terminal reconnect, policy deny + audit, agent MCP
  call, review run).
- [`AGENTS.md`](AGENTS.md) — repo conventions, push auth, deploy path,
  MCP endpoint URLs, agent pane pairing protocol.

## API overview

All routes are bearer-gated with `DEV_IDE_API_TOKEN` (the API returns 503
if the token is unset, 401 if it is wrong or missing).

### Read API

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/workspaces` | Workspace summaries |
| `GET` | `/api/workspaces/:id/status` | Full status + git + active runs + agent capabilities + audit |
| `GET` | `/api/workspaces/:id/topology` | tmux window/pane topology |
| `GET` | `/api/workspaces/:id/runs` | Run ledger history |
| `GET` | `/api/workspaces/:id/runs/:run_id` | Single run with grouped events |
| `GET` | `/api/workspaces/:id/audit` | Audit events |

### MCP endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/terminals/mcp` | Terminal MCP JSON-RPC (drives `devide_*` tmux sessions) |
| `POST` | `/api/preview/mcp` | Preview MCP JSON-RPC (scoped preview session) |

Both advertise their tool names and transport through
`GET /api/workspaces/:id/status` as `agent_capabilities`. See
[`docs/terminal_mcp.md`](docs/terminal_mcp.md) and
[`docs/preview_mcp.md`](docs/preview_mcp.md).

## Safety model

DevIDE has a narrow execution surface and records the decisions it makes.

1. **No arbitrary argv from a remote client.** The browser and MCP agents
   type into a server-side PTY; they do not submit argv to an executor.
   The one local executor (`DevIDE.Commands`) only runs fixed, allowlisted
   `ReviewCommand` argv — enumerated by `DevIDE.Commands.Allowlist`.
2. **Raw-terminal admission is a server decision.** Every raw attach
   passes through `DevIDE.Policy.can_use_raw_terminal?/1`; the verdict is
   recorded in the run ledger (`run.session_attached` /
   `run.session_denied`).
3. **MCP tools are scoped.** Terminal tools touch only `devide_`-prefixed
   tmux sessions; preview tools touch only a scoped preview session.
   Cross-workspace access is rejected.
4. **Audit at egress.** Per-subsystem sanitizers strip credentials before
   JSON serialization.
5. **Durable evidence.** The run ledger (`DevIDE.Runs.Ledger`) and audit
   events are the source of truth for review and post-mortem; the UI
   renders from them rather than presenting events as isolated facts.

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
