# Fleet chrome: manager vs worker vs ready-no-task

Operators running multi-window fleets need to tell, without full pane capture:

1. which panes are **managers** (orchestrators / solo implementers)
2. which panes are **workers** (spawned implementers)
3. which workers are **ready with no task** for longer than a few minutes

This is a **projection**, not a new state store. Casein already has
`AgentState`, `Labels`, `IssueBinding`, and `PaneLiveness`; fleet chrome only
joins those fields on `terminal_topology` and the operator situation digest.

## Label convention

Set with `terminal_set_agent_label` (prefer `freeze: true` so MCP activity does
not rewrite the role):

| Label | Meaning |
|-------|---------|
| `manager` or `manager: <note>` | Orchestrator / window-0 lead / solo implementer |
| `worker` or `worker: <note>` | Spawned implementer |

Examples:

```json
{"label": "manager", "freeze": true}
{"label": "worker: #744 item 4", "freeze": true}
```

`scripts/spawn-agent-worker.sh` already names windows `worker-<slug>`. That
window name alone classifies the pane as `fleet_role: "worker"` even when no
label was set. There is **no** automatic `manager` inference — an unlabeled
solo agent stays role-unset so chrome does not lie.

## Topology fields

On each agent pane (and its window, when present):

| Field | When |
|-------|------|
| `fleet_role` | `"manager"` or `"worker"` from label or `worker-*` window name |
| `fleet_readiness` | `"ready_no_task"` when the readiness rule matches |
| `ready_no_task_for_seconds` | quiet duration that crossed the threshold |
| `label` | chrome label string, when set |
| `issue` | bound issue number, when set (existing) |
| `task_summary` | real task text only — bare `OpenCode` / `Claude Code` titles are stripped |
| `liveness.quiet_for_seconds` | external quiet clock (`include_liveness: true`) |

### Ready, no task, > N minutes

A pane is `ready_no_task` when **all** of:

1. `role == "agent"`
2. `agent_state` is `idle` or `done`, **or** title heuristic `pane_state` is `ready`
3. no `issue` binding
4. `task_summary` is absent
5. quiet duration ≥ **120 seconds** (default), from
   `liveness.quiet_for_seconds` or `agent_state_age_s`

```text
terminal_topology { session, include_liveness: true }
→ panes with fleet_readiness == "ready_no_task"
```

No scrollback capture required. Without `include_liveness`, readiness still
projects when a live `terminal_report_agent_state` report carries age.

## What this is not

- Not a third semantic state on `AgentState` (`:working` / `:idle` / … unchanged)
- Not a new GenServer or durable table
- Not automatic role assignment for every agent pane
- Not a substitute for claim protocol / issue bindings on real queue work

## Fleet board (operator aggregate)

Per-pane fields answer "what is *this* pane doing?". Operators running a
15-window fleet also need the inverse: **what are my workers doing, which are
blocked, which need me?**

`Casein.Terminals.FleetBoard` projects `SessionBarVM` window tabs into:

| Field | Meaning |
|-------|---------|
| `rows` | one row per agent window (state, issue, role, readiness, chip) |
| `counts` | bucket tallies: `needs_you`, `working`, `ready_no_task`, `idle`, `done`, `unknown` |
| `attention_count` | rows that need the operator |

Kind discipline is preserved: report-only (`blocked` / `errored`) and
derived-only (`stalled`) stay distinct; an unscanned / unknown observation is
**never** rendered as quiet. Attention membership reuses
`Casein.Attention.Delivery.session_classification/1` (shared with #787 / #788).

Cockpit chrome: fixed **fleet** badge (bottom-right) opens a drawer. Click a
row → `tmux:select_window` focuses that worker. Rebuilt whenever
`assign_tmux_window_tabs/1` runs — no second poller.

This is **M5-lite** for issue #384 (operator-visible fleet surface). It is not
orchestration MCP, durable task graphs, path contracts, or verifier adapters.

## Orphaned claims (stale `queue/claimed` leases)

`IssueBinding` answers "is anyone on #N?". The inverse — open GitHub issues
labelled `queue/claimed` for this workspace with **no** live binding in the
session — is `Casein.Terminals.OrphanedClaims`.

| Result | Meaning |
|--------|---------|
| `observe_state: :unknown` | claimed set not observed / `{:error, _}` → **never** "no orphans" |
| `observe_state: :ok, orphan_count: 0` | scan ran; every claimed issue has a pane |
| `observe_state: :ok, orphan_count: n` | lease debt; each orphan is needs-you |

Pure projection: callers supply the claimed set (tests) or the board uses the
`gh issue list` port (`list_claimed/1`, cached ~30s). Bindings come from window
tabs / `IssueBinding`. Attention reason `:orphaned_claim` sits on
`Casein.Attention.Delivery.session_reason_urgency/1` — not a parallel ranker.

Fleet drawer section `#fleet-orphaned-claims`; badge attention_count includes
orphan count when observation succeeded. Multi-session workspace union and
auto-reclaim are out of scope for the first slice (#812).

## Gate queue (host flock depth)

PR gates (and preview-e2e) serialise on one host flock
(`/tmp/casein-pr-gate.lock` via `scripts/lib/casein-devbox-mix-lock.sh` —
see `.github/workflows/pr-gate.yml`). With a 15-worker fleet that queue is
operationally decisive: "who holds the box, and how deep is the wait?"

`Casein.Ops.GateQueue.observe/1` answers from **outside**, same kind discipline
as `AgentLiveness`:

| Result | Meaning |
|--------|---------|
| `{:error, reason}` | lock/proc unscannable → render **unknown**, never free |
| `{:ok, %{lock_state: :free}}` | scan ran; nobody holds the lock |
| `{:ok, %{lock_state: :held, holder, waiter_count, depth}}` | holder + waiters |

Holder identity prefers Actions-runner env on the lock-holding process
(`GITHUB_REF` → PR number, `GITHUB_HEAD_REF`, `GITHUB_RUN_ID`, short SHA).
Children that inherit the flock fd are the **same run**, not waiters; a waiter
must be blocked in `flock` (`/proc/*/wchan`) and/or carry a distinct run id.

The fleet drawer shows a gate-queue banner; the badge adds **gate busy** when
held and no agent needs you. Projection only — no GenServer, no GitHub API.

## MCP: `orchestration_status` (M1 operator questions)

Read-only higher-order status for orchestrators (#384). Same projections as the
fleet drawer, over the wire — **not** a second classifier and **not** shell.

M0 shipped the aggregate. **M1** answers the three questions that cost real
operator time on an 18-worker night:

| Question | Field |
|----------|-------|
| Which worker is blocked, and on what? | `blocked[]` + per-row `blocked_on` (`kind: report\|derived`, reason, detail). Report-only (`blocked`/`errored`) stays distinct from derived-only (`stalled`). |
| Where am I in the gate queue? | `gate_queue.holder.position` / `waiters[].position` (1 = holding). Optional `gate_pr` / `gate_run_id` / `gate_branch` / `gate_pid` → `gate_queue.my_position`. |
| Working or wedged? | Per-row `liveness` from external worktree observation (on by default for this tool). `state: unknown` **never** becomes quiet/idle. |

```text
orchestration_status { workspace_id, session, gate_pr? }
→ counts, attention_count, rows[] (liveness, blocked_on),
  blocked[], gate_queue (+ positions, my_position), orphaned_claims
```

| Field | Source |
|-------|--------|
| `counts` / `rows` | `FleetBoard` over topology-enriched window tabs (**liveness on**) |
| `blocked` | rows with `blocked_on` or blocked/errored/stalled state |
| `gate_queue` | `GateQueue.observe` + `with_positions` — `observe_state: unknown` never free |
| `gate_queue.my_position` | `GateQueue.position/2` when identity args given; unknown lock → `status: unknown` not `not_in_queue` |
| `orphaned_claims` | `OrphanedClaims` (claimed − live `IssueBinding`) |

Kind discipline (non-negotiable):

- `AgentLiveness` `{:error, reason}` → liveness `state: unknown` with reason
- missing liveness observation → field omitted (`nil`), **not** quiet
- gate `observe_state: unknown` → never free; `position/2` returns `:unknown`

Fail closed when `workspace_id` or `session` is missing. No scrollback, no
mutations, no `worker_launch`. Classified `mutation: false` with
`:terminal_metadata` + `:terminal_read` so locked Grok grants still see it.

**Traps this surface must not reintroduce:**

- 0% CPU ≠ idle (OpenCode works in a grandchild) — we never use CPU; pane
  content + worktree mtimes only.
- `git rev-list HEAD --not --remotes` false-unpushed after squash merge — not
  used on this path (`Operator.Risks` uses `@{upstream}...HEAD` ahead).

**Out of scope for M1:** durable task graph, path contracts, verifier adapters,
restricted orchestrator token profile, `worker_launch` / cancel / replace.

## MCP: `worker_status` (M2 single-worker deep status)

Read-only inverse of `orchestration_status`: one pane's deep status instead of
the fleet aggregate. Same kind discipline — `blocked_on` keeps report vs derived
distinct; external `liveness` with `state: unknown` never becomes quiet/idle;
missing observation is omitted, not rendered as idle. Requires `workspace_id`,
`session`, and `pane` (optional `window_id`). Liveness is on by default. No
scrollback, no shell, no mutations. **`worker_launch` is M4-lite (below) — not
this tool.**

```text
worker_status { workspace_id, session, pane, window_id? }
→ found?, pane_id, window_id/name, fleet_role, agent_state, issue,
  blocked_on, liveness, worktree_path, ready_no_task_for_seconds, …
```

## MCP: `orchestration_list_workers` (M3 compact fleet list)

Read-only scan list over the same `FleetBoard` projection as
`orchestration_status` — **not** a second classifier. Compact rows only:
`pane_id`, `window`, `issue`, `agent_state`, `blocked_on` (kind/reason/detail),
`fleet_role`, `needs_you?`. Optional filters: `fleet_role` (`manager`|`worker`),
`needs_you_only`. Liveness is on by default on the topology path; unknown
liveness never becomes idle (FleetBoard kind discipline). Requires
`workspace_id` + `session`. No scrollback, no shell, no mutations.
**Durable graph and verifiers remain out of scope; spawn is `worker_launch`.**

```text
orchestration_list_workers { workspace_id, session, fleet_role?, needs_you_only? }
→ total, filtered_total, filters, workers[]
```

Use `worker_status` when you need one-pane depth (`worktree_path`, full
liveness); use this tool to answer "which of my N workers need me?" without the
gate/orphan aggregate payload.

## MCP: `worker_launch` (M4-lite visible spawn + receipt)

**One call** spawns a Casein-managed worker window and returns a structured
receipt — same property as `runtime_signal` / `mcp_self_test`: the operator (or
orchestrator) does not need topology + N captures to learn what just launched.

```text
worker_launch {
  workspace_id, session,
  runtime: grok|codex|claude|opencode|agent,
  task_slug,
  label?, dry_run?
}
→ ok, visible?, hidden_subagent?: false,
  pane_id, window_name, window_id?,
  worktree_path?, branch?, handle_id?, label, note
```

| Property | Behaviour |
|----------|-----------|
| Placement | New tmux window `worker-<slug>` on the given Casein session (via `scripts/spawn-agent-worker.sh`) |
| Isolation | Fresh git worktree (`CASEIN_AGENT_FORCE_FRESH_WORKTREE=1`) — never the orchestrator's tree |
| Visibility | `visible?: true` only when a live pane id is returned; dry_run never claims visible |
| Hidden subagent | **Never** — spawn failure is a hard error, no silent fallback |
| Receipt | Single payload: pane + window + worktree/branch when observable + optional `WorkHandles` id |
| Fail closed | Missing args, bad runtime, missing script, non-zero spawn, empty pane id, timeout |

**Still out of scope for this slice** (carried in `WorkerLaunch` moduledoc +
contract tests so a respawned worker does not re-derive them from a dead brief):

- durable task graph / path contracts / verifier adapters
- replace lifecycle / `worker_send_contract`
- restricted orchestrator token profile rewrite
- hidden-subagent fallback (spawn failure is hard error)
- dry_run claiming `visible?` / `pane_id`

Teardown is `worker_cancel` (M4.1 below). Leave #384 open for the remaining milestones.

## MCP: `worker_cancel` (M4.1 visible teardown + receipt)

**One call** kills a Casein-managed worker window and returns a structured
receipt — inverse of `worker_launch`. Orchestrators do not need raw
`kill-window` / topology scrapes to retire a worker they just spawned.

```text
worker_cancel {
  workspace_id, session, pane,
  window_id?, handle_id?, dry_run?
}
→ ok, cancelled?, visible?,
  pane_id, window_id, window_name?, handle_id?, note
```

| Property | Behaviour |
|----------|-----------|
| Target | Existing tmux window of the given pane (via `Backend.kill_window`) |
| Address | **Window id `@N` only** — never a window index (tmux renumbers) |
| Visibility | `cancelled?: true` / `visible?: false` only after kill returns `:ok` |
| Hide-while-alive | **Never** — WindowTrash is not cancel |
| dry_run | Classifies without killing; `cancelled?: false`, `visible?: true` |
| Fail closed | Missing args, pane not found, not a worker, manager/operator/unlabeled, caller's own window, last window, unknown window count, invalid/`@N`-missing window id, kill failure |

**Still out of scope for this slice** (carried in `WorkerCancel` moduledoc +
contract tests so a respawned worker does not re-derive them from a dead brief):

- durable task graph / path contracts / verifier adapters
- `worker_replace` / `worker_send_contract`
- restricted orchestrator token profile rewrite
- dry_run claiming `cancelled?` / `visible?: false`
- hide-while-alive (WindowTrash) as a "soft" cancel

Leave #384 open for those milestones.

## MCP: `worktree_status` (M4.2 one-call Git inspection)

**One call** answers "what is this worker's tree?" by joining `WorkerStatus`
identity with `Git.Inspector` — the same inspector `casein://fleet/summary`
already uses. Not a second git scraper and not a second fleet classifier.

```text
worktree_status { workspace_id, session, pane, window_id? }
→ found?, pane_id, window_id/name, worktree_path,
  git { inspect_state, unknown_reason?, branch?, head_sha?,
        upstream?, ahead?, behind?, detached?, commits_not_on_origin? }
```

| Property | Behaviour |
|----------|-----------|
| Join | `WorkerStatus.find_pane` + `Git.Inspector.inspect_cwd` |
| `inspect_state: ok` | branch / HEAD / upstream / ahead / behind when present |
| `inspect_state: unknown` | carries `unknown_reason`; **never** `ahead: 0` or clean |
| `ahead: nil` | no upstream — omit `commits_not_on_origin?` (not false-unpushed) |
| Dirty/clean | **Not this slice** — needs porcelain (`worktree_changed_paths` later) |

**Still out of scope for this slice** (carried in `WorktreeStatus` moduledoc +
contract tests so a respawned worker does not re-derive them from a dead brief):

- changed_paths / diff
- `worker_replace` / `worker_send_contract`
- durable task graph / path contracts / verifier adapters
- treating inspect failure as clean or not-ahead

Leave #384 open for those milestones.

## MCP resource: `casein://fleet/summary` (#859 / #879)

Read-only **one-call fleet picture** on Terminal MCP `resources/list` /
`resources/read`. Replaces `terminal_topology` + N `terminal_capture` scrapes
for "what is my fleet doing?".

```text
resources/read { uri: "casein://fleet/summary" }
→ sessions[], each with panes[]:
    runtime, worktree_path, branch, ahead/behind,
    commits_not_on_origin?,
    liveness { source: "process_cpu", state, … },
    progress { state, axes, … }
```

**`liveness` is process/CPU presence, not the spinner.** `PaneProcessLiveness`
samples `pane_pid` + its `/proc` process tree and compares cumulative CPU
jiffies. A frozen UI that is still burning CPU reports `active` (process still
there). First sample is `unknown`/`warming`. Missing pid/proc is `unknown` with
reason — never collapsed into quiet.

**`progress` is the composite (#879).** CPU alone does not prove the agent is
making progress — production incident: 2h07m of advancing CPU with frozen build
timer, stuck context %, stuck spend, zero commits. `AgentProgress` samples:

| axis | advanced when | notes |
|------|---------------|-------|
| process CPU | jiffies increase | necessary-not-sufficient presence |
| worktree | commit count / HEAD / `git status` fingerprint moves | rebase/merge via `git rev-parse --git-dir` (linked worktrees: `.git` is a **file**) |
| screen | `capture-pane` hash changes | changing screen = positive proof; frozen alone is inconclusive |
| context | scraped context size grows | e.g. `54.9K (11%)` |
| spend | scraped spend grows | e.g. `$0.11` |

`progress.state`:

- `progressing` — ≥1 non-CPU progress axis advanced (or rebase/merge in flight)
- `running_but_not_progressing` — process active **and** ≥2 non-CPU axes stalled
  past the stall window (needs two axes disagreeing — no single axis produces it)
- `quiet` / `unknown` — same absence discipline as liveness

Detached HEAD + staged files mid-rebase is **normal**, not broken. Do not use
`pgrep -af git | grep <worktree>` (matches its own cmdline); progress never
does that.

Per-worktree branch + `commits_not_on_origin?` come from `Git.Inspector`
(`ahead` vs upstream), not `rev-list HEAD --not --remotes`.

No mutation verbs. Does **not** edit orchestration_status / worker_status /
orchestration_list_workers paths owned by #384.

## Code

- `Casein.Terminals.FleetChrome` — pure per-pane projection
- `Casein.Terminals.FleetBoard` — pure session aggregate over window tabs (+ orphans + gate + liveness + blocked_on)
- `Casein.Terminals.OrphanedClaims` — claimed-minus-bound lease projection
- `Casein.Terminals.OrchestrationStatus` — MCP wire projection over a fleet board
- `Casein.Terminals.WorkerStatus` — MCP wire projection for one pane (M2)
- `Casein.Terminals.OrchestrationListWorkers` — compact worker-list projection (M3)
- `Casein.Terminals.WorkerLaunch` — visible spawn + structured receipt (M4-lite)
- `Casein.Agents.TerminalTools.WorkerLaunch` — Jido / MCP `worker_launch`
- `Casein.Terminals.WorkerCancel` — visible teardown + structured receipt (M4.1)
- `Casein.Agents.TerminalTools.WorkerCancel` — Jido / MCP `worker_cancel`
- `Casein.Terminals.WorktreeStatus` — one-call Git inspection (M4.2)
- `Casein.Agents.TerminalTools.WorktreeStatus` — Jido / MCP `worktree_status`
- `Casein.Terminals.FleetSummary` — `casein://fleet/summary` payload builder (#859/#879)
- `Casein.Terminals.PaneProcessLiveness` — process-tree CPU jiffy presence (#859)
- `Casein.Terminals.AgentProgress` — composite progress + running_but_not_progressing (#879)
- `Casein.Ops.GateQueue` — host flock observation (`/proc` + lock path) + `position/2`
- `CaseinWeb.WorkspaceLive.Show.FleetPanel` / `FleetEvents` — badge + drawer
- `Casein.Agents.TerminalTools.OrchestrationStatus` — Jido action / MCP tool
- `Casein.Agents.TerminalTools.WorkerStatus` — Jido action / MCP tool (`worker_status`)
- `Casein.Agents.TerminalTools.OrchestrationListWorkers` — Jido action / MCP tool (`orchestration_list_workers`)
- `CaseinWeb.API.TerminalMCP` — publishes `casein://fleet/summary` resource
- `Casein.Labels.enrich_topology/2` — join label strings onto panes
- `Casein.Terminals.PaneState` — strips bare runtime banners from `task_summary`
- Wired from `Casein.Agents.TerminalTools.Impl.Session.topology/1`,
  `Casein.Operator.SituationDigest`, and cockpit `assign_tmux_window_tabs/1`
