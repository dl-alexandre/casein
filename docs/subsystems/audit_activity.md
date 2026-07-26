# Audit / activity / run ledger

> The durable evidence plane: every sensitive policy decision, agent MCP
> call, raw-terminal attach, and review-run lifecycle event is recorded as
> an append-only `Audit.Event` and read back as a run ledger or evidence feed
> (FP-10: execution leaves reviewable evidence).
>
> **Freeze (2026-07-21):** Audit is canonical. Run ledger and agent activity are
> typed projections, never independent authorities. See
> [`../design/authority-evidence-freeze.md`](../design/authority-evidence-freeze.md)
> and [`../architecture.md`](../architecture.md) (authority per concern,
> evidence layering).

## Responsibility

This subsystem owns the **durable event plane** of Casein — the half of the
event plane (`architecture.md` "Event plane") that must survive restart and
be reconstructable for replay, review, and post-mortem.

### Layering (Audit-first)

| Layer | Role |
|---|---|
| `Audit.Event` | Canonical durable evidence |
| `Runs.Ledger` | Constrained run/session projection (`run.*`) over Audit |
| `AgentEvents` | Operational projection for agent-session replay |

`Casein.Agents.AgentEvents` is a neighboring durable *operational* projection
for agent-session replay (ACP/MCP/state/handoffs). It intentionally does not
replace this security evidence log: `Audit` accepts occasional duplicates and
records decisions, while `AgentEvents` deduplicates native provider events and
uses metadata-only session streams. Different dedupe, replay, retention, and
privacy needs are intentional.

**Invariant:** Audit is the canonical evidence log. Run ledger and agent
activity are typed projections, never independent authorities. Separate tables
are fine. Shared identity (event / correlation / causation IDs) and explicit
projection ownership prevent duplicated facts with no reconciliation path.

Do **not** put every MCP mutation or agent lifecycle event into the `run.*`
vocabulary.

It has three layers under this subsystem’s direct ownership:

1. **Audit** (`lib/casein/audit/`) — the raw record. A flat, append-only
   `Event` struct, written through a swappable `Adapter` (in-memory ring in
   dev/test, Postgres in prod). It knows nothing about run vocabulary; it just
   stores and returns events.
2. **Run ledger** (`lib/casein/runs/`) — a normalized vocabulary *on top of*
   Audit. `Runs.Ledger` writes/reads a constrained set of `run.*` actions
   (session attach/deny, run started/succeeded/failed/timed_out, approval
   request/grant/deny) so terminal and run surfaces cannot invent incompatible
   event shapes. `Runs.Status` is the single source of truth for what each
   status string *means* (terminal? failed? retryable?).
3. **Logs** (`lib/casein/logs/`) — live, *non-durable* workspace service log
   streaming (SSE from the workspace source). It is part of the activity
   surface but is a transient transport, not part of the durable plane.

This subsystem does **not** decide anything — `Casein.Policy` makes the
decisions and hands a `%Policy.Decision{}` here to be recorded.

Sensitive evidence must carry an **authenticated principal** or an explicit
`system:<component>` actor. Callers must not forge audit attribution via
request parameters (MCP `actor_id` especially).

## Module map

| Module | File | Role |
|---|---|---|
| `Casein.Audit` | `lib/casein/audit.ex` | Public entry point. `emit/1`, `emit!/1`, `emit_decision/2`, `list/1`, `recent_for/2`, `clear/0`; dispatches to the configured adapter. |
| `Casein.Audit.Event` | `lib/casein/audit/event.ex` | The single audit record struct. Stable shape mirroring the `audit_events` table; `new/1` mints `id` + `inserted_at`. |
| `Casein.Audit.Adapter` | `lib/casein/audit/adapter.ex` | Behaviour for persistence backends (`record/1`, `list/1`, `recent_for/2`, `clear/0`). |
| `Casein.Audit.MemoryAdapter` | `lib/casein/audit/memory_adapter.ex` | GenServer-backed capped (1 000-event) in-memory ring. **Test** default only (the `config/test.exs` override). |
| `Casein.Audit.EctoAdapter` | `lib/casein/audit/ecto_adapter.ex` | Postgres adapter; maps `Event` ↔ private `Row` schema on `audit_events`. **Default for every env** (`config.exs`); test overrides to `MemoryAdapter`. Caps metadata at 32 KB. |
| `Casein.Runs.Ledger` | `lib/casein/runs/ledger.ex` | Normalized run vocabulary over Audit: emits `run.*` events, reads back run summaries/timelines, tags every event with `ledger`/`ledger_version`. |
| `Casein.Runs.Status` | `lib/casein/runs/status.ex` | Status semantics: `normalize/1`, `terminal?/1`, `failed?/1`, `blocked?/1`, `in_progress?/1`, `retryable?/2`, `failure_reason/2`, `status_class/1`. |
| `Casein.Logs.Adapter` | `lib/casein/logs/adapter.ex` | Behaviour + dispatcher for workspace service log streaming. |
| `Casein.Logs.SSE` | `lib/casein/logs/sse.ex` | Default log adapter; delegates to `Casein.Workspaces.stream_logs/3`. |

## Data flow / lifecycle

**Write path (durable plane):**

```text
Policy.Decision ─┐
                 ▼
  Casein.Audit.emit_decision/2   (sensitive UI actions, mode changes)
  Casein.Runs.Ledger.run_started / run_finished / raw_session_attached / approval_*
                 │  (builds attrs: action, target_type, target_ref, metadata)
                 ▼
        Casein.Audit.emit!/1  ──►  Event.new/1  ──►  impl().record(event)
                                                         │
                                          MemoryAdapter (ring) | EctoAdapter (audit_events)
```

Callers never build an `Event` directly. The two front doors are
`Casein.Audit` (for one-off decisions, e.g. `Agents.MCPAudit` emitting
`Audit.emit!` for MCP tool calls; mode changes) and `Casein.Runs.Ledger`
(for anything with run/session vocabulary). `Ledger.emit/3` always merges
`"ledger" => "run"` and `"ledger_version" => 1` into metadata so ledger events
are distinguishable from generic audit events.

Target mutation shape (shared use cases, not transport-local):

```text
execute(scope, action, input)
  → validate scope
  → decide policy
  → record decision
  → perform effect when allowed
  → record outcome
```

Decision and outcome for the same mutation should share correlation IDs so
allow/deny/success/failure identify the same principal and workspace.

**Read path:**

```text
Audit.recent_for(ws_id, n)                  ── generic event feed (evidence drawer total)
Ledger.recent_for(ws_id, n)                 ── filters to ledger_event?/1
Ledger.recent_runs_for(ws_id, limit)        ── groups run events by run_id → run summaries
Ledger.timeline_for(ws_id, run_id)          ── chronological events for one run
Ledger.summary_for(ws_id, run_id)           ── single run summary
```

`Runs.Status` is layered on the read path: `WorkspaceLive.Show` and the run
panel (`Show.RunPanel`) call `Status.*` to classify a run
summary's status string into terminal/failed/running/retryable and to derive
a human-readable `failure_reason/2` from the timeline.

**Key writers/readers outside this subsystem:**

- `Casein.Terminals.Boundary` — gates raw PTY attach via
  `Policy.can_use_raw_terminal?/1`, records the verdict with
  `Ledger.raw_session_attached/2`, and dedups reconnects via
  `Ledger.recent_for/2`.
- `Casein.Agents.MCPAudit` — emits MCP tool-call events via `Audit.emit!`.
  Must accept a **trusted principal** from auth/scope, not a caller-supplied
  `actor_id`.
- `CaseinWeb.WorkspaceLive.Show` + `Show.AuditDrawer` ("Evidence" drawer) —
  read both counts (`Audit.recent_for` total vs. `Ledger.ledger_event?`
  ledger count) and render run timelines.
- `Casein.Export.WorkspaceStatus` — exports run summaries/timelines.

**Logs path (transient):** `WorkspaceLive.Show` calls
`Logs.Adapter.start_stream/3` → `Logs.SSE` → `Workspaces.stream_logs/3`,
which streams workspace-service log lines to the LiveView pid. This is live
activity, not durable evidence — nothing is written to `audit_events`.

## Public surface

Other code should call these and nothing deeper:

- **`Casein.Audit`** — `emit/1`, `emit!/1` (fire-and-forget),
  `emit_decision/2` (takes a `%Policy.Decision{}`), `list/1`,
  `recent_for/2`, `clear/0`.
- **`Casein.Runs.Ledger`** — `new_run_id/0`, `run_started/1`,
  `run_finished/2`, `approval_requested/1` / `approval_granted/1` /
  `approval_denied/1`, `raw_session_attached/2`, `recent_runs_for/2`,
  `timeline_for/2`, `summary_for/2`, `recent_for/2`, `ledger_event?/1`.
- **`Casein.Runs.Status`** — `normalize/1`, `terminal?/1`, `failed?/1`,
  `blocked?/1`, `in_progress?/1`, `retryable?/2`, `failure_reason/2`,
  `status_class/1`.
- **`Casein.Logs.Adapter`** — `start_stream/3`, `stop_stream/1`.

Processes: only `Casein.Audit.MemoryAdapter` is a long-lived GenServer
(supervised, named). The Ecto adapter is stateless (Repo-backed).

## Invariants & gotchas

- **Audit is append-only, not tamper-evident.** There is no update/delete API.
  A database operator can still rewrite rows. Do not claim tamper evidence
  without hash chaining, signed checkpoints, or an external immutable sink.
- **A rare duplicate** (e.g. raw-reconnect dedup scrolling out of `Boundary`'s
  20-event lookback) is accepted as harmless rather than guarded with a unique
  constraint.
- **The adapter is swappable at runtime** via
  `Application.get_env(:casein, :audit_adapter, …)`. Default
  `EctoAdapter` (`config.exs`, inherited by every env); `config/test.exs`
  overrides to `MemoryAdapter`. Anything relying on durability
  across restart must run on the Ecto adapter.
- **Atoms round-trip as strings.** `decision`/`reason` are atoms in the
  struct but stored as strings; `EctoAdapter` reads them back with
  `String.to_existing_atom` guarded against `ArgumentError` (returns `nil`
  for unknown atoms — no atom-exhaustion risk).
- **Metadata is bounded.** `EctoAdapter` caps serialized metadata at
  `@max_metadata_bytes` (32 KB) and replaces over-budget maps with
  `%{"truncated" => true}`. Metadata keys are stringified by `Ledger`.
- **Ledger events are tagged, not separated.** Run-ledger events live in the
  *same* `audit_events` store as generic audit events; `ledger_event?/1`
  distinguishes them by the `ledger`/`ledger_version` metadata pair. The
  "Evidence" drawer surfaces both a total event count and a ledger count.
- **`Runs.Status` is the only place status meaning lives.** Do not re-derive
  "is this terminal/failed/retryable" inline; route through `Status`. It also
  recognizes legacy delegated-execution statuses (`expired`, `abandoned`,
  `denied`) for backward-compatible timelines.
- **Logs are not evidence.** `Casein.Logs.*` is a transient stream from the
  workspace source; it never touches the durable plane. Do not treat a log
  line as an audit record.
- **`recent_for` over-fetches then filters.** `Ledger.recent_for/2` asks Audit
  for `max(limit * 10, 100)` rows and filters to ledger events; on a very busy
  workspace older ledger events can fall outside the window.
- **No universal run ledger.** Specialized projections keep their own
  vocabulary; expand Audit envelope (and correlation) rather than forcing
  every event through `run.*`.

## See also

- [`../design/authority-evidence-freeze.md`](../design/authority-evidence-freeze.md)
  — freeze decision, non-goals, vertical-slice order (MCP principal first).
- [`../audit_local.md`](../audit_local.md) — runtime truth-table audit
  (rows 3 "denied run" and 6 "audit inspect"); shows where each event is
  emitted on the local path.
- [`../audit_remote.md`](../audit_remote.md) — remote-deployment truth-table
  (rows 6 "audit inspect", 7 "replay"); why the Ecto adapter is the prod
  default and how audit/PTY replay survive restart.
- [`../architecture.md`](../architecture.md) — FP-10, authority per concern,
  evidence layering, reconnect semantics, event plane.
- [`../state_machines.md`](../state_machines.md) — session, review-run, mode,
  and audit lifecycles.
- [`../glossary.md`](../glossary.md) — event taxonomy and operational terms.
