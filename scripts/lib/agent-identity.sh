#!/usr/bin/env bash
# Announce and export the identity an agent pane acts as.
#
# Sourced by launch-casein-agent.sh. Split out of it so the rules are testable
# without running the launcher's side effects — these two functions decide
# which GitHub account a pane pushes as and whose name lands on its commits.
#
# Requires agent-auth-profile.sh to be sourced first.

# Say who this agent is acting as. Identity used to be invisible from inside a
# pane — the only way to find out which GitHub account you were about to push
# as was to run `gh auth status` and be surprised.
announce_agent_identity() {
  local principal runtime key dir
  principal="$(agent_auth_principal "${CASEIN_WORKSPACE_NAME:-}" 2>/dev/null || true)"

  if [[ -z "$principal" ]]; then
    echo "casein: agent identity unresolved — every runtime uses its host global login" >&2
    return 0
  fi

  export CASEIN_ACTOR="$principal"

  local -a resolved=()
  for runtime in "${AGENT_AUTH_RUNTIMES[@]}"; do
    key="$(agent_auth_profile_env_key "$runtime")" || continue
    dir="${!key:-}"
    if [[ -z "$dir" ]]; then
      resolved+=("${runtime}=global")
    elif agent_auth_profile_signed_in "$dir" "$runtime"; then
      resolved+=("${runtime}=${principal}")
    else
      resolved+=("${runtime}=${principal}(sign-in required)")
    fi
  done

  export_git_identity "$principal"
  echo "casein: acting as ${principal} — ${resolved[*]}" >&2
}

# Commit authorship for the principal, as environment rather than repo config.
#
# A worktree is shared between panes and between people, so `git config
# user.email` in a checkout attributes whoever commits there next. GIT_AUTHOR_*
# / GIT_COMMITTER_* are per-process and outrank config, so each pane commits as
# its own principal without touching the shared checkout. Before this, the same
# person committed as "MILC Devbox", "DevIDE Agent", or themselves depending on
# which checkout the pane happened to be in.
#
# An identity the operator set explicitly is left alone.
export_git_identity() {
  local principal="$1" domain

  [[ -n "$principal" ]] || return 0
  [[ -z "${GIT_AUTHOR_EMAIL:-}" && -z "${GIT_COMMITTER_EMAIL:-}" ]] || return 0

  # CASEIN_ACTOR_EMAIL is stamped in by Casein.Identity so shell and server
  # never derive a principal's address from separate copies of the domain rule.
  local email="${CASEIN_ACTOR_EMAIL:-}"
  if [[ -z "$email" ]]; then
    domain="${CASEIN_FORWARD_AUTH_EMAIL_DOMAIN:-${CASEIN_GIT_EMAIL_DOMAIN:-}}"
    [[ -n "$domain" ]] || return 0
    email="${principal}@${domain}"
  fi

  export GIT_AUTHOR_NAME="$principal"
  export GIT_AUTHOR_EMAIL="$email"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
}
