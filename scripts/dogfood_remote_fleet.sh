#!/usr/bin/env bash
set -euo pipefail

# Local dogfood flow for the remote fleet runtime.
#
# Starts a controller node and a standalone runner node, seeds the current repo
# as a workspace, delegates one success command and one deterministic failure
# command, replays attach state, verifies recovery approval gating, and exports
# complete dossier bundles.

WORKSPACE_ID="${WORKSPACE_ID:-dev_ide}"
WORKSPACE_PATH="${WORKSPACE_PATH:-$PWD}"
COMMAND_ID="${COMMAND_ID:-format}"
FAIL_COMMAND_ID="${FAIL_COMMAND_ID:-dogfood.fail}"
PHX_PORT="${PHX_PORT:-4176}"
DEV_IDE_API_TOKEN="${DEV_IDE_API_TOKEN:-dogfood-api-token}"
DEV_IDE_RUNNER_TOKEN="${DEV_IDE_RUNNER_TOKEN:-dogfood-runner-token}"
DEVIDE_COOKIE="${DEVIDE_COOKIE:-devide_dogfood}"
LOG_DIR="${LOG_DIR:-tmp/dogfood_remote_fleet}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-1}"
RUN_FAILURE_LEG="${RUN_FAILURE_LEG:-1}"
CONTROLLER_WAIT_ATTEMPTS="${CONTROLLER_WAIT_ATTEMPTS:-90}"
EXECUTION_WAIT_ATTEMPTS="${EXECUTION_WAIT_ATTEMPTS:-90}"
TERMINAL_WAIT_ATTEMPTS="${TERMINAL_WAIT_ATTEMPTS:-120}"
POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-1000}"

mkdir -p "$LOG_DIR"
: >"$LOG_DIR/operator.log"

cleanup() {
  if [[ -f "$LOG_DIR/runner.pid" ]]; then
    kill "$(cat "$LOG_DIR/runner.pid")" 2>/dev/null || true
  fi

  if [[ -f "$LOG_DIR/controller.pid" ]]; then
    kill "$(cat "$LOG_DIR/controller.pid")" 2>/dev/null || true
  fi
}

trap cleanup EXIT

rpc() {
  local expr="$1"
  local out="$LOG_DIR/rpc-$RANDOM.out"

  if ! DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
    elixir --sname "devide_operator_$$$RANDOM" --cookie "$DEVIDE_COOKIE" \
      -S mix run --no-start --no-compile -e "$expr" >"$out" 2>>"$LOG_DIR/operator.log"; then
    cat "$out" >&2 || true
    return 1
  fi

  tee -a "$LOG_DIR/operator.log" <"$out" >&2
  grep -E '.+' "$out" | tail -n 1
}

controller_expr='
[_node, host] = Atom.to_string(Node.self()) |> String.split("@")
target = String.to_atom("devide_controller@" <> host)
true = Node.connect(target)
:ok = :rpc.call(target, Logger, :configure, [[level: :warning]])
target
'

seed_workspace() {
  WORKSPACE_ID="$WORKSPACE_ID" WORKSPACE_PATH="$WORKSPACE_PATH" rpc "
controller = ($controller_expr)
workspace_id = System.fetch_env!(\"WORKSPACE_ID\")
workspace_path = System.fetch_env!(\"WORKSPACE_PATH\")
metadata = %{
  \"id\" => workspace_id,
  \"branch\" => :os.cmd(~c\"git -C #{workspace_path} rev-parse --abbrev-ref HEAD\") |> to_string() |> String.trim(),
  \"git_sha\" => :os.cmd(~c\"git -C #{workspace_path} rev-parse HEAD\") |> to_string() |> String.trim()
}
{:ok, _record} =
  :rpc.call(controller, DevIDE.Workspaces.State, :sync, [
    %DevIDE.Workspace{
      id: workspace_id,
      name: workspace_id,
      user: \"dogfood\",
      branch: metadata[\"branch\"],
      status: :running,
      path: workspace_path,
      metadata: metadata
    }
  ])
IO.puts(workspace_id)
"
}

delegate_command() {
  local command_id="$1"
  local label="$2"

  WORKSPACE_ID="$WORKSPACE_ID" COMMAND_ID="$command_id" rpc "
controller = ($controller_expr)
workspace_id = System.fetch_env!(\"WORKSPACE_ID\")
command_id = System.fetch_env!(\"COMMAND_ID\")
{:ok, action} = :rpc.call(controller, DevIDE.Runners.SafeAction, :fetch_command, [command_id])
{:ok, assignment} =
  :rpc.call(controller, DevIDE.Assignments, :create, [
    %{
      workspace_id: workspace_id,
      actor_id: \"dogfood\",
      metadata: %{
        dogfood: true,
        safe_action_id: action.id,
        safe_action_version: action.version,
        command_id: command_id
      }
    }
  ])
requirements =
  DevIDE.Fleet.AssignmentRequirements.new(
    capabilities: action.requires,
    max_runtime_ms: 300_000
  )
:ok = :rpc.call(controller, DevIDE.Fleet.Queue, :enqueue, [assignment.id, requirements])
IO.puts(assignment.id)
"
}

wait_for_execution() {
  local assignment_id="$1"

  ASSIGNMENT_ID="$assignment_id" EXECUTION_WAIT_ATTEMPTS="$EXECUTION_WAIT_ATTEMPTS" POLL_INTERVAL_MS="$POLL_INTERVAL_MS" rpc "
controller = ($controller_expr)
assignment_id = System.fetch_env!(\"ASSIGNMENT_ID\")
attempts = System.fetch_env!(\"EXECUTION_WAIT_ATTEMPTS\") |> String.to_integer()
poll_interval_ms = System.fetch_env!(\"POLL_INTERVAL_MS\") |> String.to_integer()
execution_id =
  1..attempts
  |> Enum.reduce_while(nil, fn _attempt, _ ->
    executions = :rpc.call(controller, DevIDE.Fleet.ExecutionProjectionStore, :for_assignment, [assignment_id])

    case executions do
      [%{id: id} | _] -> {:halt, id}
      _ ->
        Process.sleep(poll_interval_ms)
        {:cont, nil}
    end
  end)

if is_nil(execution_id), do: raise(\"execution_not_observed for #{assignment_id}\")
IO.puts(execution_id)
"
}

wait_for_terminal() {
  local execution_id="$1"

  EXECUTION_ID="$execution_id" TERMINAL_WAIT_ATTEMPTS="$TERMINAL_WAIT_ATTEMPTS" POLL_INTERVAL_MS="$POLL_INTERVAL_MS" rpc "
controller = ($controller_expr)
execution_id = System.fetch_env!(\"EXECUTION_ID\")
attempts = System.fetch_env!(\"TERMINAL_WAIT_ATTEMPTS\") |> String.to_integer()
poll_interval_ms = System.fetch_env!(\"POLL_INTERVAL_MS\") |> String.to_integer()
state =
  1..attempts
  |> Enum.reduce_while(nil, fn _attempt, _ ->
    case :rpc.call(controller, DevIDE.Fleet.ExecutionProjectionStore, :get, [execution_id]) do
      {:ok, %{state: state}} when state in [:completed, :failed, :abandoned, :expired] ->
        {:halt, state}

      _ ->
        Process.sleep(poll_interval_ms)
        {:cont, nil}
    end
  end)

if is_nil(state), do: raise(\"terminal_state_not_observed for #{execution_id}\")
IO.puts(state)
"
}

attach_summary() {
  local execution_id="$1"
  local output_file="$2"

  EXECUTION_ID="$execution_id" OUTPUT_FILE="$output_file" rpc "
controller = ($controller_expr)
execution_id = System.fetch_env!(\"EXECUTION_ID\")
output_file = System.fetch_env!(\"OUTPUT_FILE\")
{:ok, packet} = :rpc.call(controller, DevIDE.Fleet, :attach_packet, [execution_id, []])
summary = %{
  execution_id: execution_id,
  state: to_string(packet.execution.state),
  historical_chunks: length(packet.historical_chunks),
  live_topic: packet.live_topic,
  dossier_executions: length(packet.dossier.executions)
}
File.write!(output_file, Jason.encode!(summary, pretty: true))
IO.puts(Jason.encode!(summary))
"
}

recovery_gate_summary() {
  local assignment_id="$1"
  local output_file="$2"

  ASSIGNMENT_ID="$assignment_id" OUTPUT_FILE="$output_file" rpc "
controller = ($controller_expr)
assignment_id = System.fetch_env!(\"ASSIGNMENT_ID\")
output_file = System.fetch_env!(\"OUTPUT_FILE\")
{:ok, assignment} = :rpc.call(controller, DevIDE.Assignments, :get, [assignment_id])
actions = :rpc.call(controller, DevIDE.Assignments.Recovery, :propose, [assignment_id])
summary =
  case actions do
    [action | _] ->
      denied = :rpc.call(controller, DevIDE.Fleet, :apply_approved_recovery, [action, nil, \"dogfood\", []])
      {:ok, approval} =
        :rpc.call(controller, DevIDE.Fleet, :request_approval, [
          action.kind,
          %{type: \"assignment\", ref: assignment_id, workspace_id: assignment.workspace_id},
          [actor_id: \"dogfood\", reason: \"dogfood recovery gate check\"]
        ])
      %{
        assignment_id: assignment_id,
        recovery_actions: length(actions),
        apply_without_approval: inspect(denied),
        requested_approval_id: approval.id,
        requested_approval_status: approval.status
      }

    [] ->
      %{assignment_id: assignment_id, recovery_actions: 0}
  end

File.write!(output_file, Jason.encode!(summary, pretty: true))
IO.puts(Jason.encode!(summary))
"
}

export_dossier() {
  local assignment_id="$1"
  local output_file="$2"

  ASSIGNMENT_ID="$assignment_id" OUTPUT_FILE="$output_file" rpc "
controller = ($controller_expr)
assignment_id = System.fetch_env!(\"ASSIGNMENT_ID\")
output_file = System.fetch_env!(\"OUTPUT_FILE\")
{:ok, path} = :rpc.call(controller, DevIDE.Fleet.DossierExport, :write_assignment, [assignment_id, output_file, []])
IO.puts(path)
"
}

echo "starting controller on port $PHX_PORT"
if [[ "$RUN_MIGRATIONS" == "1" ]]; then
  echo "running migrations"
  mix ecto.migrate >"$LOG_DIR/migrate.log" 2>&1
fi

DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" PORT="$PHX_PORT" \
  elixir --sname devide_controller --cookie "$DEVIDE_COOKIE" -S mix phx.server \
  >"$LOG_DIR/controller.log" 2>&1 &
echo "$!" >"$LOG_DIR/controller.pid"

controller_ready=0
for _ in $(seq 1 "$CONTROLLER_WAIT_ATTEMPTS"); do
  if curl -fsS "http://localhost:$PHX_PORT/" >/dev/null 2>&1; then
    controller_ready=1
    break
  fi

  sleep 1
done

if [[ "$controller_ready" != "1" ]]; then
  echo "controller did not become healthy on http://localhost:$PHX_PORT" >&2
  tail -n 80 "$LOG_DIR/controller.log" >&2 || true
  exit 1
fi

echo "seeding workspace $WORKSPACE_ID at $WORKSPACE_PATH"
seed_workspace >/dev/null

echo "starting standalone runner"
DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
  elixir --sname devide_runner --cookie "$DEVIDE_COOKIE" -S mix jx.runner.start \
  --endpoint "http://localhost:$PHX_PORT" \
  >"$LOG_DIR/runner.log" 2>&1 &
echo "$!" >"$LOG_DIR/runner.pid"

sleep 2

echo "delegating success command $COMMAND_ID"
success_assignment_id="$(delegate_command "$COMMAND_ID" success)"
success_execution_id="$(wait_for_execution "$success_assignment_id")"
success_state="$(wait_for_terminal "$success_execution_id")"
attach_summary "$success_execution_id" "$LOG_DIR/attach-success.json" >/dev/null
export_dossier "$success_assignment_id" "$LOG_DIR/dossier-success.json" >/dev/null

failure_json="null"
if [[ "$RUN_FAILURE_LEG" == "1" ]]; then
  echo "delegating failure command $FAIL_COMMAND_ID"
  failure_assignment_id="$(delegate_command "$FAIL_COMMAND_ID" failure)"
  failure_execution_id="$(wait_for_execution "$failure_assignment_id")"
  failure_state="$(wait_for_terminal "$failure_execution_id")"
  attach_summary "$failure_execution_id" "$LOG_DIR/attach-failure.json" >/dev/null
  recovery_gate_summary "$failure_assignment_id" "$LOG_DIR/recovery-gate.json" >/dev/null
  export_dossier "$failure_assignment_id" "$LOG_DIR/dossier-failure.json" >/dev/null

  failure_json=$(cat <<JSON
{
    "command_id": "$FAIL_COMMAND_ID",
    "assignment_id": "$failure_assignment_id",
    "execution_id": "$failure_execution_id",
    "state": "$failure_state",
    "attach": "$LOG_DIR/attach-failure.json",
    "recovery_gate": "$LOG_DIR/recovery-gate.json",
    "dossier": "$LOG_DIR/dossier-failure.json"
  }
JSON
)
fi

cat >"$LOG_DIR/summary.json" <<JSON
{
  "workspace_id": "$WORKSPACE_ID",
  "workspace_path": "$WORKSPACE_PATH",
  "success": {
    "command_id": "$COMMAND_ID",
    "assignment_id": "$success_assignment_id",
    "execution_id": "$success_execution_id",
    "state": "$success_state",
    "attach": "$LOG_DIR/attach-success.json",
    "dossier": "$LOG_DIR/dossier-success.json"
  },
  "failure": $failure_json
}
JSON

echo "dogfood summary: $LOG_DIR/summary.json"
echo "controller log: $LOG_DIR/controller.log"
echo "runner log: $LOG_DIR/runner.log"
