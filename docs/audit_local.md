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
| 6 | audit inspect        | **works**  | `audit.ex:17-34`, `audit/event.ex:1-43`, `workspace_live/show.ex` (evidence drawer) |
| 7 | cross-host attach    | **missing**| `runtimes.ex:56`, `runtimes/host.ex:1-28`                                       |

**Headline:** 6 of 7 rows fully work today. 1 is missing end-to-end
(cross-host attach — the cockpit is now ready; the gap is
runtime-side workspace resolution across hosts).

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

The data layer was already there (every gate decision recorded via
`Audit.emit_decision/2`; API endpoint at
`/workspaces/:id/audit`). The remaining gap was the cockpit surface,
and that now exists: an **Evidence drawer** in the workspace
LiveView, opened from the header, rendering events as a single
time-ordered stream with color-coded verbs (allow / deny / mode /
other). Deny count surfaces as a small red badge on the trigger so
refusals are noticeable without being advertised.

- [`lib/dev_ide/audit.ex:17-34`](../lib/dev_ide/audit.ex)
- [`lib/dev_ide/audit/event.ex:1-43`](../lib/dev_ide/audit/event.ex)
- [`lib/dev_ide_web/live/workspace_live/show.ex`](../lib/dev_ide_web/live/workspace_live/show.ex) (`render_audit_drawer/1`, `audit_drawer:toggle/refresh/close`)

### 7. cross-host attach — *missing* (cockpit ready; runtime gap)

The picker now renders multiple hosts when more than one is
registered. What still doesn't work end-to-end: the workspace
lookup at `Workspaces.get/1` goes through the local manager
regardless of which host's row was clicked. Real cross-host attach
needs the workspace resolver to route by `host_id`, and the
terminal channel join to attach against the runtime registered for
that host — not the local tmux.

This is no longer a cockpit blocker; the §9.1 picker is in place
and ready to send a `host_id` through. The runtime-side resolver
is the next gap.

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
2. ~~**Connection picker + workspace list as first screen.**~~ ✅ done (this commit).
3. ~~**Evidence drawer beside the terminal.**~~ ✅ done `7f15981`.
4. **Host-aware attach.** Resolver routes workspace lookup by
   `host_id` and terminal channel attaches against the runtime
   registered for that host. Closes row 7. *Touches:*
   `Workspaces.get`, `terminal_channel` join params, `Runtimes`.

After item 4 lands, Local-mode is `works` across the board. Then
the audit can be re-run against the Remote and Fleet columns, where
the gaps will be more structural (runtime-side, not cockpit-side).
