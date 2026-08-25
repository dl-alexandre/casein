#!/usr/bin/env bash
# Resolve opt-in per-person auth homes for Claude, Codex, and GitHub CLI.
#
# Shell mirror of lib/casein/identity.ex + lib/casein/agents/auth_profile.ex.
# Any rule change must land in both or a pane and the server disagree about
# who an agent is.
#
#   ~/.casein/agent-auth/profiles/<principal>/claude -> CLAUDE_CONFIG_DIR
#   ~/.casein/agent-auth/profiles/<principal>/codex  -> CODEX_HOME
#   ~/.casein/agent-auth/profiles/<principal>/gh     -> GH_CONFIG_DIR
#
# The principal is CASEIN_ACTOR when set (the viewer who launched the pane,
# stamped in by Casein), otherwise the workspace owner slug. gh joined this
# tree because nothing set GH_CONFIG_DIR before: every agent fell through to
# the host-global ~/.config/gh, which multiplexes several accounts behind one
# active `user:` key, so agents acted as whoever logged in last.
# A profile only counts as signed in once it holds provider credentials
# (.credentials.json for Claude, auth.json for Codex). A missing directory —
# or one without credentials, e.g. after an aborted sign-in — means "use
# global provider auth".
#
# Registered owners are the opt-in exception: <auth-root>/owners lists owner
# slugs (one per line, # comments) that must never fall back to the host
# global login. For a registered owner the profile dir applies even before
# sign-in, so the provider CLI prompts for its own login inside the profile
# instead of using the host account. CASEIN_AGENT_AUTH_FALLBACK=none treats
# every owner as registered.

agent_auth_profile_root() {
  printf '%s\n' "${CASEIN_AGENT_AUTH_ROOT:-${HOME}/.casein/agent-auth}"
}

agent_auth_owners_file() {
  printf '%s\n' "$(agent_auth_profile_root)/owners"
}

# Runtimes an owner is registered for, or empty when not listed. `all` means
# every runtime. Mirrors AuthProfile.registered_runtimes/1.
#
# Entry forms:
#   dalexandre            -> all
#   sconde:claude,codex   -> claude codex   (gh may still use the global login)
agent_auth_owner_runtimes() {
  local owner="$1" file entry slug rest
  file="$(agent_auth_owners_file)"
  [[ -n "$owner" && -f "$file" ]] || return 1

  while read -r entry; do
    [[ -n "$entry" ]] || continue
    slug="${entry%%:*}"
    [[ "$slug" == "$owner" ]] || continue

    if [[ "$entry" == *:* ]]; then
      rest="${entry#*:}"
      printf '%s\n' "${rest//,/ }"
    else
      printf '%s\n' "all"
    fi
    return 0
  done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file")

  return 1
}

agent_auth_owner_listed() {
  agent_auth_owner_runtimes "$1" >/dev/null 2>&1
}

# Registration is per runtime: a person may have a provider account without a
# GitHub account on this box, and failing their gh closed would break them to
# protect an identity they do not have yet. Omit the runtime to ask "registered
# for anything at all?" — reporting only, never to decide a launch.
agent_auth_owner_registered() {
  local owner="$1" runtime="${2:-}" runtimes r
  [[ -n "$owner" ]] || return 1
  if [[ "${CASEIN_AGENT_AUTH_FALLBACK:-}" == "none" ]]; then
    return 0
  fi

  runtimes="$(agent_auth_owner_runtimes "$owner")" || return 1
  [[ "$runtimes" == "all" || -z "$runtime" ]] && return 0

  for r in $runtimes; do
    [[ "$r" == "$runtime" ]] && return 0
  done

  return 1
}

# Usage: agent_auth_owner_register <owner> [runtime,runtime...]
# Omitting the runtimes registers every runtime (the historical behaviour).
agent_auth_owner_register() {
  local owner file requested="${2:-}" entry runtime tmp
  owner="$(agent_auth_profile_slug "$1")"
  if [[ -z "$owner" ]]; then
    echo "error: invalid owner: $1" >&2
    return 64
  fi

  if [[ -n "$requested" ]]; then
    for runtime in ${requested//,/ }; do
      if ! agent_auth_profile_env_key "$runtime" >/dev/null 2>&1; then
        echo "error: unknown runtime: ${runtime} (valid: ${AGENT_AUTH_RUNTIMES[*]})" >&2
        return 64
      fi
    done
    entry="${owner}:${requested}"
  else
    entry="$owner"
  fi

  file="$(agent_auth_owners_file)"
  mkdir -p "$(dirname "$file")"

  # Rewrite rather than append: re-registering with different runtimes must
  # replace the entry, or the first match would silently win forever.
  if [[ -f "$file" ]]; then
    tmp="$(mktemp "${file}.XXXXXX")"
    grep -Ev "^[[:space:]]*${owner}([[:space:]]*:|[[:space:]]*$)" "$file" >"$tmp" || true
    chmod 600 "$tmp"
    mv "$tmp" "$file"
  fi

  printf '%s\n' "$entry" >>"$file"
  chmod 600 "$file"

  for runtime in "${AGENT_AUTH_RUNTIMES[@]}"; do
    agent_auth_profile_ensure_named "$owner" "$runtime" >/dev/null
  done

  printf 'registered %s for: %s\n' "$owner" "${requested:-all runtimes}"
  printf 'agents acting as %s no longer fall back to global auth for those runtimes\n' "$owner"
  printf 'next: casein agent auth signin %s claude   (and: codex, gh)\n' "$owner"
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
  grep -Ev "^[[:space:]]*${owner}([[:space:]]*:|[[:space:]]*$)" "$file" >"$tmp" || true
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

# Keep in sync with AuthProfile's @runtimes.
AGENT_AUTH_RUNTIMES=(claude codex gh)

agent_auth_profile_env_key() {
  case "$1" in
    claude) printf '%s\n' "CLAUDE_CONFIG_DIR" ;;
    codex) printf '%s\n' "CODEX_HOME" ;;
    gh) printf '%s\n' "GH_CONFIG_DIR" ;;
    *) return 1 ;;
  esac
}

# Owner slug parsed from a workspace name. Heuristic and last-resort — see
# AuthProfile.owner_key/1. A bare workspace UUID yields nothing rather than its
# first hex group.
agent_auth_profile_owner_slug() {
  local workspace="$1"
  local slug
  slug="$(agent_auth_profile_slug "$workspace")"
  [[ -n "$slug" ]] || return 1
  if [[ "$slug" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    return 1
  fi
  printf '%s\n' "${slug%%-*}"
}

# The acting principal: CASEIN_ACTOR (the viewer Casein stamped into the pane
# environment) first, workspace owner only as fallback. Mirrors the resolution
# order in Casein.Identity.
agent_auth_principal() {
  local workspace="${1:-${CASEIN_WORKSPACE_NAME:-}}"
  local actor

  if [[ -n "${CASEIN_ACTOR:-}" ]]; then
    actor="$(agent_auth_profile_slug "$CASEIN_ACTOR")"
    if [[ -n "$actor" ]]; then
      printf '%s\n' "$actor"
      return 0
    fi
  fi

  agent_auth_profile_owner_slug "$workspace"
}

agent_auth_profile_dir() {
  local workspace="$1"
  local runtime="$2"
  local principal

  agent_auth_profile_env_key "$runtime" >/dev/null || return 1
  principal="$(agent_auth_principal "$workspace")" || return 1

  printf '%s\n' "$(agent_auth_profile_root)/profiles/${principal}/${runtime}"
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
  local readme="${dir}/README.casein-profile"

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
  owner="$(agent_auth_principal "$workspace")" || return 1
  if agent_auth_owner_registered "$owner" "$runtime"; then
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
  owner="$(agent_auth_principal "$workspace")" || return 1
  if agent_auth_profile_signed_in "$dir" "$runtime"; then
    printf '%s\n' "profile:${owner}"
    return 0
  fi

  if agent_auth_owner_registered "$owner" "$runtime"; then
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
    # gh writes hosts.yml only once `gh auth login` completes.
    gh) printf '%s\n' "${dir}/hosts.yml" ;;
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

  for runtime in "${AGENT_AUTH_RUNTIMES[@]}"; do
    if [[ -n "$runtime_filter" && "$runtime" != "$runtime_filter" ]]; then
      continue
    fi

    key="$(agent_auth_profile_env_key "$runtime")" || continue
    owner="$(agent_auth_principal "$slug")" || continue
    dir="$(agent_auth_profile_dir "$slug" "$runtime")" || continue
    state="$(agent_auth_profile_state "$dir" "$runtime")"
    credential="$(agent_auth_profile_credential_file "$dir" "$runtime")"

    case "$state" in
      signed-in)
        printf '%s: owner %s profile signed in (%s=%s)\n' "$runtime" "$owner" "$key" "$dir"
        ;;
      sign-in-required | missing)
        if agent_auth_owner_registered "$owner" "$runtime"; then
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
  local root profile profile_dir registered_state runtime
  root="$(agent_auth_profile_root)"

  printf 'auth root: %s\n' "$root"

  printf 'principal profiles:\n'

  if [[ ! -d "${root}/profiles" ]]; then
    printf '  none\n'
    return 0
  fi

  mapfile -t profiles < <(find "${root}/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    printf '  none\n'
    return 0
  fi

  printf '%-24s %-12s %-18s %-18s %-18s\n' "principal" "registered" "claude" "codex" "gh"

  local -a states
  for profile in "${profiles[@]}"; do
    profile_dir="${root}/profiles/${profile}"
    states=()
    for runtime in "${AGENT_AUTH_RUNTIMES[@]}"; do
      states+=("$(agent_auth_profile_state "${profile_dir}/${runtime}" "$runtime")")
    done

    registered_state="no"
    if agent_auth_owner_listed "$profile"; then
      registered_state="$(agent_auth_owner_runtimes "$profile")"
      registered_state="${registered_state// /,}"
    fi

    printf '%-24s %-12s %-18s %-18s %-18s\n' \
      "$profile" "$registered_state" "${states[0]}" "${states[1]}" "${states[2]}"
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
        echo "usage: agent-auth-profile.sh ${mode} <owner> [runtime,runtime...]" >&2
        exit 64
      fi
      case "$mode" in
        --register) agent_auth_owner_register "$owner" "${2:-}" ;;
        --unregister) agent_auth_owner_unregister "$owner" ;;
        --registered)
          agent_auth_owner_registered "$(agent_auth_profile_slug "$owner")" "${2:-}"
          ;;
      esac
      exit $?
      ;;
  esac

  workspace="${1:-}"
  runtime="${2:-}"

  if [[ "$mode" == "--status" ]]; then
    if [[ -z "$workspace" ]]; then
      echo "usage: agent-auth-profile.sh --status <workspace> [claude|codex|gh]" >&2
      exit 64
    fi

    agent_auth_profile_status "$workspace" "$runtime"
    exit $?
  fi

  if [[ -z "$workspace" || -z "$runtime" ]]; then
    echo "usage: agent-auth-profile.sh [--dir|--active-dir|--exists|--export|--pairs] <workspace> <claude|codex|gh>" >&2
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
