# HTTP & channel external surface

> The complete inventory of DevIDE's externally reachable HTTP routes and
> Phoenix channel topics: what each one is, which controller/action serves it,
> which pipeline authorizes it, and what it does.

This is a **reference**, not a narrative — for the architecture see
[`../architecture.md`](../architecture.md) (Event plane, Trust boundaries) and
for the deep-link URL grammar used by the cockpit UI see
[`../deep_links.md`](../deep_links.md).

## Responsibility

Translate browser, operator-tool, and external-agent traffic into DevIDE
context calls and back. Everything here is a thin transport layer:
controllers map domain results (`DevIDE.Export`, `DevIDE.Workspaces`,
`DevIDE.PreviewPanes`, `DevIDE.Deployment.*`, MCP tool modules) onto HTTP
status codes / JSON-RPC envelopes; the terminal channel maps socket frames
onto a `DevIDE.Terminals.SessionOwner`. No business logic lives in this tier.

## Module map

| Module | File | Role |
|---|---|---|
| `DevIdeWeb.Router` | `lib/dev_ide_web/router.ex` | Route table + the `:browser`, `:preview_proxy`, `:api`, `:mcp_api` pipelines and CSP |
| `DevIdeWeb.LegacyWorkspaceController` | `lib/dev_ide_web/controllers/legacy_workspace_controller.ex` | `GET /workspaces` redirects to `/` (the picker was absorbed by the dashboard) |
| `DevIdeWeb.PreviewArtifactController` | `lib/dev_ide_web/controllers/preview_artifact_controller.ex` | Serve preview snapshot PNGs (raw or iframe-wrapped) |
| `DevIdeWeb.PreviewProxyController` | `lib/dev_ide_web/controllers/preview_proxy_controller.ex` | Reverse-proxy a workspace loopback dev server into a preview iframe |
| `DevIdeWeb.API.WorkspaceController` | `lib/dev_ide_web/controllers/api/workspace_controller.ex` | Read-only workspace surface: list, status, topology, previous-session search, runs, proposals, audit |
| `DevIdeWeb.API.WorkspaceWindowController` | `lib/dev_ide_web/controllers/api/workspace_window_controller.ex` | tmux window mutations (create/select/rename/kill) |
| `DevIdeWeb.API.WorkspacePaneController` | `lib/dev_ide_web/controllers/api/workspace_pane_controller.ex` | tmux pane mutations (create/select/split/resize/kill) |
| `DevIdeWeb.API.WorkspaceTemplateController` | `lib/dev_ide_web/controllers/api/workspace_template_controller.ex` | Session-template list/export/save/apply/update/duplicate/delete |
| `DevIdeWeb.API.ArtifactProjectController` | `lib/dev_ide_web/controllers/api/artifact_project_controller.ex` | Workspace-scoped artifact restoration from retained Git state |
| `DevIdeWeb.API.WorkspaceAPI` | `lib/dev_ide_web/controllers/api/workspace_api.ex` | Shared helpers: params, topology snapshot/refresh, path safety, JSON errors |
| `DevIdeWeb.API.PreviewPaneController` | `lib/dev_ide_web/controllers/api/preview_pane_controller.ex` | Register/deregister `devide-preview` CLI panes |
| `DevIdeWeb.API.DeployStatusController` | `lib/dev_ide_web/api/deploy_status_controller.ex` | Deploy-handoff health probe |
| `DevIdeWeb.API.DrainController` | `lib/dev_ide_web/api/drain_controller.ex` | Start a graceful deployment drain |
| `DevIdeWeb.API.PreviewMCPController` | `lib/dev_ide_web/controllers/api/preview_mcp_controller.ex` | HTTP transport for the preview MCP server |
| `DevIdeWeb.API.PreviewMCP` | `lib/dev_ide_web/api/preview_mcp.ex` | Pure JSON-RPC handler exposing `DevIDE.Agents.PreviewTools` |
| `DevIdeWeb.API.TerminalMCPController` | `lib/dev_ide_web/controllers/api/terminal_mcp_controller.ex` | HTTP transport for the terminal MCP server |
| `DevIdeWeb.API.TerminalMCP` | `lib/dev_ide_web/api/terminal_mcp.ex` | Pure JSON-RPC handler exposing `DevIDE.Agents.TerminalTools` |
| `DevIdeWeb.API.ArtifactMCPController` | `lib/dev_ide_web/controllers/api/artifact_mcp_controller.ex` | HTTP transport for the artifact MCP server |
| `DevIdeWeb.API.ArtifactMCP` | `lib/dev_ide_web/api/artifact_mcp.ex` | Pure JSON-RPC handler exposing `DevIDE.Agents.ArtifactTools` |
| `DevIdeWeb.API.MCPWorkspaceScope` | `lib/dev_ide_web/api/mcp_workspace_scope.ex` | Pre-scoped-endpoint workspace injection/enforcement for MCP handlers |
| `DevIdeWeb.UserSocket` | `lib/dev_ide_web/channels/user_socket.ex` | Token-verified socket; routes `terminal:*` to the terminal channel |
| `DevIdeWeb.TerminalChannel` | `lib/dev_ide_web/channels/terminal_channel.ex` | Bidirectional terminal stream bridged to a `SessionOwner` |
| `DevIdeWeb.ErrorHTML` / `DevIdeWeb.ErrorJSON` | `lib/dev_ide_web/controllers/error_{html,json}.ex` | Status-message rendering for error responses |

## Pipelines (auth)

Defined in `DevIdeWeb.Router`. Auth plugs themselves live in
`lib/dev_ide_web/plugs/` (outside this subsystem) — referenced here for completeness.

| Pipeline | Plugs | Identity model |
|---|---|---|
| `:browser` | session, live-flash, CSP headers, `:protect_from_forgery`, `DevIdeWeb.Plugs.ForwardAuth` | Trusted `X-Auth-Request-Email` header from the reverse proxy (`ForwardAuth`); falls back to the static single-user `AssignCurrentUser` identity when forward-auth is disabled. Assigns `:current_user`. |
| `:preview_proxy` | session, `ForwardAuth` | Same identity as `:browser`, but **omits** the cockpit CSP / secure-browser headers so proxied app HTML runs under its own framing rules. |
| `:api` | `:accepts ["json"]`, `DevIdeWeb.Plugs.ApiAuth` | Bearer token (`:dev_ide, :api_token` / `DEV_IDE_API_TOKEN`, or per-workspace `workspace_api_tokens`). No token configured → **503** `api_token_not_configured`; bad token → 401; workspace-scoped token outside its workspace → 403. |
| `:mcp_api` | `:accepts ["json"]`, `ApiAuth`, `DevIdeWeb.Plugs.McpRateLimit` | Same bearer gate as `:api`, plus per-token (hashed) rate limiting (default 120 hits / 60 s → **429** `rate_limited` with `Retry-After`). |

The `/dev` LiveDashboard + Swoosh mailbox routes mount only when
`Application.compile_env(:dev_ide, :dev_routes)` is true (dev/test).

## HTTP route reference

### Cockpit UI — pipeline `:browser`

| Method | Path | Controller / LiveView · action | Purpose |
|---|---|---|---|
| LIVE | `/` | `WorkspaceLive.Show` · `:root` | Scratch cockpit: workspaceless home-rooted PTY (`__scratch__`); admin drawer + SESSIONS sidebar Browse tier replace the retired full-page dashboard |
| GET | `/workspaces` | `LegacyWorkspaceController` · `:index` | Redirect to `/` (picker absorbed by the dashboard) |
| LIVE | `/workspaces/:id` | `WorkspaceLive.Show` · `:show` | Workspace cockpit (terminal/preview). URL query grammar in [`../deep_links.md`](../deep_links.md) |
| GET | `/preview-artifacts/:workspace_id/:filename` | `PreviewArtifactController` · `:show` | Preview snapshot PNG; `?fit=preview` wraps it in a responsive HTML page |

### Preview reverse proxy — pipeline `:preview_proxy`

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| ANY | `/preview-proxy/:workspace_id/:port/*path` | `PreviewProxyController` · `:proxy` | Forward to `127.0.0.1:<port><path>` server-side, preserving method, cookies, headers, and body; strip frame-blocking response headers; inject `<base href>` and rewrite root-relative assets plus standard Phoenix socket endpoint literals for LiveView long-poll fallback. This is not a raw websocket tunnel. Authorizes via `Workspaces.viewer_terminal_owner?/2`; port validated by `DevIDE.Previews.Url.port_allowed?/2`. Returns 403/400/404, or 502 "nothing listening" page when upstream is down |

### Read-only workspace API — pipeline `:api`

All under `scope "/api", DevIdeWeb.API`. `:id` is a workspace id (manager UUID
or `folder:<base64url-path>`). Unknown workspace → 404 `not_found`.

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| GET | `/api/workspaces` | `WorkspaceController` · `:index` | `Export.list_summary/0` |
| GET | `/api/workspaces/:id/status` | `WorkspaceController` · `:status` | `Export.status/1` snapshot |
| GET | `/api/workspaces/:id/topology` | `WorkspaceController` · `:topology` | tmux topology for `?session=` (or `?tmux_session=`); 422 `session_required` if absent |
| GET | `/api/workspaces/:id/runs` | `WorkspaceController` · `:runs` | Run-ledger history |
| GET | `/api/workspaces/:id/runs/:run_id` | `WorkspaceController` · `:run` | Single run detail |
| GET | `/api/workspaces/:id/proposals` | `WorkspaceController` · `:proposals` | Proposals list |
| GET | `/api/workspaces/:id/audit` | `WorkspaceController` · `:audit` | Audit-event export |
| GET | `/api/workspaces/:id/previous_sessions` | `WorkspaceController` · `:previous_sessions` | Bounded search over recent session metadata, audit, MCP activity, and pane labels. Query params: `query`/`q`, `workspace`/`workspace_id`/`workspace_name`, `source`/`sources` (`session`, `audit`, `activity`, `label`, or `preview`), `session`/`session_id`, `pane`/`pane_id`, `since`/`from`, `until`/`to`, `limit` (clamped at 50), `source_limit` (audit/activity scan cap, clamped at 1000) |

`status` includes a compact `agent_sessions` list derived from current tmux
session summaries and recent prompt activity. Entries expose only safe summary
fields (`id`, `label`, `title`, `status`, `tmux_session`, `pane`, `href`,
`preview_pane_ids`) so clients can render first-prompt titles and
running/done/attention/noop state without loading history or scrollback.

`status.agent_layout` reports whether the current tmux sessions include a pane
with persisted `role: "agent"` metadata. It has `status` (`no_sessions`,
`ready`, or `missing_agent_pane`), `ready`, `required_role`,
`suggested_template: "agent_pair"`, `auto_apply_option:
"auto_apply_agent_pair"`, `sessions_checked`, safe `agent_panes`, and safe
`candidate_sessions`/`candidate_panes` summaries. Pane summaries intentionally
omit cwd/path fields, so clients can decide whether to apply `agent_pair`
without fetching topology or terminal scrollback.

`previous_sessions` returns JSON-safe summaries, not scrollback or raw paste
blobs. Each result includes `source`, `title`, `summary`, normalized `status`
when known, `session`, `pane`, `occurred_at`, `matched_fields`, an `href` back
to the workspace view, and sanitized metadata. Free-text `query` matches titles,
summaries, status, session/pane ids, occurrence timestamps, preview summaries,
and bounded metadata. Session rows promote the session status; prompt
audit/activity rows promote `running` / `done` / `attention` / `noop` / `error`
style status values so clients do not have to parse metadata to render badges.
The optional `workspace` filter narrows the already scoped search to the route
workspace id, public workspace name, or safe workspace metadata on the row; it
does not broaden access to other workspaces. The optional `source` filter
narrows result types; `source=preview` matches audit/activity rows that carry
browser/preview context rather than a separate persisted source. `source_limit`
only bounds how many recent audit/activity rows are scanned before filtering;
it does not raise the returned `limit`. Preview
MCP audit/activity rows also include a normalized `preview` summary when
available (`agent_action`, `agent_session`, `agent_pane`, `tool`, `session_id`,
`pane`, `title`, `status`, `url`, `source_url`, `display_url`,
`screenshot_url`, `artifact_url`, `recording_id`, `recording_url`,
`recording_path`, `recording_status`, `path`, `port`, `surface`, `mode`) so
clients can link browser actions back to the agent action, session, and
app/browser state involved without loading screenshots or recordings inline.

### tmux template API — pipeline `:api`

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| GET | `/api/workspaces/:id/templates` | `WorkspaceTemplateController` · `:templates` | List built-in + saved templates (optional `?tag=`/`?tags=` filter) |
| GET | `/api/workspaces/:id/templates/export` | `…` · `:export_template` | Preview a template exported from the current topology (YAML) |
| POST | `/api/workspaces/:id/templates/export` | `…` · `:save_template` | Save exported template (201; `?dry_run=1` previews); `tmux.template_exported` audit |
| PATCH | `/api/workspaces/:id/templates/:template_id` | `…` · `:update_template` | Rename / re-describe / re-tag; `tmux.template_updated` audit |
| POST | `/api/workspaces/:id/templates/:template_id/duplicate` | `…` · `:duplicate_template` | Copy a saved template; `tmux.template_duplicated` audit |
| POST | `/api/workspaces/:id/templates/:template_id/apply` | `…` · `:apply_template` | Apply a template; `?dry_run=1` and `?reconcile=1` modes; `tmux.template_applied` audit |
| DELETE | `/api/workspaces/:id/templates/:template_id` | `…` · `:delete_template` | Delete a saved template; `tmux.template_deleted` audit |

### tmux window/pane mutation API — pipeline `:api`

All require `?session=`. Each mutation refreshes topology, emits a
`tmux.window_*` / `tmux.pane_*` audit event, and returns the post-mutation
topology. `?dry_run=1` returns the action + current topology without mutating.

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| POST | `/api/workspaces/:id/windows` | `WorkspaceWindowController` · `:create_window` | New window (`name`, `cwd` opts) |
| POST | `/api/workspaces/:id/windows/:window_id/select` | `…` · `:select_window` | Select window |
| PATCH | `/api/workspaces/:id/windows/:window_id` | `…` · `:rename_window` | Rename (`name` required) |
| DELETE | `/api/workspaces/:id/windows/:window_id` | `…` · `:kill_window` | Kill window |
| POST | `/api/workspaces/:id/panes` | `WorkspacePaneController` · `:create_pane` | Split a target pane (`pane_id`/`target_pane_id`, `direction` `h`/`v`) |
| POST | `/api/workspaces/:id/panes/:pane_id/select` | `…` · `:select_pane` | Select pane |
| POST | `/api/workspaces/:id/panes/:pane_id/split` | `…` · `:split_pane` | Split pane (`direction` `h`/`v`) |
| POST | `/api/workspaces/:id/panes/:pane_id/resize` | `…` · `:resize_pane` | Resize (`direction` left/right/up/down, `amount`) |
| DELETE | `/api/workspaces/:id/panes/:pane_id` | `…` · `:kill_pane` | Kill pane |

### Artifact lifecycle mutation API — pipeline `:api`

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| POST | `/api/workspaces/:workspace_id/artifacts/:artifact_id/restore` | `ArtifactProjectController` · `:restore` | Restore an expired artifact in place or recreate a cleaned worktree from its retained local branch; 404 for unknown/cross-workspace ids, 409 for non-restorable retained state |

### Preview-pane registry — pipeline `:api`

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| POST | `/api/preview/panes` | `PreviewPaneController` · `:create` | Register a `devide-preview` CLI pane (201); 422 on `workspace_not_found` / `untrusted_url` |
| DELETE | `/api/preview/panes/:id` | `PreviewPaneController` · `:delete` | Deregister a pane; 404 if unknown |

### Deploy control — pipeline `:api`

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| GET | `/api/deploy_status` | `DeployStatusController` · `:show` | `DevIDE.Deployment.Health.status/1`; 200 when `ok`, else **503** |
| POST | `/api/drain` | `DrainController` · `:drain` | `DevIDE.Deployment.Drain.start_drain/1` (`commits_behind` arg); 409 `already_draining` if already draining |
| POST | `/api/deploy_webhook` | `DeployWebhookController` · `:github` | GitHub push webhook (`X-Hub-Signature-256` + `X-GitHub-Event`); starts `devide-deploy.service` on `master` pushes; **503** when `DEVIDE_DEPLOY_WEBHOOK_SECRET` unset; must bypass Caddy `forward_auth` |

### Agent MCP — pipeline `:mcp_api`

JSON-RPC 2.0 over POST, with MCP Streamable HTTP layered on top. `initialize`
returns an `Mcp-Session-Id` response header; clients can send that header on
`GET` to open a server-sent-events stream, or on `DELETE` to tear the session
down. A missing session id on `GET`/`DELETE` returns **400**
`missing_mcp_session_id`; an unknown id returns **404**
`unknown_mcp_session`. Streamable transport errors keep the legacy top-level
`error` string and also include `code`, `message`, and
`error_version: "mcp-streamable-http-v1"` so clients can branch on a versioned
shape. POST bodies over `:mcp_max_body_bytes`
(`DEV_IDE_MCP_MAX_BODY_BYTES`, default `1_000_000`) return **413**
`request_body_too_large` before JSON-RPC handling with the same
`error_version`. `?workspace_id=` pre-scopes the endpoint:
`MCPWorkspaceScope` injects it into omitted `tools/call` args and rejects calls
naming a different, non-linked workspace (`workspace_scope_mismatch`).
MCP `tools/call` execution rejects global API tokens with **403**
`workspace_scoped_token_required`; use a workspace-scoped token so agent
terminal and preview actions stay bound to one workspace.
The artifact MCP endpoint follows the same auth, streamable-session, and
workspace-scoping rules.

| Method | Path | Controller · action | Purpose |
|---|---|---|---|
| POST | `/api/preview/mcp` | `PreviewMCPController` · `:rpc` | Drive `DevIDE.Agents.PreviewTools` (surfaces/open/observe/click/screenshot/…) via `PreviewMCP.handle/2` |
| GET | `/api/preview/mcp` | `PreviewMCPController` · `:info` | Streamable HTTP SSE channel for a known `Mcp-Session-Id` |
| DELETE | `/api/preview/mcp` | `PreviewMCPController` · `:delete` | End a streamable MCP session |
| POST | `/api/terminals/mcp` | `TerminalMCPController` · `:rpc` | Drive `DevIDE.Agents.TerminalTools` (list sessions, topology, capture, send keys/command) via `TerminalMCP.handle/2` |
| GET | `/api/terminals/mcp` | `TerminalMCPController` · `:info` | Streamable HTTP SSE channel for a known `Mcp-Session-Id` |
| DELETE | `/api/terminals/mcp` | `TerminalMCPController` · `:delete` | End a streamable MCP session |
| POST | `/api/artifacts/mcp` | `ArtifactMCPController` · `:rpc` | Drive `DevIDE.Agents.ArtifactTools` (create/update/list/get/serve/snapshot artifact worktrees) via `ArtifactMCP.handle/2` |
| GET | `/api/artifacts/mcp` | `ArtifactMCPController` · `:info` | Streamable HTTP SSE channel for a known `Mcp-Session-Id` |
| DELETE | `/api/artifacts/mcp` | `ArtifactMCPController` · `:delete` | End a streamable MCP session |

MCP methods handled by all `*MCP` modules: `initialize`, `ping`,
`tools/list`, `tools/call`; `notifications/*` → 202 no-body. Every
`tools/call` is recorded via `DevIDE.Agents.MCPAudit`. Invalid JSON-RPC
objects return **400** with error code `-32600`; unknown methods return **400**
with error code `-32601`. Contract tests also assert these transport errors and
oversized-body rejections do not echo request secrets or workspace paths into
responses or logs.

### Dev-only routes (`:dev_routes`)

| Method | Path | Purpose |
|---|---|---|
| LIVE | `/dev/dashboard` | Phoenix LiveDashboard (`DevIdeWeb.Telemetry`) |
| FWD | `/dev/mailbox` | Swoosh mailbox preview |

## Channel reference

Socket mounted at `/socket` (`DevIdeWeb.UserSocket`, in `endpoint.ex`).
Connect requires `params["token"]`, verified by
`DevIdeWeb.ChannelAuth.verify_user_token/1`; assigns `:current_user`
(`role: :owner`). Socket id `users_socket:<user_id>`.

| Topic | Channel · handler | Purpose |
|---|---|---|
| `terminal:<workspace_id>:<sid>` | `TerminalChannel` · `join/3` | Attach a viewer to a logical session (shell or agent/exec stream) |

`<workspace_id>` may itself contain `:` (e.g. `folder:<base64>`); the join
splits from the right so the last segment is always the session `sid`.

| Direction | Event | Payload | Behavior |
|---|---|---|---|
| in | `input` | `%{"data" => binary}` | Write to PTY via `Terminals.owner_input/2` (raw mode only; otherwise `raw_terminal_disabled`) |
| in | `resize` | `%{"cols" => int, "rows" => int}` | `Terminals.owner_resize/3` |
| out | `data` | terminal bytes | Forwarded from the `SessionOwner` (`{:terminal_payload, :data, _}`) |
| out | `exit` | `%{reason: string}` | Session ended; channel stops |

Reply on join is the `SessionOwner` attach payload (scrollback replay etc.).

## Data flow / lifecycle

- **API mutation** → `Export.status/1` existence check → `topology_session/1`
  parses `?session=` → adapter call (`tmux_adapter/0`) →
  `refreshed_topology_payload/2` (`TmuxTopology.configure` + `refresh` +
  snapshot) → `Audit.emit!` → JSON `%{action, dry_run, result, topology}`.
  Helpers shared via `import DevIdeWeb.API.WorkspaceAPI`.
- **MCP call** → `*Controller.rpc` fetches query params, calls the pure
  `*MCP.handle/2` with `default_workspace_id` from `?workspace_id=` or the
  workspace-scoped token (`conn.assigns[:api_workspace_id]`) → `{:reply,…}`
  → 200 / `:noreply` → 202 / `{:error,…}` → 400.
- **Terminal channel** → `join` resolves workspace context (capability-token
  fast path with an ETS + socket-assign claim cache, else
  `Workspaces.get/2`) → `Terminals.resolve/1` → `attachment_policy/2` →
  `attach_owner_mode/4` (shell joins pass `Boundary.authorize_raw/2` +
  `viewer_terminal_owner?`; agent/exec sessions attach read-only). On
  terminate, `Terminals.owner_detach/2`.

## Public surface (what other code calls)

- `DevIdeWeb.API.WorkspaceAPI` — `not_found/1`, `rejected/3`,
  `topology_session/1`, `topology_payload/2`, `refreshed_topology_payload/2`,
  `resolve_workspace_path/2`, `workspace_root/1`, `tmux_adapter/0`,
  `dry_run?/1`, `reconcile?/1`, param coercers. Imported by all four workspace
  API controllers.
- `DevIdeWeb.API.PreviewMCP.handle/2`, `DevIdeWeb.API.TerminalMCP.handle/2`,
  and `DevIdeWeb.API.ArtifactMCP.handle/2`
  — pure JSON-RPC entry points; both expose `tool_specs/0`.
- `DevIdeWeb.API.MCPWorkspaceScope` — `default_workspace_id/1`,
  `inject_default_workspace/2`, `scoped_call_params/2`,
  `workspaces_compatible?/2`, `tool_specs/2`, `scoped_instructions/2`.
- `DevIdeWeb.UserSocket` / `DevIdeWeb.TerminalChannel` — driven by Phoenix
  from the `/socket` mount; not called directly by app code.

## Invariants & gotchas

- **The API refuses all traffic with 503 until a bearer token is configured**
  (`ApiAuth`) — there is no open-by-default mode. Workspace-scoped tokens only
  work on their own `/api/workspaces/:id/*` path or an MCP endpoint scoped to a
  compatible `?workspace_id=`.
- **`ForwardAuth` trust depends on the reverse proxy** overwriting
  `X-Auth-Request-Email` on every authenticated request. DevIDE must bind to
  localhost/the internal bridge; the router defines **no OPTIONS routes**, which
  is load-bearing for the Caddy matcher exclusions (see the `ForwardAuth`
  moduledoc).
- **`:preview_proxy` deliberately omits the cockpit CSP** and re-serves
  arbitrary loopback HTML under the proxied app's own authority — it is not a
  general forward proxy: host is hard-pinned to `127.0.0.1` and the port must
  pass `Url.port_allowed?/2` plus the owner authorization gate.
- **MCP GET/DELETE are streamable-session operations.** They require
  `Mcp-Session-Id`; POST still works statelessly unless a session header is
  supplied, in which case unknown ids are rejected. Missing/unknown session
  errors are versioned with `error_version: "mcp-streamable-http-v1"` while
  preserving the compact `error` string. Unknown-session responses echo only
  safe generated-id shaped values; unsafe header values are redacted so an
  accidental token or path in `Mcp-Session-Id` does not come back in the
  response or logs. `?workspace_id=` makes an endpoint pre-scoped: agents may
  omit `workspace_id` (it is injected) but may not override it with an
  unrelated workspace.
- **Every mutating window/pane/template endpoint emits an audit event and
  returns post-mutation topology**; `?dry_run=1` short-circuits before the
  mutation and (for windows/panes) before the audit emit.
- **Terminal channel `input`/`resize` are no-ops outside raw mode**; agent/exec
  sessions attach read-only. The CSP `script-src` carries a sha256 hash of the
  single inline theme-bootstrap script — editing that script requires
  recomputing the hash (recipe in `router.ex`).
- The terminal channel's capability fast-path keeps a 60 s claim cache in both
  a named ETS table (`:dev_ide_terminal_fast_path_cache`) and socket assigns;
  cache misses fall back to `Workspaces.get/2` + `Boundary.authorize_raw/2`.

## See also

- [`../architecture.md`](../architecture.md) — Trust boundaries, Authority map, Event plane, Configuration keys
- [`../deep_links.md`](../deep_links.md) — `/workspaces/:id` URL query grammar and restoration
- [`../terminal.md`](../terminal.md) — terminal substrate the channel bridges to
- [`../terminal_mcp.md`](../terminal_mcp.md) — terminal MCP tool surface (`TerminalTools`)
- [`../preview_mcp.md`](../preview_mcp.md) — preview MCP tool surface (`PreviewTools`)
- [`../tmux_control_plane.md`](../tmux_control_plane.md) — topology/template control plane behind the window/pane/template API
- [`../subsystems/policy_deploy_export.md`](../subsystems/policy_deploy_export.md) — authoritative doc for the `/api/drain` + `/api/deploy_status` deploy/export surface
