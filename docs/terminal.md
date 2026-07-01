# Terminal subsystem

Terminal surface for workspace control. The workspace terminal is a durable
raw PTY backed by tmux and a server-side Ghostty cell grid. Raw-terminal
admission is a server-side policy decision (`Policy.can_use_raw_terminal?/1`).

> **History:** earlier versions had a second "governed" mode — a custom prompt
> UI that resolved submitted lines to safe actions and queued them as runner
> assignments. That governed-command plane and its runner assignment queue
> were removed. The terminal is raw-only.

## Architecture

Raw shell path:

```
Browser (Ghostty.LiveTerminal.Component + GhosttyTerminal JS hook)
   ↕  LiveView events (key / text / mouse / resize / ready)
DevIdeWeb.WorkspaceLive.Show
   ↕  Ghostty.Terminal.write/2  +  Ghostty.PTY.write/2
Ghostty.Terminal (libghostty-vt cell grid)
   ↕  {:data, binary} messages
Ghostty.PTY (forkpty)
   ↕
tmux new-session -A -s devide_<workspace>_<sid>
```

The tmux session is the persistence boundary. The `Ghostty.Terminal` and
`Ghostty.PTY` processes live for the LiveView socket; reconnecting any
browser tab reattaches to the same tmux session via `tmux new-session -A`
(attach if exists, else create), and replays scrollback via the new
`Ghostty.Terminal` from tmux's history.

Raw mode is admitted when `Policy.can_use_raw_terminal?/1` allows
`:raw_terminal`. By default raw shell requires a local host plus manual
workspace mode; `:raw_terminal_everywhere` is an explicit opt-in for allowing
raw shell in any workspace/mode/host. The verdict is recorded in the run ledger
as a session event (`run.session_attached` / `run.session_denied`).

`DevIdeWeb.TerminalChannel` serves raw channel attaches for shell and
`:execution` sessions (MCP-driven tmux attach); those payloads may include
`replay_frame` metadata on reconnect. The workspace UI renders raw PTY through
Ghostty LiveView panes.

## Agent prompt staging

`DevIDE.Terminals.send_agent_prompt/4` sends a prompt to a specific tmux pane in
small, line-preserving chunks via `paste_text/3`. It normalizes CRLF/bare-CR to
LF, preserves blank lines, caps chunks by line count and byte size, and applies
`submit: true` only to the final chunk. Chunks are shaped so sequential tmux
pastes reconstruct the normalized prompt exactly. Empty prompt text sends no
chunks and never presses Enter.

`DevIDE.Terminals.find_agent_pane/2` resolves only panes with persisted
`role: "agent"` metadata from the `agent_pair` template. If no role-marked pane
exists, the error tells the caller to apply `agent_pair` and includes candidate
pane metadata instead of falling back to the operator pane. The error also
includes machine-readable recovery fields: `suggested_template: "agent_pair"`,
`required_role: "agent"`, and `auto_apply_option: :auto_apply_agent_pair`.
Callers that do not already have a pane id can use
`send_agent_prompt_to_agent_pane/3`. Backend callers may pass
`auto_apply_agent_pair: true` to apply the built-in `agent_pair` template once
and retry; the default is still fail-closed so layout mutation is never
implicit.

Read-only clients can check `/api/workspaces/:id/status` before sending a
prompt. Its `agent_layout` field reports `no_sessions`, `ready`, or
`missing_agent_pane`, includes the same `agent_pair` recovery hint, and exposes
only safe pane ids/roles/command names rather than cwd or scrollback. The
workspace picker renders the same readiness as a compact session badge, so a
missing `agent_pair` layout is visible before an agent prompt is sent.

The helper also extracts a deterministic first-prompt title and redacts obvious
credential forms before using that title for names or activity. After a
successful send it stores that redacted title as the tmux session alias when the
alias is blank, and renames the containing generic agent window (`work`,
`agent`, `shell`, etc.) when the target pane is role-marked `agent`. Existing
aliases and human-named windows are kept. When `workspace_id:` is supplied, the
same title is also proposed as the pane's DevIDE chrome label unless a frozen
manual label already exists. Results include `:running` /
`:done` / `:attention` / `:noop` status values plus naming metadata and the line/byte
chunk caps used for the send. Workspace session summaries prefer the alias as
the visible session label and surface the latest prompt status when recent
activity identifies the same tmux session, so the picker shows useful agent
session names before opening the workspace.

When callers pass `workspace_id:`, the helper records a bounded `running`
audit/activity transition before a non-empty send starts, followed by a final
audit event (`terminal.agent_prompt_done`, `_attention`, or `_noop`) with the title,
title source, status, target session/pane, chunk counts, line/byte caps, naming
outcome, and a short normalized prompt excerpt. It also records matching terminal MCP
activity entries so existing activity subscribers receive the title source and
running/done/attention/noop status transitions. The actual terminal paste still receives
the original prompt; derived titles and excerpts are redacted before they are
stored or broadcast. Previous-session search indexes those events, so prompt
intent and status are searchable without loading full paste history into
LiveView.

## Auth

`DevIdeWeb.ChannelAuth` centralises the token salt (`"user socket"`,
24h max age). Show LiveView signs on mount; UserSocket verifies on connect.
When real auth lands, change one module.

## Bundle size

`mix assets.build` produces an ~1.5 MB `app.js`. The main contributors are
CodeMirror (file viewer) and the vendored `assets/vendor/ghostty.js` renderer
hook. If the bundle grows beyond ~2.5 MB, split via dynamic import on the
terminal hooks so the workspace index page doesn't pull the renderer in.

## Current state (Ghostty raw + multi-pane)

Raw terminals are powered by `Ghostty.LiveTerminal.Component` + `Ghostty.PTY`
(forkpty) with a dedicated `tmux new-session -A` per browser pane. The
`PaneLayout` module maintains a recursive split tree (`{:pane, id}` |
`{:split, dir, children, sizes}`) that is rendered with nested flex containers
and independent PTY workers (`PaneWorker`). Each pane owns its own tmux session
(derived name) so shells and processes are truly independent.

- Focus ring, floating split/close controls (⇥ ⤓ ×) on the focused pane only.
- Drag resizers (`SplitResizer` hook) with live DOM preview + server commit.
- Keyboard navigation (Ctrl+arrows), double-click to equalize, arrow nudges on resizer.
- Persistence via localStorage + defensive `restore_pane_layout` guard (only
  accepts layouts whose pane ids exactly match current live panes).
- "Focus mode" (Ctrl/Cmd+Shift+F or palette) collapses the workspace header +
  terminal utility bar for maximum vertical real estate; a thin reveal strip
  remains.
- Per-pane error states, snapshots ("snap all"), and equalize/reset.

**Remote hosts**: an SSH adapter behind a `DevIDE.Terminals.Adapter` behaviour
is the planned extension path. Raw-terminal admission stays a server-side
`Policy.can_use_raw_terminal?/1` decision regardless of transport.

## Multi-tab behaviour

`sid` is user-scoped (`"u-" <> user.id`), so opening the same workspace in
two tabs gives both tabs the **same** tmux session name. Both LiveViews
spawn their own `Ghostty.PTY`, both invoke `tmux new-session -A`, and both
attach to the same session. tmux multiplexes screen output to all attached
clients, so the two tabs mirror each other — typing in tab A appears in
tab B. No server-side dedup needed.

The one wrinkle is resize: tmux's default `aggressive-resize off` shrinks
the session to the **smallest** attached viewport. If tab A is full-screen
and tab B is tiny, tab A sees tab B's small dimensions. Accept this for
now; it's tmux behaviour, not ours.

## Terminal mode

Terminals are **raw everywhere**. The governed-command plane and the old
per-window mode toggle have been removed, so `DevIDE.Terminals.ModePolicy`
resolves every session — workspace shell, execution, or agent — to `:raw`, and
there is no per-window mode to remember, no badge, and no `?mode=raw` deep-link
param (a stray one from an old link is ignored).

`WindowTerminalMode` survives only as a thin active-window surface: when the
operator switches tmux windows it (re)starts the Ghostty pane for the new active
window, and it supplies `tmux_window_id` / `tmux_window_name` for audit metadata
and palette labels.

UI affordances:

- The raw indicator (`#terminal-mode-raw`) and the mobile key bar's `raw` chip
  are **static** — they show that the shell is raw, not a toggle. Tapping the
  mobile chip opens a session/window bottom sheet. Window cycle (‹ ›) and command
  palette (⌘) sit in the key bar — dropdown pickers are desktop-header only.
  First touch visit defaults to focus mode (header hidden); use the reveal strip
  to bring chrome back.
- The evidence drawer can filter audit events by tmux window name/id; raw
  session attaches include `tmux_window_id` / `tmux_window_name` in audit
  metadata.

## Idle GC

`DevIDE.Terminals.TmuxJanitor` is a singleton GenServer that tracks
LiveView subscribers per tmux session (keyed by session name, e.g.
`devide_alpha_u-<user>`). On mount the LiveView calls
`TmuxJanitor.subscribe/1`; the janitor monitors the socket pid. On `:DOWN`
or explicit `unsubscribe/1`, if no subscribers remain for that session, it
schedules `tmux kill-session -t <name>` after `:tmux_idle_seconds` (config,
default disabled in dev, `600` in prod). A new subscriber arriving cancels
the pending kill. Safety: only sessions whose name starts with `devide_`
are killed.

## Ghostty raw renderer

The raw shell is rendered by `Ghostty.LiveTerminal.Component` (from
`{:ghostty, "~> 0.4"}`), backed by a `Ghostty.PTY` (forkpty) running
`tmux new-session -A`. The LiveComponent pushes cell grids via
`ghostty:render` events; the JS hook (`assets/vendor/ghostty.js`) renders
them into a `<pre>` with styled spans. Why Ghostty for raw PTY:

- **Server-authoritative snapshots** via `Ghostty.Terminal.snapshot/2` (the
  Snapshot button captures HTML / plain / VT to `/tmp` and emits an audit
  event `ghostty.raw_terminal_snapshot`). Client-only renderers cannot do
  this — only the server knows the grid.
- **Query/response cycle** (`{:pty_write, data}` handler in the
  `Ghostty.Terminal`) so TUIs that use DSR, cursor reports, OSC queries
  etc. work correctly without the browser as the round-trip authority.
- **SIMD VT reflow** on resize is handled by libghostty-vt.
- **Same persistence**: tmux survives BEAM restarts; a new
  `Ghostty.Terminal` rebuilds the grid from tmux's history on reattach.

Wiring lives in `lib/dev_ide_web/live/workspace_live/show.ex`:
`@ghostty_term_id`, `start_ghostty_terminal/1`,
`handle_info({:terminal_ready, ...})` (lazily spawns the PTY using the
fitted cols/rows), `handle_info({:data, ...})` (forwards PTY output into
the terminal grid), `cleanup_ghostty_resources/1` (called on mode
transitions out of `:raw` and from `terminate/2`).

Disk writes for the Snapshot button live in
`lib/dev_ide/terminals/ghostty_snapshot.ex` — extracted from `show.ex` so
the LiveView source stays write-free for the `DevIDE.ProposalsNoApplyTest`
boundary guard.
