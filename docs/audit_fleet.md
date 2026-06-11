# Fleet-mode truth-table audit

> Grounded assessment of the current `lib/` against the Fleet-mode
> column of [`product.md`](product.md) §12 (demo truth table).
>
> Date of audit: 2026-05-11 · last updated this commit (CC-F1 closed).
> Re-run this audit when significant runtime, coordinator, or
> integration changes land.
>
> Status legend: `works` · `partial` · `stub` · `missing` · `n/a` · `out-of-scope`.
>
> **What "Fleet mode" means here** (product.md §4.3, FP-7):
> `browser → JX → DevIDE × N → leased runners`. A coordinator (JX)
> routes intent across multiple DevIDE runtime authorities and a pool
> of runners. JX is the cockpit host; DevIDE is one of many runtime
> authorities it consumes. Fleet *composes* single-runtime mode
> (FP-7) — it does not replace it.

## Why this audit is different from Local and Remote

The prior two audits asked: *can the operator's browser do X against
a DevIDE?* Fleet mode asks a different question: *can a coordinator
on the operator's behalf do X across many DevIDEs?*

That subtly relocates several rows:

- **Some rows that already work in Local/Remote** also work in Fleet
  because their code path is per-DevIDE and unchanged by a
  coordinator's presence (audit, replay, allow/deny gating, session
  durability).
- **Some rows that are out-of-scope for DevIDE** in Fleet mode
  belong to JX — specifically the federated cockpit, multi-host
  picker, and assignment routing UX. DevIDE cannot meaningfully ship
  these; it can only provide the API surface a coordinator consumes.
- **A few rows have real DevIDE-side gaps** that the coordinator
  pattern exposes: lease expiration scheduling, queue/lease
  visualization, and cross-host workspace resolution.

The honest framing of this audit: **DevIDE already provides
substantial fleet API surface (runner v1, workspace registry, audit
query). Three concrete code gaps remain. The rest is JX's job.**

## DevIDE's contract with a coordinator (what exists today)

| Surface                                                     | Exists | Purpose                                                              |
|-------------------------------------------------------------|:------:|----------------------------------------------------------------------|
| `GET /api/workspaces`                                       |   ✓   | Workspace registry per DevIDE                                        |
| `GET /api/workspaces/:id/status`                            |   ✓   | Full workspace status                                                |
| `GET /api/workspaces/:id/audit`                             |   ✓   | Per-workspace governed event stream (Ecto-durable)                   |
| `POST /api/workspaces/:id/runs`                             |   ✓   | Queue immediate or durable run (admission-gated)                     |
| `POST /api/runner/v1/assignments/poll`                      |   ✓   | Runner claims one compatible assignment with a lease token           |
| `GET /api/runner/v1/assignments/:id`                        |   ✓   | Replay assignment + all reports idempotently                         |
| `POST /api/runner/v1/assignments/:id/reports`               |   ✓   | Append progress (deduped by client_report_id)                        |
| `POST /api/runner/v1/assignments/:id/complete` / `/fail`    |   ✓   | Terminal transitions                                                  |
| `Runners.expire_leases/1`                                   |   ✓   | Scheduled by `DevIDE.Runners.ExpiryScheduler` every 30s (CC-F1 closed) |
| Audit emission on every assignment transition               |   ✓   | claim, succeed, fail, expire are all audited                         |

Code refs:

- Runner protocol: [`lib/dev_ide/runners.ex`](../lib/dev_ide/runners.ex), [`lib/dev_ide_web/controllers/api/runner_controller.ex`](../lib/dev_ide_web/controllers/api/runner_controller.ex)
- State machine: [`lib/dev_ide/runners/state_machine.ex`](../lib/dev_ide/runners/state_machine.ex) — `queued → claimed → running → {succeeded, failed, expired, abandoned}`
- Persistence: [`lib/dev_ide/runners/ecto_adapter.ex`](../lib/dev_ide/runners/ecto_adapter.ex) (487 lines, prod default)
- Runtime placement: [`lib/dev_ide/runtimes.ex`](../lib/dev_ide/runtimes.ex)
- Protocol contract: [`docs/jx_devide.md`](jx_devide.md)
- Lifecycle docs: [`docs/state_machines.md`](state_machines.md), [`docs/protocol_governance.md`](protocol_governance.md)

## Summary

| #  | Row                  | Status        | Where the gap is (if any)                                                       |
|----|----------------------|---------------|---------------------------------------------------------------------------------|
| 1  | attach               | **out-of-scope** | the multi-host federated picker belongs to JX; DevIDE provides registry API |
| 2  | allowed run          | **works**     | per-workspace gate fires same as Local/Remote; runner v1 path is gate-first    |
| 3  | denied run           | **works**     | same; deny audited on durable queue submission, before any runner sees argv    |
| 4  | disconnect           | **works**     | coordinator disconnect doesn't affect runners or sessions                       |
| 5  | resume               | **works**     | assignment replay via GET endpoint; session replay per-DevIDE                  |
| 6  | audit inspect        | **works**     | per-workspace audit query exposed via API; aggregation is JX's job             |
| 7  | replay               | **works**     | assignment replay is idempotent by design; audit replay via Ecto               |
| 8  | lease visible        | **partial**   | data present in assignment payload; **DevIDE cockpit doesn't render it** — CC-F2 |
| 9  | runner failover      | **works**     | `expire_leases/1` scheduled every 30s by `Runners.ExpiryScheduler`              |
| 10 | cross-host attach    | **out-of-scope** | federation belongs to a coordinator; see "What this audit deliberately does not say" |

**Headline:** *DevIDE is fleet-ready as a service to a coordinator.*
The runner v1 protocol exists end-to-end. Audit is durable. Replay
is idempotent. Leases now expire on a timer. No code-level gap
remains. Rows 8 (lease visibility in DevIDE's own cockpit) and 10
(federated picker) are coordinator-cockpit concerns, not DevIDE
concerns, and are deferred until a JX integration target is
concrete.

## Row-by-row

### 1. attach — *out-of-scope* (JX's cockpit)

Fleet-mode attach means: the operator opens the JX cockpit, sees
workspaces across all coordinated DevIDEs, clicks one, and the
terminal attaches to the right runtime authority. DevIDE doesn't
host the federated picker — it just provides the registry API
(`GET /api/workspaces`) for JX to consume.

For *within-DevIDE* attach (operator hits one DevIDE's cockpit
directly, ignoring JX), Remote-mode rules apply and that already
works.

### 2. allowed run — *works*

Runner v1 path is admission-gated at submission. `POST
/api/workspaces/:id/runs` invokes `Policy.can_run_command?` before
queueing, so non-allowlisted argv never reaches a runner. Same gate
as Local/Remote, same audit shape — coordinator sees the allow
event via the audit API.

### 3. denied run — *works*

Deny audited at submission, *before* any runner is offered the
work. This is FP-6 ("runners stay policy-dumb") working as
designed — runners can't claim what was never queued.

- [`lib/dev_ide/policy.ex:59-73`](../lib/dev_ide/policy.ex)
- [`lib/dev_ide_web/controllers/api/workspace_controller.ex:34-44`](../lib/dev_ide_web/controllers/api/workspace_controller.ex)

### 4. disconnect — *works*

JX going down is a coordinator concern, not a DevIDE concern.
DevIDE-side: an assignment with a held lease keeps running on its
runner. A queued assignment stays queued. Sessions persist as in
Local/Remote. When JX comes back, it reconciles via the replay
endpoint (`GET /api/runner/v1/assignments/:id`), which is
idempotent.

### 5. resume — *works*

Two angles:

- **PTY session resume** — per-DevIDE, identical to
  Remote (in-state buffer + tmux capture-pane on reattach).
- **Assignment resume** — the runner v1 protocol is replay-safe.
  A coordinator that reconnects and asks for `GET /api/runner/v1/
  assignments/:id` gets the full ordered list of reports it
  missed.

### 6. audit inspect — *works*

Per-workspace audit query at `GET /api/workspaces/:id/audit` is the
canonical source. The Ecto adapter writes every governed decision
(allow / deny / mode change / lease claim / lease expire / replay)
to `audit_events`. A coordinator aggregates across N workspaces
across N DevIDEs as needed — DevIDE provides the per-workspace feed.

### 7. replay — *works*

Combined with row 5. The runner protocol has an explicit
"replay assignment + reports" endpoint that is documented to be
idempotent ([`docs/jx_devide.md`](jx_devide.md), "Replay
semantics"). The audit log is durable. The PTY buffer is durable
via the work in `feff22a` + `c301833`.

### 8. lease visible — *partial* (data present; not rendered)

Assignment payloads carry `claim_token` (opaque), `claimed_at`,
`lease_expires_at`, `runner_id`, `status`. A coordinator can show
this. **DevIDE's own cockpit does not** — there is no LiveView
surface today that visualizes the runner assignment queue or
active leases:

```
$ grep -rln "assignment\|runner_id\|lease" lib/dev_ide_web/live/
(no matches)
```

This may be acceptable in Fleet mode (JX is the cockpit, not
DevIDE). But for operators who attach directly to a DevIDE in a
fleet-aware deployment, the inability to see assignment state from
the cockpit is a real gap.

- Tracked as **CC-F2** below.

### 9. runner failover — *works* (closed this commit)

`Runners.expire_leases/1` walks assignments with
`lease_expires_at < now`, transitions them to `expired`, and audits
each transition. `DevIDE.Runners.ExpiryScheduler` is a supervised
GenServer that calls it every 30s (configurable via
`:dev_ide, :lease_expiry_interval_ms`). A runner that disappears
mid-job has its lease reclaimed within one interval, and the
expired event is in the audit stream a coordinator can subscribe
to.

- [`lib/dev_ide/runners/expiry_scheduler.ex`](../lib/dev_ide/runners/expiry_scheduler.ex)
- [`lib/dev_ide/application.ex`](../lib/dev_ide/application.ex) (supervision tree)
- Test: [`test/dev_ide/runners/expiry_scheduler_test.exs`](../test/dev_ide/runners/expiry_scheduler_test.exs) ("transitions claimed assignments with expired leases to 'expired'")

### 10. cross-host attach — *out-of-scope* (federation belongs to a coordinator)

The Fleet truth-table row asks: switch host in picker, terminal
re-attaches elsewhere. In Fleet topology, "host" means "another
DevIDE runtime authority." Federated workspace resolution requires
either:

- The cockpit talks to JX, which knows about every DevIDE
  (coordinator brokers the view), or
- DevIDE-to-DevIDE peer discovery (federation without a
  coordinator), which is a different and larger architecture.

The first is the FP-7 framing. The cockpit-side host gate already
exists in DevIDE (`5656126`) — when JX directs the cockpit to
attach to a workspace on `host=cloud-1`, DevIDE's `show.ex` is
ready to honor that *if* the resolver knows how to find the
workspace there. Today the resolver refuses politely (§11).
Cross-host resolution is the runtime-side gap a coordinator
integration would close.

For pure DevIDE (no coordinator), this row is correctly classified
**out-of-scope**. Within Fleet, it's a coordinator-side feature.

## Cross-cutting gaps — the Fleet-mode punch list

### CC-F1. Schedule `Runners.expire_leases/1` — ✅ done (this commit)

Closed. `DevIDE.Runners.ExpiryScheduler` is a small supervised
GenServer that calls `Runners.expire_leases(DateTime.utc_now())` on
a 30-second tick (configurable via
`:dev_ide, :lease_expiry_interval_ms`). On each tick, expirations
are audited per assignment as before; the scheduler logs only when
at least one lease was actually expired (no log spam on empty
ticks). Tick failures crash the GenServer rather than getting
swallowed, so adapter-level bugs are visible in supervisor restart
logs.

Tests cover:

- Scheduler stays alive across multiple ticks.
- A claimed assignment with a sub-interval lease transitions to
  `expired` after the scheduler runs.
- Empty-state ticks (nothing to expire) don't crash.

### CC-F2. Render lease + queue state in the cockpit

DevIDE's own LiveView doesn't show assignment state. Decide if
this is needed:

- *If DevIDE is purely a coordinator-consumed service*, this is
  out-of-scope; JX renders fleet state.
- *If DevIDE's cockpit should remain useful in fleet-aware
  deployments* (operator attaches directly without going through
  JX), add an "Assignments" tab to the workspace LiveView showing
  the assignment queue and active leases. The audit API already
  exposes the underlying event stream; this would make lease state
  directly visible in the cockpit.

Defer until a concrete use case appears. The product hasn't yet
committed to whether DevIDE's cockpit is also operator-usable in
Fleet topology.

### CC-F3. Cross-host workspace resolution

For row 10 to ever work end-to-end, the resolver must route by
`host_id`. The cockpit boundary is ready (`5656126`); the runtime
side is not. Three plausible shapes, ordered by simplicity:

- **JX-brokered**: DevIDE never talks to peer DevIDEs; JX
  aggregates and the cockpit talks to JX. DevIDE stays unchanged.
- **Outbound DevIDE-to-DevIDE HTTP**: DevIDE A's resolver hits
  DevIDE B's `/api/workspaces/:id` when `host_id` matches B. Reuses
  the existing read API. Adds a peer registry to DevIDE.
- **Federation protocol**: a new contract for DevIDE peer
  discovery + capability negotiation. Much larger; probably the
  wrong shape until a real use case exists.

Recommendation: **defer**. The JX-brokered shape is the obvious
correct one and requires zero DevIDE changes. Re-evaluate when JX
integration becomes a concrete work item.

## Punch list (ordered by leverage)

1. ~~**CC-F1: schedule `expire_leases`.**~~ ✅ done (this commit).
2. **CC-F2: cockpit assignment/lease visibility.** Defer until
   product commits to whether DevIDE's own cockpit is the
   fleet-operator surface (vs. JX hosting it).
3. **CC-F3: cross-host resolution.** Defer; JX-brokered is the
   right shape and requires zero DevIDE changes.

**Every Fleet row DevIDE is *responsible for* is now `works`** or
`out-of-scope (coordinator)`. The cockpit/UX work that remains is
shaped by whether JX exists and what its integration target is —
those are coordinator-side decisions, not DevIDE-side ones.

## What this audit deliberately does not say

- It does not specify a JX implementation. JX is a peer system;
  DevIDE's job is to expose the API surface JX consumes. Whether
  JX is OTP-based, Rust, Python, or anything else is irrelevant
  to this audit.
- It does not extrapolate from one runner to many. The runner v1
  protocol already supports many runners; capability-based
  routing is in the placement layer. Concurrent claim semantics
  are handled by the state machine (`queued → claimed` is the
  atomic step).
- It does not propose multi-region fleet topology. Cross-region
  is a JX/coordinator concern; DevIDE just exposes a per-runtime
  API.
- It does not address authn/authz between JX and DevIDE beyond
  the existing bearer-token model. Mutual TLS, scoped tokens,
  short-lived tokens — all worthwhile, none are blockers.

## When to re-run

- After CC-F1 lands.
- Once a JX integration target is concrete (will it be talking to
  our `/api/runner/v1/poll`? does that need versioning to v2?).
- If a cockpit-rendered assignment view is proposed.
- If a federation-without-coordinator design emerges (which would
  invalidate the audit's headline assumption that fleet =
  JX-brokered).
