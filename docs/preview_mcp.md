# Preview MCP

DevIDE exposes preview control to coding agents through a narrow MCP
JSON-RPC endpoint:

```text
POST /api/preview/mcp
```

The endpoint uses the same bearer-token gate as the rest of the API:

```text
Authorization: Bearer $CASEIN_API_TOKEN
```

Agents should discover this endpoint from the `preview_mcp` capability. The
capability is exposed through normal agent capability detection and through
`GET /api/workspaces/:id/status` as `agent_capabilities`. It advertises the
MCP URL, `auth_type: "bearer"`, HTTP JSON-RPC transport, and current tool
names.

## Streamable HTTP transport

The endpoint supports the MCP Streamable HTTP transport in addition to plain
POST JSON-RPC:

- `initialize` returns an `Mcp-Session-Id` response header.
- `GET /api/preview/mcp` with that `Mcp-Session-Id` header opens a
  server→client SSE stream (`text/event-stream`) for `notifications/*` pushes.
- `DELETE /api/preview/mcp` with the header ends the session.

Sessions are optional and additive: a POST without an `Mcp-Session-Id` behaves
exactly like the stateless transport, so existing clients are unaffected. A POST
that supplies an unknown id gets `404 unknown_mcp_session`, signalling the client
to re-`initialize`. Missing or unknown streamable-session errors preserve the
top-level `error` string and include `code`, `message`, and
`error_version: "mcp-streamable-http-v1"`. Server pushes are delivered through
`DevIDE.Agents.MCPSessions.notify/2`.

## Access scope

Global tokens may initialize and list the available tools, but Preview MCP
`tools/call` execution requires a workspace-scoped API token. A global token
receives `403 workspace_scoped_token_required` before the tool handler runs, so
it cannot open, observe, click, type, screenshot, or close previews through MCP.
Use generated workspace-scoped MCP URLs in production and dogfood setups.

## Tool Flow

1. Call `initialize`.
2. Call `tools/list`.
3. Call `preview_open` to open a preview. Pick the surface with `mode`:
   - `mode: "app"` (default) opens the workspace app surface. On a pre-scoped
     MCP URL you can omit `workspace_id`; otherwise pass `workspace_id` /
     `workspace_path`.
   - `mode: "localhost"` opens a specific dev-server `port`.
   - `mode: "here"` opens the app surface beside the calling agent (needs
     `tmux_session`, injected automatically by a session-scoped MCP URL).

   `preview_open` splits the active tmux window and runs `devide-preview <url>`
   in the new pane. The response includes `pane_id` plus the usual `session_id`.
   The older `preview_open_app`, `preview_open_localhost`, `preview_open_here`,
   and `preview_open_current_workspace` tools remain as deprecated aliases.
4. In worktree sessions, use the session-scoped Preview MCP URL supplied by
   the launcher/status payload. That URL injects both the workspace and
   `tmux_session`, so open tools split beside the agent's session instead of
   the base workspace lane. Do not use the base workspace preview lane unless
   the human explicitly asks for it.
5. Open previews from the agent pane/session you are working in. If a preview
   pane is already visible, prefer `preview_observe_pane` and
   `preview_navigate_pane` with that pane's `pane_id` instead of opening a
   second preview.
6. Use the returned `session_id` with `preview_observe`,
   `preview_observe_live`, `preview_click`, `preview_type`, `preview_press`,
   `preview_screenshot`, `preview_get_storage`, and `preview_report_errors`.
   After `preview_observe_live`, call `preview_elements` and prefer the returned
   `element_id` values with `preview_click` / `preview_type` instead of guessing
   CSS selectors.
7. For repeatable evidence, call `preview_record_start` before driving the
   browser flow, drive it with `preview_click` / `preview_type` /
   `preview_press` / `preview_navigate`, then call `preview_record_stop`.
   `preview_record_stop` returns an `artifact_path`; pass that path to
   `preview_playback_open` to split a fresh preview pane that loops the saved
   recording. Inspect that pane with `preview_observe_pane`.
8. Use `preview_navigate_pane` with the returned `pane_id` to navigate an
   already embedded preview pane and update connected DevIDE viewers.
9. Use `preview_reload_iframe` to ask connected DevIDE workspace viewers to
   reload all preview-pane iframes in the terminal layout, or
   `devide_reload_page` to ask them to reload the whole workspace page.
10. Call `preview_close` with the `session_id` when the agent is done. This
   kills the preview tmux pane and expires the pane registration.

`devide-preview` is shipped in release `priv/scripts/`. Humans can also run
`devide-preview :4000` (or any trusted URL) inside a tmux pane; the CLI
registers the pane via `POST /api/preview/panes` and DevIDE paints an
iframe overlay at the pane rectangle.

Preview actions are scoped to workspace/localhost origins through
`DevIDE.PreviewControl`; agents do not get arbitrary browser access.
For DevIDE-hosted preview pane URLs, the iframe keeps the public display URL,
while the control session uses the configured loopback DevIDE URL. This lets
on-box Playwright automation avoid the external forward-auth redirect.

## Agent Bug-Fix Loop

DevIDE now exposes the primitives needed for an external agent to work a bug
with visible feedback:

- Use Terminal MCP to inspect files, edit, run the dev server/tests, and capture
  server output from the relevant tmux pane.
- Use Preview MCP to open the app/runtime surface, observe hydrated DOM, click,
  type, press keys, read storage, collect console/network errors, and capture
  screenshots.
- Use Tidewave MCP directly against the resolved external Tidewave URL when a
  dev/preview-env instance exposes it. DevIDE only resolves/materializes the URL;
  it does not proxy Tidewave tools.
- Use `preview_record_start` / `preview_record_stop` to capture the Playwright
  browser flow, then `preview_playback_open` to keep the saved `.webm` / `.mp4`
  looping in a fresh preview pane while the agent or human reviews it.

The remaining gap is orchestration, not the individual controls: there is no
single DevIDE tool that bundles terminal output, Tidewave output, preview
observations, and the recording into one bug-work evidence packet. Agents should
coordinate those surfaces explicitly and cite the returned `session_id`,
`pane_id`, terminal capture, Tidewave results, and recording `artifact_path`.
Recording captures the Playwright page the agent drives, not arbitrary human
screen activity.

## Socket Boundary Smoke Check

Production DevIDE traffic and ephemeral preview traffic use separate socket
lanes:

- Main app: `/run/devide/current.sock`
- Preview envs: `.devide-preview/sockets/*.sock`

The preview router must never become the upstream for
`devide.devbox.milcgroup.com`, and a worktree preview launch must not touch the
main app socket. Use the boundary smoke check before and after preview lifecycle
changes:

```bash
scripts/verify-preview-socket-boundaries.sh
```

To remove stale preview registry entries before checking router state:

```bash
scripts/verify-preview-socket-boundaries.sh --cleanup
```

The script verifies the main socket responds, preview registry socket paths stay
under `.devide-preview/sockets/`, and `scripts/preview-router.sh status` does
not reference `/run/devide/current.sock`.

## Control-plane layers

```text
MCP tools (PreviewTools)
        │
        ▼
DevIDE.PreviewControl          ← Ecto sessions, audit, PubSub, surface open
        │
        ▼
PreviewCtl.Session             ← origin guard, registry, adapter dispatch
        │
   ┌────┴────┐
   ▼         ▼
FakeAdapter  Playwright.Adapter (+ Bridge GenServer)
```

`PreviewCtl` is an in-repo boundary (like `TmuxCtl`): generic URL primitives,
ETS session registry, adapter behaviour, and optional Node Playwright bridge.
DevIDE keeps workspace allowlists (`DevIDE.Previews.Url`), persistence, and
human-iframe broadcasts.

### Adapter configuration (two keys)

| Key | App | Purpose |
|-----|-----|---------|
| `:preview_control_adapter` | `:dev_ide` | Operator-facing atom (`:memory` \| `:playwright`) |
| `:adapter` | `:preview_ctl` | Resolved adapter module (set at boot from the atom) |

`DevIDE.Application.configure_preview_ctl!/0` copies `config :dev_ide, :preview_ctl`
and maps `:preview_control_adapter` → `:preview_ctl :adapter`. Playwright script
path uses `:dev_ide :preview_playwright_script` → `:preview_ctl :playwright_script`.
DevIDE facades (`DevIDE.PreviewControl.PlaywrightAdapter`, `MemoryAdapter`,
`PlaywrightBridge`, `Registry`) defdelegate to `PreviewCtl.*` for backward
compatibility.
Opening a preview session registers a tmux preview pane and broadcasts to
connected DevIDE workspace viewers. Each registered pane gets an iframe overlay
in the terminal layout at the pane's geometry. Same-origin navigations update
the control session URL; unrelated screenshot/artifact URLs do not become
iframe sources.
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
CASEIN_PREVIEW_DEFAULT_HEADERS='{"X-Auth-Request-Email":"agent@example.com"}'
# …or the forward-auth email shorthand.
CASEIN_PREVIEW_FORWARD_AUTH_EMAIL=agent@example.com
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
`dom_summary.visible_text` for quick text checks. `preview_elements` derives
clickable/typeable `element_id` targets from the browser-backed DOM summary.
If `preview_open_localhost` rejects a port, the tool error includes the rejected
`port` and `allowed_ports`. The localhost accept set is common dev ports,
workspace metadata ports, and terminal-detected ports.

Preview infrastructure reserves the `41000–41099` loopback block in disjoint
sub-bands: `41000–41049` for ephemeral preview envs, `41050–41079` for
runtime-owned preview servers, and `41080–41081` for the preview router listener
and admin listener.

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
  a preview. Use this when an agent task, human operator, forward-auth
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
  storage state, actor, or task needs isolation.
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
export CASEIN_API_TOKEN=...
```

Initialize:

```bash
curl -sS -X POST "$DEVIDE_URL/api/preview/mcp" \
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
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
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
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
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "preview_open",
      "arguments": {
        "mode": "app",
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
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
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
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
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

`preview_record_start` and `preview_record_stop` use the same Playwright page
and record only agent-driven browser activity for that control session. Stopping
the recording stores a `.webm` artifact under `/preview-artifacts/...` and shows
it in the registered preview pane. `preview_playback_open` accepts that returned
artifact path (or a full artifact URL, reduced to its path) and opens a fresh
tmux preview pane pointed at `?fit=playback`; it loops by default and accepts
`loop: false` for one-shot playback.

Preview browser storage is ephemeral by default. Open tools accept
`storage_profile`:

- `ephemeral` keeps cookies/localStorage only for the active browser runtime.
- `workspace` saves Playwright storage state per workspace and preview origin so
  logins/localStorage survive closing and reopening the preview.
- `profile` saves a named profile; pass `storage_profile_name` such as
  `staging-admin` or `demo-user`.

Use `new_control_session: true` when you want a separate browser runtime, and
use different profile names when auth state must stay isolated.
`preview_clear_storage` clears cookies, localStorage, and sessionStorage for the
current origin; for persistent profiles it also writes the cleared state back to
the saved profile.

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
CASEIN_PREVIEW_CONTROL_ADAPTER=playwright
# Optional; relative paths resolve from the release app priv directory.
CASEIN_PREVIEW_PLAYWRIGHT_SCRIPT=scripts/preview_playwright.mjs
CASEIN_PREVIEW_ARTIFACTS_ROOT=/opt/devide/preview_artifacts
```

For the systemd devbox deployment, the release build installs the locked
`priv/scripts` npm dependency into the release tree. Chromium still needs to be
installed once for the service user:

```bash
cd /opt/devide/release/lib/casein-*/priv/scripts
sudo -u devbox env HOME=/home/devbox node node_modules/playwright/cli.js install chromium
```

Then restart `devide` so `PreviewCtl.Playwright.Bridge` starts with the
configured helper (`DevIDE.PreviewControl.PlaywrightBridge` is a thin facade). The generic Docker runtime image does not currently
include Node or browser OS dependencies, so keep
`CASEIN_PREVIEW_CONTROL_ADAPTER=memory` there until the image is extended for
browser automation.
