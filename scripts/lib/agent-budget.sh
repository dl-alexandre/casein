#!/usr/bin/env bash
#
# agent-budget.sh — live agent-count gate for agent launch.
#
# spawn-host-headroom.sh refuses a launch when the host is *already* thrashing
# (load, MemAvailable). This gate refuses one step earlier: when enough agent
# processes are already resident that the next one is what tips the box over.
# On 2026-08-27 the devbox reached ~66 resident opencode/claude processes with
# nothing counting them and ran out of memory. casein-agents.slice now bounds
# their memory; this bounds their number, so each agent keeps a usable share.
#
# Source from a launcher:
#   # shellcheck source=lib/agent-budget.sh
#   source "${ROOT}/scripts/lib/agent-budget.sh"
#   agent_budget_check "$RUNTIME" || exit $?
#
# Env:
#   CASEIN_AGENT_MAX_TOTAL       refuse when this many agents run host-wide (default 32; 0 = off)
#   CASEIN_AGENT_MAX_PER_USER    refuse when this user already runs this many (default 0 = off —
#                                on the devbox every agent runs as the shared `devbox` user)
#   CASEIN_AGENT_BUDGET_FORCE=1  operator override — launch anyway (loud warn)
#   CASEIN_AGENT_BUDGET_PS_PATH  file of "user args" lines standing in for `ps` (tests)
#   CASEIN_AGENT_BUDGET_USER     override the calling user name (tests)
#
# Exit codes from agent_budget_check:
#   0  under budget (or FORCE override)
#   75 budget exhausted (EX_TEMPFAIL — same as the headroom gate)
#   2  misconfiguration (non-integer limit / unreadable probe)
#
# Stdout tokens — one line, so callers branch without parsing prose:
#   refused:budget           exit 75 — gate closed, nothing launched
#   proceed:budget-force     exit 0  — over budget, FORCE override
# Absence of either token + exit 0 means the budget was fine (no override).
#
# What counts as an agent (keep in sync with Casein.Terminals.HostCapacity):
# argv[0] basename in {opencode, claude, claude.exe, claude_exe, grok, codex},
# or a node/bun process whose script is codex(.js) — Codex ships as a JS entry
# point, so its comm is "node".

# shellcheck disable=SC2034  # exported for callers/tests that inspect the last probe
AGENT_BUDGET_LAST=""

# Prints "user args" lines for every process. Overridable for tests.
agent_budget_ps() {
  local path="${CASEIN_AGENT_BUDGET_PS_PATH:-}"
  if [[ -n "${path}" ]]; then
    if [[ ! -r "${path}" ]]; then
      echo "error: agent budget: cannot read process list at ${path}" >&2
      return 2
    fi
    cat "${path}"
    return 0
  fi
  ps -eo user=,args= 2>/dev/null
}

# Reads "user args" lines on stdin; prints "user" for each agent process.
agent_budget_filter_agents() {
  awk '
    function base(p,  n, a) { n = split(p, a, "/"); return a[n] }
    {
      user = $1
      cmd = base($2)
      script = (NF >= 3) ? base($3) : ""
      if (cmd ~ /^(opencode|claude|claude\.exe|claude_exe|grok|codex)$/) { print user; next }
      if ((cmd == "node" || cmd == "bun") && script ~ /^codex(\.js)?$/) { print user; next }
    }'
}

agent_budget_current_user() {
  if [[ -n "${CASEIN_AGENT_BUDGET_USER:-}" ]]; then
    printf '%s\n' "${CASEIN_AGENT_BUDGET_USER}"
    return 0
  fi
  id -un 2>/dev/null || printf '%s\n' "${USER:-unknown}"
}

agent_budget_check() {
  local runtime="${1:-agent}"
  local force="${CASEIN_AGENT_BUDGET_FORCE:-0}"
  local max_total="${CASEIN_AGENT_MAX_TOTAL:-32}"
  local max_user="${CASEIN_AGENT_MAX_PER_USER:-0}"
  local me total mine reason=""

  case "${max_total}" in
    '' | *[!0-9]*)
      echo "error: agent budget: CASEIN_AGENT_MAX_TOTAL must be an integer (got '${max_total}')" >&2
      return 2
      ;;
  esac
  case "${max_user}" in
    '' | *[!0-9]*)
      echo "error: agent budget: CASEIN_AGENT_MAX_PER_USER must be an integer (got '${max_user}')" >&2
      return 2
      ;;
  esac

  # 0 disables a limit — never "refuse everything".
  me="$(agent_budget_current_user)"
  local listing users
  # Capture the probe separately so its exit status is not masked by awk's.
  listing="$(agent_budget_ps)" || return $?
  users="$(printf '%s\n' "${listing}" | agent_budget_filter_agents)"
  total="$(printf '%s\n' "${users}" | grep -c . || true)"
  mine="$(printf '%s\n' "${users}" | grep -cx -- "${me}" || true)"

  AGENT_BUDGET_LAST="agents_total=${total} max_total=${max_total} agents_user=${mine} max_per_user=${max_user} user=${me}"

  if ((max_total > 0 && total >= max_total)); then
    reason="${total} agent processes already resident host-wide (limit ${max_total})"
  fi
  if ((max_user > 0 && mine >= max_user)); then
    if [[ -n "${reason}" ]]; then
      reason="${reason}; "
    fi
    reason="${reason}${me} already runs ${mine} agents (limit ${max_user})"
  fi

  if [[ -z "${reason}" ]]; then
    return 0
  fi

  if [[ "${force}" == "1" ]]; then
    cat >&2 <<EOF
warn: agent budget exceeded; launching ${runtime} anyway under CASEIN_AGENT_BUDGET_FORCE
      ${reason}
      probe: ${AGENT_BUDGET_LAST}
      operator accepts memory-pressure risk; this is not a silent no-op
      tune: CASEIN_AGENT_MAX_TOTAL  CASEIN_AGENT_MAX_PER_USER
EOF
    printf 'proceed:budget-force\n'
    return 0
  fi

  cat >&2 <<EOF
error: ${runtime} launch refused — agent budget exhausted
       ${reason}
       probe: ${AGENT_BUDGET_LAST}
       why: 66 resident agents took the devbox down on 2026-08-27; casein-agents.slice caps their
            memory, this caps their number so each one keeps a usable share.
       free a slot: close idle agent tabs (the janitor reaps unattached idle agents after
                    CASEIN_TMUX_AGENT_IDLE_SECONDS), or check \`ps -eo user,args | grep -E 'opencode|claude|codex|grok'\`
       override: CASEIN_AGENT_BUDGET_FORCE=1 ...  # operator accepts the risk
       tune:     CASEIN_AGENT_MAX_TOTAL  CASEIN_AGENT_MAX_PER_USER
EOF
  printf 'refused:budget\n'
  return 75
}
