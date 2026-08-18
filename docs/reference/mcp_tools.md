# MCP Tools Reference

> The complete catalog of MCP (Model Context Protocol) tools an external coding agent can call against Casein: terminal control, preview control, artifact projects, workspace annotations, and the resolved-but-external Tidewave bridge.

This is a flat reference catalog. For narrative flow, scoping rules, and smoke
tests see [`../terminal_mcp.md`](../terminal_mcp.md) and
[`../preview_mcp.md`](../preview_mcp.md). Artifact storage and runtime
registration are covered by [`../subsystems/artifact_projects.md`](../subsystems/artifact_projects.md).
For the preview control plane internals
(`PreviewControl` → `PreviewCtl.Session` → adapters) see
[`../preview_mcp.md`](../preview_mcp.md).

## Responsibility

Expose a narrow, auditable, workspace-scoped tool surface so external agents
(Grok, Claude, Codex, opencode) can drive Casein the way a human would — tmux
panes, browser previews, and review annotations — over JSON-RPC 2.0, without
arbitrary shell or browser access. Each surface is one HTTP POST endpoint behind
the same bearer-token gate (`CaseinWeb.Plugs.ApiAuth`).

## Module map

| Module | File | Role |
|--------|------|------|
| `CaseinWeb.API.TerminalMCP` | `lib/casein_web/api/terminal_mcp.ex` | Pure JSON-RPC handler for the terminal surface; `initialize`/`tools/list`/`tools/call`/`ping` dispatch |
| `CaseinWeb.API.PreviewMCP` | `lib/casein_web/api/preview_mcp.ex` | Pure JSON-RPC handler for the preview surface; resolves/validates workspace per call |
| `CaseinWeb.API.ArtifactMCP` | `lib/casein_web/api/artifact_mcp.ex` | Pure JSON-RPC handler for the artifact-project surface; returns Preview MCP handoff args |
| `CaseinWeb.API.TerminalMCPController` | `lib/casein_web/controllers/api/terminal_mcp_controller.ex` | HTTP transport for terminal MCP; maps handler outcomes to status codes |
| `CaseinWeb.API.PreviewMCPController` | `lib/casein_web/controllers/api/preview_mcp_controller.ex` | HTTP transport for preview MCP |
| `CaseinWeb.API.ArtifactMCPController` | `lib/casein_web/controllers/api/artifact_mcp_controller.ex` | HTTP transport for artifact MCP |
| `Casein.Agents.TerminalTools` | `lib/casein/agents/terminal_tools.ex` | Tool definitions + `invoke/2` for all `terminal_*` tools |
| `Casein.Agents.PreviewTools` | `lib/casein/agents/preview_tools.ex` | Tool definitions + `invoke/3` for all `preview_*` / `casein_reload_page` tools |
| `Casein.Agents.ArtifactTools` | `lib/casein/agents/artifact_tools.ex` | Tool definitions + `invoke/2` for all `artifact_*` tools |
| `Casein.Agents.AnnotationTools` | `lib/casein/agents/annotation_tools.ex` | `annotation_*` tools (folded into the terminal surface) |
| `CaseinWeb.API.MCPWorkspaceScope` | `lib/casein_web/api/mcp_workspace_scope.ex` | Pre-scoped-endpoint workspace injection / mismatch enforcement / schema-`required` rewriting |
| `Casein.Agents.MCPAudit` | `lib/casein/agents/mcp_audit.ex` | Records activity feed + `Audit.emit!` for mutating tools |
| `Casein.Agents.MCPError` | `lib/casein/agents/mcp_error.ex` | Normalizes `{:error, reason}` into MCP `tool_result` content |
| `Casein.Agents.TerminalMCPCapability` | `lib/casein/agents/terminal_mcp_capability.ex` | Advertises terminal MCP URL + tool names in capability detection |
| `Casein.Agents.PreviewTools.MCPCapability` | `lib/casein/agents/preview_tools/mcp_capability.ex` | Advertises preview MCP URL + tool names |
| `Casein.Agents.ArtifactMCPCapability` | `lib/casein/agents/artifact_mcp_capability.ex` | Advertises artifact MCP URL + tool names |
| `Casein.Agents.TidewaveCapability` | `lib/casein/agents/tidewave_capability.ex` | Detects the dev-only Tidewave endpoint (URL only — Casein does not implement tidewave tools) |
| `Casein.Agents.TidewaveMCP` | `lib/casein/agents/tidewave_mcp.ex` | Resolves an external Tidewave MCP URL for agent client config materialization |
| `Casein.Agents.PreviewTools.BrowserControl` | `lib/casein/agents/preview_tools/browser_control.ex` | Backs `preview_reload_iframe` / `casein_reload_page` viewer broadcasts |
| `McpCtl.Tool` / `McpCtl.Params` | (in-repo `mcp_ctl` boundary) | `Tool.define/3`, `Tool.object/1,2`, shared param schemas used by every definition |

## Endpoints

| Surface | Method + Path | Auth | Handler → Tools |
|---------|---------------|------|------------------|
| Terminal MCP | `POST /api/terminals/mcp` | `Authorization: Bearer $CASEIN_API_TOKEN` | `TerminalMCP` → `TerminalTools` + `AnnotationTools` |
| Terminal MCP stream | `GET /api/terminals/mcp` | bearer + `Mcp-Session-Id` | Streamable HTTP SSE channel for a known MCP session |
| Terminal MCP session end | `DELETE /api/terminals/mcp` | bearer + `Mcp-Session-Id` | End a Streamable HTTP session |
| Preview MCP | `POST /api/preview/mcp` | bearer | `PreviewMCP` → `PreviewTools` |
| Preview MCP stream | `GET /api/preview/mcp` | bearer + `Mcp-Session-Id` | Streamable HTTP SSE channel for a known MCP session |
| Preview MCP session end | `DELETE /api/preview/mcp` | bearer + `Mcp-Session-Id` | End a Streamable HTTP session |
| Artifact MCP | `POST /api/artifacts/mcp` | bearer | `ArtifactMCP` → `ArtifactTools` |
| Artifact MCP stream | `GET /api/artifacts/mcp` | bearer + `Mcp-Session-Id` | Streamable HTTP SSE channel for a known MCP session |
| Artifact MCP session end | `DELETE /api/artifacts/mcp` | bearer + `Mcp-Session-Id` | End a Streamable HTTP session |
| Preview pane register | `POST /api/preview/panes`, `DELETE /api/preview/panes/:id` | bearer | `PreviewPaneController` — used by the `casein-preview` CLI, not an MCP tool |
| Tidewave (dev only) | external `…/tidewave/mcp` | per-server | NOT served by Casein; URL resolved by `TidewaveMCP` |

Routes defined in `lib/casein_web/router.ex` (`scope "/api", CaseinWeb.API`).
JSON-RPC: `protocolVersion` `2025-03-26`; `initialize` returns an
`Mcp-Session-Id` response header for Streamable HTTP clients; `tools/list`
returns `{name, description, inputSchema}`; `tools/call` returns
`{content: [text], structuredContent}`.

## Tool catalog — Terminal MCP (`POST /api/terminals/mcp`)

Implemented in `Casein.Agents.TerminalTools` (dispatch in `invoke/2`). Every
session-scoped tool is guarded to `casein_`-prefixed tmux sessions. `workspace_id`
is injected when the endpoint is pre-scoped (`?workspace_id=…`).

| Tool | Does | Key params (required\*) | Implementing fn |
|------|------|--------------------------|-----------------|
| `terminal_list_sessions` | List live Casein tmux sessions (name, attached, activity) | `workspace_id`, `contains` | `list_sessions/1` |
| `terminal_context` | Recommended session, agent pane safety, and exact next tool/arguments | `workspace_id`, `session` | `context/1` |
| `terminal_topology` | Windows/panes with geometry, running command, active marker | `session`\* , `workspace_id` | `topology/1` |
| `terminal_capture` | Capture a pane's scrollback (defaults active pane, full history) | `session`\*, `pane`, `lines`, `ansi` | `capture/1` |
| `terminal_agent_pane` | Find the `agent_pair` agent pane (marker, then process fallback) | `session`, `workspace_id` | `agent_pane/1` |
| `terminal_capture_agent` | Capture scrollback from the dedicated agent pane | `session`, `lines`, `ansi` | `capture_agent/1` |
| `terminal_send_agent_keys` | Send raw keys to the agent pane only (requires marker) | `keys`\*, `session` | `send_agent_keys/1` |
| `terminal_send_agent_command` | Type command + Enter into the agent pane (requires marker); confirms submit | `command`\*, `confirm`, `session` | `send_agent_command/1` |
| `terminal_paste_agent_text` | Paste literal/multiline text via tmux paste buffer; optional `pane` skips agent_pair; `submit` confirms Enter | `text`\*, `submit`, `confirm`, `pane`, `session` | `paste_agent_text/1` |
| `terminal_set_next_prompt` | Stage the one sticky operator message for an agent pane, delivered on its next state edge. Refuses `state_edges_unavailable` on hook-less runtimes (OpenCode) rather than parking forever | `workspace_id`\*, `text`\*, `deliver_when`, `coalesce_key`, `expires_in_seconds`, `session`, `pane` | `set_next_prompt/1` |
| `terminal_clear_next_prompt` | Retract the staged message (only when `coalesce_key` matches, if given) | `workspace_id`\*, `coalesce_key`, `session`, `pane` | `clear_next_prompt/1` |
| `terminal_get_next_prompt` | Read the staged message for a pane | `workspace_id`\*, `session`, `pane` | `get_next_prompt/1` |
| `terminal_send_keys` | Send raw keys to a pane, no trailing Enter (tmux key names) | `session`\*, `keys`\*, `pane` | `send_keys/1` |
| `terminal_send_command` | Type command + Enter into a targeted pane; confirms submit (one retry) | `session`\*, `command`\*, `pane`, `confirm` | `send_command/1` |
| `terminal_set_agent_label` | Set a Casein chrome label for an agent pane (`freeze` to pin). Fleet roles: `manager` / `worker` (see `docs/fleet-chrome.md`) | `workspace_id`\*, `label`\*, `session`, `pane` | `set_agent_label/1` |
| `terminal_report_worktree` | Register an agent-created Git worktree under the workspace; re-call at session end with `exit_status`/`handoff` | `workspace_id`\*, `worktree_path`\*, `branch`, `agent`, `runner_id`, `session_id`, `tmux_session_id`, `ensure_preview_started` (default false), `exit_status`, `handoff` | `report_worktree/1` |

### Annotation tools (folded into the terminal surface)

Implemented in `Casein.Agents.AnnotationTools`; appended to `TerminalTools.definitions/0`.

| Tool | Does | Key params (required\*) | Implementing fn |
|------|------|--------------------------|-----------------|
| `annotation_list` | List workspace annotations (read-only) | `workspace_id`\*, `limit`, `approval_state`, `file_path`, `session_id`, `pane_id` | `list/1` |
| `annotation_propose` | Propose an annotation for human review (defaults pending) | `workspace_id`\*, `content`\*, `author_type`\* (`human`/`agent_grok`/`agent_codex`/`agent_claude`), plus one anchor: `file_path`/`terminal_range`/`preview_id`/`linked_entities`; `visibility`, `metadata`, `actor_id` | `propose/1` |

## Tool catalog — Preview MCP (`POST /api/preview/mcp`)

Implemented in `Casein.Agents.PreviewTools` (dispatch in `invoke/3`). Workspace
tools listed in `PreviewMCP.@workspace_tools` resolve a workspace from
`workspace_id`/`workspace_path`; session tools resolve the workspace from the
runtime `PreviewControl.Registry` by `session_id`. Actions delegate to
`Casein.PreviewControl` and `Casein.PreviewPanes`.

| Tool | Does | Key params (required\*) | Implementing fn |
|------|------|--------------------------|-----------------|
| `preview_resolve_workspace` | Resolve a `workspace_id` from manager id or folder path | `workspace_id` / `workspace_path` / `path` / `cwd` | `resolve_workspace/1` |
| `preview_surfaces` | List discoverable surfaces (manager URLs, metadata + terminal-detected ports) | `workspace_id`\* | `surfaces/1` |
| `preview_open` | Preferred unified opener; `mode` selects app, localhost, or here | `workspace_id`\*, `mode`, `surface`, `port`, `tmux_session` | `open_unified/2` |
| `preview_open_current_workspace` | Open the pre-scoped workspace app preview; auto-navigate viewer on loopback | (workspace-scoped; no `workspace_id` arg) | `open_app_preview/2` |
| `preview_open_app` | Open the workspace app (or named `surface`) preview in a control session | `workspace_id`\*, `surface`, storage/header opts | `open_app_preview/2` |
| `preview_open_here` | Open the app surface beside the calling agent session | `workspace_id`\*, `tmux_session`\*, `surface` | `open_app_here/2` |
| `preview_ensure_server_here` | Ensure the runtime-owned preview server for the calling worktree session | `workspace_id`\*, `tmux_session` | `ensure_server_here/2` |
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
| `preview_record_start` | Start Playwright video recording for the control session | `session_id`\* | `record_start/1` |
| `preview_record_stop` | Stop recording, store the `.webm`, and show playback in the pane | `session_id`\* | `record_stop/1` |
| `preview_playback_open` | Open a saved `.webm` / `.mp4` recording artifact as looping playback in a fresh pane | `workspace_id`\*, `artifact_path`\*, `tmux_session`, `loop` | `playback_open/2` |
| `preview_close` | Close the control session, kill the preview pane, release browser | `session_id`\* | `close/1` |
| `preview_get_storage` | Return localStorage + sessionStorage for the origin | `session_id`\* | `get_storage/1` |
| `preview_clear_storage` | Clear cookies/localStorage/sessionStorage (updates saved profile) | `session_id`\* | `clear_storage/1` |
| `preview_report_errors` | Return console + network errors from the latest observation | `session_id`\* | `report_errors/1` |
| `preview_reload_iframe` | Best-effort: ask connected viewers to reload the active preview iframe | `workspace_id`\*, `actor_id`, `reason` | `reload_iframe/2` |
| `casein_reload_page` | Best-effort: ask connected viewers to reload the whole workspace page | `workspace_id`\*, `actor_id`, `reason` | `reload_page/2` |

Open tools also accept `new_control_session`, `isolation_key`, `storage_profile`
(`ephemeral`/`workspace`/`profile`), `storage_profile_name`, `default_headers`,
and `viewport` (see `tool_opts/2`, `split_opts/2`).
`preview_playback_open` accepts placement/viewport options too, but it always
splits a fresh pane for the supplied recording artifact instead of reusing a
live app-surface pane.

## Tool catalog — Artifact MCP (`POST /api/artifacts/mcp`)

Implemented in `Casein.Agents.ArtifactTools` (dispatch in `invoke/2`). Every
tool requires `workspace_id`; pre-scoped endpoints inject it and remove it from
the required schema. Project payloads include `preview_open_arguments` plus
`next_tool: "preview_open"` / `next_arguments` for handoff to Preview MCP.

| Tool | Does | Key params (required\*) | Backend call |
|------|------|--------------------------|--------------|
| `artifact_create` | Create a static/html artifact in an isolated Git worktree | `workspace_id`\*, `name`, `kind`, `prompt`, `files`, `base_ref`, `branch` | `ArtifactProjects.create/2` |
| `artifact_update` | Write generated files, append prompt history, and commit | `workspace_id`\*, `artifact_id`\*, `prompt`, `files` | `ArtifactProjects.update/2` after ownership check |
| `artifact_list` | List active artifact projects for the workspace | `workspace_id`\* | `ArtifactProjects.list/1` |
| `artifact_get` | Fetch one artifact project's metadata | `workspace_id`\*, `artifact_id`\* | `ArtifactProjects.get/1` |
| `artifact_serve` | Ensure the artifact preview server is starting/running | `workspace_id`\*, `artifact_id`\* | `ArtifactProjects.serve/1` after ownership check |
| `artifact_snapshot` | Create an explicit Git version-marker commit | `workspace_id`\*, `artifact_id`\*, `label`, `message` | `ArtifactProjects.snapshot/2` |

`files` accepts either `{relative_path: content}` or a list of file objects.
File objects may provide UTF-8/base64 `content`, or `source_path` for a
server-local file beneath the workspace checkout root recorded by Casein.
Agent scratch paths and artifact worktrees outside that checkout are rejected.
Destination paths are normalized by `ArtifactProjects` and cannot escape the
artifact worktree or target `.git`. Publish all HTML dependencies through
`artifact_create`/`artifact_update`; direct worktree copies are intentionally
absent from the durable generated-file allowlist.

## Tool catalog — Tidewave (dev only, external)

Casein does **not** implement or proxy Tidewave's tools. The Tidewave MCP server
is the third-party `:tidewave` dependency, compiled only in `MIX_ENV=dev`
(including ephemeral preview-env instances on ports 41000–41049). Casein's role
is discovery and client-config materialization:

- `Casein.Agents.TidewaveCapability.detect/0` reports the endpoint
  (`url <> "/tidewave"`, `details.mcp_url = url <> "/tidewave/mcp"`).
- `Casein.Agents.TidewaveMCP.resolve_url/2` resolves an MCP URL by precedence:
  `CASEIN_TIDEWAVE_MCP_URL` → self-hosted node → workspace metadata
  (`ports.tidewave`, fingerprinted ports) → latest running preview-env instance;
  `normalize_mcp_url/1` canonicalizes to the `…/tidewave/mcp` path.

Agents call Tidewave's own tools (e.g. `project_eval`, `execute_sql_query`,
`get_docs`) directly against that resolved URL; their schemas live in the
`tidewave` hex package, not this repo.

## Data flow / lifecycle

```text
Agent (JSON-RPC 2.0 over HTTPS)
  │  Authorization: Bearer $CASEIN_API_TOKEN
  ▼
{Terminal,Preview,Artifact}MCPController  ── ApiAuth plug; default_workspace_id from ?workspace_id= or :api_workspace_id
  ▼
{Terminal,Preview,Artifact}MCP.handle/2   ── route initialize | tools/list | tools/call | ping | notifications/*
  ▼  (tools/call)
MCPWorkspaceScope.scoped_call_params/2  ── inject pre-scoped workspace_id / reject mismatch
  ▼
{Terminal,Preview,Artifact}Tools.invoke   ── (Preview also resolves workspace; session tools via PreviewControl.Registry)
  ▼
MCPAudit.record_{terminal,preview,artifact}  ── Activity feed + Audit.emit! for mutating tools
  ▼
result(id, %{content: [text], structuredContent})   |   MCPError.tool_result/1
```

Handler outcomes (`{:reply, map}` → 200, `:noreply` → 202, `{:error, map}` → 400)
are mapped to HTTP status by the controllers.

## Public surface (called by other code)

- `TerminalTools.definitions/0`, `PreviewTools.definitions/0`, and
  `ArtifactTools.definitions/0` — the tool specs
  consumed by `tool_specs/0` in each handler and by capability advertisement
- `TerminalTools.invoke/2`, `PreviewTools.invoke/3`, `ArtifactTools.invoke/2`,
  `AnnotationTools.invoke/2` —
  tool dispatch entry points.
- `{Terminal,Preview,Artifact}MCP.handle/2` — pure handler entry, called by the controllers
  and exercised directly in tests.
- `MCPWorkspaceScope.{default_workspace_id, scoped_call_params, scoped_instructions,
  tool_specs, workspaces_compatible?}/*` — pre-scoped-endpoint plumbing.
- `MCPAudit.record_terminal/3`, `MCPAudit.record_preview/4`,
  `MCPAudit.record_artifact/4` — audit hooks.

## Invariants & gotchas

- **Bearer token is the only access control.** `terminal_send_command` /
  `terminal_send_keys` inject into a live shell with no command allow-list beyond
  the `casein_` session guardrail and workspace scoping (see `../terminal_mcp.md`).
- **`casein_` session prefix is enforced** (`@session_prefix`); unscoped sessions
  return `:unscoped_session`, cross-workspace returns `:workspace_mismatch`.
- **Agent-pane shortcuts refuse the operator pane.** `terminal_send_agent_*` use
  `find_agent_pane/2` with `allow_process_fallback: false` — they require the
  `agent_pair` marker ("Casein agent pane" in scrollback) and never fall back to
  process detection, unlike `terminal_agent_pane` / `terminal_capture_agent`.
- **Pre-scoped endpoints inject `workspace_id`** and reject a *different* explicit
  value (`MCPWorkspaceScope.scoped_call_params/2`), but tolerate manager-UUID ↔
  folder-attached aliases via `WorkspaceAliases.linked?/2`. Scoped endpoints also
  drop `workspace_id` from each tool's `inputSchema.required`.
- **Mutating tools are audited;** `MCPAudit` lists the mutating sets explicitly
  (`mutating_terminal_tool?/1`, `mutating_preview_tool?/1`,
  `mutating_artifact_tool?/1`) — they emit `Audit.emit!` and surface in the
  workspace **Live MCP activity** feed. Read-only tools only record activity.
- **Artifact mutations check ownership before writes.** `artifact_update`,
  `artifact_serve`, and `artifact_snapshot` load the project and reject
  cross-workspace ids before mutating.
- **Preview session-scoped tools accept string or integer `session_id`**
  (`parse_id/1`); the workspace is resolved from `PreviewControl.Registry`, so an
  empty workspace is fine for them.
- **Browser refresh tools are best-effort broadcasts** (`preview_reload_iframe`,
  `casein_reload_page`) — they return once queued for connected viewers, not when
  every tab has reloaded.
- **MCP streams are session-scoped.** `GET` and `DELETE` require an
  `Mcp-Session-Id`; missing ids return `missing_mcp_session_id`, unknown ids
  return `unknown_mcp_session`, and both surfaces keep POST usable for stateless
  JSON-RPC clients.
- **Tidewave is dev-only and external** — never shipped in the prod release;
  Casein only resolves its URL.

## See also

- [`../terminal_mcp.md`](../terminal_mcp.md) — terminal MCP scoping, agent pairing, smoke tests
- [`../preview_mcp.md`](../preview_mcp.md) — preview MCP flow, control-plane layers, Playwright, storage profiles
- [`../subsystems/artifact_projects.md`](../subsystems/artifact_projects.md) — artifact worktree/runtime backend
- [`../terminal.md`](../terminal.md) — raw-terminal model behind the terminal tools
- [`../architecture.md`](../architecture.md) — system overview
- [`../glossary.md`](../glossary.md) — workspace / session / pane terminology
