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
