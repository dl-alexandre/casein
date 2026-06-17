#!/usr/bin/env bash
# Resolve the real agent binary, skipping DevIDE shims in ~/.local/bin.

real_agent_bin_path_without_shims() {
  local IFS=':'
  local part out=()
  for part in ${PATH:-/usr/bin:/bin}; do
    [[ "$part" == "${HOME}/.local/bin" ]] && continue
    out+=("$part")
  done
  (IFS=:; printf '%s' "${out[*]}")
}

is_devide_shim() {
  local path="$1"
  [[ -f "$path" ]] && grep -q 'devide" agent launch' "$path" 2>/dev/null
}

real_agent_bin() {
  local name="$1"
  local recorded="${HOME}/.devide/real-bins/${name}"
  local candidate=""

  if [[ -e "$recorded" ]]; then
    printf '%s\n' "$recorded"
    return 0
  fi

  candidate="$(PATH="$(real_agent_bin_path_without_shims)" command -v "$name" 2>/dev/null || true)"
  if [[ -n "$candidate" ]] && ! is_devide_shim "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  case "$name" in
    claude)
      for candidate in \
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
        "${HOME}/.local/lib/node_modules/@openai/codex/bin/codex.js" \
        "${HOME}/.local/lib/node_modules/@openai/codex/bin/codex"; do
        if [[ -f "$candidate" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
      ;;
  esac
}