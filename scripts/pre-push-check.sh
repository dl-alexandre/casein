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
# Report the verdict to Casein as a durable gate.passed / gate.failed audit
# row via the terminal MCP gate_report tool (the agent_worktree_report_mcp
# pattern in scripts/lib/agent-worktree.sh). Reporting must NEVER fail the
# gate: it is skipped silently without the workspace env, curls with a short
# timeout, and swallows every error.
GATE_STARTED_AT="$(date +%s)"

report_gate_result() {
  local exit_code="$1"
  [[ -n "${CASEIN_API_TOKEN:-}" && -n "${CASEIN_WORKSPACE_ID:-}" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local mcp_url="${CASEIN_TERMINAL_MCP_URL:-${CASEIN_URL:-http://127.0.0.1:4000}/api/terminals/mcp}"
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
    "workspace_id": os.environ["CASEIN_WORKSPACE_ID"],
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
    -H "authorization: Bearer ${CASEIN_API_TOKEN}" \
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
# before paying for npm, compile (zigler/NIF), and the test suite. ---
# When CASEIN_GATE_SKIP_* is set (pr-gate fail-fast phase already green), skip
# only the identical check — never drop a check from the set (#818).

run_or_skip() {
  local token="$1"
  shift
  local var="CASEIN_GATE_SKIP_${token}"
  if [[ "${!var:-}" == "1" ]]; then
    log "${token} already verified (CASEIN_GATE_SKIP_${token}=1) — skip"
    return 0
  fi
  "$@"
}

log "checking staged/worktree whitespace"
git diff --check

log "checking deploy script syntax"
bash -n scripts/deploy-devbox-release.sh
bash -n scripts/deploy-poller.sh
bash -n scripts/build-release.sh
bash -n scripts/lib/canary-drain.sh
bash -n scripts/lib/caddy-upstream.sh
# Companion signing helpers (#416) — syntax only here; fixture content below.
bash -n scripts/verify-companion-signing-contract.sh
bash -n scripts/verify-companion-external-prereqs.sh
bash -n scripts/verify-companion-fixtures.sh

# Pure shell/static guards — no Mix, no compile.
log "checking HEEx boolean data-/aria- attrs (#163)"
run_or_skip HEEX_BOOL ./scripts/check-heex-boolean-attr-guard.sh

log "checking portable product defaults stay host-agnostic (#248)"
run_or_skip PORTABLE ./scripts/check-portable-defaults-guard.sh

log "checking npm install paths run audit (#929)"
run_or_skip NPM_AUDIT_GUARD ./scripts/check-npm-audit-guard.sh

log "checking doc citations resolve (docs/subsystems, docs/reference)"
run_or_skip DOC_CITATIONS ./scripts/check-doc-citations.sh

log "running hermetic shell unit tests (scoped-token validation/durability)"
bash scripts/test-scoped-token-durability.sh

log "running hermetic shell unit tests (agent shim install/resolution/passthrough)"
bash scripts/test-agent-shims.sh

log "running hermetic shell unit tests (canary drain/stop decisions)"
bash scripts/test-canary-drain.sh

log "running hermetic shell unit tests (canonical Caddy upstream repair)"
bash scripts/test-caddy-upstream.sh

log "running hermetic shell unit tests (preview router reap/rebind)"
bash scripts/test-preview-router-reap.sh

log "running hermetic shell unit tests (preview router generated Caddyfile scheme)"
bash scripts/test-preview-router.sh

log "running hermetic shell unit tests (release extraction cleanup)"
bash scripts/test-build-release-extraction.sh

log "running hermetic shell unit tests (bare agent-worktree primary resolve)"
bash scripts/test-agent-worktree-bare.sh

log "running hermetic shell unit tests (spawn worker cross-session env isolation)"
bash scripts/test-spawn-worker-env-resolve.sh

# Companion Mob synthetic fixtures only (#416) — never real profiles/devices.
log "checking companion signing fixtures are synthetic (#416)"
run_or_skip COMPANION_FIXTURES bash scripts/verify-companion-fixtures.sh

log "shellcheck (warning+) on agent shim/launch scripts"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning -x \
    scripts/casein \
    scripts/install-agent-shims.sh \
    scripts/launch-casein-agent.sh \
    scripts/lib/real-agent-bin.sh \
    scripts/lib/agent-doctor.sh \
    scripts/lib/agent-auth-profile.sh \
    scripts/lib/agent-auth-login.sh \
    scripts/lib/agent-identity.sh \
    scripts/migrate-gh-auth-profiles.sh \
    scripts/ensure-gh-shell-identity.sh \
    scripts/lib/canary-drain.sh \
    scripts/lib/caddy-upstream.sh \
    scripts/lib/preview-router-reap.sh \
    scripts/lib/agent-worktree.sh \
    scripts/test-canary-drain.sh \
    scripts/test-caddy-upstream.sh \
    scripts/test-preview-router-reap.sh \
    scripts/test-preview-router.sh \
    scripts/test-build-release-extraction.sh \
    scripts/test-agent-shims.sh \
    scripts/test-agent-worktree-bare.sh \
    scripts/test-spawn-worker-env-resolve.sh \
    scripts/spawn-agent-worker.sh
else
  log "shellcheck not installed — skipping (GitHub-hosted CI runners have it)"
fi

log "boundary: agent launcher shims must never target ~/.local/bin again"
# The shims moved to ~/.casein/agent-shims so plain terminals stay untouched
# by Casein (operator call, 2026-07-13). Pin the installer's target dir and
# the Elixir default; a regression here silently re-hijacks agent names
# machine-wide.
if ! grep -q 'BIN_DIR="\${CASEIN_AGENT_BIN_DIR:-\${HOME}/.casein/agent-shims}"' scripts/install-agent-shims.sh; then
  echo "ERROR: install-agent-shims.sh BIN_DIR no longer pins ~/.casein/agent-shims" >&2
  exit 1
fi
if ! grep -q '@default_bin_dir "~/.casein/agent-shims"' lib/casein/agents/agent_shims.ex; then
  echo "ERROR: AgentShims @default_bin_dir no longer pins ~/.casein/agent-shims" >&2
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
  # `npm` here is whatever is on PATH — .tool-versions pins erlang/elixir only.
  # jsdom >= 30 needs node >= 22.22.2; on node 20 its undici blows up with a
  # bare "webidl.util.markAsUncloneable is not a function" from seven terminal
  # test files, which reads like a test bug rather than a toolchain mismatch.
  # Say so plainly instead. CI pins node via setup-node in pr-gate.yml.
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  if ((node_major < 22)); then
    echo "ERROR: node $(node -v) is too old — assets/ requires node >= 22.22.2 (jsdom 30)." >&2
    echo "       Try: mise exec node@22 -- bash scripts/pre-push-check.sh" >&2
    exit 1
  fi

  # #929: --no-audit on install is for speed. Scan lockfiles separately.
  log "auditing npm lockfiles (#929)"
  run_or_skip NPM_AUDIT ./scripts/npm-audit.sh

  # Skip the (slow) `npm ci` when package-lock.json is unchanged since the last
  # successful install — a sha256 stamp inside node_modules records what was
  # installed. Benefits the local hook and the self-hosted runner, which now
  # persists node_modules across runs (checkout clean:false). npm ci wipes
  # node_modules, so the stamp is written *after* it succeeds.
  ensure_npm_ci() {
    local dir="$1"
    shift
    local stamp want
    (
      cd "${dir}"
      stamp="node_modules/.package-lock.sha256"
      want="$(sha256sum package-lock.json | awk '{print $1}')"
      if [[ -d node_modules && -f "${stamp}" && "$(cat "${stamp}")" == "${want}" ]]; then
        log "${dir}/node_modules up to date (package-lock.json unchanged) — skipping npm ci"
      else
        log "npm ci in ${dir}"
        NODE_ENV=development npm ci "$@"
        printf '%s\n' "${want}" >"${stamp}"
      fi
    )
  }

  ensure_npm_ci assets --include=dev
  # assets/test/preview_bridge_file_page.test.mjs drives
  # scripts/verify_preview_bridge_file_page.mjs, which resolves playwright from
  # priv/scripts/node_modules (not assets/). A clean poller/deploy worktree that
  # only npm-ci'd assets fails test 121 with exit 2 / "playwright not found"
  # while CI stays green on a runner that still has priv/scripts node_modules
  # from prior clean:false checkouts. Install both trees before npm test.
  ensure_npm_ci priv/scripts

  cd assets
  NODE_ENV=development npm run lint
  NODE_ENV=development npm test
)

log "testing preview-ui-walk driver, schema, and packed payload"
node .claude/skills/preview-ui-walk/references/selftest.mjs

log "fetching Elixir dependencies"
"${MIX[@]}" deps.get

# Format needs deps (phoenix_live_view HTMLFormatter plugin) but NOT project
# compile / zigler NIF. Run immediately after deps.get and BEFORE native tests
# and precommit.ci so format-only reds never burn a compile (#818).
log "checking mix format (before compile)"
run_or_skip FORMAT "${MIX[@]}" format --check-formatted

# precommit.ci repeats format/heex/portable for standalone `mix precommit.ci`
# callers; after this script already verified them, skip the duplicates only.
export CASEIN_GATE_SKIP_FORMAT=1
export CASEIN_GATE_SKIP_HEEX_BOOL=1
export CASEIN_GATE_SKIP_PORTABLE=1
export CASEIN_GATE_SKIP_DOC_CITATIONS=1
export CASEIN_GATE_SKIP_NPM_AUDIT_GUARD=1
export CASEIN_GATE_SKIP_NPM_AUDIT=1

log "checking native plugin supply-chain signatures and committed manifest"
(
  # The deploy poller shares MIX_DEPS_PATH across clean root builds. Running
  # the nested app against that same directory rewrites it to the native lock
  # set, so the later root precommit sees lock mismatches. Keep a persistent,
  # deterministic sibling cache for the native app; without an inherited
  # cache, leave MIX_DEPS_PATH unset so Mix uses native/casein_mob/deps.
  if [[ -n "${MIX_DEPS_PATH:-}" ]]; then
    native_mix_deps_path="${MIX_DEPS_PATH%/}-casein-mob"
    if [[ "${native_mix_deps_path}" != /* ]]; then
      native_mix_deps_path="${ROOT}/${native_mix_deps_path}"
    fi
    export MIX_DEPS_PATH="${native_mix_deps_path}"
  else
    unset MIX_DEPS_PATH
  fi

  cd native/casein_mob
  "${MIX[@]}" deps.get
  "${MIX[@]}" test test/casein_mob/plugin_supply_chain_test.exs \
    test/casein_mob/mob_dev_native_deploy_contract_test.exs \
    test/casein_mob/android_cmake_zig_fallback_test.exs
  "${MIX[@]}" mob.regen_plugin_manifest --check
)

# precommit.ci owns the complete read-only Elixir gate used by deploy-devbox.yml.
# It re-orders format/heex/portable before compile (#818) and honours
# CASEIN_GATE_SKIP_* so the fail-fast phase does not double-run those checks.
# HEEx/portable/format also run above for local pre-push fail-fast; when skipped
# here they already passed. Vendor pin + config-seam still run inside precommit.ci
# (and again below for SCC/vendor where pre-push historically duplicated them).
log "running read-only precommit checks"
"${MIX[@]}" precommit.ci

log "checking preview stays out of the core SCC (extraction guard, PRs #301-#303)"
MIX="${MIX[*]}" ./scripts/check-scc-guard.sh

log "checking vendored Ghostty matches its pinned artifact hash"
MIX="${MIX[*]}" ./scripts/check-vendor-pin-guard.sh

log "checking config-seam module-literal defaults stay out of xref cycles (#347/#348)"
MIX="${MIX[*]}" ./scripts/check-config-seam-guard.sh

log "checking preview modules reach core only through the deps seam (#982, soft canary)"
MIX="${MIX[*]}" ./scripts/check-layering-guard.sh

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
