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
