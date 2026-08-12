# Policy, Deploy & Export

> Server-side admission decisions (FP-1), devbox deploy/drain coordination, and the redacted API export surface — the three subsystems that gate, ship, and emit Casein state.

This is a companion reference. The authoritative operator runbook is
[`../deploy.md`](../deploy.md) and the security posture is
[`../hardening.md`](../hardening.md); this doc maps the code behind them and
does not restate them.

## Responsibility

Three adjacent concerns, grouped because they sit at the trust boundary:

- **Policy** (`lib/casein/policy/`) — the value types behind the single
  server-side admission decision point (`Casein.Policy`, FP-1). Raw-terminal
  admission, agent-write locks, proposal-apply denial, and workspace-mode
  changes all resolve to a `Decision` struct stamped with the active
  `WorkspaceMode`.
- **Deployment** (`lib/casein/deployment/`) — on-box release-handoff
  machinery for the devbox systemd/socket layout: per-instance heartbeat
  registry, graceful connection drain, deploy-drift detection against
  `origin/master`, and a deploy-wiring health probe.
- **Export** (`lib/casein/export/`) — builds the outbound `/api/workspaces`
  JSON payloads from persisted state, and a deny-list scrubber that strips
  credentials at egress before anything leaves the BEAM.

## Module map

| Module | File | Role |
|---|---|---|
| `Casein.Policy.Decision` | `lib/casein/policy/decision.ex` | Verdict struct (`:allow`/`:deny` + reason + mode + metadata) returned by every policy check. Constructors `allow/3`, `deny/4`, predicate `allow?/1`. |
| `Casein.Policy.WorkspaceMode` | `lib/casein/policy/workspace_mode.ex` | The four safety modes (`:manual`, `:review`, `:agent_write_locked`, `:shared_stage_guarded`) and their config resolution order. `resolve/1`, `valid_modes/0`. |
| `Casein.Deployment.Registry` | `lib/casein/deployment/registry.ex` | GenServer writing a per-instance JSON heartbeat file; owns instance id, version, socket path, and the `current.sock` symlink. `list_instances/0`, `mark_draining/0`, `version/0`, `socket_path/0`. |
| `Casein.Deployment.Drain` | `lib/casein/deployment/drain.ex` | GenServer counting live LiveView connections; on `start_drain/1` broadcasts an update notice and stops the VM once connections hit zero (or hard-timeout). `track/1`, `draining?/0`, `connection_count/0`. Timers go through `Casein.Clock`. |
| `Casein.Clock` | `lib/casein/clock.ex` | Prototype virtual clock + `send_after` scheduler (#897). Idle in production (real `Process.send_after/3`). Verdict: [`../prototypes/clock-step-determinism.md`](../prototypes/clock-step-determinism.md). |
| `Casein.Deployment.Drift` | `lib/casein/deployment/drift.ex` | Detects when the running revision ≠ `origin/master` HEAD via cached `git ls-remote`. Pure `assess/3`; runtime `check_and_broadcast/0`, `remote_head/1`, `check_async/0`. |
| `Casein.Deployment.Health` | `lib/casein/deployment/health.ex` | Deploy-wiring health probe: socket exists, `current.sock` points at this instance, Caddy upstream dials the socket, deploy not drifted. `status/1`, `caddy_app_dial/2`. |
| `Casein.Export.Sanitizer` | `lib/casein/export/sanitizer.ex` | Deny-list redaction: `scrub/1` drops secret keys from maps/lists/env, `redact_text/1` masks secrets in text streams. Second-line egress defense. |
| `Casein.Export.WorkspaceStatus` | `lib/casein/export/workspace_status.ex` | Builds the per-workspace API summary payloads (status, mode, git, runs, proposals, audit, deploy, previous-session search) — summaries only, never raw artifacts. `status/1`, `list_summary/0`, `runs/1`, `run/2`, `proposals/1`, `audit/1`, `previous_sessions/2`. |

> The decision point itself, `Casein.Policy` (`lib/casein/policy.ex`), lives
> outside this subsystem's assigned paths but consumes both policy value types;
> it is the caller-facing surface for everything below.

## Data flow / lifecycle

### Policy decision (FP-1)
1. A caller (e.g. `Terminals.Boundary`, `WorkspaceLive.Show`) builds a `ctx`
   map and calls a `Casein.Policy.can_*?/1` helper.
2. `Casein.Policy` resolves the active mode via `mode/1` →
   `State.mode_for/1` (or `WorkspaceMode.resolve/1` when no workspace id).
3. The helper returns a `Decision` struct via `Decision.allow/3` / `deny/4`,
   stamped with that mode (`caps` are dropped from the metadata).
4. The caller inspects `Decision.allow?/1`, performs the work only on allow,
   and is responsible for its own audit/ledger record (Policy logs nothing).
   `:apply_proposal` and `:enable_agent_write` are *always* denied.

### Deploy handoff & drain
1. On boot `Registry.init/1` writes `<instance-id>.json` into
   `/run/casein/instances` (falling back to `/tmp/...`), best-effort creates
   `current.sock → this instance`, and fires `Drift.check_async/0`.
2. Each connected LiveView calls `Drain.track/1` (via the
   `DeploymentUpdateHook` on_mount) so the drain controller monitors its pid.
3. `POST /api/drain` → `Drain.start_drain/1`: marks the instance draining in
   the registry, broadcasts `{:update_available, version, commits_behind}` on
   the `"deploy:updates"` PubSub topic, arms a 30-minute hard timeout, and —
   once `count == 0` — a 5s grace timer then calls `System.stop(0)`.
   (A test seam, `:drain_stop_system`, replaces the real stop in ExUnit.)
4. `GET /api/deploy_status` → `Health.status/1` returns the four wiring
   checks; `deploy_revision_current` is `Drift.assess/3` returning `:current`.

### Export at egress
1. `GET /api/workspaces[/:id...]` → `Casein.Export` (facade) delegates to
   `WorkspaceStatus`.
2. `WorkspaceStatus.status/1` assembles the payload from persisted
   `WorkspaceRecord` state plus cheap live reads (git status, runtime list,
   ledger, audit, proposals, deploy summary via `Health.status/1`).
3. The whole map is passed through `Sanitizer.scrub/1` before return — the
   last line of defense behind per-subsystem sanitizers.

## Public surface

Functions other code calls into this subsystem:

- **Policy value types** — `Decision.allow/3`, `Decision.deny/4`,
  `Decision.allow?/1`; `WorkspaceMode.resolve/1`, `WorkspaceMode.valid_modes/0`.
  (Consumed by `Casein.Policy`, the actual decision module.)
- **Deployment** — `Drain.track/1` (LiveView on_mount),
  `Drain.start_drain/1` (`DrainController`), `Drain.draining?/0`,
  `Drain.connection_count/0`; `Health.status/1` (`DeployStatusController`,
  `WorkspaceStatus`); `Registry.version/0` / `socket_path/0` /
  `list_instances/0` / `mark_draining/0`; `Drift.assess/3`,
  `Drift.remote_head/1`, `Drift.check_async/0`.
- **Export** — `WorkspaceStatus.{list_summary/0, status/1, runs/1, run/2,
  proposals/1, audit/1, previous_sessions/2}` (via the `Casein.Export`
  defdelegate facade);
  `Sanitizer.scrub/1` and `Sanitizer.redact_text/1` (called wherever a
  payload or text stream crosses the egress boundary).

Long-lived processes: `Registry` and `Drain` are GenServers supervised in the
application tree (see `lib/casein/application.ex`).

## Invariants & gotchas

- **Policy is pure and does not audit.** Every `can_*?` returns a `Decision`;
  the caller funnels through it *before* mutating state and owns the audit
  record. Do not log inside policy.
- **`Decision` carries the mode.** `@enforce_keys [:action, :verdict, :mode]`
  — a decision always records the policy that produced it, so audit rows carry
  both verdict and mode. `caps` are stripped from metadata before stamping.
- **Raw terminal is gated by default.** `can_use_raw_terminal?/1` allows local
  host + manual-mode workspaces by default. `:raw_terminal_everywhere` must be
  explicitly enabled for raw shell in any workspace/mode/host. This is the FP-1
  admission decision referenced in `hardening.md` "Boundaries".
- **Mode resolution order** (`WorkspaceMode.resolve/1`): per-workspace
  `:workspace_modes` override → `:default_workspace_mode` → `:review`. Invalid
  configured modes silently fall back, never crash.
- **Drain must never stop the test VM.** `Drain` is a real supervised
  singleton; its grace timer would call `System.stop(0)` mid-suite. The
  `:casein, :drain_stop_system` env injects a no-op in `test_helper.exs`.
- **`start_drain/1` is idempotent-guarded.** A second call while already
  draining returns `{:error, :already_draining}`.
- **Drain timers are clock-mediated.** `Casein.Clock.send_after/3` is a
  real `Process.send_after/3` unless `Casein.Clock.Scheduler` is running.
  Starting the scheduler is a test-only seam; it does not change production
  drain timing. Step-determinism constraints live in
  [`../prototypes/clock-step-determinism.md`](../prototypes/clock-step-determinism.md).
- **`ls-remote` is time-boxed and cached.** `Drift.remote_head/1` caches per
  branch in `:persistent_term` (`:remote_head_cache_ttl_ms`, default 60s) and
  brutal-kills the subprocess after `:ls_remote_timeout_ms` (default 5s) so a
  slow GitHub never hangs `/api/deploy_status`.
- **Drift kinds matter for durability.** A running SHA that differs from remote
  → `:revision_differs`; a non-SHA manual label → `:manual_revision`. Both are
  drift: the next canonical deploy will replace `/opt/casein/release`. (See the
  deploy-local drift gate notes; do not hand-edit the release.)
- **Export emits summaries, not artifacts.** `WorkspaceStatus` deliberately
  excludes `manager_payload`, env, `DATABASE_URL`, file contents, terminal
  scrollback, and proposal diffs. `active_run_summary/1` and `run_artifacts/1`
  are intentional stubs (the delegated-execution / batch-command stack was
  retired).
- **Scrubbing is two-layered and last.** `Sanitizer.scrub/1` is the *second*
  line behind per-subsystem sanitizers and runs on the fully-assembled payload
  immediately before return. Secret keys (`database_url`, `password`, `token`,
  `bearer`, …) are dropped entirely; env lists are scrubbed value-side.

## See also

- [`../deploy.md`](../deploy.md) — operator deploy runbook (image, env,
  TLS, smoke checks); the authoritative deployment doc.
- [`../hardening.md`](../hardening.md) — permissions, deploy-safety, and
  workspace-scoped-token posture this subsystem enforces.
- [`../architecture.md`](../architecture.md) — FP-1 (server-side execution
  authority), the Authority map, and the config-key table.
- [`../state_machines.md`](../state_machines.md) — workspace-mode and
  audit/decision lifecycles.
- [`../glossary.md`](../glossary.md) — mode, decision, and event terminology.
