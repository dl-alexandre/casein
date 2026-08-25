---
name: task-control
kind: task
jido: unsupported
description: Task wait and cancel. Not supported on the first Jido release.
actions:
  - task_wait
  - task_cancel
---

# Task control

Intentionally unsupported on headless Jido. Cancellation and resume stay on
the pod (`JidoPod.cancel/2`, `JidoPod.resume/2`). Requesting this skill on
Jido fails with `not_yet_supported`.
