# Host Grok dual-plane ops (multi-workspace)

> **Status:** adopted operator contract (2026-08-08).  
> **Tracking:** [#713](https://github.com/dl-alexandre/casein/issues/713) and children.  
> **Audience:** host-side Grok (and similar) on a laptop/desktop that talks to Casein Terminal/Preview/Artifact MCP on the devbox, **and** fleet agents that must not re-learn split brain.

This document is the durable home for the dual-plane ground truth and the multi-workspace ops contract. It does **not** change product code paths.

## Ground truth

Two healthy planes, **not** one machine:

| Plane | What works | What it is not |
|-------|------------|----------------|
| Agent shell (`run_terminal_command` / local CLI) | Real shell on the host (e.g. DairyBookPro as `developer`) | Not a Casein pane; not `/data/casein-agent-worktrees/...` |
| Casein Terminal / Preview / Artifact MCP | Real control plane on the Casein host (e.g. `casein.devbox.milcgroup.com`) | Not local MenuBar tmux; not “this” process’s `agent_pair` |
| Local `tmux -L casein` (desktop app) | Scratch sessions on the Mac | Not what global Casein MCP lists by default |

**Failure mode to avoid:** the dangerous lie is not “MCP is down” — it is **unscoped remote ops with a host-level agent**, so path/cwd/session identity can silently disagree.

## Operator policy

1. **Dual-plane honesty** — Mac/host shell ≠ remote Casein panes. State which plane you are on when paths matter.
2. **Remote-path rule** — Never `cd` remote worktree paths (e.g. `/data/casein-agent-worktrees/...`) on the host and never assume a local git root is the pane’s worktree without checking topology `worktree_path` / `current_path`.
3. **Multi-workspace ops (intentional default for host Grok)** — Keep fleet-wide visibility when this process is an ops console. For every non-trivial terminal/preview/artifact call, pass **`workspace_id` + `session`** (and `pane` when mutating). **Never** rely on “recommended session” alone.
4. **Agent mutate** — Use `terminal_send_agent_*` only when `safe_to_mutate` is true **and** an `agent_pair` (or equivalent role marker) is present. Host-home Grok typically has neither; use explicit `session` + `pane` tools instead (`terminal_send_command`, or `terminal_paste_agent_text` with `pane` + `submit: true`). Do **not** double-Enter — paste/submit paths settle, press Enter, and retry once; trust `delivery` / `submitted` on the response.
5. **Fleet nuance** — Bare OpenCode/Claude worker windows without `agent_pair` are expected for many fleet spawns. That is hygiene, not proof MCP is broken.
6. **Host config apply gate** — Changes to host `~/.grok/config.toml` (MCP enable/disable, token wiring) only after human greenlight (`apply phase 1 only` / `apply mode A full`). No silent token rewrites in chat or git.

## Two modes

### Mode A — Host Grok, remote-ops (default for laptop Grok)

- Shell and git on the **host**
- Casein MCP for **remote** session/pane control
- Multi-workspace visibility is OK for an ops console
- Mandatory: `workspace_id` + `session` on ops calls
- **No** assume `safe_to_mutate` for this process

### Mode B — Casein-launched paired Grok (not host-home default)

- Agent started via Casein launch / `agent_pair` template
- Materialized env: `CASEIN_WORKSPACE_ID`, `CASEIN_CHECKOUT`, pre-scoped `CASEIN_*_MCP_URL`, caller pane
- `safe_to_mutate` may be true for the dedicated agent pane only
- **Out of scope** for host-home Grok until deliberately launched

## Config surfaces

| Surface | Role |
|---------|------|
| Host `~/.grok/config.toml` | Global MCP URLs/headers for host Grok; prefer env-ref secrets |
| Project `.mcp.json` / `.grok/config.toml` | Prefer for product cwd sessions when pairing a checkout |
| `~/.casein/agent-mcp/<workspace>/env.sh` | Materializer output: IDs, MCP URLs, checkout |
| `scripts/ensure-workspace-agent-pair.sh --runtime grok` | Mechanical install of project MCP + skills after staging exists |

Grok config priority (same name replaces, does not deep-merge): cwd → repo → user (`~/.grok/config.toml`).

## Env vars (reference — no secret values)

| Variable | Purpose |
|----------|---------|
| `CASEIN_API_TOKEN` | Bearer for Casein MCP |
| `CASEIN_WORKSPACE_ID` / `CASEIN_WORKSPACE_NAME` | Target workspace |
| `CASEIN_CHECKOUT` | Product tree path **on the machine where the pane runs** |
| `CASEIN_TERMINAL_MCP_URL` / `PREVIEW` / `ARTIFACT` | MCP endpoints (optionally pre-scoped) |
| `CASEIN_TMUX_SESSION` | Optional pin to a live `casein_*` session |
| Caller pane / `X-Casein-Caller-Pane` | Present for Casein-launched agents only |

If `CASEIN_WORKSPACE_ID` is unset on a host ops console, treat MCP as multi-workspace and **require** explicit `workspace_id` + `session` on every call.

## Related backlog (do not mix into product features)

| ID | Issue | Notes |
|----|-------|--------|
| P0 | #719 | This runbook |
| P1 | #718 | Host MCP hygiene (disable noise servers) — host apply |
| P1b | #715 | Env-ref Casein Bearer — host apply |
| P3 | #716 | Product cwd discipline |
| P4 | #717 | Reap stale local `casein_test_*` sockets |
| P5 | #714 | Short agent note (this folder / AGENTS link) |

**Explicitly deferred:** default URL scope-down to a single workspace only; Mode B for host-home Grok.

## Verify (host dual-plane)

| Check | Healthy host Grok |
|-------|-------------------|
| Shell host | Local machine hostname/user |
| Topology `current_path` | Often `/data/...` on remote |
| Local `/data` | Usually missing on Mac |
| `safe_to_mutate` | false without pair |
| Cross-ws call | Fails closed or mis-targets without `workspace_id`+`session` |

## See also

- [`external-agent-connect.md`](../external-agent-connect.md) — off-box MCP wiring
- [`terminal_mcp.md`](../terminal_mcp.md) — terminal MCP tool contract
- [`tmux_control_plane.md`](../tmux_control_plane.md) — topology / mutation behaviour
- [`agent_concurrency.md`](../agent_concurrency.md) — multi-agent checkout safety
- AGENTS.md — project agent workflow; always pass `workspace_id` on terminal MCP calls
