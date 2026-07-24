# tmux-ctl / terminal-ctl

> The in-repo, app-agnostic control plane that turns tmux into DevIDE's durable session engine and conditions PTY byte streams for replay.

This is a companion to the authoritative [`tmux_control_plane.md`](../tmux_control_plane.md),
which owns the operator/API/audit narrative (topology shape, HTTP routes, mutation
envelopes, audit events, templates). This doc covers the **library internals** under
`lib/tmux_ctl/` and `lib/terminal_ctl/` — the durable-session persistence boundary
(§FP-2 in [`architecture.md`](../architecture.md)). It does not duplicate the API
surface; read the authoritative doc for that.

## Responsibility

`TmuxCtl.*` is a self-contained tmux control plane: it reads session topology,
mutates windows/panes, and watches sessions for change — with **no** references to
`DevIDE`, `Audit`, or `WorkspaceSource`. The product layer
(`DevIDE.Terminals.Tmux`, `DevIDE.Terminals.TmuxTopology`, outside these paths)
is a thin facade that injects config and adds audit on top.

`TerminalCtl.*` is two small pure helpers for PTY byte streams: stripping terminal
control handshakes before they reach replay buffers or raw subscribers, and
maintaining a fixed-size tail buffer for reconnect scrollback.

## Module map

| Module | File | Role |
|--------|------|------|
| `TmuxCtl.Adapter` | `lib/tmux_ctl/adapter.ex` | Behaviour: every tmux capability (reads, mutations, capture, env) as a `@callback`. Default impl is `TmuxCtl.Client`; tests swap `TmuxCtl.Test.FakeAdapter`. |
| `TmuxCtl.Client` | `lib/tmux_ctl/client.ex` | The real adapter. Builds tmux subcommand argv, parses `-F` pipe-delimited format strings into topology maps, and applies session defaults. Executes argv through `TmuxCtl.Runner`. |
| `TmuxCtl.Runner` | `lib/tmux_ctl/runner.ex` | Behaviour + dispatch for executing a tmux subcommand. `run/2` runs it; `argv/2` returns the full argv (for `Port.open`/`System.cmd` at call sites). Pluggable via `config :tmux_ctl, :runner`. |
| `TmuxCtl.Runner.Default` | `lib/tmux_ctl/runner/default.ex` | Default runner: `System.cmd("tmux", argv, ...)` with `stderr_to_stdout` and optional `:cd`. |
| `TmuxCtl.Topology` | `lib/tmux_ctl/topology.ex` | Pure topology projection: `snapshot/2` reads windows+panes via an adapter, attaches pane lists, picks active ids, and computes `version`/`structure_version` hashes. No process, no PubSub. |
| `TmuxCtl.Topology.Watcher` | `lib/tmux_ctl/topology/watcher.ex` | GenServer that polls `Topology.snapshot` on a timer and broadcasts `{:updated, topology}` / `{:session_terminated, ...}` over PubSub. One per session, registered via a `Registry`, supervised by an injected `DynamicSupervisor`. Idle-stops when no watchers remain. |
| `TmuxCtl.Test.FakeState` | `lib/tmux_ctl/test/fake_state.ex` | Test-only app-env store (`:tmux_ctl` keys) backing the fake adapter's session state. `@moduledoc false`. |
| `TerminalCtl.Escape` | `lib/terminal_ctl/escape.ex` | `strip_handshakes/1` removes cursor reports, XTVERSION probes, and device-attribute queries/responses from PTY bytes; returns `{clean_data, last_cursor_report \| nil}`. |
| `TerminalCtl.Replay` | `lib/terminal_ctl/replay.ex` | `append/4` maintains a fixed-size tail buffer (byte-bounded) with an optional truncation marker, for reconnect scrollback. |

## Data flow / lifecycle

**Topology read (no process):**
`TmuxCtl.Topology.snapshot(session, tmux: adapter)` → `read_topology/2` calls
`adapter.session_topology/1` (one subprocess: chained `list-windows` + `list-panes -s`)
or falls back to `list_session_windows/1` + `list_session_panes/1` → `attach_panes/2`
groups panes under their windows → active window/pane resolved → `version`
(`phash2` of all windows+panes) and `structure_version` (identity/order/active only)
computed.

**Watched read (live UI):**
`Watcher.ensure_started/2` looks up the session in the injected `registry`; if absent it
`DynamicSupervisor.start_child`s a watcher (`restart: :transient`, named via the
`Registry` `:via` tuple). `Watcher.init/1` takes an initial snapshot, tags it with a
monotonic `generation`, and schedules a refresh timer (`refresh_ms`, default 300ms /
`:topology_refresh_ms`). Each `:refresh` re-snapshots:
- empty windows **and** empty panes ⇒ session is gone ⇒ broadcast
  `{:session_terminated, %{reason: :session_not_alive}}`, run `on_session_terminated`,
  stop the timer, GenServer stops `:normal`.
- `version` changed ⇒ broadcast `{:updated, topology}` (tagged with `broadcast_tag`).
Consumers `watch/2` (monitored, cancels idle-stop) and `subscribe/2` (PubSub topic
`topic_prefix <> session`). When the last watcher drops, an idle-stop timer
(`:topology_idle_stop_ms`, default 60s) terminates the watcher.

**Mutation:** call sites (the DevIDE facade / API) invoke adapter mutation callbacks
(`new_window`, `split_pane`, `resize_pane`, `kill_pane`, …) directly on `TmuxCtl.Client`,
then refresh topology so the UI/audit converge on tmux truth.

**PTY conditioning (TerminalCtl):** raw PTY output arriving in `DevIDE.Terminals.SessionOwner`
is passed through `TerminalCtl.Escape.strip_handshakes/1` before being appended to the
replay buffer via `TerminalCtl.Replay.append/4` (exposed app-side as
`DevIDE.BoundedBuffer.append/4`). This keeps control handshakes out of reconnect
scrollback and out of raw subscriber streams.

## Public surface

Other code (primarily the `DevIDE.Terminals.*` facade) calls:

- **`TmuxCtl.Topology.snapshot/2`** — one-shot topology read with an explicit `tmux:`
  adapter. Also `structure_version/2` for DOM-keying that ignores per-poll churn.
- **`TmuxCtl.Topology.Watcher`** — `get/2`, `refresh/2`, `refresh_now/2`, `configure/2`,
  `subscribe/2`, `watch/2`, `unwatch/2`, `switch_subscription/3`, `topic/2`,
  `ensure_started/2`. Most take injected `:registry`/`:supervisor` (lifecycle ops),
  `:pubsub` (`subscribe/2`), or none (`topic/2` reads only `:topic_prefix`) — the opts
  required vary per function (+ optional `:tmux_resolver`, `:broadcast_tag`, `:topic_prefix`, `:on_session_terminated`).
- **`TmuxCtl.Client`** — the full `TmuxCtl.Adapter` callback set: `ensure_session/2`,
  `attach/1` (streaming `Port`), `send_keys/3`, `send_command/3`, `capture_scrollback/2`,
  `session_topology/1`, `directory_inventory/0`, window/pane mutations
  (`new_window`, `select_window`, `split_pane`, `resize_pane`, `kill_pane`, `rename_window`,
  `zoom_pane`/`ensure_zoomed`, `select_layout`, …), janitor reads
  (`list_windows/0`, `list_sessions/0`, `list_panes/0`, `kill_window/2`),
  `apply_defaults/1`, `resize_window/3`, `set_environment(s)`.
- **`TmuxCtl.Runner.run/2` / `argv/2`** — execute or materialize tmux argv; call sites that
  open Ports (`attach/1`) or run `System.cmd` directly (`send_command/3`) use `argv/2`.
- **`TerminalCtl.Escape.strip_handshakes/1`**, **`TerminalCtl.Replay.append/4`** — consumed by
  `lib/casein/terminals/session_owner.ex` and `lib/casein/bounded_buffer.ex`.

## Invariants & gotchas

- **No DevIDE references.** `TmuxCtl.*` must not reference `DevIDE`/`Audit`/`WorkspaceSource`.
  All app coupling (audit, config injection) lives in the facade outside these paths.
- **Two adapter config keys.** `TmuxCtl` reads `config :tmux_ctl, :adapter` (default
  `TmuxCtl.Client`); the product reads `:dev_ide, :tmux_adapter`. Adapter selection is
  deliberately **not** copied between them by `configure_tmux_ctl!` — see the authoritative
  doc's "Adapter configuration (two keys)" table. The watcher resolves its adapter lazily
  via `:tmux_resolver` (or the `:tmux_ctl, :adapter` fallback).
- **Mutations refuse non-`devide_*` sessions.** `Client.managed_session?/1` gates
  `kill_pane`, `kill_window`, `split_pane`, `resize_pane`, `zoom_pane`, `kill_other_panes`
  with `{:error, :refused_non_devide_session}` — the session prefix (`:tmux_ctl, :session_prefix`,
  default `"devide"`) is the safety namespace. Reads are not gated.
- **Pane ids are server-global.** `pane_target/2` passes `%N` ids through unprefixed;
  `session:%N` would be parsed by tmux as a window name.
- **`session_topology` empty-both means dead.** `{[], []}` from a topology read is the
  liveness signal the watcher uses to declare `:session_terminated` — no separate
  `has-session` probe.
- **`version` vs `structure_version`.** `version` hashes everything (incl. activity/geometry/
  command) and drives broadcast decisions; `structure_version` excludes per-poll churn so
  DOM consumers keyed on structure aren't patched every 300ms.
- **`apply_defaults/1` is batched then per-option.** One `;`-chained tmux invocation; on any
  non-zero exit it re-runs each option to report which failed. Idempotent — safe to re-run.
  Rebinds `prefix w`/`prefix s` to hint messages so stray prefixes don't draw tmux's
  choose-tree inside the embedded terminal.
- **Format-string field ordering.** In the **directory/janitor** `-F` formats
  (`@directory_window_fmt`, `@directory_pane_fmt`) the user-controlled field (window
  name, pane path) is placed **last** so a literal `|` can't shift earlier fields. The
  primary `@topology_window_fmt` puts `window_name` mid-string (3rd of 7) and instead
  relies on `String.split(…, parts: 7)` capping the trailing split + session-name
  sanitization to `[A-Za-z0-9_-]`.
- **`Escape.strip_handshakes/1` fast-path.** Returns input unchanged when no `\e` byte is
  present — most PTY chunks skip the regex passes.
- **`Replay.append/4` is byte-bounded, not line-bounded.** When incoming data alone meets the
  limit it keeps only the trailing `limit` bytes (prefixed with the marker); it does not align
  to line boundaries.

## See also

- [`tmux_control_plane.md`](../tmux_control_plane.md) — authoritative: topology/mutation API,
  audit events, session templates, operator workflow.
- [`architecture.md`](../architecture.md) — §FP-2 (durability), §FP-8/§FP-9 (server without
  cockpit, disconnect tolerance).
- [`terminal.md`](../terminal.md) — terminal/PTY surface this control plane backs.
- [`workspace_sources.md`](../workspace_sources.md) — host vs container argv wrapping the
  runner/`attach` accommodate.
