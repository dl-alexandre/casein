#!/usr/bin/env bash
#
# Install DevIDE agent shims on PATH (~/.local/bin).
# Typing grok/claude/codex/opencode/agent anywhere on the devbox automatically
# injects Terminal + Preview MCP.  clauded stays a shell alias (see ~/.bashrc).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"

BIN_DIR="${HOME}/.local/bin"
REAL_DIR="${HOME}/.devide/real-bins"
export DEV_IDE_NPM_PREFIX="${DEV_IDE_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
NPM_PREFIX="${DEV_IDE_NPM_PREFIX}"
DEVIDE_CLI="${ROOT}/scripts/devide"
# clauded is a bash alias → claude --dangerously-skip-permissions; do not shim it.
RUNTIMES=(grok claude codex opencode agent)

mkdir -p "$BIN_DIR" "$REAL_DIR" "${NPM_PREFIX}/bin"

if [[ ! -x "$DEVIDE_CLI" ]]; then
  echo "error: missing executable ${DEVIDE_CLI}" >&2
  exit 1
fi

ln -sf "$DEVIDE_CLI" "${BIN_DIR}/devide"

ensure_npm_prefix() {
  local current

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

path_contains_bin_dir() {
  local IFS=':'
  local part resolved bin_dir_resolved
  bin_dir_resolved="$(readlink -f "$BIN_DIR" 2>/dev/null || printf '%s' "$BIN_DIR")"
  for part in ${PATH:-}; do
    [[ -z "$part" ]] && continue
    resolved="$(readlink -f "$part" 2>/dev/null || printf '%s' "$part")"
    [[ "$resolved" == "$bin_dir_resolved" ]] && return 0
  done
  return 1
}

# The whole design depends on BIN_DIR preceding any directory that carries a
# real agent binary. If PATH order defeats the shims, agents launch without
# MCP injection and nothing else ever reports it — so make it loud here.
# Non-interactive callers (systemd units, deploy poller) run with a minimal
# PATH that omits BIN_DIR; prepend it for this check so deploy logs still
# catch shadowing without requiring the caller's environment to match tmux.
verify_shim_precedence() {
  local name resolved resolved_target shim_target shadowed=0

  if ! path_contains_bin_dir; then
    PATH="${BIN_DIR}:${PATH:-}"
    export PATH
    hash -r
  fi
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
    echo "error: PATH order defeats the DevIDE shims — agents launched by name will skip MCP injection." >&2
    echo "error: move ${BIN_DIR} ahead of the shadowing directory on PATH, then re-run this installer." >&2
    return 1
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

verify_shim_precedence

echo "Installed DevIDE agent shims in ${BIN_DIR}: ${RUNTIMES[*]}"
echo "npm global prefix: ${NPM_PREFIX}"
echo "Real binaries recorded under ${REAL_DIR}:"
ls -la "${REAL_DIR}" 2>/dev/null || true
