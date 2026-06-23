# Code cleanup backlog

> Actionable **code** findings surfaced while documenting the subsystems
> (2026-06-20). These are distinct from documentation gaps — each is a change to
> the code, not the docs. Sourced from the divergences in
> [`coverage_map.md`](coverage_map.md#gaps--divergences); line numbers are
> as-reported and worth re-confirming before editing. Ordered by confidence /
> value, not urgency. None of these block anything.

## A. Dead / inert code (safe to remove)

| # | Finding | Location | Action |
|---|---------|----------|--------|
| A1 | `Export.Sanitizer.redact_text/1` is public, `@doc`'d and `@spec`'d but has **zero callers** in `lib/`. | `lib/dev_ide/export/sanitizer.ex:34-49` | Remove, or wire it into the egress-redaction path it claims to be part of. |
| A2 | Export emits permanently-inert fields: `WorkspaceStatus.active_run_summary/1` always returns `nil`, `run_artifacts/1` always `[]` (retired with the delegated-execution stack). | `lib/dev_ide/export/workspace_status.ex:248,324` | Drop the `nil`/`[]` fields from the export payload, or restore real values if the feature returns. |
| A3 | `runtimes.ex:list_agent_worktrees/1` filters a `"failed"` status that no transition in `StateMachine.statuses/0` produces; `Runtime.failure_reason` is likewise unreachable. | `lib/dev_ide/runtimes.ex` (+ `runtimes/state_machine.ex`) | Remove the dead `"failed"` branch and `failure_reason`, or add the missing transition. |
| A4 | `DevIdeCore` convenience facade (`git_inspect/1`, `exec_run/3`, `mcp_tool/3`) is unused — callers reach `GitCtl.Inspector` / `McpCtl.Tool` directly. | `dev_ide_core/lib/dev_ide_core.ex` | Keep as documented sugar, or delete if it will never be the call path. |

## B. Duplication to consolidate

| # | Finding | Location | Action |
|---|---------|----------|--------|
| B1 | `ExecCtl.Port` (erlexec spawn + proxy + monitor) has **no production caller** — only tests and the unused `DevIdeCore.exec_run/3`. The app's real executor `DevIDE.Commands.spawn/3` reimplements the same plumbing inline. | `dev_ide_core/lib/exec_ctl/port.ex` vs `lib/dev_ide/commands.ex` | Point `DevIDE.Commands.spawn/3` at `ExecCtl.Port`, deleting the duplicate plumbing — or drop `ExecCtl.Port` if the app's copy must own it. |

## C. Contract / spec mismatches

| # | Finding | Location | Action |
|---|---------|----------|--------|
| C1 | Behaviour callback type is wrong: `@callback directory_inventory/0` is typed `… | {:error, term()}`, but the impl `TmuxCtl.Client.directory_inventory/0` returns `… | :error` (bare atom). The client's own `@spec` is correct; the behaviour callback is not. | `lib/tmux_ctl/adapter.ex:25` | Fix the `@callback` to `… | :error` to match the impl + spec. |

## D. Stale comments / "future" markers (code says future, reality is present)

| # | Finding | Location | Action |
|---|---------|----------|--------|
| D1 | `DevIDE.Audit` / `MemoryAdapter` / `Event` `@moduledoc`s describe the Ecto adapter as future work ("M11", "Swap with an Ecto-backed adapter in M11"), but `EctoAdapter` is fully implemented and the prod default. | `lib/dev_ide/audit/audit.ex:2-8`, `memory_adapter.ex:1-4`, `audit/event.ex:2-5` | Update the moduledocs to present tense. |
| D2 | Inline `NOTE: in-flight refactor adds ChannelAuth.sign_terminal_capability/3` — that function already exists and is already called. | `lib/dev_ide_web/live/workspace_live/show.ex:164` (fn at `channel_auth.ex:59`, called `show.ex:1812`) | Delete the stale NOTE. |
| D3 | `docs/terminal.md` still narrates the retired `:ghostty_pty`-per-pane raw path and smallest-viewer resize; prod defaults to `SessionOwner`/`Attachment` and focused-viewer resize. (Doc fix, but the docs-win call is to update the narrative.) | `docs/terminal.md` vs `terminals/pane_worker.ex:113`, `session_owner.ex` | Refresh `terminal.md` to the `:session_owner` reality (see `docs/subsystems/terminals.md`). |

## E. Known-incomplete (documented, no action unless prioritised)

- `Annotation.preview_id` is intentionally a nullable `:binary_id`, **not** a
  foreign key, because the preview persistence model has not landed.
  (`lib/dev_ide/annotations/annotation.ex:30`.)
- `DevIDE.Runs.Status` retains legacy delegated-execution statuses (`expired`,
  `abandoned`, `assignment_id`/`protocol`/`safe_action_id`) for
  backward-compatible timelines, with no doc explaining the retention.
  (`runs/status.ex:12-16,98-105`; `runs/ledger.ex:226-231`.)
