#!/usr/bin/env bash
# Shared git worktree helpers for DevIDE agent launch.
# Sourced by launch-casein-agent.sh — not executed directly.

agent_worktree_root() {
  printf '%s\n' "${DEVIDE_AGENT_WORKTREE_ROOT:-${TMPDIR:-/tmp}/casein-agent-worktrees}"
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

agent_worktree_default_base_ref() {
  local primary="$1"
  local configured="${DEVIDE_AGENT_WORKTREE_BASE:-}"
  local remote_head

  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return 0
  fi

  remote_head="$(git -C "$primary" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$remote_head" ]]; then
    printf '%s\n' "$remote_head"
    return 0
  fi

  if git -C "$primary" show-ref --verify --quiet refs/remotes/origin/master; then
    printf '%s\n' "origin/master"
  elif git -C "$primary" show-ref --verify --quiet refs/remotes/origin/main; then
    printf '%s\n' "origin/main"
  else
    printf '%s\n' "HEAD"
  fi
}

agent_worktree_create() {
  local runtime="$1"
  local task="${2:-adhoc}"
  local base_ref
  local primary wt_root branch path

  primary="$(agent_worktree_primary_repo)" || {
    echo "error: DEVIDE_CHECKOUT is not a git repository" >&2
    return 1
  }

  env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" fetch --quiet origin 2>/dev/null || true
  base_ref="$(agent_worktree_default_base_ref "$primary")"

  wt_root="$(agent_worktree_root)"
  mkdir -p "$wt_root"

  branch="$(agent_worktree_branch_name "$runtime" "$task")"
  # Flatten only the branch's slashes; the leading wt_root must stay a real
  # absolute path or git treats the dash-leading result as an option.
  path="${wt_root}/${branch//\//-}"

  # Keep git's stdout ("HEAD is now at ...") out of this function's stdout —
  # callers capture it as the worktree path.
  if ! env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" worktree add -b "$branch" "$path" "$base_ref" >/dev/null 2>&1; then
    path="${wt_root}/detached-${runtime}-$(date +%s)"
    env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" worktree add --detach "$path" "$base_ref" >/dev/null
    branch="detached"
  fi

  printf '%s\n' "$path"
}

agent_worktree_report_mcp() {
  local worktree_path="$1"
  local runtime="${2:-}"
  local token="${CASEIN_API_TOKEN:-}"
  local workspace_id="${DEVIDE_WORKSPACE_ID:-}"
  local mcp_url="${DEVIDE_TERMINAL_MCP_URL:-${DEVIDE_URL:-http://127.0.0.1:4000}/api/terminals/mcp}"

  [[ -n "$token" && -n "$workspace_id" ]] || {
    echo "warn: skipping terminal_report_worktree (missing CASEIN_API_TOKEN or DEVIDE_WORKSPACE_ID)" >&2
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

  # shellcheck source=scripts/casein-curl.sh
  source "${ROOT}/scripts/casein-curl.sh"

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

# Watch the launcher PID (which becomes the agent PID after exec) from a
# detached process and remove the worktree once the agent exits, but only when
# the tree is clean — `git worktree remove` without --force is the second
# safety net. Commits survive on their agent/<runtime>/<task>-<stamp> branch.
agent_worktree_spawn_reaper() {
  local worktree_path="$1"
  local primary="$2"
  local agent_pid="$3"

  setsid bash -c '
    worktree_path="$1"
    primary="$2"
    agent_pid="$3"
    while kill -0 "$agent_pid" 2>/dev/null; do
      sleep 15
    done
    [[ -d "$worktree_path" ]] || exit 0
    if [[ -z "$(git -C "$worktree_path" status --porcelain 2>/dev/null)" ]]; then
      git -C "$primary" worktree remove "$worktree_path" >/dev/null 2>&1 || true
    fi
  ' _ "$worktree_path" "$primary" "$agent_pid" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

agent_worktree_ensure() {
  local runtime="$1"
  local task="${2:-adhoc}"

  if [[ "${DEVIDE_AGENT_SKIP_WORKTREE:-0}" == "1" ]]; then
    return 0
  fi

  # Adoption paths: a human launching *inside* an existing worktree reuses it.
  # A SPAWNED worker (DEVIDE_AGENT_FORCE_FRESH_WORKTREE=1, set by
  # spawn-agent-worker.sh) must NEVER adopt — adopting silently shares the
  # orchestrator's checkout and branch, so the worker's git ops (including a
  # tree-wide `git restore`/discard to satisfy a gate) hit other sessions' work.
  # Force it past adoption to branch a fresh worktree off the primary; because
  # agent_worktree_create runs `git -C <primary> worktree add`, it works even
  # when PWD is a linked worktree.
  if [[ "${DEVIDE_AGENT_FORCE_FRESH_WORKTREE:-0}" != "1" ]]; then
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
  fi

  local primary path
  primary="$(agent_worktree_primary_repo)" || return 1
  path="$(agent_worktree_create "$runtime" "$task")" || return 1

  export DEVIDE_CHECKOUT="$path"
  export DEVIDE_AGENT_WORKTREE_PATH="$path"
  export DEVIDE_WORKTREE=1
  export DEVIDE_GIT_DIR="${path}/.git"

  agent_worktree_report_mcp "$path" "$runtime"
  agent_worktree_spawn_reaper "$path" "$primary" "$$"
}
