# Connecting an external agent to Casein MCP

Ready-to-go connection bundles for reaching Casein's agent-control MCP from **outside**
the devbox. Two transports ("doors"); the tool surface and semantics are identical — only
how you reach the endpoints and authenticate differ. See the host-side `devide-remote`
skill for the full map.

Three JSON-RPC 2.0 MCP servers back everything:

| Server | Path | Purpose |
|---|---|---|
| Terminal | `/api/terminals/mcp` | tmux/agent control (list/topology/capture/send/wait) |
| Preview | `/api/preview/mcp` | preview panes + headless browser control |
| Artifact | `/api/artifacts/mcp` | artifact projects |

**Injected params for the `dalexandre-devide` workspace:**

| Param | Value |
|---|---|
| Workspace UUID | `e7c18b93-688b-4bb0-904d-ac93d61e9372` |
| Public host (Door 2) | `devide.devbox.milcgroup.com` |
| Loopback base (Door 1) | `http://127.0.0.1:4000` |
| Tool-search | ON (`CASEIN_MCP_TOOL_SEARCH=1` on the box) |

> **The bearer token is a root-grade secret.** Never inline it in a prompt, transcript, or
> committed config. Read it from env or a `chmod 600` file. A **global** token is
> root-on-the-box — for third parties/CI, issue a **workspace-scoped** token instead.

## Door status (verify before relying on either)

Both doors work today (verified 2026-07-14).

- **Door 1 (SSH tunnel):** ✅ loopback `:4000` token gate is live.
- **Door 2 (public HTTPS):** ✅ the Caddy `@bearer` bypass on the `devide.*` host is live
  (`manager/lib/caddy.js`, shipped in milc-devbox #245). Bearer requests to the three
  `/api/*/mcp` paths reach Phoenix `ApiAuth` directly; the browser cockpit still goes
  through oauth2-proxy.

> **Testing gotcha:** verify Door 2 **with** a bearer header. A **no-bearer** request to
> `/api/*/mcp` returns `302` (oauth login redirect) *by design* — that's the cockpit path,
> not a closed door. `curl -X POST …/api/terminals/mcp` alone will always look "closed".
> With a valid bearer you get `200` / a JSON-RPC result; with a bad bearer, `401`.

---

## Config shape: pinned vs durable

Orthogonal to which door you use, the `.mcp.json` comes in two shapes. The difference is
whether `workspace_id` is baked into the URL.

| | **Pinned** (one workspace) | **Durable** (workspace-agnostic) |
|---|---|---|
| URL | `…/api/terminals/mcp?workspace_id=<uuid>` | `…/api/terminals/mcp` (no query) |
| Workspace selected | by the URL, fixed | per tool call (`workspace_id` in `arguments`) |
| New workspace | re-materialize a fresh config | **just target it — no re-wiring** |
| Abandon a stale one | config points at a dead workspace | **stop passing its id; nothing to tear down** |
| Token required | workspace-scoped **or** global | **global** (traverse) — see caveat |

**Use durable when** you hop between / spin up / abandon workspaces and don't want to
regenerate MCP config each time. The endpoint resolves `workspace_id` per-call
(`Casein.MCP.Scope`), so one wiring outlives any individual workspace.

> **Token caveat.** A durable/workspaceless config needs a token that can reach more than
> one workspace — i.e. the **global** orchestrator token (root-grade). That's fine over
> **Door 1 (SSH)**, where your SSH access already gates it. Do **not** put the global token
> on **Door 2 (public)** — there, keep using a pinned, workspace-scoped token. (A
> multi-workspace *set* token is the middle path, but adding a workspace to a set is not yet
> a runtime action — it needs an env edit + restart today.)

### Durable `.mcp.json` (Door 1 / global token)

Same for either door — just swap the host. Note: **no `?workspace_id`** in any URL.

```json
{
  "mcpServers": {
    "devide-terminal": {
      "url": "http://127.0.0.1:4000/api/terminals/mcp",
      "headers": { "Authorization": "Bearer PASTE_GLOBAL_TOKEN_HERE" }
    },
    "casein-preview": {
      "url": "http://127.0.0.1:4000/api/preview/mcp",
      "headers": { "Authorization": "Bearer PASTE_GLOBAL_TOKEN_HERE" }
    },
    "devide-artifact": {
      "url": "http://127.0.0.1:4000/api/artifacts/mcp",
      "headers": { "Authorization": "Bearer PASTE_GLOBAL_TOKEN_HERE" }
    }
  }
}
```

### Working durably: list live workspaces, then target per-call

With no workspace pinned, **discover first, then confine each call**:

```text
1. terminal_list_sessions            (no workspace_id) → every live devide_* session, box-wide
2. GET /api/workspaces               → id / name / host path for each workspace
3. <any tool> with "workspace_id":"<uuid>" in arguments → confined to that workspace
```

- **Enumerate what's live / abandonable:** `terminal_list_sessions` with no `workspace_id`
  returns sessions across all workspaces with `last activity` — stale ones are the
  low-activity / no-attached-client rows. That's your "what can I abandon?" view.
- **Abandon a stale workspace:** simply stop targeting its id. The durable config needs no
  change. Reclaiming the underlying worktree/tmux is a separate concern handled by the
  reaper / `cleanup-agent-worktrees.sh`; it does not require touching this config.
- **Pick up a new workspace:** pass its `workspace_id` (from step 2) in `arguments`. Nothing
  to materialize — a global token sees new `devide_*` sessions the moment they exist.

Curl form of the discover-then-target loop:

```bash
export CASEIN_API_TOKEN="$(cat ~/.devide-orchestrator-token)"   # GLOBAL token, chmod 600
BASE=http://127.0.0.1:4000                                        # or the Door 2 public host
rpc() { curl -s -X POST "$BASE/api/terminals/mcp" \
  -H "authorization: Bearer $CASEIN_API_TOKEN" -H 'content-type: application/json' -d "$1"; }

# box-wide inventory — which workspaces have live sessions (and which are stale)
rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"terminal_list_sessions","arguments":{}}}'

# workspace map (id / name / path)
curl -s -H "authorization: Bearer $CASEIN_API_TOKEN" "$BASE/api/workspaces"

# confine a call to one workspace by passing its id in arguments
rpc '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"terminal_topology","arguments":{"session":"<name>","workspace_id":"<uuid>"}}}'
```

The **pinned** per-workspace configs below are still the right choice for Door 2 / a
workspace-scoped token / a third party. Everything else in this doc (doors, tokens, prompts)
applies to both shapes.

---

## Door 1 — SSH tunnel (works today)

Your SSH key is the transport auth; the bearer authorizes the API. Recommended default and
for any off-box agent/CI you control.

### Step 1 — Tunnel + token

```bash
# forward the box's loopback :4000 to your machine (leave running)
ssh -N -L 4000:127.0.0.1:4000 devbox &          # ← replace 'devbox' with your SSH host/alias

# token from a private file, never committed / never pasted into a prompt
export CASEIN_API_TOKEN="$(cat ~/.devide-orchestrator-token)"   # chmod 600 this file

# sanity: 401 = gate reached (good). 000 = tunnel not up. 200 with bearer = you're in.
curl -s -o /dev/null -w "no-bearer: %{http_code}\n" http://127.0.0.1:4000/api/workspaces
curl -s -o /dev/null -w "bearer:    %{http_code}\n" -H "Authorization: Bearer $CASEIN_API_TOKEN" \
  http://127.0.0.1:4000/api/workspaces
```

### Step 2 — MCP client config

Save as `devide-remote.mcp.json`, replace the token placeholder, keep it gitignored:

```json
{
  "mcpServers": {
    "devide-terminal": {
      "url": "http://127.0.0.1:4000/api/terminals/mcp?workspace_id=e7c18b93-688b-4bb0-904d-ac93d61e9372",
      "headers": { "Authorization": "Bearer PASTE_TOKEN_HERE" }
    },
    "casein-preview": {
      "url": "http://127.0.0.1:4000/api/preview/mcp?workspace_id=e7c18b93-688b-4bb0-904d-ac93d61e9372",
      "headers": { "Authorization": "Bearer PASTE_TOKEN_HERE" }
    },
    "devide-artifact": {
      "url": "http://127.0.0.1:4000/api/artifacts/mcp?workspace_id=e7c18b93-688b-4bb0-904d-ac93d61e9372",
      "headers": { "Authorization": "Bearer PASTE_TOKEN_HERE" }
    }
  }
}
```

Launch: `claude --mcp-config devide-remote.mcp.json`. Drop `?workspace_id=…` on all three
URLs to traverse the whole box (global token only).

---

## Door 2 — public HTTPS (no tunnel; live)

Only the base URL changes vs Door 1, and there's no SSH step. Works from anywhere —
including a claude.ai custom connector (the only path that works from claude.ai, since no
tunnel is possible there).

### Step 1 — Token + verify (must send a bearer)

```bash
export CASEIN_API_TOKEN="$(cat ~/.devide-orchestrator-token)"   # chmod 600 this file

# Correct test — WITH a bearer. Expect 200 (good token) or 401 (bad token).
curl -s -o /dev/null -w "bearer:    %{http_code}\n" -X POST \
  https://devide.devbox.milcgroup.com/api/terminals/mcp \
  -H "Authorization: Bearer $CASEIN_API_TOKEN" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# Sanity of the "no-bearer 302 is expected" behavior — this SHOULD show 302, not a failure.
curl -s -o /dev/null -w "no-bearer: %{http_code}\n" -X POST \
  https://devide.devbox.milcgroup.com/api/terminals/mcp \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

Expected: `bearer: 200` and `no-bearer: 302`. If the **bearer** line shows `302`, the
`@bearer` route on the `devide.*` host regressed — check `manager/lib/caddy.js` and that
the running manager (`/opt/devbox/manager`) regenerated + reloaded Caddy
(`devide-remote/references/operator-setup.md` §2).

### Step 2 — MCP client config

Save as `devide-remote-door2.mcp.json`, replace the token placeholder, keep it gitignored:

```json
{
  "mcpServers": {
    "devide-terminal": {
      "url": "https://devide.devbox.milcgroup.com/api/terminals/mcp?workspace_id=e7c18b93-688b-4bb0-904d-ac93d61e9372",
      "headers": { "Authorization": "Bearer PASTE_TOKEN_HERE" }
    },
    "casein-preview": {
      "url": "https://devide.devbox.milcgroup.com/api/preview/mcp?workspace_id=e7c18b93-688b-4bb0-904d-ac93d61e9372",
      "headers": { "Authorization": "Bearer PASTE_TOKEN_HERE" }
    },
    "devide-artifact": {
      "url": "https://devide.devbox.milcgroup.com/api/artifacts/mcp?workspace_id=e7c18b93-688b-4bb0-904d-ac93d61e9372",
      "headers": { "Authorization": "Bearer PASTE_TOKEN_HERE" }
    }
  }
}
```

Launch: `claude --mcp-config devide-remote-door2.mcp.json`. Drop `?workspace_id=…` to
traverse the whole box (global token only). For a **claude.ai custom connector**, add each
URL with an `Authorization: Bearer …` header once the door is open.

---

## Copyable prompt for the external agent

Pick by config shape. The **pinned** variants (Door 1 / Door 2) lock the agent to
`dalexandre-devide`; the **durable** variant lets it roam every live workspace and abandon
stale ones with no re-wiring.

### Durable (workspace-agnostic, global token)

```text
You are connected to a remote Casein dev box over MCP with a workspace-agnostic (durable)
config — no workspace is pinned. Three JSON-RPC 2.0 servers are wired as MCP clients:

  • devide-terminal  — tmux/agent control (list/topology/capture/send/wait)
  • casein-preview   — preview panes + headless browser control
  • devide-artifact  — artifact projects

How to work here:
- DISCOVER FIRST. Call terminal_list_sessions with NO workspace_id to see every live
  devide_* session box-wide, then GET /api/workspaces for the id/name/path of each
  workspace. Report which workspaces are live and which look stale (low last-activity,
  no attached client).
- TARGET PER CALL. To act inside a workspace, pass its "workspace_id" in the tool call's
  arguments — that confines the call to that workspace. Omit it only for box-wide discovery.
- ABANDON is free: to drop a stale workspace, just stop targeting its id. Do not tear down
  or reconfigure anything. Reclaiming its worktree/session is a separate reaper concern.
- NEW workspaces need nothing — a new devide_* session is reachable the moment it exists;
  just pass its workspace_id.
- Tool-search is ON: each big server lists a small CORE set plus search_tools/invoke_tool.
  For a tool that isn't listed, search_tools (natural language; "picture"→screenshot,
  "kill"→close) then invoke_tool.
- To drive an on-box agent in a workspace: terminal_topology → AGENT pane id (not operator)
  → terminal_send_agent_command → terminal_wait_agent_state → terminal_capture (ansi:false).
- Never claim a preview is visible just because a pane/server exists — check
  operator_visible / browser_loaded from preview_surfaces / preview_observe_pane.
- This transport is rate-limited and every mutating call is audited server-side.

Start by listing live sessions box-wide and giving me the workspace inventory (live vs
stale). Then wait for me to name which workspace to work in.
```

---

The two **pinned** variants below are identical except the transport line; both lock to
`dalexandre-devide`.

### Door 1 (SSH tunnel)

```text
You are connected to a remote Casein dev box over MCP (SSH tunnel → http://127.0.0.1:4000).
Three JSON-RPC 2.0 servers are wired as MCP clients, all scoped to the dalexandre-devide
workspace (workspace_id e7c18b93-688b-4bb0-904d-ac93d61e9372):

  • devide-terminal  — tmux/agent control (list/topology/capture/send/wait)
  • casein-preview   — preview panes + headless browser control
  • devide-artifact  — artifact projects

Ground rules:
- Always pass workspace_id "e7c18b93-688b-4bb0-904d-ac93d61e9372" on terminal calls.
- Tool-search is ON: each big server lists only a small CORE set plus two meta-tools.
  If you need a tool that isn't listed, call search_tools with a natural-language query
  (synonyms work: "picture"→screenshot, "kill"→close), then run it via invoke_tool.
- To drive an on-box agent: terminal_topology → find the AGENT pane id (not the operator
  pane) → terminal_send_agent_command → terminal_wait_agent_state → terminal_capture
  (ansi:false unless you need color). Grok/Codex idle-state and the wait→capture loop
  behave the same as on-box.
- Never claim a preview is visible just because a pane/server exists — check
  operator_visible / browser_loaded from preview_surfaces / preview_observe_pane.
- This transport is rate-limited and every mutating call is audited server-side.

Start by calling terminal_list_sessions (with the workspace_id) and reporting the sessions,
windows, and any agent panes you find. Then wait for my instructions.
```

### Door 2 (public HTTPS)

```text
You are connected to a remote Casein dev box over MCP (public HTTPS → https://devide.devbox.milcgroup.com).
Three JSON-RPC 2.0 servers are wired as MCP clients, all scoped to the dalexandre-devide
workspace (workspace_id e7c18b93-688b-4bb0-904d-ac93d61e9372):

  • devide-terminal  — tmux/agent control (list/topology/capture/send/wait)
  • casein-preview   — preview panes + headless browser control
  • devide-artifact  — artifact projects

Ground rules:
- Always pass workspace_id "e7c18b93-688b-4bb0-904d-ac93d61e9372" on terminal calls.
- Tool-search is ON: each big server lists only a small CORE set plus two meta-tools.
  If you need a tool that isn't listed, call search_tools with a natural-language query
  (synonyms work: "picture"→screenshot, "kill"→close), then run it via invoke_tool.
- To drive an on-box agent: terminal_topology → find the AGENT pane id (not the operator
  pane) → terminal_send_agent_command → terminal_wait_agent_state → terminal_capture
  (ansi:false unless you need color). Grok/Codex idle-state and the wait→capture loop
  behave the same as on-box.
- Never claim a preview is visible just because a pane/server exists — check
  operator_visible / browser_loaded from preview_surfaces / preview_observe_pane.
- This transport is rate-limited and every mutating call is audited server-side.

Start by calling terminal_list_sessions (with the workspace_id) and reporting the sessions,
windows, and any agent panes you find. Then wait for my instructions.
```

---

## Door 1 vs Door 2

| | Door 1 (SSH tunnel) | Door 2 (public HTTPS) |
|---|---|---|
| Works today | ✅ yes | ✅ yes (bearer bypass live, #245) |
| Setup | `ssh -L 4000:…` per session | none |
| From claude.ai / phone | ✗ (no tunnel there) | ✅ |
| Transport auth | your SSH key | TLS only |
| Exposure | none (loopback) | internet-facing → wants IP allowlist / mTLS for the global token |

**Security posture:** keep the **global** token off any public surface — prefer a
workspace-scoped token for Door 2, or put access behind a Tailscale/WireGuard overlay for
anywhere-access without exposing MCP to the internet (Door 1 already has that property).
Rate limiting (`McpRateLimit`) and audit (`Casein.Agents.MCPAudit`) are on the pipeline;
confirm audit retention before exposing publicly.
