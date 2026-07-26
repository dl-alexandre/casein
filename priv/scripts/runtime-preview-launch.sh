#!/usr/bin/env bash
#
# Casein-owned runtime preview launcher.
#
# Runs from a recorded runtime cwd and starts that repo's normal dev server on
# $PORT. The target repo does not need to vendor Casein's preview-env scripts.
set -euo pipefail

port="${PORT:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      port="${2:-}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$port" ]] || { echo "error: --port is required" >&2; exit 2; }

runtime_id="${CASEIN_RUNTIME_ID:-runtime-$$}"
workspace_id="${CASEIN_WORKSPACE_ID:-}"
tmux_session="${CASEIN_TMUX_SESSION:-}"
cwd="$(pwd -P)"
state="${CASEIN_PREVIEW_HOME:-${cwd}/.casein-preview}"
inst_dir="${state}/instances"
sock_dir="${state}/sockets"
log_dir="${state}/logs"
socket="${CASEIN_RUNTIME_PREVIEW_SOCKET:-${sock_dir}/${runtime_id}.sock}"
logf="${log_dir}/${runtime_id}.log"
registry="${inst_dir}/${runtime_id}.json"

mkdir -p "$inst_dir" "$sock_dir" "$log_dir"
rm -f "$socket"

json_escape() {
  python3 -c 'import json, sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

write_registry() {
  local status="$1" pid="${2:-$$}" proxy_pid="${3:-}" started
  started="$(date -u +%FT%TZ)"
  printf '{"id":"%s","kind":"runtime","ref":"runtime","sha":"","port":"%s","socket":"%s","pid":"%s","proxy_pid":"%s","db":"","worktree":"","checkout":"%s","workspaces_root":"","log":"%s","started_at":"%s","status":"%s","workspace_id":"%s","runtime_id":"%s","tmux_session_id":"%s","url":"http://127.0.0.1:%s/"}\n' \
    "$(printf '%s' "$runtime_id" | json_escape)" \
    "$(printf '%s' "$port" | json_escape)" \
    "$(printf '%s' "$socket" | json_escape)" \
    "$(printf '%s' "$pid" | json_escape)" \
    "$(printf '%s' "$proxy_pid" | json_escape)" \
    "$(printf '%s' "$cwd" | json_escape)" \
    "$(printf '%s' "$logf" | json_escape)" \
    "$started" \
    "$(printf '%s' "$status" | json_escape)" \
    "$(printf '%s' "$workspace_id" | json_escape)" \
    "$(printf '%s' "$runtime_id" | json_escape)" \
    "$(printf '%s' "$tmux_session" | json_escape)" \
    "$(printf '%s' "$port" | json_escape)" \
    > "$registry"
}

wait_for_port() {
  local i
  for i in $(seq 1 90); do
    if bash -c ":</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

build_command() {
  if [[ -n "${CASEIN_RUNTIME_PREVIEW_COMMAND:-}" ]]; then
    printf '%s\n' "bash" "-lc" "$CASEIN_RUNTIME_PREVIEW_COMMAND"
  elif [[ -x ./bin/mix ]]; then
    printf '%s\n' "./bin/mix" "dev"
  elif [[ -f mix.exs ]] && command -v mise >/dev/null 2>&1; then
    printf '%s\n' "mise" "exec" "--" "mix" "phx.server"
  elif [[ -f mix.exs ]]; then
    printf '%s\n' "mix" "phx.server"
  elif [[ -f package.json ]]; then
    printf '%s\n' "npm" "run" "dev" "--" "--host" "0.0.0.0" "--port" "$port"
  else
    return 1
  fi
}

mapfile -t command < <(build_command) || {
  echo "error: no runtime preview command detected in $cwd" >&2
  exit 127
}

app_pid=""
proxy_pid=""
cleanup() {
  [[ -n "$proxy_pid" ]] && kill "$proxy_pid" >/dev/null 2>&1 || true
  [[ -n "$app_pid" ]] && kill "$app_pid" >/dev/null 2>&1 || true
  rm -f "$socket"
}
trap cleanup EXIT INT TERM

{
  echo ">>> runtime preview cwd=$cwd port=$port socket=$socket"
  printf '>>> command:'
  printf ' %q' "${command[@]}"
  printf '\n'
} >> "$logf"

PORT="$port" "${command[@]}" >> "$logf" 2>&1 &
app_pid="$!"

if wait_for_port; then
  if command -v socat >/dev/null 2>&1; then
    socat "UNIX-LISTEN:${socket},fork,reuseaddr" "TCP:127.0.0.1:${port}" >> "$logf" 2>&1 &
    proxy_pid="$!"
    write_registry "running" "$$" "$proxy_pid"
  else
    echo "warn: socat is not installed; runtime preview has no unix socket proxy" >> "$logf"
    write_registry "running" "$$" ""
  fi
else
  echo "error: runtime preview did not answer on 127.0.0.1:${port}" >> "$logf"
  write_registry "failed" "$$" ""
  exit 1
fi

wait "$app_pid"
