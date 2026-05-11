# Terminal subsystem

Live PTY terminal for workspace control. Per-tab xterm.js client, Phoenix
channel transport, erlexec-spawned `tmux new-session -A -s <name>` on the host.

## Architecture

```
Browser (xterm.js + FitAddon)
   ↕  Phoenix Channel  (terminal:<workspace_id>:<sid>)
DevIdeWeb.TerminalChannel
   ↕  GenServer messages
DevIDE.Terminals.Session     ← one per (workspace, sid), Registry-keyed
   ↕  erlexec :pty
tmux new-session -A -s devide:<workspace>:<sid>
```

The tmux session is the persistence boundary. The Elixir Session GenServer
can come and go; reconnecting any browser tab reattaches to the same tmux
session via `tmux new-session -A` (attach if exists, else create).

## erlexec PTY: known quirks

`:exec.run/2` with the `:pty` option allocates a real PTY, but it routes
**all child output through the `:stderr` channel**, not `:stdout`. Capture
both:

```elixir
opts = [:pty, :stdin, :monitor,
        {:stdout, self()},
        {:stderr, self()}]   # ← required in PTY mode
```

We also call `:exec.winsz/3` immediately after spawn — without it, tmux
detects a pathological terminal size (e.g. 11216 rows) from whatever the
default ioctl returns.

## Auth

`DevIdeWeb.ChannelAuth` centralises the token salt (`"user socket"`,
24h max age). Show LiveView signs on mount; UserSocket verifies on connect.
When real auth lands, change one module.

## Bundle size

`mix assets.build` produces an ~805 kB `app.js`. Most of that is xterm.js +
addons. **Don't optimize this blindly.** Tree-shaking xterm requires careful
import paths and breaks lazily-loaded addons. The cost is paid once per
session; control-plane UX is not latency-critical for first-paint.

If the bundle grows beyond ~1.5 MB, split via dynamic import on the
terminal hook so the workspace index page doesn't pull it in.

## Open issues (not yet implemented)

- **Idle session GC**: Sessions live until tmux exits. Acceptable for dev,
  but production needs an idle timer that kills tmux + Session after N
  minutes with no subscriber. File: `lib/dev_ide/terminals/session.ex`.
- **Multi-pane**: One `(workspace, sid)` → one session. Splits/panes live
  inside tmux for now; a future iteration may surface them as separate
  channels.
- **Remote hosts**: Sessions assume tmux on the local host. SSH adapter
  belongs behind a `DevIDE.Terminals.Adapter` behaviour, not added yet.
