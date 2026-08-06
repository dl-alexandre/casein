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

usage() {
  cat <<'EOF'
Usage: spawn-agent-worker.sh <runtime> <task-slug> [session]

Spawn an external agent in a new tmux window on the workspace session.

Arguments:
  runtime     grok | codex | claude | opencode | agent
  task-slug   short slug for branch/worktree naming (CASEIN_AGENT_TASK)
  session     optional casein_* tmux session; defaults to CASEIN_TMUX_SESSION
              or the current attached session

Prints the new pane id (e.g. %42) on stdout — use it for explicit-pane MCP calls.

Environment: same as launch-casein-agent.sh (resolve via .devbox-agent.env or tmux).
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

# `tmux new-window -P` prints a pane id the moment the *window* exists, but the
# launch command runs inside that pane afterwards. A command that dies instantly
# — a product checkout with no launch-casein-agent.sh, a pairing env that fails
# to source — therefore still yields a pane id and a zero exit, and the caller
# goes on to address a worker that was never running. A false success costs more
# than a failure: you brief a pane that will never answer.
#
# Probe that the pane outlives its first moment. Returns nonzero when the pane
# has vanished (the window closed with its command) or is dead-but-retained
# (`remain-on-exit`).
spawn_worker_probe_pane() {
  local pane_id="$1"
  local budget="${CASEIN_SPAWN_PROBE_SECONDS:-2}"

  # Escape hatch for callers running their own readiness check.
  if [[ "$budget" == "0" ]]; then
    return 0
  fi

  local deadline=$((budget * 10))
  local elapsed=0
  local dead

  while ((elapsed < deadline)); do
    # `list-panes -a` + exact match: `-t <pane>` silently falls back to the
    # current pane for some tmux targets, which would mask a vanished pane.
    dead="$(
      tmux list-panes -a -F '#{pane_id} #{pane_dead}' 2>/dev/null |
        awk -v p="$pane_id" '$1 == p { print $2; found = 1 } END { exit !found }'
    )" || return 1

    if [[ "$dead" == "1" ]]; then
      return 1
    fi

    sleep 0.1
    elapsed=$((elapsed + 1))
  done

  return 0
}

# Best-effort diagnostic output from a pane that failed its probe. A retained
# dead pane still has scrollback; a vanished one does not, so this may print
# nothing.
spawn_worker_pane_tail() {
  local pane_id="$1"
  tmux capture-pane -p -t "$pane_id" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -20 ||
    echo "(pane is gone — no output captured)"
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
  exit 1
fi

printf '%s\n' "$PANE_ID"
