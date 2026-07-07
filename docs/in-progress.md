# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Window picker sidebar cleanup

| Field | Value |
|-------|-------|
| **Owner** | dalexandre / Grok |
| **Branch** | `agent/grok/sidebar-cleanup-20260707` |
| **Status** | In progress — post-#131 hygiene (testable filter helper landed; dedup window row markup next). |
| **Paths (frozen)** | `assets/js/window_picker_sidebar.js`, `assets/js/window_picker_sidebar_utils.mjs`, `assets/test/window_picker_sidebar.test.mjs`, `lib/dev_ide_web/live/workspace_live/show/session_bar.ex` |

Direction of record: finish sidebar cleanup after #131 — keep keyboard/filter
behavior tested, dedupe shared window-row markup between tabs and sidebar rail.

---

## Jido adoption (phases 1–2)

| Field | Value |
|-------|-------|
| **Owner** | agent (claude adhoc-20260706204502) |
| **Branch** | `agent/claude/jido-adoption-20260706` (merged PR #141) |
| **Status** | Landed on `master` — phase 3 (signal bus) not started |
| **Paths (frozen)** | `lib/dev_ide/agents/*_action.ex`, `lib/dev_ide/agents/artifact_tools.ex`, `lib/dev_ide/agents/terminal_tools.ex`, `lib/dev_ide/agents/preview_tools.ex`, `lib/dev_ide/agents/annotation_tools.ex`, `lib/dev_ide/signals*` |

## Cleared (2026-07-06)

- **Window picker sidebar feature + freeze** — merged via PR #131; stale `in-progress` entry removed on `master` (8d903873). Supersedes `agent/grok/in-progress-sidebar-cleanup`.
- **Preview recordings storage** — branches `feat/preview-recordings` / `feat/worktree-session-core` no longer exist on origin; frozen paths absent from `master`. Treat as lost/abandoned unless rediscovered in another checkout.
- **Session-bar / leader-keys WIP** (`agent/claude/adhoc-20260706181508`) — auto-preserved uncommitted snapshot only; local branch deleted as discard.
- **Window-picker WIP scraps** (`agent/grok/adhoc-20260704194213`, `agent/grok/adhoc-20260706161729`) — superseded by merged window-picker work; local branches deleted.
- **Terminal file links** — merged via PR #139.
