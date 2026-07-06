#!/usr/bin/env bash
#
# Install DevIDE agent shims on PATH (~/.local/bin).
# Typing grok/claude/codex/opencode/agent anywhere on the devbox automatically
# injects Terminal + Preview MCP.  clauded stays a shell alias (see ~/.bashrc).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
REAL_DIR="${HOME}/.devide/real-bins"
NPM_PREFIX="${DEV_IDE_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
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

path_without_shims() {
  local IFS=':'
  local part out=()
  for part in ${PATH:-/usr/bin:/bin}; do
    [[ "$part" == "$BIN_DIR" ]] && continue
    out+=("$part")
  done
  (IFS=:; printf '%s' "${out[*]}")
}

is_devide_shim() {
  local path="$1"
  [[ -f "$path" ]] && grep -q 'devide" agent launch' "$path" 2>/dev/null
}

npm_package_bin() {
  local name="$1"
  local candidate

  case "$name" in
    claude)
      for candidate in \
        "${NPM_PREFIX}/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
        "${NPM_PREFIX}/lib/node_modules/@anthropic-ai/claude-code/bin/claude.js" \
        "${NPM_PREFIX}/lib/node_modules/@anthropic-ai/claude-code/bin/claude" \
        "${HOME}/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
        "${HOME}/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.js" \
        "${HOME}/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude"; do
        if [[ -f "$candidate" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
      ;;
    codex)
      for candidate in \
        "${NPM_PREFIX}/lib/node_modules/@openai/codex/bin/codex.js" \
        "${NPM_PREFIX}/lib/node_modules/@openai/codex/bin/codex" \
        "${HOME}/.local/lib/node_modules/@openai/codex/bin/codex.js" \
        "${HOME}/.local/lib/node_modules/@openai/codex/bin/codex"; do
        if [[ -f "$candidate" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
      ;;
  esac

  return 1
}

record_real_bin() {
  local name="$1"
  local real=""
  local resolved=""
  local bin_dir_resolved=""

  case "$name" in
    claude|codex)
      if real="$(npm_package_bin "$name")"; then
        ln -sf "$real" "${REAL_DIR}/${name}"
        return 0
      fi
      ;;
  esac

  real="$(PATH="$(path_without_shims)" command -v "$name" 2>/dev/null || true)"

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

  if real="$(npm_package_bin "$name")"; then
    ln -sf "$real" "${REAL_DIR}/${name}"
    return 0
  fi

  return 1
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

echo "Installed DevIDE agent shims in ${BIN_DIR}: ${RUNTIMES[*]}"
echo "npm global prefix: ${NPM_PREFIX}"
echo "Real binaries recorded under ${REAL_DIR}:"
ls -la "${REAL_DIR}" 2>/dev/null || true
