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

## MCP dual-stack (2025 path is still correct)

Casein terminal/preview/artifact servers are **dual-stack** (PR #476; design
[`mcp-2026-07-28-adoption.md`](../design/mcp-2026-07-28-adoption.md)): they speak
legacy `initialize` **and** `server/discover` with
`_meta["io.modelcontextprotocol/protocolVersion"]` `2026-07-28`.

**We are stateless POST even on 2025.** Streamable HTTP sessions
(`Mcp-Session-Id`, GET SSE) are optional and additive. A plain
`POST /api/{terminals,preview,artifacts}/mcp` with no session header is the
default path for host Grok, on-box agents, and `agent-doctor` — both for
2025-era `initialize` and for 2026 `server/discover`. Do not treat a missing
session id as a failure.

| Client | Wire today | How to change |
|--------|------------|---------------|
| Host Grok (`~/.grok/config.toml`) | Declares **2025-03-26** via legacy `initialize` | Host-local only; remains 2025 until Grok Build exposes a config/runtime declare for 2026. **No silent rewrite** from this box — operator apply on the laptop after greenlight (see Host config apply gate). |
| On-box Claude / OpenCode / Codex / Grok | Runtime-owned negotiate (still 2025-era `initialize` as of 2026-08) | Materializer injects URLs + bearer only; it passes `_meta` protocolVersion **when the runtime’s MCP config schema allows** (see design doc client matrix). Never flip the **server** default to 2026-only while agents still declare 2025. |

Probe both legs from a paired shell: `bash scripts/lib/agent-doctor.sh` (legacy
`initialize` + `server/discover` × three Casein endpoints).

### Host-only remaining (#751) — operator checklist

On-box client work for [#751](https://github.com/dl-alexandre/casein/issues/751) is
done (agent-doctor dual-stack probe, materializer `client_protocol_declare` hook,
this dual-stack section). **What is left is laptop-side only** and cannot be
applied from the devbox.

Do **not** rewrite host `~/.grok/config.toml` from a Casein pane, pairing script,
or health check. Do **not** touch `~/.grok/auth.json`.

When Grok Build documents a stable MCP config field (or CLI flag) that declares
`2026-07-28` / `_meta` `protocolVersion` per server:

1. **Inventory first** on the Mac (show intent; no silent rewrite):

   ```bash
   cp -a ~/.grok/config.toml ~/.grok/config.toml.bak.$(date -u +%Y%m%dT%H%M%SZ)
   grep -n 'casein-terminal\|casein-preview\|casein-artifact\|protocol\|mcp_servers' ~/.grok/config.toml
   grok --version   # note the build that gained the field
   ```

2. **Apply only the documented field** for the three Casein servers (shape is
   runtime-owned — do not invent keys). Prefer a visible edit + `diff` against
   the backup. Keep `Authorization = "Bearer ${CASEIN_API_TOKEN}"` env-ref
   headers ([Host secrets hygiene](#host-secrets-hygiene-715)).

3. **Verify both legs** still work (dual-stack must remain healthy for older
   tools):

   ```bash
   grok mcp doctor casein-terminal
   grok mcp doctor casein-preview
   grok mcp doctor casein-artifact
   # Optional: curl-style probe against public Casein MCP with
   # server/discover + _meta 2026-07-28 (same body as scripts/lib/agent-doctor.sh)
   ```

4. **If no field exists yet** — leave host Grok on legacy `initialize` →
   `2025-03-26`. That is correct: Casein servers stay dual-stack; default server
   revision stays `2025-03-26`. File the Grok version on #751 rather than
   forcing unknown TOML.

5. **When on-box runtimes gain a schema** — flip
   `Casein.Agents.MCPMaterializer.client_protocol_declare/0` (and
   `merge-agent-mcp.client_protocol_declare`) for that runtime only; do not
   change `@default_protocol_version` on the server.

## Operator policy

1. **Dual-plane honesty** — Mac/host shell ≠ remote Casein panes. State which plane you are on when paths matter.
2. **Remote-path rule** — Never `cd` remote worktree paths (e.g. `/data/casein-agent-worktrees/...`) on the host and never assume a local git root is the pane’s worktree without checking topology `worktree_path` / `current_path`.
3. **Product cwd (not `$HOME`)** — For Casein/product work on host Grok, start the shell from a **local product checkout** (e.g. host clone of Casein / `dev_ide`), not `$HOME`. A wrong cwd fails silently (side effects land outside the repo); a deleted cwd fails loudly (`getcwd`). See [Product cwd discipline](#product-cwd-discipline-716) below.
4. **Multi-workspace ops (intentional default for host Grok)** — Keep fleet-wide visibility when this process is an ops console. For every non-trivial terminal/preview/artifact call, pass **`workspace_id` + `session`** (and `pane` when mutating). **Never** rely on “recommended session” alone.
5. **Agent mutate** — Use `terminal_send_agent_*` only when `safe_to_mutate` is true **and** an `agent_pair` (or equivalent role marker) is present. Host-home Grok typically has neither; use explicit `session` + `pane` tools instead (`terminal_send_command`, or `terminal_paste_agent_text` with `pane` + `submit: true`). Do **not** double-Enter — paste/submit paths settle, press Enter, and retry once; trust `delivery` / `submitted` on the response.
6. **Fleet nuance** — Bare OpenCode/Claude worker windows without `agent_pair` are expected for many fleet spawns. That is hygiene, not proof MCP is broken.
7. **Host config apply gate** — Changes to host `~/.grok/config.toml` (MCP enable/disable, token wiring) only after human greenlight (`apply phase 1 only` / `apply mode A full`). No silent token rewrites in chat or git.

## Two modes

### Mode A — Host Grok, remote-ops (default for laptop Grok)

- Shell and git on the **host**
- Casein MCP for **remote** session/pane control
- Multi-workspace visibility is OK for an ops console
- Mandatory: `workspace_id` + `session` on ops calls
- **No** assume `safe_to_mutate` for this process
- Launch Grok from a **product checkout cwd** (see below), not `$HOME`

### Mode B — Casein-launched paired Grok (not host-home default)

- Agent started via Casein launch / `agent_pair` template
- Materialized env: `CASEIN_WORKSPACE_ID`, `CASEIN_CHECKOUT`, pre-scoped `CASEIN_*_MCP_URL`, caller pane
- `safe_to_mutate` may be true for the dedicated agent pane only
- **Out of scope** for host-home Grok until deliberately launched

## Product cwd discipline (#716)

Host Grok baseline often lands at `$HOME` (e.g. `/Users/developer`). That is fine for
chat, but **wrong for Casein/product work**: project MCP/docs discovery walks from cwd,
and tool side effects (writes, git, scripts) follow the shell cwd — not the remote pane.

### Expectation

| Work | Host shell cwd |
|------|----------------|
| Casein / product coding, PRs, local git | A **local** clone/checkout of that product (host path) |
| Pure remote ops (topology, paste into panes) with no local edits | Product checkout still preferred so project `.mcp.json` / docs win over bare home |
| Unrelated host tasks | Anywhere — do not pretend it is product work |

**Do not** `cd` to remote paths like `/data/casein-agent-worktrees/...` on the Mac (remote-path rule). The product cwd is the **host** tree that mirrors the product, not the pane’s `worktree_path`.

### Why it bites

- **Wrong cwd** — silent: files and scrap land under `$HOME` where nobody reviews them.
- **Deleted cwd** — loud: shells/tmux fail `getcwd` until restarted from a live path (recover from a known-good dir such as `$HOME`, then `cd` into the checkout again).

### Launch convention (host Mac)

```bash
# Pick your real host checkout (examples — adjust to the machine)
cd ~/src/casein          # or ~/dev/dev_ide, ~/code/casein, …
pwd                      # confirm: not $HOME
grok                     # then use Casein MCP with workspace_id + session
```

Optional one-liner helper (shell alias or function — **host-local**, not committed config):

```bash
# ~/.zshrc or equivalent — path is operator-chosen; show before adopting
casein-grok() {
  local root="${CASEIN_HOST_CHECKOUT:-$HOME/src/casein}"
  if [[ ! -d "$root/.git" && ! -f "$root/.git" ]]; then
    echo "casein-grok: missing checkout at $root (set CASEIN_HOST_CHECKOUT)" >&2
    return 1
  fi
  cd "$root" || return 1
  exec grok "$@"
}
```

No change to box-global `~/.grok/config.toml` is required for cwd discipline. Prefer
project-scoped MCP/docs when cwd is the product tree; keep durable multi-workspace Casein
MCP URLs (Mode A) — **do not** collapse them to a single `workspace_id` query for this issue.

### Do not

- Start product sessions from `$HOME` and hope discovery finds the repo.
- Treat host cwd as the remote pane worktree without checking topology.
- Rewrite shared `~/.grok/config.toml` to “fix” cwd (it cannot; cwd is process launch state).

## Config surfaces

| Surface | Role |
|---------|------|
| Host `~/.grok/config.toml` | Global MCP URLs/headers for host Grok; prefer env-ref secrets |
| Project `.mcp.json` / `.grok/config.toml` | Prefer for product cwd sessions when pairing a checkout |
| `~/.casein/agent-mcp/<workspace>/env.sh` | Materializer output: IDs, MCP URLs, checkout |
| `scripts/ensure-workspace-agent-pair.sh --runtime grok` | Mechanical install of project MCP + skills after staging exists |

Grok config priority (same name replaces, does not deep-merge): cwd → repo → user (`~/.grok/config.toml`).

## Host MCP hygiene (#718) — operator apply on the laptop

**This is host-local only.** Devbox agents must not rewrite laptop `~/.grok/config.toml`.
That file is box-global and hot-reloaded: a careless write takes out every Grok on the
machine. Apply on the **host Mac** after operator greenlight (`apply phase 1 only` /
`apply mode A full`). Prefer `grok mcp disable` over hand-editing TOML.

### Noise to clear

| Server key | Why it is red | Action |
|------------|---------------|--------|
| `agent` | Robinhood trading (`agent.robinhood.com`) — auth required / always failed on host Grok | `disable` (or `remove` if you do not use it) |
| `devide-*-scratch` (any) | Handshake failures when left enabled | `disable` each name `grok mcp list` shows |

### Keep (multi-workspace intentional)

- `casein-terminal`, `casein-preview`, `casein-artifact` — durable/global URLs, **no**
  single-workspace scope-down (see Mode A above and #713).

### Apply (host Mac shell — show first, then run)

```bash
# 1) Inventory (names + enabled only; review before changing anything)
grok mcp list
# optional machine-readable:
grok mcp list --json

# 2) Disable permanent red / scratch noise (repeat per scratch name)
grok mcp disable agent
# grok mcp disable devide-<name>-scratch   # only if list shows it enabled

# 3) Doctor should be green for intentional servers only
grok mcp doctor
grok mcp doctor casein-terminal
grok mcp doctor casein-preview
grok mcp doctor casein-artifact

# 4) Confirm Casein multi-ws still works (durable URLs + explicit workspace_id+session)
#    e.g. terminal_list_sessions with no pin, then one call with workspace_id+session
```

If a name is unknown to `disable`, it is already absent — do not invent blocks in TOML.
Equivalent TOML (only if CLI unavailable): under `[mcp_servers.agent]` set
`enabled = false` (or delete the table). Never commit host config or tokens.

### Do not

- Scope Casein MCP URLs down to one `workspace_id` query (multi-space is the host default).
- Run this against the **devbox** `~/.grok` as a substitute for the laptop.
- Probe or refresh `~/.grok/auth.json` as part of hygiene (auth wipe is a separate failure
  mode; recover with `~/.grok/bin/grok login --device-auth`, never the Casein shim).

## Host secrets hygiene (#715) — Casein Bearer via env ref

**This is host-local only.** Devbox agents must not rewrite laptop `~/.grok/config.toml`.
That file is box-global and hot-reloaded: a careless write takes out every Grok on the
machine. Apply on the **host Mac** after operator greenlight. **Show the change first** —
never a silent in-place edit.

### Goal

Stop storing the Casein MCP Bearer as a plaintext literal in shared/host config. Prefer
an environment reference that Grok expands from process env at connect time (same pattern
Casein already materializes for on-box Grok: `Authorization = "Bearer ${CASEIN_API_TOKEN}"`).

### Required shape (headers only — no secret values in the file)

Under each intentional Casein server (`casein-terminal`, `casein-preview`,
`casein-artifact`), headers must look like:

```toml
[mcp_servers.casein-terminal.headers]
Authorization = "Bearer ${CASEIN_API_TOKEN}"

[mcp_servers.casein-preview.headers]
Authorization = "Bearer ${CASEIN_API_TOKEN}"

[mcp_servers.casein-artifact.headers]
Authorization = "Bearer ${CASEIN_API_TOKEN}"
```

URLs stay the durable multi-workspace endpoints (see Mode A / #713). Do **not** paste a
token into TOML, chat, issues, or git.

### Supply the token via env (not config)

| Source | Notes |
|--------|--------|
| Shell profile / private file | e.g. `export CASEIN_API_TOKEN="$(cat ~/.casein-orchestrator-token)"` with the file `chmod 600` |
| Launch env | Host Grok process must inherit `CASEIN_API_TOKEN` before MCP connect |
| Casein materializer (Mode B) | On-box only: `scripts/materialize-agent-mcp.sh` already writes the `${CASEIN_API_TOKEN}` placeholder + exports the token in staging `env.sh` |

### Apply (host Mac shell — inventory first, then edit)

```bash
# 0) Ensure the process env will have the token (no value printed)
test -n "${CASEIN_API_TOKEN:-}" && echo "CASEIN_API_TOKEN is set" || echo "CASEIN_API_TOKEN missing — export it before doctor"

# 1) Inventory — review Authorization lines; expect either env-ref or a long literal
#    (do not paste output into chat if it still contains a literal Bearer)
grep -n 'Authorization\|casein-terminal\|casein-preview\|casein-artifact' ~/.grok/config.toml

# 2) If any Casein header still has a literal Bearer <token>, replace with env-ref.
#    Prefer a visible edit (diff then write), not a silent rewrite:
cp -a ~/.grok/config.toml ~/.grok/config.toml.bak.$(date -u +%Y%m%dT%H%M%SZ)
# Edit the three Casein *.headers Authorization lines to:
#   Authorization = "Bearer ${CASEIN_API_TOKEN}"
# Then show the diff of header lines only (values should be the placeholder):
grep -n 'Authorization' ~/.grok/config.toml

# Equivalent via CLI when re-adding a server (still show intent first):
# grok mcp add --transport http casein-terminal https://casein.devbox.milcgroup.com/api/terminals/mcp \
#   --header 'Authorization: Bearer ${CASEIN_API_TOKEN}'
# (repeat for casein-preview / casein-artifact with their durable URLs)

# 3) Doctor + auth smoke — must succeed with env set, fail closed if unset
grok mcp doctor casein-terminal
grok mcp doctor casein-preview
grok mcp doctor casein-artifact
# Optional: one MCP call with explicit workspace_id+session (Mode A)
```

If Grok does not expand `${CASEIN_API_TOKEN}` in headers on your installed version,
stop and keep the backup; do not invent a second secret store. File a note on #715 with
the version (`grok --version`) rather than embedding the token again.

### Optional: rotate

If a token may have been logged, pasted, or committed historically: mint a new scoped or
global token on the Casein host, store it only in the private file / env path above, and
revoke the old one. Do not put the new value in the runbook, PR, or issue comments.

### Do not

- Commit `~/.grok/config.toml`, `.mcp.json`, or any file with an embedded Bearer literal.
- Print token values in issues, PRs, or agent chat.
- Silently rewrite host (or devbox) `~/.grok/config.toml` from an agent session.
- Probe, refresh, or rewrite `~/.grok/auth.json` as part of this hygiene (recover login
  with `~/.grok/bin/grok login --device-auth`, never the Casein shim).
- Narrow Casein MCP to a single workspace as a side effect of secrets work (#718 / #713).

## Env vars (reference — no secret values)

Names only — never document real values. Host Grok must receive `CASEIN_API_TOKEN` via
process env (see **Host secrets hygiene (#715)** above); config files hold the
`Bearer ${CASEIN_API_TOKEN}` placeholder, not the secret.

| Variable | Purpose |
|----------|---------|
| `CASEIN_API_TOKEN` | Bearer for Casein MCP (env only; referenced from MCP headers) |
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
| P3 | #716 | Product cwd discipline — [section above](#product-cwd-discipline-716) |
| P4 | #717 | Reap stale local `casein_test_*` sockets — `scripts/casein-test-tmux-socket-reaper.sh` (inventory + dry-run default; see script header) |
| P5 | #714 | Short agent note (this folder / AGENTS link) |
| P6 | #751 | Client 2026 declare — on-box done (#762/#799); **host Grok remaining** — [checklist above](#host-only-remaining-751--operator-checklist) |

**Explicitly deferred:** default URL scope-down to a single workspace only; Mode B for host-home Grok.

## Verify (host dual-plane)

| Check | Healthy host Grok |
|-------|-------------------|
| Shell host | Local machine hostname/user |
| Shell cwd for product work | Host product checkout — **not** bare `$HOME` |
| Topology `current_path` | Often `/data/...` on remote |
| Local `/data` | Usually missing on Mac |
| `safe_to_mutate` | false without pair |
| Cross-ws call | Fails closed or mis-targets without `workspace_id`+`session` |

## See also

- [`mcp-2026-07-28-adoption.md`](../design/mcp-2026-07-28-adoption.md) — server dual-stack + client declare matrix
- [`external-agent-connect.md`](../external-agent-connect.md) — off-box MCP wiring
- [`terminal_mcp.md`](../terminal_mcp.md) — terminal MCP tool contract
- [`tmux_control_plane.md`](../tmux_control_plane.md) — topology / mutation behaviour
- [`agent_concurrency.md`](../agent_concurrency.md) — multi-agent checkout safety
- AGENTS.md — project agent workflow; always pass `workspace_id` on terminal MCP calls
- Issue [#751](https://github.com/dl-alexandre/casein/issues/751) — client path still on 2025; host Grok declare is laptop-side
