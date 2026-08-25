---
name: approved-verify
kind: task
jido: supported
description: Run an allowlisted verification command through typed Casein code actions.
actions:
  - code_exec
---

# Approved verify

Run a server-owned verifier (`compile`, `test`, `format`, `precommit`,
`assets.build`) with `code_exec`. Workers pass a command id, never a shell
string.
