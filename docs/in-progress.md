# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Path-first navigation (picker → path URLs)

| Field | Value |
|-------|-------|
| **Owner** | dalexandre (Claude session) |
| **Branch** | Stage 2 should start from fresh `origin/master` |
| **Status** | Stage 1 merged via PR #107 (`b16e1be4`). Stage 2 is unblocked: `feat/worktree-session-core` landed via PRs #67/#68 and preview recordings landed via PR #69. Rebase before flipping routes. |
| **Paths (frozen)** | `lib/dev_ide/workspaces/path_resolver.ex`, `lib/dev_ide/workspaces/state*`; later stages: `router.ex`, `workspace_live/index.ex` (deletion), new `workspace_live/dashboard.ex`, and the **routing/navigation code in `workspace_live/show.ex`** (route helpers, `~p"/workspaces/..."` links, redirects, breadcrumbs). The freeze on `show.ex` is scoped to that navigation surface — its terminal/pane UI is **not** frozen. |

Direction of record: filesystem-path URLs replace `/workspaces` picker navigation;
`/workspaces/:id` becomes a redirect; breadcrumbs replace the back arrow;
workspace identity stays keyed on `external_id`/`folder:` ids. Do not add new
hardcoded `~p"/workspaces/..."` links — Stage 2 introduces a canonical route
helper. Plan lives with the session owner; ask before touching the picker or
LAN-path routing.

> **Scope note (2026-07-05):** this freeze protects the routing flip only. Edits to
> `show.ex`'s terminal/pane UI are out of scope — e.g. the mobile pane-zoom
> reconsideration (mobile now robustly tmux-zooms the focused pane so it renders
> crisp/native, with the focus-rails CSS scale made uniform to never stretch)
> landed 2026-07-05 without touching any routing/navigation code.
> Stage 2 guardrail prep is in flight on PR #112 (`workspace_routes.ex`, `index.ex`);
> the route flip itself is still pending, so the entry stays.

> **Update (2026-07-06):** the Stage 2 route flip landed on `master` via PR #118
> (always-on path routing with mode-keyed trust). Later stages (picker deletion,
> `dashboard.ex`) remain, so the Paths freeze entry stays for those surfaces.

---

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
