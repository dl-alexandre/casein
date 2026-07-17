---
name: devide-workspace-handoff
description: Finish a DevIDE agent session with an explicit landed, WIP, or handoff worktree report. Use when work is ending, pausing, changing owners, or at risk of becoming an unreported dirty worktree.
---

# DevIDE workspace handoff

1. Inspect `git status --short --branch`, the current branch, and recent commits.
2. Run the relevant verification for the work completed. Do not claim checks that did not run.
3. Choose exactly one outcome:
   - `landed`: changes are committed and pushed or merged.
   - `wip`: changes are intentionally paused; create a `wip:` commit when appropriate.
   - `handoff`: work cannot be pushed yet but must remain discoverable.
4. Call `terminal_report_worktree` with `workspace_id`, the absolute worktree path, branch, `exit_status`, and a short `handoff` describing completed work, checks, and blockers.
5. Keep unrelated user changes out of commits and reports.

Never leave a dirty DevIDE worktree without a report.
