#!/usr/bin/env bash
# Resolve opt-in owner auth homes for Claude and Codex.
#
# Directory presence enables a profile for matching <owner>-* workspaces:
#   ~/.devide/agent-auth/profiles/<owner-key>/claude -> CLAUDE_CONFIG_DIR
#   ~/.devide/agent-auth/profiles/<owner-key>/codex  -> CODEX_HOME
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

agent_auth_profile_owner_slug() {
  local workspace="$1"
  local slug
  slug="$(agent_auth_profile_slug "$workspace")"
  [[ -n "$slug" ]] || return 1
  printf '%s\n' "${slug%%-*}"
}

agent_auth_profile_dir() {
  local workspace="$1"
  local runtime="$2"
  local owner

  agent_auth_profile_env_key "$runtime" >/dev/null || return 1
  owner="$(agent_auth_profile_owner_slug "$workspace")" || return 1

  printf '%s\n' "$(agent_auth_profile_root)/profiles/${owner}/${runtime}"
}

agent_auth_profile_named_dir() {
  local profile="$1"
  local runtime="$2"
  local slug

  agent_auth_profile_env_key "$runtime" >/dev/null || return 1
  slug="$(agent_auth_profile_slug "$profile")"
  [[ -n "$slug" ]] || return 1

  printf '%s\n' "$(agent_auth_profile_root)/profiles/${slug}/${runtime}"
}

agent_auth_profile_active_dir() {
  local workspace="$1"
  local runtime="$2"
  local dir

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 1
  if [[ -d "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi

  return 1
}

agent_auth_profile_active_source() {
  local workspace="$1"
  local runtime="$2"
  local dir owner

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 1
  if [[ -d "$dir" ]]; then
    owner="$(agent_auth_profile_owner_slug "$workspace")" || return 1
    printf '%s\n' "profile:${owner}"
    return 0
  fi

  printf '%s\n' "global"
}

agent_auth_profile_export() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_active_dir "$workspace" "$runtime")" || return 0
  [[ -d "$dir" ]] || return 0
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  printf 'export %s=%q\n' "$key" "$dir"
}

agent_auth_profile_pair() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_active_dir "$workspace" "$runtime")" || return 0
  [[ -d "$dir" ]] || return 0
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  printf '%s\t%s\n' "$key" "$dir"
}

agent_auth_profile_status() {
  local workspace="$1"
  local runtime_filter="${2:-}"
  local root slug runtime dir key state source

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

    key="$(agent_auth_profile_env_key "$runtime")" || continue
    source="$(agent_auth_profile_active_source "$slug" "$runtime")" || source="global"

    case "$source" in
      profile:*)
        dir="$(agent_auth_profile_active_dir "$slug" "$runtime")" || continue
        state="owner ${source#profile:} profile"
        printf '%s: %s (%s=%s)\n' "$runtime" "$state" "$key" "$dir"
        ;;
      *)
        dir="$(agent_auth_profile_dir "$slug" "$runtime")" || continue
        state="global auth"
        printf '%s: %s (no profile dir at %s)\n' "$runtime" "$state" "$dir"
        ;;
    esac
  done
}

agent_auth_profile_list() {
  local root profile profile_dir claude_state codex_state
  root="$(agent_auth_profile_root)"

  printf 'auth root: %s\n' "$root"

  printf 'owner profiles:\n'

  if [[ ! -d "${root}/profiles" ]]; then
    printf '  none\n'
    return 0
  fi

  mapfile -t profiles < <(find "${root}/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    printf '  none\n'
    return 0
  fi

  printf '%-36s %-8s %-8s\n' "owner" "claude" "codex"

  for profile in "${profiles[@]}"; do
    profile_dir="${root}/profiles/${profile}"
    claude_state="missing"
    codex_state="missing"

    if [[ -d "${profile_dir}/claude" ]]; then
      claude_state="profile"
    fi

    if [[ -d "${profile_dir}/codex" ]]; then
      codex_state="profile"
    fi

    printf '%-36s %-8s %-8s\n' "$profile" "$claude_state" "$codex_state"
  done
}

agent_auth_profile_ensure_named() {
  local profile="$1"
  local runtime="$2"
  local dir

  dir="$(agent_auth_profile_named_dir "$profile" "$runtime")" || return 1
  mkdir -p "$dir"

  local readme="${dir}/README.devide-profile"
  if [[ ! -f "$readme" ]]; then
    {
      printf 'DevIDE %s owner auth profile\n\n' "$runtime"
      printf 'This directory is an opt-in owner auth home. Workspaces whose owner\n'
      printf 'prefix matches this profile use it automatically after sign-in with\n'
      printf 'devide agent auth signin <owner> %s.\n\n' "$runtime"
      printf 'This isolates provider auth from the host global login, but every\n'
      printf 'workspace using this profile shares provider-local config, logs,\n'
      printf 'sessions, and runtime state.\n'
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
    --dir|--active-dir|--exists|--export|--pairs|--status|--list)
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
    echo "usage: agent-auth-profile.sh [--dir|--active-dir|--exists|--export|--pairs] <workspace> <claude|codex>" >&2
    exit 64
  fi

  case "$mode" in
    --dir)
      agent_auth_profile_dir "$workspace" "$runtime"
      ;;
    --active-dir)
      agent_auth_profile_active_dir "$workspace" "$runtime"
      ;;
    --exists)
      agent_auth_profile_active_dir "$workspace" "$runtime" >/dev/null
      ;;
    --pairs)
      agent_auth_profile_pair "$workspace" "$runtime"
      ;;
    --export)
      agent_auth_profile_export "$workspace" "$runtime"
      ;;
  esac
fi
