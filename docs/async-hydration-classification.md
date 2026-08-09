# Async hydration classification

Issue #732. Decide per async site whether the client should narrate a wait.
**Fast paths stay silent.** A spinner on a ~40–50ms load is worse than silence —
it flashes and reads as jank. Only slow/unbounded waits get a delayed label.

Delay threshold for slow-path affordances: **~200ms** (CSS `async-wait`, not
immediate-on-mount). Failures are owned by #731 — do not invent parallel error UI.

## Rule of thumb for new sites

| Expected latency | Treatment |
|---|---|
| In-memory / local ETS / already-cached, roughly **&lt;200ms** | **Fast** — show nothing |
| Filesystem walk, `git`, tmux fan-out, remote, ripgrep, PTY/scrollback | **Slow** — delayed specific label |
| Error / empty after settle | **#731** |

## Inventory (`handle_async` + related waits)

There are **12** distinct `start_async` names on the cockpit (29 `handle_async`
clauses counting ok/error pairs) plus related non-`handle_async` waits called out
below. The two `assign_async` mentions in `show.ex` are comments only — the cockpit
uses `start_async` + plain assigns.

| Site | Waits on | Expected latency | Class | Affordance |
|---|---|---|---|---|
| `:after_mount_hydration` | tmux ensure_session, session tabs, topology snapshot, previews list, workspace summaries (git×N), saved templates | Often 50–300ms; summaries can be multi-second on large fleets | **Slow** (background) | **None on first paint** — terminal chrome is primary; rail paints from cache. Do not flash a shell-wide spinner. |
| `:load_side_panels` | `git status --short` + root tree list | Git: tens–hundreds of ms (commented as such); tree: FS list | **Slow** | Delayed **"Reading the file tree…"** while root not hydrated; delayed **"Querying git…"** on Diff while status not ready |
| `:agents_mount` | DB isolation detect + Elixir project/tooling meta | Usually &lt;200ms local; can spike on remote/disk | **Fast** (default) | **None** — Agents chrome is not the first paint; silence is fine |
| `:load_preview_state` | `discover_surfaces` + feature pane snapshot | Surface scan can be 100–500ms | **Slow** (background) | **None** unless a preview holder is empty and waiting — existing "Preview is still loading" path only |
| `:refresh_git_status` | `git status --short` off LV process | Tens–hundreds of ms; large repos higher | **Slow** | Delayed **"Querying git…"** on Diff panel while refresh in flight |
| `:workspace_summaries` | Per-workspace git branch/status + session directory | Unbounded with workspace count | **Slow** (background) | **None** until rail open; open rail uses session-row loading below |
| `:sidebar_session_tabs` | SessionDirectory refresh (slow path, caller used to block open) | Can exceed 200ms | **Slow** | Rail already painted from cache; **no extra flash** on refresh |
| `:sidebar_tmux_topology` | tmux topology refresh | Usually fast; can stall on busy server | **Fast–slow** | **None** — windows rail keeps last topology |
| `{:sidebar_ws_sessions, id}` | SessionDirectory.read for one expanded workspace | 50–300ms typical | **Slow** | Delayed **"Loading sessions…"** when expanded and empty (existing row; delay-gated) |
| `{:sidebar_ws_warm, batch}` | Batched SessionDirectory reads | Background warm | **Slow** (background) | **None** — warm must not flash chrome |
| `:run_search` | `rg` over workspace | Unbounded (timeout path exists) | **Slow** | Delayed **"Searching the workspace…"** while `:running` |
| `:saved_session_templates` | DB template list | Fast local DB | **Fast** | **None** |

### Related waits (not `handle_async`, still classified)

| Site | Waits on | Class | Affordance |
|---|---|---|---|
| **Terminal pane start** (PTY + Ghostty + tmux attach / scrollback replay) | Unbounded; highly visible | **Slow** | Delayed **"Starting terminal…"** (was immediate plain text — delay so fast attach does not flash) |
| **Pane scrollback drawer** (`PaneHistoryWorker`) | tmux capture, up to large scrollback | **Slow** | Delayed **"Loading scrollback…"** |
| **History tab** (`history_loaded?`) | Export previous-sessions search | **Slow** on first open | Delayed **"Loading previous sessions…"** (static disconnected paint) |
| **Desktop PowerShell connect** | Native session start | **Slow** | Delayed **"Starting native PowerShell…"** |
| Notifications drawer open | Inbox fetch | Out of scope / existing | Leave as-is this issue |

## Explicit non-goals

- No uniform skeleton system.
- No immediate-on-mount spinners.
- Do not restructure `:after_mount` timing.
- Failure presentation → #731.
- New-window 30–50ms path is **not** a server hydration bug; do not add narration there.

## Coordination

- #731 owns empty / degraded / error copy once a wait settles.
- Sibling cockpit tracks own other chrome; keep shared-file diffs minimal.
