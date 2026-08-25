# Jido workspace and fleet budgets

[#1018](https://github.com/dl-alexandre/casein/issues/1018) (parent
[#1012](https://github.com/dl-alexandre/casein/issues/1012)). Consumes the
#1014 pod, #1015 actions, #1016 projection, and #1017 skills. It does not
reimplement those contracts.

The migration exists because one manager plus many OpenCode workers burns
processes, RSS, and provider slots. Headless Jido must prove the reduction
and fail honestly when a budget is exhausted.

## Limits

Operators change limits through `config :casein, :jido_pod` or env:

| Key | Env | Default | Effect |
|-----|-----|---------|--------|
| `max_running_per_workspace` | `CASEIN_JIDO_MAX_RUNNING_PER_WORKSPACE` | 2 | Active workers in one workspace |
| `max_queued_per_workspace` | `CASEIN_JIDO_MAX_QUEUED_PER_WORKSPACE` | 4 | Admit past this rejects |
| `max_running_fleet` | `CASEIN_JIDO_MAX_RUNNING_FLEET` | 8 | Active workers host-wide |
| `max_share_per_workspace` | `CASEIN_JIDO_MAX_SHARE_PER_WORKSPACE` | 0.5 | Hard share of the fleet. One workspace cannot take every slot |
| `max_provider_inflight` | `CASEIN_JIDO_MAX_PROVIDER_INFLIGHT` | 4 | Shared provider/model calls |
| `max_worker_memory_bytes` | `CASEIN_JIDO_MAX_WORKER_MEMORY_BYTES` | 2_000_000 | Per-attempt term size (not content) |
| `max_action_output_bytes` | `CASEIN_JIDO_MAX_ACTION_OUTPUT_BYTES` | 256_000 | Per-action result size |
| `max_crash_rate` | `CASEIN_JIDO_MAX_CRASH_RATE` | 5 | Crashes in `crash_window_ms` |
| `max_leaked_leases` | — | 0 | Stale unreleased leases |

Exceeding a budget **queues** when the workspace queue has room, otherwise
**rejects**. Reasons are honest atoms:

`workspace_limit` · `queue_full` · `fleet_limit` · `fairness` ·
`workspace_share` · `provider_limit` · `memory_limit` · `crash_rate` ·
`lease_leak` · `rss_pressure` · `cpu_pressure` · `draining`

`JidoPod.admit/1` still returns `{:error, :backpressure}` for a full queue
(#1014). Other rejects return the reason atom. Queued attempts keep
`reason` on the public status.

## Observability

- Activity `source: :jido_budgets` records `action` + `reason` (no prompts,
  source, secrets, or output).
- `Casein.Agents.JidoBudgets.snapshot/1` and workspace status `jido_budgets`
  show last decision, fleet running, provider inflight, leaked leases.
- CPU/RSS come from `HostCapacity`. An unknown probe is never spare capacity.
- Resource pressure drains the workspace queue **before** refusing new work.

## Benchmark

```bash
mise exec -- mix casein.jido_bench --n 4
```

Or `Casein.Agents.JidoBudgets.benchmark/1`. Scenarios: idle, burst,
provider-slow, provider-failure, cancel, workspace-contention.

Jido numbers are measured. OpenCode numbers are the documented cost model
(one OS/TUI process + pane per worker, default 250MB RSS). The report
records revision, configuration, provider mode, task mix, and sample size.

## Go / no-go

| Check | Go | Rollback |
|-------|----|----------|
| process ratio (Jido delta / OpenCode N) | `< 0.5` | `>= 1.0` |
| RSS ratio | `< 0.5` | — |
| burst error rate | `<= 0.05` | above |
| cancel | every cancel reaches `cancelled` | miss |
| contention | both workspaces run | one workspace starved |
| leaked leases | `0` | any leak |

Rollback trigger: flip `CASEIN_JIDO_HEADLESS=0` (or remove the workspace
from `CASEIN_JIDO_HEADLESS_WORKSPACES`) so admit returns
`{:error, :legacy_opencode}` and callers keep launching OpenCode.
