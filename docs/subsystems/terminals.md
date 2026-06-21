# Subsystem: terminals (server-side PTY/tmux core)

> Owns the durable, server-authoritative terminal: one tmux session per
> `(workspace, sid)`, the PTY behind it, output fan-out to every viewer, and
> the session/window/template control plane over tmux.

This is the largest DevIDE subsystem. It is the server half of FP-1 (execution
authority lives server-side), FP-2/FP-8 (durable sessions over tmux), and
FP-9 (reattach replays scrollback). It does **not** own the browser renderer or
the LiveView wiring — those live in `lib/dev_ide_web/live/workspace_live/`
(`PaneWorker`, the Ghostty hook). It does not own admission policy
(`DevIDE.Policy.can_use_raw_terminal?/1`); `Terminals.Boundary` is the only call
site into it.

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
| `DevIDE.Terminals.Session` | `session.ex` | GenServer wrapping `tmux new-session -A` under an `erlexec` PTY; one per `{workspace, sid}` in `Terminals.Registry`. Multi-subscriber fan-out (`{:term_data, ref, bin}`), 64 KiB bounded replay buffer seeded from `Tmux.capture_scrollback/1`, resize clamps to `1..500`. |
| `DevIDE.Terminals.SessionOwner` | `session_owner.ex` | Per-logical-session owner GenServer; attaches/detaches subscribers, broadcasts `{:terminal_payload, ...}`, owns the **focused-viewer resize policy** and the reconnect replay buffer. `:shell` owners are immortal; `:agent` owners stop on last detach. |
| `DevIDE.Terminals.Attachment` | `attachment.ex` | Deterministic backend handle; `:shell` routes through `GhosttyRawAdapter`+`Session`, `:agent` returns `:agent_backend_unavailable`. Dispatches `send_input`/`resize`/`snapshot`/`close`. |
| `DevIDE.Terminals.GhosttyRawAdapter` | `ghostty_raw_adapter.ex` | Migration bridge: ensures the canonical `Session` PTY for `(workspace, sid, loc)` so channel raw joins and LiveView panes share one `SessionOwner`. |
| `DevIDE.Terminals.Session.Info` | `session/info.ex` | Uniform session struct (`:shell` / `:agent`), `owner_key` derivation source, `new_shell/3`, `new_agent/2`. |
| `DevIDE.Terminals.SessionRegistry` | `session_registry.ex` | Discovers attachable shell sessions for a workspace from `Terminals.Registry`; `resolve/1` used by the channel on join. |
| `DevIDE.Terminals.SyncOutput` | `sync_output.ex` | DEC 2026 synchronized-output (BSU/ESU) detection so a frame is held back mid-redraw (consumed by `PaneWorker`). |
| `DevIDE.Terminals.CleanExec` | `clean_exec.ex` | Wraps non-tmux raw child argv to close inherited BEAM fds before exec; **tmux argv is passed through untouched** (wrapping breaks `new-session` attach). |
| `DevIDE.Terminals.Telemetry` | `telemetry.ex` | O(1) ETS gauges for active owners / open attachments / subscribers-per-owner. |

### Session directory (tab list)

| Module | File | Role |
|---|---|---|
| `DevIDE.Terminals.SessionDirectory` | `session_directory.ex` | Per-workspace GenServer: canonical tab list, 2 s tmux poll while watched, broadcasts `{:sessions_updated, workspace_id, tabs}`; slow tmux reads run off the GenServer. `read/2` is the processless fallback. |
| `DevIDE.Terminals.SessionDirectory.Compose` | `session_directory/compose.ex` | Pure merge/dedup/staleness rules; `compose/2`, `visible_for/2`, `attach_id/1`, `stable_hash/1` (the re-broadcast gate). |
| `DevIDE.Terminals.Activity` | `activity.ex` | `monitor-silence` analog: quantizes an agent window's activity timestamp into a boolean `quiet?` so only flips re-broadcast the tab list. |

### tmux control plane

| Module | File | Role |
|---|---|---|
| `DevIDE.Terminals.Tmux` | `tmux.ex` | Facade over `TmuxCtl.Client`; the `@behaviour TmuxCtl.Adapter` used as the product `:tmux_adapter`. |
| `DevIDE.Terminals.TmuxPolicy` | `tmux_policy.ex` | Session naming/sanitization: `session_name/2` → `devide_<ws>_<sid>`, `workspace_session_prefix/1`. |
| `DevIDE.Terminals.TmuxRunner` | `tmux_runner.ex` | `@behaviour TmuxCtl.Runner`; host-vs-container argv wrapping via `WorkspaceSource.prepare_local_argv/2`, container-tmux probe cached in `:persistent_term`. |
| `DevIDE.Terminals.TmuxTopology` | `tmux_topology.ex` | Facade over `TmuxCtl.Topology`/`.Watcher`; preserves the `{TmuxTopology, msg}` PubSub tuple; emits `tmux.session_terminated` audit on terminate. |
| `DevIDE.Terminals.TmuxServer` | `tmux_server.ex` | Resolves the tmux server label (`-L`); `:test` sandboxes onto `devide_test`, prod/dev use the default server. |
| `DevIDE.Terminals.TmuxJanitor` | `tmux_janitor.ex` | Subscriber-driven idle GC at the **session** level; kills `devide_*` sessions after `:tmux_idle_seconds` with no subscribers. |
| `DevIDE.Terminals.TmuxWindowJanitor` | `tmux_window_janitor.ex` | Periodic sweep reaping blank auto-named idle **windows** and whole orphaned sessions (survives restarts; the safety net `TmuxJanitor` cannot reach). |
| `DevIDE.Terminals.TmuxAdapter` | `tmux_adapter.ex` | Standalone `System.cmd` tmux lifecycle helper (create/alive/kill/capture) for execution sessions; **not** wired into the facade path. |

### Templates

| Module | File | Role |
|---|---|---|
| `DevIDE.Terminals.SessionTemplate` | `session_template.ex` | Declarative built-in template type; `new/1`, `list/0,1`, `plan/2`, `dry_run/2`, `execute/3`, `export_topology/2`. |
| `DevIDE.Terminals.SessionTemplate.Loader` | `session_template/loader.ex` | Resolves built-in (hard-coded) templates and merges saved exports for a workspace. |
| `DevIDE.Terminals.SessionTemplate.Planner` | `session_template/planner.ex` | Builds dry-run tmux mutation plans from a template. |
| `DevIDE.Terminals.SessionTemplate.Executor` | `session_template/executor.ex` | Plan/dry-run/execute boundary for built-in templates. |
| `DevIDE.Terminals.SessionTemplate.Export` | `session_template/export.ex` | Exports live topology → template v2 map (conservative h/v split inference, `tiled` fallback). |
| `DevIDE.Terminals.SessionTemplate.Window` / `.Pane` | `session_template/window.ex`, `pane.ex` | Window/pane sub-structs for the template tree. |
| `DevIDE.Terminals.Templates` | `templates.ex` | Ecto persistence boundary for saved v2 exports (`saved_templates` table): save/list/get/update/duplicate/delete + `dry_run`/`execute`/`diff`/`execute_reconcile`. |
| `DevIDE.Terminals.Templates.Executor` | `templates/executor.ex` | Imperative replay of a saved v2 export (creates windows/panes, sends commands, restores focus). |
| `DevIDE.Terminals.Templates.Reconciler` | `templates/reconciler.ex` | Read-only diff of a saved export against current topology. |
| `DevIDE.Terminals.Templates.ReconcileExecutor` | `templates/reconcile_executor.ex` | Additive/selective apply of a reconcile diff (reuse, create-missing, never delete/rename). |

### Policy, themes, input helpers

| Module | File | Role |
|---|---|---|
| `DevIDE.Terminals.Boundary` | `boundary.ex` | Raw-admission gate: `raw_allowed?/2`/`authorize_raw/2` → `Policy.can_use_raw_terminal?/1` + `Runs.Ledger`; `interactive_command_ids/0`, `format_reason/1`. |
| `DevIDE.Terminals.ModePolicy` | `mode_policy.ex` | Pure mode resolver; everything is `:raw`; `tmux_mutations_enabled?/1` true only for `:shell`. |
| `DevIDE.Terminals.Theme` / `.Builtins` | `theme.ex`, `theme/builtins.ex` | Renderer-first themes (Catppuccin presets + `ghostty.conf` loading) and OSC 10/11/12/4 rewrite helpers for pane query responses. |
| `DevIDE.Terminals.ClipboardPaste` | `clipboard_paste.ex` | Saves pasted/dropped images/files into `.devide/clipboard/` and pastes the path; git-exclude maintenance. |
| `DevIDE.Terminals.GhosttySnapshot` | `ghostty_snapshot.ex` | Writes `Ghostty.Terminal` HTML/plain/VT grid dumps to `:ghostty_snapshot_dir` (kept out of the LiveView for the no-apply boundary guard). |
| `DevIDE.Terminals.InspectionCommands` | `inspection_commands.ex` | Read-only governed argv registry (`pwd`/`ls`/`git status`/`rg`/`tidewave`/`preview …`) run in the workspace root with bounded output. |
| `DevIDE.Terminals.Workflows` | `workflows.ex` | Repo-scoped Warp-subset workflow launchers; renders+revalidates argv, encodes a `workflow:` command id (never persists executable argv). |
| `DevIDE.Terminals.WorkspaceAccessCache` | `workspace_access_cache.ex` | 60 s ETS cache of `Workspaces.get/2` to avoid manager round-trips on reconnect. |

## Data flow / lifecycle

Raw shell attach (the default `:session_owner` path):

```
caller pid (LiveView PaneWorker / channel)
  └─ SessionOwner.attach(workspace_id, %Info{kind: :shell}, mode: :raw, loc: ..., workspace_key: ...)
       ├─ ensure_started → DynamicSupervisor under Terminals.Registry (owner_key/1)
       ├─ Process.monitor(subscriber); record in subscribers/refs maps
       └─ ensure_attachment → Attachment.open(:shell)
            └─ GhosttyRawAdapter.ensure_raw_shell → Session.ensure_started({ws, sid, loc})
                 └─ :exec.run("tmux new-session -A -s devide_<ws>_<sid> ...")  ← persistence boundary
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
- Idle GC: `TmuxJanitor` kills a `devide_*` session after its last LiveView
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
  `InspectionCommands.run/3`, `Workflows.resolve_line/2`,
  `Theme` client bundle + OSC rewrites, `Telemetry` counters.

Registries/supervisors: `DevIDE.Terminals.Registry` (sessions + owners +
directory), `DevIDE.Terminals.Supervisor` (DynamicSupervisor),
`DevIDE.Terminals.TopologyRegistry` / `TopologySupervisor` (watcher pool),
`DevIDE.TaskSupervisor` (off-process tmux resize).

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
- **`devide_`-prefix guard.** Both janitors refuse to kill any session whose
  name does not start with `devide_`; `TmuxWindowJanitor` additionally spares
  named, active, or busy (non-shell) windows/sessions. (See MEMORY "Devbox
  process safety".)
- **Test tmux sandboxing.** In `:test`, set `:tmux_server_label` so every tmux
  call targets `-L devide_test` and cannot touch the live devbox server. The
  adapter is selected from `:dev_ide` `:tmux_adapter` (see
  `docs/tmux_control_plane.md` for the two-key split).
- **Tab list stability.** Only identity-stable fields belong in
  `metadata.windows` (it feeds `Compose.stable_hash/1`); volatile activity and
  pane membership go in non-hashed metadata so they don't re-broadcast every
  poll. The `quiet?` boolean (`Activity`) is the deliberate exception.
- **`SessionDirectory` slow reads run off the GenServer.** `refresh_now/2` does
  the tmux read in the caller; the GenServer only stores+broadcasts, so cheap
  `tabs/2` reads from other viewers never queue behind a slow enumeration.
- **`Boundary` is the only admission call site.** Raw admission policy itself
  lives in `DevIDE.Policy` (outside this subsystem); the verdict is recorded as
  `run.session_attached` / `run.session_denied` in `Runs.Ledger`.

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
