#!/usr/bin/env bash
#
# Spawn a dedicated agent worker in a new tmux window and print its pane id.
#
# The launcher execs the agent in the *current* pane, so workers need a fresh
# window. Worktrees are created from the primary checkout (CASEIN_CHECKOUT).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/agent-env.sh
source "${ROOT}/scripts/lib/agent-env.sh"
# Resolves the executable the launcher will exec — the readiness check below
# looks for exactly that process, not a guess at its name.
# shellcheck source=lib/real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"

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

Environment: same as launch-casein-agent.sh (resolve via .devbox-agent.env or tmux), plus:
  CASEIN_SPAWN_READY_SECONDS        seconds to wait for the agent process (default 120; 0 waives)
  CASEIN_SPAWN_KEEP_FAILED_WINDOW   1 keeps a failed window (renamed failed-*) instead of closing it
  CASEIN_SPAWN_DRY_RUN              1 prints the resolved launch plan without opening a window
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
    tmux display-message -p '#{session_name}' 2>/dev/null || true
    return 0
  fi

  return 1
}

spawn_worker_window_name() {
  local slug="$1"
  printf 'worker-%s\n' "$(spawn_worker_sanitize_slug "$slug")"
}

# A managed Grok worker's bwrap sandbox base is chosen once, when its leader
# starts, from the workspace's agent-write unlock — and is then frozen for the
# pane's life. Spawning while locked therefore produces a pane that reaches a
# normal prompt but cannot write its worktree, resolve DNS, or start the BEAM;
# re-granting the unlock afterwards does not free it, only a relaunch does.
# launch-casein-agent.sh warns about this, but the warning is one stderr line at
# startup that scrolls away, so whole fan-outs have been spawned dead and
# rediscovered by failure. Refuse to open the window instead.
#
# Fails *open* when the answer is inconclusive (no token, no API base, endpoint
# unreachable or unparseable): a degraded control plane must not make spawning
# impossible, and the launcher's own announce still fires in that case. Only a
# definitive "locked" blocks.
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
if agent_write["write_enabled"]:
    print("unlocked"); raise SystemExit(0)
# write_enabled can be false with a live unlock: the workspace may not be in
# manual mode, or its DB isolation may be shared_stage/unsafe. Do not call that
# an expired unlock — the operator would re-grant and get nowhere.
status = agent_write.get("unlock_status")
print(status if status in ("inactive", "expired") else "blocked-by-workspace-policy")
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
    unlocked)
      return 0
      ;;
    unknown)
      warn_degraded "could not confirm this workspace's agent-write unlock; if the worker comes up read-only, re-grant agent write and relaunch it"
      return 0
      ;;
  esac

  cat >&2 <<EOF
error: refusing to spawn a Grok worker — agent write is unavailable (${state}).
error:   The worker would get a READ-ONLY sandbox: it would reach a normal prompt but
error:   could not write its worktree, reach the network, or run mix. That state is
error:   frozen at launch, so re-granting the unlock later would not free this pane.
EOF

  if [[ "$state" == "blocked-by-workspace-policy" ]]; then
    cat >&2 <<'EOF'
error:   The unlock itself is active — the block is elsewhere: the workspace is not in
error:   manual mode, or its DB isolation is shared_stage/unsafe. Re-granting the
error:   unlock will not help; resolve that first.
EOF
  else
    cat >&2 <<'EOF'
error:   Fix: re-grant agent write for the workspace in the Casein UI, then spawn again.
EOF
  fi

  cat >&2 <<EOF
error:   For write work right now, spawn a codex worker instead — it is not gated:
error:     bash scripts/spawn-agent-worker.sh codex ${TASK_SLUG:-<slug>}
error:   To spawn a deliberately read-only Grok worker anyway, set
error:   CASEIN_SPAWN_ALLOW_READ_ONLY=1.
EOF
  exit 3
}

# Resolve the generated, workspace-scoped environment file that a fresh tmux
# window must source before entering the managed launcher. tmux windows inherit
# the server's environment, not the orchestrating shell's current exports, so
# relying on inherited CASEIN_* values can bind the worker to an old session (or
# leave it unpaired entirely).
spawn_worker_resolve_env_file() {
  local candidate

  for candidate in \
    "${CASEIN_AGENT_ENV_FILE:-}" \
    "${CASEIN_AGENT_MCP_HOME:-}/env.sh"; do
    [[ -n "$candidate" && -r "$candidate" ]] || continue
    realpath -m "$candidate"
    return 0
  done

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
    tmux list-panes -a -F '#{pane_id} #{pane_dead}' 2>/dev/null |
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

    pane_pid="$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null || true)"
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
  tmux capture-pane -p -t "$pane_id" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -20 ||
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
    tmux rename-window -t "$pane_id" "failed-${window_name}" 2>/dev/null || true
    echo "note: left the window open as 'failed-${window_name}' — close it when you are done" >&2
    return 0
  fi

  tmux kill-window -t "$pane_id" 2>/dev/null || true
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
  local listing line primary=""

  if listing="$(git -C "$candidate" worktree list --porcelain 2>/dev/null)"; then
    while IFS= read -r line; do
      if [[ "$line" == "worktree "* ]]; then
        primary="${line#worktree }"
        break
      fi
    done <<<"$listing"
  fi

  if [[ -n "$primary" && -d "$primary" ]]; then
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

agent_env_resolve

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

CHECKOUT="${CASEIN_CHECKOUT:-$ROOT}"
if [[ ! -d "$CHECKOUT" ]]; then
  echo "error: checkout not found at ${CHECKOUT}" >&2
  exit 1
fi

# CASEIN_CHECKOUT may point at the orchestrator's own linked worktree; the
# worker must branch off the primary repo, not launch inside it.
CHECKOUT="$(spawn_worker_resolve_primary_checkout "$CHECKOUT")"

LAUNCHER="${ROOT}/scripts/launch-casein-agent.sh"
if [[ ! -f "$LAUNCHER" ]]; then
  echo "error: Casein launcher not found at ${LAUNCHER}" >&2
  exit 1
fi

ENV_FILE="$(spawn_worker_resolve_env_file)" || {
  echo "error: workspace pairing env not found — run scripts/materialize-agent-mcp.sh first" >&2
  exit 1
}

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "error: tmux session not found: ${SESSION}" >&2
  exit 1
fi

if [[ "$RUNTIME" == "grok" && "${CASEIN_SPAWN_ALLOW_READ_ONLY:-0}" != "1" ]]; then
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
LAUNCH_CMD="source $(printf '%q' "$ENV_FILE") && export CASEIN_TMUX_SESSION=$(printf '%q' "$SESSION") && unset CASEIN_TMUX_SOCKET_RESOLVED CASEIN_AGENT_WORKTREE_PATH CASEIN_WORKTREE CASEIN_GIT_DIR CASEIN_SCRIPTS && cd $(printf '%q' "$CHECKOUT") && export CASEIN_CHECKOUT=$(printf '%q' "$CHECKOUT") CASEIN_AGENT_FORCE_FRESH_WORKTREE=1 && CASEIN_AGENT_TASK=$(printf '%q' "$TASK_SLUG") bash $(printf '%q' "$LAUNCHER") $(printf '%q' "$RUNTIME")"

if [[ "${CASEIN_SPAWN_DRY_RUN:-0}" == "1" ]]; then
  printf 'session=%s\ncheckout=%s\nenv_file=%s\nlauncher=%s\nwindow=%s\nlaunch=%s\n' \
    "$SESSION" "$CHECKOUT" "$ENV_FILE" "$LAUNCHER" "$WINDOW_NAME" "$LAUNCH_CMD"
  exit 0
fi

PANE_ID="$(
  tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -P -F '#{pane_id}' "$LAUNCH_CMD" 2>/dev/null ||
    tmux new-window -t "$SESSION" -P -F '#{pane_id}' "$LAUNCH_CMD"
)"

if [[ -z "$PANE_ID" ]]; then
  echo "error: tmux new-window did not return a pane id" >&2
  exit 1
fi

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

printf '%s\n' "$PANE_ID"
