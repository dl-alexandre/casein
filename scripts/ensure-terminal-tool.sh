#!/usr/bin/env bash
#
# Ensure a DevIDE-supported terminal tool is available without prompting.
#
# Usage:
#   bash scripts/ensure-terminal-tool.sh elio
#   bash scripts/ensure-terminal-tool.sh --check elio
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ensure-terminal-tool.sh [--check] [--yes] <tool>

Supported tools:
  elio    Install the crates.io package with cargo into ~/.devide/tools

Environment:
  CASEIN_TERMINAL_TOOLS_DIR   Override the DevIDE tool root
  CASEIN_TERMINAL_SHIMS_DIR   Override the DevIDE terminal shim dir
  CASEIN_TERMINAL_INSTALL_LOCK_TIMEOUT_SECONDS
                               Seconds to wait for another install; default 600
EOF
}

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --yes|-y)
      # Non-interactive is already the default. Accept the flag for callers.
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      break
      ;;
  esac
done

TOOL="${1:-}"
if [[ -z "$TOOL" ]]; then
  echo "error: missing tool name" >&2
  usage >&2
  exit 64
fi

TOOL_ROOT="${CASEIN_TERMINAL_TOOLS_DIR:-${HOME}/.devide/tools}"
TOOL_BIN="${TOOL_ROOT}/bin"
SHIM_DIR="${CASEIN_TERMINAL_SHIMS_DIR:-${HOME}/.devide/terminal-shims}"
LOCK_TIMEOUT_SECONDS="${CASEIN_TERMINAL_INSTALL_LOCK_TIMEOUT_SECONDS:-600}"
INSTALL_LOCK_DIR=""

path_without_terminal_shims() {
  local IFS=':'
  local part
  local out=()

  for part in ${PATH:-/usr/local/bin:/usr/bin:/bin}; do
    [[ -z "$part" ]] && continue
    [[ "$part" == "$SHIM_DIR" ]] && continue
    out+=("$part")
  done

  (IFS=:; printf '%s' "${out[*]}")
}

real_tool_bin() {
  PATH="$(path_without_terminal_shims)" command -v "$1" 2>/dev/null || true
}

managed_bin() {
  local bin="$1"
  if [[ -x "${TOOL_BIN}/${bin}" ]]; then
    printf '%s\n' "${TOOL_BIN}/${bin}"
    return 0
  fi
  return 1
}

already_available() {
  local tool="$1"
  local bin="$2"
  local existing

  if existing="$(managed_bin "$bin")"; then
    echo "DevIDE: terminal tool '${tool}' already installed at ${existing}" >&2
    return 0
  fi

  existing="$(real_tool_bin "$tool")"
  if [[ -n "$existing" ]]; then
    echo "DevIDE: terminal tool '${tool}' already available at ${existing}" >&2
    return 0
  fi

  return 1
}

cargo_cmd=()
resolve_cargo() {
  if command -v cargo >/dev/null 2>&1; then
    cargo_cmd=(cargo)
  elif command -v mise >/dev/null 2>&1; then
    cargo_cmd=(mise exec -y rust@stable -- cargo)
  else
    echo "DevIDE: cannot install ${TOOL}; cargo is not installed and mise is unavailable." >&2
    exit 127
  fi
}

with_install_lock() {
  local tool="$1"
  local bin="$2"
  shift 2
  local lock_dir="${TOOL_ROOT}/.${tool}-install.lock"

  mkdir -p "$TOOL_ROOT" "$TOOL_BIN"

  if mkdir "$lock_dir" 2>/dev/null; then
    INSTALL_LOCK_DIR="$lock_dir"
    trap 'rm -rf "${INSTALL_LOCK_DIR:-}"' EXIT

    if already_available "$tool" "$bin"; then
      return 0
    fi

    if "$@"; then
      return 0
    else
      return $?
    fi
  fi

  echo "DevIDE: terminal tool '${tool}' is already being installed; waiting..." >&2
  local deadline=$((SECONDS + LOCK_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if already_available "$tool" "$bin"; then
      return 0
    fi

    if [[ ! -d "$lock_dir" ]]; then
      if mkdir "$lock_dir" 2>/dev/null; then
        INSTALL_LOCK_DIR="$lock_dir"
        trap 'rm -rf "${INSTALL_LOCK_DIR:-}"' EXIT

        if already_available "$tool" "$bin"; then
          return 0
        fi

        if "$@"; then
          return 0
        else
          return $?
        fi
      fi
    fi

    sleep 1
  done

  echo "DevIDE: timed out waiting for terminal tool '${tool}' install lock at ${lock_dir}" >&2
  return 75
}

install_cargo_package() {
  local tool="$1"
  local package="$2"
  local bin="$3"
  local tmp_root=""
  local tmp_bin=""

  resolve_cargo

  tmp_root="$(mktemp -d "${TOOL_ROOT}/.install-${tool}.XXXXXX")"
  tmp_bin="${TOOL_BIN}/.${bin}.$$"

  echo "DevIDE: provisioning terminal tool '${tool}' via cargo package '${package}'." >&2
  echo "DevIDE: cargo output follows; first install can take a few minutes." >&2
  if ! "${cargo_cmd[@]}" install --root "$tmp_root" "$package"; then
    rm -rf "$tmp_root"
    rm -f "$tmp_bin"
    echo "DevIDE: failed to provision terminal tool '${tool}'." >&2
    return 1
  fi

  if [[ ! -x "${tmp_root}/bin/${bin}" ]]; then
    echo "DevIDE: cargo install finished, but ${tmp_root}/bin/${bin} is missing or not executable." >&2
    rm -rf "$tmp_root"
    rm -f "$tmp_bin"
    return 127
  fi

  if ! cp "${tmp_root}/bin/${bin}" "$tmp_bin" || ! chmod +x "$tmp_bin" || ! mv -f "$tmp_bin" "${TOOL_BIN}/${bin}"; then
    rm -rf "$tmp_root"
    rm -f "$tmp_bin"
    echo "DevIDE: failed to publish terminal tool '${tool}' into ${TOOL_BIN}." >&2
    return 1
  fi

  rm -rf "$tmp_root"
  rm -f "$tmp_bin"
  echo "DevIDE: provisioned terminal tool '${tool}' at ${TOOL_BIN}/${bin}" >&2
}

ensure_cargo_package() {
  local tool="$1"
  local package="$2"
  local bin="$3"

  mkdir -p "$TOOL_BIN"

  if already_available "$tool" "$bin"; then
    exit 0
  fi

  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "DevIDE: ${tool} is not installed" >&2
    exit 1
  fi

  with_install_lock "$tool" "$bin" install_cargo_package "$tool" "$package" "$bin"

  if [[ ! -x "${TOOL_BIN}/${bin}" ]]; then
    echo "DevIDE: cargo install finished, but ${TOOL_BIN}/${bin} is missing or not executable." >&2
    exit 127
  fi
}

case "$TOOL" in
  elio)
    ensure_cargo_package "elio" "elio" "elio"
    ;;
  *)
    echo "error: unsupported DevIDE terminal tool: ${TOOL}" >&2
    usage >&2
    exit 64
    ;;
esac
