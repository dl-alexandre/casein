# Code cleanup backlog

> Actionable **code** findings surfaced while documenting the subsystems
> (2026-06-20). These are distinct from documentation gaps — each is a change to
> the code, not the docs. Sourced from the divergences in
> [`coverage_map.md`](coverage_map.md#gaps--divergences); line numbers are
> as-reported and worth re-confirming before editing. Ordered by confidence /
> value, not urgency. None of these block anything.
>
> **2026-07-04 accuracy pass:** A1, A3, C1, D1, D2 were found to already be
> resolved or incorrect on re-inspection. Notes added inline. Items B1 and A4
> remain open.

## A. Dead / inert code (safe to remove)

| # | Finding | Location | Action |
|---|---------|----------|--------|
| ~~A1~~ | ~~`Export.Sanitizer.redact_text/1` is public, `@doc`'d and `@spec`'d but has **zero callers** in `lib/`.~~ | ~~`lib/casein/export/sanitizer.ex:34-49`~~ | **Resolved** — has multiple callers: `workspace_status.ex` (via `redact_text_values/1`), `mcp_audit.ex`, and `agent_prompt_sender.ex`. Finding was inaccurate. |
| A2 | Export emits permanently-inert fields: `WorkspaceStatus.active_run_summary/1` always returns `nil`, `run_artifacts/1` always `[]` (retired with the delegated-execution stack). | `lib/casein/export/workspace_status.ex` — `active_run_summary/1` at `defp active_run_summary`, `run_artifacts/1` | Intentionally kept: both are live in the payload / UI (`run_events.ex` calls `run_artifacts/1`). The comment in the source documents the retirement. No action needed unless the feature returns. |
| ~~A3~~ | ~~`runtimes.ex:list_agent_worktrees/1` filters a `"failed"` status that no transition in `StateMachine.statuses/0` produces; `Runtime.failure_reason` is likewise unreachable.~~ | ~~`lib/casein/runtimes.ex` (+ `runtimes/state_machine.ex`)~~ | **Resolved/inaccurate** — `list_agent_worktrees/1` only rejects `"cleaned"` and `"expired"`, which are the real terminal statuses. `failure_reason` is set in `expire_runtime/2` and used in the payload, ecto adapter, and preview server. No dead code. |
| A4 | `CaseinCore` convenience facade (`git_inspect/1`, `exec_run/3`, `mcp_tool/3`) is unused — callers reach `GitCtl.Inspector` / `McpCtl.Tool` directly. | `casein_core/lib/casein_core.ex` | Keep as documented sugar, or delete if it will never be the call path. |

## B. Duplication to consolidate

| # | Finding | Location | Action |
|---|---------|----------|--------|
| B1 | `ExecCtl.Port` (erlexec spawn + proxy + monitor) has **no production caller** — only tests and the unused `CaseinCore.exec_run/3`. The app's real executor `Casein.Commands.spawn/3` reimplements the same plumbing inline. | `casein_core/lib/exec_ctl/port.ex` vs `lib/casein/commands.ex` | Point `Casein.Commands.spawn/3` at `ExecCtl.Port`, deleting the duplicate plumbing — or drop `ExecCtl.Port` if the app's copy must own it. |

## C. Contract / spec mismatches

| # | Finding | Location | Action |
|---|---------|----------|--------|
| ~~C1~~ | ~~Behaviour callback type is wrong: `@callback directory_inventory/0` is typed `… \| {:error, term()}`, but the impl `TmuxCtl.Client.directory_inventory/0` returns `… \| :error` (bare atom).~~ | ~~`lib/tmux_ctl/adapter.ex:25`~~ | **Already fixed** — the callback in `adapter.ex` already reads `\| :error` (bare atom), matching the impl and spec. |

## D. Stale comments / "future" markers (code says future, reality is present)

| # | Finding | Location | Action |
|---|---------|----------|--------|
| ~~D1~~ | ~~`Casein.Audit` / `MemoryAdapter` / `Event` `@moduledoc`s describe the Ecto adapter as future work ("M11", "Swap with an Ecto-backed adapter in M11"), but `EctoAdapter` is fully implemented and the prod default.~~ | ~~`lib/casein/audit/audit.ex:2-8`, `memory_adapter.ex:1-4`, `audit/event.ex:2-5`~~ | **Already fixed** — all three moduledocs are in present tense. No stale M11 reference found. |
| ~~D2~~ | ~~Inline `NOTE: in-flight refactor adds ChannelAuth.sign_terminal_capability/3` — that function already exists and is already called.~~ | ~~`lib/casein_web/live/workspace_live/show.ex:164`~~ | **Already fixed** — no such NOTE comment exists in show.ex. |
| D3 | `docs/terminal.md` still narrates the retired `:ghostty_pty`-per-pane raw path and smallest-viewer resize; prod defaults to `SessionOwner`/`Attachment` and focused-viewer resize. (Doc fix, but the docs-win call is to update the narrative.) | `docs/terminal.md` vs `terminals/pane_worker.ex:113`, `session_owner.ex` | Refresh `terminal.md` to the `:session_owner` reality (see `docs/subsystems/terminals.md`). |

## E. Known-incomplete (documented, no action unless prioritised)

- `Annotation.preview_id` is intentionally a nullable `:binary_id`, **not** a
  foreign key, because the preview persistence model has not landed.
  (`lib/casein/annotations/annotation.ex:30`.)
- `Casein.Runs.Status` retains legacy delegated-execution statuses (`expired`,
  `abandoned`, `assignment_id`/`protocol`/`safe_action_id`) for
  backward-compatible timelines, with no doc explaining the retention.
  (`runs/status.ex:12-16,98-105`; `runs/ledger.ex:226-231`.)
