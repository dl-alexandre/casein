#!/usr/bin/env bash
#
# Regression coverage for DevIDE agent shim installation/resolution.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
}

assert_not_under() {
  local label="$1" path="$2" parent="$3"
  case "$path" in
    "$parent" | "$parent"/*)
      echo "FAIL: ${label}: ${path} should not be under ${parent}" >&2
      exit 1
      ;;
  esac
}

write_executable() {
  local path="$1"
  local body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
  chmod +x "$path"
}

run_installer_rejects_bin_dir_candidate() (
  echo "== install-agent-shims rejects candidates under ~/.local/bin =="

  local home bin_dir package_claude target
  home="$(mktemp -d)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  bin_dir="${HOME}/.local/bin"
  package_claude="${HOME}/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude"

  write_executable "${bin_dir}/claude" "#!/usr/bin/env bash
echo stale-bin-dir-claude"
  write_executable "$package_claude" "#!/usr/bin/env bash
echo package-claude"

  # The trailing slash used to bypass the BIN_DIR guard and record the soon-to-be
  # overwritten shim path as the "real" binary.
  PATH="${bin_dir}/:${PATH:-/usr/bin:/bin}" bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null

  target="$(readlink -f "${HOME}/.devide/real-bins/claude")"
  assert_eq "recorded claude target" "$package_claude" "$target"
  assert_not_under "recorded claude target" "$target" "$bin_dir"
)

run_resolver_rejects_recorded_devide_shim() (
  echo "== real-agent-bin rejects recorded DevIDE shims =="

  local home real_dir real_codex resolved
  home="$(mktemp -d)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  real_dir="${home}/real-bin-dir"
  real_codex="${real_dir}/codex"

  write_executable "${HOME}/.devide/real-bins/codex" "#!/usr/bin/env bash
exec \"${ROOT}/scripts/devide\" agent launch codex \"\$@\""
  write_executable "$real_codex" "#!/usr/bin/env bash
echo real-codex"

  # shellcheck source=scripts/lib/real-agent-bin.sh
  source "${ROOT}/scripts/lib/real-agent-bin.sh"

  export PATH="${HOME}/.local/bin:${real_dir}:${PATH:-/usr/bin:/bin}"
  resolved="$(real_agent_bin codex)"
  assert_eq "resolved codex binary" "$real_codex" "$resolved"
)

main() {
  run_installer_rejects_bin_dir_candidate
  run_resolver_rejects_recorded_devide_shim
  echo "OK: agent shim checks passed"
}

main "$@"
