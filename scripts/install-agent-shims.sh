#!/usr/bin/env bash
#
# Install DevIDE agent launcher shims into ~/.devide/agent-shims.
# The dir is only put on PATH inside DevIDE contexts (pane env, shell
# integration, agent env files) — plain terminals resolve grok/claude/codex/
# opencode/agent straight to the real binaries with zero DevIDE footprint.
# Inside DevIDE, typing an agent name injects Terminal + Preview MCP.
# clauded stays a shell alias (see ~/.bashrc); palette/MCP launches map
# clauded → claude (see PaneEnv.launch_command/3).
#
# Usage:
#   bash scripts/install-agent-shims.sh           # install + verify
#   bash scripts/install-agent-shims.sh --check   # exit 0 only if complete
#   bash scripts/install-agent-shims.sh --ensure  # install only when incomplete
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"

BIN_DIR="${DEV_IDE_AGENT_BIN_DIR:-${HOME}/.devide/agent-shims}"
# Pre-migration shim home; runtime shims found here get cleaned up so plain
# terminals stop resolving agent names to DevIDE launchers.
LEGACY_BIN_DIR="${HOME}/.local/bin"
REAL_DIR="${HOME}/.devide/real-bins"
export DEV_IDE_NPM_PREFIX="${DEV_IDE_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
NPM_PREFIX="${DEV_IDE_NPM_PREFIX}"
DEVIDE_CLI="${ROOT}/scripts/devide"
# clauded is a bash alias → claude --dangerously-skip-permissions; do not shim it.
RUNTIMES=(grok claude codex opencode agent)
MODE="install"

usage() {
  cat <<'EOF'
Usage: install-agent-shims.sh [--check | --ensure | --install]

  --install  (default) rewrite shims, record real bins, verify PATH precedence
  --check    exit 0 if every runtime shim is present and executable; else 1
  --ensure   run --install only when --check would fail
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --ensure) MODE="ensure"; shift ;;
    --install) MODE="install"; shift ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

shims_complete() {
  local name
  for name in "${RUNTIMES[@]}" devide; do
    if [[ ! -x "${BIN_DIR}/${name}" ]]; then
      return 1
    fi
  done
  return 0
}

missing_shims() {
  local name
  for name in "${RUNTIMES[@]}" devide; do
    if [[ ! -x "${BIN_DIR}/${name}" ]]; then
      printf '%s\n' "$name"
    fi
  done
}

if [[ "$MODE" == "check" ]]; then
  if shims_complete; then
    echo "OK: agent shims complete in ${BIN_DIR}: ${RUNTIMES[*]} devide"
    exit 0
  fi
  echo "error: incomplete agent shims in ${BIN_DIR}:" >&2
  missing_shims | sed 's/^/  - /' >&2
  echo "error: run: bash scripts/install-agent-shims.sh" >&2
  exit 1
fi

if [[ "$MODE" == "ensure" ]] && shims_complete; then
  echo "OK: agent shims already complete in ${BIN_DIR}"
  exit 0
fi

mkdir -p "$BIN_DIR" "$REAL_DIR" "${NPM_PREFIX}/bin"

if [[ ! -x "$DEVIDE_CLI" ]]; then
  echo "error: missing executable ${DEVIDE_CLI}" >&2
  exit 1
fi

ln -sf "$DEVIDE_CLI" "${BIN_DIR}/devide"
# The devide CLI itself is a plain command, not an interceptor — keep a
# convenience symlink in ~/.local/bin so `devide agent doctor` etc. work from
# any terminal. This is the only thing DevIDE still places there.
if [[ -d "$LEGACY_BIN_DIR" ]]; then
  ln -sf "$DEVIDE_CLI" "${LEGACY_BIN_DIR}/devide"
fi

# Repointing the npm global prefix redirects ALL of the user's `npm -g`
# installs — a boundary violation on personal machines. Auto-on only for
# DevIDE-managed hosts (marked by /etc/devide/devide.env);
# DEV_IDE_MANAGE_NPM_PREFIX=1/0 overrides in either direction.
manage_npm_prefix() {
  case "${DEV_IDE_MANAGE_NPM_PREFIX:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [[ -f /etc/devide/devide.env ]]
}

ensure_npm_prefix() {
  local current

  if ! manage_npm_prefix; then
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    return 0
  fi

  current="$(npm config get prefix 2>/dev/null || true)"
  if [[ "$current" != "$NPM_PREFIX" ]]; then
    npm config set prefix "$NPM_PREFIX" >/dev/null
  fi
}

ensure_npm_prefix

record_real_bin() {
  local name="$1"
  local real=""
  local resolved=""
  local bin_dir_resolved=""

  case "$name" in
    claude|codex)
      if real="$(real_agent_npm_candidate "$name")"; then
        ln -sf "$real" "${REAL_DIR}/${name}"
        return 0
      fi
      ;;
  esac

  real="$(PATH="$(real_agent_bin_path_without_shims)" command -v "$name" 2>/dev/null || true)"

  if [[ -n "$real" ]] && ! is_devide_shim "$real"; then
    resolved="$(readlink -f "$real" 2>/dev/null || printf '%s' "$real")"
    bin_dir_resolved="$(readlink -f "$BIN_DIR" 2>/dev/null || printf '%s' "$BIN_DIR")"
    # Never point real-bins at BIN_DIR — shims overwrite those paths next.
    case "$resolved" in
      "${bin_dir_resolved}" | "${bin_dir_resolved}/"*) ;;
      *)
        ln -sf "$resolved" "${REAL_DIR}/${name}"
        return 0
        ;;
    esac
  fi

  if real="$(real_agent_npm_candidate "$name")"; then
    ln -sf "$real" "${REAL_DIR}/${name}"
    return 0
  fi

  return 1
}

# DevIDE contexts (pane env, shell integration, agent env files) put BIN_DIR
# at the FRONT of PATH. Verify resolution with that layout so a broken shim
# (unreadable, wrong target, PATH parse surprise) fails loudly at install time
# rather than as a silent unpaired launch later.
verify_shim_precedence() {
  local name resolved resolved_target shim_target shadowed=0

  PATH="${BIN_DIR}:${PATH:-}"
  export PATH
  hash -r
  for name in "${RUNTIMES[@]}"; do
    resolved="$(command -v "$name" 2>/dev/null || true)"
    resolved_target="$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")"
    shim_target="$(readlink -f "${BIN_DIR}/${name}" 2>/dev/null || printf '%s' "${BIN_DIR}/${name}")"
    if [[ -z "$resolved" || "$resolved_target" != "$shim_target" ]]; then
      echo "error: '${name}' resolves to '${resolved:-nothing}' instead of the DevIDE shim ${BIN_DIR}/${name}" >&2
      shadowed=1
    fi
  done

  if [[ "$shadowed" == "1" ]]; then
    echo "error: shim resolution broken — agents launched by name inside DevIDE will skip MCP injection." >&2
    echo "error: inspect ${BIN_DIR}, then re-run this installer." >&2
    return 1
  fi
}

# Migration: earlier installs put runtime shims directly in ~/.local/bin,
# which made agent names resolve to DevIDE launchers in every terminal on the
# box. Remove ours (marker-checked — never a user's real binary) so plain
# terminals go back to the real agents.
cleanup_legacy_shims() {
  local name removed=""
  for name in "${RUNTIMES[@]}" clauded; do
    if is_devide_shim "${LEGACY_BIN_DIR}/${name}"; then
      rm -f "${LEGACY_BIN_DIR}/${name}"
      removed="${removed} ${name}"
    fi
  done
  if [[ -n "$removed" ]]; then
    echo "Removed legacy DevIDE shims from ${LEGACY_BIN_DIR}:${removed}"
  fi
}

install_shim() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${DEVIDE_CLI}" agent launch ${name} "\$@"
EOF
  chmod +x "$tmp"
  mv -f "$tmp" "${BIN_DIR}/${name}"
}

# Record real binaries BEFORE overwriting PATH entries with shims.
for runtime in "${RUNTIMES[@]}"; do
  record_real_bin "$runtime" || true
done

for runtime in "${RUNTIMES[@]}"; do
  install_shim "$runtime"
done

# clauded must remain a shell alias — remove a stale shim if a prior run added one.
rm -f "${BIN_DIR}/clauded"

cleanup_legacy_shims

# Partial installs (interrupted deploys, npm clobbering a single name) used to
# leave e.g. grok present but claude missing. Fail closed if any shim is gone.
if ! shims_complete; then
  echo "error: install finished but shims are incomplete in ${BIN_DIR}:" >&2
  missing_shims | sed 's/^/  - /' >&2
  exit 1
fi

verify_shim_precedence

echo "Installed DevIDE agent shims in ${BIN_DIR}: ${RUNTIMES[*]}"
echo "npm global prefix: ${NPM_PREFIX}"
echo "Real binaries recorded under ${REAL_DIR}:"
ls -la "${REAL_DIR}" 2>/dev/null || true
