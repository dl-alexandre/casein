# Delegation prompt template (Grok worker)

Copy and fill this template when sending a task to a Grok worker pane.
Keep the orchestrator context summary under ~4k tokens.

---

## Task

{{ONE_PARAGRAPH_SCOPED_TASK}}

## Context

{{BULLET_SUMMARY_OF_RELEVANT_STATE}}

- Primary checkout (read-only mirror of origin/master): `/data/workspaces/dalexandre/casein`
- Your worktree is isolated — do all edits there.
- Toolchain: `mise exec -- mix ...` from inside your worktree (never host `mix`).
- Pre-push gate: `bash scripts/pre-push-check.sh` before any push.
- Commit to your branch; do **not** push unless explicitly asked.

## Constraints

- Touch only files required by the task.
- Run targeted tests for changed modules.
- If blocked (missing credentials, ambiguous requirement, cross-worktree conflict), say so explicitly.

## Output contract

End your **final** message with exactly one fenced JSON block and nothing after it:

```json
{
  "status": "done",
  "summary": "one sentence outcome",
  "branch": "agent/grok/<slug>-<stamp>",
  "files_changed": ["path/one", "path/two"],
  "needs_input": null
}
```

Use `"status": "blocked"` and set `needs_input` when you cannot proceed without orchestrator help.