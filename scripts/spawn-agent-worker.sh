#!/usr/bin/env bash
#
# Spawn a dedicated agent worker in a new tmux window and print its pane id.
#
# The launcher execs the agent in the *current* pane, so workers need a fresh
# window. Worktrees are created from the primary checkout (CASEIN_CHECKOUT).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Labeled tmux only — bare tmux follows $TMUX / default server (#248).
# shellcheck source=lib/tmux-label.sh
source "${ROOT}/scripts/lib/tmux-label.sh"
# shellcheck source=lib/agent-env.sh
source "${ROOT}/scripts/lib/agent-env.sh"
# Resolves the executable the launcher will exec — the readiness check below
# looks for exactly that process, not a guess at its name.
# shellcheck source=lib/real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"
# Load/memory gate before opening a worker window (#863).
# shellcheck source=lib/spawn-host-headroom.sh
source "${ROOT}/scripts/lib/spawn-host-headroom.sh"
# Resident-agent budget — the count-based sibling of the headroom gate.
# shellcheck source=lib/agent-budget.sh
source "${ROOT}/scripts/lib/agent-budget.sh"

usage() {
  cat <<'EOF'
Usage: spawn-agent-worker.sh <runtime> <task-slug> [session]

Spawn an external agent in a new tmux window on the workspace session.

Arguments:
  runtime     grok | codex | claude | opencode | agent
  task-slug   short slug for branch/worktree naming (CASEIN_AGENT_TASK)
  session     optional casein_* tmux session; defaults to CASEIN_TMUX_SESSION
              or the current attached session

Prints the new pane id (e.g. %42) on stdout, and only once the agent process is
actually running in that window — use it for explicit-pane MCP calls. A window
that never gets an agent is closed and the script exits non-zero, so a printed
pane id always means a live agent.

Worktrees:
  Branches a fresh agent/<runtime>/<slug>-<stamp> worktree off CASEIN_CHECKOUT
  (CASEIN_AGENT_FORCE_FRESH_WORKTREE=1). Bare product roots are supported
  (Mira-class: core.bare=true) — primary resolve no longer requires a work
  tree, so you do not need CASEIN_AGENT_SKIP_WORKTREE=1 or a hand-made
  worktree. See docs/development-workflow.md.

Environment: same as launch-casein-agent.sh (resolve via .devbox-agent.env or tmux), plus:
  CASEIN_SPAWN_READY_SECONDS        seconds to wait for the agent process (default 120; 0 waives)
  CASEIN_SPAWN_KEEP_FAILED_WINDOW   1 keeps a failed window (renamed failed-*) instead of closing it
  CASEIN_SPAWN_DRY_RUN              1 prints the resolved launch plan without opening a window
  CASEIN_SPAWN_SKIP_WRITE_PREFLIGHT 1 skips the Grok locked-MCP-grant advisory
  CASEIN_SPAWN_FORCE                1 spawn despite headroom below threshold (loud warn; operator risk)
  CASEIN_SPAWN_MAX_LOAD_RATIO       refuse when load1 > nproc × ratio (default 1.0)
  CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB refuse when MemAvailable below this KiB (default 2097152 = 2 GiB)

Stdout tokens (branch on these, not prose):
  spawned <pane_id>          success (also prints a bare pane id for older callers)
  refused:headroom           exit 75 — gate closed
  proceed:headroom-force     CASEIN_SPAWN_FORCE overrode a closed gate, then continues
EOF
}

warn_degraded() {
  echo "warn: $*" >&2
}

spawn_worker_sanitize_slug() {
  local slug="$1"
  slug="${slug//[^A-Za-z0-9_-]/}"
  if [[ -z "$slug" ]]; then
    slug="adhoc"
  fi
  printf '%s\n' "${slug:0:48}"
}

spawn_worker_resolve_session() {
  local explicit="${1:-}"

  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  if [[ -n "${CASEIN_TMUX_SESSION:-}" ]]; then
    printf '%s\n' "${CASEIN_TMUX_SESSION}"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    casein_tmux display-message -p '#{session_name}' 2>/dev/null || true
    return 0
  fi

  return 1
}

spawn_worker_window_name() {
  local slug="$1"
  printf 'worker-%s\n' "$(spawn_worker_sanitize_slug "$slug")"
}

# Report what MCP grant a Grok worker will launch with. The grant is read once,
# when the leader starts, and is then frozen for the pane's life, so resolving
# isolation later does not free a running pane — only a relaunch does. That
# freeze is the part worth announcing up front.
#
# This preflight used to refuse the spawn outright, because a locked grant also
# selected a read-only bwrap base that left the pane unable to write its
# worktree, resolve DNS, or start the BEAM. The base is now always "strict" and
# the two are decoupled, so a locked worker still writes, runs mix, and commits;
# only pane control is withheld. Refusing here would now block a worker that
# works, so this advises and proceeds.
#
# Fails *open* when the answer is inconclusive (no token, no API base, endpoint
# unreachable or unparseable): a degraded control plane must not distort what we
# tell the operator, and the launcher's own announce still fires in that case.
spawn_worker_grok_write_state() {
  local token="${CASEIN_API_TOKEN:-}" workspace="${CASEIN_WORKSPACE_ID:-}"
  local base response state

  # Same resolution order as grok_capability_api_base in launch-casein-agent.sh,
  # so the preflight asks exactly the control plane the launcher would.
  base="${CASEIN_API_BASE_URL:-${CASEIN_URL:-}}"
  if [[ -z "$base" && -n "${CASEIN_TERMINAL_MCP_URL:-}" ]]; then
    base="${CASEIN_TERMINAL_MCP_URL%%/api/terminals/mcp*}"
  fi

  if [[ -z "$base" || -z "$token" || -z "$workspace" ]]; then
    printf 'unknown\n'
    return 0
  fi

  response="$(curl --max-time 5 -fsS \
    -H "authorization: Bearer ${token}" \
    "${base%/}/api/workspaces/${workspace}/status" 2>/dev/null)" || {
    printf 'unknown\n'
    return 0
  }

  state="$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("unknown"); raise SystemExit(0)
agent_write = data.get("agent_write")
if not isinstance(agent_write, dict) or "write_enabled" not in agent_write:
    print("unknown"); raise SystemExit(0)
print("enabled" if agent_write["write_enabled"] else "blocked")
' 2>/dev/null)" || {
    printf 'unknown\n'
    return 0
  }

  printf '%s\n' "${state:-unknown}"
}

spawn_worker_preflight_grok_write() {
  local state
  state="$(spawn_worker_grok_write_state)"

  case "$state" in
    enabled)
      return 0
      ;;
    unknown)
      warn_degraded "could not confirm this workspace's agent-write state; the worker will still write its worktree and run mix, but if it cannot drive panes, resolve isolation and relaunch it"
      return 0
      ;;
  esac

  # A locked grant no longer produces a read-only sandbox — the bwrap base is
  # always "strict" and the worker can write its worktree, run mix, and commit.
  # Only the MCP grant is withheld, so spawning is still worth doing; refusing
  # here would block a worker that works.
  cat >&2 <<EOF
warn: spawning a Grok worker with a LOCKED MCP grant (${state}).
warn:   The worker CAN write its worktree, run mix, and commit. It CANNOT drive
warn:   live tmux panes (terminal_send_command / terminal_send_keys); reporting
warn:   tools still work, so unattended delegation is fine.
warn:   Cause: workspace DB isolation is shared_stage, unsafe, or unknown.
warn:   To get pane control, resolve isolation, then spawn again — the grant is
warn:   read at launch and frozen for the pane.
EOF

  return 0
}

# Resolve the generated, workspace-scoped environment file that a fresh tmux
# window must source before entering the managed launcher. tmux windows inherit
# the server's environment, not the orchestrating shell's current exports, so
# relying on inherited CASEIN_* values can bind the worker to an old session (or
# leave it unpaired entirely).
#
# When the target session is known, THAT session's workspace wins. Inherited
# CASEIN_AGENT_ENV_FILE / CASEIN_AGENT_MCP_HOME are fallbacks only — never an
# override of an explicit cross-session target (fleet bug: A-orchestrator spawn
# into B-session silently sourced A's pairing and wrote the wrong product).
spawn_worker_resolve_env_file() {
  local session="${1:-}"
  local workspace_name="" session_env="" candidate
  local caller_env="${CASEIN_AGENT_ENV_FILE:-}"
  local caller_ws="${CASEIN_WORKSPACE_NAME:-}"

  if [[ -z "$caller_ws" && -n "${CASEIN_AGENT_MCP_HOME:-}" &&
    "${CASEIN_AGENT_MCP_HOME}" =~ /agent-mcp/([^/]+)/?$ ]]; then
    caller_ws="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$caller_ws" && -n "$caller_env" &&
    "$caller_env" =~ /agent-mcp/([^/]+)/ ]]; then
    caller_ws="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$session" ]] && workspace_name="$(agent_env_parse_workspace_name "$session")"; then
    session_env="$(agent_env_staging_env_file "$workspace_name")"
    if [[ -r "$session_env" ]]; then
      printf '%s\n' "$session_env"
      return 0
    fi

    # Named target workspace but no pairing file: refuse rather than fall back
    # to the caller's (likely foreign) env — silent wrong-product is worse.
    {
      echo "error: workspace pairing env not found for target session '${session}'"
      echo "error:   target_workspace=${workspace_name}"
      echo "error:   expected=${session_env}"
      if [[ -n "$caller_ws" && "$caller_ws" != "$workspace_name" ]]; then
        echo "error:   caller_workspace=${caller_ws} (not used — target session wins)"
      fi
      if [[ -n "$caller_env" ]]; then
        echo "error:   ignoring caller CASEIN_AGENT_ENV_FILE=${caller_env}"
      fi
      echo "error:   pair the target workspace first (materialize-agent-mcp / ensure-workspace-agent-pair)"
    } >&2
    return 1
  fi

  for candidate in \
    "${CASEIN_AGENT_ENV_FILE:-}" \
    "${CASEIN_AGENT_MCP_HOME:-}/env.sh"; do
    [[ -n "$candidate" && -r "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

# When the resolved env file describes a different workspace than the
# orchestrator already exported, load it into this process so checkout + Grok
# write preflight match the destination. Same-workspace keeps caller overrides
# (e.g. an explicit CASEIN_CHECKOUT pointing at a product tree).
spawn_worker_align_process_to_env_file() {
  local env_file="$1"
  local session="${2:-}"
  local target_ws="" file_ws="" caller_ws="${CASEIN_WORKSPACE_NAME:-}"

  if [[ -n "$session" ]]; then
    target_ws="$(agent_env_parse_workspace_name "$session" 2>/dev/null)" || target_ws=""
  fi

  file_ws="$(
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$env_file" >/dev/null 2>&1
    set +a
    printf '%s' "${CASEIN_WORKSPACE_NAME:-}"
  )"

  if [[ -z "$target_ws" ]]; then
    target_ws="$file_ws"
  fi

  if [[ -z "$caller_ws" && -n "${CASEIN_AGENT_ENV_FILE:-}" &&
    "${CASEIN_AGENT_ENV_FILE}" =~ /agent-mcp/([^/]+)/ ]]; then
    caller_ws="${BASH_REMATCH[1]}"
  fi

  # Already on the destination workspace with creds — keep process env (and any
  # intentional CASEIN_CHECKOUT override from the caller).
  if [[ -n "$caller_ws" && -n "$target_ws" && "$caller_ws" == "$target_ws" &&
    -n "${CASEIN_API_TOKEN:-}" && -n "${CASEIN_WORKSPACE_ID:-}" ]]; then
    return 0
  fi
  if [[ -z "$target_ws" || -z "$file_ws" ]]; then
    return 0
  fi
  if [[ -n "$caller_ws" && "$caller_ws" == "$file_ws" &&
    -n "${CASEIN_API_TOKEN:-}" && -n "${CASEIN_WORKSPACE_ID:-}" ]]; then
    return 0
  fi

  unset CASEIN_API_TOKEN CASEIN_WORKSPACE_ID CASEIN_WORKSPACE_NAME CASEIN_CHECKOUT \
    CASEIN_AGENT_MCP_HOME CASEIN_TERMINAL_MCP_URL CASEIN_PREVIEW_MCP_URL \
    CASEIN_ARTIFACT_MCP_URL CASEIN_API_BASE_URL CASEIN_URL 2>/dev/null || true
  agent_env_load_file "$env_file"
}

spawn_worker_checkout_is_valid() {
  local candidate="${1:-}"

  [[ -n "$candidate" && -d "$candidate" ]] || return 1
  git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1
}

spawn_worker_env_file_value() {
  local env_file="$1"
  local key="$2"

  (
    # shellcheck disable=SC1090
    source "$env_file" >/dev/null 2>&1 || exit 1
    printf '%s\n' "${!key:-}"
  )
}

spawn_worker_recover_checkout() {
  local stale="$1"
  local env_file="$2"
  local workspace_name="${3:-}"
  local file_scripts file_primary candidate
  local -a candidates=()

  file_primary="$(spawn_worker_env_file_value "$env_file" CASEIN_AGENT_PRIMARY_CHECKOUT 2>/dev/null || true)"
  if [[ -n "$file_primary" ]]; then
    candidates+=("$file_primary")
  fi

  if [[ -n "$workspace_name" ]]; then
    candidates+=("$(agent_env_default_checkout "$workspace_name")")
  fi

  file_scripts="$(spawn_worker_env_file_value "$env_file" CASEIN_SCRIPTS 2>/dev/null || true)"
  if [[ "$file_scripts" == */scripts ]]; then
    candidates+=("${file_scripts%/scripts}")
  fi

  if [[ "${CASEIN_SCRIPTS:-}" == */scripts ]]; then
    candidates+=("${CASEIN_SCRIPTS%/scripts}")
  fi

  # ROOT is a safe fallback only for the Casein workspace. A product launch
  # must never silently fall back to the Casein repository when its own primary
  # checkout is unavailable.
  case "$workspace_name" in
    dalexandre-casein | casein) candidates+=("$ROOT") ;;
  esac

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if spawn_worker_checkout_is_valid "$candidate"; then
      echo "warn: recovered stale CASEIN_CHECKOUT=${stale} using ${candidate} (env.sh source=${env_file})" >&2
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "error: CASEIN_CHECKOUT=${stale} from env.sh source=${env_file} does not exist" >&2
  echo "error: could not recover an existing primary checkout for workspace=${workspace_name:-<unknown>}" >&2
  return 1
}

# Nonzero when the pane has vanished (the window closed with its command) or is
# dead-but-retained (`remain-on-exit`).
spawn_worker_pane_alive() {
  local pane_id="$1"
  local dead

  # `list-panes -a` + exact match: `-t <pane>` silently falls back to the
  # current pane for some tmux targets, which would mask a vanished pane.
  dead="$(
    casein_tmux list-panes -a -F '#{pane_id} #{pane_dead}' 2>/dev/null |
      awk -v p="$pane_id" '$1 == p { print $2; found = 1 } END { exit !found }'
  )" || return 1

  [[ "$dead" != "1" ]]
}

# `tmux new-window -P` prints a pane id the moment the *window* exists, but the
# launch command runs inside that pane afterwards. A command that dies instantly
# — a product checkout with no launch-casein-agent.sh, a pairing env that fails
# to source — therefore still yields a pane id and a zero exit, and the caller
# goes on to address a worker that was never running. A false success costs more
# than a failure: you brief a pane that will never answer.
#
# Probe that the pane outlives its first moment. This is only the fast fail;
# spawn_worker_wait_for_agent below covers the launcher dying *later*.
spawn_worker_probe_pane() {
  local pane_id="$1"
  local budget="${CASEIN_SPAWN_PROBE_SECONDS:-2}"

  # Escape hatch for callers running their own readiness check.
  if [[ "$budget" == "0" ]]; then
    return 0
  fi

  local deadline=$((budget * 10))
  local elapsed=0

  while ((elapsed < deadline)); do
    spawn_worker_pane_alive "$pane_id" || return 1
    sleep 0.1
    elapsed=$((elapsed + 1))
  done

  return 0
}

spawn_worker_escape_ere() {
  printf '%s' "$1" | sed 's/[][(){}.*+?^$|\\]/\\&/g'
}

# An ERE matching the argv of the process the launcher execs for this runtime.
#
# Prefer the resolved absolute path: it is the exact executable
# launch-casein-agent.sh runs (both resolve through real_agent_bin), and it never
# appears in the launch command itself — so the launcher's own trailing
# `launch-casein-agent.sh claude` argument cannot masquerade as a running agent.
# The name fallback covers a runtime installed only behind a shim, and is
# anchored to a path segment plus an argument boundary for the same reason.
spawn_worker_agent_pattern() {
  local runtime="$1"
  local names bin=""

  case "$runtime" in
    claude) names='claude([.](exe|js))?' ;;
    codex) names='codex([.]js)?' ;;
    opencode) names='opencode' ;;
    grok) names='grok' ;;
    # `agent` is the Grok-family runtime under its generic name.
    agent) names='(grok|agent)' ;;
    *) names="$runtime" ;;
  esac

  bin="$(real_agent_bin "$runtime" 2>/dev/null || true)"
  if [[ -n "$bin" ]]; then
    printf '(%s)( |$)|(^|/)%s( |$)\n' "$(spawn_worker_escape_ere "$bin")" "$names"
    return 0
  fi

  printf '(^|/)%s( |$)\n' "$names"
}

# Print the argv of the first process in the pane's tree whose command matches
# `pattern`. Nonzero when the pane holds no such process.
#
# The whole tree, not just the pane's own process: tmux runs the launch command
# under a shell, and bash does not exec the tail of an `&&` chain, so the agent
# is a child of the pane process rather than the pane process itself.
spawn_worker_agent_process() {
  local root_pid="$1" pattern="$2"

  # -ww so long agent argv is not truncated to terminal width. awk reads the
  # whole listing (no early exit) — an early exit would SIGPIPE ps and, under
  # `set -o pipefail`, report a found agent as a failure.
  ps -eww -o pid=,ppid=,args= 2>/dev/null |
    SPAWN_PATTERN="$pattern" SPAWN_ROOT_PID="$root_pid" awk '
      BEGIN { pattern = ENVIRON["SPAWN_PATTERN"]; root = ENVIRON["SPAWN_ROOT_PID"] }
      {
        pid = $1
        args = $0
        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", args)
        parent[pid] = $2
        command[pid] = args
        order[++seen] = pid
      }
      END {
        for (i = 1; i <= seen; i++) {
          pid = order[i]
          if (command[pid] !~ pattern) continue
          cursor = pid
          for (depth = 0; depth < 64; depth++) {
            if (cursor == root) { print command[pid]; exit 0 }
            if (!(cursor in parent)) break
            cursor = parent[cursor]
          }
        }
        exit 1
      }
    '
}

# Surviving the first moment is not the same as running an agent. A spawn has
# already returned "success" for a window holding nothing but a shell — the
# launcher got far enough to keep the pane alive, then failed before its exec —
# and the caller went on to brief a pane that could never answer. Wait for the
# agent process itself.
#
# Returns 0 once it is running, 2 if the pane died while starting, 1 if the
# budget elapsed with no agent in the pane.
spawn_worker_wait_for_agent() {
  local pane_id="$1" runtime="$2"
  local budget="${CASEIN_SPAWN_READY_SECONDS:-120}"

  # Escape hatch for callers running their own readiness check.
  if [[ "$budget" == "0" ]]; then
    return 0
  fi

  local pattern pane_pid elapsed=0
  pattern="$(spawn_worker_agent_pattern "$runtime")"

  while ((elapsed < budget)); do
    spawn_worker_pane_alive "$pane_id" || return 2

    pane_pid="$(casein_tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null || true)"
    if [[ -n "$pane_pid" ]] && spawn_worker_agent_process "$pane_pid" "$pattern" >/dev/null; then
      return 0
    fi

    # Startup is 30-90s (fresh worktree, fetch, MCP materialize), so say what
    # the wait is for rather than looking hung.
    if ((elapsed > 0 && elapsed % 15 == 0)); then
      echo "waiting for ${runtime} to come up in ${pane_id} (${elapsed}s of ${budget}s)" >&2
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

# Best-effort diagnostic output from a pane that failed its probe. A retained
# dead pane still has scrollback; a vanished one does not, so this may print
# nothing.
spawn_worker_pane_tail() {
  local pane_id="$1"
  casein_tmux capture-pane -p -t "$pane_id" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -20 ||
    echo "(pane is gone — no output captured)"
}

# A failed spawn must not leave a window that looks like a worker. Close it by
# default — the diagnosis the operator needs is the pane tail, which is already
# on stderr, and an abandoned window is indistinguishable in the picker from a
# live worker waiting on a briefing. Keep it when asked, renamed so it reads as
# wreckage rather than as a worker.
spawn_worker_dispose_window() {
  local pane_id="$1" window_name="$2"

  if [[ "${CASEIN_SPAWN_KEEP_FAILED_WINDOW:-0}" == "1" ]]; then
    casein_tmux rename-window -t "$pane_id" "failed-${window_name}" 2>/dev/null || true
    echo "note: left the window open as 'failed-${window_name}' — close it when you are done" >&2
    return 0
  fi

  casein_tmux kill-window -t "$pane_id" 2>/dev/null || true
  echo "note: closed the failed worker window (CASEIN_SPAWN_KEEP_FAILED_WINDOW=1 keeps it for inspection)" >&2
}

# Resolve the primary (main) working tree for a candidate checkout.
#
# In an agent's environment CASEIN_CHECKOUT points at *that agent's own* linked
# worktree, not the primary repo. Launching a worker there is a trap:
# agent_worktree_ensure adopts any linked worktree it is started inside instead
# of branching a fresh one (see scripts/lib/agent-worktree.sh), so the worker
# would silently share the orchestrator's checkout and branch. git lists the
# main working tree first in `worktree list`, so resolve to that — worktrees
# must be branched from the primary.
#
# Deliberately no pipeline. `git worktree list | awk '/^worktree /{print $2; exit}'`
# reads naturally, but awk's early exit closes the pipe, git dies on SIGPIPE, and
# `set -o pipefail` then reports the whole pipeline as failed — so the guard fell
# through and returned the ORCHESTRATOR's own worktree, silently defeating the
# protection this function exists to provide. It only reproduces once the repo has
# enough worktrees for git's output to outrun awk (41 here), which is why it
# survived review: on a small checkout git finishes writing first and it looks
# correct.
spawn_worker_resolve_primary_checkout() {
  local candidate="$1"
  local listing line primary="" candidate_real primary_real

  if listing="$(git -C "$candidate" worktree list --porcelain 2>/dev/null)"; then
    while IFS= read -r line; do
      if [[ "$line" == "worktree "* ]]; then
        primary="${line#worktree }"
        break
      fi
    done <<<"$listing"
  fi

  if [[ -n "$primary" && -d "$primary" ]]; then
    candidate_real="$(cd "$candidate" 2>/dev/null && pwd -P)"
    primary_real="$(cd "$primary" 2>/dev/null && pwd -P)"
    if [[ "$candidate_real" == "$primary_real" ]]; then
      # Keep the env.sh spelling when it already names the primary checkout.
      # Git canonicalizes /var to /private/var on macOS, but the persisted
      # CASEIN_CHECKOUT value is an exact launch identity.
      printf '%s\n' "$candidate"
      return 0
    fi

    printf '%s\n' "$primary"
    return 0
  fi

  printf '%s\n' "$candidate"
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 1
fi

RUNTIME="$1"
TASK_SLUG="$(spawn_worker_sanitize_slug "$2")"
SESSION_ARG="${3:-}"

case "$RUNTIME" in
  grok | codex | claude | opencode | agent) ;;
  *)
    echo "error: unsupported runtime '${RUNTIME}' (expected grok|codex|claude|opencode|agent)" >&2
    exit 1
    ;;
esac

# Session first: env resolution keys off the *target* session workspace, not
# whatever CASEIN_AGENT_* the orchestrator inherited from its own pane.
SESSION="$(spawn_worker_resolve_session "$SESSION_ARG")" || {
  echo "error: could not resolve tmux session — pass session explicitly" >&2
  exit 1
}

if [[ -z "$SESSION" ]]; then
  echo "error: empty tmux session name" >&2
  exit 1
fi

if [[ "$SESSION" != casein_* ]]; then
  warn_degraded "session '${SESSION}' does not look like a Casein session (expected casein_* prefix)"
fi

ENV_FILE="$(spawn_worker_resolve_env_file "$SESSION")" || {
  # spawn_worker_resolve_env_file already printed a target/caller mismatch when
  # the session named a workspace; only the no-session fallback needs a generic
  # hint here.
  if [[ ! -r "${CASEIN_AGENT_ENV_FILE:-}" && ! -r "${CASEIN_AGENT_MCP_HOME:-}/env.sh" ]]; then
    echo "error: workspace pairing env not found — run scripts/materialize-agent-mcp.sh first" >&2
  fi
  exit 1
}

# Prefer target pairing when the orchestrator is already fully exported for a
# *different* workspace (agent_env_resolve short-circuits on token+id). Same-
# workspace callers keep their exports / CASEIN_CHECKOUT overrides.
spawn_worker_align_process_to_env_file "$ENV_FILE" "$SESSION"
agent_env_resolve

REQUESTED_CHECKOUT="${CASEIN_CHECKOUT:-$ROOT}"
if ! spawn_worker_checkout_is_valid "$REQUESTED_CHECKOUT"; then
  WORKSPACE_NAME="${CASEIN_WORKSPACE_NAME:-}"
  if [[ -z "$WORKSPACE_NAME" ]]; then
    WORKSPACE_NAME="$(agent_env_parse_workspace_name "$SESSION" 2>/dev/null || true)"
  fi
  CHECKOUT="$(spawn_worker_recover_checkout "$REQUESTED_CHECKOUT" "$ENV_FILE" "$WORKSPACE_NAME")" || exit 1
else
  CHECKOUT="$REQUESTED_CHECKOUT"
fi

# CASEIN_CHECKOUT may point at the orchestrator's own linked worktree; the
# worker must branch off the primary repo, not launch inside it.
CHECKOUT="$(spawn_worker_resolve_primary_checkout "$CHECKOUT")"
if ! spawn_worker_checkout_is_valid "$CHECKOUT"; then
  echo "error: resolved primary checkout is not a usable git checkout: ${CHECKOUT}" >&2
  echo "error: CASEIN_CHECKOUT source=${ENV_FILE}" >&2
  exit 1
fi

LAUNCHER="${ROOT}/scripts/launch-casein-agent.sh"
if [[ ! -f "$LAUNCHER" ]]; then
  echo "error: Casein launcher not found at ${LAUNCHER}" >&2
  exit 1
fi

if ! casein_tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "error: tmux session not found: ${SESSION}" >&2
  exit 1
fi

# Headroom before any window open (and before dry-run print) so a full box never
# looks "successful" under CASEIN_SPAWN_DRY_RUN. Decline is loud; FORCE overrides.
spawn_host_headroom_check || exit $?
agent_budget_check "$RUNTIME" || exit $?

if [[ "$RUNTIME" == "grok" && "${CASEIN_SPAWN_SKIP_WRITE_PREFLIGHT:-0}" != "1" ]]; then
  spawn_worker_preflight_grok_write
fi

WINDOW_NAME="$(spawn_worker_window_name "$TASK_SLUG")"
# Source the orchestrator's resolved workspace pairing before launch. A fresh
# tmux window otherwise sees only the tmux server's potentially stale env. Pin
# the explicit target session after sourcing because an older env.sh may have
# been materialized for another session; launch-casein-agent.sh then normalizes
# the tmux socket and rebinds MCP URLs to the actual new pane.
#
# Clear stale worktree pointers and pin CASEIN_CHECKOUT to the primary so each
# spawn gets a fresh agent/<runtime>/<slug>-<stamp> worktree off the primary
# checkout. Both matter: launch-casein-agent.sh keys worktree creation off the
# cwd *and* CASEIN_CHECKOUT, and an inherited value would point back at the
# orchestrator's linked worktree. CASEIN_AGENT_FORCE_FRESH_WORKTREE makes
# agent_worktree_ensure refuse to adopt whatever tree the launcher lands in
# (the cwd heuristic has proven unreliable from nested worktrees) and always
# branch a fresh one — so a worker can never operate in a shared checkout.
# The launcher is Casein infrastructure and deliberately comes from ROOT, not
# the product checkout (which generally has no launch-casein-agent.sh).
LAUNCH_CMD="source $(printf '%q' "$ENV_FILE") && export CASEIN_TMUX_SESSION=$(printf '%q' "$SESSION") && unset CASEIN_TMUX_SOCKET_RESOLVED CASEIN_AGENT_WORKTREE_PATH CASEIN_WORKTREE CASEIN_GIT_DIR CASEIN_SCRIPTS && cd $(printf '%q' "$CHECKOUT") && export CASEIN_CHECKOUT=$(printf '%q' "$CHECKOUT") CASEIN_AGENT_PRIMARY_CHECKOUT=$(printf '%q' "$CHECKOUT") CASEIN_AGENT_FORCE_FRESH_WORKTREE=1 && CASEIN_AGENT_TASK=$(printf '%q' "$TASK_SLUG") bash $(printf '%q' "$LAUNCHER") $(printf '%q' "$RUNTIME")"

if [[ "${CASEIN_SPAWN_DRY_RUN:-0}" == "1" ]]; then
  printf 'session=%s\ncheckout=%s\nenv_file=%s\nlauncher=%s\nwindow=%s\nheadroom=%s\nlaunch=%s\n' \
    "$SESSION" "$CHECKOUT" "$ENV_FILE" "$LAUNCHER" "$WINDOW_NAME" \
    "${SPAWN_HOST_HEADROOM_LAST:-ok}" "$LAUNCH_CMD"
  exit 0
fi

PANE_ID=""
NEW_WINDOW_STATUS=0
PANE_ID="$(casein_tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -P -F '#{pane_id}' "$LAUNCH_CMD" 2>/dev/null)" ||
  NEW_WINDOW_STATUS=$?

if ((NEW_WINDOW_STATUS != 0)); then
  echo "error: tmux new-window failed (exit ${NEW_WINDOW_STATUS}); launch was not retried" >&2
  if [[ -n "$PANE_ID" ]]; then
    spawn_worker_dispose_window "$PANE_ID" "$WINDOW_NAME"
  fi
  exit "$NEW_WINDOW_STATUS"
fi

if [[ -z "$PANE_ID" ]]; then
  echo "error: tmux new-window did not return a pane id" >&2
  exit 1
fi

# Keep the pane after the launch command exits so spawn_worker_pane_tail can
# still read the launcher's stderr. Without remain-on-exit, tmux reaps the
# dead pane before KEEP_FAILED_WINDOW can preserve it (#990).
casein_tmux set-option -w -t "$PANE_ID" remain-on-exit on 2>/dev/null ||
  casein_tmux set-window-option -t "$PANE_ID" remain-on-exit on 2>/dev/null ||
  true

if ! spawn_worker_probe_pane "$PANE_ID"; then
  echo "error: worker pane ${PANE_ID} died immediately after launch" >&2
  echo "hint: the launch command failed inside the pane — common causes are a" \
    "product checkout with no launch-casein-agent.sh, or pairing env that" \
    "failed to source. Last pane output:" >&2
  spawn_worker_pane_tail "$PANE_ID" >&2
  spawn_worker_dispose_window "$PANE_ID" "$WINDOW_NAME"
  exit 1
fi

READY_STATUS=0
spawn_worker_wait_for_agent "$PANE_ID" "$RUNTIME" || READY_STATUS=$?

if ((READY_STATUS != 0)); then
  if ((READY_STATUS == 2)); then
    echo "error: worker pane ${PANE_ID} died while ${RUNTIME} was starting" >&2
  else
    echo "error: no ${RUNTIME} process appeared in worker pane ${PANE_ID} within" \
      "${CASEIN_SPAWN_READY_SECONDS:-120}s" >&2
    echo "hint: the window is alive but holds only a shell — the launcher never" \
      "reached its exec, so this window would never have answered a briefing." \
      "Reproduce it with CASEIN_SPAWN_DRY_RUN=1 and run the printed launch" \
      "command by hand to see where it stops. Raise" \
      "CASEIN_SPAWN_READY_SECONDS if the runtime is genuinely just slow." >&2
  fi
  echo "hint: last pane output:" >&2
  spawn_worker_pane_tail "$PANE_ID" >&2
  spawn_worker_dispose_window "$PANE_ID" "$WINDOW_NAME"
  exit 1
fi

printf 'spawned %s\n' "$PANE_ID"
printf '%s\n' "$PANE_ID"
