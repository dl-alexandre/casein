# Headless Jido lifecycle projection

[#1016](https://github.com/dl-alexandre/casein/issues/1016) (parent
[#1012](https://github.com/dl-alexandre/casein/issues/1012)). Connects Jido
pod and typed action events to Casein's existing agent-state, activity,
audit, inbox, clarification, and result surfaces.

## Boundary

- **Does not change** the #1014 pod or #1015 action contracts.
- **Casein** remains authoritative for identity, human input, cancellation,
  audit, and verified completion.
- **No fake pane.** Headless workers have `headless: true` and no `pane_id`.
  Missing tmux output is not idle.

## Envelope

Every persisted event carries workspace, task, attempt, worker, action,
correlation, sequence, timestamp, and a redacted payload. Secrets, prompts,
code, command/keys, and tool I/O are dropped before persist and notification.

## Truthfulness

- A worker is `completed` only when the pod records that terminal state.
- `report_result` is evidence of a claimed result, never verified completion.
- OpenCode `:done` is a finished turn (`:done`), not `:completed`.
- Human resolve requires `actor_kind: :human`. A worker cannot self-approve.
- Evidence is `current`, `partial`, or `stale` after later progress.

## Surfaces

| Surface | Role |
|---------|------|
| `AgentEvents` | Durable stream `jido:<attempt>` with source-id dedupe |
| `Activity` | Live feed (`source: :jido_lifecycle`) |
| `Audit` | Cancel, timeout, result, evidence, human resolve |
| `Inbox` | Worktree-addressed notice when awaiting human |
| `WorkspaceStatus` | `headless_workers` list |
| `JidoLifecycle.get/2` | Current snapshot |
| `JidoLifecycle.replay/2` | Reconstruct the same snapshot from the stream |
| `JidoLifecycle.answer/2` | Human resolve + `JidoPod.resume/2` |

Resume token: `jido:<workspace_id>:<attempt_id>`.
