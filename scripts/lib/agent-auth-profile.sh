#!/usr/bin/env bash
# Resolve opt-in workspace-scoped auth homes for Claude and Codex.
#
# Directory presence enables a profile:
#   ~/.devide/agent-auth/<workspace-key>/claude -> CLAUDE_CONFIG_DIR
#   ~/.devide/agent-auth/<workspace-key>/codex  -> CODEX_HOME
#
# Missing directory means "use global provider auth".

agent_auth_profile_root() {
  printf '%s\n' "${DEVIDE_AGENT_AUTH_ROOT:-${HOME}/.devide/agent-auth}"
}

agent_auth_profile_slug() {
  local workspace="$1"
  WORKSPACE_NAME="$workspace" python3 -c '
import os, re
name = os.environ.get("WORKSPACE_NAME", "")
slug = re.sub(r"[^a-z0-9._-]+", "-", name.lower()).strip("-")
print(slug)
'
}

agent_auth_profile_env_key() {
  case "$1" in
    claude) printf '%s\n' "CLAUDE_CONFIG_DIR" ;;
    codex) printf '%s\n' "CODEX_HOME" ;;
    *) return 1 ;;
  esac
}

agent_auth_profile_dir() {
  local workspace="$1"
  local runtime="$2"
  local slug

  agent_auth_profile_env_key "$runtime" >/dev/null || return 1
  slug="$(agent_auth_profile_slug "$workspace")"
  [[ -n "$slug" ]] || return 1

  printf '%s\n' "$(agent_auth_profile_root)/${slug}/${runtime}"
}

agent_auth_profile_export() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 0
  [[ -d "$dir" ]] || return 0
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  printf 'export %s=%q\n' "$key" "$dir"
}

agent_auth_profile_pair() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 0
  [[ -d "$dir" ]] || return 0
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  printf '%s\t%s\n' "$key" "$dir"
}

agent_auth_profile_status() {
  local workspace="$1"
  local runtime_filter="${2:-}"
  local root slug runtime dir key state

  root="$(agent_auth_profile_root)"
  slug="$(agent_auth_profile_slug "$workspace")"

  if [[ -z "$slug" ]]; then
    echo "error: invalid workspace: ${workspace}" >&2
    return 64
  fi

  if [[ -n "$runtime_filter" ]]; then
    agent_auth_profile_env_key "$runtime_filter" >/dev/null || return 64
  fi

  printf 'workspace: %s\n' "$slug"
  printf 'auth root: %s\n' "$root"

  for runtime in claude codex; do
    if [[ -n "$runtime_filter" && "$runtime" != "$runtime_filter" ]]; then
      continue
    fi

    dir="$(agent_auth_profile_dir "$slug" "$runtime")" || continue
    key="$(agent_auth_profile_env_key "$runtime")" || continue

    if [[ -d "$dir" ]]; then
      state="workspace profile"
      printf '%s: %s (%s=%s)\n' "$runtime" "$state" "$key" "$dir"
    else
      state="global auth"
      printf '%s: %s (no profile dir at %s)\n' "$runtime" "$state" "$dir"
    fi
  done
}

agent_auth_profile_list() {
  local root workspace workspace_dir claude_state codex_state
  root="$(agent_auth_profile_root)"

  printf 'auth root: %s\n' "$root"

  if [[ ! -d "$root" ]]; then
    printf 'no workspace auth profiles configured\n'
    return 0
  fi

  mapfile -t workspaces < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  if [[ "${#workspaces[@]}" -eq 0 ]]; then
    printf 'no workspace auth profiles configured\n'
    return 0
  fi

  printf '%-36s %-8s %-8s\n' "workspace" "claude" "codex"

  for workspace in "${workspaces[@]}"; do
    workspace_dir="${root}/${workspace}"
    claude_state="global"
    codex_state="global"

    if [[ -d "${workspace_dir}/claude" ]]; then
      claude_state="profile"
    fi

    if [[ -d "${workspace_dir}/codex" ]]; then
      codex_state="profile"
    fi

    printf '%-36s %-8s %-8s\n' "$workspace" "$claude_state" "$codex_state"
  done
}

agent_auth_profile_ensure() {
  local workspace="$1"
  local runtime="$2"
  local dir

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 1
  mkdir -p "$dir"

  local readme="${dir}/README.devide-profile"
  if [[ ! -f "$readme" ]]; then
    {
      printf 'DevIDE %s auth profile\n\n' "$runtime"
      printf 'This directory is an opt-in workspace-scoped auth home. While it exists,\n'
      printf 'DevIDE launches %s for this workspace with this directory as the\n' "$runtime"
      printf 'provider auth/config root. Delete the directory to return this workspace\n'
      printf 'to the global provider login.\n\n'
      printf 'This isolates provider auth, but it may also isolate provider-local config,\n'
      printf 'logs, sessions, and runtime state.\n'
    } >"$readme"
    chmod 600 "$readme"
  fi

  printf '%s\n' "$dir"
}

agent_auth_profile_under_root() {
  local path="$1"
  local root
  root="$(agent_auth_profile_root)"

  [[ "$path" == "${root}/"* ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  mode="--export"
  case "${1:-}" in
    --dir|--exists|--ensure|--export|--pairs|--status|--list)
      mode="$1"
      shift
      ;;
  esac

  if [[ "$mode" == "--list" ]]; then
    agent_auth_profile_list
    exit $?
  fi

  workspace="${1:-}"
  runtime="${2:-}"

  if [[ "$mode" == "--status" ]]; then
    if [[ -z "$workspace" ]]; then
      echo "usage: agent-auth-profile.sh --status <workspace> [claude|codex]" >&2
      exit 64
    fi

    agent_auth_profile_status "$workspace" "$runtime"
    exit $?
  fi

  if [[ -z "$workspace" || -z "$runtime" ]]; then
    echo "usage: agent-auth-profile.sh [--dir|--exists|--ensure|--export|--pairs] <workspace> <claude|codex>" >&2
    exit 64
  fi

  case "$mode" in
    --dir)
      agent_auth_profile_dir "$workspace" "$runtime"
      ;;
    --exists)
      dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || exit 1
      [[ -d "$dir" ]]
      ;;
    --ensure)
      agent_auth_profile_ensure "$workspace" "$runtime"
      ;;
    --pairs)
      agent_auth_profile_pair "$workspace" "$runtime"
      ;;
    --export)
      agent_auth_profile_export "$workspace" "$runtime"
      ;;
  esac
fi
