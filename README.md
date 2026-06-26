# DevIDE

**Durable, agent-native development. Your session lives on the server — close
the tab, sleep the laptop, lose the network, and the work keeps running.**

DevIDE is a workspace runtime with a browser terminal as its cockpit. The
runtime is the engine: it owns the session, decides what may execute, records
what happened, and survives disconnects. The browser is just a view of it. When
an agent is mid-task and your client disconnects, nothing stops: the tmux
session keeps executing server-side, and on reconnect the terminal **replays
exactly where you left off**.

<!-- TODO: 60-second hero demo. Disconnect → reconnect → agent still running. -->
![DevIDE: disconnect and reconnect with the agent still running](docs/assets/hero.gif)

### Why it exists

Running AI agents on real work means living with crashes, rate limits, and
dropped connections. Most setups tie the agent's life to the client — when the
tab dies, the work dies with it. DevIDE puts the session under the runtime, so:

- **Survives disconnects.** Sessions are real server-side tmux sessions
  (`tmux -A` attach-or-create). A tab crash, sleep, or reboot of the *client*
  doesn't touch the work. *(verified: a process in a pane accrued 31s of output
  with zero clients attached.)*
- **Replays on reconnect.** Reattach and the terminal restores recent
  scrollback from an in-state buffer plus tmux history — no "where was I?"
  *(`DevIDE.Terminals.SessionOwner`, `DevIDE.Terminals.Session`)*
- **Human + agent, side by side.** The agent-pair layout splits a workspace
  into operator / agent / verify panes, each agent in its own worktree, with
  clean/dirty status visible. You stay in control without babysitting.
  *(`DevIDEWeb.WorkspaceLive.Show.AgentsPanel`, `DevIDE.Runtimes`)*
- **Admission is a server decision, on the record.** Attaching a raw terminal
  is a server-side policy check (`DevIDE.Policy.can_use_raw_terminal?/1`)
  recorded in the run ledger, not a client capability. Agent runs that the
  runtime drives are constrained to the command allowlist; refusals are visible
  and audited. *(`DevIDE.Policy`, `DevIDE.Commands.Allowlist`)*

This is how we run dozens of agent sessions a week at MILCGroup.

### Try it / become a design partner

DevIDE is early, and we're working with a small number of agent-heavy Elixir
teams as design partners. If context-loss and multi-repo agent safety are real
pains for you:

- **Quickstart:** see [`docs/deploy.md`](docs/deploy.md) (operator runbook) and
  [`docs/architecture.md`](docs/architecture.md) (system internals).
- **Design partner:** open an issue titled `design-partner` (template under
  `.github/ISSUE_TEMPLATE/`) or reach out — we'll sit in your workflow and tune
  it to how your team actually runs agents.

## Product & docs

Start here. These are canonical and citable by section number in tickets.

- **[`docs/product.md`](docs/product.md)** — what this is, who it is for,
  the server/client boundary, the user promise, the UI and runtime contracts,
  decision rules.
- **[`docs/glossary.md`](docs/glossary.md)** — load-bearing vocabulary
  table with explicit "Must not mean" columns.
- **[`docs/architecture.md`](docs/architecture.md)** — system internals
  + ten numbered first-principles invariants (FP-1 … FP-10).
- **[`docs/terminal.md`](docs/terminal.md)** — terminal subsystem
  architecture, erlexec PTY quirks, auth, bundle size notes.
- **[`docs/deploy.md`](docs/deploy.md)** — operator runbook for a production
  deployment (Dockerfile, env vars, TLS fronting options, upgrade procedure).
- **[`docs/audit_local.md`](docs/audit_local.md)** and
  **[`docs/audit_remote.md`](docs/audit_remote.md)** — truth-table audits of
  observed runtime behaviour.

## What it does

- **Browser terminal attached to a workspace.** A raw Ghostty + tmux terminal
  is driven over LiveView. Sessions are durable across reconnect and survive
  server restarts (in-state buffer + tmux scrollback recovery).
- **Recorded admission.** Whether a client may attach a raw terminal is a
  server-side policy decision (`DevIDE.Policy.can_use_raw_terminal?/1`),
  recorded in the run ledger. The command allowlist
  (`DevIDE.Commands.Allowlist`) powers palette enumeration and constrains the
  review-mode agent runs the runtime drives (`DevIDE.Agents.Run`).
- **Workspace picker.** `/workspaces` lists the workspaces this runtime can
  attach, with derived status and capability chips.
- **Workspace observation.** Surfaces workspace state, DB isolation, git
  status, active runs, proposals.
- **Preview surface.** A browser preview pane the runtime can drive and
  snapshot, available to humans and to agents over MCP.
- **Audit trail.** Every policy decision is recorded (Ecto-durable in prod,
  in-memory in dev/test); run-scoped audit appears in the Run ledger and agent
  MCP activity appears in the Agents panel.

## What it does NOT do

- Not a code editor (no buffer, no LSP, no file tree as primary UI).
- Not an SSH client wrapper (transport is HTTPS + websockets; the
  authority is the server, not the shell).
- Not an agent framework (agents are clients of the runtime contract a
  human uses).
- Not a terminal multiplexer (tmux is an implementation detail).
- Not a fleet scheduler (no multi-host placement, leases, or coordinator —
  this is a single workspace runtime).
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

For local-network dogfooding, run `mise exec -- mix dev_ide.lan.up` and open
`http://<hostname>.local/`. That creates/checks the default `home` workspace,
installs the managed `devide-lan.service` backend plus the port-80 LAN edge,
and `/` opens the workspace directly. Use
`mise exec -- mix dev_ide.lan.status` and `mise exec -- mix dev_ide.lan.down`
to inspect or stop it. Trusted mkcert HTTPS remains available as an optional
manual path.
See [`docs/lan-access.md`](docs/lan-access.md).

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

## Architecture & protocol docs

Subsystem-level detail (the canonical product/architecture docs are linked at
the top of this file).

- [`docs/state_machines.md`](docs/state_machines.md) — workspace-mode, run,
  and audit-event lifecycles.
- [`docs/sequence_diagrams.md`](docs/sequence_diagrams.md) — terminal attach
  and reconnect, policy decision + audit, workspace status read.
- [`docs/tmux_control_plane.md`](docs/tmux_control_plane.md) — tmux control-mode
  plane: windows, panes, layouts, and the control protocol.
- [`docs/terminal_mcp.md`](docs/terminal_mcp.md) — terminal MCP tool surface
  (session discovery, topology, capture, send-keys, agent panes).
- [`docs/preview_mcp.md`](docs/preview_mcp.md) — preview MCP tool surface
  (open, navigate, observe, screenshot).
- [`AGENTS.md`](AGENTS.md) — agent onboarding, push/deploy mechanics, MCP
  endpoint URLs, and the agent pane pairing protocol.

## API overview

All endpoints are bearer-gated with `DEV_IDE_API_TOKEN`.

### Read API

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/workspaces` | Workspace summaries |
| `GET` | `/api/workspaces/:id/status` | Full status + mode + git + runs + proposals + audit |
| `GET` | `/api/workspaces/:id/topology` | Window/pane topology |
| `GET` | `/api/workspaces/:id/runs` | Run history |
| `GET` | `/api/workspaces/:id/runs/:run_id` | Single run detail |
| `GET` | `/api/workspaces/:id/audit` | Audit events |

### MCP

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/terminals/mcp` | Terminal control MCP (see [`docs/terminal_mcp.md`](docs/terminal_mcp.md)) |
| `POST` | `/api/preview/mcp` | Preview control MCP (see [`docs/preview_mcp.md`](docs/preview_mcp.md)) |

## Safety model

DevIDE operates under explicit safety invariants:

1. **Admission is recorded**: Attaching a raw terminal is a server-side policy
   decision (`DevIDE.Policy.can_use_raw_terminal?/1`) written to the run ledger;
   it is not a client capability.
2. **Constrained agent runs**: The command allowlist
   (`DevIDE.Commands.Allowlist`) governs palette enumeration and the review-mode
   agent runs the runtime drives (`DevIDE.Agents.Run`) — not arbitrary argv.
3. **No generic HTTP proxy**: No endpoint translates requests into arbitrary
   HTTP.
4. **Append-only audit**: Audit and run events are immutable; reads are stable.
5. **Redaction at egress**: Credentials are stripped before any JSON response.
6. **Policy before work**: Every mutation checks policy first; blocks are
   audited.
7. **Transport is not authority**: HTTP, Phoenix Channels, and tmux only move or
   attach to runtime state; they do not decide what may execute.

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
