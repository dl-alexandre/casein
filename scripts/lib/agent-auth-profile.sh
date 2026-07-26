#!/usr/bin/env bash
# Resolve opt-in owner auth homes for Claude and Codex.
#
# Matching <owner>-* workspaces use owner-scoped provider homes once signed in:
#   ~/.casein/agent-auth/profiles/<owner-key>/claude -> CLAUDE_CONFIG_DIR
#   ~/.casein/agent-auth/profiles/<owner-key>/codex  -> CODEX_HOME
# A profile only counts as signed in once it holds provider credentials
# (.credentials.json for Claude, auth.json for Codex). A missing directory —
# or one without credentials, e.g. after an aborted sign-in — means "use
# global provider auth".
#
# Registered owners are the opt-in exception: <auth-root>/owners lists owner
# slugs (one per line, # comments) that must never fall back to the host
# global login. For a registered owner the profile dir applies even before
# sign-in, so the provider CLI prompts for its own login inside the profile
# instead of using the host account. DEVIDE_AGENT_AUTH_FALLBACK=none treats
# every owner as registered.

agent_auth_profile_root() {
  printf '%s\n' "${DEVIDE_AGENT_AUTH_ROOT:-${HOME}/.casein/agent-auth}"
}

agent_auth_owners_file() {
  printf '%s\n' "$(agent_auth_profile_root)/owners"
}

agent_auth_owner_listed() {
  local owner="$1"
  local file
  file="$(agent_auth_owners_file)"
  [[ -n "$owner" && -f "$file" ]] || return 1
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file" | grep -Fxq "$owner"
}

agent_auth_owner_registered() {
  local owner="$1"
  [[ -n "$owner" ]] || return 1
  if [[ "${DEVIDE_AGENT_AUTH_FALLBACK:-}" == "none" ]]; then
    return 0
  fi
  agent_auth_owner_listed "$owner"
}

agent_auth_owner_register() {
  local owner file
  owner="$(agent_auth_profile_slug "$1")"
  if [[ -z "$owner" ]]; then
    echo "error: invalid owner: $1" >&2
    return 64
  fi

  file="$(agent_auth_owners_file)"
  mkdir -p "$(dirname "$file")"
  if ! agent_auth_owner_listed "$owner"; then
    printf '%s\n' "$owner" >>"$file"
    chmod 600 "$file"
  fi

  local runtime
  for runtime in claude codex; do
    agent_auth_profile_ensure_named "$owner" "$runtime" >/dev/null
  done

  printf 'registered owner %s: %s-* workspaces no longer fall back to global auth\n' \
    "$owner" "$owner"
  printf 'next: devide agent auth signin %s claude   (and: codex)\n' "$owner"
}

agent_auth_owner_unregister() {
  local owner file tmp
  owner="$(agent_auth_profile_slug "$1")"
  if [[ -z "$owner" ]]; then
    echo "error: invalid owner: $1" >&2
    return 64
  fi

  file="$(agent_auth_owners_file)"
  if ! agent_auth_owner_listed "$owner"; then
    printf 'owner %s is not registered\n' "$owner"
    return 0
  fi

  tmp="$(mktemp "${file}.XXXXXX")"
  grep -Fxv "$owner" "$file" >"$tmp" || true
  chmod 600 "$tmp"
  mv "$tmp" "$file"
  printf 'unregistered owner %s: workspaces fall back to global auth when the profile is not signed in\n' "$owner"
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
      printf 'Casein %s owner auth profile\n\n' "$runtime"
      printf 'This directory is a Casein owner auth home. Matching workspaces\n'
      printf 'launch %s with this directory as the provider auth/config root.\n' "$runtime"
      printf 'If the directory is deleted, Casein recreates an empty isolated\n'
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
  local dir owner

  dir="$(agent_auth_profile_dir "$workspace" "$runtime")" || return 1
  if agent_auth_profile_signed_in "$dir" "$runtime"; then
    printf '%s\n' "$dir"
    return 0
  fi

  # Registered owners fail closed: hand back the (possibly empty) profile dir
  # so the provider CLI runs its own sign-in there instead of using global auth.
  owner="$(agent_auth_profile_owner_slug "$workspace")" || return 1
  if agent_auth_owner_registered "$owner"; then
    agent_auth_profile_ensure_named "$owner" "$runtime" >/dev/null || return 1
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
  owner="$(agent_auth_profile_owner_slug "$workspace")" || return 1
  if agent_auth_profile_signed_in "$dir" "$runtime"; then
    printf '%s\n' "profile:${owner}"
    return 0
  fi

  if agent_auth_owner_registered "$owner"; then
    printf '%s\n' "pending:${owner}"
    return 0
  fi

  printf '%s\n' "global"
}

agent_auth_profile_export() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_active_dir "$workspace" "$runtime")" || return 0
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  printf 'export %s=%q\n' "$key" "$dir"
}

agent_auth_profile_pair() {
  local workspace="$1"
  local runtime="$2"
  local dir key

  dir="$(agent_auth_profile_active_dir "$workspace" "$runtime")" || return 0
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
      sign-in-required | missing)
        if agent_auth_owner_registered "$owner"; then
          printf '%s: registered owner %s — sign-in required, global fallback disabled (%s=%s)\n' \
            "$runtime" "$owner" "$key" "$dir"
        elif [[ "$state" == "sign-in-required" ]]; then
          printf '%s: global auth — owner %s profile exists but is not signed in (missing %s)\n' \
            "$runtime" "$owner" "$credential"
        else
          printf '%s: global auth — no owner %s profile (sign in to create %s)\n' \
            "$runtime" "$owner" "$dir"
        fi
        ;;
    esac
  done
}

agent_auth_profile_list() {
  local root profile profile_dir claude_state codex_state registered_state
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

  printf '%-36s %-12s %-16s %-16s\n' "owner" "registered" "claude" "codex"

  for profile in "${profiles[@]}"; do
    profile_dir="${root}/profiles/${profile}"
    claude_state="$(agent_auth_profile_state "${profile_dir}/claude" claude)"
    codex_state="$(agent_auth_profile_state "${profile_dir}/codex" codex)"

    registered_state="no"
    if agent_auth_owner_listed "$profile"; then
      registered_state="yes"
    fi

    printf '%-36s %-12s %-16s %-16s\n' "$profile" "$registered_state" "$claude_state" "$codex_state"
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
    --dir|--active-dir|--exists|--export|--pairs|--status|--list|--register|--unregister|--registered)
      mode="$1"
      shift
      ;;
  esac

  if [[ "$mode" == "--list" ]]; then
    agent_auth_profile_list
    exit $?
  fi

  case "$mode" in
    --register|--unregister|--registered)
      owner="${1:-}"
      if [[ -z "$owner" ]]; then
        echo "usage: agent-auth-profile.sh ${mode} <owner>" >&2
        exit 64
      fi
      case "$mode" in
        --register) agent_auth_owner_register "$owner" ;;
        --unregister) agent_auth_owner_unregister "$owner" ;;
        --registered) agent_auth_owner_registered "$(agent_auth_profile_slug "$owner")" ;;
      esac
      exit $?
      ;;
  esac

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
