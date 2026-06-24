# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

---

## SEC-1: workspace-scoped MCP token enforcement

| Field | Value |
|-------|-------|
| **Owner** | TBD |
| **Status** | Not started (audit 2026-06-24) |
| **Blocked by** | — |
| **Paths (frozen)** | `lib/dev_ide_web/api/terminal_mcp.ex`, `lib/dev_ide_web/api/preview_mcp.ex`, `lib/dev_ide_web/api_auth.ex`, `lib/dev_ide/agents/terminal_tools.ex`, `lib/dev_ide/agents/preview_tools.ex` |

Global bearer tokens must not reach `terminal_send_command` without
`viewer_terminal_owner?/2` (or equivalent). Workspace-scoped tokens are the only
supported path for external agents until this closes.

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