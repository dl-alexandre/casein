# Runtime truth-table audit

> Grounded assessment of the current `lib/` against the core
> behaviors a single-runtime DevIDE cockpit promises: attach, run,
> disconnect, resume, and audit.
>
> Date of audit: 2026-05-11 · last updated this commit.
> Re-run this audit when significant runtime changes land.
>
> Status legend: `works` · `partial` · `stub` · `missing` · `uncertain`.

## Summary

| # | Row           | Status     | Where it lives                                                                 |
|---|---------------|------------|--------------------------------------------------------------------------------|
| 1 | attach        | **works**  | `router.ex`, `workspace_live/index.ex` (picker), `workspace_live/show.ex`, `terminal_channel.ex` |
| 2 | allowed run   | **works**  | `policy.ex` (`can_run_command?/1`), `commands.ex` (allowlist)                  |
| 3 | denied run    | **works**  | `policy.ex`, `audit.ex` (`emit_decision/2`)                                    |
| 4 | disconnect    | **works**  | `terminals/session.ex` (`:DOWN` handler)                                       |
| 5 | resume        | **works**  | `terminals/session.ex` (output buffer + replay-on-subscribe)                   |
| 6 | audit inspect | **works**  | `audit.ex`, `audit/event.ex`, Run ledger panel, Agents panel                   |

**Headline:** every core row works today. The cockpit attaches a
durable raw terminal to a workspace, the policy gate fires before
exec, and every decision lands in the audit log.

## Row-by-row

### 1. attach — *works*

The `/workspaces` route renders a workspace picker; selecting a
workspace opens the show LiveView, which joins the terminal channel
and attaches a server-side PTY (tmux + Ghostty).

- Route: [`lib/dev_ide_web/router.ex`](../lib/dev_ide_web/router.ex)
- Picker: [`lib/dev_ide_web/live/workspace_live/index.ex`](../lib/dev_ide_web/live/workspace_live/index.ex)
- Workspace LiveView: [`lib/dev_ide_web/live/workspace_live/show.ex`](../lib/dev_ide_web/live/workspace_live/show.ex)
- Channel: [`lib/dev_ide_web/channels/terminal_channel.ex`](../lib/dev_ide_web/channels/terminal_channel.ex)

Raw-terminal admission is a server-side policy decision via
`Policy.can_use_raw_terminal?/1` — the browser never sources argv.

### 2. allowed run — *works*

Keystrokes flow `xterm → terminal_channel → Session → tmux pane`;
output flows back the same way. The policy gate fires before exec via
`Policy.can_run_command?`. This is the row the rest of the truth table
depends on, and it's solid.

- [`lib/dev_ide/policy.ex`](../lib/dev_ide/policy.ex) (`can_run_command?/1`)
- [`lib/dev_ide/commands.ex`](../lib/dev_ide/commands.ex) (`allowlist/0`, backed by `commands/allowlist.ex`)
- [`lib/dev_ide_web/channels/terminal_channel.ex`](../lib/dev_ide_web/channels/terminal_channel.ex)

### 3. denied run — *works*

The policy gate refuses non-allowlisted argv and emits an audit event
via `Audit.emit_decision/2`. Both the allow and deny paths converge on
the same audit emitter, which is why row 6 also works.

- [`lib/dev_ide/policy.ex`](../lib/dev_ide/policy.ex)
- [`lib/dev_ide/audit.ex`](../lib/dev_ide/audit.ex) (`emit_decision/2`)

### 4. disconnect — *works* (and quietly important)

`Session` is a GenServer that monitors the erlexec ospid, not the
websocket. When the channel goes down (`:DOWN` handler in
[`session.ex`](../lib/dev_ide/terminals/session.ex)), the subscriber is
cleared but tmux keeps running. This is what makes **FP-2** (*sessions
are durable by default*) real.

### 5. resume — *works* (closed `feff22a`)

`Session` retains a 64KB rolling tail of PTY output in state. On
subscribe, the buffer is sent to the new subscriber as one
`{:term_data, ref, buffer}` message before live forwarding resumes —
xterm.js renders it as if it had been live. Buffering continues whether
or not a subscriber is attached, so the operator who closes the tab and
reopens it sees what happened while they were gone.

- [`lib/dev_ide/terminals/session.ex`](../lib/dev_ide/terminals/session.ex) (`@buffer_bytes`, `subscribe` replay, `ingest/2`, `append_buffer/3`)
- [`test/dev_ide/terminals/session_test.exs`](../test/dev_ide/terminals/session_test.exs) (`"replays buffered output to a re-attaching subscriber"`)

### 6. audit inspect — *works*

The data layer is there (every gate decision recorded via
`Audit.emit_decision/2`). The cockpit surface is contextual rather than
a standalone audit drawer: the Run tab renders run-ledger events
([`Runs.Ledger`](../lib/dev_ide/runs/ledger.ex)), live MCP activity is
recorded via [`Agents.MCPAudit`](../lib/dev_ide/agents/mcp_audit.ex),
and the full per-workspace audit stream remains queryable.

- [`lib/dev_ide/audit.ex`](../lib/dev_ide/audit.ex)
- [`lib/dev_ide/audit/event.ex`](../lib/dev_ide/audit/event.ex)
- [`lib/dev_ide_web/live/workspace_live/show/run_panel.ex`](../lib/dev_ide_web/live/workspace_live/show/run_panel.ex)

## Surprises

1. **Audit is wired everywhere it matters.** Every entry point converges
   on `Audit.emit_decision/2`; the Run ledger reads
   from the same storage.
2. **Session reattach does more than it looks.** The `:DOWN` handler
   (row 4) and the in-state buffer (row 5) together make disconnect a
   normal event, not an error state.
3. **The policy gate is consistently early.** Every entry point goes
   through `Policy.can_run_command?` (and raw-terminal attaches through
   `Policy.can_use_raw_terminal?`) before exec. This is the cleanest part
   of the codebase and the reason rows 2–3 and 6 work at all.
