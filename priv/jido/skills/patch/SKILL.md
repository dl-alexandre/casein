---
name: patch
kind: task
jido: supported
description: Apply a unified diff through typed Casein code actions.
actions:
  - code_apply_patch
---

# Patch

Apply a unified diff with `code_apply_patch`. Already-applied patches are
idempotent. Do not write files outside the assigned worktree.
