# JX DevIDE Integration

> Version: v1 (aligned with implementation as of M10)
>
> This document is the **authoritative protocol contract** between JX and DevIDE.
> The implementation in `lib/dev_ide/runners.ex`, `lib/dev_ide_web/controllers/api/`,
> and `lib/dev_ide/policy.ex` is the runtime expression of this contract.
> When implementation and docs diverge, the docs win: fix the code.

## Dependency direction

```text
JX --HTTP observe + approved rerun--> DevIDE --wraps--> milc-devbox
                     ^
                     |
              durable runner
              (pull/report/claim)
```

DevIDE owns the HTTP API. JX does not embed DevIDE runtime code. Runners are
external to both.

## Read API (M19)

All endpoints require bearer authentication (`DEV_IDE_API_TOKEN`).

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/workspaces` | List workspace summaries |
| `GET` | `/api/workspaces/:id/status` | Full workspace status (mode, git, active run, recent runs, proposals, audit) |
| `GET` | `/api/workspaces/:id/runs` | Recent command run history |
| `GET` | `/api/workspaces/:id/runs/:run_id` | Replay one run from the canonical run ledger |
| `GET` | `/api/workspaces/:id/proposals` | Recent proposal metadata + conflict analysis |
| `GET` | `/api/workspaces/:id/audit` | Recent audit events |

Status payload is a **denied-list redacted summary**:
- No `manager_payload` env, `DATABASE_URL`, or credentials.
- No file contents.
- No terminal scrollback.
- Command output only via persisted, capped history snapshot.
- Proposal diffs are NOT included; only metadata + risk.

## Action endpoint (M30)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/workspaces/:id/runs` | Queue a command execution |

### Immediate mode (legacy, default)

When the request does **not** include `execution_protocol: "jx.runner.v1"`:

```json
{ "command_id": "compile" | "test" | "format" | "precommit" }
```

DevIDE validates the command against `DevIDE.Commands.allowlist/0`, checks
`DevIDE.Policy.can_run_command?/1`, spawns the command on the local host via
`DevIDE.Commands.Run`, and returns the active run snapshot.

### Durable runner mode (protocol v1)

When the request **does** include `execution_protocol: "jx.runner.v1"`:

```json
{
  "execution_protocol": "jx.runner.v1",
  "command_id": "test",
  "jx_assignment_id": "asgn-...",
  "jx_action_id": "act-...",
  "jx_safe_action_kind": "rerun_devide_command",
  "runner_requirements": {
    "host": "host-a",
    "os": "darwin",
    "tools": ["mix", "git"],
    "repo": "onebackend-v3",
    "branch_isolation": "worktree"
  }
}
```

DevIDE:
1. Validates `command_id` against `DevIDE.Runners.SafeAction`.
2. Checks policy (`Policy.can_run_command?/1`).
3. Emits `run.command_requested` or `run.command_denied` into the run ledger.
4. Creates a `DevIDE.Runners.Assignment` with status `queued`.
5. Emits `run.queued` with the same `run_id`.
5. Returns the assignment payload (no claim token).

DevIDE **ignores** any `argv` field. The executable argv is resolved from
`SafeAction` at claim/replay time.

## Runner protocol v1

The runner protocol is **pull/report oriented**.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/runner/v1/assignments/poll` | Claim at most one compatible queued assignment |
| `GET` | `/api/runner/v1/assignments/:id` | Replay assignment + all reports (idempotent) |
| `POST` | `/api/runner/v1/assignments/:id/reports` | Append a progress report |
| `POST` | `/api/runner/v1/assignments/:id/complete` | Mark assignment succeeded (terminal) |
| `POST` | `/api/runner/v1/assignments/:id/fail` | Mark assignment failed (terminal) |

**There is no endpoint that lets a runner create an assignment.**

### Poll request

```json
{
  "protocol": "jx.runner.v1",
  "runner_id": "runner-42",
  "capabilities": ["workspace-command:v1"],
  "workspace_ids": ["optional-filter"],
  "host": "host-a",
  "os": "darwin",
  "tools": ["mix", "git"],
  "repo": "onebackend-v3",
  "branch_isolation": "worktree",
  "runtime_id": "rt-123",
  "runtime_path": "/run/rt-123",
  "active_assignments": 2,
  "concurrency_limit": 4
}
```

DevIDE claims the oldest compatible queued assignment and returns:

```json
{
  "protocol": "jx.runner.v1",
  "assignment": {
    "id": "uuid",
    "workspace_id": "my-app",
    "safe_action_id": "command:test",
    "safe_action_version": 1,
    "action": {
      "id": "command:test",
      "version": 1,
      "kind": "workspace_command",
      "command_id": "test",
      "argv": ["mix", "test", "--color"],
      "requires": ["workspace-command:v1"],
      "description": "Run the allowlisted test workspace command."
    },
    "status": "claimed",
    "claim_token": "uuid-claim-token",
    "queued_at": "...",
    "claimed_at": "...",
    "lease_expires_at": "..."
  }
}
```

If no compatible assignment exists: `204 No Content`.

### Report request

```json
{
  "claim_token": "uuid-claim-token",
  "event": "started" | "progress" | "stdout" | "stderr" | "heartbeat" | "evidence",
  "client_report_id": "runner-local-seq-7",
  "stream": "stdout",
  "message": "Compiling 14 files",
  "data": "...",
  "evidence": {},
  "observed_at": "2024-..."
}
```

Reports are **append-only**. A report with `event: "started"`, `"progress"`,
`"stdout"`, `"stderr"`, or `"evidence"` moves a `claimed` assignment to
`running`.

### Complete request

```json
{
  "claim_token": "uuid-claim-token",
  "client_report_id": "runner-local-seq-final",
  "evidence": {
    "exit_code": 0
  },
  "message": "All tests passed"
}
```

### Fail request

```json
{
  "claim_token": "uuid-claim-token",
  "client_report_id": "runner-local-seq-final",
  "evidence": {
    "exit_code": 1,
    "failure_class": "action_failed"
  },
  "message": "2 tests failed",
  "reason": "test_failure"
}
```

**`evidence` is required** for both `complete` and `fail`. Without it the request
is rejected with `evidence_required`.

## Assignment state machine

```
queued ──claim──► claimed ──start──► running ──succeed──► succeeded
   │                │                  │
   │                │                  └──fail──────────► failed
   │                │                  │
   │                │                  └──expire─────────► expired
   │                │                  │
   │                │                  └──abandon────────► abandoned
   │                │
   └──expire────────► expired         Terminal states are final.
   │                │
   └──abandon───────► abandoned
```

Terminal states: `succeeded`, `failed`, `expired`, `abandoned`.

## Replay semantics

`GET /api/workspaces/:id/runs/:run_id` returns the normalized run replay
document:

```json
{
  "id": "run-...",
  "workspace_id": "ws-...",
  "summary": { "...": "..." },
  "artifacts": [{ "type": "command_output" }],
  "timeline": [{ "action": "run.command_requested" }]
}
```

The timeline is ordered oldest-first and is reconstructed from audit rows whose
metadata marks them as run-ledger events. Immediate local runs may include the
capped command-output artifact from command history. Runner-backed runs include
assignment/report references rather than raw runner output.

`GET /api/runner/v1/assignments/:id` returns the exact same JSON every time:

```json
{
  "protocol": "jx.runner.v1",
  "assignment": { ... },
  "reports": [ ... ]
}
```

Guarantees:
1. **Idempotent**: Same request, same response.
2. **Read-only**: No mutation, no audit event, no new assignment.
3. **Stable ordering**: Reports ordered by `position` ascending.
4. **No claim token**: Never included in replay.

## Failure classes

| Class | Meaning | Retryable? |
|---|---|---|
| `enqueue_failed` | Assignment could not be queued | Yes (fix payload) |
| `claim_rejected` | Runner not eligible | Yes (upgrade capabilities) |
| `lease_expired` | Claim token expired | Yes (re-poll) |
| `report_rejected` | Report invalid | Sometimes |
| `action_failed` | Command failed | Yes (new assignment) |
| `replay_mismatch` | State inconsistent | No (investigate) |
| `runner_lost` | Runner abandoned | Yes (new runner) |

See [`docs/failure_taxonomy.md`](failure_taxonomy.md) for the full internal
reason → external class mapping and HTTP status codes.

## Capability routing

Capability routing is **advisory scheduling only**. DevIDE may use workspace,
host, OS, tools, repo, branch isolation, runtime_id, runtime_path, and
concurrency-limit data to decide which runner can claim an assignment. It never
uses those fields to authorize a command; argv still comes only from
`DevIDE.Runners.SafeAction`.

## Safety invariants

- No runner endpoint accepts arbitrary argv or shell strings.
- No generic HTTP proxy action exists.
- No runner endpoint creates assignments or mutates workspace files/proposals.
- Safe-action ids are resolved through `DevIDE.Runners.SafeAction`.
- DevIDE must not import, alias, require, use, or call `JX.*` modules.

## JX operator commands (owned by JX, not DevIDE)

```bash
jx devide portfolio
jx devide status <workspace-id>
jx devide risks
jx devide watch --interval-ms 5000
jx actions execute <action-id> --confirm
```

JX config lives with the `jx` package:

- `JX_DEVIDE_URL`
- `JX_DEVIDE_API_TOKEN`

## Operational boundaries

| Concern | Owner |
|---|---|
| Queue assignment | DevIDE (after policy + safe-action check) |
| Claim assignment | Runner (via poll) |
| Execute argv | Runner (local host) |
| Report progress | Runner (via append-only reports) |
| Replay / reconcile | DevIDE (idempotent GET) |
| Policy decisions | DevIDE (`Policy` module) |
| Audit logging | DevIDE (`Audit` module) |
| Workspace lifecycle | Manager (milc-devbox) |
| Terminal PTY | DevIDE (`Terminals.Session` + tmux) |
| Agent write gating | DevIDE (currently denied) |
