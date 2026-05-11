# Protocol Governance

> Version: v1 (aligned with `jx.runner.v1` as of M10)
>
> This document defines the policy for evolving the JX ↔ DevIDE runner protocol.
> It is a **governance document**, not an implementation guide.
> For the protocol contract itself, see [`docs/jx_devide.md`](jx_devide.md).
> For the state machine, see [`docs/state_machines.md`](state_machines.md).
> For failure taxonomy, see [`docs/failure_taxonomy.md`](failure_taxonomy.md).

## Principles

1. **Docs win.** When implementation and documented contract diverge,
   implementation is wrong until the protocol version is bumped and all
   fixtures are regenerated.
2. **Fixtures are law.** Every JSON fixture in `test/fixtures/jx_runner_v1/`
   is a versioned contract. Changing a fixture without a version bump is a
   protocol-breaking change.
3. **Drift tests guard the boundary.** Tests in `drift_test.exs` fail on
   envelope drift, failure-class drift, state-machine drift, and safe-action
   registry drift. They must pass before any merge.
4. **No implicit upgrades.** A runner or JX client must not assume new fields
   exist. Additive changes require explicit negotiation.

## Version format

Protocol versions follow `jx.runner.v{N}` where `N` is a monotonically
increasing positive integer.

Examples:
- `jx.runner.v1` — current stable
- `jx.runner.v2` — next major revision (if ever)

Protocol versions are **not** SemVer. There are no minor or patch levels.
Every increment is a potential breaking change that requires both sides to
upgrade.

## Fixture directory structure

```
test/fixtures/
  jx_runner_v1/     ← current stable protocol
    enqueue_request.json
    enqueue_response.json
    poll_request.json
    poll_response.json
    report_request.json
    report_response.json
    complete_request.json
    complete_response.json
    fail_request.json
    fail_response.json
    replay_response.json
    error_claim_rejected.json
    error_report_rejected.json
  jx_runner_v2/     ← future protocol (do not create until needed)
```

When bumping from v1 to v2:
1. Create `test/fixtures/jx_runner_v2/` with all fixtures.
2. Update `@protocol_version` in `drift_test.exs`.
3. Update `Runners.protocol/0` return value.
4. Update all docs references to the new version.
5. Keep v1 fixtures and drift tests for backward compatibility testing.

## Changelog

### jx.runner.v1 (M10)

**Stable since:** 2024-05-10

**Defined in:**
- `lib/dev_ide/runners.ex` (protocol implementation)
- `lib/dev_ide/runners/state_machine.ex` (state machine)
- `lib/dev_ide/runners/failure.ex` (failure taxonomy)
- `lib/dev_ide/runners/safe_action.ex` (safe-action registry)
- `docs/jx_devide.md`
- `docs/state_machines.md`
- `docs/failure_taxonomy.md`
- `docs/glossary.md`

**Features:**
- Enqueue assignments via `POST /api/workspaces/:id/runs` with `execution_protocol: "jx.runner.v1"`
- Poll for one compatible assignment via `POST /api/runner/v1/assignments/poll`
- Append progress reports via `POST /api/runner/v1/assignments/:id/reports`
- Terminal complete/fail via `POST /api/runner/v1/assignments/:id/{complete,fail}`
- Idempotent replay via `GET /api/runner/v1/assignments/:id`
- Claim lease with configurable expiry (default 15 minutes)
- Capability-based routing (advisory scheduling only)
- Exact duplicate detection by `client_report_id`
- Forbidden payload scanning (no argv/url/http smuggling)
- Failure class taxonomy (7 classes)
- Safe-action registry derived from `Commands.allowlist/0`

**State machine:**
```
queued -> claimed -> running -> succeeded | failed | expired | abandoned
```

**Invariants:**
- Runners cannot create assignments.
- Runners cannot send arbitrary argv.
- No generic HTTP proxy action exists.
- Evidence is required for terminal reports.
- Replay is read-only and idempotent.

## Change categories

| Category | Example | Protocol bump required? |
|---|---|---|
| Additive field (optional, ignored by old clients) | New `annotations` field in report evidence | **No** (if old clients ignore it) |
| Additive endpoint | New `POST /api/runner/v1/assignments/:id/cancel` | **Yes** (runner must know about it) |
| New state | Add `paused` to state machine | **Yes** (state machine change) |
| New transition | Allow `claimed -> paused` | **Yes** (state machine change) |
| New failure class | Add `quota_exceeded` | **Yes** (taxonomy change) |
| Remove/rename field | Remove `failure_reason` from assignment payload | **Yes** (breaking) |
| Change field semantics | `lease_expires_at` becomes absolute instead of relative | **Yes** (breaking) |
| Change auth model | Switch from bearer to mTLS | **Yes** (breaking) |
| Fix bug in payload generation | `data_truncated` now correctly boolean | **No** (bugfix, same contract) |

## Decision process

1. **Propose:** Open a PR that includes:
   - The proposed change description
   - Updated fixtures (if additive, show old + new side-by-side)
   - Updated drift tests
   - Updated docs (this file, `jx_devide.md`, `state_machines.md`, etc.)

2. **Review:** At least one reviewer verifies:
   - `mix test test/dev_ide/runners/drift_test.exs` passes
   - All fixtures are updated
   - Docs and implementation are consistent

3. **Version:** If bump required:
   - Update `Runners.protocol/0`
   - Create new fixture directory
   - Update this changelog
   - Announce to JX and runner maintainers

4. **Migrate:** Old protocol version is supported for a deprecation window:
   - Minor bugfixes: 4 weeks
   - Major version bump: 12 weeks
   - After deprecation, endpoints return `410 Gone` with `failure_class: "protocol_not_supported"`

## Drift test policy

The following drift tests must always pass:

| Test | File | Guards against |
|---|---|---|
| Protocol version stable | `drift_test.exs` | Accidental protocol string change |
| Failure class completeness | `drift_test.exs` | New internal errors without taxonomy mapping |
| Fixture failure class validity | `drift_test.exs` | Fixtures using obsolete/invalid classes |
| State machine transitions | `drift_test.exs` | Undocumented transitions or missing documented ones |
| Start event set | `drift_test.exs` | Events that advance state machine changed |
| Safe action registry | `drift_test.exs` | Allowlist derivation drift |
| Envelope key stability | `drift_test.exs` | Unexpected fields in response envelopes |
| Assignment payload shape | `drift_test.exs` | Assignment schema drift |
| Report payload shape | `drift_test.exs` | Report schema drift |
| Struct field parity | `drift_test.exs` | Elixir struct fields diverging from documented schema |

## Safe-action governance

Safe actions are the **only** execution path for runners. New safe-action kinds
require:

1. A new capability string (e.g., `git:v1`)
2. A new `kind` atom in `SafeAction`
3. A new entry in `Commands.allowlist/0` OR a new derivation rule
4. Updated fixtures showing the new `action` payload
5. Updated capability routing tests
6. **Explicit approval** — safe-action kinds are not additive without review

The current v1 safe-action kind is:

- `:workspace_command` — requires `workspace-command:v1`

## Capability governance

Capabilities are advisory scheduling hints, not authorization. Adding a new
capability:

1. Does **not** require a protocol bump if it is advisory only.
2. Must be documented in `docs/glossary.md`.
3. Must have a corresponding test in `drift_test.exs` or `protocol_test.exs`.

## Contact

Protocol evolution proposals are filed as issues against the `dev_ide` project
with label `protocol`.
