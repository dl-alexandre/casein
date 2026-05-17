#!/usr/bin/env bash
set -euo pipefail

# Remote runner smoke flow.
#
# Starts a local controller, exposes it to a remote host with an SSH reverse
# tunnel, starts a standalone runner from a temporary remote checkout, delegates
# one allowlisted command, writes a summary, and cleans up local/remote process
# state.

REMOTE_HOST="${REMOTE_HOST:?REMOTE_HOST is required, for example REMOTE_HOST=milcmini}"
REMOTE_PATH="${REMOTE_PATH:-/tmp/devide-remote-runner-smoke.$$}"
REMOVE_REMOTE_PATH="${REMOVE_REMOTE_PATH:-1}"
WORKSPACE_ID="${WORKSPACE_ID:-remote-${REMOTE_HOST}-devide-smoke}"
COMMAND_ID="${COMMAND_ID:-compile}"
PHX_PORT="${PHX_PORT:-4193}"
DEV_IDE_API_TOKEN="${DEV_IDE_API_TOKEN:-dogfood-api-token}"
DEV_IDE_RUNNER_TOKEN="${DEV_IDE_RUNNER_TOKEN:-dogfood-runner-token}"
DEVIDE_COOKIE="${DEVIDE_COOKIE:-devide_dogfood}"
LOG_DIR="${LOG_DIR:-tmp/dogfood_remote_runner_smoke}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-1}"
CONTROLLER_WAIT_ATTEMPTS="${CONTROLLER_WAIT_ATTEMPTS:-90}"
RUNNER_WAIT_ATTEMPTS="${RUNNER_WAIT_ATTEMPTS:-300}"
EXECUTION_WAIT_ATTEMPTS="${EXECUTION_WAIT_ATTEMPTS:-120}"
TERMINAL_WAIT_ATTEMPTS="${TERMINAL_WAIT_ATTEMPTS:-300}"
POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-1000}"
RUNNER_ID="${RUNNER_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
CONTROLLER_SNAME="${CONTROLLER_SNAME:-devide_controller_remote_smoke_${PHX_PORT}}"

mkdir -p "$LOG_DIR"
: >"$LOG_DIR/operator.log"

cleanup() {
  if [[ -f "$LOG_DIR/remote-runner.pid" ]]; then
    kill "$(cat "$LOG_DIR/remote-runner.pid")" 2>/dev/null || true
  fi

  if [[ -f "$LOG_DIR/tunnel.pid" ]]; then
    kill "$(cat "$LOG_DIR/tunnel.pid")" 2>/dev/null || true
  fi

  if [[ -f "$LOG_DIR/controller.pid" ]]; then
    kill "$(cat "$LOG_DIR/controller.pid")" 2>/dev/null || true
  fi

  ssh "$REMOTE_HOST" "
    pids=\$(pgrep -f 'runner-id $RUNNER_ID' || true)
    if [ -n \"\$pids\" ]; then
      kill \$pids 2>/dev/null || true
      sleep 1
      pids=\$(pgrep -f 'runner-id $RUNNER_ID' || true)
      if [ -n \"\$pids\" ]; then
        kill -9 \$pids 2>/dev/null || true
      fi
    fi
  " >/dev/null 2>&1 || true

  if [[ "$REMOVE_REMOTE_PATH" == "1" ]]; then
    ssh "$REMOTE_HOST" "rm -rf '$REMOTE_PATH'" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

rpc() {
  local expr="$1"
  local out="$LOG_DIR/rpc-$RANDOM.out"

  if ! DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
    CONTROLLER_SNAME="$CONTROLLER_SNAME" REMOTE_HOST="$REMOTE_HOST" \
    elixir --sname "devide_remote_smoke_operator_$$$RANDOM" --cookie "$DEVIDE_COOKIE" \
      -S mix run --no-start --no-compile -e "$expr" >"$out" 2>>"$LOG_DIR/operator.log"; then
    cat "$out" >&2 || true
    return 1
  fi

  tee -a "$LOG_DIR/operator.log" <"$out" >&2
  grep -E '.+' "$out" | tail -n 1
}

controller_expr='
[_node, host] = Atom.to_string(Node.self()) |> String.split("@")
controller_sname = System.fetch_env!("CONTROLLER_SNAME")
target = String.to_atom(controller_sname <> "@" <> host)
true = Node.connect(target)
:ok = :rpc.call(target, Logger, :configure, [[level: :warning]])
target
'

seed_and_delegate() {
  WORKSPACE_ID="$WORKSPACE_ID" REMOTE_PATH="$REMOTE_PATH" COMMAND_ID="$COMMAND_ID" \
    EXECUTION_WAIT_ATTEMPTS="$EXECUTION_WAIT_ATTEMPTS" TERMINAL_WAIT_ATTEMPTS="$TERMINAL_WAIT_ATTEMPTS" \
    POLL_INTERVAL_MS="$POLL_INTERVAL_MS" LOG_DIR="$LOG_DIR" rpc "
controller = ($controller_expr)
workspace_id = System.fetch_env!(\"WORKSPACE_ID\")
workspace_path = System.fetch_env!(\"REMOTE_PATH\")
command_id = System.fetch_env!(\"COMMAND_ID\")
execution_attempts = System.fetch_env!(\"EXECUTION_WAIT_ATTEMPTS\") |> String.to_integer()
terminal_attempts = System.fetch_env!(\"TERMINAL_WAIT_ATTEMPTS\") |> String.to_integer()
poll_interval_ms = System.fetch_env!(\"POLL_INTERVAL_MS\") |> String.to_integer()
log_dir = System.fetch_env!(\"LOG_DIR\")
remote_host = System.fetch_env!(\"REMOTE_HOST\")

raw = %{
  \"id\" => workspace_id,
  \"branch\" => \"remote-smoke\",
  \"git_sha\" => \"working-tree\",
  \"remote_host\" => remote_host
}

{:ok, _record} =
  :rpc.call(controller, DevIDE.Workspaces.State, :sync, [
    %DevIDE.Workspace{
      id: workspace_id,
      name: workspace_id,
      user: \"dogfood\",
      branch: \"remote-smoke\",
      status: :running,
      path: workspace_path,
      metadata: raw
    }
  ])

{:ok, action} = :rpc.call(controller, DevIDE.Runners.SafeAction, :fetch_command, [command_id])

{:ok, assignment} =
  :rpc.call(controller, DevIDE.Assignments, :create, [
    %{
      workspace_id: workspace_id,
      actor_id: \"dogfood\",
      metadata: %{
        dogfood: true,
        remote_host: remote_host,
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

execution_id =
  1..execution_attempts
  |> Enum.reduce_while(nil, fn _attempt, _ ->
    case :rpc.call(controller, DevIDE.Fleet.ExecutionProjectionStore, :for_assignment, [assignment.id]) do
      [%{id: id} | _] -> {:halt, id}
      _ ->
        Process.sleep(poll_interval_ms)
        {:cont, nil}
    end
  end)

if is_nil(execution_id), do: raise(\"remote_execution_not_observed for #{assignment.id}\")

state =
  1..terminal_attempts
  |> Enum.reduce_while(nil, fn _attempt, _ ->
    case :rpc.call(controller, DevIDE.Fleet.ExecutionProjectionStore, :get, [execution_id]) do
      {:ok, %{state: state}} when state in [:completed, :failed, :abandoned, :expired] ->
        {:halt, state}

      _ ->
        Process.sleep(poll_interval_ms)
        {:cont, nil}
    end
  end)

if is_nil(state), do: raise(\"remote_terminal_not_observed for #{execution_id}\")

{:ok, packet} = :rpc.call(controller, DevIDE.Fleet, :attach_packet, [execution_id, []])

summary = %{
  remote_host: remote_host,
  runner_id: packet.execution.runner_id,
  workspace_id: workspace_id,
  workspace_path: workspace_path,
  command_id: command_id,
  assignment_id: assignment.id,
  execution_id: execution_id,
  state: state,
  historical_chunks: length(packet.historical_chunks)
}

File.write!(Path.join(log_dir, \"summary.json\"), Jason.encode!(summary, pretty: true))
IO.puts(Jason.encode!(summary))
"
}

wait_for_runner() {
  RUNNER_ID="$RUNNER_ID" RUNNER_WAIT_ATTEMPTS="$RUNNER_WAIT_ATTEMPTS" POLL_INTERVAL_MS="$POLL_INTERVAL_MS" rpc "
controller = ($controller_expr)
runner_id = System.fetch_env!(\"RUNNER_ID\")
attempts = System.fetch_env!(\"RUNNER_WAIT_ATTEMPTS\") |> String.to_integer()
poll_interval_ms = System.fetch_env!(\"POLL_INTERVAL_MS\") |> String.to_integer()

runner =
  1..attempts
  |> Enum.reduce_while(nil, fn _attempt, _ ->
    case :rpc.call(controller, DevIDE.Fleet, :get_runner, [runner_id]) do
      {:ok, runner} -> {:halt, runner}
      _ ->
        Process.sleep(poll_interval_ms)
        {:cont, nil}
    end
  end)

if is_nil(runner), do: raise(\"remote_runner_not_registered for #{runner_id}\")
IO.puts(runner.id)
"
}

echo "syncing checkout to $REMOTE_HOST:$REMOTE_PATH"
ssh "$REMOTE_HOST" "rm -rf '$REMOTE_PATH' && mkdir -p '$REMOTE_PATH'"
rsync -a --delete \
  --exclude .git \
  --exclude deps \
  --exclude _build \
  --exclude tmp \
  ./ "$REMOTE_HOST:$REMOTE_PATH/"

echo "fetching remote deps"
ssh "$REMOTE_HOST" "cd '$REMOTE_PATH' && mix deps.get" >"$LOG_DIR/remote-deps.log" 2>&1

if [[ "$RUN_MIGRATIONS" == "1" ]]; then
  echo "running local migrations"
  mix ecto.migrate >"$LOG_DIR/migrate.log" 2>&1
fi

echo "starting controller on local port $PHX_PORT"
DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" PORT="$PHX_PORT" \
  elixir --sname "$CONTROLLER_SNAME" --cookie "$DEVIDE_COOKIE" -S mix phx.server \
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

echo "opening reverse tunnel on $REMOTE_HOST:$PHX_PORT"
ssh -N -R "$PHX_PORT:localhost:$PHX_PORT" "$REMOTE_HOST" >"$LOG_DIR/tunnel.log" 2>&1 &
echo "$!" >"$LOG_DIR/tunnel.pid"

tunnel_ready=0
for _ in $(seq 1 "$CONTROLLER_WAIT_ATTEMPTS"); do
  if ssh "$REMOTE_HOST" "curl -fsS 'http://localhost:$PHX_PORT/' >/dev/null"; then
    tunnel_ready=1
    break
  fi

  sleep 1
done

if [[ "$tunnel_ready" != "1" ]]; then
  echo "remote host could not reach controller through tunnel" >&2
  cat "$LOG_DIR/tunnel.log" >&2 || true
  exit 1
fi

echo "starting remote runner $RUNNER_ID on $REMOTE_HOST"
ssh "$REMOTE_HOST" \
  "cd '$REMOTE_PATH' && DEV_IDE_RUNNER_TOKEN='$DEV_IDE_RUNNER_TOKEN' mix jx.runner.start --endpoint 'http://localhost:$PHX_PORT' --runner-id '$RUNNER_ID' --hostname '$REMOTE_HOST'" \
  >"$LOG_DIR/remote-runner.log" 2>&1 &
echo "$!" >"$LOG_DIR/remote-runner.pid"

echo "waiting for remote runner registration"
wait_for_runner >/dev/null

echo "delegating $COMMAND_ID to remote runner"
seed_and_delegate >/dev/null

echo "remote runner smoke summary: $LOG_DIR/summary.json"
echo "remote runner log: $LOG_DIR/remote-runner.log"
