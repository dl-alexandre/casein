---
name: git-inspect
kind: task
jido: unsupported
description: Git status and diff. Not supported on the first Jido release.
actions:
  - git_status
  - git_diff
---

# Git inspect

Intentionally unsupported on headless Jido until `git_status` / `git_diff`
join the Code MCP contract. Requesting this skill on Jido fails with
`not_yet_supported`. OpenCode keeps using worktree status/diff MCP.
