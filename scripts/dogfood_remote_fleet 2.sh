#!/usr/bin/env bash
set -euo pipefail

# Local two-process smoke test for the remote fleet substrate.
#
# Required:
#   WORKSPACE_ID=<observed workspace id>
#
# Optional:
#   COMMAND_ID=format
#   DEV_IDE_API_TOKEN=dogfood-api-token
#   DEV_IDE_RUNNER_TOKEN=dogfood-runner-token
#   DEVIDE_COOKIE=devide_dogfood

WORKSPACE_ID="${WORKSPACE_ID:-}"
COMMAND_ID="${COMMAND_ID:-format}"
PHX_PORT="${PHX_PORT:-4000}"
DEV_IDE_API_TOKEN="${DEV_IDE_API_TOKEN:-dogfood-api-token}"
DEV_IDE_RUNNER_TOKEN="${DEV_IDE_RUNNER_TOKEN:-dogfood-runner-token}"
DEVIDE_COOKIE="${DEVIDE_COOKIE:-devide_dogfood}"
LOG_DIR="${LOG_DIR:-tmp/dogfood_remote_fleet}"

if [[ -z "$WORKSPACE_ID" ]]; then
  echo "WORKSPACE_ID is required" >&2
  exit 64
fi

mkdir -p "$LOG_DIR"

cleanup() {
  if [[ -f "$LOG_DIR/runner.pid" ]]; then
    kill "$(cat "$LOG_DIR/runner.pid")" 2>/dev/null || true
  fi

  if [[ -f "$LOG_DIR/controller.pid" ]]; then
    kill "$(cat "$LOG_DIR/controller.pid")" 2>/dev/null || true
  fi
}

trap cleanup EXIT

echo "starting controller on port $PHX_PORT"
DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" PHX_PORT="$PHX_PORT" \
  elixir --sname devide_controller --cookie "$DEVIDE_COOKIE" -S mix phx.server \
  >"$LOG_DIR/controller.log" 2>&1 &
echo "$!" >"$LOG_DIR/controller.pid"

for _ in $(seq 1 60); do
  if curl -fsS "http://localhost:$PHX_PORT/" >/dev/null 2>&1; then
    break
  fi

  sleep 1
done

echo "starting standalone runner"
DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
  elixir --sname devide_runner --cookie "$DEVIDE_COOKIE" -S mix jx.runner.start \
  --endpoint "http://localhost:$PHX_PORT" \
  >"$LOG_DIR/runner.log" 2>&1 &
echo "$!" >"$LOG_DIR/runner.pid"

rpc() {
  local expr="$1"

  DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
    elixir --sname "devide_operator_$$" --cookie "$DEVIDE_COOKIE" -S mix run --no-start -e "$expr"
}

controller_expr='
[_node, host] = Atom.to_string(Node.self()) |> String.split("@")
controller = String.to_atom("devide_controller@" <> host)
true = Node.connect(controller)
controller
'

echo "delegating safe command $COMMAND_ID for workspace $WORKSPACE_ID"
assignment_id="$(
  WORKSPACE_ID="$WORKSPACE_ID" COMMAND_ID="$COMMAND_ID" rpc "
controller = $controller_expr
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
IO.write(assignment.id)
"
)"

echo "$assignment_id" >"$LOG_DIR/assignment.id"
echo "assignment_id=$assignment_id"

echo "waiting for runner execution"
execution_id="$(
  ASSIGNMENT_ID="$assignment_id" rpc "
controller = $controller_expr
assignment_id = System.fetch_env!(\"ASSIGNMENT_ID\")
execution_id =
  1..60
  |> Enum.reduce_while(nil, fn _attempt, _ ->
    executions = :rpc.call(controller, DevIDE.Fleet.ExecutionProjectionStore, :for_assignment, [assignment_id])

    case executions do
      [%{id: id} | _] -> {:halt, id}
      _ ->
        Process.sleep(1_000)
        {:cont, nil}
    end
  end)

if is_nil(execution_id), do: exit({:shutdown, :execution_not_observed})
IO.write(execution_id)
"
)"

echo "$execution_id" >"$LOG_DIR/execution.id"
echo "execution_id=$execution_id"

echo "attach/reconnect replay packet"
EXECUTION_ID="$execution_id" rpc "
controller = $controller_expr
execution_id = System.fetch_env!(\"EXECUTION_ID\")
{:ok, packet} = :rpc.call(controller, DevIDE.Fleet, :attach_packet, [execution_id, []])
IO.inspect(%{
  execution: packet.execution,
  historical_chunks: length(packet.historical_chunks),
  live_topic: packet.live_topic,
  dossier_executions: length(packet.dossier.executions)
})
"

echo "failure/recovery inspection"
ASSIGNMENT_ID="$assignment_id" rpc "
controller = $controller_expr
assignment_id = System.fetch_env!(\"ASSIGNMENT_ID\")
IO.inspect(:rpc.call(controller, DevIDE.Assignments.Recovery, :propose, [assignment_id]))
"

echo "logs: $LOG_DIR/controller.log $LOG_DIR/runner.log"
