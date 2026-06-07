# Preview MCP

DevIDE exposes preview control to coding agents through a narrow MCP
JSON-RPC endpoint:

```text
POST /api/preview/mcp
```

The endpoint uses the same bearer-token gate as the rest of the API:

```text
Authorization: Bearer $DEV_IDE_API_TOKEN
```

Agents should discover this endpoint from the `preview_mcp` capability. The
capability is exposed through normal agent capability detection and through
`GET /api/workspaces/:id/status` as `agent_capabilities`. It advertises the
MCP URL, `auth_type: "bearer"`, HTTP JSON-RPC transport, and current tool
names.

## Tool Flow

1. Call `initialize`.
2. Call `tools/list`.
3. Call `preview_open_app` with a `workspace_id`.
4. Use the returned `session_id` with `preview_observe`, `preview_click`,
   `preview_type`, `preview_press`, `preview_screenshot`, and
   `preview_report_errors`.
5. Call `preview_close` with the `session_id` when the agent is done.

Preview actions are scoped to workspace/localhost origins through
`DevIDE.PreviewControl`; agents do not get arbitrary browser access.

## Smoke Test

Set the base URL and token:

```bash
export DEVIDE_URL=http://localhost:4000
export DEV_IDE_API_TOKEN=...
```

Initialize:

```bash
curl -sS -X POST "$DEVIDE_URL/api/preview/mcp" \
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
curl -sS -X POST "$DEVIDE_URL/api/preview/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list"
  }'
```

Open the app preview:

```bash
curl -sS -X POST "$DEVIDE_URL/api/preview/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "preview_open_app",
      "arguments": {
        "workspace_id": "ws-1",
        "surface": "app"
      }
    }
  }'
```

Observe the page with the returned `session_id`:

```bash
curl -sS -X POST "$DEVIDE_URL/api/preview/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "preview_observe",
      "arguments": {
        "session_id": 1
      }
    }
  }'
```

Close the session:

```bash
curl -sS -X POST "$DEVIDE_URL/api/preview/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": {
      "name": "preview_close",
      "arguments": {
        "session_id": 1
      }
    }
  }'
```

## Browser Interaction

`preview_observe` uses HTTP observation and can run without a browser helper.
Real `click`, `type`, `press`, and screenshot capture use the configured
Playwright helper.

Development defaults enable the Playwright adapter and resolve the helper at
`priv/scripts/preview_playwright.mjs`. Install the helper dependency and a
browser from the repo root:

```bash
cd priv/scripts
npm ci
npx playwright install chromium
```

Production can opt into browser automation with:

```bash
DEV_IDE_PREVIEW_CONTROL_ADAPTER=playwright
# Optional; relative paths resolve from the release app priv directory.
DEV_IDE_PREVIEW_PLAYWRIGHT_SCRIPT=scripts/preview_playwright.mjs
DEV_IDE_PREVIEW_ARTIFACTS_ROOT=/opt/devide/preview_artifacts
```

For the systemd devbox deployment, the release build installs the locked
`priv/scripts` npm dependency into the release tree. Chromium still needs to be
installed once for the service user:

```bash
cd /opt/devide/release/lib/dev_ide-*/priv/scripts
sudo -u devbox env HOME=/home/devbox node node_modules/playwright/cli.js install chromium
```

Then restart `devide` so `DevIDE.PreviewControl.PlaywrightBridge` starts with
the configured helper. The generic Docker runtime image does not currently
include Node or browser OS dependencies, so keep
`DEV_IDE_PREVIEW_CONTROL_ADAPTER=memory` there until the image is extended for
browser automation.
