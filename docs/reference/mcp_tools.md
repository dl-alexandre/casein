# MCP Tools Reference

> The complete catalog of MCP (Model Context Protocol) tools an external coding agent can call against DevIDE: terminal control, preview control, workspace annotations, and the resolved-but-external Tidewave bridge.

This is a flat reference catalog. For narrative flow, scoping rules, and smoke
tests see [`../terminal_mcp.md`](../terminal_mcp.md) and
[`../preview_mcp.md`](../preview_mcp.md). For the preview control plane internals
(`PreviewControl` → `PreviewCtl.Session` → adapters) see
[`../preview_mcp.md`](../preview_mcp.md).

## Responsibility

Expose a narrow, auditable, workspace-scoped tool surface so external agents
(Grok, Claude, Codex, opencode) can drive DevIDE the way a human would — tmux
panes, browser previews, and review annotations — over JSON-RPC 2.0, without
arbitrary shell or browser access. Each surface is one HTTP POST endpoint behind
the same bearer-token gate (`DevIdeWeb.Plugs.ApiAuth`).

## Module map

| Module | File | Role |
|--------|------|------|
| `DevIdeWeb.API.TerminalMCP` | `lib/dev_ide_web/api/terminal_mcp.ex` | Pure JSON-RPC handler for the terminal surface; `initialize`/`tools/list`/`tools/call`/`ping` dispatch |
| `DevIdeWeb.API.PreviewMCP` | `lib/dev_ide_web/api/preview_mcp.ex` | Pure JSON-RPC handler for the preview surface; resolves/validates workspace per call |
| `DevIdeWeb.API.TerminalMCPController` | `lib/dev_ide_web/controllers/api/terminal_mcp_controller.ex` | HTTP transport for terminal MCP; maps handler outcomes to status codes |
| `DevIdeWeb.API.PreviewMCPController` | `lib/dev_ide_web/controllers/api/preview_mcp_controller.ex` | HTTP transport for preview MCP |
| `DevIDE.Agents.TerminalTools` | `lib/dev_ide/agents/terminal_tools.ex` | Tool definitions + `invoke/2` for all `terminal_*` tools |
| `DevIDE.Agents.PreviewTools` | `lib/dev_ide/agents/preview_tools.ex` | Tool definitions + `invoke/3` for all `preview_*` / `devide_reload_page` tools |
| `DevIDE.Agents.AnnotationTools` | `lib/dev_ide/agents/annotation_tools.ex` | `annotation_*` tools (folded into the terminal surface) |
| `DevIdeWeb.API.MCPWorkspaceScope` | `lib/dev_ide_web/api/mcp_workspace_scope.ex` | Pre-scoped-endpoint workspace injection / mismatch enforcement / schema-`required` rewriting |
| `DevIDE.Agents.MCPAudit` | `lib/dev_ide/agents/mcp_audit.ex` | Records activity feed + `Audit.emit!` for mutating tools |
| `DevIDE.Agents.MCPError` | `lib/dev_ide/agents/mcp_error.ex` | Normalizes `{:error, reason}` into MCP `tool_result` content |
| `DevIDE.Agents.TerminalMCPCapability` | `lib/dev_ide/agents/terminal_mcp_capability.ex` | Advertises terminal MCP URL + tool names in capability detection |
| `DevIDE.Agents.PreviewMCPCapability` | `lib/dev_ide/agents/preview_mcp_capability.ex` | Advertises preview MCP URL + tool names |
| `DevIDE.Agents.TidewaveCapability` | `lib/dev_ide/agents/tidewave_capability.ex` | Detects the dev-only Tidewave endpoint (URL only — DevIDE does not implement tidewave tools) |
| `DevIDE.Agents.TidewaveMCP` | `lib/dev_ide/agents/tidewave_mcp.ex` | Resolves an external Tidewave MCP URL for agent client config materialization |
| `DevIDE.Agents.BrowserControl` | `lib/dev_ide/agents/browser_control.ex` | Backs `preview_reload_iframe` / `devide_reload_page` viewer broadcasts |
| `McpCtl.Tool` / `McpCtl.Params` | (in-repo `mcp_ctl` boundary) | `Tool.define/3`, `Tool.object/1,2`, shared param schemas used by every definition |

## Endpoints

| Surface | Method + Path | Auth | Handler → Tools |
|---------|---------------|------|------------------|
| Terminal MCP | `POST /api/terminals/mcp` | `Authorization: Bearer $DEV_IDE_API_TOKEN` | `TerminalMCP` → `TerminalTools` + `AnnotationTools` |
| Terminal MCP info | `GET /api/terminals/mcp` | bearer | returns `405` (POST/JSON-RPC only) |
| Preview MCP | `POST /api/preview/mcp` | bearer | `PreviewMCP` → `PreviewTools` |
| Preview MCP info | `GET /api/preview/mcp` | bearer | returns `405` |
| Preview pane register | `POST /api/preview/panes`, `DELETE /api/preview/panes/:id` | bearer | `PreviewPaneController` — used by the `devide-preview` CLI, not an MCP tool |
| Tidewave (dev only) | external `…/tidewave/mcp` | per-server | NOT served by DevIDE; URL resolved by `TidewaveMCP` |

Routes defined in `lib/dev_ide_web/router.ex` (`scope "/api", DevIdeWeb.API`).
JSON-RPC: `protocolVersion` `2025-03-26`; `tools/list` returns
`{name, description, inputSchema}`; `tools/call` returns
`{content: [text], structuredContent}`.

## Tool catalog — Terminal MCP (`POST /api/terminals/mcp`)

Implemented in `DevIDE.Agents.TerminalTools` (dispatch in `invoke/2`). Every
session-scoped tool is guarded to `devide_`-prefixed tmux sessions. `workspace_id`
is injected when the endpoint is pre-scoped (`?workspace_id=…`).

| Tool | Does | Key params (required\*) | Implementing fn |
|------|------|--------------------------|-----------------|
| `terminal_list_sessions` | List live DevIDE tmux sessions (name, attached, activity) | `workspace_id`, `contains` | `list_sessions/1` |
| `terminal_context` | Recommended session, agent pane safety, and exact next tool/arguments | `workspace_id`, `session` | `context/1` |
| `terminal_topology` | Windows/panes with geometry, running command, active marker | `session`\* , `workspace_id` | `topology/1` |
| `terminal_capture` | Capture a pane's scrollback (defaults active pane, full history) | `session`\*, `pane`, `lines`, `ansi` | `capture/1` |
| `terminal_agent_pane` | Find the `agent_pair` agent pane (marker, then process fallback) | `session`, `workspace_id` | `agent_pane/1` |
| `terminal_capture_agent` | Capture scrollback from the dedicated agent pane | `session`, `lines`, `ansi` | `capture_agent/1` |
| `terminal_send_agent_keys` | Send raw keys to the agent pane only (requires marker) | `keys`\*, `session` | `send_agent_keys/1` |
| `terminal_send_agent_command` | Type command + Enter into the agent pane (requires marker) | `command`\*, `session` | `send_agent_command/1` |
| `terminal_paste_agent_text` | Paste literal/multiline text into the agent pane via tmux paste buffer | `text`\*, `submit`, `session` | `paste_agent_text/1` |
| `terminal_send_keys` | Send raw keys to a pane, no trailing Enter (tmux key names) | `session`\*, `keys`\*, `pane` | `send_keys/1` |
| `terminal_send_command` | Type command + Enter into a targeted pane | `session`\*, `command`\*, `pane` | `send_command/1` |
| `terminal_set_agent_label` | Set a DevIDE chrome label for an agent pane (`freeze` to pin) | `workspace_id`\*, `label`\*, `session`, `pane` | `set_agent_label/1` |
| `terminal_report_worktree` | Register an agent-created Git worktree under the workspace | `workspace_id`\*, `worktree_path`\*, `branch`, `agent`, `runner_id`, `session_id`, `tmux_session_id` | `report_worktree/1` |

### Annotation tools (folded into the terminal surface)

Implemented in `DevIDE.Agents.AnnotationTools`; appended to `TerminalTools.definitions/0`.

| Tool | Does | Key params (required\*) | Implementing fn |
|------|------|--------------------------|-----------------|
| `annotation_list` | List workspace annotations (read-only) | `workspace_id`\*, `limit`, `approval_state`, `file_path`, `session_id`, `pane_id` | `list/1` |
| `annotation_propose` | Propose an annotation for human review (defaults pending) | `workspace_id`\*, `content`\*, `author_type`\* (`human`/`agent_grok`/`agent_codex`/`agent_claude`), plus one anchor: `file_path`/`terminal_range`/`preview_id`/`linked_entities`; `visibility`, `metadata`, `actor_id` | `propose/1` |

## Tool catalog — Preview MCP (`POST /api/preview/mcp`)

Implemented in `DevIDE.Agents.PreviewTools` (dispatch in `invoke/3`). Workspace
tools listed in `PreviewMCP.@workspace_tools` resolve a workspace from
`workspace_id`/`workspace_path`; session tools resolve the workspace from the
runtime `PreviewControl.Registry` by `session_id`. Actions delegate to
`DevIDE.PreviewControl` and `DevIDE.PreviewPanes`.

| Tool | Does | Key params (required\*) | Implementing fn |
|------|------|--------------------------|-----------------|
| `preview_resolve_workspace` | Resolve a `workspace_id` from manager id or folder path | `workspace_id` / `workspace_path` / `path` / `cwd` | `resolve_workspace/1` |
| `preview_surfaces` | List discoverable surfaces (manager URLs, metadata + terminal-detected ports) | `workspace_id`\* | `surfaces/1` |
| `preview_open_current_workspace` | Open the pre-scoped workspace app preview; auto-navigate viewer on loopback | (workspace-scoped; no `workspace_id` arg) | `open_app_preview/2` |
| `preview_open_app` | Open the workspace app (or named `surface`) preview in a control session | `workspace_id`\*, `surface`, storage/header opts | `open_app_preview/2` |
| `preview_open_localhost` | Open a localhost preview on an allowed `port` | `workspace_id`\*, `port`\*, `path` | `open_localhost_preview/2` |
| `preview_navigate` | Navigate within the allowed preview origin | `session_id`\*, `path`\* | `navigate/1` |
| `preview_navigate_pane` | Navigate an embedded pane by tmux `pane_id` + broadcast | `pane_id`\*, `path`\* | `navigate_pane/1` |
| `preview_observe_pane` | Observe a registered pane (URL/title, mode, latest screenshot, recent activity) | `workspace_id`\*, `pane_id`\*, `limit` | `observe_pane/2` |
| `preview_observe` | Observe current page via static HTTP HTML fetch | `session_id`\* | `observe/1` |
| `preview_observe_live` | Observe post-hydration DOM via Playwright (falls back to static) | `session_id`\* | `observe_live/1` |
| `preview_elements` | List visible clickable/typeable targets with stable `element_id` values | `session_id`\*, `query` | `elements/1` |
| `preview_click` | Click by `element_id`, CSS selector (`nth`), or viewport `x`/`y` | `session_id`\*, `element_id`/`selector`/`x`+`y`, `nth` | `click/1` |
| `preview_type` | Type text into an input matched by `element_id` or selector | `session_id`\*, `element_id`/`selector`, `text`\*, `nth` | `type/1` |
| `preview_press` | Press a keyboard key | `session_id`\*, `key`\* | `press/1` |
| `preview_screenshot` | Capture a screenshot artifact | `session_id`\* | `screenshot/1` |
| `preview_close` | Close the control session, kill the preview pane, release browser | `session_id`\* | `close/1` |
| `preview_get_storage` | Return localStorage + sessionStorage for the origin | `session_id`\* | `get_storage/1` |
| `preview_clear_storage` | Clear cookies/localStorage/sessionStorage (updates saved profile) | `session_id`\* | `clear_storage/1` |
| `preview_report_errors` | Return console + network errors from the latest observation | `session_id`\* | `report_errors/1` |
| `preview_reload_iframe` | Best-effort: ask connected viewers to reload the active preview iframe | `workspace_id`\*, `actor_id`, `reason` | `reload_iframe/2` |
| `devide_reload_page` | Best-effort: ask connected viewers to reload the whole workspace page | `workspace_id`\*, `actor_id`, `reason` | `reload_page/2` |

Open tools also accept `new_control_session`, `isolation_key`, `storage_profile`
(`ephemeral`/`workspace`/`profile`), `storage_profile_name`, `default_headers`,
and `viewport` (see `tool_opts/2`, `split_opts/2`).

## Tool catalog — Tidewave (dev only, external)

DevIDE does **not** implement or proxy Tidewave's tools. The Tidewave MCP server
is the third-party `:tidewave` dependency, compiled only in `MIX_ENV=dev`
(including ephemeral preview-env instances on ports 41000–41049). DevIDE's role
is discovery and client-config materialization:

- `DevIDE.Agents.TidewaveCapability.detect/0` reports the endpoint
  (`url <> "/tidewave"`, `details.mcp_url = url <> "/tidewave/mcp"`).
- `DevIDE.Agents.TidewaveMCP.resolve_url/2` resolves an MCP URL by precedence:
  `DEVIDE_TIDEWAVE_MCP_URL` → self-hosted node → workspace metadata
  (`ports.tidewave`, fingerprinted ports) → latest running preview-env instance;
  `normalize_mcp_url/1` canonicalizes to the `…/tidewave/mcp` path.

Agents call Tidewave's own tools (e.g. `project_eval`, `execute_sql_query`,
`get_docs`) directly against that resolved URL; their schemas live in the
`tidewave` hex package, not this repo.

## Data flow / lifecycle

```text
Agent (JSON-RPC 2.0 over HTTPS)
  │  Authorization: Bearer $DEV_IDE_API_TOKEN
  ▼
{Terminal,Preview}MCPController  ── ApiAuth plug; default_workspace_id from ?workspace_id= or :api_workspace_id
  ▼
{Terminal,Preview}MCP.handle/2   ── route initialize | tools/list | tools/call | ping | notifications/*
  ▼  (tools/call)
MCPWorkspaceScope.scoped_call_params/2  ── inject pre-scoped workspace_id / reject mismatch
  ▼
{Terminal,Preview}Tools.invoke   ── (Preview also resolves workspace; session tools via PreviewControl.Registry)
  ▼
MCPAudit.record_{terminal,preview}  ── Activity feed + Audit.emit! for mutating tools
  ▼
result(id, %{content: [text], structuredContent})   |   MCPError.tool_result/1
```

Handler outcomes (`{:reply, map}` → 200, `:noreply` → 202, `{:error, map}` → 400)
are mapped to HTTP status by the controllers.

## Public surface (called by other code)

- `TerminalTools.definitions/0` and `PreviewTools.definitions/0` — the tool specs
  consumed by `tool_specs/0` in each handler and by capability advertisement
  (`{Terminal,Preview}MCPCapability.detect/0` → `tool_names/0`).
- `TerminalTools.invoke/2`, `PreviewTools.invoke/3`, `AnnotationTools.invoke/2` —
  tool dispatch entry points.
- `{Terminal,Preview}MCP.handle/2` — pure handler entry, called by the controllers
  and exercised directly in tests.
- `MCPWorkspaceScope.{default_workspace_id, scoped_call_params, scoped_instructions,
  tool_specs, workspaces_compatible?}/*` — pre-scoped-endpoint plumbing.
- `MCPAudit.record_terminal/3`, `MCPAudit.record_preview/4` — audit hooks.

## Invariants & gotchas

- **Bearer token is the only access control.** `terminal_send_command` /
  `terminal_send_keys` inject into a live shell with no command allow-list beyond
  the `devide_` session guardrail and workspace scoping (see `../terminal_mcp.md`).
- **`devide_` session prefix is enforced** (`@session_prefix`); unscoped sessions
  return `:unscoped_session`, cross-workspace returns `:workspace_mismatch`.
- **Agent-pane shortcuts refuse the operator pane.** `terminal_send_agent_*` use
  `find_agent_pane/2` with `allow_process_fallback: false` — they require the
  `agent_pair` marker ("DevIDE agent pane" in scrollback) and never fall back to
  process detection, unlike `terminal_agent_pane` / `terminal_capture_agent`.
- **Pre-scoped endpoints inject `workspace_id`** and reject a *different* explicit
  value (`MCPWorkspaceScope.scoped_call_params/2`), but tolerate manager-UUID ↔
  folder-attached aliases via `WorkspaceAliases.linked?/2`. Scoped endpoints also
  drop `workspace_id` from each tool's `inputSchema.required`.
- **Mutating tools are audited;** `MCPAudit` lists the mutating sets explicitly
  (`mutating_terminal_tool?/1`, `mutating_preview_tool?/1`) — they emit `Audit.emit!`
  and surface in the workspace **Live MCP activity** feed. Read-only tools only
  record activity.
- **Preview session-scoped tools accept string or integer `session_id`**
  (`parse_id/1`); the workspace is resolved from `PreviewControl.Registry`, so an
  empty workspace is fine for them.
- **Browser refresh tools are best-effort broadcasts** (`preview_reload_iframe`,
  `devide_reload_page`) — they return once queued for connected viewers, not when
  every tab has reloaded.
- **`GET` on either MCP route returns 405** — POST/JSON-RPC only, no SSE.
- **Tidewave is dev-only and external** — never shipped in the prod release;
  DevIDE only resolves its URL.

## See also

- [`../terminal_mcp.md`](../terminal_mcp.md) — terminal MCP scoping, agent pairing, smoke tests
- [`../preview_mcp.md`](../preview_mcp.md) — preview MCP flow, control-plane layers, Playwright, storage profiles
- [`../terminal.md`](../terminal.md) — raw-terminal model behind the terminal tools
- [`../architecture.md`](../architecture.md) — system overview
- [`../glossary.md`](../glossary.md) — workspace / session / pane terminology
