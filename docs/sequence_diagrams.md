# Sequence Diagrams

> Version: v1 (aligned with implementation as of M10)

## Diagram 1: JX triggers immediate local run

```text
JX          DevIDE API          Policy        Commands.Run      History       Manager
│                  │                │                │                │             │
│ POST /api/workspaces/:id/runs │                │                │             │
│ {command_id: "test"}          │                │                │             │
│────────────────────────────────>│                │                │             │
│                  │ can_run_command?               │                │             │
│                  │────────────────>│                │                │             │
│                  │  Decision(allow)                │                │             │
│                  │<────────────────│                │                │             │
│                  │ audit_decision(allow)           │                │             │
│                  │─────────────────────────────────────────────────>│             │
│                  │                │                │                │             │
│                  │ Run.start/4    │                │                │             │
│                  │────────────────────────────────>│                │             │
│                  │                │                │ spawn(argv)    │             │
│                  │                │                │────────────────>│             │
│                  │                │                │ record started │                │
│                  │                │                │─────────────────────────────────>
│                  │                │                │                │ create(record)│
│                  │                │                │                │──────────────>│
│                  │                │                │ {:ok, pid}     │                │
│                  │<────────────────────────────────│                │                │
│ 201 Created      │                │                │                │                │
│ {run payload}    │                │                │                │                │
│<─────────────────│                │                │                │                │
│                  │                │                │                │                │
│                  │                │                │ {:cmd_exit, 0}│                │
│                  │                │                │────────────────>│                │
│                  │                │                │ finish_run     │                │
│                  │                │                │─────────────────────────────────>
│                  │                │                │                │ update(record) │
│                  │                │                │                │──────────────>│
```

## Diagram 2: JX triggers durable runner assignment

```text
JX          DevIDE API          Policy        Runners         SafeAction      MemoryAdapter
│                  │                │                │                │             │
│ POST /api/workspaces/:id/runs    │                │                │             │
│ {command_id:"test",             │                │                │             │
│  execution_protocol:"jx.runner.v1",             │                │             │
│  runner_requirements:{...}}      │                │                │             │
│────────────────────────────────>│                │                │             │
│                  │ can_run_command?                │                │             │
│                  │────────────────>│                │                │             │
│                  │  Decision(allow)                │                │             │
│                  │<────────────────│                │                │             │
│                  │ audit_decision(allow)           │                │             │
│                  │─────────────────────────────────────────────────────────────────>│
│                  │                │                │                │             │
│                  │ Runners.enqueue_command/2       │                │             │
│                  │─────────────────────────────────────────────────────────────────>
│                  │                │                │ fetch_command  │             │
│                  │                │                │──────────────>│             │
│                  │                │                │ {:ok, action}  │             │
│                  │                │                │                │             │
│                  │                │                │ create_assignment            │
│                  │                │                │────────────────────────────>│
│                  │                │                │                │             │
│ 201 Created      │                │                │                │             │
│ {protocol, assignment}           │                │                │             │
│<─────────────────│                │                │                │             │

[ ... runner polls and claims ... ]

Runner      DevIDE API          Runners         MemoryAdapter
│                  │                │                │
│ POST /api/runner/v1/assignments/poll              │
│ {protocol, runner_id, capabilities, routing}      │
│────────────────────────────────>│                │
│                  │ Runners.poll/1 │                │
│                  │────────────────────────────────>│
│                  │                │ claim_one/1    │
│                  │                │────────────────>
│                  │                │ {:ok, claimed} │
│                  │                │                │
│                  │ 200 OK         │                │
│                  │ {protocol, assignment}          │
│<─────────────────│                │                │

[ ... runner executes command locally ... ]

Runner      DevIDE API          Runners         MemoryAdapter
│                  │                │                │
│ POST /api/runner/v1/assignments/:id/reports      │
│ {claim_token, event:"started"}   │                │
│────────────────────────────────>│                │
│                  │ append_report/2                │
│                  │────────────────────────────────>│
│                  │                │                │
│                  │ 201 Created    │                │
│                  │ {protocol, report}             │
│<─────────────────│                │                │

[ ... more progress reports ... ]

Runner      DevIDE API          Runners         MemoryAdapter
│                  │                │                │
│ POST /api/runner/v1/assignments/:id/complete     │
│ {claim_token, evidence:{...}}    │                │
│────────────────────────────────>│                │
│                  │ Runners.complete/2              │
│                  │────────────────────────────────>│
│                  │                │                │
│                  │ 200 OK         │                │
│                  │ {protocol, assignment, report} │
│<─────────────────│                │                │

[ ... JX replays to reconcile ... ]

JX          DevIDE API          Runners         MemoryAdapter
│                  │                │                │
│ GET /api/runner/v1/assignments/:id              │
│────────────────────────────────>│                │
│                  │ Runners.replay/1               │
│                  │────────────────────────────────>│
│                  │                │                │
│                  │ 200 OK         │                │
│                  │ {protocol, assignment, reports}│
│<─────────────────│                │                │
```

## Diagram 3: Policy deny + audit

```text
JX          DevIDE API          Policy        Audit.MemoryAdapter
│                  │                │                │
│ POST /api/workspaces/:id/runs  │                │
│ {command_id: "test"}           │                │
│────────────────────────────────>│                │
│                  │ can_run_command?                │
│                  │────────────────>│                │
│                  │ Decision(deny, :shared_stage_guarded)            │
│                  │<────────────────│                │
│                  │                │                │
│                  │ audit_decision(deny)            │
│                  │────────────────────────────────>│
│                  │                │                │
│ 403 Forbidden    │                │                │
│ {error:"unsafe_db_isolation"}   │                │
│<─────────────────│                │                │
```

## Diagram 4: Runner claim rejected (capabilities mismatch)

```text
Runner      DevIDE API          Runners         SafeAction
│                  │                │                │
│ POST /api/runner/v1/assignments/poll              │
│ {capabilities: ["git:v1"]}       │                │
│────────────────────────────────>│                │
│                  │ Runners.poll/1 │                │
│                  │────────────────>│                │
│                  │                │ compatible_ids(["git:v1"])     │
│                  │                │────────────────>│
│                  │                │ []               │
│                  │                │<────────────────│
│                  │                │                │
│                  │ 204 No Content │                │
│<─────────────────│                │                │
```

## Diagram 5: Lease expiration

```text
Time ──────────────────────────────────────────────────────────────►

Runner      DevIDE API          Runners         MemoryAdapter       Expiry Cron
│                  │                │                │                │
│ claim (lease = 15 min)            │                │                │
│────────────────────────────────>│                │                │
│                  │                │                │                │
│ [runner stalls, no reports]      │                │                │
│                  │                │                │                │
│                  │                │                │                │ expire_leases(now)
│                  │                │                │                │────────────────>
│                  │                │                │ transition to "expired"           │
│                  │                │                │<───────────────│                │
│                  │                │                │                │                │
│ [runner wakes up, tries report]  │                │                │                │
│────────────────────────────────>│                │                │                │
│                  │ Runners.append_report/2         │                │                │
│                  │────────────────────────────────>│                │                │
│                  │                │                │                │                │
│                  │ 409 Conflict   │                │                │                │
│                  │ {error:"lease_expired"}         │                │                │
│<─────────────────│                │                │                │                │
│                  │                │                │                │
│ [runner re-polls]                │                │                │                │
│────────────────────────────────>│                │                │                │
│                  │ 204 No Content │                │                │                │
│<─────────────────│                │                │                │                │
│                  │                │                │ (assignment is expired, not claimable)
```

## Diagram 6: Exact duplicate terminal report

```text
Runner      DevIDE API          Runners         MemoryAdapter
│                  │                │                │
│ POST .../fail    │                │                │
│ {client_report_id:"seq-9",       │                │
│  evidence:{exit_code:1}}       │                │
│────────────────────────────────>│                │
│                  │ Runners.fail/2 │                │
│                  │────────────────────────────────>│
│                  │                │                │
│                  │ 200 OK         │                │
│                  │ {assignment, report}           │
│<─────────────────│                │                │
│                  │                │                │
│ [network timeout, runner retries]                │
│                  │                │                │
│ POST .../fail    │                │                │
│ {client_report_id:"seq-9",       │                │
│  evidence:{exit_code:1}}       │                │
│────────────────────────────────>│                │
│                  │ Runners.fail/2 │                │
│                  │────────────────────────────────>│
│                  │                │ existing report with same client_report_id
│                  │                │                │
│                  │ exact duplicate detected        │
│                  │                │                │
│                  │ 200 OK         │                │
│                  │ {same assignment, same report} │
│<─────────────────│                │                │
```

## Diagram 7: Workspace status read (export)

```text
Browser     DevIDE LiveView     Export.WorkspaceStatus       State       Commands.Run
│                  │                │                │                │
│ GET /workspaces/:id            │                │                │
│────────────────────────────────>│                │                │
│                  │                │                │                │
│                  │ status/1     │                │                │
│                  │────────────────>│                │                │
│                  │                │ State.get/1    │                │
│                  │                │────────────────>│                │
│                  │                │ {:ok, record}  │                │
│                  │                │<────────────────│                │
│                  │                │                │                │
│                  │                │ git_summary    │                │
│                  │                │ (spawns git)   │                │
│                  │                │                │                │
│                  │                │ active_run_summary            │
│                  │                │ Run.whereis + Run.state        │
│                  │                │─────────────────────────────────>│
│                  │                │ {:ok, snap}    │                │
│                  │                │<─────────────────────────────────│
│                  │                │                │                │
│                  │                │ recent_runs    │                │
│                  │                │ History.recent_for            │
│                  │                │                │                │
│                  │                │ recent_proposals              │
│                  │                │ Proposals.discover + ConflictAnalyzer
│                  │                │                │                │
│                  │                │ Sanitizer.scrub/1 (strip creds)
│                  │                │                │                │
│                  │ render page  │                │                │
│<─────────────────│                │                │                │
```

## Diagram 8: Terminal subsystem (reconnect)

```text
Browser     TerminalChannel     Terminals.Session      erlexec       tmux
│                  │                │                │                │
│ join terminal:workspace:id:sid │                │                │
│────────────────────────────────>│                │                │
│                  │                │                │                │
│                  │ start_or_reconnect/2            │                │
│                  │────────────────>│                │                │
│                  │                │ Registry lookup               │
│                  │                │                │                │
│                  │                │ [found existing Session]       │
│                  │                │                │                │
│                  │                │ attach subscriber             │
│                  │                │                │                │
│                  │                │ (if no Session exists)        │
│                  │                │                │                │
│                  │                │ spawn pty      │                │
│                  │                │────────────────>│                │
│                  │                │                │ exec("tmux new-session -A -s ...")
│                  │                │                │────────────────>│
│                  │                │                │                │
│                  │                │                │ [tmux already exists → attach]
│                  │                │                │                │
│                  │ push data to browser           │                │
│                  │<────────────────                │                │
│                  │                │                │                │
│ [browser sends keypress]         │                │                │
│────────────────────────────────>│                │                │
│                  │                │ send stdin     │                │
│                  │                │────────────────>│                │
│                  │                │                │                │
│ [tmux output]    │                │                │                │
│                  │                │<────────────────                │
│                  │                │ (all PTY output routes through stderr)
│                  │                │                │                │
│ [browser closes tab]             │                │                │
│────────────────────────────────>│                │                │
│                  │                │ subscriber removed             │
│                  │                │                │                │
│ [new browser tab opens]          │                │                │
│────────────────────────────────>│                │                │
│                  │                │ reattach to same Session      │
│                  │                │                │                │
│                  │                │ tmux still running            │
```
