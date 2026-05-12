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
