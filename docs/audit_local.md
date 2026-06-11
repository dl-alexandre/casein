# Local-mode truth-table audit

> Grounded assessment of the current `lib/` against the seven Local-mode
> rows of [`product.md`](product.md) §12 (demo truth table).
>
> Date of audit: 2026-05-11 · last updated this commit.
> Re-run this audit when significant runtime changes land.
>
> Status legend: `works` · `partial` · `stub` · `missing` · `uncertain`.

## Summary

| # | Row                  | Status     | Where it lives                                                                 |
|---|----------------------|------------|--------------------------------------------------------------------------------|
| 1 | attach               | **works**  | `router.ex:24-25`, `workspace_live/index.ex` (picker), `workspace_live/show.ex:25-43`, `terminal_channel.ex:20-37` |
| 2 | allowed run          | **works**  | `policy.ex:59-73`, `commands.ex:10-15`, `rerun.ex:22-37`                       |
| 3 | denied run           | **works**  | `policy.ex:59-73`, `audit.ex:42-51`, `workspace_controller.ex:34-44`           |
| 4 | disconnect           | **works**  | `terminal_channel.ex:54-62`, `session.ex:116-122`, `session.ex:153-160`        |
| 5 | resume               | **works**  | `session.ex:26,114,123-133,148-150,164-178` (output buffer + replay-on-subscribe) |
| 6 | audit inspect        | **works**  | `audit.ex:17-34`, `audit/event.ex:1-43`, `workspace_live/show/run_panel.ex`, Agents panel |
| 7 | cross-host attach    | **partial**| picker carries non-local `?host=`, show gates non-local (§11); runtime resolver still local-only |

**Headline:** 6 of 7 rows fully work today. 1 is partial (cross-host
attach — the cockpit is host-aware end-to-end; the runtime resolver
honors only `local` and politely refuses other hosts per §11). All
cockpit-side punch-list items are closed; remaining work is
runtime-side and requires a second DevIDE instance to verify.

## Row-by-row

### 1. attach — *works*

The `/workspaces` route now renders a **connection picker**
([`product.md`](product.md) §9.1): a host-grouped list of
workspaces, each host carrying a derived mode badge
(local / remote / fleet — never declared, always computed from
capabilities per §11) and a capability chip strip. When no host has
been registered, a synthetic local host is shown so the picker
always has something honest to display (`hide rather than mock` is
honored — the synthetic host advertises only capabilities the local
runtime actually has).

- Route: [`lib/dev_ide_web/router.ex:24-25`](../lib/dev_ide_web/router.ex)
- Picker: [`lib/dev_ide_web/live/workspace_live/index.ex`](../lib/dev_ide_web/live/workspace_live/index.ex) (`build_hosts/1`, `derive_mode/1`, `synthetic_local_host/0`)
- Workspace LiveView: [`lib/dev_ide_web/live/workspace_live/show.ex:25-43`](../lib/dev_ide_web/live/workspace_live/show.ex)
- Channel: [`lib/dev_ide_web/channels/terminal_channel.ex:20-37`](../lib/dev_ide_web/channels/terminal_channel.ex)
- Test: [`test/dev_ide_web/live/workspace_live_test.exs`](../test/dev_ide_web/live/workspace_live_test.exs) ("renders the picker as a host-grouped list with a derived mode badge")

### 2. allowed run — *works*

End-to-end. Keystrokes flow `xterm → terminal_channel → Session →
tmux pane`; output flows back the same way. The policy gate fires
before exec via `Policy.can_run_command?`. This is the row the rest
of the truth table depends on, and it's solid.

- [`lib/dev_ide/policy.ex:59-73`](../lib/dev_ide/policy.ex) (`can_run_command?/2`)
- [`lib/dev_ide/commands.ex:10-15`](../lib/dev_ide/commands.ex) (allowlist)
- [`lib/dev_ide/commands/rerun.ex:22-37`](../lib/dev_ide/commands/rerun.ex)
- [`lib/dev_ide_web/channels/terminal_channel.ex:40-42`](../lib/dev_ide_web/channels/terminal_channel.ex)

### 3. denied run — *works*

Policy gate refuses non-allowlisted argv, returns 403/400 on the API
path, and emits an audit event via `Audit.emit_decision/4`. Both the
allow and deny paths converge on the same audit emitter, which is why
row 6 also works.

- [`lib/dev_ide/policy.ex:59-73`](../lib/dev_ide/policy.ex)
- [`lib/dev_ide/audit.ex:42-51`](../lib/dev_ide/audit.ex) (`emit_decision/4`)
- [`lib/dev_ide_web/controllers/api/workspace_controller.ex:34-44`](../lib/dev_ide_web/controllers/api/workspace_controller.ex)

### 4. disconnect — *works* (and quietly important)

`Session` is a GenServer that monitors the erlexec ospid, not the
websocket. When the channel goes down (`:DOWN` at
[`session.ex:153-160`](../lib/dev_ide/terminals/session.ex)), the
subscriber is cleared but tmux keeps running. This is what makes FP-2
(*sessions are durable by default*) real, at least for Local mode.

### 5. resume — *works* (closed `feff22a`)

`Session` retains a 64KB rolling tail of PTY output in state. On
subscribe, the buffer is sent to the new subscriber as one
`{:term_data, ref, buffer}` message before live forwarding resumes —
xterm.js renders it as if it had been live. Buffering continues
whether or not a subscriber is attached, so the operator who closes
the tab and reopens it sees what happened while they were gone.

- [`lib/dev_ide/terminals/session.ex:26`](../lib/dev_ide/terminals/session.ex) (`@buffer_bytes`)
- [`lib/dev_ide/terminals/session.ex:123-133`](../lib/dev_ide/terminals/session.ex) (`subscribe` replay)
- [`lib/dev_ide/terminals/session.ex:148-178`](../lib/dev_ide/terminals/session.ex) (`ingest/2`, `append_buffer/3`)
- [`test/dev_ide/terminals/session_test.exs`](../test/dev_ide/terminals/session_test.exs) (`"replays buffered output to a re-attaching subscriber"`)

### 6. audit inspect — *works*

The data layer is there (every gate decision recorded via
`Audit.emit_decision/2`; API endpoint at
`/workspaces/:id/audit`). The cockpit surface is contextual rather
than a standalone audit drawer: the Run tab renders run-ledger events,
the Agents panel renders live MCP activity, and the full per-workspace
audit stream remains queryable through the API.

- [`lib/dev_ide/audit.ex:17-34`](../lib/dev_ide/audit.ex)
- [`lib/dev_ide/audit/event.ex:1-43`](../lib/dev_ide/audit/event.ex)
- [`lib/dev_ide_web/live/workspace_live/show/run_panel.ex`](../lib/dev_ide_web/live/workspace_live/show/run_panel.ex)
- [`lib/dev_ide_web/live/workspace_live/show/agents_panel.ex`](../lib/dev_ide_web/live/workspace_live/show/agents_panel.ex)

### 7. cross-host attach — *partial* (cockpit done; runtime gap)

The cockpit is now host-aware end-to-end:

- The picker renders one row per registered host (synthetic local
  host when none registered).
- Picker links omit the redundant local host and carry non-local host ids as
  `/workspaces/:id?host=<host>`.
- The show LiveView reads `host` and runs a gate before
  `Workspaces.get/1`. Unknown / non-local hosts are refused
  politely with a flash and a redirect back to the picker — §11
  "hide rather than mock" honored at the LiveView boundary.

What remains for true row-7 behavior: `Workspaces.get/1` and the
terminal channel join still target the local manager regardless of
host id. Real cross-host attach needs the workspace resolver to
route by `host_id`, and the channel to attach against the runtime
registered for that host. Both require a second DevIDE instance to
verify end-to-end.

- [`lib/dev_ide_web/live/workspace_live/index.ex`](../lib/dev_ide_web/live/workspace_live/index.ex) (picker links carry host id)
- [`lib/dev_ide_web/live/workspace_live/show.ex`](../lib/dev_ide_web/live/workspace_live/show.ex) (`ensure_local_host/1`, `with` gate in `mount/3`)
- Test: [`test/dev_ide_web/live/workspace_live_test.exs`](../test/dev_ide_web/live/workspace_live_test.exs) ("show LiveView refuses non-local hosts politely")

## Surprises

1. **Audit is wired but invisible.** All the data, no surface. Row 6
   is one component away from `works/works`.
2. **Host infrastructure is built but unused.** Row 7 + the connection
   picker (row 1) are the same cockpit change. They light up together.
3. **Session reattach is implicit, not buffered.** Row 4 is doing more
   work than row 5 gets credit for. A scrollback replay is the
   smallest unlock.
4. **Policy gate is consistently early.** Every entry point (LiveView,
   API, future runner) goes through `Policy.can_run_command?` before
   exec. This is the cleanest part of the codebase and the reason
   rows 2–3 and 6 work at all.

## Punch list (ordered by leverage)

1. ~~**Scrollback replay on reattach.**~~ ✅ done `feff22a`.
2. ~~**Connection picker + workspace list as first screen.**~~ ✅ done `ba35717`.
3. ~~**Audit inspection surface.**~~ ✅ contextualized in Run/Agents/API.
4. ~~**Host-aware attach (cockpit side).**~~ ✅ done (this commit).

**All cockpit-side punch-list items are closed.** The cockpit is
host-aware, the runtime is honest about its limits, and §11 is
enforced at the boundary. Remaining work for true row-7 / full
cross-host attach is runtime-side:

- `Workspaces.get/1` accepts a `host_id` and routes the lookup
- Terminal channel join accepts and validates `host_id`
- An HTTP transport for cross-host workspace resolution (likely
  reusing the existing JX runner protocol shape)

These changes require a second DevIDE instance to verify
end-to-end and are best tackled as a Remote-mode audit pass
(separate doc) rather than continuing the Local-mode audit. Then
the audit can be re-run against the Remote and Fleet columns, where
the gaps will be more structural (runtime-side, not cockpit-side).
