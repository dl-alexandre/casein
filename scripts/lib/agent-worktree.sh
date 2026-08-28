#!/usr/bin/env bash
# Shared git worktree helpers for Casein agent launch.
# Sourced by launch-casein-agent.sh — not executed directly.

agent_worktree_root() {
  printf '%s\n' "${CASEIN_AGENT_WORKTREE_ROOT:-${TMPDIR:-/tmp}/casein-agent-worktrees}"
}

agent_worktree_is_bare() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 1
  [[ "$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null || true)" == "true" ]]
}

# Resolve the primary repo path for CASEIN_CHECKOUT.
# Works for normal work trees and bare product roots (Mira-class): on bare,
# `rev-parse --show-toplevel` fails with "must be run in a work tree", but
# `git worktree add` still works from the bare path. Prefer porcelain's first
# worktree entry (the bare root itself), then absolute-git-dir.
agent_worktree_primary_repo() {
  local checkout="${CASEIN_CHECKOUT:-}"
  local toplevel listing line bare_path=""

  if [[ -z "$checkout" ]]; then
    return 1
  fi

  if toplevel="$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$toplevel"
    return 0
  fi

  if ! agent_worktree_is_bare "$checkout"; then
    return 1
  fi

  if listing="$(git -C "$checkout" worktree list --porcelain 2>/dev/null)"; then
    while IFS= read -r line; do
      if [[ "$line" == "worktree "* ]]; then
        bare_path="${line#worktree }"
        break
      fi
    done <<<"$listing"
  fi

  if [[ -n "$bare_path" && -e "$bare_path" ]]; then
    # Preserve the caller's spelling for a bare primary. Git may canonicalize
    # /var to /private/var on macOS, but the checkout value is also persisted in
    # env.sh and must remain stable across a launch/restart pair.
    printf '%s\n' "$checkout"
    return 0
  fi

  if bare_path="$(git -C "$checkout" rev-parse --absolute-git-dir 2>/dev/null)"; then
    printf '%s\n' "$bare_path"
    return 0
  fi

  return 1
}

agent_worktree_is_linked() {
  local dir="$1"
  [[ -f "${dir}/.git" ]]
}

agent_worktree_inside_primary() {
  local dir="${1:-${PWD}}"
  local primary repo_root abs_dir abs_primary

  primary="$(agent_worktree_primary_repo)" || return 1

  # Bare primary has no work tree: standing on the bare path itself counts as
  # "inside primary" so launch still branches a fresh linked worktree.
  if agent_worktree_is_bare "$primary"; then
    abs_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
    abs_primary="$(cd "$primary" 2>/dev/null && pwd -P)" || abs_primary="$primary"
    [[ "$abs_dir" == "$abs_primary" ]]
    return
  fi

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

agent_worktree_validate_path() {
  local path="${1:-}"

  if [[ -z "$path" || ! -d "$path" ]]; then
    echo "error: agent worktree does not exist at ${path:-<unset>}" >&2
    return 1
  fi

  if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: agent worktree is not a git checkout at ${path}" >&2
    return 1
  fi
}

agent_worktree_validate_env_checkout() {
  local expected="$1"
  local env_file="${2:-${CASEIN_AGENT_ENV_FILE:-}}"
  local recorded

  if [[ -z "$env_file" || ! -r "$env_file" ]]; then
    echo "error: CASEIN_CHECKOUT=${expected} could not be verified; env.sh source is ${env_file:-<unset>}" >&2
    return 1
  fi

  recorded="$({
    # shellcheck disable=SC1090
    source "$env_file" >/dev/null 2>&1
    printf '%s' "${CASEIN_CHECKOUT:-}"
  })" || {
    echo "error: CASEIN_CHECKOUT=${expected} could not be read from env.sh source ${env_file}" >&2
    return 1
  }

  if [[ "$recorded" != "$expected" ]]; then
    echo "error: persisted CASEIN_CHECKOUT does not match the created worktree" >&2
    echo "error:   expected=${expected}" >&2
    echo "error:   recorded=${recorded:-<unset>}" >&2
    echo "error:   env.sh source=${env_file}" >&2
    return 1
  fi
}

agent_worktree_default_base_ref() {
  local primary="$1"
  local configured="${CASEIN_AGENT_WORKTREE_BASE:-}"
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
  local primary wt_root branch_base branch path attempt=0

  primary="$(agent_worktree_primary_repo)" || {
    if [[ -n "${CASEIN_CHECKOUT:-}" ]] && agent_worktree_is_bare "${CASEIN_CHECKOUT}"; then
      cat >&2 <<'EOF'
error: CASEIN_CHECKOUT is a bare git checkout but its primary path could not be resolved.
error:   Bare product roots are supported — `git worktree add` runs from the bare path.
error:   See docs/development-workflow.md (agent worktrees) and scripts/spawn-agent-worker.sh --help.
EOF
    else
      echo "error: CASEIN_CHECKOUT is not a git repository (${CASEIN_CHECKOUT:-unset})" >&2
      echo "error:   For bare product checkouts see docs/development-workflow.md (agent worktrees)." >&2
    fi
    return 1
  }

  env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" fetch --quiet origin 2>/dev/null || true
  base_ref="$(agent_worktree_default_base_ref "$primary")"

  wt_root="$(agent_worktree_root)"
  mkdir -p "$wt_root"

  # Compute the timestamped identity once. If several launches arrive in the
  # same second, add a deterministic collision suffix without recomputing the
  # path from a second clock read. The path is always derived from the exact
  # branch passed to git, so the launcher's checkout and persisted CASEIN_CHECKOUT
  # cannot drift apart.
  branch_base="$(agent_worktree_branch_name "$runtime" "$task")"

  while ((attempt < 100)); do
    if ((attempt == 0)); then
      branch="$branch_base"
    else
      branch="${branch_base}-${attempt}"
    fi

    # Flatten only the branch's slashes; the leading wt_root must stay a real
    # absolute path or git treats the dash-leading result as an option.
    path="${wt_root}/${branch//\//-}"

    if [[ -e "$path" ]] || git -C "$primary" show-ref --verify --quiet "refs/heads/${branch}"; then
      attempt=$((attempt + 1))
      continue
    fi

    # Keep git's stdout ("HEAD is now at ...") out of this function's stdout —
    # callers capture it as the worktree path.
    if env -u GH_TOKEN -u GITHUB_TOKEN git -C "$primary" worktree add -b "$branch" "$path" "$base_ref" >/dev/null 2>&1; then
      printf '%s\n' "$path"
      return 0
    fi

    attempt=$((attempt + 1))
  done

  echo "error: could not create a unique agent worktree under ${wt_root} from ${primary}" >&2
  return 1
}

agent_worktree_report_mcp() {
  local worktree_path="$1"
  local runtime="${2:-}"
  local token="${CASEIN_API_TOKEN:-}"
  local workspace_id="${CASEIN_WORKSPACE_ID:-}"
  local mcp_url="${CASEIN_TERMINAL_MCP_URL:-${CASEIN_URL:-http://127.0.0.1:4000}/api/terminals/mcp}"

  [[ -n "$token" && -n "$workspace_id" ]] || {
    echo "warn: skipping terminal_report_worktree (missing CASEIN_API_TOKEN or CASEIN_WORKSPACE_ID)" >&2
    return 0
  }

  local branch tmux_session
  branch="$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
  tmux_session="${CASEIN_TMUX_SESSION:-}"

  local params
  params="$(
    WORKTREE_PATH="$worktree_path" \
    WORKTREE_BRANCH="$branch" \
    CASEIN_WORKSPACE_ID="$workspace_id" \
    CASEIN_AGENT_RUNTIME="$runtime" \
    CASEIN_TMUX_SESSION="$tmux_session" \
    python3 -c '
import json, os
print(json.dumps({
    "workspace_id": os.environ["CASEIN_WORKSPACE_ID"],
    "worktree_path": os.environ["WORKTREE_PATH"],
    "branch": os.environ.get("WORKTREE_BRANCH") or None,
    "agent": os.environ.get("CASEIN_AGENT_RUNTIME") or None,
    "tmux_session_id": os.environ.get("CASEIN_TMUX_SESSION") or None,
}))
'
  )"

  # shellcheck source=scripts/casein-curl.sh
  source "${ROOT}/scripts/casein-curl.sh"

  local rpc_body response
  rpc_body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"terminal_report_worktree\",\"arguments\":${params}}}"

  if ! response="$(casein_curl -fsS -X POST "$mcp_url" \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d "$rpc_body" 2>&1)" \
    || [[ "$response" == *'"isError":true'* || "$response" == *'"error":'* ]]; then
    echo "warn: terminal_report_worktree failed — agent continues in degraded mode (${response:0:200})" >&2
    return 0
  fi

  echo "reported worktree ${worktree_path} to Casein" >&2
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

  if [[ "${CASEIN_AGENT_SKIP_WORKTREE:-0}" == "1" ]]; then
    return 0
  fi

  # Adoption paths: a human launching *inside* an existing worktree reuses it.
  # A SPAWNED worker (CASEIN_AGENT_FORCE_FRESH_WORKTREE=1, set by
  # spawn-agent-worker.sh) must NEVER adopt — adopting silently shares the
  # orchestrator's checkout and branch, so the worker's git ops (including a
  # tree-wide `git restore`/discard to satisfy a gate) hit other sessions' work.
  # Force it past adoption to branch a fresh worktree off the primary; because
  # agent_worktree_create runs `git -C <primary> worktree add`, it works even
  # when PWD is a linked worktree.
  if [[ "${CASEIN_AGENT_FORCE_FRESH_WORKTREE:-0}" != "1" ]]; then
    if [[ -n "${CASEIN_AGENT_WORKTREE_PATH:-}" && -d "${CASEIN_AGENT_WORKTREE_PATH}" ]]; then
      agent_worktree_validate_path "${CASEIN_AGENT_WORKTREE_PATH}" || return 1
      export CASEIN_CHECKOUT="${CASEIN_AGENT_WORKTREE_PATH}"
      export CASEIN_WORKTREE=1
      agent_worktree_report_mcp "${CASEIN_AGENT_WORKTREE_PATH}" "$runtime"
      return 0
    fi

    if agent_worktree_is_linked "${PWD}"; then
      local linked_root
      # Preserve the logical spelling supplied by the caller. On macOS Git
      # resolves /var to /private/var, but CASEIN_CHECKOUT is persisted and
      # must remain byte-for-byte stable across launch and restart.
      linked_root="${PWD}"
      agent_worktree_validate_path "$linked_root" || return 1
      export CASEIN_CHECKOUT="$linked_root"
      export CASEIN_WORKTREE=1
      agent_worktree_report_mcp "${CASEIN_CHECKOUT}" "$runtime"
      return 0
    fi

    if ! agent_worktree_inside_primary "${PWD}"; then
      export CASEIN_WORKTREE=1
      return 0
    fi
  fi

  local primary path
  primary="$(agent_worktree_primary_repo)" || return 1
  path="$(agent_worktree_create "$runtime" "$task")" || return 1
  agent_worktree_validate_path "$path" || return 1

  export CASEIN_CHECKOUT="$path"
  export CASEIN_AGENT_WORKTREE_PATH="$path"
  export CASEIN_WORKTREE=1
  export CASEIN_GIT_DIR="${path}/.git"

  agent_worktree_report_mcp "$path" "$runtime"
  agent_worktree_spawn_reaper "$path" "$primary" "$$"
}
