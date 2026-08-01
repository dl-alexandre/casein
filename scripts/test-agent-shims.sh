#!/usr/bin/env bash
#
# Regression coverage for Casein agent shim installation/resolution.
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
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX
  bin_dir="${HOME}/.local/bin"
  package_claude="${HOME}/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude"

  write_executable "${bin_dir}/claude" "#!/usr/bin/env bash
echo stale-bin-dir-claude"
  write_executable "$package_claude" "#!/usr/bin/env bash
echo package-claude"

  # The trailing slash used to bypass the BIN_DIR guard and record the soon-to-be
  # overwritten shim path as the "real" binary.
  PATH="${bin_dir}/:${PATH:-/usr/bin:/bin}" bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null

  target="$(readlink -f "${HOME}/.casein/real-bins/claude")"
  assert_eq "recorded claude target" "$package_claude" "$target"
  assert_not_under "recorded claude target" "$target" "$bin_dir"
)

run_resolver_rejects_recorded_casein_shim() (
  echo "== real-agent-bin rejects recorded Casein shims =="

  local home real_dir real_codex resolved
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX
  real_dir="${home}/real-bin-dir"
  real_codex="${real_dir}/codex"

  write_executable "${HOME}/.casein/real-bins/codex" "#!/usr/bin/env bash
exec \"${ROOT}/scripts/casein\" agent launch codex \"\$@\""
  write_executable "$real_codex" "#!/usr/bin/env bash
echo real-codex"

  # shellcheck source=scripts/lib/real-agent-bin.sh
  source "${ROOT}/scripts/lib/real-agent-bin.sh"

  export PATH="${HOME}/.local/bin:${real_dir}:${PATH:-/usr/bin:/bin}"
  resolved="$(real_agent_bin codex)"
  assert_eq "resolved codex binary" "$real_codex" "$resolved"
)

run_installer_generated_shims_carry_marker() (
  echo "== installer-generated shims are detected by is_casein_shim =="

  local home name
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX

  bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null

  # shellcheck source=scripts/lib/real-agent-bin.sh
  source "${ROOT}/scripts/lib/real-agent-bin.sh"

  # The shim template (installer) and the marker grep (real-agent-bin.sh)
  # live in different files; this pins their coupling.
  for name in grok claude codex opencode agent; do
    if ! is_casein_shim "${HOME}/.casein/agent-shims/${name}"; then
      echo "FAIL: installed shim not detected as a Casein shim: ${name}" >&2
      exit 1
    fi
  done

  # agent-doctor.sh extracts the embedded casein CLI path with this sed
  # pattern; pin it against the installer's shim template.
  local embedded
  embedded="$(sed -n 's/^exec "\(.*\)" agent launch .*/\1/p' "${HOME}/.casein/agent-shims/claude" | head -n 1)"
  assert_eq "embedded casein CLI path" "${ROOT}/scripts/casein" "$embedded"
)

run_installer_cleans_legacy_shims() (
  echo "== installer removes legacy Casein shims from ~/.local/bin, keeps user files =="

  local home
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX

  # A legacy marker-carrying launcher shim and a user's own script side by
  # side in ~/.local/bin: migration must remove exactly the former.
  write_executable "${HOME}/.local/bin/grok" "#!/usr/bin/env bash
exec \"${ROOT}/scripts/casein\" agent launch grok \"\$@\""
  write_executable "${HOME}/.local/bin/my-tool" "#!/usr/bin/env bash
echo mine"

  bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null

  if [[ -e "${HOME}/.local/bin/grok" ]]; then
    echo "FAIL: legacy grok shim should be removed from ~/.local/bin" >&2
    exit 1
  fi
  if [[ ! -x "${HOME}/.local/bin/my-tool" ]]; then
    echo "FAIL: user file in ~/.local/bin must be untouched" >&2
    exit 1
  fi
  if [[ ! -x "${HOME}/.casein/agent-shims/grok" ]]; then
    echo "FAIL: grok shim missing from ~/.casein/agent-shims" >&2
    exit 1
  fi
)

run_installer_verifies_precedence_when_bin_dir_off_path() (
  echo "== installer verifies resolution with a minimal caller PATH =="

  local home err status
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX
  err="${home}/stderr.log"

  # Non-interactive callers (systemd units, deploy poller) run without the
  # shim dir on PATH; the installer must self-prepend it for the check.
  status=0
  PATH="/usr/bin:/bin" \
    bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null 2>"$err" || status=$?

  assert_eq "installer exit status without shim dir on PATH" "0" "$status"
  if grep -q 'shim resolution broken' "$err"; then
    echo "FAIL: resolution check failed unexpectedly:" >&2
    cat "$err" >&2
    exit 1
  fi
)

run_launch_version_passthrough_skips_launcher() (
  echo "== agent launch passthrough execs the real binary for administrative commands =="

  local home out
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX

  write_executable \
    "${HOME}/.local/share/npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude" \
    "#!/usr/bin/env bash
echo \"real-claude \$*\""

  write_executable "${HOME}/real-bin-dir/opencode" "#!/usr/bin/env bash
echo \"real-opencode \$*\""
  write_executable "${HOME}/real-bin-dir/grok" "#!/usr/bin/env bash
echo \"real-grok \$*\""
  mkdir -p "${HOME}/.casein/real-bins"
  ln -sf "${HOME}/real-bin-dir/opencode" "${HOME}/.casein/real-bins/opencode"
  ln -sf "${HOME}/real-bin-dir/grok" "${HOME}/.casein/real-bins/grok"

  # Version/help probes must not resolve env, create a worktree, or inject
  # MCP — with no Casein env in this HOME, anything but a clean passthrough
  # would fail or hang rather than print the real binary's output.
  out="$(cd "$home" && bash "${ROOT}/scripts/casein" agent launch claude --version)"
  assert_eq "claude --version passthrough" "real-claude --version" "$out"

  out="$(cd "$home" && bash "${ROOT}/scripts/casein" agent launch claude update)"
  assert_eq "claude update passthrough" "real-claude update" "$out"

  out="$(cd "$home" && bash "${ROOT}/scripts/casein" agent launch opencode --help)"
  assert_eq "opencode --help passthrough" "real-opencode --help" "$out"

  # Authentication must reach Grok before Casein resolves a workspace or
  # requires the persistent OAuth credential that this command creates.
  out="$(cd "$home" && CASEIN_AGENT_LAUNCH_STRICT=1 \
    bash "${ROOT}/scripts/casein" agent launch grok login --device-auth)"
  assert_eq "grok device login passthrough" "real-grok login --device-auth" "$out"

  out="$(cd "$home" && CASEIN_AGENT_LAUNCH_STRICT=1 \
    bash "${ROOT}/scripts/casein" agent launch grok logout)"
  assert_eq "grok logout passthrough" "real-grok logout" "$out"
)

run_launch_falls_back_unpaired_without_env() (
  echo "== agent launch falls back to the real binary when no Casein env resolves =="

  local home out err status
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX

  write_executable "${HOME}/real-bin-dir/grok" "#!/usr/bin/env bash
echo \"real-grok \$*\""
  mkdir -p "${HOME}/.casein/real-bins"
  ln -sf "${HOME}/real-bin-dir/grok" "${HOME}/.casein/real-bins/grok"

  # A plain terminal outside Casein: no pane env, no .devbox-agent.env in
  # cwd ancestry. The shimmed name must launch the real binary with ZERO
  # added output — the shim never adds noise to the command it wraps.
  err="${home}/stderr.log"
  out="$(cd "$home" && env -u TMUX -u TMUX_PANE -u CASEIN_API_TOKEN -u CASEIN_WORKSPACE_ID -u CASEIN_AGENT_ENV_FILE \
    bash "${ROOT}/scripts/casein" agent launch grok chat 2>"$err")"
  assert_eq "unpaired fallback execs real grok" "real-grok chat" "$out"
  if [[ -s "$err" ]]; then
    echo "FAIL: unpaired fallback must be silent by default, got stderr:" >&2
    cat "$err" >&2
    exit 1
  fi

  out="$(cd "$home" && env -u TMUX -u TMUX_PANE -u CASEIN_API_TOKEN -u CASEIN_WORKSPACE_ID -u CASEIN_AGENT_ENV_FILE \
    CASEIN_AGENT_LAUNCH_VERBOSE=1 \
    bash "${ROOT}/scripts/casein" agent launch grok chat 2>"$err")"
  assert_eq "verbose unpaired fallback execs real grok" "real-grok chat" "$out"
  if ! grep -q 'launching grok unpaired' "$err"; then
    echo "FAIL: CASEIN_AGENT_LAUNCH_VERBOSE=1 should explain the fallback, got:" >&2
    cat "$err" >&2
    exit 1
  fi

  status=0
  (cd "$home" && env -u TMUX -u TMUX_PANE -u CASEIN_API_TOKEN -u CASEIN_WORKSPACE_ID -u CASEIN_AGENT_ENV_FILE \
    CASEIN_AGENT_LAUNCH_STRICT=1 \
    bash "${ROOT}/scripts/casein" agent launch grok chat >/dev/null 2>"$err") || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: CASEIN_AGENT_LAUNCH_STRICT=1 should hard-fail without env" >&2
    exit 1
  fi
  if ! grep -q 'could not resolve Casein agent env' "$err"; then
    echo "FAIL: strict mode should surface the resolver error, got:" >&2
    cat "$err" >&2
    exit 1
  fi
)

run_launch_stamps_pane_pairing_state() (
  echo "== agent launch stamps @casein_paired on the tmux pane =="

  local home tmux_log out
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX
  tmux_log="${home}/tmux-calls.log"

  write_executable "${HOME}/real-bin-dir/grok" "#!/usr/bin/env bash
echo real-grok"
  mkdir -p "${HOME}/.casein/real-bins"
  ln -sf "${HOME}/real-bin-dir/grok" "${HOME}/.casein/real-bins/grok"

  # Fake tmux: answers env probes with nothing (so resolution still fails)
  # and records set-option calls — pairing state must reach the pane option
  # without any terminal output.
  write_executable "${HOME}/fake-bin/tmux" "#!/usr/bin/env bash
printf '%s\\n' \"\$*\" >>\"${tmux_log}\"
exit 0"

  out="$(cd "$home" && env -u CASEIN_API_TOKEN -u CASEIN_WORKSPACE_ID -u CASEIN_AGENT_ENV_FILE \
    TMUX="${home}/fake-socket,1,0" TMUX_PANE="%7" PATH="${HOME}/fake-bin:${PATH:-/usr/bin:/bin}" \
    bash "${ROOT}/scripts/casein" agent launch grok chat 2>&1)"
  assert_eq "stamped fallback still execs real grok" "real-grok" "$out"

  if ! grep -q '^set-option -p -t %7 @casein_paired 0$' "$tmux_log"; then
    echo "FAIL: expected @casein_paired 0 stamp on pane %7, tmux calls were:" >&2
    cat "$tmux_log" >&2
    exit 1
  fi
  if ! grep -q '^set-option -p -t %7 @casein_paired_reason no agent env$' "$tmux_log"; then
    echo "FAIL: expected @casein_paired_reason stamp, tmux calls were:" >&2
    cat "$tmux_log" >&2
    exit 1
  fi
)

run_check_and_ensure_modes() (
  echo "== install-agent-shims --check / --ensure detect and heal partial loss =="

  local home status
  home="$(cd "$(mktemp -d)" && pwd -P)"
  trap 'rm -rf "$home"' EXIT

  export HOME="$home"
  unset CASEIN_NPM_PREFIX

  bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null

  status=0
  bash "${ROOT}/scripts/install-agent-shims.sh" --check >/dev/null || status=$?
  assert_eq "check after full install" "0" "$status"

  # Simulate the production failure mode: one runtime shim deleted, siblings ok.
  rm -f "${HOME}/.casein/agent-shims/claude"
  status=0
  bash "${ROOT}/scripts/install-agent-shims.sh" --check >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: --check should fail when claude shim is missing" >&2
    exit 1
  fi

  status=0
  bash "${ROOT}/scripts/install-agent-shims.sh" --ensure >/dev/null || status=$?
  assert_eq "ensure heals missing claude" "0" "$status"
  if [[ ! -x "${HOME}/.casein/agent-shims/claude" ]]; then
    echo "FAIL: --ensure did not restore claude shim" >&2
    exit 1
  fi

  status=0
  bash "${ROOT}/scripts/install-agent-shims.sh" --ensure >/dev/null || status=$?
  assert_eq "ensure is no-op when complete" "0" "$status"
)

main() {
  run_installer_rejects_bin_dir_candidate
  run_resolver_rejects_recorded_casein_shim
  run_installer_generated_shims_carry_marker
  run_installer_cleans_legacy_shims
  run_installer_verifies_precedence_when_bin_dir_off_path
  run_launch_version_passthrough_skips_launcher
  run_launch_falls_back_unpaired_without_env
  run_launch_stamps_pane_pairing_state
  run_check_and_ensure_modes
  echo "OK: agent shim checks passed"
}

main "$@"
