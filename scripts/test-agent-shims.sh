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
  unset DEV_IDE_NPM_PREFIX
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
  unset DEV_IDE_NPM_PREFIX
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

run_installer_generated_shims_carry_marker() (
  echo "== installer-generated shims are detected by is_devide_shim =="

  local home name
  home="$(mktemp -d)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset DEV_IDE_NPM_PREFIX

  PATH="${HOME}/.local/bin:${PATH:-/usr/bin:/bin}" \
    bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null

  # shellcheck source=scripts/lib/real-agent-bin.sh
  source "${ROOT}/scripts/lib/real-agent-bin.sh"

  # The shim template (installer) and the marker grep (real-agent-bin.sh)
  # live in different files; this pins their coupling.
  for name in grok claude codex opencode agent; do
    if ! is_devide_shim "${HOME}/.local/bin/${name}"; then
      echo "FAIL: installed shim not detected as a DevIDE shim: ${name}" >&2
      exit 1
    fi
  done

  # agent-doctor.sh extracts the embedded devide CLI path with this sed
  # pattern; pin it against the installer's shim template.
  local embedded
  embedded="$(sed -n 's/^exec "\(.*\)" agent launch .*/\1/p' "${HOME}/.local/bin/claude" | head -n 1)"
  assert_eq "embedded devide CLI path" "${ROOT}/scripts/devide" "$embedded"
)

run_installer_fails_when_shims_shadowed() (
  echo "== installer fails when an earlier PATH entry shadows the shims =="

  local home shadow status
  home="$(mktemp -d)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset DEV_IDE_NPM_PREFIX
  shadow="${HOME}/shadow-bin"

  write_executable "${shadow}/claude" "#!/usr/bin/env bash
echo shadow-claude"

  status=0
  PATH="${shadow}:${HOME}/.local/bin:${PATH:-/usr/bin:/bin}" \
    bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null 2>&1 || status=$?

  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: installer should exit nonzero when a PATH entry shadows the shims" >&2
    exit 1
  fi
)

run_installer_warns_when_bin_dir_off_path() (
  echo "== installer warns but succeeds when ~/.local/bin is not on PATH =="

  local home err status
  home="$(mktemp -d)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset DEV_IDE_NPM_PREFIX
  err="${home}/stderr.log"

  status=0
  PATH="/usr/bin:/bin" \
    bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null 2>"$err" || status=$?

  assert_eq "installer exit status without bin dir on PATH" "0" "$status"
  if ! grep -q 'cannot verify shim precedence' "$err"; then
    echo "FAIL: expected precedence warning on stderr, got:" >&2
    cat "$err" >&2
    exit 1
  fi
)

run_launch_version_passthrough_skips_launcher() (
  echo "== agent launch passthrough execs the real binary for version/help probes =="

  local home out
  home="$(mktemp -d)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset DEV_IDE_NPM_PREFIX

  write_executable \
    "${HOME}/.local/share/npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude" \
    "#!/usr/bin/env bash
echo \"real-claude \$*\""

  write_executable "${HOME}/real-bin-dir/opencode" "#!/usr/bin/env bash
echo \"real-opencode \$*\""
  mkdir -p "${HOME}/.devide/real-bins"
  ln -sf "${HOME}/real-bin-dir/opencode" "${HOME}/.devide/real-bins/opencode"

  # Version/help probes must not resolve env, create a worktree, or inject
  # MCP — with no DevIDE env in this HOME, anything but a clean passthrough
  # would fail or hang rather than print the real binary's output.
  out="$(cd "$home" && bash "${ROOT}/scripts/devide" agent launch claude --version)"
  assert_eq "claude --version passthrough" "real-claude --version" "$out"

  out="$(cd "$home" && bash "${ROOT}/scripts/devide" agent launch claude update)"
  assert_eq "claude update passthrough" "real-claude update" "$out"

  out="$(cd "$home" && bash "${ROOT}/scripts/devide" agent launch opencode --help)"
  assert_eq "opencode --help passthrough" "real-opencode --help" "$out"
)

main() {
  run_installer_rejects_bin_dir_candidate
  run_resolver_rejects_recorded_devide_shim
  run_installer_generated_shims_carry_marker
  run_installer_fails_when_shims_shadowed
  run_installer_warns_when_bin_dir_off_path
  run_launch_version_passthrough_skips_launcher
  echo "OK: agent shim checks passed"
}

main "$@"
