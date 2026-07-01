#!/usr/bin/env bash
# Resolve required owner auth homes for Claude and Codex.
#
# Matching <owner>-* workspaces always use owner-scoped provider homes:
#   ~/.devide/agent-auth/profiles/<owner-key>/claude -> CLAUDE_CONFIG_DIR
#   ~/.devide/agent-auth/profiles/<owner-key>/codex  -> CODEX_HOME
# Missing directories are created by env materialization and then require
# provider sign-in inside that isolated home.

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

agent_auth_profile_seed_readme() {
  local dir="$1"
  local runtime="$2"
  local readme="${dir}/README.devide-profile"

  if [[ ! -f "$readme" ]]; then
    {
      printf 'DevIDE %s owner auth profile\n\n' "$runtime"
      printf 'This directory is a DevIDE owner auth home. Matching workspaces\n'
      printf 'launch %s with this directory as the provider auth/config root.\n' "$runtime"
      printf 'If the directory is deleted, DevIDE recreates an empty isolated\n'
      printf 'home and %s requires sign-in again.\n\n' "$runtime"
      printf 'This isolates provider auth from the host global login, but every\n'
      printf 'workspace using this profile shares provider-local config, logs,\n'
      printf 'sessions, and runtime state.\n'
    } >"$readme"
    chmod 600 "$readme"
  fi
}

agent_auth_profile_ensure_dir() {
  local workspace="$1"
  local runtime="$2"
  local dir

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 1
  mkdir -p "$dir"
  agent_auth_profile_seed_readme "$dir" "$runtime"
  printf '%s\n' "$dir"
}

agent_auth_profile_active_dir() {
  local workspace="$1"
  local runtime="$2"
  agent_auth_profile_dir "$workspace" "$runtime"
}

agent_auth_profile_active_source() {
  local workspace="$1"
  local runtime="$2"
  local owner

  agent_auth_profile_dir "$workspace" "$runtime" >/dev/null || return 1
  owner="$(agent_auth_profile_owner_slug "$workspace")" || return 1
  printf '%s\n' "profile:${owner}"
}

agent_auth_profile_export() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_ensure_dir "$workspace" "$runtime")" || return 0
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  printf 'export %s=%q\n' "$key" "$dir"
}

agent_auth_profile_pair() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_ensure_dir "$workspace" "$runtime")" || return 0
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  printf '%s\t%s\n' "$key" "$dir"
}

agent_auth_profile_credential_file() {
  local dir="$1"
  local runtime="$2"

  case "$runtime" in
    claude) printf '%s\n' "${dir}/.credentials.json" ;;
    codex) printf '%s\n' "${dir}/auth.json" ;;
    *) return 1 ;;
  esac
}

agent_auth_profile_signed_in() {
  local dir="$1"
  local runtime="$2"
  local credential

  credential="$(agent_auth_profile_credential_file "$dir" "$runtime")" || return 1
  [[ -f "$credential" ]]
}

agent_auth_profile_state() {
  local dir="$1"
  local runtime="$2"

  if agent_auth_profile_signed_in "$dir" "$runtime"; then
    printf '%s\n' "signed-in"
  elif [[ -d "$dir" ]]; then
    printf '%s\n' "sign-in-required"
  else
    printf '%s\n' "missing"
  fi
}

agent_auth_profile_status() {
  local workspace="$1"
  local runtime_filter="${2:-}"
  local root slug runtime dir key state owner credential

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
    owner="$(agent_auth_profile_owner_slug "$slug")" || continue
    dir="$(agent_auth_profile_dir "$slug" "$runtime")" || continue
    state="$(agent_auth_profile_state "$dir" "$runtime")"
    credential="$(agent_auth_profile_credential_file "$dir" "$runtime")"

    case "$state" in
      signed-in)
        printf '%s: owner %s profile signed in (%s=%s)\n' "$runtime" "$owner" "$key" "$dir"
        ;;
      sign-in-required)
        printf '%s: owner %s profile active, sign-in required (%s=%s; missing %s)\n' \
          "$runtime" "$owner" "$key" "$dir" "$credential"
        ;;
      *)
        printf '%s: owner %s profile not created yet, sign-in required (%s=%s)\n' \
          "$runtime" "$owner" "$key" "$dir"
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

  printf '%-36s %-16s %-16s\n' "owner" "claude" "codex"

  for profile in "${profiles[@]}"; do
    profile_dir="${root}/profiles/${profile}"
    claude_state="$(agent_auth_profile_state "${profile_dir}/claude" claude)"
    codex_state="$(agent_auth_profile_state "${profile_dir}/codex" codex)"

    printf '%-36s %-16s %-16s\n' "$profile" "$claude_state" "$codex_state"
  done
}

agent_auth_profile_ensure_named() {
  local profile="$1"
  local runtime="$2"
  local dir

  dir="$(agent_auth_profile_named_dir "$profile" "$runtime")" || return 1
  mkdir -p "$dir"
  agent_auth_profile_seed_readme "$dir" "$runtime"

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
      dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || exit 1
      [[ -d "$dir" ]]
      ;;
    --pairs)
      agent_auth_profile_pair "$workspace" "$runtime"
      ;;
    --export)
      agent_auth_profile_export "$workspace" "$runtime"
      ;;
  esac
fi
