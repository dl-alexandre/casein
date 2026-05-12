# Runtime Orchestration Plan v1

> Status: Historical planning document. Runtime orchestration v1 is now
> implemented; see [`docs/runtime_orchestration.md`](runtime_orchestration.md)
> for the current lifecycle, placement, CLI, and recovery contract.
>
> This document defines the architecture, state machines, event taxonomy, and
> trust boundaries for workspace runtime orchestration in DevIDE. It does not
> add execution power; it describes how existing safe actions will be placed,
> isolated, and cleaned up by a future runtime orchestrator.
>
> See [`docs/architecture.md`](architecture.md) for the existing system context.
> See [`docs/protocol_governance.md`](protocol_governance.md) for the protocol
> evolution policy that governs when this plan becomes code.

## Goal

Enable DevIDE to place runner assignments onto specific workspace runtimes
(git worktrees, branch-isolated checkouts, pre-warmed environments) while
preserving the existing safety invariants:

- DevIDE decides what can execute (safe actions only).
- JX may request placement but never controls argv.
- Runners remain policy-dumb (they claim, run what they are given, report).
- No shell/argv forwarding, no generic HTTP proxying, no new mutation paths.

## Non-goals

- Adding new safe-action kinds (e.g., `git:v1` operations as first-class actions).
- Letting runners create workspaces or mutate workspace state outside the
  existing `Commands.allowlist/0`.
- Generic SSH or container orchestration.
- Agent write enablement (still policy-denied as of M10).

## Concepts

### Runtime
A filesystem context where a workspace safe action executes. A runtime is not a
VM or container; it is a placement unit: a directory tree + environment +
optional tmux session. Multiple assignments may reuse a runtime if isolation
policy permits.

### Worktree
A git worktree (`git worktree add`) created from the workspace's primary
repository. Worktrees provide branch isolation without full clone overhead.

### Placement
The decision of which runtime (and optionally which host) receives an
assignment. Placement is advisory; the runner still claims the assignment
through the existing poll endpoint.

### Runtime profile
A declarative description of a runtime's properties, stored in assignment
metadata and used for capability routing:

```json
{
  "runtime_id": "wt-main-abc123",
  "runtime_path": "/workspaces/my-app/worktrees/wt-main-abc123",
  "branch": "main",
  "worktree": true,
  "pre_warmed": false,
  "ttl_seconds": 3600
}
```

## Trust boundaries

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Trust Boundary Map                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Boundary A: JX → DevIDE API                                            │
│    • JX may include `runner_requirements` in enqueue (existing v1)       │
│    • JX may request `runtime_id` or `runtime_path` (future)            │
│    • JX may request branch isolation strategy (e.g., "worktree")       │
│    • JX NEVER supplies argv, shell, or executable paths                │
│    • DevIDE validates all placement hints against workspace state      │
│                                                                         │
│  Boundary B: DevIDE → Runtime Orchestrator (future module)             │
│    • Orchestrator receives only safe-action ids + placement metadata   │
│    • Orchestrator may create/destroy worktrees and tmux sessions       │
│    • Orchestrator may set environment variables (from safe registry)   │
│    • Orchestrator NEVER receives arbitrary argv or shell strings       │
│                                                                         │
│  Boundary C: Runtime Orchestrator → Host Filesystem                    │
│    • All paths validated through `DevIDE.Files.PathSafety`             │
│    • Worktrees created only under allowed roots                        │
│    • tmux sessions named with `devide_` prefix only                    │
│    • Cleanup removes only known runtime paths                        │
│                                                                         │
│  Boundary D: Runner → DevIDE API (existing, unchanged)                 │
│    • Runner polls, claims, reports exactly as v1                       │
│    • Runner may include `runtime_id` in poll for affinity              │
│    • Runner NEVER creates runtimes or assignments                      │
│                                                                         │
│  Boundary E: Runner → Runtime (host-local execution)                   │
│    • Runner executes only the argv from `SafeAction.to_runner_payload/1`│
│    • Runner executes only inside the assigned `runtime_path`           │
│    • Runner may attach to tmux session for terminal replay             │
│    • Runner NEVER writes outside `runtime_path` or runs shell strings    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## State machines

### Runtime lifecycle (new)

```
┌──────────┐  provision  ┌──────────┐  activate  ┌──────────┐
│ pending  │ ──────────► │ ready    │ ─────────► │ active   │
└──────────┘             └──────────┘            └────┬─────┘
      │                    │       │                  │
      │ fail               │ idle  │                  │ assignment_claimed
      │                    │       │                  │
      ▼                    ▼       ▼                  ▼
┌──────────┐            ┌──────────┐            ┌──────────┐
│ failed   │            │ stale    │            │ assigned │
└──────────┘            └────┬─────┘            └────┬─────┘
                           │                       │
                           │ ttl_expired           │ assignment_released
                           │                       │
                           ▼                       ▼
                      ┌──────────┐           ┌──────────┐
                      │ cleaned  │           │ ready    │
                      └──────────┘           └──────────┘
```

#### States

| State | Meaning | Actor |
|---|---|---|
| `pending` | Provisioning requested, worktree/tmux not ready yet | Orchestrator |
| `ready` | Filesystem and tmux session exist, no active assignment | Orchestrator |
| `active` | Runtime is in use (tmux session has runner or human attached) | Runner / Human |
| `assigned` | A runner assignment is executing in this runtime | Runner |
| `stale` | No activity for > TTL, candidate for cleanup | Orchestrator (cron) |
| `cleaned` | Filesystem removed, tmux session killed, record archived | Orchestrator |
| `failed` | Provisioning failed (disk full, git error, etc.) | Orchestrator |

#### Transitions

| From | Event | To | Authority |
|---|---|---|---|
| `pending` | `provision_success` | `ready` | Orchestrator |
| `pending` | `provision_failure` | `failed` | Orchestrator |
| `ready` | `assignment_claimed` | `assigned` | DevIDE (on runner poll match) |
| `assigned` | `assignment_released` | `ready` | DevIDE (on terminal report) |
| `ready` | `human_attach` | `active` | Human (terminal channel join) |
| `active` | `human_detach` | `ready` | Human (terminal channel leave) |
| `ready` | `ttl_expired` | `stale` | Orchestrator (cron check) |
| `stale` | `rejuvenated` | `ready` | Orchestrator (human activity detected) |
| `stale` | `cleanup_complete` | `cleaned` | Orchestrator |
| `active` | `ttl_expired` | `stale` | Orchestrator (with warning, then grace period) |

**Invariant:** A runtime in `assigned` state must have exactly one
`Assignment` with `status` in `["claimed", "running"]` referencing it.

### Assignment → runtime binding (new metadata field)

The existing `Assignment` struct gains an optional `runtime_id` field in
`metadata` (not a new struct field — protocol v1 additive):

```json
{
  "metadata": {
    "runtime_id": "wt-main-abc123",
    "runtime_path": "/workspaces/my-app/worktrees/wt-main-abc123",
    "branch": "main",
    "worktree": true
  }
}
```

When an assignment is queued with runtime metadata:
1. The orchestrator ensures the runtime is `ready` before the assignment becomes
   claimable.
2. If provisioning fails, the assignment transitions to `failed` with
   `failure_class: "enqueue_failed"` and `reason: "runtime_unavailable"`.

## Event taxonomy

### Orchestrator events (future audit target_type)

These events will be emitted to `DevIDE.Audit` with `target_type: "runtime"`:

| Action | When | Actor |
|---|---|---|
| `runtime.provision_requested` | JX enqueue includes runtime hint | JX |
| `runtime.provisioned` | Worktree + tmux ready | Orchestrator |
| `runtime.provision_failed` | Worktree or tmux creation failed | Orchestrator |
| `runtime.assigned` | Runner claimed assignment bound to runtime | DevIDE |
| `runtime.released` | Assignment terminal, runtime back to ready | DevIDE |
| `runtime.stale_detected` | TTL expired, no activity | Orchestrator |
| `runtime.cleaned` | Filesystem removed, tmux killed | Orchestrator |
| `runtime.rejuvenated` | Human or runner activity on stale runtime | Orchestrator |

### Runner events (existing, extended)

The runner poll request may include `runtime_id` for affinity:

```json
{
  "protocol": "jx.runner.v1",
  "runner_id": "runner-42",
  "capabilities": ["workspace-command:v1"],
  "runtime_id": "wt-main-abc123"
}
```

DevIDE uses `runtime_id` only for scheduling, never for authorization.

## Capability routing extension

The existing capability routing in `Runners.poll/1` will be extended to
support runtime-aware scheduling without protocol bump:

| Poll field | Assignment metadata match | Scheduling effect |
|---|---|---|
| `runtime_id` | `metadata["runtime_id"]` | Pin runner to specific runtime |
| `runtime_path` | `metadata["runtime_path"]` | Pin runner to specific path |
| `host` | `metadata["routing"]["host"]` | Existing (unchanged) |
| `branch_isolation` | `metadata["routing"]["branch_isolation"]` | Existing (unchanged) |

This is additive and advisory. Runners without `runtime_id` can still claim
assignments that have one (the orchestrator ensures the runtime is ready first).

## Implementation phases

### Phase 1: Runtime registry (M11 candidate)

**Scope:** Add a runtime registry without changing the runner protocol.

**Modules:**
- `DevIDE.Runtimes` — public API for runtime CRUD
- `DevIDE.Runtimes.Runtime` — struct: `id`, `workspace_id`, `path`, `branch`, `status`, `ttl_seconds`, `created_at`, `last_active_at`
- `DevIDE.Runtimes.MemoryAdapter` — in-memory store (parallel pattern to `Runners.MemoryAdapter`)

**Rules:**
- Runtime creation is triggered by enqueue metadata, not by JX directly.
- Runtime paths are validated via `Files.PathSafety`.
- No tmux or git worktree creation yet — only registry records.

**State machine:** `pending → ready | failed` (simplified, no `active`/`assigned` yet)

**Tests:**
- Runtime registry drift tests (struct shape, state machine)
- Path safety validation tests
- Audit event emission tests

### Phase 2: Worktree provisioning (M12 candidate)

**Scope:** Actually create git worktrees when runtime registry enters `pending`.

**Modules:**
- `DevIDE.Runtimes.Provisioner` — `git worktree add` + `tmux new-session`
- `DevIDE.Runtimes.TmuxSession` — tmux session lifecycle wrapper (similar to `Terminals.Tmux`)

**Rules:**
- Worktree directory must be under the workspace's allowed root.
- tmux session name: `devide_runtime_{runtime_id}`
- On provision failure, runtime transitions to `failed`, assignment is rejected.
- On provision success, runtime transitions to `ready`, assignment becomes claimable.

**State machine:** Full lifecycle (`pending → ready → assigned → ready → stale → cleaned`)

**Tests:**
- Provision success/failure tests
- tmux session naming tests
- Path safety tests

### Phase 3: Stale runtime cleanup (M12-M13)

**Scope:** Background cron that cleans up old runtimes.

**Modules:**
- `DevIDE.Runtimes.Janitor` — periodic scan + cleanup
- `DevIDE.Runtimes.Cleanup` — safe removal (verify runtime_id in name before rm)

**Rules:**
- Never clean a runtime with `status: "assigned"`.
- Never clean a runtime with a live tmux session that has subscribers.
- Cleanup removes worktree directory, kills tmux session, transitions runtime to `cleaned`.
- Audit event emitted for every cleanup.

**Tests:**
- TTL calculation tests
- Cleanup safety tests (verify before remove)
- Race condition tests (cleanup while assignment active)

### Phase 4: Runner placement affinity (M13 candidate)

**Scope:** Runners can declare runtime affinity in poll requests.

**Changes:**
- `Runners.poll/1` already accepts `runtime_id` in `attrs` (routing_claim parses it).
- `Runners.MemoryAdapter.claim_one/1` already uses `routing_match?/2` which checks
  string requirements.
- No protocol bump needed — `runtime_id` is already in the routing map.

**Rules:**
- If runner requests `runtime_id: "wt-123"` and assignment has `metadata["routing"]["runtime_id"] == "wt-123"`, match succeeds.
- If runner does not request `runtime_id`, match is unaffected.

**Tests:**
- Routing match tests with runtime_id
- Poll + claim integration tests

### Phase 5: Human terminal + runtime integration (M14 candidate)

**Scope:** Browser terminal tabs attach to runtime tmux sessions instead of
workspace-scoped sessions.

**Changes:**
- `Terminals.Session` currently keys by `(workspace_id, sid)`.
- Extend to key by `(workspace_id, runtime_id, sid)` or reuse runtime tmux session.
- When a human opens a terminal in a workspace with runtimes, they get a
  runtime-specific tmux session.

**Rules:**
- Human terminal activity rejuvenates a stale runtime.
- Human terminals are read-only w.r.t. assignments (they don't claim or execute).

**Tests:**
- Terminal channel join/leave tests with runtime
- Rejuvenation tests

## Safety invariants (must hold across all phases)

1. **Argv authority stays in DevIDE.** Runners never receive unsanitized argv.
2. **No shell forwarding.** Worktree paths are validated; no shell interpolation.
3. **No generic proxy.** Runtime provisioning is local git + tmux only.
4. **Assignment creation stays in DevIDE.** JX enqueues; orchestrator provisions;
   runners claim. No runner creates assignments or runtimes.
5. **Cleanup is defensive.** Verify runtime_id in path and tmux name before
   removing anything.
6. **Audit everything.** Every provision, assignment, release, and cleanup emits
   an audit event.
7. **Graceful degradation.** If provisioning fails, the assignment fails cleanly
   with a known failure class, not a partial state.

## Open questions

1. **Runtime sharing:** Can multiple assignments share a `ready` runtime? If yes,
   the state machine needs a reference count. If no, simpler but more overhead.
   *Recommendation: no sharing for v1 (one assignment per runtime at a time).*

2. **Pre-warmed runtimes:** Should the orchestrator keep a pool of `ready`
   runtimes for hot branches? This reduces enqueue latency but increases disk
   usage.
   *Recommendation: deferred to M13; start with on-demand provisioning.*

3. **Multi-host:** How does a runner on host-b claim an assignment whose
   runtime is on host-a?
   *Recommendation: routing already supports `host` matching. Extend with
   explicit `runtime_host` field in metadata if needed.*

4. **tmux session limits:** How many tmux sessions can exist per workspace?
   *Recommendation: configurable max (default 10), enforced by orchestrator.*

## Migration path

This plan requires **no protocol bump** for phases 1-4 because all changes are
additive to assignment metadata or use existing routing fields. Phase 5 (human
terminal integration) may require UI changes but no API changes.

When this plan is approved:
1. Update this document with an "Implementation log" section.
2. Create tickets for each phase.
3. Each phase gets its own drift tests before merge.
4. The runtime registry state machine gets its own fixture directory:
   `test/fixtures/runtime_v1/`.

## References

- [`docs/architecture.md`](architecture.md) — system context, trust boundaries
- [`docs/jx_devide.md`](jx_devide.md) — runner protocol v1 contract
- [`docs/state_machines.md`](state_machines.md) — assignment state machine
- [`docs/protocol_governance.md`](protocol_governance.md) — version policy
- [`docs/terminal.md`](terminal.md) — tmux + erlexec architecture
