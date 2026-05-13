# Dogfood Phase 2

Purpose: validate whether DevIDE can be trusted for daily delegated engineering
work. This phase is intentionally operational. Do not add speculative autonomy
or broad architecture here; delegate real work, record friction, and fix only
trust, visibility, recovery, lifecycle, and ergonomics pain.

## Ledger

### 2026-05-12 — Full Test Loop Delegated Through Fleet Runner

Command:

```bash
LOG_DIR=tmp/dogfood_phase2_test \
PHX_PORT=4186 \
COMMAND_ID=test \
bash scripts/dogfood_remote_fleet.sh
```

Evidence:

| Item | Value |
|---|---|
| Success assignment | `9fbd52af-1ebf-405f-b46f-30ff0a2c7eba` |
| Success execution | `83b3c287-674f-4179-9cc2-b8566ab02e97` |
| Success state | `completed` |
| Persisted output replay | `567` historical chunks |
| Success dossier | `tmp/dogfood_phase2_test/dossier-success.json` |
| Failure assignment | `411e1be2-41a1-461a-8af6-73d4c551333c` |
| Failure execution | `5e6ec788-67b4-4d1e-94a8-c24ab4b0da51` |
| Failure state | `failed` |
| Failure dossier | `tmp/dogfood_phase2_test/dossier-failure.json` |
| Recovery gate | `{:error, :approval_required}` |
| Approval requested | `f0292c4e-aad3-4433-96d5-f6d535e40b9a` |

Operational result:

- Full `mix test --color` ran through the controller + standalone runner path.
- Replay output volume is realistic and persisted.
- Failure/recovery path remained gated.
- Failure dossier contained assignment, events, execution, runner, workspace,
  artifact, recovery action, and timeline evidence.
- No project-owned `devide_`, `test-...`, or renamed `ws-1` tmux sessions
  remained after execution.

Friction observed:

- No new blocking friction in this run.
- Prior Phase 1 tmux lifecycle leaks are fixed on the real delegated path.

Next validation targets:

- Delegate `assets.build`.
- Delegate a longer mixed sequence against a non-DevIDE repo.
- Exercise attach/takeover while a long-running delegated task is still active.
- Repeat with a runner on another host.

### 2026-05-12 — Asset Build Delegated Through Fleet Runner

Command:

```bash
LOG_DIR=tmp/dogfood_phase2_assets \
PHX_PORT=4187 \
COMMAND_ID=assets.build \
bash scripts/dogfood_remote_fleet.sh
```

Evidence:

| Item | Value |
|---|---|
| Success assignment | `c37bd4e2-e06e-4d3d-8a29-31e871a8a2c9` |
| Success execution | `ad75b246-6adb-4a08-89b0-a6f784821f72` |
| Success state | `completed` |
| Persisted output replay | `4` historical chunks |
| Success dossier | `tmp/dogfood_phase2_assets/dossier-success.json` |
| Failure assignment | `f506b917-727f-4ee5-81a3-2527259794f6` |
| Failure execution | `f6b24d47-d67c-401e-bd29-240ef2386a6c` |
| Failure state | `failed` |
| Failure dossier | `tmp/dogfood_phase2_assets/dossier-failure.json` |
| Recovery gate | `{:error, :approval_required}` |
| Approval requested | `5408891a-5afa-4173-b54c-a4535e6e0f72` |

Operational result:

- `mix assets.build` ran through the controller + standalone runner path.
- Output replay persisted, but at the expected small asset-build volume.
- Failure/recovery path remained gated.
- Failure dossier contained assignment, events, execution, runner, workspace,
  artifact, recovery action, and timeline evidence.
- No project-owned `devide_`, `test-...`, or renamed `ws-1` tmux sessions
  remained after execution.

Friction observed:

- No new blocking friction in this run.
- The dogfood script remains biased toward a success leg plus deterministic
  failure leg; useful for validation, but noisy when the operator only wants a
  single delegated work command.

Next validation targets:

- Add or use a single-command dogfood mode if repeated daily use proves the
  failure leg too noisy.
- Delegate a longer mixed sequence against a non-DevIDE repo.
- Exercise attach/takeover while a long-running delegated task is still active.
- Repeat with a runner on another host.

### 2026-05-12 — Active Attach/Takeover During Delegated Precommit

Command:

```bash
LOG_DIR=tmp/dogfood_phase2_active_takeover \
PHX_PORT=4188 \
COMMAND_ID=precommit \
bash scripts/dogfood_remote_fleet.sh
```

During the success leg, an operator process called `DevIDE.Fleet.prepare_takeover/2`
and `DevIDE.Fleet.attach_packet/2` against the live execution.

Evidence:

| Item | Value |
|---|---|
| Success assignment | `6850b3e9-9cf8-4ab8-b896-8adb27954ad3` |
| Success execution | `8c2a80e8-bc54-4405-8d5d-8ea5d6a3027a` |
| Success state | `completed` |
| Live takeover tmux session | `$248` |
| Takeover observed chunks | `305` |
| Live attach observed chunks | `306` |
| Final persisted output replay | `571` historical chunks |
| Success dossier | `tmp/dogfood_phase2_active_takeover/dossier-success.json` |
| Failure assignment | `164102ec-ffef-4e0b-8f60-5a83ce391663` |
| Failure execution | `573e62c1-d435-4dd0-85f0-b05fc76aeda5` |
| Failure state | `failed` |
| Failure dossier | `tmp/dogfood_phase2_active_takeover/dossier-failure.json` |
| Recovery gate | `{:error, :approval_required}` |
| Approval requested | `d7599dbf-43b4-40ad-a8a8-aa61b46271c9` |

Operational result:

- Live attach and takeover worked while the delegated `mix precommit` execution
  was still running.
- Attach replay caught up from the persisted output stream and exposed the live
  execution topic.
- Recovery approval gates still held after the success leg.
- No project-owned `devide_`, `test-...`, or renamed workspace tmux sessions
  remained after execution.

Friction observed:

- No new blocking friction in this run.

### 2026-05-12 — Non-DevIDE Repo Test Loop

Initial command:

```bash
LOG_DIR=tmp/dogfood_phase2_saysure_test \
PHX_PORT=4189 \
WORKSPACE_ID=saysure \
WORKSPACE_PATH=/Users/developer/Documents/GitHub/workspaces/saysure \
COMMAND_ID=test \
bash scripts/dogfood_remote_fleet.sh
```

The first run failed before the delegated Saysure `mix test` reached a terminal
state:

| Item | Value |
|---|---|
| Initial assignment | `5d1044de-2b58-48f5-b2be-bcbf24d60584` |
| Initial execution | `cb4a1092-1556-4f7b-a1be-9b017343b218` |
| Failure mode | `terminal_state_not_observed` |
| Root friction | default terminal wait was too short for a real non-DevIDE repo test loop |

Operational fix:

- `scripts/dogfood_remote_fleet.sh` now exposes `CONTROLLER_WAIT_ATTEMPTS`,
  `EXECUTION_WAIT_ATTEMPTS`, `TERMINAL_WAIT_ATTEMPTS`, and `POLL_INTERVAL_MS`.
- The leaked project-owned tmux session from the failed harness run was cleaned
  up and did not recur in the successful rerun.

Successful rerun:

```bash
LOG_DIR=tmp/dogfood_phase2_saysure_test_rerun \
PHX_PORT=4190 \
WORKSPACE_ID=saysure \
WORKSPACE_PATH=/Users/developer/Documents/GitHub/workspaces/saysure \
COMMAND_ID=test \
TERMINAL_WAIT_ATTEMPTS=900 \
bash scripts/dogfood_remote_fleet.sh
```

Evidence:

| Item | Value |
|---|---|
| Success assignment | `39817911-9ac5-47d7-91e2-3b2705c6cc65` |
| Success execution | `b47c20e1-5713-4b09-a038-2eba5775921c` |
| Success state | `completed` |
| Persisted output replay | `720` historical chunks |
| Success dossier | `tmp/dogfood_phase2_saysure_test_rerun/dossier-success.json` |
| Failure assignment | `ee4f77a8-3ab3-4240-b518-01bf6ddbc01b` |
| Failure execution | `2edd168a-7d4d-4210-93ea-574015770fa8` |
| Failure state | `failed` |
| Failure dossier | `tmp/dogfood_phase2_saysure_test_rerun/dossier-failure.json` |
| Recovery gate | `{:error, :approval_required}` |
| Approval requested | `275c61da-8cce-41a6-b2a0-be9b1a79b322` |

Operational result:

- A separate Phoenix repo's `mix test` ran through the controller + standalone
  runner path.
- Longer output replay worked at `720` chunks.
- Recovery approval gates still held after the real repo test run.
- No project-owned tmux sessions remained after the successful rerun.

Friction observed:

- Real repo test/build loops need operator-controlled wait windows.
- The controller is still run through the dev `mix phx.server` path in the
  dogfood harness. This is acceptable for local validation, but remote or daily
  use should prefer release/prod-style startup once that path is convenient.

### 2026-05-12 — Single-Command Daily Dogfood Mode

Command:

```bash
LOG_DIR=tmp/dogfood_phase2_single_command \
PHX_PORT=4191 \
COMMAND_ID=assets.build \
RUN_FAILURE_LEG=0 \
bash scripts/dogfood_remote_fleet.sh
```

Evidence:

| Item | Value |
|---|---|
| Success assignment | `bb6309d4-b27f-4a02-8e91-5270ac301b87` |
| Success execution | `00a22bc6-a18d-4943-8487-87bbbde886ef` |
| Success state | `completed` |
| Persisted output replay | `4` historical chunks |
| Success dossier | `tmp/dogfood_phase2_single_command/dossier-success.json` |
| Failure leg | skipped with `"failure": null` in `summary.json` |

Operational result:

- Daily validation can now run a single delegated command without forcing the
  deterministic failure/recovery leg.
- Release validation still keeps the failure leg enabled by default.
- No project-owned tmux sessions remained after execution.

### 2026-05-12 — Remote Runner Host Check

Reachability check:

| Host | Result |
|---|---|
| `creamery_mini` | SSH refused |
| `milcmini` | SSH reachable, Elixir/Mix present, temporary checkout created under `/tmp` |
| `testserver` | SSH reachable, repo checkout not found |
| `devbox` | SSH reachable, repo checkout not found |

Attempted flow:

1. Created a temporary checkout on `milcmini`:
   `/tmp/devide-remote-runner-phase2.D3HHUq`.
2. Ran `mix deps.get` successfully on the remote host.
3. Started a local controller on port `4192`.
4. Exposed it to `milcmini` with an SSH reverse tunnel:
   `ssh -N -R 4192:localhost:4192 milcmini`.
5. Confirmed the remote host could reach the controller at
   `http://localhost:4192/`.
6. Started the remote runner from the temporary checkout:
   `mix jx.runner.start --endpoint http://localhost:4192 --runner-id dogfood-milcmini-1 --hostname milcmini`.

Operational result:

- The remote runner can be set up from a clean checkout and can reach a local
  controller through a reverse SSH tunnel.
- The runner process starts and receives work, but it also starts the full
  application supervision tree on the runner host.
- Because the full app starts `DevIde.Repo`, the remote runner tried to connect
  to a local `dev_ide_dev` database on `milcmini`. That database did not exist,
  causing repeated Postgrex connection failures and preventing a clean remote
  execution.
- The attempted delegated assignment did not produce an observed execution
  projection before the operator timeout.

Remaining blocker:

- Standalone runner startup is not boring on a fresh remote machine because it
  currently depends on local controller-app infrastructure, especially
  `DevIde.Repo`.
- The runner path needs a remote-safe runtime profile or release entrypoint that
  starts only the runner dependencies needed for HTTP transport and command
  execution.
- This is Dogfood Phase 2 friction, not M86 feature work: fix the startup
  ergonomics before trusting remote runners for daily work.
