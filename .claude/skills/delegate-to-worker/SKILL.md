---
name: delegate-to-worker
description: >
  Delegate a scoped coding task to a worker agent (grok, codex, claude, or
  opencode) running in an isolated git worktree via Casein terminal MCP. Use when
  the user says delegate, spawn a worker, offload to grok/codex, or wants
  parallel implementation in a separate worktree without sharing the
  orchestrator's checkout.
---

# Delegate to a worker

Orchestrate a worker through Casein terminal MCP. Prefer headless Jido when
the workspace flag is on. Fall back to a visible OpenCode/`worker_launch`
pane only when Jido is disabled or `runtime: opencode` is explicit. Jido
never gets a pane id — do not send tmux keys.

All four runtimes get per-workspace Casein MCP configs materialized at launch, so
any of them can call `terminal_report_agent_state` back at you. What differs is
what they signal *without* being asked — see [§6](#6-wait-loop).

## Prerequisites

- Terminal MCP with `workspace_id` on every call.
- Orchestrator cwd is **not** where the worker should edit (workers use their own worktree).

## 1. Pick the runtime

**Headless Jido first.** Call `jido_admit` with `dry_run: true` (or omit
`runtime`) so Casein chooses from `CASEIN_JIDO_HEADLESS` /
`CASEIN_JIDO_HEADLESS_WORKSPACES`. Do not guess the flag.

| `jido_admit` receipt | Path |
|---|---|
| `runtime: "jido"`, `fallback?: false` | Admit typed CodeTools actions. Poll `jido_status`. Cancel with `jido_cancel`. No pane, no `terminal_send_*`. |
| `fallback?: true` / `next_tool: "worker_launch"` | OpenCode TUI path below. Same when you pass `runtime: "opencode"`. |
| `error: "jido_disabled"` | You pinned `runtime: "jido"` on a workspace that is not flagged. Use `worker_launch`. |

Typed actions only: `code_read`, `code_search`, `code_apply_patch`,
`code_exec`. Never pass `terminal_send_*`, a shell, or `git_*` / `task_*`
(those fail closed). Identity on action args is ignored — workspace and
worktree come from the admit call.

Route remaining TUI work on **capability**, not preference. Agent-write unlock
is **not** a hard gate for write work — it only controls whether a Grok worker
may drive live tmux panes.

### Agent-write unlock (grok MCP grant only)

`terminal_context` returns an `agent_write` block, but `write_enabled: false` is
**not a blocker** for write work. The worker's bwrap base is always `strict`, so
it writes its own worktree, runs `mix`, and commits regardless. The unlock
governs only the MCP grant — whether the worker may drive live tmux panes
(`terminal_send_command` / `terminal_send_keys`). Reporting tools stay granted
while locked, so unattended delegation works either way.

`spawn-agent-worker.sh` preflights the unlock and, when it is locked, prints a
`warn:` advisory naming what the worker can and cannot do — then spawns anyway.
It does not refuse. Set `CASEIN_SPAWN_SKIP_WRITE_PREFLIGHT=1` to suppress the
advisory. The grant is read at launch and **frozen for the pane's life**, so
re-granting later does not free a running pane — relaunch it. Ask an operator to
grant write only when the task genuinely needs pane control.

**Orchestrator fail-fast (#593):** if *you* need `terminal_send_*` and
`terminal_context.agent_write.orchestrator_ready` is false, emit one blocked
report, label `blocked: need agent-write unlock`, and stop — do not poll.
Launch managers with `CASEIN_AGENT_REQUIRE_WRITE=1` so a locked grant exits 3
before a fake-healthy session. Never set `CASEIN_GROK_SANDBOX_BASE` to bypass.

Two distinct locked states (only relevant when you need pane control):

| `unlock_status` | Meaning | Response |
|---|---|---|
| `inactive` / `expired` | The unlock lapsed (max 240 min) | Grant in the workspace UI, then relaunch |
| `blocked-by-workspace-policy` | Unlock **is** active; workspace is not in manual mode, or DB isolation is `shared_stage`/`unsafe` | Re-granting will not help — resolve the policy first |

**codex, claude, and opencode are not gated** — the preflight runs only for
`grok`.

### Preference order

Pick on task shape:

| Situation | Runtime |
|---|---|
| Long multi-slice implementation | **codex** or **claude** — both report semantic state, so the wait is exact instead of a poll |
| Bulk / parallel implementation | **grok** — cheap to fan out; works locked for write/commit, needs unlock only for pane control |
| Work that needs the worker to drive live panes | any runtime with an active agent-write unlock (or codex/claude/opencode) |
| Read-only analysis or review | any |

### Which model a worker gets

Casein pins a model for two runtimes and leaves the rest to the runtime's own
config:

| Runtime | Model source |
|---|---|
| **codex** | `CASEIN_CODEX_DEFAULT_MODEL`, else the `model` key in `~/.codex/config.toml` |
| **opencode** | `CASEIN_OPENCODE_DEFAULT_MODEL`, default `opencode/grok-4.6` |
| **claude**, **grok** | the runtime's own config; Casein sets nothing |

Both vars yield to an explicit `--model`/`-m` on the launch command, and setting
either to the empty string opts out so the host-global config wins. Note that
opencode's own config (`~/.config/opencode`) is **box-global** — editing it
changes every opencode session on the machine, Casein-launched or not, which is
why the default is injected per launch rather than written there.

Casein-launched OpenCode also pins the maximum OpenCode permission rule,
`permission: "allow"`, in its inline runtime config while preserving unrelated
inline settings. A project-local config therefore cannot reintroduce prompts or
denials for a delegated OpenCode worker.

There is no reliable quota signal to route on, and you should not invent one:

- **codex** — the only runtime with real telemetry. Session rollouts under
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` carry
  `rate_limits: {primary: {used_percent, window_minutes, resets_at}, credits}`.
  It is a **snapshot from the last codex run**, not a live query, so it decays
  exactly when delegation is busiest. Use it as a soft tiebreak at most, and say
  it is stale whenever you cite it.
- **grok** — none. No `usage` subcommand; `~/.grok/sessions/*` holds only
  `prompt_history.jsonl`.
- **claude** — none usable. `~/.claude/stats-cache.json` is message/session/tool
  *counts*, not quota; `/usage` is interactive-only.

Do not claim a runtime is "cheaper" or "has headroom" without one of the above in
hand.

## 2. Resolve session

```text
terminal_context(workspace_id)
```

If `ambiguous_workspace_sessions`, pass the attached `casein_*` session explicitly
on every subsequent call.

Record orchestrator cwd: `terminal_topology` → active pane `current_path`, or
`terminal_capture` of the orchestrator pane.

## 3. Acquire a worker

### Headless Jido (preferred when the workspace flag is on)

```text
jido_admit {
  workspace_id,
  worktree_path?,
  skill?,
  actions: [{name: code_read|code_search|code_apply_patch|code_exec, args?, mutation_token?}],
  dry_run?
}
```

A live Jido receipt has `attempt_id`, `headless: true`, and **no** `pane_id`.
`dry_run: true` returns the selection only. Then:

```text
jido_status { workspace_id, attempt_id }
jido_cancel { workspace_id, attempt_id }
```

Poll `jido_status` until `state` is `completed|failed|cancelled|timed_out|provider_unavailable`.
Do not `terminal_capture` a Jido attempt. If the receipt is `fallback?: true`,
use `worker_launch` below — do not retry Jido with a shell spawn.

### OpenCode / TUI fallback (`worker_launch`)

Use this only when Jido is disabled or you passed `runtime: "opencode"`.

### Reuse (only when safe)

From `terminal_topology`, find a pane for your chosen runtime that is:

- `pane_state` is `"unknown"` — or `"ready"` for claude (see the state table in §6)
- **not** `pane_state: "working"`
- `current_path` differs from the orchestrator cwd (shared-worktree guard)

### Spawn fresh (preferred when reuse is ambiguous)

**The only supported TUI spawn path is the `worker_launch` MCP tool.** Do not
shell out to `spawn-agent-worker.sh`. Do not resolve `$CASEIN_SCRIPTS` or
`$CASEIN_CHECKOUT/scripts`. Do **not** `find` / `locate` the helper — a
filesystem search that hits a stale Casein checkout is worse than a clean
failure (wrong version, no signal). If `worker_launch` fails, stop; do not
fall back to a shell spawn.

```text
worker_launch {
  workspace_id,
  session,
  runtime: grok|codex|claude|opencode|agent,
  task_slug,
  label?,
  dry_run?
}
```

The receipt is the spawn result — no topology scrape required:

- `pane_id` (e.g. `%255`)
- `window_name` (`worker-<slug>`)
- `worktree_path`, `branch`
- `handle_id`

`dry_run: true` prints the plan without opening a window.

`worker_launch` resolves the installed Casein helper (release `priv/scripts`,
then host overlay), sources the workspace env in the new window, and pins a
fresh worktree (`CASEIN_AGENT_FORCE_FRESH_WORKTREE=1`) so the worker does not
adopt the orchestrator's checkout. Product repos are not expected to carry
Casein host infrastructure.

**A returned `pane_id` means a live agent.** There is no "spawned but empty"
state to check for — if you got a pane id, something is there to talk to.

It does *not* mean the agent has finished drawing its prompt, so still confirm
that before sending:

1. `terminal_topology(pane: <id>)` until `pane_state` settles out of startup churn.
2. `terminal_capture(pane: <id>, lines: 40)` shows that runtime's input prompt.

Re-issue every ~10s. Spawn itself absorbs most of the 30–90s startup (worktree +
MCP materialize) before it returns.

**Collision note:** branch stamps are per-second; two spawns in the same second
can collide — serialize spawns or use distinct task slugs.

## 4. Compose the delegation prompt

Load `.claude/skills/delegate-to-worker/references/prompt-template.md`, fill
placeholders, keep context ≤4k tokens.

The template asks the worker to call `terminal_report_agent_state` at the end.
That call is what upgrades a poll into an exact wait — see §6.

## 5. Send to the worker

**Put the prompt in the worker's inbox, then type one line to wake it.** This is
the correct way to hand over a multi-KB work order without racing the TUI — not
a fallback after spawn. Typing a multi-thousand-token prompt into a TUI is the
least reliable step in this whole flow: keystrokes race whatever the agent is
drawing, a chunked send can interleave, and a paste that half-landed looks
identical to one that worked.

```text
terminal_say(to: "pane:<worker_pane>", body: <the full prompt>, message_id: <task-slug>)
terminal_send_keys(session, pane: <worker_pane>, keys: "Read your Casein inbox with terminal_inbox and follow it.")
terminal_send_keys(session, pane: <worker_pane>, keys: "Enter")
```

The wake line is short, fixed, and goes to a worker sitting at an empty prompt —
the one moment pane-typing is safe. Everything of substance travels as a message,
where it is durable, size-checked, and *visibly uncollected* until the worker
actually reads it.

`terminal_say` refuses an ambiguous recipient rather than delivering to a guess,
so pass `pane:<id>` when two windows share a name. For a long-lived role
(coordinator / factory manager) address `handle:<id>` from
`terminal_work_handle_create` — a pane: mailbox is orphaned on respawn.

### Follow-ups to a running worker

Never type at a worker mid-turn. Send another message instead:

```text
terminal_say(to: "pane:<worker_pane>", body: "Requirements changed: skip the migration.")
```

The template tells the worker to check its inbox between phases, so a follow-up
lands at the next safe point in its loop instead of racing its input box. If the
worker never collects it, that stays visible — `terminal_inbox` on its address
still shows the message as uncollected, which a keystroke could never tell you.

## 6. Wait loop

### What each signal actually means

Casein derives pane state two ways, and they are not interchangeable:

- **Title heuristic** (`Casein.Terminals.PaneState`) — a leading Braille spinner
  means `working`; a leading heavy asterisk (`✳`, U+2733) means `ready`;
  everything else is `unknown`. Only Claude Code publishes these markers today.
- **Semantic report** (`Casein.Terminals.AgentState`) — `working | blocked | done
  | idle`, from Claude Code hooks, Codex CLI hooks, or any agent calling
  `terminal_report_agent_state`. **`blocked` and `done` are report-only** — the
  title heuristic can never produce them.

`ready` is **not** `done`. The asterisk means "ready *or waiting for input*", so
treating it as finished renders a blocked permission prompt as success.

Staleness rules, worth knowing when a wait behaves oddly: a fresh report wins
outright for 10s; a `working` report older than 120s with the title showing
`ready` flips to ready (the agent stopped and the hook missed `Stop`); any report
older than 30 min is discarded entirely.

| Runtime | Title markers | Reports `done`/`blocked` unprompted | Wait strategy |
|---|---|---|---|
| **claude** | ✅ spinner + `✳` | ✅ Claude Code hooks | `terminal_wait_agent_state` on `["done", "idle"]` |
| **codex** | ❌ | ✅ CLI hooks (`working`/`blocked`/`done`) | `terminal_wait_agent_state` on `["done", "blocked"]` |
| **grok** | spinner only | ❌ | poll `working` → `unknown` |
| **opencode** | ❌ | ❌ | poll, or rely on the template's explicit report |

For grok and opencode the template's closing `terminal_report_agent_state` call is
the only thing that makes `done` waitable. If the worker skips it, fall back to
the poll.

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
processing, or it failed to submit.

### Phase B — wait for completion

**claude / codex** — wait on the semantic states directly:

```text
terminal_wait_agent_state(states: ["done", "blocked", "idle"], timeout_ms: 900000)
```

**grok / opencode** — poll until `pane_state` is `"unknown"`:

```text
terminal_topology(session, workspace_id)  → find pane, read pane_state
```

Re-issue every 15–30s. Overall deadline ~30 minutes; surface `task_summary` from
topology as progress text while `pane_state` is `"working"`.

**Do not** wait on `states: ["done"]` for a grok worker that was not told to
report — it will time out (Phase 0 spike: task finished in 9s, `done` never
matched).

**Stall / wedge detection:** `pane_state` stays `"working"` through both healthy
work *and* a hang, so topology alone can't tell them apart — you must
`terminal_capture(lines: 40)` and read the spinner/footer. If it stays `"working"`
unchanged for >5 min, capture and classify:

- Permission prompt or question in the footer → answer it (§8, `blocked`).
- Grok spinner stuck on **`⠹ Compacting…`** → **wedged**. A healthy compaction
  finishes in seconds; a minute-plus means the worker is hung. Do **not** wait it
  out or try to salvage its chat — jump to
  [Recover a wedged worker](#recover-a-wedged-worker-compaction-hang).

## 7. Extract the result

`include_answer` works only where the runtime has transcript hooks, and **worker
panes generally do not** — treat capture as the default path for every runtime:

```text
terminal_capture(session, pane: <worker_pane>, lines: 120, ansi: false)
```

Parse the **last** fenced ` ```json ` block from the capture text. Expected shape:

```json
{
  "status": "done|blocked",
  "summary": "...",
  "branch": "agent/<runtime>/...",
  "files_changed": ["..."],
  "needs_input": null
}
```

On parse failure, send one retry:

```text
terminal_send_keys(..., keys: "Re-emit your final JSON block only, in one fenced json code block.")
terminal_send_keys(..., keys: "Enter")
```

Then repeat Phase B → §7 once.

## 8. Handle outcomes

| `status` | Action |
|----------|--------|
| `done` | Verify yourself — never trust the worker's claim alone (§9). |
| `blocked` | Read `needs_input`; answer in-scope via `terminal_send_keys`, else surface to the user. |

## 9. Verify and integrate

In the orchestrator shell (not the worker pane):

```bash
git -C <worker-worktree-path> status
git -C <worker-worktree-path> log --oneline -5
git -C <worker-worktree-path> diff origin/master...HEAD
```

Cross-check `files_changed` against the actual diff. Run targeted tests if the
task warrants it.

## 10. Cleanup

Report to the user: runtime, worker `pane_id`, worktree path, branch name,
verification summary.

Leave the pane alive by default for inspection. Kill only on explicit request:

```bash
tmux kill-window -t <session>:<window_index>
```

## Recover a wedged worker (compaction hang)

A Grok worker can wedge on `⠹ Compacting… 10m+` (see Stall / wedge detection in
§6). Because this flow keeps durable state on disk — **each slice is committed and
the plan lives in a plan file** — you discard the wedged in-memory chat and
respawn a fresh session in the **same** worktree. A ~3-line re-brief recovers the
full task; no work is lost.

**1. Confirm the restart point** from the orchestrator shell (read-only — does not
touch the wedged pane):

```bash
git -C <worker-worktree-path> log --oneline -1     # last committed slice
git -C <worker-worktree-path> status --short       # empty = hang was before any uncommitted work
```

**2. Respawn the SAME pane in place** — preserves the pane id, the committed slice,
the materialized MCP, and the agent-state hook. Do **not** call `worker_launch`
again (it forces a fresh worktree and would strand committed slices). Do **not**
resolve `launch-casein-agent.sh` via `$CASEIN_SCRIPTS` or `find`.

Extract the installed launcher from the pane's original start command (the path
`worker_launch` already used). If that path is missing, stop.

```bash
start=$(tmux display-message -p -t <worker_pane> '#{pane_start_command}')
launcher=$(printf '%s\n' "$start" | grep -oE '/[^[:space:]]+/launch-casein-agent.sh' | head -1)
# If $launcher is empty, stop. Do not search the filesystem.
tmux respawn-pane -k -t <worker_pane> -c <worker-worktree-path> \
  "bash -lc 'cd \"<worker-worktree-path>\" && CASEIN_AGENT_WORKTREE_PATH=\"<worker-worktree-path>\" CASEIN_AGENT_TASK=<task-slug> exec bash \"$launcher\" <runtime>'"
```

Use **`launch-casein-agent.sh`**, not another `worker_launch` / spawn (§3): the
launcher *reuses* the worktree when `CASEIN_AGENT_WORKTREE_PATH` points at it.
Wait for the prompt as in §3 (30–90s).

**3. Re-brief compactly** — self-contained, since the fresh session has no chat
memory. Send the plan path plus where to resume, then continue the §6 wait loop:

```text
Plan: <plan-file-path>. Slice N is committed at <sha>, git is clean. Continue with
Slice N+1: <one-line slice spec>. Read the committed code + plan, then proceed.
```

**Recovery caveats:**

- The respawned session's agent-state hook **may not re-pair**, so
  `terminal_wait_agent_state` for `working` can time out. Monitor via
  `terminal_capture` instead (Grok footer `Esc:cancel` = working; `Enter:send` =
  still composing).
- Grok's Enter-to-submit sometimes needs a **second Enter** after a long multiline
  paste (the first can land mid-render and only add a newline).

## Quick reference

| Signal | Meaning |
|--------|---------|
| `working` | Braille spinner in `pane_title`, or an explicit report |
| `ready` | `✳` in title — claude only, and it means **ready or awaiting input**, not done |
| `unknown` | No marker; for grok/codex/opencode this is the idle tell |
| `done` / `blocked` | **Report-only** — hooks (claude, codex) or `terminal_report_agent_state` |
| `⠹ Compacting…` >1 min | Grok **wedged** — respawn same pane/worktree ([recover](#recover-a-wedged-worker-compaction-hang)) |
| `jido_admit` `fallback?: true` | Jido off or `runtime: opencode` — use `worker_launch` |
| `jido_status` `state` terminal | Headless result — do not scrape a pane |
| `worker_launch` spawn refused / exit 3 | Grok refused: agent write locked — route to codex or ask for a re-grant |
| `include_answer` | Unreliable on worker panes — use `terminal_capture` + JSON parse |
