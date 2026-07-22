#!/usr/bin/env bash
#
# Local mirror of the checks that must pass before a push to master can deploy.
# This intentionally uses read-only Mix checks so it is safe in a dirty worktree
# with unrelated edits.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# log announces each gate step; GATE_CURRENT_STEP remembers the last one so a
# failing run can report which step it died in (approximate: informational log
# lines inside a step move the marker, which is close enough for triage).
GATE_CURRENT_STEP=""
log() { printf '>>> %s\n' "$*"; GATE_CURRENT_STEP="$*"; }

# --- Gate-run recording (fail-open) -----------------------------------------
# Report the verdict to DevIDE as a durable gate.passed / gate.failed audit
# row via the terminal MCP gate_report tool (the agent_worktree_report_mcp
# pattern in scripts/lib/agent-worktree.sh). Reporting must NEVER fail the
# gate: it is skipped silently without the workspace env, curls with a short
# timeout, and swallows every error.
GATE_STARTED_AT="$(date +%s)"

report_gate_result() {
  local exit_code="$1"
  [[ -n "${DEV_IDE_API_TOKEN:-}" && -n "${DEVIDE_WORKSPACE_ID:-}" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local mcp_url="${DEVIDE_TERMINAL_MCP_URL:-${DEVIDE_URL:-http://127.0.0.1:4000}/api/terminals/mcp}"
  local branch sha duration passed failed_step
  branch="$(git -C "${ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  sha="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || true)"
  duration="$(( $(date +%s) - GATE_STARTED_AT ))"
  if [[ "${exit_code}" -eq 0 ]]; then
    passed=true
    failed_step=""
  else
    passed=false
    failed_step="${GATE_CURRENT_STEP}"
  fi

  local params rpc_body
  params="$(
    GATE_BRANCH="${branch}" GATE_SHA="${sha}" GATE_PASSED="${passed}" \
    GATE_DURATION_S="${duration}" GATE_FAILED_STEP="${failed_step}" \
    python3 -c '
import json, os
print(json.dumps({
    "workspace_id": os.environ["DEVIDE_WORKSPACE_ID"],
    "branch": os.environ.get("GATE_BRANCH") or None,
    "sha": os.environ.get("GATE_SHA") or None,
    "passed": os.environ.get("GATE_PASSED") == "true",
    "duration_s": int(os.environ.get("GATE_DURATION_S") or 0),
    "failed_step": os.environ.get("GATE_FAILED_STEP") or None,
}))
' 2>/dev/null || true
  )"
  [[ -n "${params}" ]] || return 0

  rpc_body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"gate_report\",\"arguments\":${params}}}"
  curl -fsS --max-time 5 -X POST "${mcp_url}" \
    -H "authorization: Bearer ${DEV_IDE_API_TOKEN}" \
    -H "content-type: application/json" \
    -d "${rpc_body}" >/dev/null 2>&1 || true
  return 0
}
trap 'report_gate_result "$?" || true' EXIT
# -----------------------------------------------------------------------------

# The deploy poller runs this gate under systemd with a 1024 soft fd limit;
# the full test suite plus the cover HTML export opens more files than that
# under load (observed as `:emfile` aborting an otherwise-green gate). Raise
# the soft limit toward the hard limit — allowed without privileges; best
# effort so an environment with a locked-down hard limit still runs.
hard_nofile="$(ulimit -Hn 2>/dev/null || echo "")"
if [[ "${hard_nofile}" =~ ^[0-9]+$ ]] && [ "${hard_nofile}" -gt 4096 ]; then
  ulimit -n "$(( hard_nofile < 65536 ? hard_nofile : 65536 ))" 2>/dev/null || true
fi

cd "${ROOT}"

# Elixir runs through mise (reads .tool-versions) locally and on the self-hosted
# runner, but GitHub-hosted runners have no mise. Fall back to plain `mix` when
# mise is absent so one script drives both.
if command -v mise >/dev/null 2>&1; then
  MIX=(mise exec -- mix)
else
  MIX=(mix)
fi

# --- Cheap checks first: fail fast on trivial breakage (seconds, not minutes)
# before paying for npm and the test suite. ---

log "checking staged/worktree whitespace"
git diff --check

log "checking deploy script syntax"
bash -n scripts/deploy-devbox-release.sh
bash -n scripts/lib/canary-drain.sh

log "running hermetic shell unit tests (scoped-token validation/durability)"
bash scripts/test-scoped-token-durability.sh

log "running hermetic shell unit tests (agent shim install/resolution/passthrough)"
bash scripts/test-agent-shims.sh

log "running hermetic shell unit tests (canary drain/stop decisions)"
bash scripts/test-canary-drain.sh

log "shellcheck (warning+) on agent shim/launch scripts"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning -x \
    scripts/devide \
    scripts/install-agent-shims.sh \
    scripts/launch-devide-agent.sh \
    scripts/lib/real-agent-bin.sh \
    scripts/lib/agent-doctor.sh \
    scripts/lib/canary-drain.sh \
    scripts/test-canary-drain.sh \
    scripts/test-agent-shims.sh
else
  log "shellcheck not installed — skipping (GitHub-hosted CI runners have it)"
fi

log "boundary: agent launcher shims must never target ~/.local/bin again"
# The shims moved to ~/.devide/agent-shims so plain terminals stay untouched
# by DevIDE (operator call, 2026-07-13). Pin the installer's target dir and
# the Elixir default; a regression here silently re-hijacks agent names
# machine-wide.
if ! grep -q 'BIN_DIR="\${DEV_IDE_AGENT_BIN_DIR:-\${HOME}/.devide/agent-shims}"' scripts/install-agent-shims.sh; then
  echo "ERROR: install-agent-shims.sh BIN_DIR no longer pins ~/.devide/agent-shims" >&2
  exit 1
fi
if ! grep -q '@default_bin_dir "~/.devide/agent-shims"' lib/dev_ide/agents/agent_shims.ex; then
  echo "ERROR: AgentShims @default_bin_dir no longer pins ~/.devide/agent-shims" >&2
  exit 1
fi

log "test hygiene: reject fixed-port :gen_tcp.listen in test/"
# The required gate runs on the shared devbox, where a hard-coded TCP port is
# often already held by a live workload — a fixed-port listener :eaddrinuse's
# and reds the whole 20-min gate (isolated hosted runner has the port free, so
# it silently passes there). Bind ephemerally with :gen_tcp.listen(0, ...) and
# read the assigned port via :inet.sockname/1. (Bandit/ThousandIsland listeners
# that must use an allow-listed port should probe with :gen_tcp first, as
# preview_proxy_controller_test's start_ws_echo_upstream! does.)
if fixed_ports="$(grep -rnE ':gen_tcp\.listen\(\s*[1-9][0-9]*' test/ 2>/dev/null)"; then
  echo "ERROR: test/ binds a fixed TCP port; use :gen_tcp.listen(0, ...) + :inet.sockname/1:" >&2
  echo "${fixed_ports}" >&2
  exit 1
fi

log "linting JS hooks"
(
  cd assets
  # Skip the (slow) `npm ci` when package-lock.json is unchanged since the last
  # successful install — a sha256 stamp inside node_modules records what was
  # installed. Benefits the local hook and the self-hosted runner, which now
  # persists node_modules across runs (checkout clean:false). npm ci wipes
  # node_modules, so the stamp is written *after* it succeeds.
  stamp="node_modules/.package-lock.sha256"
  want="$(sha256sum package-lock.json | awk '{print $1}')"
  if [[ -d node_modules && -f "${stamp}" && "$(cat "${stamp}")" == "${want}" ]]; then
    log "node_modules up to date (package-lock.json unchanged) — skipping npm ci"
  else
    NODE_ENV=development npm ci --include=dev
    printf '%s\n' "${want}" >"${stamp}"
  fi
  NODE_ENV=development npm run lint
  NODE_ENV=development npm test
)

log "fetching Elixir dependencies"
"${MIX[@]}" deps.get

# precommit.ci also runs ./scripts/check-deploy-sync.sh (via the mix.exs alias),
# so it is not invoked standalone here — deploy-devbox.yml relies on the alias too.
log "running read-only precommit checks"
"${MIX[@]}" precommit.ci

log "checking doc citations resolve (docs/subsystems, docs/reference)"
./scripts/check-doc-citations.sh

log "checking preview stays out of the core SCC (extraction guard, PRs #301-#303)"
MIX="${MIX[*]}" ./scripts/check-scc-guard.sh

if [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
  preview_json="$(
    bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true
  )"
  if [[ -n "$preview_json" ]]; then
    log "optional tidewave smoke check (${preview_json})"
    status="$(curl -fsS -o /dev/null -w '%{http_code}' \
      -H "content-type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      "$preview_json" 2>/dev/null || echo 000)"
    if [[ "$status" == "200" ]]; then
      log "tidewave MCP initialize → 200"
    else
      log "warn: tidewave MCP initialize → ${status} (preview env may still be booting)"
    fi
  fi
fi

log "pre-push checks passed"
