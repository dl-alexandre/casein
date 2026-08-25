---
name: human-input
kind: task
jido: supported
description: Ask a human for clarification without a visible pane.
actions:
  - request_clarification
  - request_human_input
---

# Human input

Park the attempt on `blocked_on_human`. A human answer resumes the same
attempt. Workers cannot self-approve.
