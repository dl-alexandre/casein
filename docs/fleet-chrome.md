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

## Code

- `Casein.Terminals.FleetChrome` — pure per-pane projection
- `Casein.Terminals.FleetBoard` — pure session aggregate over window tabs
- `CaseinWeb.WorkspaceLive.Show.FleetPanel` / `FleetEvents` — badge + drawer
- `Casein.Labels.enrich_topology/2` — join label strings onto panes
- `Casein.Terminals.PaneState` — strips bare runtime banners from `task_summary`
- Wired from `Casein.Agents.TerminalTools.Impl.Session.topology/1`,
  `Casein.Operator.SituationDigest`, and cockpit `assign_tmux_window_tabs/1`
