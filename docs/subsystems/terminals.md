# Subsystem: terminals (server-side PTY/tmux core)

> Owns the durable, server-authoritative terminal: one tmux session per
> `(workspace, sid)`, the PTY behind it, output fan-out to every viewer, and
> the session/window/template control plane over tmux.

This is the largest Casein subsystem. It is the server half of FP-1 (execution
authority lives server-side), FP-2/FP-8 (durable sessions over tmux), and
FP-9 (reattach replays scrollback). It does **not** own the browser renderer or
the LiveView wiring — those live in `lib/casein_web/live/workspace_live/`
(`PaneWorker`, the Ghostty hook). It does not own admission policy
(`Casein.Policy.can_use_raw_terminal?/1`); `Terminals.Boundary` is the only call
site into it.

### Geometry ownership (issue #748)

tmux here is the **persistence** boundary (sessions, PTYs, scrollback, crash
recovery). It is **not** the layout authority for where panes appear in the
cockpit. Arrangement, focus, and the cols/rows told to each PTY are Casein's
(`docs/design/casein-owns-geometry.md`). Today `SessionOwner` already stamps the
focused viewer's fitted size onto the shared window; the browser fit is a single
pure path (`assets/js/terminal_layout_model.mjs` `computeTerminalLayout` + the
jsdom contract tests). Do not add a second fit path. Layout is never a crash-
recovery input (`docs/subsystems/tmux_crash_recovery.md`).

## Responsibility

- Allocate and own one tmux-backed PTY per `(workspace, sid)`
  (`Session` via `tmux new-session -A`), surviving client disconnects and BEAM
  restarts.
- Multiplex one PTY's output to N attached viewers and resolve the single shared
  PTY winsize across differently-sized viewers (`SessionOwner`).
- Replay retained scrollback to a freshly-attached viewer (`Session` buffer +
  `SessionOwner` replay buffer).
- Compute the canonical, viewer-independent list of attachable session tabs and
  push updates (`SessionDirectory` + `Compose`).
- Provide the tmux control plane facade — naming, argv wrapping, topology,
  window/pane mutation, idle GC (`Tmux`, `TmuxPolicy`, `TmuxRunner`,
  `TmuxTopology`, the janitors).
- Apply and persist session-layout templates (`SessionTemplate`, `Templates`,
  and their executors/reconcilers).
- Gate raw-terminal admission at the boundary and audit it (`Boundary`).

## Module map

### Session core (PTY + fan-out + replay)

| Module | File | Role |
|---|---|---|
| `Casein.Terminals.Session` | `session.ex` | GenServer wrapping `tmux new-session -A` under an `erlexec` PTY; one per `{workspace, sid}` in `Terminals.Registry`. Multi-subscriber fan-out (`{:term_data, ref, bin}`), 64 KiB bounded replay buffer seeded from `Tmux.capture_scrollback/1`, resize clamps to `1..500`. |
| `Casein.Terminals.SessionOwner` | `session_owner.ex` | Per-logical-session owner GenServer; attaches/detaches subscribers, broadcasts `{:terminal_payload, ...}`, owns the **focused-viewer resize policy** and the reconnect replay buffer. `:shell` owners are immortal; `:agent` owners stop on last detach. |
| `Casein.Terminals.Attachment` | `attachment.ex` | Deterministic backend handle; `:shell` routes through `GhosttyRawAdapter`+`Session`, `:agent` returns `:agent_backend_unavailable`. Dispatches `send_input`/`resize`/`snapshot`/`close`. |
| `Casein.Terminals.GhosttyRawAdapter` | `ghostty_raw_adapter.ex` | Migration bridge: ensures the canonical `Session` PTY for `(workspace, sid, loc)` so channel raw joins and LiveView panes share one `SessionOwner`. |
| `Casein.Terminals.Session.Info` | `session/info.ex` | Uniform session struct (`:shell` / `:agent`), `owner_key` derivation source, `new_shell/3`, `new_agent/2`. |
| `Casein.Terminals.SessionRegistry` | `session_registry.ex` | Discovers attachable shell sessions for a workspace from `Terminals.Registry`; `resolve/1` used by the channel on join. |
| `Casein.Terminals.SyncOutput` | `sync_output.ex` | DEC 2026 synchronized-output (BSU/ESU) detection so a frame is held back mid-redraw (consumed by `PaneWorker`). |
| `Casein.Terminals.CleanExec` | `clean_exec.ex` | Wraps non-tmux raw child argv to close inherited BEAM fds before exec; **tmux argv is passed through untouched** (wrapping breaks `new-session` attach). |
| `Casein.Terminals.Telemetry` | `telemetry.ex` | O(1) ETS gauges for active owners / open attachments / subscribers-per-owner. |

### Session directory (tab list)

| Module | File | Role |
|---|---|---|
| `Casein.Terminals.SessionDirectory` | `session_directory.ex` | Per-workspace GenServer: canonical tab list, 2 s tmux poll while watched, broadcasts `{:sessions_updated, workspace_id, tabs}`; slow tmux reads run off the GenServer. `read/2` is the processless fallback. |
| `Casein.Terminals.SessionDirectory.Compose` | `session_directory/compose.ex` | Pure merge/dedup/staleness rules; `compose/2`, `visible_for/2`, `attach_id/1`, `stable_hash/1` (the re-broadcast gate). |
| `Casein.Terminals.Activity` | `activity.ex` | `monitor-silence` analog: quantizes an agent window's activity timestamp into a boolean `quiet?` so only flips re-broadcast the tab list. |

### tmux control plane

| Module | File | Role |
|---|---|---|
| `Casein.Terminals.Tmux` | `tmux.ex` | Facade over `TmuxCtl.Client`; the `@behaviour TmuxCtl.Adapter` used as the product `:tmux_adapter`. |
| `Casein.Terminals.TmuxPolicy` | `tmux_policy.ex` | Session naming/sanitization: `session_name/2` → `casein_<ws>_<sid>`, `workspace_session_prefix/1`. |
| `Casein.Terminals.TmuxRunner` | `tmux_runner.ex` | `@behaviour TmuxCtl.Runner`; host-vs-container argv wrapping via `WorkspaceSource.prepare_local_argv/2`, container-tmux probe cached in `:persistent_term`. |
| `Casein.Terminals.TmuxTopology` | `tmux_topology.ex` | Facade over `TmuxCtl.Topology`/`.Watcher`; preserves the `{TmuxTopology, msg}` PubSub tuple; emits `tmux.session_terminated` audit on terminate. |
| `Casein.Terminals.TmuxServer` | `tmux_server.ex` | Resolves the per-env tmux server label (`-L`): `casein` (prod), `casein_dev` (dev), `casein_test` (test). Each is an isolated server so Casein never shares a socket with another env or with plain SSH tmux. |
| `Casein.Terminals.TmuxJanitor` | `tmux_janitor.ex` | Subscriber-driven idle GC at the **session** level; kills `casein_*` sessions after `:tmux_idle_seconds` with no subscribers. |
| `Casein.Terminals.TmuxWindowJanitor` | `tmux_window_janitor.ex` | Periodic sweep reaping blank auto-named idle **windows** and whole orphaned sessions (survives restarts; the safety net `TmuxJanitor` cannot reach). |

### Templates

| Module | File | Role |
|---|---|---|
| `Casein.Terminals.SessionTemplate` | `session_template.ex` | Declarative built-in template type; `new/1`, `list/0,1`, `plan/2`, `dry_run/2`, `execute/3`, `export_topology/2`. |
| `Casein.Terminals.SessionTemplate.Loader` | `session_template/loader.ex` | Resolves built-in (hard-coded) templates and merges saved exports for a workspace. |
| `Casein.Terminals.SessionTemplate.Planner` | `session_template/planner.ex` | Builds dry-run tmux mutation plans from a template. |
| `Casein.Terminals.SessionTemplate.Executor` | `session_template/executor.ex` | Plan/dry-run/execute boundary for built-in templates. |
| `Casein.Terminals.SessionTemplate.Export` | `session_template/export.ex` | Exports live topology → template v2 map (conservative h/v split inference, `tiled` fallback). |
| `Casein.Terminals.SessionTemplate.Window` / `.Pane` | `session_template/window.ex`, `pane.ex` | Window/pane sub-structs for the template tree. |
| `Casein.Terminals.Templates` | `templates.ex` | Ecto persistence boundary for saved v2 exports (`saved_templates` table): save/list/get/update/duplicate/delete + `dry_run`/`execute`/`diff`/`execute_reconcile`. |
| `Casein.Terminals.Templates.Executor` | `templates/executor.ex` | Imperative replay of a saved v2 export (creates windows/panes, sends commands, restores focus). |
| `Casein.Terminals.Templates.Reconciler` | `templates/reconciler.ex` | Read-only diff of a saved export against current topology. |
| `Casein.Terminals.Templates.ReconcileExecutor` | `templates/reconcile_executor.ex` | Additive/selective apply of a reconcile diff (reuse, create-missing, never delete/rename). |

### Policy, themes, input helpers

| Module | File | Role |
|---|---|---|
| `Casein.Terminals.Boundary` | `boundary.ex` | Raw-admission gate: `raw_allowed?/2`/`authorize_raw/2` → `Policy.can_use_raw_terminal?/1` + `Runs.Ledger`; `interactive_command_ids/0`, `format_reason/1`. |
| `Casein.Terminals.ModePolicy` | `mode_policy.ex` | Pure mode resolver; everything is `:raw`; `tmux_mutations_enabled?/1` true only for `:shell`. |
| `Casein.Terminals.Theme` / `.Builtins` | `theme.ex`, `theme/builtins.ex` | Renderer-first themes (Catppuccin presets + `ghostty.conf` loading) and OSC 10/11/12/4 rewrite helpers for pane query responses. |
| `Casein.Terminals.ClipboardPaste` | `clipboard_paste.ex` | Saves pasted/dropped images/files into `.casein/clipboard/` and pastes the path; git-exclude maintenance. |
| `Casein.Terminals.Shims` | `shims.ex` | Materializes Casein-scoped terminal command shims under `~/.casein/terminal-shims/`, self-healing installers under `~/.casein/terminal-shims/install/`, managed tool binaries under `~/.casein/tools/bin/`, and pane capability env (`CASEIN_TERMINAL=1`, `CASEIN_CLIPBOARD=osc52`). Current app shim: `elio` → auto-install via Cargo + `ELIO_CLIPBOARD_OSC52=1`. |
| `Casein.Terminals.GhosttySnapshot` | `ghostty_snapshot.ex` | Writes `Ghostty.Terminal` HTML/plain/VT grid dumps to `:ghostty_snapshot_dir` (kept out of the LiveView for the no-apply boundary guard). |
| `Casein.Terminals.InspectionCommands` | `inspection_commands.ex` | Read-only governed argv registry (`pwd`/`ls`/`git status`/`rg`/`tidewave`/`preview …`) run in the workspace root with bounded output. |
| `Casein.Terminals.Workflows` | `workflows.ex` | Repo-scoped Warp-subset workflow launchers; renders+revalidates argv, encodes a `workflow:` command id (never persists executable argv). |
| `Casein.Terminals.WorkspaceAccessCache` | `workspace_access_cache.ex` | 60 s ETS cache of `Workspaces.get/2` to avoid manager round-trips on reconnect. |

## Data flow / lifecycle

Raw shell attach (the default `:session_owner` path):

```
caller pid (LiveView PaneWorker / channel)
  └─ SessionOwner.attach(workspace_id, %Info{kind: :shell}, mode: :raw, loc: ..., workspace_key: ...)
       ├─ ensure_started → DynamicSupervisor under Terminals.Registry (owner_key/1)
       ├─ Process.monitor(subscriber); record in subscribers/refs maps
       └─ ensure_attachment → Attachment.open(:shell)
            └─ GhosttyRawAdapter.ensure_raw_shell → Session.ensure_started({ws, sid, loc})
                 └─ :exec.run("tmux new-session -A -s casein_<ws>_<sid> ...")  ← persistence boundary
            └─ Session.subscribe(pid) → {:ok, ref, cols, rows}; replays 64 KiB buffer

PTY output:  Session ingest → {:term_data, ref, bin} → SessionOwner.handle_term_data
              → strip handshakes / capture cursor → append replay buffer (raw subs only)
              → broadcast {:terminal_payload, :data, %{data: ...}} to subscribers

Resize:      viewer → SessionOwner.resize(pid, cols, rows)  (tagged with caller pid)
             viewer → SessionOwner.set_active(pid, true/false)
              → record_subscriber_size / record_subscriber_active
              → authoritative_size = most-recently-active viewer, else largest
              → Attachment.resize (Session.resize → :exec.winsz) + async Tmux.resize_window
```

Lifecycle / durability:

- A `Session` persists across client disconnects: `{:DOWN, ...}` of a subscriber
  removes only that subscriber; the PTY (and tmux) live on for reconnects.
- `SessionOwner` for a `:shell` is **immortal** (`should_stop?/1`) — tied to the
  tmux session's `-A` reuse, reused across clients; `:agent` owners stop on last
  detach.
- Idle GC: `TmuxJanitor` kills a `casein_*` session after its last LiveView
  subscriber leaves and `:tmux_idle_seconds` elapses; `TmuxWindowJanitor`
  periodically reaps abandoned blank windows and orphaned sessions that the
  in-memory subscriber map cannot (e.g. after a restart).
- Tab list: `SessionDirectory` polls tmux every 2 s while watched, recomputes
  `Compose.compose/2`, and broadcasts only when `Compose.stable_hash/1` changes.

## Public surface

Functions/processes other subsystems and the web tier call:

- **Attach / IO** — `SessionOwner.attach/3`, `detach/2`, `input/2`, `resize/3`,
  `set_active/2`, `subscriber_count/1`. Lower-level: `Session.ensure_started/3`,
  `subscribe/1`, `snapshot/1`, `unsubscribe/1`, `send_input/2`, `resize/3`.
- **Discovery** — `SessionDirectory.tabs/2`, `read/2`, `refresh_now/2`,
  `subscribe/2`, `fetch/3`, `topic/1`; `SessionRegistry.list_attachable/1`,
  `resolve/1`; `Session.Info.new_shell/3` / `new_agent/2`.
- **tmux control plane** — `Tmux.*` (the full `TmuxCtl.Adapter` surface incl.
  `session_name/2`, `capture_scrollback/1`, window/pane mutations);
  `TmuxTopology.get/2`, `snapshot/2`, `subscribe/1`, `watch/2`,
  `switch_subscription/3`, `topic/1`; `TmuxPolicy.session_name/2`,
  `workspace_session_prefix/1`.
- **Admission / mode** — `Boundary.raw_allowed?/2`, `authorize_raw/2`,
  `interactive_command_ids/0`, `format_reason/1`; `ModePolicy.initial_mode/2`,
  `tmux_mutations_enabled?/1`.
- **Templates** — `SessionTemplate.list/1`, `dry_run/2`, `execute/3`,
  `export_topology/2`; `Templates.save/1`, `list_for_workspace/2`, `dry_run/3`,
  `execute/4`, `diff/4`, `execute_reconcile/5`.
- **Helpers** — `GhosttySnapshot.capture/2`, `ClipboardPaste.save_file/2`,
  `Shims.materialize!/1`, `Shims.env/1`, `InspectionCommands.run/3`,
  `Workflows.resolve_line/2`,
  `Theme` client bundle + OSC rewrites, `Telemetry` counters.

Registries/supervisors: `Casein.Terminals.Registry` (sessions + owners +
directory), `Casein.Terminals.Supervisor` (DynamicSupervisor),
`Casein.Terminals.TopologyRegistry` / `TopologySupervisor` (watcher pool),
`Casein.TaskSupervisor` (off-process tmux resize).

## Invariants & gotchas

- **One PTY, one winsize.** A `SessionOwner` owns a single PTY at a single size.
  When viewers differ, the size resolves to the **most-recently-active**
  (visible+focused, via `set_active/2`) viewer, falling back to the **largest**
  requested area when nobody is focused. History: last-writer-wins caused
  interleaved redraws; smallest-clamp let a phone/hidden tab shrink the primary
  user to a narrow column. See the comment block above
  `record_subscriber_size/3`. (Matches the MEMORY note "Terminal multi-viewer
  resize corruption".)
- **tmux is the persistence boundary.** `tmux new-session -A` attaches if the
  session exists, else creates — that single `-A` is the reconnect mechanism;
  `Session`/`SessionOwner` processes are disposable.
- **`:shell` owners never self-stop.** Only `:agent` owners stop on last detach;
  do not assume a detach tears down a shell PTY.
- **Replay source is the `Session` buffer, not the owner buffer.** The owner's
  replay buffer only accumulates while a raw subscriber is attached;
  `replay_data/1` prefers `Attachment.snapshot/1` (the continuously-captured
  `Session` buffer) and strips terminal handshakes so stale startup probes never
  reach a fresh viewer. Replay is delivered synchronously inside the attach
  `handle_call` to avoid replay/live interleaving.
- **Never wrap tmux argv in `CleanExec`.** Any fd close/redirect before
  `exec tmux ...` breaks the foreground `new-session` attach (surfaces as
  "Terminal exited 0"); tmux self-daemonizes and is exempt.
- **`casein_`-prefix guard.** Both janitors refuse to kill any session whose
  name does not start with `casein_`; `TmuxWindowJanitor` additionally spares
  named, active, or busy (non-shell) windows/sessions. (See MEMORY "Devbox
  process safety".)
- **Calendar cleanup is outside the app timer.** The in-app
  `:tmux_window_sweep_ms` interval resets on release restarts. The systemd
  timer installed by `scripts/ensure-casein-tmux-janitor-sweep.sh` is the
  durable weekly cadence; it still calls the in-app policy, so there is only
  one kill-policy implementation.
- **Server isolation & config (`-L` / `-f`).** Each env runs its tmux sessions
  on a dedicated server via `:tmux_server_label` (`TmuxServer.args/0` →
  `["-L", label]`): `casein` (prod, `config/prod.exs`), `casein_dev` (dev,
  `config/dev.exs`), `casein_test` (test, `config/test.exs`). Distinct labels
  are required — on the devbox the `:4000` dev server and the prod release run
  as the same user, so a shared label would collide on one socket; the test
  label also keeps the live integration tests off prod sessions. An unset label
  falls back to the host's *default* server, sharing it with plain SSH tmux.
  - **Per-server config.** On the host path, `TmuxRunner` appends `-f <file>`,
    resolved by precedence: `:tmux_ctl, :config_file` → `:casein,
    :tmux_config_file` → `$CASEIN_TMUX_CONFIG` → bundled `priv/tmux/casein.conf`
    (`tmux_runner.ex:82-104`). Container sessions skip `-f` (the priv dir isn't
    mounted in arbitrary workspace images) and instead get the same options
    programmatically via `TmuxCtl.Client.apply_defaults/1`. tmux reads `-f` only
    when it *starts* a server, so config is **per-server, not per-client**: one
    server = one config. A different config means a different `-L` label.
  - **SSH coexistence.** Because Casein owns a labeled server, an operator's
    plain `tmux` (default server, their `~/.tmux.conf`) is untouched. To attach
    to Casein's sessions from a shell: `tmux -L casein attach` (or `casein_dev`
    / `casein_test`). The `-f` on such an attach is ignored — the server is
    already running with its own conf.
  - **Operator cutover ⚠️.** Introducing or changing a label points Casein at a
    *fresh, empty* server. Sessions on the previously-used server (e.g. the
    default server before this change) stay alive but become invisible to
    Casein — it won't list, attach, or reconcile them, and creates new sessions
    on the new server as workspaces reopen. Expect a one-time "terminals reset"
    for active users at the first deploy that sets the label. To preserve a
    live session, `tmux move-session`/relaunch it onto the new `-L` server, or
    cut over during a quiet window.
- **Adapter selection.** The `:tmux_adapter` is selected from `:casein`
  `:tmux_adapter` (see `docs/tmux_control_plane.md` for the two-key split).
- **Tab list stability.** Only identity-stable fields belong in
  `metadata.windows` (it feeds `Compose.stable_hash/1`); volatile activity and
  pane membership go in non-hashed metadata so they don't re-broadcast every
  poll. The `quiet?` boolean (`Activity`) is the deliberate exception.
- **`SessionDirectory` slow reads run off the GenServer.** `refresh_now/2` does
  the tmux read in the caller; the GenServer only stores+broadcasts, so cheap
  `tabs/2` reads from other viewers never queue behind a slow enumeration.
- **`Boundary` is the only admission call site.** Raw admission policy itself
  lives in `Casein.Policy` (outside this subsystem); the verdict is recorded as
  `run.session_attached` / `run.session_denied` in `Runs.Ledger`.
- **Clipboard copy-out is OSC52.** Casein terminal panes advertise
  `CASEIN_TERMINAL=1` and `CASEIN_CLIPBOARD=osc52`; terminal apps should emit
  OSC52 for copy/yank operations so the browser-side clipboard bridge can write
  to the human's clipboard. Server desktop helpers (`wl-copy`, `xclip`, `xsel`,
  `pbcopy`, etc.) are not the primary route because they target the server or
  container desktop environment, not the user's browser.
- **Desktop drag-select is copy-on-select.** Finishing a cell selection (mouseup
  after a real drag) writes the selection to the browser clipboard immediately
  while keeping the highlight. Cmd/Ctrl+C, the context-menu Copy action, and
  OSC52 still work. Touch keeps the system long-press callout (no auto-copy).
- **Whether a drag selects depends on the program's mouse modes, not on the
  scroll policy.** `plainDragSelectMode` (`terminal_scroll_policy.mjs`) reads the
  DECSET modes Ghostty reports per pane:
  - motion tracking (1002/1003 — tmux `mouse on`, lazygit, htop): drags are the
    program's, so local selection needs **Shift**, the xterm/iTerm convention.
  - click tracking only (1000/9, no motion — **Claude Code** sets 1000 + 1006):
    the program can act on a click but can never see a drag, so the press is
    **deferred** until the gesture declares itself. Past a 4px slop it becomes a
    local selection and nothing reaches the PTY; released inside the slop it is
    replayed to the program as press+release at the original cell. Suppressing
    the mousedown is what makes the gesture ours — it also stops the vendor
    setting `pointerActive`, so the vendor's own move/up handlers no-op and the
    click branch must re-focus the input itself. A deferred press also retires
    any existing highlight: a click never re-anchors the selection the way a
    drag does, so without that it would stay painted.
  - no tracking (plain shell): plain drag selects immediately.

  Gating this on the coarse `mouse.tracking` flag is what used to make Shift
  mandatory in agent panes that never wanted the drag. Regression tests:
  `assets/test/ghostty_terminal_drag_select.test.mjs`.
- **Agent TUI scroll is pointer-local SGR, not emulator history.** Focused-pane
  `role` / `current_command` (via `Casein.Terminals.PaneInteraction`) sets
  `data-scroll-policy` on pane tiles. Agent mode: wheel/touch → SGR mouse at the
  cell under the pointer (multi-pane hit-test); plain click reaches the PTY;
  Alt+wheel opens the pane history drawer (tmux capture — dual-layer history).
  Shell mode keeps Ghostty scrollback. Debug with `?termscroll=1` or
  `localStorage["casein:termscroll"]="1"`.
- **Clipboard image paste into agents uses `@path`.** The paste reply includes
  `path_format` from the same pane interaction detector so Grok/Claude attach
  files instead of printing a shell-quoted absolute path line.

- **Terminal shims are scoped, lazy, and self-healing for known tools.**
  `Casein.Terminals.Shims` materializes wrappers under
  `~/.casein/terminal-shims/`, installer backends under
  `~/.casein/terminal-shims/install/`, and Casein-managed binaries under
  `~/.casein/tools/bin/`. Casein prepends the shim dir and tool bin dir only for
  terminal panes. A shim removes only its own directory from `PATH`, resolves the
  real command, and `exec`s it with app-specific compatibility env. If a
  registry-backed command is missing, the shim calls `casein ensure-installed
  <tool>` when available, falls back to its materialized installer, re-resolves,
  then launches. Installers are non-interactive, print a short Casein-prefixed
  provisioning message before streaming Cargo output, use a per-tool lock
  directory (`~/.casein/tools/.<tool>-install.lock`) so two panes do not race,
  build into a temporary Cargo root, and publish the final binary into
  `~/.casein/tools/bin/` only after success. This keeps `/usr/bin/<tool>` raw
  and makes bypass/debugging straightforward. The first self-healing shim is
  `elio`, which installs the crates.io `elio` package into `~/.casein/tools/`
  and sets `ELIO_CLIPBOARD_OSC52=1` so Elio uses the OSC52 clipboard path inside
  Casein.

## See also

- [`../terminal.md`](../terminal.md) — authoritative terminal architecture
  (Ghostty renderer, multi-pane split tree, multi-tab behaviour, idle GC, the
  browser/LiveView wiring). **This doc is the server-core companion; that doc
  wins on renderer/UI.**
- [`../tmux_control_plane.md`](../tmux_control_plane.md) — authoritative tmux
  control-plane reference (TmuxCtl layering, two-key adapter config, topology +
  template HTTP API, audit events).
- [`../architecture.md`](../architecture.md) — first principles (FP-1/2/8/9),
  authority map, config keys, adapter pattern.
- [`../terminal_mcp.md`](../terminal_mcp.md) — agent-facing terminal MCP tools
  over these tmux sessions.
- [`../state_machines.md`](../state_machines.md) — session/mode/audit lifecycles.
</content>
