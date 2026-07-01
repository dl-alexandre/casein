#!/usr/bin/env bash
# Resolve opt-in workspace-scoped and shared auth homes for Claude and Codex.
#
# Directory presence enables a profile:
#   ~/.devide/agent-auth/workspaces/<workspace-key>/claude -> CLAUDE_CONFIG_DIR
#   ~/.devide/agent-auth/workspaces/<workspace-key>/codex  -> CODEX_HOME
#   ~/.devide/agent-auth/profiles/<profile-key>/claude     -> CLAUDE_CONFIG_DIR
#   ~/.devide/agent-auth/profiles/<profile-key>/codex      -> CODEX_HOME
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
  local slug

  agent_auth_profile_env_key "$runtime" >/dev/null || return 1
  slug="$(agent_auth_profile_slug "$workspace")"
  [[ -n "$slug" ]] || return 1

  printf '%s\n' "$(agent_auth_profile_root)/workspaces/${slug}/${runtime}"
}

agent_auth_profile_legacy_dir() {
  local workspace="$1"
  local runtime="$2"
  local slug

  agent_auth_profile_env_key "$runtime" >/dev/null || return 1
  slug="$(agent_auth_profile_slug "$workspace")"
  [[ -n "$slug" ]] || return 1

  printf '%s\n' "$(agent_auth_profile_root)/${slug}/${runtime}"
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

agent_auth_profile_name_for_dir() {
  local path="$1"
  local root profiles_root resolved rest

  root="$(agent_auth_profile_root)"
  profiles_root="$(readlink -f "${root}/profiles" 2>/dev/null || true)"
  resolved="$(readlink -f "$path" 2>/dev/null || true)"

  [[ -n "$profiles_root" && -n "$resolved" ]] || return 1
  [[ "$resolved" == "${profiles_root}/"* ]] || return 1

  rest="${resolved#${profiles_root}/}"
  printf '%s\n' "${rest%%/*}"
}

agent_auth_profile_owner_dir() {
  local workspace="$1"
  local runtime="$2"
  local owner

  owner="$(agent_auth_profile_owner_slug "$workspace")" || return 1
  agent_auth_profile_named_dir "$owner" "$runtime"
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

  dir="$(agent_auth_profile_owner_dir "$workspace" "$runtime")" || return 1
  if [[ -d "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi

  dir="$(agent_auth_profile_legacy_dir "$workspace" "$runtime")" || return 1
  if [[ -d "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi

  return 1
}

agent_auth_profile_active_source() {
  local workspace="$1"
  local runtime="$2"
  local dir owner profile

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 1
  if [[ -d "$dir" ]]; then
    profile="$(agent_auth_profile_name_for_dir "$dir" 2>/dev/null || true)"
    if [[ -n "$profile" ]]; then
      printf '%s\n' "profile:${profile}"
      return 0
    fi

    printf '%s\n' "workspace"
    return 0
  fi

  owner="$(agent_auth_profile_owner_slug "$workspace")" || return 1
  dir="$(agent_auth_profile_named_dir "$owner" "$runtime")" || return 1
  if [[ -d "$dir" ]]; then
    printf '%s\n' "profile:${owner}"
    return 0
  fi

  dir="$(agent_auth_profile_legacy_dir "$workspace" "$runtime")" || return 1
  if [[ -d "$dir" ]]; then
    printf '%s\n' "legacy"
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
      workspace)
        dir="$(agent_auth_profile_active_dir "$slug" "$runtime")" || continue
        state="workspace profile"
        printf '%s: %s (%s=%s)\n' "$runtime" "$state" "$key" "$dir"
        ;;
      profile:*)
        dir="$(agent_auth_profile_active_dir "$slug" "$runtime")" || continue
        state="shared ${source#profile:} profile"
        printf '%s: %s (%s=%s)\n' "$runtime" "$state" "$key" "$dir"
        ;;
      legacy)
        dir="$(agent_auth_profile_active_dir "$slug" "$runtime")" || continue
        state="legacy workspace profile"
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
  local root workspace runtime workspace_dir source state profile profile_dir claude_state codex_state
  root="$(agent_auth_profile_root)"

  printf 'auth root: %s\n' "$root"

  printf 'workspace profiles:\n'

  if [[ -d "$root" ]]; then
    mapfile -t workspaces < <(
      {
        find "${root}/workspaces" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
        find "$root" -mindepth 1 -maxdepth 1 -type d ! -name workspaces ! -name profiles -printf '%f\n' 2>/dev/null || true
      } | sort -u
    )
  else
    workspaces=()
  fi

  if [[ "${#workspaces[@]}" -eq 0 ]]; then
    printf '  none\n'
  else
    printf '%-36s %-14s %-14s\n' "workspace" "claude" "codex"

    for workspace in "${workspaces[@]}"; do
      claude_state="global"
      codex_state="global"

      for runtime in claude codex; do
        source="$(agent_auth_profile_active_source "$workspace" "$runtime")" || source="global"
        case "$source" in
          workspace) state="workspace" ;;
          profile:*) state="${source#profile:}" ;;
          legacy) state="legacy" ;;
          *) state="global" ;;
        esac

        case "$runtime" in
          claude) claude_state="$state" ;;
          codex) codex_state="$state" ;;
        esac
      done

      printf '%-36s %-14s %-14s\n' "$workspace" "$claude_state" "$codex_state"
    done
  fi

  printf '\nshared profiles:\n'

  if [[ ! -d "${root}/profiles" ]]; then
    printf '  none\n'
    return 0
  fi

  mapfile -t profiles < <(find "${root}/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    printf '  none\n'
    return 0
  fi

  printf '%-36s %-8s %-8s\n' "profile" "claude" "codex"

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

agent_auth_profile_ensure_named() {
  local profile="$1"
  local runtime="$2"
  local dir

  dir="$(agent_auth_profile_named_dir "$profile" "$runtime")" || return 1
  mkdir -p "$dir"

  local readme="${dir}/README.devide-profile"
  if [[ ! -f "$readme" ]]; then
    {
      printf 'DevIDE %s shared auth profile\n\n' "$runtime"
      printf 'This directory is an opt-in shared auth home. Workspaces can point\n'
      printf 'at it with devide agent auth use-profile, and workspaces whose owner\n'
      printf 'prefix matches this profile use it automatically when no workspace\n'
      printf 'override exists.\n\n'
      printf 'This isolates provider auth from the host global login, but every\n'
      printf 'workspace using this profile shares provider-local config, logs,\n'
      printf 'sessions, and runtime state.\n'
    } >"$readme"
    chmod 600 "$readme"
  fi

  printf '%s\n' "$dir"
}

agent_auth_profile_use_named() {
  local workspace="$1"
  local profile="$2"
  local runtime="$3"
  local target link parent backup

  target="$(agent_auth_profile_ensure_named "$profile" "$runtime")" || return 1
  link="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 1
  parent="$(dirname "$link")"
  mkdir -p "$parent"

  if [[ -e "$link" || -L "$link" ]]; then
    if [[ -L "$link" ]]; then
      rm -f "$link"
    elif [[ "$(cd "$link" 2>/dev/null && pwd -P)" == "$(cd "$target" 2>/dev/null && pwd -P)" ]]; then
      printf '%s\n' "$link"
      return 0
    else
      backup="${link}.backup-$(date -u +%Y%m%d%H%M%S)-$$"
      mv "$link" "$backup"
      echo "moved existing workspace profile to ${backup}" >&2
    fi
  fi

  ln -s "$target" "$link"
  printf '%s\n' "$link"
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
    --dir|--active-dir|--exists|--ensure|--ensure-named|--use-named|--export|--pairs|--status|--list)
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

  if [[ "$mode" == "--use-named" ]]; then
    profile="${2:-}"
    runtime="${3:-}"

    if [[ -z "$workspace" || -z "$profile" || -z "$runtime" ]]; then
      echo "usage: agent-auth-profile.sh --use-named <workspace> <profile> <claude|codex>" >&2
      exit 64
    fi

    agent_auth_profile_use_named "$workspace" "$profile" "$runtime"
    exit $?
  fi

  if [[ "$mode" == "--status" ]]; then
    if [[ -z "$workspace" ]]; then
      echo "usage: agent-auth-profile.sh --status <workspace> [claude|codex]" >&2
      exit 64
    fi

    agent_auth_profile_status "$workspace" "$runtime"
    exit $?
  fi

  if [[ "$mode" == "--ensure-named" ]]; then
    if [[ -z "$workspace" || -z "$runtime" ]]; then
      echo "usage: agent-auth-profile.sh --ensure-named <profile> <claude|codex>" >&2
      exit 64
    fi

    agent_auth_profile_ensure_named "$workspace" "$runtime"
    exit $?
  fi

  if [[ -z "$workspace" || -z "$runtime" ]]; then
    echo "usage: agent-auth-profile.sh [--dir|--active-dir|--exists|--ensure|--export|--pairs] <workspace> <claude|codex>" >&2
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
