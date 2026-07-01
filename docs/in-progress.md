# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

---

## Worktree sessions + preview proxy

| Field | Value |
|-------|-------|
| **Owner** | dalexandre |
| **Branch** | `feat/worktree-session-core` (rebased on `origin/master`, pushed) |
| **Status** | Ready for PR — preview recordings split to `feat/preview-recordings` |
| **Paths (frozen)** | `lib/dev_ide_web/live/workspace_live/show.ex`, `lib/dev_ide/agents/*`, `lib/dev_ide/preview_panes.ex`, `lib/dev_ide_web/api/*_mcp.ex` |

**Next steps**

1. Open PR for `feat/worktree-session-core` → `master`.
2. After merge, rebase `feat/preview-recordings` onto `master` and open second PR.

---

## Preview recordings storage

| Field | Value |
|-------|-------|
| **Owner** | dalexandre |
| **Branch** | `feat/preview-recordings` (stacked on `feat/worktree-session-core`, pushed) |
| **Status** | Ready for PR after worktree-session core lands |
| **Paths (frozen)** | `lib/dev_ide/previews/recordings.ex`, `lib/dev_ide/previews/storage*`, `lib/dev_ide_web/controllers/preview_recording_controller.ex` |

Blocked on landing worktree-session MCP scoping first.
