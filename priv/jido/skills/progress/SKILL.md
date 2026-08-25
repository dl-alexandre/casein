---
name: progress
kind: task
jido: supported
description: Report progress, result, and evidence for a headless attempt.
actions:
  - report_progress
  - report_result
  - handoff_evidence
---

# Progress and evidence

Record bounded progress and a claimed result. `report_result` is not verified
completion. Evidence is stale when the skill or action catalog digest changes.
