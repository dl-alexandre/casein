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

## Access scope

The bearer token is fully trusted: tools operate on **every** DevIDE-managed
(`devide_*`) tmux session on the host, regardless of workspace. There is no
per-workspace scoping — `terminal_list_sessions` enumerates all of them and
the driving tools can read/control any of them. The only guardrail is the
`devide_` prefix, which keeps agents from touching tmux sessions DevIDE does
not own. Treat the API token accordingly.

## Tool Flow

1. Call `initialize`.
2. Call `tools/list`.
3. Call `terminal_list_sessions` to discover a session name (e.g.
   `devide_<workspace>_<tab>`).
4. Call `terminal_topology` with that `session` to inspect its windows and
   panes (each pane carries an id like `%3`).
5. Read output with `terminal_capture` (optionally `pane`, `lines` to tail,
   `ansi: false` for plain text), and drive the session with
   `terminal_send_keys` (raw keys, e.g. `C-c`) or `terminal_send_command`
   (a shell command + Enter). Pass `pane` to target a non-focused pane.

All session-scoped tools require a `devide_`-prefixed session that currently
exists; a `pane` must belong to that session.

## Smoke Test

Set the base URL and token:

```bash
export DEVIDE_URL=http://localhost:4000
export DEV_IDE_API_TOKEN=...
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

List live sessions:

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
      "arguments": {}
    }
  }'
```

Read the tail of a session's active pane (plain text):

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
        "session": "devide_my_workspace_main",
        "lines": 50,
        "ansi": false
      }
    }
  }'
```

Run a command in a specific pane:

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
        "session": "devide_my_workspace_main",
        "pane": "%3",
        "command": "mix test"
      }
    }
  }'
```

## Notes

`terminal_send_keys` and `terminal_send_command` inject input into a live
shell — there is no command allow-list beyond the `devide_` session guardrail.
Access control is the API token. `terminal_capture` returns the full
scrollback by default; pass `lines` to bound what the agent reads.
