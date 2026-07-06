# Dogfood Phase 2

> **Historical ledger.** The fleet-runner / delegated-execution stack referenced
> here (`scripts/dogfood_remote_fleet.sh`, `scripts/dogfood_remote_runner_smoke.sh`,
> `DevIDE.Fleet`, `mix runner.start`) was retired. These scripts no longer exist
> in the repo. The MCP side-by-side section (lower half) remains current.

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
| `boxhost` | SSH reachable, repo checkout not found |

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
   `mix runner.start --endpoint http://localhost:4192 --runner-id dogfood-milcmini-1 --hostname milcmini`.

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

### 2026-05-13 — Remote Runner Startup Fixed

Fix:

- `mix runner.start` now starts runner dependencies directly instead of
  booting the full Phoenix application with `Mix.Task.run("app.start")`.
- `AssignmentOffered` now carries the controller-approved `worktree_path` so a
  remote runner can execute in its local checkout without consulting local
  controller workspace state.
- The remote runner executor still resolves argv from `SafeAction`; the protocol
  carries only the approved workspace root, not arbitrary shell text.

Validation:

1. Rsynced the working tree to `milcmini` at
   `/tmp/devide-remote-runner-phase2.fixed`.
2. Ran `mix deps.get` on `milcmini`.
3. Started a local controller on port `4193`.
4. Exposed the local controller to `milcmini` with
   `ssh -N -R 4193:localhost:4193 milcmini`.
5. Confirmed `milcmini` could reach `http://localhost:4193/`.
6. Started the remote runner:
   `mix runner.start --endpoint http://localhost:4193 --runner-id 5c78f2a5-5fcf-45dc-9127-e1d42693d65c --hostname milcmini`.
7. Delegated `compile` to workspace path
   `/tmp/devide-remote-runner-phase2.fixed`.

Evidence:

| Item | Value |
|---|---|
| Remote host | `milcmini` |
| Runner id | `5c78f2a5-5fcf-45dc-9127-e1d42693d65c` |
| Assignment | `9ad93422-c1e2-45c5-85eb-fe07d67f0e8d` |
| Execution | `52789799-a6df-4e16-9c03-8adbf51dae07` |
| Command | `compile` |
| State | `completed` |
| Workspace path | `/tmp/devide-remote-runner-phase2.fixed` |

Operational result:

- The remote runner starts without a local `dev_ide_dev` database.
- The remote runner receives work through the controller tunnel.
- The remote runner executes from the runner-host checkout path.
- The temporary remote checkout was removed after validation.

Friction still observed:

- The runner id must be a UUID because protocol envelope validation currently
  rejects human-readable runner ids. This is acceptable for now, but the CLI
  should eventually fail before registration with a clearer error.

### 2026-05-13 — Remote Runner Smoke Ergonomics

Fix:

- `mix runner.start` now validates operator input before starting runner
  dependencies.
- Missing `--endpoint` fails with:
  `runner endpoint required via --endpoint http://host:4000`.
- Non-UUID `--runner-id` fails before registration with:
  `runner id must be a UUID`.
- Added `scripts/dogfood_remote_runner_smoke.sh` to make the remote runner smoke
  path repeatable.

Usage:

```bash
REMOTE_HOST=milcmini \
PHX_PORT=4193 \
COMMAND_ID=compile \
LOG_DIR=tmp/dogfood_remote_runner_smoke \
bash scripts/dogfood_remote_runner_smoke.sh
```

The script:

1. rsyncs the current checkout to a temporary path on the remote host;
2. runs `mix deps.get` on the remote host;
3. starts a local controller;
4. opens an SSH reverse tunnel to the remote host;
5. starts `mix runner.start` on the remote host with a UUID runner id;
6. waits for the runner to register with the controller;
7. registers a remote workspace path;
8. delegates one allowlisted command;
9. writes `summary.json`;
10. cleans up local controller, tunnel, remote runner, and temporary checkout.

Validated run:

```bash
REMOTE_HOST=milcmini \
PHX_PORT=4194 \
COMMAND_ID=compile \
LOG_DIR=tmp/dogfood_remote_runner_smoke_check2 \
bash scripts/dogfood_remote_runner_smoke.sh
```

Evidence:

| Item | Value |
|---|---|
| Remote host | `milcmini` |
| Runner id | `e9a70ebf-4bb4-4056-b090-b86c3aa5b0cd` |
| Assignment | `e0f9ab94-c402-493f-952b-595e6ec1c565` |
| Execution | `b9562988-257e-4a7a-a987-dc95f0024e92` |
| Command | `compile` |
| State | `completed` |
| Workspace path | `/tmp/devide-remote-runner-smoke.32137` |

Operational result:

- The remote runner path is now a repeatable smoke flow instead of a hand-built
  sequence of SSH, tunnel, runner, and RPC commands.
- Release validation can keep using the broader local dogfood script, while
  remote-runner validation can use this narrower script.
- The script originally raced remote first-run compilation; it now waits for
  controller-observed runner registration before delegating.
- Cleanup now uses the generated runner id to kill any surviving remote runner
  BEAM before deleting the temporary checkout.

## MCP side-by-side (human + external agent)

Purpose: validate whether DevIDE can support daily engineering with a human in
the LiveView and an external agent driving the workspace through Terminal +
Preview MCP. This path is separate from fleet-runner delegation above; both
share tmux adapters, so `mix precommit` protects both.

### Pre-flight (every session)

| Step | Check |
|------|-------|
| Deploy | Pairing changes are on `master` and CI deployed `/opt/devide/release` |
| Smoke | `source .devbox-agent.env && WORKSPACE_ID=$DEVIDE_WORKSPACE_ID bash scripts/verify_agent_pairing.sh --ci` |
| Layout | **Agents → Apply Agent Pair layout** |
| Mode | Workspace is `:manual` (raw terminal) |
| Agent env | External agent sourced `.devbox-agent.env`; passes `workspace_id` on every MCP call |
| Pane rule | Agent targets **agent** pane from `terminal_topology` only |

### Ledger template (copy per dogfood session)

```markdown
### YYYY-MM-DD — <short task title>

Participants: <human> + <agent runtime>
Workspace: <name> (<uuid>)
Deploy rev: <git sha on devbox>

Task:
- <what we tried to accomplish>

Commands / MCP flow:
- terminal_list_sessions → terminal_topology → terminal_send_command (agent pane)
- <preview steps if any>

Evidence:
| Item | Value |
|------|-------|
| Agent pane id | <%N> |
| Tests run | <mix test ...> |
| Preview | <open/observe/close or n/a> |
| Live MCP activity | <visible / missing events> |
| verify_agent_pairing.sh | <pass/fail> |

Result: <completed / partial / failed>

Friction:
- <pane collision, deploy overwrite, workspace_id scoping, preview drift, etc.>

Fixes filed:
- <issue or commit ref, or "none">
```

### First dogfood targets

1. Agent runs `mix test test/dev_ide/agents/` in the **agent** pane; human watches
   terminal + Live MCP activity.
2. Small code change → `mix precommit` in agent pane → human reviews diff in UI.
3. LiveView tweak → `preview_open_app` screenshot → human compares preview iframe.
4. Log each session in the ledger above; fix only trust, visibility, recovery, and
   ergonomics pain (Phase 2 charter).

### 2026-06-23 — Crucial improvements MCP pre-flight + agent_pair flow

Participants: human (LiveView) + Grok CLI (external agent via DevIDE Terminal MCP)

Workspace: dalexandre-devide (e7c18b93-688b-4bb0-904d-ac93d61e9372)

Deploy rev: `15ce1bf` (`GOAL_HEAD` from `goal-five-evidence.sh`; six commits on
`9b75d9c`; 18 files in `goal-deliverable-files.txt`)

Task:
- Validate MCP side-by-side pre-flight and agent-pane control plane while landing
  the top-five crucial improvements (loops quarantine, poller test gate, tmux
  durability docs, workspace-scoped agent tokens).

Commands / MCP flow:
- Pre-flight: `source .devbox-agent.env && WORKSPACE_ID=$DEVIDE_WORKSPACE_ID bash scripts/verify_agent_pairing.sh --ci`
- Apply layout: `POST /api/workspaces/:id/templates/agent_pair/apply?session=…` (REST)
- MCP (`scripts/mcp-dogfood-agent-pair.sh`, transcript `mcp-raw-transcript.jsonl`):
  `terminal_list_sessions` → `terminal_topology` → `terminal_agent_pane` →
  `terminal_send_agent_command` → `terminal_capture_agent` (agent pane only)
- Preview: n/a (terminal-only session)

Evidence:

| Item | Value |
|------|-------|
| Session | `devide_dalexandre-devide_u-dalexandre-5kdigyma` |
| Agent pane id | `%14342` (`agent_pair_marker`; `terminal_agent_pane` / send / capture agree) |
| Marker in capture | `agent-pair-dogfood-1782184397` via `terminal_capture_agent` (no `lines` tail) |
| Raw MCP transcript | `mcp-raw-transcript.jsonl` (list/topology/agent_pane/send_agent/capture_agent) |
| Tests run | `mise exec -- mix test` loops/policy/audit + `tmux_janitor_test.exs`; `pre-push-check.sh`; `hardening-audit.sh` (see `goal-five-evidence.sh` logs) |
| Preview | n/a |
| Live MCP activity | `terminal_send_agent_command` audited (`MCPAudit.record_terminal`) |
| verify_agent_pairing.sh | pass (exit 0) |

Result: completed

Friction:
- `agent_pair` must be applied per session (REST or UI) before `terminal_send_agent_*`;
  without it, `terminal_agent_pane` falls back to `agent_process` (grok/claude TUI).
- `terminal_capture` / `terminal_capture_agent` with `lines: N` can return blank padding
  on tall panes; omit `lines` for dogfood capture.

Fixes filed:
- Scoped agent tokens + poller test gate + loops quarantine (`scripts/goal-five-evidence.sh`
  runnable from a clean worktree for reproducible verification).
