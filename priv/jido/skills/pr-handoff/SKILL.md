---
name: pr-handoff
kind: task
jido: supported
description: Push a verified worker branch and hand a bounded receipt to Dash.
actions:
  - git_push
  - handoff_evidence
  - report_result
---

# PR handoff

Use after the worker's targeted tests and `bash scripts/pre-push-check.sh` pass.

- Build a receipt containing the repository, base/head branches, full head SHA,
  handoff id, test/check evidence, and any known PR identity.
- Call `git_push` once. It validates the assigned isolated worktree, exact
  branch and SHA, and clean tree, then pushes only the worker branch.
- Treat the returned idempotency key and head SHA as the handoff identity.
- Report evidence and completion after the push.
- Never create, approve, resolve review threads, enable auto-merge, or merge a
