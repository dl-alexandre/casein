# Delegation prompt template (worker)

## Jido / typed-action contract (headless)

When `jido_admit` selected Jido, do **not** paste this prompt into a pane.
Admit a bounded action list instead:

```text
jido_admit {
  workspace_id: "{{WORKSPACE_ID}}",
  worktree_path: "{{WORKER_WORKTREE}}",
  skill: "inspect" | "patch" | "approved-verify" | "representative-edit",
  actions: [
    {"name": "code_read", "args": {"path": "…"}},
    {"name": "code_search", "args": {"query": "…"}},
    {"name": "code_apply_patch", "args": {"patch": "…"}, "mutation_token": "…"},
    {"name": "code_exec", "args": {"command_id": "mix.test"}}
  ]
}
```

Allowed names: `code_read`, `code_search`, `code_apply_patch`, `code_exec`.
Forbidden: `terminal_send_*`, `terminal_capture`, any shell, `git_*`, `task_*`.
Poll `jido_status` for `state` / redacted `result`. Cancel with `jido_cancel`.
If the admit receipt is `fallback?: true`, use the OpenCode pane template below.

---

Copy and fill this template when sending a task to a **TUI** worker pane
(`worker_launch` fallback). Works for grok, codex, claude, opencode. Keep the
orchestrator context summary under ~4k tokens.

Substitute `{{RUNTIME}}` and `{{PRIMARY_CHECKOUT}}` with real values — resolve the
checkout from `git worktree list --porcelain | head -1`, never from a remembered
absolute path.

---

## Task

{{ONE_PARAGRAPH_SCOPED_TASK}}

## Context

{{BULLET_SUMMARY_OF_RELEVANT_STATE}}

- Primary checkout (read-only mirror of origin/master): `{{PRIMARY_CHECKOUT}}`
- Your worktree is isolated — do all edits there.
- Toolchain: `mise exec elixir@1.20.0-otp-28 erlang@28.5 -- mix ...` from inside
  your worktree (never host `mix`).
- Pre-push gate: `bash scripts/pre-push-check.sh` before any push.
- Commit to your branch; do **not** push unless explicitly asked.

## Constraints

- Touch only files required by the task.
- Check your Casein inbox (`terminal_inbox`, no arguments — it defaults to your
  own pane) between phases of the work, and again before you report done. The
  orchestrator sends corrections there rather than typing at you mid-turn, so an
  uncollected message is a change you have not applied yet. Pass `collect=true`
  once you have acted on what you read.
- Run targeted tests for changed modules.
- If blocked (missing credentials, ambiguous requirement, cross-worktree conflict), say so explicitly.

## Output contract

Two steps, both required.

**1. Report your terminal state** so the orchestrator's wait resolves instead of
polling. Call the Casein terminal MCP tool:

```text
terminal_report_agent_state(
  workspace_id: <your workspace_id>,
  state: "done" | "blocked",
  message: "<one line>"
)
```

Use `"blocked"` if you are stopping to ask something. If that tool is
unavailable, skip this step and go straight to step 2 — the orchestrator falls
back to a capture-based poll.

**2. End your final message with exactly one fenced JSON block and nothing after
it:**

```json
{
  "status": "done",
  "summary": "one sentence outcome",
  "branch": "agent/{{RUNTIME}}/<slug>-<stamp>",
  "files_changed": ["path/one", "path/two"],
  "needs_input": null
}
```

Use `"status": "blocked"` and set `needs_input` when you cannot proceed without
orchestrator help.
