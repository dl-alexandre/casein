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
| **Branch** | `merge-agent-worktree-sessions` (rebase onto `origin/master` before merge) |
| **Status** | In progress — core session/worktree reporting ready; preview recordings split out |
| **Paths (frozen)** | `lib/dev_ide_web/live/workspace_live/show.ex`, `lib/dev_ide/agents/*`, `lib/dev_ide/preview_panes.ex`, `lib/dev_ide_web/api/*_mcp.ex` |

**Next steps**

1. Rebase branch onto `origin/master`.
2. Land worktree-session core without preview recording storage.
3. Follow-up branch for `lib/dev_ide/previews/recordings.ex` and `lib/dev_ide/mcp/`.

---

## Preview recordings storage

| Field | Value |
|-------|-------|
| **Owner** | dalexandre |
| **Branch** | `feat/preview-recordings` (to be created after worktree-session merge) |
| **Status** | WIP in dirty tree — do not stack on unrebased integration branch |
| **Paths (frozen)** | `lib/dev_ide/previews/recordings.ex`, `lib/dev_ide/previews/storage*`, `lib/dev_ide_web/controllers/preview_recording_controller.ex` |

Blocked on landing worktree-session MCP scoping first.