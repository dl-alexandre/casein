# State Machines

> Version: v2 (raw + MCP reality)
>
> **History:** earlier versions documented the runner-assignment lifecycle,
> the claim-lease lifecycle, and the runtime-orchestration lifecycle. Those
> subsystems were removed. What remains: terminal sessions, review-agent
> runs, workspace modes, and audit.

## Terminal session lifecycle

A workspace terminal is a durable tmux session fronted by a `Ghostty.PTY` and
`Ghostty.Terminal` cell grid that live for the LiveView socket.

```
join/attach ──► spawn PTY (tmux new-session -A) ──► attached
     ▲                                                  │
     │ reattach (replay scrollback from tmux history)   │ disconnect
     └──────────────────────────────────────────────────┘
                                                         │
                          no subscribers + idle TTL ──► tmux kill-session
```

Rules:

1. The tmux session is the persistence boundary; it outlives the socket and
   survives BEAM restarts.
2. Reattaching any browser tab runs `tmux new-session -A` (attach if exists,
   else create) and rebuilds the grid from tmux history.
3. `Casein.Terminals.TmuxJanitor` schedules `tmux kill-session` after
   `:tmux_idle_seconds` once a session has no subscribers; a new subscriber
   cancels the pending kill. Only `casein_`-prefixed sessions are killed.
4. Raw input is admitted only when `Policy.can_use_raw_terminal?/1` allows; the
   verdict is recorded as `run.session_attached` / `run.session_denied`.

See [`terminal.md`](terminal.md) for the full subsystem and multi-pane model.

## Review-agent run lifecycle (`Casein.Agents.Run`)

```
:start ──► :running ──► :succeeded | :failed | :timed_out
                              │
                              └──► 2-minute linger ──► process exits
```

### Rules

1. One in-flight review run per workspace (Registry-keyed by workspace id).
2. A new `Run.start/5` for the same workspace replaces a terminal-status
   process; a new start while `:running` returns `{:error, :already_running}`.
3. Hard timeout kills the OS process and sets `:timed_out`.
4. Subscriber (LiveView) gets `{:cmd_data, ...}` and `{:cmd_exit, ...}` messages.
5. Output buffer is capped at 256 KiB (`@max_buffer_bytes`).
6. argv is fixed by `Casein.Agents.ReviewCommand` — there is no path to run an
   arbitrary command, send a prompt, or apply a patch.
7. Runs emit `run.started` and one terminal run-ledger event (`run.succeeded`,
   `run.failed`, or `run.timed_out`) using a shared `run_id`.

## Workspace mode lifecycle

Modes are resolved in order:

1. Config override (`:workspace_modes` map, keyed by workspace id)
2. Persisted mode (`WorkspaceRecord.mode`)
3. Default (`:default_workspace_mode` config, or `:manual`)

Modes (assuming a workspace operator/owner; a non-operator is always denied
`:forbidden` regardless of mode):

| Mode | `can_apply_proposal?` | `can_enable_agent_write?` |
|---|---|---|
| `:manual` | Allow | Allow, only with an active `Workspaces.grant_agent_write_unlock/3` unlock — else deny `:agent_write_locked` |
| `:review` | Deny (`:requires_manual_mode`) | Deny (`:requires_manual_mode`) |
| `:agent_write_locked` | Deny (`:requires_manual_mode`) | Deny (`:requires_manual_mode`) |
| `:shared_stage_guarded` | Deny (`:requires_manual_mode`) | Deny (`:shared_stage_guarded`) |

DB isolation (`:shared_stage`, `:unsafe`) forces `:shared_stage_guarded`/
`:unsafe_db` denials for both checks, unconditionally — checked before mode
or unlock state, and never overridable by an active unlock.

`can_apply_proposal?/1` is the write path for `Casein.ProposalApply`
(a human reviewing and applying a proposal diff, gated by workspace
operator + `:manual` mode). `can_enable_agent_write?/1` is the *separate*,
stricter gate for `Casein.Proposals.AutoApply` — a server-spawned
review-agent run self-applying its own proposal with no per-change human
click, requiring `:manual` mode **and** a currently-active, human-granted,
time-boxed unlock. A deployment-wide config kill switch
(`Casein.Proposals.AutoApply` `enabled:`, default `false`) additionally
gates the latter regardless of any per-workspace unlock.

## Audit event lifecycle

Every audit event is immutable:

```
emit/1 or emit_decision/2 ──► adapter.record/1 ──► store
                                              │
                                              └── MemoryAdapter: capped ring
                                              └── EctoAdapter: `audit_events` table
```

Events carry: `id`, `workspace_id`, `actor_id`, `action`, `target_type`,
`target_ref`, `decision`, `reason`, `metadata`, `inserted_at`.

A blocked generic policy decision **must** produce an audit event with
`action: "policy.blocked"`. Run-ledger events
(`Casein.Runs.Ledger`) carry `metadata.ledger == "run"` and use the
`run.*` actions documented in [`glossary.md`](glossary.md) §Event taxonomy.
