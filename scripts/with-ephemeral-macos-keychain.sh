#!/usr/bin/env bash
# Run a command with an isolated, unlocked keychain for noninteractive macOS CI.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "with-ephemeral-macos-keychain.sh requires macOS" >&2
  exit 2
fi

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 command [args ...]" >&2
  exit 2
fi

runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
lock_dir="$runner_temp/casein-ephemeral-keychain.lock"
command=("$@")
temp_dir=""
keychain_path=""
original_default=""
original_list=""

acquire_lock() {
  for _ in $(seq 1 120); do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock_dir/pid"
      return 0
    fi

    owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi

    sleep 1
  done

  echo "timed out waiting for the macOS keychain test lock" >&2
  return 1
}

restore_keychains() {
  if [[ -n "$original_list" && -f "$original_list" ]]; then
    set --
    while IFS= read -r existing; do
      [[ -n "$existing" ]] && set -- "$@" "$existing"
    done < "$original_list"
    security list-keychains -d user -s "$@" >/dev/null 2>&1 || true
  fi

  if [[ -n "$original_default" ]]; then
    security default-keychain -d user -s "$original_default" >/dev/null 2>&1 || true
  fi

  if [[ -n "$keychain_path" ]]; then
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  fi

  [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
}

acquire_lock
trap restore_keychains EXIT HUP INT TERM

temp_dir="$(mktemp -d "$runner_temp/casein-keychain.XXXXXX")"
keychain_path="$temp_dir/ci.keychain-db"
original_list="$temp_dir/original-list"
security list-keychains -d user \
  | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
  > "$original_list"
original_default="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
password="$(/usr/bin/openssl rand -hex 32)"

security create-keychain -p "$password" "$keychain_path"
security set-keychain-settings -lut 3600 "$keychain_path"
security unlock-keychain -p "$password" "$keychain_path"

set --
while IFS= read -r existing; do
  [[ -n "$existing" ]] && set -- "$@" "$existing"
done < "$original_list"
security list-keychains -d user -s "$keychain_path" "$@"
security default-keychain -d user -s "$keychain_path"

"${command[@]}"
