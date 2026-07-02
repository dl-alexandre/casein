#!/usr/bin/env bash
# Shared git worktree helpers for DevIDE agent launch.
# Sourced by launch-devide-agent.sh — not executed directly.

agent_worktree_root() {
  printf '%s\n' "${DEVIDE_AGENT_WORKTREE_ROOT:-${TMPDIR:-/tmp}/devide-agent-worktrees}"
}

agent_worktree_primary_repo() {
  local checkout="${DEVIDE_CHECKOUT:-}"
  if [[ -z "$checkout" ]]; then
    return 1
  fi
  git -C "$checkout" rev-parse --show-toplevel 2>/dev/null
}

agent_worktree_is_linked() {
  local dir="$1"
  [[ -f "${dir}/.git" ]]
}

agent_worktree_inside_primary() {
  local dir="${1:-${PWD}}"
  local primary repo_root
  primary="$(agent_worktree_primary_repo)" || return 1
  repo_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ "$repo_root" == "$primary" ]] && ! agent_worktree_is_linked "$dir"
}

agent_worktree_branch_name() {
  local runtime="${1:-agent}"
  local task="${2:-adhoc}"
  local stamp
  stamp="$(date +%Y%m%d%H%M%S)"
  printf 'agent/%s/%s-%s\n' "$runtime" "$task" "$stamp"
}

agent_worktree_create() {
  local runtime="$1"
  local task="${2:-adhoc}"
  local base_ref="${DEVIDE_AGENT_WORKTREE_BASE:-origin/master}"
  local primary wt_root branch path

  primary="$(agent_worktree_primary_repo)" || {
    echo "error: DEVIDE_CHECKOUT is not a git repository" >&2
    return 1
  }

  wt_root="$(agent_worktree_root)"
  mkdir -p "$wt_root"

  branch="$(agent_worktree_branch_name "$runtime" "$task")"
  path="${wt_root}/${branch}"
  path="${path//\//-}"

  env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" fetch --quiet origin 2>/dev/null || true

  if ! env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" worktree add -b "$branch" "$path" "$base_ref" 2>/dev/null; then
    path="${wt_root}/detached-${runtime}-$(date +%s)"
    env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" worktree add --detach "$path" "$base_ref"
    branch="detached"
  fi

  printf '%s\n' "$path"
}

agent_worktree_report_mcp() {
  local worktree_path="$1"
  local runtime="${2:-}"
  local token="${DEV_IDE_API_TOKEN:-}"
  local workspace_id="${DEVIDE_WORKSPACE_ID:-}"
  local mcp_url="${DEVIDE_TERMINAL_MCP_URL:-${DEVIDE_URL:-http://127.0.0.1:4000}/api/terminals/mcp}"

  [[ -n "$token" && -n "$workspace_id" ]] || {
    echo "warn: skipping terminal_report_worktree (missing DEV_IDE_API_TOKEN or DEVIDE_WORKSPACE_ID)" >&2
    return 0
  }

  local branch tmux_session
  branch="$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
  tmux_session="${DEVIDE_TMUX_SESSION:-}"

  local params
  params="$(
    WORKTREE_PATH="$worktree_path" \
    WORKTREE_BRANCH="$branch" \
    DEVIDE_WORKSPACE_ID="$workspace_id" \
    DEVIDE_AGENT_RUNTIME="$runtime" \
    DEVIDE_TMUX_SESSION="$tmux_session" \
    python3 -c '
import json, os
print(json.dumps({
    "workspace_id": os.environ["DEVIDE_WORKSPACE_ID"],
    "worktree_path": os.environ["WORKTREE_PATH"],
    "branch": os.environ.get("WORKTREE_BRANCH") or None,
    "agent": os.environ.get("DEVIDE_AGENT_RUNTIME") or None,
    "tmux_session_id": os.environ.get("DEVIDE_TMUX_SESSION") or None,
}))
'
  )"

  # shellcheck source=scripts/devide-curl.sh
  source "${ROOT}/scripts/devide-curl.sh"

  local rpc_body response
  rpc_body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"terminal_report_worktree\",\"arguments\":${params}}}"

  if ! response="$(devide_curl -fsS -X POST "$mcp_url" \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d "$rpc_body" 2>&1)" \
    || [[ "$response" == *'"isError":true'* || "$response" == *'"error":'* ]]; then
    echo "warn: terminal_report_worktree failed — agent continues in degraded mode (${response:0:200})" >&2
    return 0
  fi

  echo "reported worktree ${worktree_path} to DevIDE" >&2
}

agent_worktree_ensure() {
  local runtime="$1"
  local task="${2:-adhoc}"

  if [[ "${DEVIDE_AGENT_SKIP_WORKTREE:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -n "${DEVIDE_AGENT_WORKTREE_PATH:-}" && -d "${DEVIDE_AGENT_WORKTREE_PATH}" ]]; then
    export DEVIDE_CHECKOUT="${DEVIDE_AGENT_WORKTREE_PATH}"
    export DEVIDE_WORKTREE=1
    agent_worktree_report_mcp "${DEVIDE_AGENT_WORKTREE_PATH}" "$runtime"
    return 0
  fi

  if agent_worktree_is_linked "${PWD}"; then
    export DEVIDE_CHECKOUT="$(git -C "${PWD}" rev-parse --show-toplevel)"
    export DEVIDE_WORKTREE=1
    agent_worktree_report_mcp "${DEVIDE_CHECKOUT}" "$runtime"
    return 0
  fi

  if ! agent_worktree_inside_primary "${PWD}"; then
    export DEVIDE_WORKTREE=1
    return 0
  fi

  local path
  path="$(agent_worktree_create "$runtime" "$task")" || return 1

  export DEVIDE_CHECKOUT="$path"
  export DEVIDE_AGENT_WORKTREE_PATH="$path"
  export DEVIDE_WORKTREE=1
  export DEVIDE_GIT_DIR="${path}/.git"

  agent_worktree_report_mcp "$path" "$runtime"
}