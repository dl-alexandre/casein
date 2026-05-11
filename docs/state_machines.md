# State Machines

> Version: v1 (aligned with `DevIDE.Runners.StateMachine` and
> `DevIDE.Commands.Run` as of M10)

## Runner assignment lifecycle

The canonical state machine is defined in `DevIDE.Runners.StateMachine`.

```
┌─────────┐   claim   ┌─────────┐   start   ┌─────────┐
│ queued  │ ───────► │ claimed │ ───────► │ running │
└─────────┘          └────┬────┘          └────┬────┘
     │                    │                    │
     │ expire             │ succeed            │ succeed
     │ abandon            │ fail               │ fail
     │                    │ expire             │ expire
     ▼                    │ abandon            │ abandon
┌─────────┐               ▼                    ▼
│ expired │          ┌─────────┐         ┌─────────┐
│abandoned│          │succeeded│         │ failed  │
└─────────┘          └─────────┘         └─────────┘
```

### States

| State | Terminal? | Meaning |
|---|---|---|
| `queued` | No | Awaiting a compatible runner to claim |
| `claimed` | No | Runner holds claim token; lease ticking |
| `running` | No | Runner has sent a `started`/`progress`/`stdout`/`stderr`/`evidence` report |
| `succeeded` | **Yes** | Runner called `complete` with evidence |
| `failed` | **Yes** | Runner called `fail` with evidence |
| `expired` | **Yes** | Lease expired before terminal report |
| `abandoned` | **Yes** | Explicitly abandoned (runner lost, system shutdown, etc.) |

### Valid transitions

| From | Event | To |
|---|---|---|
| `queued` | `claim` | `claimed` |
| `queued` | `expire` | `expired` |
| `queued` | `abandon` | `abandoned` |
| `claimed` | `start` | `running` |
| `claimed` | `succeed` | `succeeded` |
| `claimed` | `fail` | `failed` |
| `claimed` | `expire` | `expired` |
| `claimed` | `abandon` | `abandoned` |
| `running` | `succeed` | `succeeded` |
| `running` | `fail` | `failed` |
| `running` | `expire` | `expired` |
| `running` | `abandon` | `abandoned` |
| any terminal | any | `{:error, :assignment_terminal}` |
| any invalid | any | `{:error, :invalid_transition}` |

### Start-event detection

Reports with these `event` values move a `claimed` assignment to `running`:

- `started`
- `progress`
- `stdout`
- `stderr`
- `evidence`

`heartbeat` does **not** advance the state machine.

## Claim lease lifecycle

```
queued_at ──► claimed_at ──► lease_expires_at ──► completed_at
     │            │                  │                  │
     │            │         [lease still valid]       │
     │            │                  │                  │
     │      claim token      expire_leases/1      terminal report
     │       issued            may expire            or abandon
     │            │                  │                  │
     ▼            ▼                  ▼                  ▼
   claimable   fetch_claimed    lease_expired?    same_claim_token?
```

## Runtime lifecycle

Runtime orchestration models environment placement only. It never authorizes a
command and never lets a runner create assignments.

```
requested -> provisioned -> bound -> active -> idle -> expired -> cleaned
        \          \           \         \        \-> failed -> cleaned
```

| From | Event | To |
|---|---|---|
| `nil` | `runtime_requested` | `requested` |
| `requested` | `runtime_provisioned` | `provisioned` |
| `requested` | `runtime_failed` | `failed` |
| `provisioned` | `runtime_bound` | `bound` |
| `bound` | `runtime_active` | `active` |
| `active` | `runtime_idle` | `idle` |
| `bound` | `runtime_idle` | `idle` |
| `idle` | `runtime_bound` | `bound` |
| any non-cleaned runtime | `runtime_expired` | `expired` |
| `expired` | `runtime_cleaned` | `cleaned` |
| `failed` | `runtime_cleaned` | `cleaned` |

Lifecycle events are append-only. `DevIDE.Runtimes.project_lifecycle/1` reduces
them into the runtime projection during recovery checks.

### Lease rules

1. `lease_expires_at` is set at claim time (`DateTime.add(now, default_lease_ms())`).
2. Default lease is 15 minutes (`:runner_assignment_lease_ms` config).
3. `fetch_claimed/3` rejects any report or terminal call if `lease_expired?` is true, returning `{:error, :lease_expired}`.
4. `expire_leases/1` is called by a periodic process (or manual trigger) to transition expired assignments to `expired`.
5. A terminal report from a runner whose lease just expired is rejected; the runner must re-poll and reclaim.

## Immediate command lifecycle (`DevIDE.Commands.Run`)

```
:start ──► :running ──► :succeeded | :failed | :timed_out
                              │
                              └──► 2-minute linger ──► process exits
```

### Rules

1. One in-flight run per workspace (Registry-keyed by workspace id).
2. A new `Run.start/4` for the same workspace kills a terminal-status process and replaces it.
3. A new `Run.start/4` while `:running` returns `{:error, :already_running}`.
4. Hard timeout kills the OS process and sets `:timed_out`.
5. Subscriber (LiveView) gets `{:run_data, ...}` and `{:run_exit, ...}` messages.
6. Output buffer is capped at 256 KiB (`@max_buffer_bytes`).
7. History output is capped at 64 KiB (`@output_cap`).

## Workspace mode lifecycle

Modes are resolved in order:

1. Config override (`:workspace_modes` map, keyed by workspace id)
2. Persisted mode (`WorkspaceRecord.mode`)
3. Default (`:default_workspace_mode` config, or `:review`)

Modes:

| Mode | `can_apply_proposal?` | `can_enable_agent_write?` | `can_run_command?` (JX/agent) |
|---|---|---|---|
| `:manual` | Deny (`:not_implemented`) | Deny (`:agent_write_locked`) | Allow (if on allowlist) |
| `:review` | Deny (`:not_implemented`) | Deny (`:agent_write_locked`) | Allow (if on allowlist) |
| `:agent_write_locked` | Deny (`:not_implemented`) | Deny (`:agent_write_locked`) | Allow (if on allowlist) |
| `:shared_stage_guarded` | Deny (`:not_implemented`) | Deny (`:shared_stage_guarded`) | Deny (`:shared_stage_guarded`) |

DB isolation (`:shared_stage`, `:unsafe`) forces `:shared_stage_guarded` for JX/agent runners regardless of mode.

## Audit event lifecycle

Every audit event is immutable:

```
emit/1 or emit_decision/2 ──► adapter.record/1 ──► store
                                              │
                                              └── MemoryAdapter: capped ring
                                              └── EctoAdapter (M11): `audit_events` table
```

Events carry: `id`, `workspace_id`, `actor_id`, `action`, `target_type`, `target_ref`, `decision`, `reason`, `metadata`, `inserted_at`.

A blocked policy decision **must** produce an audit event with `action: "policy.blocked"`.
