# Failure Taxonomy and Reconciliation

> Version: v1 (aligned with `DevIDE.Runners.Failure` and
> `DevIdeWeb.API.RunnerController` as of M10)

## Failure classes

Failure classes are part of the JX ↔ DevIDE contract. They describe *why* a
protocol operation failed without revealing what runners are allowed to do.

| Class | Meaning | Typical HTTP | Retryable? |
|---|---|---|---|
| `enqueue_failed` | Assignment could not be queued | `400` | Yes (fix payload) |
| `claim_rejected` | Runner not eligible to claim | `400` | Yes (upgrade capabilities) |
| `lease_expired` | Claim token expired before terminal | `409` | Yes (re-poll) |
| `report_rejected` | Report invalid (duplicate, bad token, etc.) | `400` / `409` | Sometimes |
| `action_failed` | Runner executed argv but command failed | `200` (terminal) | Yes (new assignment) |
| `replay_mismatch` | Replayed state does not match expectation | `200` | No (investigate) |
| `runner_lost` | Runner abandoned or unreachable | varies | Yes (new runner) |

## Failure class map

Internal reason → external class mapping (`DevIDE.Runners.Failure.class/1`):

| Internal reason | Class |
|---|---|
| `:safe_action_not_allowed` | `enqueue_failed` |
| `:not_found` (workspace) | `enqueue_failed` |
| `{:policy_denied, _}` | `enqueue_failed` |
| `:unsafe_db` | `enqueue_failed` |
| `:shared_stage_guarded` | `enqueue_failed` |
| `:capabilities_required` | `claim_rejected` |
| `:protocol_not_supported` | `claim_rejected` |
| `:runner_id_required` | `claim_rejected` |
| `:lease_expired` | `lease_expired` |
| `:runner_lost` | `runner_lost` |
| `:action_failed` | `action_failed` |
| `:replay_mismatch` | `replay_mismatch` |
| `:claim_token_invalid` | `report_rejected` |
| `:assignment_not_claimed` | `report_rejected` |
| `:assignment_terminal` | `report_rejected` |
| `:duplicate_report_conflict` | `report_rejected` |
| `:invalid_transition` | `report_rejected` |
| `:forbidden_payload` | `report_rejected` |
| `:event_not_allowed` | `report_rejected` |
| `:evidence_required` | `report_rejected` |
| Any other atom | `report_rejected` |
| Any tuple | `report_rejected` |

## HTTP status mapping

`DevIdeWeb.API.RunnerController` maps internal errors to HTTP status codes:

| Internal error | Status |
|---|---|
| `:not_found` | `404` |
| `:claim_token_invalid` | `403` |
| `:lease_expired` | `409` |
| `:assignment_not_claimed` | `409` |
| `:assignment_terminal` | `409` |
| `:duplicate_report_conflict` | `409` |
| everything else | `400` |

For `poll`, `:none` returns `204 No Content`.

## Duplicate report semantics

### Progress reports

If a progress report arrives with the same `client_report_id` as an existing
report:

- **Exact duplicate** (same `event`, `stream`, `message`, `data`, `evidence`): DevIDE returns the existing report (`200 OK`).
- **Conflicting duplicate** (same `client_report_id` but different content): DevIDE rejects with `409` and `duplicate_report_conflict`.

This makes runner retries safe: send the same report again, get the same response.

### Terminal reports (`complete` / `fail`)

If a terminal call arrives with the same `client_report_id` as an existing
terminal report:

- **Exact duplicate** (same `event`, `message`, `evidence`, `failure_class`): DevIDE returns the existing assignment + report (`200 OK`).
- **Conflicting duplicate**: DevIDE rejects with `409` and `duplicate_report_conflict`.

Terminal calls from terminal states (without a matching `client_report_id`) are
rejected with `409` and `assignment_terminal`.

## Replay semantics

`GET /api/runner/v1/assignments/:id` returns:

```json
{
  "protocol": "jx.runner.v1",
  "assignment": { ... },
  "reports": [ ... ]
}
```

### Guarantees

1. **Idempotent**: Same request returns identical JSON (modulo `inserted_at` precision if adapter changes).
2. **Read-only**: Replay never mutates assignment state or creates audit events.
3. **Stable ordering**: Reports are ordered by `position` ascending.
4. **No claim token**: The claim token is never included in replay.
5. **Unavailable safe action**: If the safe action registry no longer contains the action id, replay shows `{id, unavailable: true}` instead of resolved argv.

### Reconciliation contract for JX

JX may call replay repeatedly. DevIDE guarantees:

- No duplicate operational events are emitted on replay.
- No new audit events are created.
- No new runner assignments are created.
- The payload is sufficient for JX to reconstruct the same outcome it saw the first time.

## Evidence requirements

Terminal reports (`complete`, `fail`) require a non-empty `evidence` map:

```json
{
  "claim_token": "...",
  "evidence": {
    "exit_code": 1,
    "failure_class": "action_failed"
  }
}
```

Without `evidence`, the request is rejected with `evidence_required`.

The `failure_class` inside evidence is advisory for `complete` and authoritative
for `fail`. If omitted, DevIDE derives it from the terminal status
(`"failed"` → `"action_failed"`, `"succeeded"` → `nil`).

## Reconciliation scenarios

### Scenario A: Runner crashes after sending `started`

1. Runner claims assignment, sends `started` (state = `running`).
2. Runner process crashes.
3. Lease eventually expires.
4. `expire_leases/1` transitions to `expired`.
5. JX observes `expired` via replay.
6. JX may enqueue a new assignment if retry policy permits.

### Scenario B: Runner retries terminal report

1. Runner sends `fail` with `client_report_id = "seq-9"`.
2. Network timeout; runner does not receive `200 OK`.
3. Runner retries `fail` with same `client_report_id = "seq-9"`.
4. DevIDE detects exact duplicate, returns existing assignment + report.
5. Runner proceeds safely.

### Scenario C: JX polls during lease

1. JX enqueues assignment.
2. Runner claims and starts working.
3. JX calls replay.
4. JX sees `status: "running"`, `claimed_by: "runner-42"`, reports in order.
5. JX can surface liveness to operator without mutating state.

### Scenario D: Policy denies enqueue

1. JX sends `POST /api/workspaces/:id/runs` with `command_id: "test"`.
2. Workspace mode is `:shared_stage_guarded`.
3. Policy denies.
4. Audit event `policy.blocked` is emitted.
5. JX receives `403` with `failure_class: "enqueue_failed"`.
6. JX must not retry blindly; operator intervention required.

## Forbidden payload protection

DevIDE recursively scans all runner payloads for forbidden keys:

```
argv command cmd shell executable url uri method headers body request proxy http
```

If any key (case-insensitive) matches, the entire request is rejected with
`forbidden_payload`. This prevents runners from attempting to smuggle
out-of-band execution requests through the report channel.
