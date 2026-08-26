# Typed Jido worker actions

[#1015](https://github.com/dl-alexandre/casein/issues/1015) (parent
[#1012](https://github.com/dl-alexandre/casein/issues/1012)). Thin adapter
between a headless Jido worker and Casein-owned capabilities.

## Boundary

- **Trusted context** supplies workspace, task, attempt, worktree, principal,
  capability profile, and correlation id. Model-authored args cannot override
  that identity.
- **Casein services** are called in-process (`CodeTools`, `AgentEvents`,
  `Activity`, `Audit`). There is no unauthenticated HTTP loopback.
- **OpenCode / MCP** stays on `POST /api/code/mcp` and Terminal MCP while the
  Jido path is behind `CASEIN_JIDO_HEADLESS`. See
  `Casein.Agents.JidoActions.Compatibility`.
- **Projection:** `Casein.Agents.JidoLifecycle` (#1016) consumes action
  results without changing this catalog or result atoms.
- **Skills:** `Casein.Agents.JidoSkills` (#1017) maps `SKILL.md` onto this
  catalog. Unsupported names fail closed; they do not change these result
  atoms.

Raw terminal keystrokes and pane scrapes are not actions. Cross-workspace
paths and unscoped credentials are denied.

## Catalog

| Action | Capability | Supported | Idempotent | Mutates |
|--------|------------|-----------|------------|---------|
| `code_read` | code | yes — `CodeTools` | yes | no |
| `code_search` | code | yes — `CodeTools` | yes | no |
| `code_apply_patch` | code | yes — `CodeTools` | yes (already-applied) | yes |
| `code_exec` | code | yes — `CodeTools` | no | yes |
| `git_status` | git | not yet (`not_yet_supported`) | yes | no |
| `git_diff` | git | not yet (`not_yet_supported`) | yes | no |
| `task_wait` | task | not yet (`not_yet_supported`) | yes | no |
| `task_cancel` | task | not yet (`not_yet_supported`) | yes | yes |
| `request_clarification` | human | yes — headless, no pane | yes (`request_id`) | yes |
| `request_human_input` | human | yes — headless, no pane | yes (`request_id`) | yes |
| `report_progress` | handoff | yes — activity only | yes | no |
| `report_result` | handoff | yes — activity only | yes | yes |
| `handoff_evidence` | handoff | yes — activity only | yes | yes |

`Casein.Agents.JidoActions.catalog/0` is the discovery surface.

## Results

Every call returns `{:ok, payload}` or `{:error, payload}` with a stable
`result` atom:

| `result` | When |
|----------|------|
| `ok` | Capability succeeded |
| `denied` | Policy, path, scope, unknown/forbidden tool, or flag off |
| `blocked_on_human` | Clarification / human-input request |
| `timeout` | Verifier or action deadline |
| `cancelled` | Attempt already cancelled |
| `stale_attempt` | Attempt already completed/failed/timed out |
| `provider_failure` | CodeTools/provider unavailable |
| `not_yet_supported` | git/task follow-ups not on the #1013 contract |
| `invalid` | Missing trusted context or bad arguments |

`blocked_on_human` also sets `error: :awaiting_human` so the #1014 worker
classifier can park the attempt. Timeouts and provider failures set
`retryable: true`.

## Feature flag

Same switch as the pod:

| Switch | Effect |
|--------|--------|
| `CASEIN_JIDO_HEADLESS=1` / `:jido_headless` | Typed actions run |
| `CASEIN_JIDO_HEADLESS_WORKSPACES` / `:jido_headless_workspaces` | Those workspace ids only |
| flag off | `result: :denied`, `error: :legacy_opencode` |

OpenCode callers keep using Code MCP when the flag is off.
`Compatibility.path/1` reports `:legacy_opencode` or `:jido_actions`.

## Dash PR handoff

`handoff_evidence` records `repository`, optional `pull_request`, `head_sha`,
and bounded `review_thread_ids`. After that receipt, Dash/Verda owns live
GitHub PR mutations. Workers do not create, approve, resolve, auto-merge, or
merge the PR.
