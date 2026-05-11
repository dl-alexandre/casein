# Local-mode truth-table audit

> Grounded assessment of the current `lib/` against the seven Local-mode
> rows of [`product.md`](product.md) §12 (demo truth table).
>
> Date of audit: 2026-05-11 · against commit `6d1938c`.
> Re-run this audit when significant runtime changes land.
>
> Status legend: `works` · `partial` · `stub` · `missing` · `uncertain`.

## Summary

| # | Row                  | Status     | Where it lives                                                                 |
|---|----------------------|------------|--------------------------------------------------------------------------------|
| 1 | attach               | **partial**| `router.ex:24-25`, `workspace_live/show.ex:25-43`, `terminal_channel.ex:20-37` |
| 2 | allowed run          | **works**  | `policy.ex:59-73`, `commands.ex:10-15`, `rerun.ex:22-37`                       |
| 3 | denied run           | **works**  | `policy.ex:59-73`, `audit.ex:42-51`, `workspace_controller.ex:34-44`           |
| 4 | disconnect           | **works**  | `terminal_channel.ex:54-62`, `session.ex:116-122`, `session.ex:153-160`        |
| 5 | resume               | **partial**| `session.ex:46-56`, `terminal_channel.ex:20-37`                                |
| 6 | audit inspect        | **works**  | `audit.ex:17-34`, `audit/event.ex:1-43`, `workspace_controller.ex:202-207`     |
| 7 | cross-host attach    | **missing**| `runtimes.ex:56`, `runtimes/host.ex:1-28`                                       |

**Headline:** 3 of 7 rows fully work today. 3 are partial (the runtime
exists; the cockpit surface is missing or rough). 1 is missing
end-to-end. The runtime side of Local mode is in better shape than the
cockpit side.

## Row-by-row

### 1. attach — *partial*

The mechanics are there: a route, a LiveView, a channel that joins a
tmux session. What's missing is the **connection picker**
([`product.md`](product.md) §9.1). Today the LiveView hard-binds to
"the local workspace from manager" — there is no "which host? which
workspace?" entry screen, so step one of every demo is silently
skipped.

- Route: [`lib/dev_ide_web/router.ex:24-25`](../lib/dev_ide_web/router.ex)
- LiveView: [`lib/dev_ide_web/live/workspace_live/show.ex:25-43`](../lib/dev_ide_web/live/workspace_live/show.ex)
- Channel: [`lib/dev_ide_web/channels/terminal_channel.ex:20-37`](../lib/dev_ide_web/channels/terminal_channel.ex)

**Gap:** build a picker that lists workspaces (and, eventually, hosts —
see row 7) and routes to `workspace_live/show` on selection. The data
already exists in `Runtimes.list_hosts/0` and the workspace registry.

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

### 5. resume — *partial*

Reattach works — `Session.ensure_started` uses `tmux -A` to find the
existing session, and the channel's join handler re-subscribes. What
**does not** work: scrollback recovery. The reattached client sees
only *future* output, not what happened during the disconnect. From
the operator's perspective this looks like row 4 "the work continued
running" but row 5 "I can see what happened" is incomplete.

- [`lib/dev_ide/terminals/session.ex:46-56`](../lib/dev_ide/terminals/session.ex) (`ensure_started`)
- [`lib/dev_ide_web/channels/terminal_channel.ex:20-37`](../lib/dev_ide_web/channels/terminal_channel.ex) (rejoin path)

**Gap:** capture the tmux pane's scrollback (`tmux capture-pane -p
-S -<N>`) at disconnect or on rejoin, and replay it to the client
before live output resumes. This is the smallest change that delivers
the "welcome back, here's the 47s you missed" UX from
`ui-iterations-v3/05-remote-resume.html`.

### 6. audit inspect — *works (API) / partial (UI)*

The API endpoint `/workspaces/:id/audit` returns up to 200 recent
events. Every gate decision is recorded with reason, argv, and
workspace context. The data is there.

What's missing is the **evidence drawer** ([`product.md`](product.md)
§9.4). The current LiveView dumps audit rows as plain text in
`show.ex`. There's no single time-ordered stream interleaving allows,
denies, mode changes, and recoveries; there's no toggle to open it
beside the terminal.

- [`lib/dev_ide/audit.ex:17-34`](../lib/dev_ide/audit.ex)
- [`lib/dev_ide/audit/event.ex:1-43`](../lib/dev_ide/audit/event.ex)
- [`lib/dev_ide_web/controllers/api/workspace_controller.ex:202-207`](../lib/dev_ide_web/controllers/api/workspace_controller.ex)

### 7. cross-host attach — *missing*

`Runtimes.list_hosts/0`, `Runtimes.register_host/1`, and the `Host`
struct are fully implemented. None of it is reachable from the UI.
Every code path that calls `request_runtime` passes
`host_id: "local"` ([`runtimes.ex:64`](../lib/dev_ide/runtimes.ex)).

This row is `missing` because the cockpit cannot exercise the
runtime; the runtime itself is ready.

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

1. **Scrollback replay on reattach.** Smallest change, biggest user
   impact. Closes row 5. *Touches:* `Session`, `terminal_channel`.
2. **Connection picker + workspace list as first screen.** Closes
   row 1 and unblocks row 7. *Touches:* a new LiveView, router,
   `Runtimes.list_hosts`.
3. **Evidence drawer beside the terminal.** Renders the existing
   audit API as the time-ordered stream from §9.4. Closes row 6 on
   the UI side. *Touches:* `workspace_live/show.heex`, a new component.
4. **Host-aware attach.** Wire the picker's selected host through to
   `request_runtime/_`. Closes row 7. *Touches:* `Runtimes`,
   `terminal_channel` join params.

After those four, Local-mode is `works` across the board. Then the
audit can be re-run against the Remote and Fleet columns, where the
gaps will be more structural (runtime-side, not cockpit-side).
