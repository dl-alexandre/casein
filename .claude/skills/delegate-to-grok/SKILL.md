---
name: delegate-to-grok
description: >
  Delegate a scoped coding task to a Grok worker in an isolated git worktree via
  DevIDE terminal MCP. Use when the user says delegate, grok worker, offload to
  grok, spawn a grok agent, or wants parallel implementation in a separate
  worktree without sharing the orchestrator's checkout.
---

# Delegate to Grok

Orchestrate a Grok worker through DevIDE terminal MCP. No `agent_pair` marker
required — always pass an explicit `pane` id from topology or the spawn helper.

## Prerequisites

- Terminal MCP with `workspace_id` on every call.
- Orchestrator cwd is **not** where the worker should edit (workers use their own worktree).

## 1. Resolve session

```text
terminal_context(workspace_id)
```

If `ambiguous_workspace_sessions`, pass the attached `devide_*` session explicitly
on every subsequent call.

Record orchestrator cwd: `terminal_topology` → active pane `current_path`, or
`terminal_capture` of the orchestrator pane.

## 2. Acquire a worker pane

### Reuse (only when safe)

From `terminal_topology`, find a Grok pane (`current_command` is `node`, title
ends with ` - grok`) that is:

- `pane_state` is `"unknown"` (idle — Grok does **not** publish Claude's `✳` ready glyph)
- **not** `pane_state: "working"`
- `current_path` differs from the orchestrator cwd (shared-worktree guard)

### Spawn fresh (preferred when reuse is ambiguous)

From the primary checkout on the devbox:

```bash
bash /data/workspaces/dalexandre/dev_ide/scripts/spawn-agent-worker.sh grok <task-slug> <session>
```

Or from any checkout with env resolved:

```bash
bash scripts/spawn-agent-worker.sh grok <task-slug> <session>
```

Stdout is the new `pane_id` (e.g. `%255`). The helper unsets
`DEVIDE_AGENT_WORKTREE_PATH` from tmux session env so each spawn creates a fresh
worktree — without that, workers reuse the orchestrator's checkout.

Wait until the worker is at prompt:

1. `terminal_topology(pane: <id>)` until `pane_state` is `"unknown"`.
2. `terminal_capture(pane: <id>, lines: 40)` shows the Grok input prompt (`❯`).

Re-issue every ~10s; startup can take 30–90s (worktree + MCP materialize).

**Collision note:** branch stamps are per-second; two spawns in the same second
can collide — serialize spawns or use distinct task slugs.

## 3. Compose the delegation prompt

Load `.claude/skills/delegate-to-grok/references/prompt-template.md`, fill
placeholders, keep context ≤4k tokens.

## 4. Send to the worker

Use explicit-pane tools (not `terminal_send_agent_*`):

```text
terminal_send_keys(session, pane: <worker_pane>, keys: <single-line prompt>)
terminal_send_keys(session, pane: <worker_pane>, keys: "Enter")
```

For multiline prompts, send in chunks or use bracketed paste via repeated
`terminal_send_keys` — verify with `terminal_capture` that the prompt landed
before pressing Enter.

## 5. Wait loop (Grok-specific)

Grok does **not** report `done` or `idle` today. Only `working` (braille spinner
in pane title) and `unknown` (idle at prompt) are reliable.

### Phase A — confirm acceptance

```text
terminal_wait_agent_state(
  workspace_id, session,
  pane: <worker_pane>,
  states: ["working"],
  timeout_ms: 30000
)
```

If this times out, `terminal_capture` the pane — the prompt may already be
processing (title already `working`) or failed to submit.

### Phase B — wait for completion (`working` → `unknown`)

Poll until `pane_state` is `"unknown"`:

```text
terminal_topology(session, workspace_id)  → find pane, read pane_state
```

Re-issue every 15–30s. Overall deadline ~30 minutes; surface `task_summary` from
topology as progress text while `pane_state` is `"working"`.

**Do not** wait on `states: ["done"]` or `["idle"]` for Grok — they will time out
(Phase 0 spike: task finished in 9s but `done` never matched).

**Stall / wedge detection:** `pane_state` stays `"working"` through both healthy
work *and* a hang, so topology alone can't tell them apart — you must
`terminal_capture(lines: 40)` and read the spinner/footer. If it stays `"working"`
unchanged for >5 min, capture and classify:

- Permission prompt or question in the footer → answer it (step 6, `blocked`).
- Spinner stuck on **`⠹ Compacting…`** → **wedged**. A healthy compaction finishes
  in seconds; a minute-plus means the worker is hung. Do **not** wait it out or try
  to salvage its chat — jump to
  [Recover a wedged worker](#recover-a-wedged-worker-compaction-hang).

### Phase C — extract result (capture fallback)

`include_answer: true` does not work for Grok (no transcript hooks). Always:

```text
terminal_capture(session, pane: <worker_pane>, lines: 120, ansi: false)
```

Parse the **last** fenced ` ```json ` block from the capture text. Expected shape:

```json
{
  "status": "done|blocked",
  "summary": "...",
  "branch": "agent/grok/...",
  "files_changed": ["..."],
  "needs_input": null
}
```

On parse failure, send one retry:

```text
terminal_send_keys(..., keys: "Re-emit your final JSON block only, in one fenced json code block.")
terminal_send_keys(..., keys: "Enter")
```

Then repeat Phase B → Phase C once.

## 6. Handle outcomes

| `status` | Action |
|----------|--------|
| `done` | Verify yourself — never trust the worker's claim alone (step 7). |
| `blocked` | Read `needs_input`; answer in-scope via `terminal_send_keys`, else surface to the user. |

## 7. Verify and integrate

In the orchestrator shell (not the worker pane):

```bash
git -C <worker-worktree-path> status
git -C <worker-worktree-path> log --oneline -5
git -C <worker-worktree-path> diff origin/master...HEAD
```

Cross-check `files_changed` against the actual diff. Run targeted tests if the
task warrants it.

## 8. Cleanup

Report to the user: worker `pane_id`, worktree path, branch name, verification
summary.

Leave the pane alive by default for inspection. Kill only on explicit request:

```bash
tmux kill-window -t <session>:<window_index>
```

## Recover a wedged worker (compaction hang)

A Grok worker can wedge on `⠹ Compacting… 10m+` (see Stall / wedge detection in
step 5). Because this flow keeps durable state on disk — **each slice is committed
and the plan lives in a plan file** — you discard the wedged in-memory chat and
respawn a fresh session in the **same** worktree. A ~3-line re-brief recovers the
full task; no work is lost.

**1. Confirm the restart point** from the orchestrator shell (read-only — does not
touch the wedged pane):

```bash
git -C <worker-worktree-path> log --oneline -1     # last committed slice
git -C <worker-worktree-path> status --short       # empty = hang was before any uncommitted work
```

**2. Respawn the SAME pane in place** — preserves the pane id, the committed slice,
the materialized MCP, and the agent-state hook:

```bash
tmux respawn-pane -k -t <worker_pane> -c <worker-worktree-path> \
  "bash -lc 'cd \"<worker-worktree-path>\" && DEVIDE_AGENT_WORKTREE_PATH=\"<worker-worktree-path>\" DEVIDE_AGENT_TASK=<task-slug> exec bash scripts/launch-devide-agent.sh grok'"
```

Use **`launch-devide-agent.sh`**, not `spawn-agent-worker.sh` (§2): the launcher
*reuses* the worktree when `DEVIDE_AGENT_WORKTREE_PATH` points at it, whereas the
spawn helper unsets that var to force a fresh worktree — which would strand the
already-committed slices. Wait for the prompt as in §2 (`pane_state: "unknown"` +
`❯` in capture; 30–90s).

**3. Re-brief compactly** — self-contained, since the fresh session has no chat
memory. Send the plan path plus where to resume, then continue the step 5 wait loop:

```text
Plan: <plan-file-path>. Slice N is committed at <sha>, git is clean. Continue with
Slice N+1: <one-line slice spec>. Read the committed code + plan, then proceed.
```

**Recovery caveats:**

- The respawned session's agent-state hook **may not re-pair**, so
  `terminal_wait_agent_state` for `working` can time out. Monitor via
  `terminal_capture` instead (footer `Esc:cancel` = working; `Enter:send` = still
  composing).
- Grok's Enter-to-submit sometimes needs a **second Enter** after a long multiline
  paste (the first can land mid-render and only add a newline).

## Quick reference

| Signal | Grok behavior |
|--------|---------------|
| `working` | Braille spinner in `pane_title` (e.g. `⠴ - Thinking - … - grok`) |
| Idle / done | `pane_state: "unknown"`, plain title, prompt visible in capture |
| `⠹ Compacting…` >1 min | **Wedged** — respawn same pane/worktree ([recover](#recover-a-wedged-worker-compaction-hang)) |
| `done` / `idle` wait | **Unsupported** — use `working` → `unknown` poll |
| `include_answer` | **Unsupported** — use `terminal_capture` + JSON parse |
| `blocked` | No reliable signal — read capture for questions |