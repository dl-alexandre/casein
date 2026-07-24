#!/usr/bin/env bash
# Resolve the real agent binary, skipping DevIDE launcher shims.

devide_npm_prefix() {
  printf '%s\n' "${CASEIN_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
}

devide_agent_shim_dir() {
  printf '%s\n' "${CASEIN_AGENT_BIN_DIR:-${HOME}/.casein/agent-shims}"
}

real_agent_bin_path_without_shims() {
  local IFS=':'
  local part out=() shim_dir
  shim_dir="$(devide_agent_shim_dir)"
  for part in ${PATH:-/usr/bin:/bin}; do
    [[ "$part" == "$shim_dir" ]] && continue
    # Legacy shim home — stale launcher shims may linger there until the
    # installer's migration cleanup has run on this box.
    [[ "$part" == "${HOME}/.local/bin" ]] && continue
    out+=("$part")
  done
  (IFS=:; printf '%s' "${out[*]}")
}

is_devide_shim() {
  local path="$1"
  [[ -f "$path" ]] && grep -q 'devide" agent launch' "$path" 2>/dev/null
}

real_agent_npm_candidate() {
  local name="$1"
  local npm_prefix
  npm_prefix="$(devide_npm_prefix)"

  case "$name" in
    claude)
      for candidate in \
        "${npm_prefix}/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
        "${npm_prefix}/lib/node_modules/@anthropic-ai/claude-code/bin/claude.js" \
        "${npm_prefix}/lib/node_modules/@anthropic-ai/claude-code/bin/claude" \
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
        "${npm_prefix}/lib/node_modules/@openai/codex/bin/codex.js" \
        "${npm_prefix}/lib/node_modules/@openai/codex/bin/codex" \
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

real_agent_bin() {
  local name="$1"
  local recorded="${HOME}/.casein/real-bins/${name}"
  local candidate=""

  case "$name" in
    claude|codex)
      if candidate="$(real_agent_npm_candidate "$name")"; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
  esac

  if [[ -e "$recorded" ]] && ! is_devide_shim "$recorded"; then
    printf '%s\n' "$recorded"
    return 0
  fi

  candidate="$(PATH="$(real_agent_bin_path_without_shims)" command -v "$name" 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && ! is_devide_shim "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  real_agent_npm_candidate "$name"
}
