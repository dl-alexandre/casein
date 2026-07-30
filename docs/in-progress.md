# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Preview-walk reliability and self-contained execution

- **Owner:** `agent/codex/preview-walk-reliability-20260730`
- **Started:** 2026-07-30
- **Direction:** make preview-walk reports compact and directly linkable, enforce
  strict performance budgets and stable required Tidewave evidence, and add an
  artifact publish/parity gate so the durable URL and local preview expose the
  same registered files.
- **Frozen paths:** `.claude/skills/preview-ui-walk/**`,
  `lib/casein/artifact_projects*`,
  `lib/casein/agents/tools/artifact_tools.ex`,
  `lib/casein_web/controllers/artifact_project_controller.ex`, and their tests.
- **Product counterpart:** OneBackend branch
  `agent/codex/preview-walk-isolated-run-20260730` owns disposable per-run
  databases, loopback-only containment, and calibrated product manifests.
