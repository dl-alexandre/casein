# Terminal MCP

DevIDE exposes tmux session control to coding agents through a narrow MCP
JSON-RPC endpoint:

```text
POST /api/terminals/mcp
```

The endpoint uses the same bearer-token gate as the rest of the API:

```text
Authorization: Bearer $DEV_IDE_API_TOKEN
```

Agents should discover this endpoint from the `terminal_mcp` capability. The
capability is exposed through normal agent capability detection and through
`GET /api/workspaces/:id/status` as `agent_capabilities`. It advertises the
MCP URL, `auth_type: "bearer"`, HTTP JSON-RPC transport, and current tool
names.

## Streamable HTTP transport

The endpoint supports the MCP Streamable HTTP transport in addition to plain
POST JSON-RPC:

- `initialize` returns an `Mcp-Session-Id` response header.
- `GET /api/terminals/mcp` with that `Mcp-Session-Id` header opens a
  server→client SSE stream (`text/event-stream`) for `notifications/*` pushes.
- `DELETE /api/terminals/mcp` with the header ends the session.

Sessions are optional and additive: a POST without an `Mcp-Session-Id` behaves
exactly like the stateless transport, so existing clients are unaffected. A POST
that supplies an unknown id gets `404 unknown_mcp_session`, signalling the client
to re-`initialize`. Server pushes are delivered through
`DevIDE.Agents.MCPSessions.notify/2`.

## Access scope

The bearer token is fully trusted on the host. Tools only touch DevIDE-managed
tmux sessions (`devide_*` prefix), never unrelated tmux sessions.

**Pass `workspace_id` on every call unless the MCP URL is pre-scoped.** Generated
same-host agent configs include `?workspace_id=<manager UUID>` on the MCP URL,
and the transport injects that value into tool calls when the agent omits it.
When set, discovery and mutation are scoped to that workspace's sessions. DevIDE
resolves both the manager UUID and the workspace **name** to tmux prefixes —
sessions are named `devide_<workspace_name>_<sid>`, not `devide_<uuid>_`.
Cross-workspace session access is rejected with `workspace_mismatch`.

Without `workspace_id`, tools can see every `devide_*` session on the host.
Prefer always scoping in production and dogfood setups.

## Command Policy

`terminal_send_command` / `terminal_send_agent_command` run arbitrary shell, so
DevIDE runs an allow/deny gate in front of them
(`DevIDE.Agents.TerminalCommandPolicy`). The default is a small denylist for
high-risk host commands such as recursive root deletes, pipe-to-shell downloads,
and `sudo`. Configure it with an allowlist or denylist of regexes matched
against the full command string:

```elixir
# config/runtime.exs (or dev.exs)
config :dev_ide, :terminal_command_policy, {:allowlist, ["^mix ", "^git "]}
config :dev_ide, :terminal_command_policy, {:denylist, ["rm -rf", "curl "]}
# Trusted local-only setups may opt out explicitly:
config :dev_ide, :terminal_command_policy, :disabled
```

Releases can use the `DEV_IDE_TERMINAL_COMMAND_POLICY` env var instead (JSON):

```bash
DEV_IDE_TERMINAL_COMMAND_POLICY='{"mode":"allowlist","patterns":["^mix ","^git "]}'
```

A blocked call returns a structured `command_blocked` tool error and is recorded
in the **Live MCP activity** feed. Raw key tools (`terminal_send_keys` /
`terminal_send_agent_keys`) are never gated — they carry control keys like `C-c`
and TUI input, so gating them would break interactivity.

Treat the policy as a **guardrail, not a hard security boundary**: because the
key tools are intentionally ungated, a determined agent could still synthesize a
command by sending its characters plus an Enter key. The policy stops a
well-behaved agent (and honest mistakes) from running disallowed *commands*; the
bearer token (and optional per-workspace tokens) remains the actual trust
boundary. Per-agent identity is a possible future addition.

## Terminal mode and MCP

Terminals are raw everywhere — there is no per-window mode and no governed
plane (see `docs/terminal.md`). Agents always interact with real tmux panes via
`terminal_send_command` / `terminal_send_keys`; the operator's LiveView chrome
never changes tmux topology or MCP behaviour.

## Agent pairing quickstart (human + external agent)

Side-by-side DevIDE development uses a built-in tmux template and explicit pane
targeting so operator keystrokes do not collide with agent MCP writes.

### Operator (human)

1. Open the workspace in DevIDE LiveView.
2. Set workspace mode to **manual** (raw multi-pane terminal).
3. **Agents → Apply Agent Pair layout** once per session.
   - Operator pane stays **focused** (human types here).
   - **Agent** pane receives MCP `terminal_send_command` / `terminal_send_keys`.
   - **Verify** pane is for `git status` / test output.
4. Watch **Agents → Live MCP activity** during agent work.

### External agent

1. Source env (devbox example):

   ```bash
   source /path/to/checkout/.devbox-agent.env
   ```

2. Always pass `workspace_id` (manager UUID or workspace name).

3. Tool flow:

   ```text
   terminal_context(workspace_id)        # returns recommended next_tool / next_arguments
     → terminal_agent_pane(workspace_id) # finds the marked agent_pair pane
     → terminal_send_agent_command(command, workspace_id)
     → terminal_capture_agent(lines: 100, ansi: false, workspace_id)
   ```

4. Prefer the `*_agent_*` shortcut tools. They refuse to mutate when the
   dedicated agent pane cannot be identified, instead of falling back to the
   operator's focused pane. Lower-level `terminal_send_command` still requires
   explicit pane targeting for safety.

5. For UI checks, use Preview MCP from the same workspace/session context
   (`preview_open_app` → observe/screenshot → `preview_close`). In worktree
   sessions, use the session-scoped Preview MCP URL so preview panes open beside
   the agent session instead of the base workspace lane. If a preview pane is
   already visible, use `preview_observe_pane` / `preview_navigate_pane` with
   that `pane_id`. See `docs/preview_mcp.md`.

### Agent-created worktrees

When an agent creates a Git worktree, it should report it back to DevIDE instead
of expecting it to appear as a new devbox workspace:

```text
terminal_report_worktree(
  workspace_id,
  worktree_path,
  branch?,
  agent?,
  runner_id?,
  session_id?,
  tmux_session_id?
)
```

DevIDE records the worktree as a child runtime context under the parent
workspace. The Agents panel then shows it in **Agent Worktrees** with an explicit
Attach shell action. Worktrees remain out of the main workspace picker.

When attached to a worktree session, keep Terminal MCP and Preview MCP on the
session-scoped URLs for that session. Do not open or navigate previews in the
base workspace session unless the operator explicitly asks you to inspect the
base checkout.

### Devbox smoke test

```bash
source .devbox-agent.env
WORKSPACE_ID=$DEVIDE_WORKSPACE_ID bash scripts/verify_agent_pairing.sh --ci
```

On the milc devbox, MCP is also reachable at
`https://devide.devbox.milcgroup.com/api/terminals/mcp` (same bearer token).
Same-host agents may use `http://127.0.0.1:4000/api/terminals/mcp`.

Deploy durability: commit and push to `master` before relying on devbox
behavior — `deploy-devbox.yml` replaces `/opt/devide/release` from git. See
`AGENTS.md` (Devbox agent pairing).

## Tool Flow

1. Call `initialize`.
2. Call `tools/list`.
3. Call `terminal_context` with `workspace_id` when unsure. It returns the
   recommended session, agent pane safety, and exact `next_tool` /
   `next_arguments`.
4. Call `terminal_list_sessions` with `workspace_id` to discover session names
   (e.g. `devide_my_workspace_u-alice-abcd1234`).
5. Call `terminal_topology` with that `session` and `workspace_id` to inspect
   windows and panes (each pane carries an id like `%3`).
6. Read output with `terminal_capture` (pass `pane`, `lines` to tail,
   `ansi: false` for plain text), and drive the session with
   `terminal_send_keys` (raw keys, e.g. `C-c`) or `terminal_send_command`
   (a shell command + Enter). Target the **agent** pane explicitly.
   Prefer `terminal_paste_agent_text` for multiline/literal text.

All session-scoped tools require a `devide_`-prefixed session that currently
exists; a `pane` must belong to that session.

## Smoke Test

Set the base URL, token, and workspace:

```bash
export DEVIDE_URL=http://localhost:4000
export DEV_IDE_API_TOKEN=...
export WORKSPACE_ID=my-workspace-id
```

Or run the bundled verifier:

```bash
WORKSPACE_ID=$WORKSPACE_ID bash scripts/verify_agent_pairing.sh
```

Initialize:

```bash
curl -sS -X POST "$DEVIDE_URL/api/terminals/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {"protocolVersion": "2025-03-26"}
  }'
```

List tools:

```bash
curl -sS -X POST "$DEVIDE_URL/api/terminals/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list"
  }'
```

List live sessions (scoped):

```bash
curl -sS -X POST "$DEVIDE_URL/api/terminals/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "terminal_list_sessions",
      "arguments": {"workspace_id": "'"$WORKSPACE_ID"'"}
    }
  }'
```

Read the tail of a pane (plain text):

```bash
curl -sS -X POST "$DEVIDE_URL/api/terminals/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "terminal_capture",
      "arguments": {
        "workspace_id": "'"$WORKSPACE_ID"'",
        "session": "devide_my_workspace_main",
        "pane": "%3",
        "lines": 50,
        "ansi": false
      }
    }
  }'
```

Run a command in the agent pane:

```bash
curl -sS -X POST "$DEVIDE_URL/api/terminals/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": {
      "name": "terminal_send_command",
      "arguments": {
        "workspace_id": "'"$WORKSPACE_ID"'",
        "session": "devide_my_workspace_main",
        "pane": "%3",
        "command": "mix test"
      }
    }
  }'
```

## Notes

`terminal_send_keys` and `terminal_send_command` inject input into a live
shell. Access control is the API token plus the `devide_` session guardrail and
workspace scoping; command execution can additionally be constrained with the
configurable [command policy](#command-policy).
`terminal_capture` returns the full scrollback by default; pass `lines` to
bound what the agent reads.
When `workspace_id` is omitted, `terminal_list_sessions` omits the field from
the response instead of returning `workspace_id: null`.

Mutating terminal MCP calls are audited and appear in the workspace **Live MCP
activity** feed (Agents tab).
