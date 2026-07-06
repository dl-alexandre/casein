# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Jido adoption (phases 1–2)

| Field | Value |
|-------|-------|
| **Owner** | agent (claude adhoc-20260706204502) |
| **Branch** | `agent/claude/jido-adoption-20260706` (pushed, PR #141) |
| **Status** | Awaiting gate + merge (Grok tool ports + cherry-picked `jido_signal` causality) |
| **Paths (frozen)** | `lib/dev_ide/agents/*_action.ex`, `lib/dev_ide/agents/artifact_tools.ex`, `lib/dev_ide/agents/terminal_tools.ex`, `lib/dev_ide/agents/preview_tools.ex`, `lib/dev_ide/agents/annotation_tools.ex`, `lib/dev_ide/signals*` |

Phase 3 (signal bus + alerts routing) not started.

## Cleared (2026-07-06)

- **Preview recordings storage** — branches `feat/preview-recordings` / `feat/worktree-session-core` no longer exist on origin; frozen paths absent from `master`. Treat as lost/abandoned unless rediscovered in another checkout.
- **Session-bar / leader-keys WIP** (`agent/claude/adhoc-20260706181508`) — auto-preserved uncommitted snapshot only; local branch deleted as discard.
- **Window-picker WIP scraps** (`agent/grok/adhoc-20260704194213`, `agent/grok/adhoc-20260706161729`) — superseded by merged window-picker work; local branches deleted.
- **Terminal file links** — merged via PR #139.