# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Window picker sidebar

| Field | Value |
|-------|-------|
| **Owner** | dalexandre / Codex |
| **Branch** | `agent/codex/window-picker-sidebar-20260704` |
| **Status** | Queued — blocked on `feat/worktree-session-core` and path-first picker/header coordination clearing. Fresh worktree created at `/tmp/devide-agent-worktrees/agent-codex-window-picker-sidebar-20260704`. |
| **Paths (planned, not frozen by this entry yet)** | `lib/dev_ide_web/live/workspace_live/show.ex`, `lib/dev_ide_web/live/workspace_live/show/session_bar.ex`, `lib/dev_ide/command_palette/actions.ex`, `assets/js/window_picker_view.js`, `assets/js/workspace_leader.js`, new sidebar picker hook, related LiveView/JS tests |

Direction of record: add `sidebar` as a third `@window_picker_view` mode backed
by `@tmux_window_tabs` / `SessionBarVM.window_tabs/4`; render a desktop-only
left rail around the terminal tab body, preserve `C-b w` behavior with a
sidebar-specific picker hook, and keep dropdown/mobile sheet as the constrained
layout fallback.

---

## Preview recordings storage

| Field | Value |
|-------|-------|
| **Owner** | dalexandre |
| **Branch** | `feat/preview-recordings` (stacked on `feat/worktree-session-core`, pushed) |
| **Status** | Ready for PR after worktree-session core lands |
| **Paths (frozen)** | `lib/dev_ide/previews/recordings.ex`, `lib/dev_ide/previews/storage*`, `lib/dev_ide_web/controllers/preview_recording_controller.ex` |

Blocked on landing worktree-session MCP scoping first.
