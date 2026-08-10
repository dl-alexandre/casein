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

## MCP: `orchestration_status` (M0 discovery)

Read-only higher-order status for orchestrators (#384). Same projections as the
fleet drawer, over the wire — **not** a second classifier and **not** shell.

```text
orchestration_status { workspace_id, session }
→ counts, attention_count, rows[], gate_queue, orphaned_claims
```

| Field | Source |
|-------|--------|
| `counts` / `rows` | `FleetBoard` over topology-enriched window tabs |
| `gate_queue` | `GateQueue.observe` — `observe_state: unknown` never free |
| `orphaned_claims` | `OrphanedClaims` (claimed − live `IssueBinding`) |

Fail closed when `workspace_id` or `session` is missing. No scrollback, no
mutations, no `worker_launch`. Classified `mutation: false` with
`:terminal_metadata` + `:terminal_read` so locked Grok grants still see it.

**Out of scope for M0:** durable task graph, path contracts, verifier adapters,
restricted orchestrator token profile, `worker_launch` / cancel / replace.

## Code

- `Casein.Terminals.FleetChrome` — pure per-pane projection
- `Casein.Terminals.FleetBoard` — pure session aggregate over window tabs (+ orphans + gate)
- `Casein.Terminals.OrphanedClaims` — claimed-minus-bound lease projection
- `Casein.Terminals.OrchestrationStatus` — MCP wire projection over a fleet board
- `Casein.Ops.GateQueue` — host flock observation (`/proc` + lock path)
- `CaseinWeb.WorkspaceLive.Show.FleetPanel` / `FleetEvents` — badge + drawer
- `Casein.Agents.TerminalTools.OrchestrationStatus` — Jido action / MCP tool
- `Casein.Labels.enrich_topology/2` — join label strings onto panes
- `Casein.Terminals.PaneState` — strips bare runtime banners from `task_summary`
- Wired from `Casein.Agents.TerminalTools.Impl.Session.topology/1`,
  `Casein.Operator.SituationDigest`, and cockpit `assign_tmux_window_tabs/1`
