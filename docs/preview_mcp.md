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
3. Call `preview_open_current_workspace` when the MCP URL is pre-scoped, or
   call `preview_open_app` with a `workspace_id` / `workspace_path`.
4. Use the returned `session_id` with `preview_observe`,
   `preview_observe_live`, `preview_click`, `preview_type`, `preview_press`,
   `preview_screenshot`, `preview_get_storage`, and `preview_report_errors`.
5. Use `preview_reload_iframe` to ask connected DevIDE workspace viewers to
   reload their active embedded preview iframe, or `devide_reload_page` to ask
   them to reload the whole workspace page.
6. Call `preview_close` with the `session_id` when the agent is done.

Preview actions are scoped to workspace/localhost origins through
`DevIDE.PreviewControl`; agents do not get arbitrary browser access.
Opening a preview session broadcasts the selected preview to connected DevIDE
workspace viewers, so an embeddable `display_url` becomes visible in the preview
pane while the agent continues controlling its own session runtime. Same-origin
navigations update the visible iframe URL; unrelated screenshot/artifact URLs do
not become iframe sources.
Generated same-host agent configs use a pre-scoped MCP URL, so the transport
injects that workspace id into workspace-scoped tools when the agent omits it.
Browser refresh tools are best-effort workspace broadcasts: they return once the
request is queued for connected DevIDE viewers, not when every browser tab has
executed the reload.

Folder-attached workspaces use ids shaped as
`folder:<base64url-absolute-path>`. Agents should call
`preview_resolve_workspace` with `workspace_path`, `path`, or `cwd` instead of
hand-encoding this value.

For forward-auth or header-gated apps, pass `default_headers` when opening the
session. These headers are sent by static HTTP observation and by the Playwright
browser context, including WebSocket upgrade requests:

```json
{"default_headers":{"X-Auth-Request-Email":"agent@example.com"}}
```

Deployments can also configure server-side defaults that apply whenever the
caller opens a session without `default_headers` (caller-provided headers
always win):

```bash
# Either a full JSON header object…
DEV_IDE_PREVIEW_DEFAULT_HEADERS='{"X-Auth-Request-Email":"agent@example.com"}'
# …or the forward-auth email shorthand.
DEV_IDE_PREVIEW_FORWARD_AUTH_EMAIL=agent@example.com
```

These env vars are read in the prod-only section of `config/runtime.exs`, so
they apply to releases (the devbox systemd deploy) but are ignored by a dev
`mix phx.server`. In dev, set the application env directly if needed:
`config :dev_ide, :preview_default_headers, %{...}` in `dev.exs`.

The named `app` surface falls back to the best discoverable surface (manager
surfaces first, then terminal-detected localhost ports) when the workspace has
no registered `app` surface, so `preview_open_current_workspace` works on
workspaces without manager surface metadata. Explicitly named surfaces other
than `app` still return `surface_not_found`.

`preview_observe` and browser-backed observations include
`dom_summary.visible_text` for quick text checks. If `preview_open_localhost`
rejects a port, the tool error includes the rejected `port` and `allowed_ports`.

## Preview Scoping Plan

Previews are workspace resources first. A `preview` represents an open,
workspace-scoped surface or URL, while a `preview_control_session` represents one
browser/control runtime attached to that preview. The terminal `session_id` and
`pane_id` on a preview are provenance, not hard ownership; tmux windows are not
currently part of preview identity.

The target model is to break previews up by durable surface identity, then layer
short-lived control sessions on top:

- **Preview identity:** `workspace_id` + normalized surface/origin. Examples:
  `app`, `api`, `tidewave`, `localhost:5173`, or a trusted public workspace
  origin.
- **Control-session identity:** one actor/task/auth/storage runtime attached to
  a preview. Use this when an agent assignment, human operator, forward-auth
  header set, or browser storage state must stay isolated.
- **Terminal affinity:** terminal session, tmux window, and pane metadata answer
  "where did this preview come from?" and "what should the focused UI prefer?".
  They should not cause duplicate previews by themselves.

Breakup rules:

- Reuse an existing preview when the normalized workspace surface/origin matches.
- Navigate within an existing preview for same-origin route changes unless the
  caller explicitly asks for a separate control session.
- Create a separate preview for a distinct surface/origin, for example app vs.
  API, Tidewave, or another allowed localhost port.
- Create a separate control session, not a separate preview, when auth headers,
  storage state, actor, or assignment needs isolation.
- Keep untrusted or cross-origin URLs out of embedded preview panels; preserve the
  existing workspace-origin allowlist boundary.

Implementation phases:

1. **Normalize identity.** Add a shared preview identity helper that derives a
   stable `surface_key` from manager surfaces, localhost candidates, and raw URLs.
   Store it in preview metadata first to avoid a migration until the shape proves
   stable.
2. **Deduplicate opens.** Route `preview_open_app`, `preview_open_localhost`,
   palette opens, detected terminal opens, and LiveView surface opens through the
   same find-or-open path keyed by `workspace_id` + `surface_key`.
3. **Make control sessions explicit.** Add an optional MCP argument such as
   `new_control_session: true` or `isolation_key` for callers that need a fresh
   browser runtime on an existing preview.
4. **Add affinity metadata.** Capture terminal session, tmux window, and pane
   metadata when available. Use it for UI sorting, focused-window suggestions,
   and audit context, not as the primary dedupe key.
5. **Expose preview groups in the UI.** Replace the single hidden preview stream
   with visible workspace preview tabs grouped by surface, showing the active
   control session and recent terminal affinity.
6. **Prune safely.** Closing a control session should only close that runtime.
   Closing a preview should close or detach all open control sessions for that
   preview and mark the preview closed.

Non-goals for this pass:

- Do not make previews hard-scoped to tmux windows.
- Do not add arbitrary external browser access.
- Do not create duplicate previews solely because multiple panes printed the same
  dev-server URL.

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

Observe the page with the returned `session_id`. Use `preview_observe` for a
fast static HTML fetch, or `preview_observe_live` when you need the hydrated DOM
from the browser runtime:

```bash
curl -sS -X POST "$DEVIDE_URL/api/preview/mcp" \
  -H "authorization: Bearer $DEV_IDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "preview_observe_live",
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
`preview_observe_live` uses the configured Playwright helper to load the current
preview URL, wait briefly for `networkidle`, and return a post-hydration DOM
summary. If Playwright is unavailable, `preview_observe_live` falls back to the
static HTTP observation; the same fallback is used if the browser helper fails
before producing a live observation.

Real `click`, `type`, `press`, screenshot capture, and `preview_get_storage` use
the configured Playwright helper. Playwright-backed actions return a live
post-hydration DOM summary and flush console/page/network errors captured since
the previous action. `preview_get_storage` returns `local_storage` and
`session_storage` for the current preview origin.

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
