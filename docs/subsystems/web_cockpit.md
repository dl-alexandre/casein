# Web cockpit subsystem

> The Phoenix/LiveView tier that renders runtime truth into a browser cockpit and accepts viewer input — the browser drives a server-side PTY, it is never an argv source (FP-1).

This is a companion to the authoritative [`../architecture.md`](../architecture.md)
("Web Tier" in the subsystem map). When code and that doc diverge, the doc wins.

## Responsibility

`lib/casein_web/{live,components,channels,plugs}` own the **viewer surface** of
Casein: how a workspace's durable terminal, tmux topology, files, runs, audit,
and previews are presented to a browser, and how browser input is admitted and
relayed to server-side state. It owns no execution authority — input flows into
a server-side Ghostty/tmux PTY (FP-1), and capabilities/history are rendered from
what the server reports (FP-3). Identity for every request is established by the
plugs before any LiveView mounts.

The single large LiveView is `CaseinWeb.WorkspaceLive.Show` (the cockpit). It is
deliberately decomposed: socket state and orchestration live in `show.ex`, while
per-domain `handle_event` / render logic is delegated to ~20
`CaseinWeb.WorkspaceLive.Show.*` submodules.

## Module map

| Module | File | Role |
|---|---|---|
| `CaseinWeb.WorkspaceLive.Show` (`:root`) | `live/workspace_live/show.ex` | Landing page at `/`: scratch cockpit (home-rooted PTY). Admin actions are the header drawer; directory browse is the SESSIONS Browse tier. |
| `CaseinWeb.WorkspaceLive.PickerBadges` | `live/workspace_live/picker_badges.ex` | Shared presentation helpers for workspace rows: status colors, per-session agent badges, agent-layout badge. |
| `CaseinWeb.WorkspaceLive.Show` | `live/workspace_live/show.ex` | The cockpit LiveView. Mount + socket state, `authz_gate/3` fail-closed hook, render, orchestration of `PaneWorker`s and submodules. |
| `CaseinWeb.WorkspaceLive.PaneWorker` | `live/workspace_live/pane_worker.ex` | Per-pane GenServer owning a `Ghostty.Terminal` + backend; drains PTY output off the LV process and sends `{:pane_frame, pane_id, payload}`. |
| `CaseinWeb.DeploymentUpdateHook` | `live/deployment_update_hook.ex` | `on_mount` hook: subscribes to `deploy:updates`, tracks the connection for graceful drain. |
| `CaseinWeb.WorkspaceLive.Show.Context` | `live/workspace_live/show/context.ex` | Cross-cutting socket helpers (`host_path/1`, `policy_ctx`, gates) imported by the delegation modules. |
| `CaseinWeb.WorkspaceLive.Show.TerminalState` | `live/workspace_live/show/terminal_state.ex` | Terminal/tmux socket-state helpers: topology + session-tab subscriptions, pane data, header labels. |
| `CaseinWeb.WorkspaceLive.Show.TerminalEvents` | `live/workspace_live/show/terminal_events.ex` | `tmux:*` / `terminal:*` / `attach_terminal_session` event clauses. |
| `CaseinWeb.WorkspaceLive.Show.TerminalChrome` | `live/workspace_live/show/terminal_chrome.ex` | Raw-terminal surface + tmux pane-geometry render; pane/window/session presentation helpers. |
| `CaseinWeb.WorkspaceLive.Show.TerminalInfo` | `live/workspace_live/show/terminal_info.ex` | `handle_info` for `{:terminal_ready,...}` / `{:terminal_resize,...}` Ghostty dimension sync. |
| `CaseinWeb.WorkspaceLive.Show.SessionBar` | `live/workspace_live/show/session_bar.ex` | Session-tab + tmux window-bar markup (stable DOM ids); applies `mutations_allowed?` but decides no policy. |
| `CaseinWeb.WorkspaceLive.Show.SessionBarVM` | `live/workspace_live/show/session_bar_vm.ex` | Pure view-model builder mapping `Session.Info` → render-ready maps. |
| `CaseinWeb.WorkspaceLive.Show.WindowTerminalMode` | `live/workspace_live/show/window_terminal_mode.ex` | Active-window Ghostty surface + window-name helpers; terminals are raw-everywhere so mode is always `:raw`. |
| `CaseinWeb.WorkspaceLive.Show.ViewDeepLink` | `live/workspace_live/show/view_deep_link.ex` | Encodes/restores the `host/session/window/pane/zoom` view into the URL via `push_patch`. |
| `CaseinWeb.WorkspaceLive.Show.FileEvents` | `live/workspace_live/show/file_events.ex` | `tree:*` / `file:*` editor + file-tree event clauses (Policy `can_edit_file?`). |
| `CaseinWeb.WorkspaceLive.Show.SidePanels` | `live/workspace_live/show/side_panels.ex` | Files-tree, Search, Diff, Run side-panel render functions. |
| `CaseinWeb.WorkspaceLive.Show.RunPanel` | `live/workspace_live/show/run_panel.ex` | Run-detail panel render (timeline, artifacts, retry). |
| `CaseinWeb.WorkspaceLive.Show.RunEvents` | `live/workspace_live/show/run_events.ex` | `run:*` / `run_ledger:*` / `workflow:*` events; launches interactive agents into the raw terminal. |
| `CaseinWeb.WorkspaceLive.Show.PaletteItems` | `live/workspace_live/show/palette_items.ex` | Command-palette item catalog + fuzzy query. |
| `CaseinWeb.WorkspaceLive.Show.PaletteEvents` | `live/workspace_live/show/palette_events.ex` | `palette:*` events; `palette:execute` re-dispatches into `Show.handle_event/3`. |
| `CaseinWeb.WorkspaceLive.Show.TemplatePanels` | `live/workspace_live/show/template_panels.ex` | Session-template preview modal + library drawer render. |
| `CaseinWeb.WorkspaceLive.Show.AuditDrawer` | `live/workspace_live/show/audit_drawer.ex` | Audit/activity drawer render (streamed events). |
| `CaseinWeb.WorkspaceLive.Show.LogsPanel` | `live/workspace_live/show/logs_panel.ex` | Service-log tail panel render. |
| `CaseinWeb.WorkspaceLive.Show.UI` | `live/workspace_live/show/ui.ex` | Tiny presentation helpers (`tab_class`, `render_path`, `dom_fragment`). |
| `CaseinWeb.CoreComponents` | `components/core_components.ex` | Phoenix core UI components (tables, forms, inputs; Tailwind + daisyUI). |
| `CaseinWeb.GhosttyTerminalComponent` | `components/ghostty_terminal_component.ex` | LiveComponent wrapping `Ghostty.LiveTerminal.Component`; handles `key`/`text`/`mouse`/`ready`/`resize`/`focus`, pushes row-diff render frames. |
| `CaseinWeb.Layouts` | `components/layouts.ex` (+ `layouts/root.html.heex`) | App + root layout. |
| `CaseinWeb.UserSocket` | `channels/user_socket.ex` | Browser socket; verifies signed user token (`ChannelAuth.verify_user_token/1`), routes `terminal:*` to `TerminalChannel`. |
| `CaseinWeb.TerminalChannel` | `channels/terminal_channel.ex` | Per-session raw terminal stream `terminal:<workspace_id>:<sid>`; thin transport delegating to `Casein.Terminals.SessionOwner`. |
| `CaseinWeb.Plugs.ForwardAuth` | `plugs/forward_auth.ex` | `:browser` pipeline identity from trusted `X-Auth-Request-Email` header; stashes `current_user` in session, derives `:admin` role. |
| `CaseinWeb.Plugs.AssignCurrentUser` | `plugs/assign_current_user.ex` | Static single-user fallback identity + `from_session/1` reader for LV mounts. |
| `CaseinWeb.Plugs.ApiAuth` | `plugs/api_auth.ex` | Bearer-token gate for the read-only `/api` + MCP pipelines (503 if unconfigured). |
| `CaseinWeb.Plugs.McpRateLimit` | `plugs/mcp_rate_limit.ex` | Per-token rate limiter applied after `ApiAuth` on `:mcp_api`. |

## Data flow / lifecycle

**Request → identity.** The `:browser` pipeline (router) runs
`ForwardAuth` last: in forward-auth deployments it reads `X-Auth-Request-Email`,
builds `%{id, username, email, role}`, and `put_session("current_user", ...)`.
With forward-auth disabled it falls back to `AssignCurrentUser.current_user/0`.
LiveView mounts read identity via `AssignCurrentUser.from_session/1`.

**Mount (`Show.mount/3`).** Resolves `%{"id" => id}` + `host` param, gates
non-local hosts (`ensure_local_host/1` → `:cross_host_not_configured` flash), and
calls `Workspaces.get(id, user.email)` (the access boundary). It derives a
per-tab `sid` (`"u-<user.id>-<tab_id>"` from the `tab_id` connect param so each
browser tab gets an independent durable session), a `tmux_session` name, a
`workspace_capability` (`ChannelAuth.sign_terminal_capability` re-attach token),
and a `socket_token` (`ChannelAuth.sign_user_token`) for the channel. It assigns
the full socket state, subscribes (topology, session tabs, workspace mode,
previews, generic pane events (`Casein.Panes.Events` — preview and file pane
lifecycle since the preview runtime cutover), browser control, pane labels)
**only when `connected?`**, attaches the
`:authz_gate` hook, then `send(self(), :after_mount)` to defer PTY startup and
all heavy reads out of mount for fast first paint.

**Staged hydration.** `:after_mount` → `:after_mount_side_panels` →
`:after_mount_runs` chain; side panels and agents load via `start_async`. PTY
panes start in `:after_mount` via `maybe_start_raw_ghostty_and_request_restore`.
Client narration is **latency-classified** — see
[`../async-hydration-classification.md`](../async-hydration-classification.md)
(#732): fast paths stay silent; slow waits get a delayed (~200ms) specific label
via the `async-wait` CSS class / `UI.async_wait/1`.

**Terminal input/output (the FP-1 path).** Browser keystrokes reach a PTY by two
transports: (a) the LiveView `GhosttyTerminalComponent` (`key`/`text`/`mouse`
events → `Ghostty.PTY.write` / `Ghostty.LiveTerminal`), and (b) the
`TerminalChannel` (`handle_in("input"/"resize")` → `Terminals.owner_input/2` /
`owner_resize/3`). Both write into the **server-side** PTY owned by
`Casein.Terminals.SessionOwner`; the browser never submits argv. Output is
drained per-pane inside `PaneWorker`, which sends `{:pane_frame, pane_id,
payload}` to the LV; the LV forwards it to the browser with `push_event(...,
"ghostty:render", payload)`. The tmux session is the persistence boundary —
reconnecting a tab reattaches via `tmux new-session -A` and replays scrollback
(FP-9). `TerminalChannel.terminate/2` detaches the owner pid.

**Authorization.** `authz_gate/3` runs before every `handle_event` clause and
**halts** any event not in the `@known_events` allowlist (or the `tmux:` /
`terminal:` delegation prefixes), emitting a deny `Policy.Decision` to the audit
log. Genuinely sensitive actions funnel through `Casein.Policy` inside their
handlers (`can_edit_file?`, `can_run_command?`, `can_set_workspace_mode?`,
`can_start_review_agent?`); the table makes coverage structural — new handlers
fail closed until registered.

## Public surface

- `Show.handle_event/3` — central dispatch; submodules delegate back here
  (`PaletteEvents`, `FileEvents`, `RunEvents`, `TerminalEvents`).
- `Show.refresh_audit_stream/1`, `refresh_run_ledger/2`,
  `refresh_workspace_mode/1`, `assign_workspace_summaries/1`,
  `refresh_terminal_workspace_capability/1` — socket refreshers called by
  submodules and timers.
- `Show.start_ghostty_terminal/1`, `update_pane/3`, `get_pane_data/2`,
  `cleanup_ghostty_resources_if_leaving/1`, `launch_interactive_agent/2`,
  `interactive_agent?/1` — pane/agent helpers other Show.* modules call.
- `PaneWorker` (GenServer) — `start_link/1`; emits `{:pane_frame, ...}`,
  `{:pty_data, ...}`, `{:pty_exit, ...}` to its parent LV.
- `ForwardAuth.user_from_email/1`, `admins/0`, `admin?/1`, `enabled?/0` — identity
  helpers used by `Index`/`Show` and the plug.
- `AssignCurrentUser.from_session/1`, `current_user/0` — identity readers.
- `TerminalChannel.join/3` + `handle_in/3` — `"input"`/`"resize"` over a raw
  session; rejects input when not `:raw` (`raw_terminal_disabled`).
- `DeploymentUpdateHook.on_mount/4` — wired in `router.ex` `live_session :default`.

## Responsive rule: pointer vs width (issue #735)

**`pointer-coarse` decides hit targets, spacing, and gesture affordances; width
decides layout and information density.**

They are not interchangeable. A narrow desktop window with a mouse wants compact
layout and precise targets. A wide tablet or touchscreen laptop wants desktop
information density with roomy targets. Deriving touch chrome from width alone
(or layout from pointer alone) is wrong in both directions.

| Question | Mechanism | Examples |
|---|---|---|
| Layout / density | Width (`sm`/`max-sm`, `@media (max-width: …)`, `data-chrome-narrow`, `@container`) | Hide header window tabs, compact identity cluster, in-pane file strip, palette row meta |
| Hit targets / spacing / gestures | `pointer-coarse` / `(pointer: coarse)` | `min-h-11` controls, taller chrome-reveal strip, safe-area padding, swipe coach, overscroll lock |

Combined conditions are fine when the state is truly both (e.g. coarse **and**
narrow). Mobile key bar and nav sheet stay available on coarse pointers even at
desktop widths so touch affordances are not removed; they must not *replace*
desktop layout on a large coarse device.

TUI “click here” hotspots still need DECSET mouse mode plus a real click —
pointer-coarse handling on terminal surfaces is not only a CSS concern
(`ghostty_terminal.js`).

Sibling #736 owns tablet-range density; this rule only says which query to ask.

## Invariants & gotchas

- **FP-1: the browser is a viewer.** No event handler accepts argv. Input only
  ever writes into the server-side PTY via `SessionOwner`/`Ghostty.PTY`.
- **Fail-closed events.** Any `handle_event` not in `@known_events` (and not a
  `tmux:`/`terminal:` prefix) is denied + audited by `authz_gate/3`. Adding a
  handler without registering it makes the action silently unavailable.
- **No unconditional work in mount.** All PubSub subscribes are `connected?`-guarded;
  PTY startup and heavy reads are deferred to the `:after_mount*` chain and
  `assign_async`.
- **Per-tab sessions.** `sid` includes the `tab_id` connect param so multiple
  windows stay independent rather than converging on one shared tmux session.
- **PaneWorker draining is load-bearing.** `Ghostty.Terminal.write/2` /
  `render_state/1` are synchronous `GenServer.call`s; running them on the LV
  process let a noisy pane block the channel and trigger a client reload, so they
  run in the per-pane worker. Only finished frames cross to the LV.
- **ForwardAuth trust depends on the proxy.** The header is only trustworthy
  because the reverse proxy strips client copies and re-sets it; Casein must bind
  to localhost / the internal bridge. The `:browser` pipeline must not gain
  OPTIONS-routable endpoints (the Caddy matcher excludes OPTIONS +
  `/site.webmanifest`) — see the plug's SECURITY note.
- **`from_session` vs. ForwardAuth clobber.** ForwardAuth overwrites session
  `current_user` on every request, so tests can't set LV identity via
  `put_session`; set `Application.put_env(:casein, :current_user, ...)` instead.
- **Stable DOM ids.** `SessionBar` ids (`terminal-session-tabs-<ws>`,
  `active_sessions-<id>`, `tmux-window-<frag>`, ...) are a contract relied on by
  tests and the palette; `SessionBarVM.dom_id` preserves the historical
  `"active_sessions-<id>"` scheme.
- **Mode is raw-everywhere.** `WindowTerminalMode` keeps a stable API but there is
  no governed/raw toggle anymore; `set_mode/2` always (re)starts the Ghostty pane.
- **One inspector, no tab strip (#692).** The inspector region holds a single
  LiveView-owned viewport; opening another replaces it. Chrome is a header
  context strip (kind/title/close), not tabs. Returning to a previous inspector
  is a palette/surface action.
- **Inspector leader focus is `InspectorFocus.focus_target/1`.** When
  `inspector_focus_id` names a live slot, `C-b z` / `C-b x` / arrows act on
  socket state and never call tmux. Tmux active pane / `focused_pane_id` stay
  the terminal region's PTY under zoom. Browser DOM focus edits panel content
  only. Input-ownership ladder is unchanged: *global > leader > pane content*.
  Authoritative write-up: `CaseinWeb.WorkspaceLive.Show.InspectorFocus`.

## See also

- [`../architecture.md`](../architecture.md) — authoritative narrative; "Web Tier", trust boundaries, FP-1/3/8/9.
- [`../terminal.md`](../terminal.md) — the raw-PTY / Ghostty / tmux path this cockpit views.
- [`../product.md`](../product.md) — §9.1 connection picker, §11 hide-rather-than-mock.
- [`../deep_links.md`](../deep_links.md) — the `host/session/window/pane/zoom` URL view (`ViewDeepLink`).
- [`../glossary.md`](../glossary.md) — term definitions (workspace, session, sid).
