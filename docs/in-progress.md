# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Cleared (2026-07-07)

- **Window picker sidebar cleanup** — filter helper merged via PR #146; session_bar
  window-row dedup merged via PR #149. Frozen paths released.
- **Jido adoption (phases 1–2)** — merged via PR #141. Phase 3 (signal bus +
  alerts routing) not started; re-add an entry when it begins.

## Cleared (2026-07-06)

- **Window picker sidebar feature + freeze** — merged via PR #131; stale `in-progress` entry removed on `master` (8d903873). Supersedes `agent/grok/in-progress-sidebar-cleanup`.
- **Preview recordings storage** — branches `feat/preview-recordings` / `feat/worktree-session-core` no longer exist on origin; frozen paths absent from `master`. Treat as lost/abandoned unless rediscovered in another checkout.
- **Session-bar / leader-keys WIP** (`agent/claude/adhoc-20260706181508`) — auto-preserved uncommitted snapshot only; local branch deleted as discard.
- **Window-picker WIP scraps** (`agent/grok/adhoc-20260704194213`, `agent/grok/adhoc-20260706161729`) — superseded by merged window-picker work; local branches deleted.
- **Terminal file links** — merged via PR #139.
