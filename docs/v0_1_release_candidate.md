# DevIDE v0.1 Internal Release Candidate

This release candidate prepares the dogfoodable remote fleet runtime for
internal use. The bar is operational repeatability, not broad product
completeness.

## M81 Release Boundary

### In v0.1

- Phoenix controller serving the workspace picker, terminal LiveViews, fleet
  dashboard, runner detail page, assignment detail page, and dossier links.
- Local browser terminal path: xterm.js -> Phoenix Channel -> session ->
  tmux/erlexec.
- Remote/fleet runner path over HTTP:
  - `mix jx.runner.start --endpoint http://localhost:4000`
  - runner registration, heartbeat, offer polling, lease renewal, output
    upload, terminal success/failure reporting, drain, and shutdown.
- Fleet runner Phoenix Channel transport for reconnect/resume validation.
- Assignment event replay, execution projection, artifact persistence,
  recovery proposals, approval gating, and dossier export.
- One-command local dogfood smoke:
  `bash scripts/dogfood_remote_fleet.sh`.
- OTP release packaging through `mix release dev_ide`, with migrations,
  static assets, README, and docs included in the release directory.

### Out of v0.1

- Public hosted service, multi-tenant billing, and external SLA.
- Generic arbitrary command execution. Runners execute only allowlisted
  `DevIDE.Commands` safe actions.
- Runner-created assignments. Operators/controllers create assignments;
  runners only claim and report.
- Escript packaging. v0.1 supports the OTP release path for the controller and
  repo-checkout Mix tasks for dogfood runner/operator commands.
- Full remote SSH provisioning or workspace creation. DevIDE observes and
  validates workspaces; the milc-devbox manager remains a separate service.
- Automatic recovery execution. Recovery remains approval-gated.

### Supported Runner Paths

| Path | Status | Start Command | Notes |
|---|---|---|---|
| Local controller + local runner | Supported dogfood path | `bash scripts/dogfood_remote_fleet.sh` | Starts both processes and proves delegation, output, recovery gating, and dossier export. |
| Existing controller + standalone HTTP runner | Supported internal path | `DEV_IDE_RUNNER_TOKEN=... mix jx.runner.start --endpoint http://host:4000` | Runner token should be distinct from the operator API token. |
| Phoenix Channel runner transport | Experimental internal path | channel topic `runner:<runner_id>` on `/fleet_runner` | Covered by protocol tests; not the default dogfood path. |
| Legacy `/api/runner/v1/*` durable runner protocol | Supported compatibility path | external runner polls `/api/runner/v1/assignments/poll` | Stable protocol v1, separate from fleet runtime endpoints. |
| Escript runner/controller | Out of scope | n/a | No escript is produced for v0.1. |

### Experimental APIs

The following are internal and may change without migration support before a
later public release:

- `/api/fleet/v1/*`
- `/fleet` and `/fleet/runners/:id`
- `DevIDE.Fleet.*`
- `mix jx.attach`
- `mix jx.dossier.export`
- `mix jx.runner.start`
- `scripts/dogfood_remote_fleet.sh`

Stable for v0.1 compatibility:

- `/api/runner/v1/*`
- assignment replay semantics
- safe-action command ids exposed by `DevIDE.Commands.allowlist/0`

## M82 Install And Start Flow

### Local Dogfood Smoke

```bash
mix deps.get
mix ecto.setup

DEV_IDE_API_TOKEN=dogfood-api-token \
DEV_IDE_RUNNER_TOKEN=dogfood-runner-token \
WORKSPACE_ID=dev_ide \
WORKSPACE_PATH="$PWD" \
COMMAND_ID=format \
FAIL_COMMAND_ID=dogfood.fail \
bash scripts/dogfood_remote_fleet.sh
```

The script runs migrations, starts the controller, starts a standalone runner,
delegates one successful safe command, delegates one deterministic failure,
captures attach summaries, checks recovery approval gating, and exports
dossiers under `tmp/dogfood_remote_fleet/`.

### Controller Release

```bash
export MIX_ENV=prod
export PHX_SERVER=true
export PORT=4000
export PHX_HOST=localhost
export SECRET_KEY_BASE="$(mix phx.gen.secret)"
export DATABASE_URL="ecto://USER:PASS@HOST:5432/dev_ide_prod"
export DEV_IDE_API_TOKEN="$(mix phx.gen.secret)"
export DEV_IDE_RUNNER_TOKEN="$(mix phx.gen.secret)"
export MILC_DEVBOX_MANAGER_URL="http://manager.local:9000"
export DEV_IDE_WORKSPACES_ROOT="/workspaces"

mix assets.deploy
mix release dev_ide --overwrite
_build/prod/rel/dev_ide/bin/migrate
_build/prod/rel/dev_ide/bin/dev_ide start
```

### Standalone Runner

```bash
DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
mix jx.runner.start \
  --endpoint "http://localhost:4000" \
  --runner-id "runner-local-1" \
  --hostname "$(hostname)" \
  --capability workspace-command:v1
```

The runner registers its identity, heartbeats, polls for assignment offers,
renews leases during execution, uploads output chunks, and reports terminal
status. `Ctrl-C` is acceptable for local dogfood. Programmatic graceful
shutdown is available through `DevIDE.Fleet.RemoteRunner.shutdown/2` and the
fleet runner shutdown endpoint.

## M83 Operator Guide

1. Delegate.
   - Use the assignment/operator surface or create a safe-action assignment
     with metadata containing `safe_action_id` and `command_id`.
   - Enqueue it with `DevIDE.Fleet.Queue.enqueue/2`.
2. Observe.
   - Open `/fleet` to verify runner registration, pool state, leases, and
     scheduler visibility.
   - Open `/fleet/runners/:id` for runner trust state, heartbeat, active
     leases, current execution, failures, and assignment/dossier anchors.
3. Attach.
   - Run `mix jx.attach <execution_id>` or inspect the attach packet through
     the runner/assignment UI links.
   - Attach replays durable chunks first, then points at the live topic.
4. Review.
   - For failures, inspect assignment events, execution state, artifact chunks,
     failure reason, and recovery proposals.
   - The deterministic dogfood failure writes one stderr artifact and leaves a
     reviewable failed execution.
5. Approve.
   - Request approval for retry/recovery/takeover with the assignment as the
     target.
   - Recovery apply without approval must return `{:error, :approval_required}`.
6. Recover.
   - Apply only a granted recovery action. v0.1 deliberately keeps this gated;
     there is no automatic recovery loop.
7. Export dossier.
   - Run:
     ```bash
     mix jx.dossier.export <assignment_id> --output tmp/dossier.json
     ```
   - The bundle includes assignment, assignment events, execution, runner,
     workspace, artifacts, recovery actions, timeline, and the current runtime
     dossier view.

## M84 Packaging And Release Checks

Run:

```bash
bash scripts/verify_v0_1_release.sh
```

The check verifies:

- no escript packaging is configured for v0.1;
- prod assets build and digest;
- `mix release dev_ide --overwrite` succeeds;
- release binary exists at `_build/prod/rel/dev_ide/bin/dev_ide`;
- migration helper exists at `_build/prod/rel/dev_ide/bin/migrate`;
- assignment-event and artifact migrations are present in the release;
- `lib/dev_ide-0.1.0/priv/static/cache_manifest.json` is present in the release;
- `README.md` and `docs/v0_1_release_candidate.md` are present in the release.

Config defaults checked for v0.1:

| Config | Expected |
|---|---|
| `DEV_IDE_API_TOKEN` | Required in prod; general API bearer. |
| `DEV_IDE_RUNNER_TOKEN` | Recommended for runner transport; falls back to API token only for local compatibility. |
| `MILC_DEVBOX_MANAGER_URL` | Required in prod. |
| `DEV_IDE_WORKSPACES_ROOT` | Optional env override; default remains `/workspaces`. |
| `PHX_SERVER` | Required for release server start. |

## M85 RC Notes

### Candidate

Current tag: `v0.1.0-rc.2`.

Do not tag until the gates below are green in the release branch workspace.

### Dogfood Transcript

Current dogfood evidence from M81-M85:

```text
LOG_DIR=tmp/dogfood_m81_current PHX_PORT=4181 bash scripts/dogfood_remote_fleet.sh

success assignment 653b5f8f-e93e-45ee-a2b3-b79d79fe4c60
success execution  cf162565-c4cb-4786-aa98-2a467349b2c8 completed
success dossier    tmp/dogfood_m81_current/dossier-success.json

failure assignment 1f910db7-dc36-497f-950f-808b16f8d075
failure execution  b0fc4aa7-a7cb-4b57-8290-6637a54c094e failed
failure dossier    tmp/dogfood_m81_current/dossier-failure.json
recovery gate      {:error, :approval_required}
approval           7042574e-af98-41dc-bbeb-dc0d8f11811e requested
```

Dogfood Phase 1 operational validation after `v0.1.0-rc.1`:

```text
LOG_DIR=tmp/dogfood_phase1_precommit_clean3
PHX_PORT=4185
COMMAND_ID=precommit
bash scripts/dogfood_remote_fleet.sh

success assignment 6fb3d38e-af01-439f-8d10-98a843f81d9a
success execution  aea607ef-5775-4300-a130-a4195ba9335e completed
success chunks     569 historical chunks
success dossier    tmp/dogfood_phase1_precommit_clean3/dossier-success.json

failure assignment 1e025dce-db74-4fcf-9634-e8617c011a0c
failure execution  34284445-31ea-4213-8a1d-b7a86393e48f failed
failure dossier    tmp/dogfood_phase1_precommit_clean3/dossier-failure.json
recovery gate      {:error, :approval_required}
approval           f5823ba2-fa7a-4950-820e-dddddcd763cd requested
tmux cleanup       no project-owned devide_, test-..., or renamed ws-1 sessions remained
```

`v0.1.0-rc.2` includes two operational cleanup fixes discovered by the
delegated `precommit` run:

- fleet execution tmux sessions are killed on terminal completed, failed, and
  abandoned states;
- terminal/channel test sessions clean up renamed tmux sessions whose names are
  changed by local tmux configuration.

This validates delegated dogfood execution, replay/output persistence at
realistic chunk volume, approval/recovery gating, dossier export, and tmux
lifecycle cleanup through the real runner path.

### Known Limitations

- Fleet APIs and fleet UI are internal/experimental.
- Standalone runner is started from a repo checkout for v0.1 dogfood.
- Release packaging is OTP release only, not escript.
- Runner lifecycle endpoints are operational primitives, not a full admin UI.
- The default dogfood success command is `format`, which may produce zero
  artifact chunks when the workspace is already formatted.
- Remote workspace provisioning is still delegated to milc-devbox manager.
- Recovery is intentionally manual and approval-gated.

### Required Gates

```bash
mix format
mix test test/dev_ide/fleet/remote_runner_test.exs \
  test/dev_ide/fleet/remote_substrate_test.exs \
  test/dev_ide/fleet/remote_failure_modes_test.exs \
  test/dev_ide/fleet/dossier_export_test.exs \
  test/dev_ide_web/api/fleet_runner_controller_test.exs \
  test/dev_ide_web/channels/fleet_runner_channel_test.exs \
  test/dev_ide_web/live/fleet_live_test.exs
mix precommit
mix assets.build
bash scripts/verify_v0_1_release.sh
git diff --check
```
