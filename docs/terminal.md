# Terminal subsystem

Terminal surface for workspace control. The default mode is governed:
xterm.js behaves as a command entry cockpit, and submitted lines resolve to
safe actions before they enter the runner assignment queue. Raw PTY mode is
separate and available only for explicit local/manual workspaces.

## Architecture

Governed command path:

```
Browser (xterm.js line editor)
   ↕  Phoenix Channel  (terminal:<workspace_id>:<sid>, mode=governed)
DevIdeWeb.TerminalChannel
   ↕
DevIDE.Terminals.Boundary
   ↕
Policy + DevIDE.Runs.Ledger + Runners.enqueue_command/3
   ↕
Runner assignment lease/replay protocol
```

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

Raw mode is admitted only when policy allows `:raw_terminal`: local host and
manual workspace mode. Governed mode does not start a PTY. It parses a line
like `mix test`, resolves it to an allowlisted command id, and queues
`command:<id>` through `DevIDE.Runners`. Unrecognized lines are refused and
audited in the run ledger as `run.command_denied`.

Governed mode still uses xterm.js (line-editor cockpit) via
`assets/js/terminal_hook.js` and `DevIdeWeb.TerminalChannel`. The same
`TerminalChannel` also serves attached fleet execution sessions (read-only
tmux attach) — those continue to render in xterm.js.

## Auth

`DevIdeWeb.ChannelAuth` centralises the token salt (`"user socket"`,
24h max age). Show LiveView signs on mount; UserSocket verifies on connect.
When real auth lands, change one module.

## Bundle size

`mix assets.build` produces an ~1.9 MB `app.js`. The main contributors are
xterm.js + addons (still loaded for governed mode and fleet execution
attach) and the vendored `assets/vendor/ghostty.js` renderer hook. **Don't
optimize this blindly** — tree-shaking xterm requires careful import paths
and breaks lazily-loaded addons.

If the bundle grows beyond ~2.5 MB, split via dynamic import on the
terminal hook so the workspace index page doesn't pull either renderer in.

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

**Governed mode** still uses the xterm.js + `TerminalChannel` path (inspection
and policy-gated commands). Multi-pane rendering is currently raw-only.

**Remote hosts**: Raw Ghostty + per-pane PTY is currently restricted to local/
manual hosts (`raw_terminal_allowed?/2`). An SSH adapter behind a
`DevIDE.Terminals.Adapter` behaviour is the planned extension path.

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
them into a `<pre>` with styled spans. Why Ghostty over xterm.js for raw:

- **Server-authoritative snapshots** via `Ghostty.Terminal.snapshot/2` (the
  Snapshot button captures HTML / plain / VT to `/tmp` and emits an audit
  event `ghostty.raw_terminal_snapshot`). xterm.js cannot do this — only
  the client knows the grid.
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
