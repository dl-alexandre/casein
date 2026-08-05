#!/usr/bin/env bash
# Static validation for the self-contained macOS desktop package.
set -euo pipefail

APP="${1:-native/casein_menubar/build/Casein MenuBar.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
RELEASE="$APP/Contents/Resources/release"

[[ -x "$APP/Contents/MacOS/casein-menubar" ]]
[[ -x "$RELEASE/bin/casein" ]]
tmux_bin="$(find "$RELEASE/lib" -path '*/casein-*/priv/bin/tmux' -print -quit)"
[[ -x "$tmux_bin" ]]
metadata="$RELEASE/releases/casein.relmeta.json"
[[ -f "$metadata" ]]
[[ "$(plutil -extract profile raw "$metadata")" == "desktop" ]]
case "$(uname -m)" in
  arm64) expected_target="darwin-aarch64" ;;
  x86_64) expected_target="darwin-x86_64" ;;
  *) echo "unsupported macOS architecture" >&2; exit 1 ;;
esac
[[ "$(plutil -extract target raw "$metadata")" == "$expected_target" ]]

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
env -u TMUX "$tmux_bin" -V | rg -x 'tmux 3\.7b'
resolver_secret="package-smoke-secret-package-smoke-secret-package-smoke-secret-1234"
resolved_tmux="$(DATABASE_PATH="${TMPDIR:-/tmp}/casein-resolver-$$.sqlite3" \
  SECRET_KEY_BASE="$resolver_secret" \
  CASEIN_API_TOKEN="$resolver_secret" \
  "$RELEASE/bin/casein" eval 'IO.puts(Casein.Terminals.TmuxExecutable.resolve())' | tail -n 1)"
[[ "$resolved_tmux" == "$tmux_bin" ]]

smoke_label="casein_package_$$"
smoke_release_node="casein_package_$$"
smoke_socket="${TMPDIR:-/tmp}/$smoke_label.sock"
tmux_environment=(env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=xterm-256color)
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/casein-package-smoke.XXXXXX")"
smoke_account="$(dirname "$smoke_dir")/$(basename "$smoke_dir")"
keychain_service="com.onebackend.casein.desktop.secrets.v1"
runtime_file="$smoke_dir/runtime.json"
host_pid=""
launch_token="package-smoke-launch-secret-package-smoke-launch-secret-1234"
legacy_secrets="$smoke_dir/host-secrets.json"
printf '%s' \
  "{\"secret_key_base\":\"package-smoke-cookie-secret-package-smoke-cookie-secret-package-smoke-cookie-secret\",\"api_token\":\"package-smoke-api-secret-package-smoke-api-secret-1234\",\"desktop_launch_token\":\"$launch_token\"}" \
  > "$legacy_secrets"
chmod 600 "$legacy_secrets"
cleanup() {
  if [[ "$host_pid" =~ ^[0-9]+$ ]]; then
    host_command="$(ps -p "$host_pid" -o command= 2>/dev/null || true)"
    if [[ "$host_command" == "$APP/Contents/MacOS/casein-menubar" ]]; then
      kill -TERM "$host_pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$host_pid" 2>/dev/null || break; sleep 0.1; done
    fi
  fi
  # Read the contract only after the host is gone. If cleanup raced the
  # detach/publish handoff, this short drain lets the already-launched daemon
  # publish its identity without giving the host a chance to restart it.
  for _ in $(seq 1 20); do [[ -f "$runtime_file" ]] && break; sleep 0.1; done
  runtime_pid=""
  if [[ -f "$runtime_file" ]]; then
    runtime_pid="$(plutil -extract pid raw "$runtime_file" 2>/dev/null || true)"
  fi
  if [[ "$runtime_pid" =~ ^[0-9]+$ ]]; then
    runtime_command="$(ps -p "$runtime_pid" -o command= 2>/dev/null || true)"
    if [[ "$runtime_command" == *"$RELEASE"* ]]; then
      kill -TERM "$runtime_pid" 2>/dev/null || true
      for _ in $(seq 1 50); do kill -0 "$runtime_pid" 2>/dev/null || break; sleep 0.1; done
    fi
  fi
  if [[ -S "$smoke_socket" ]]; then
    "${tmux_environment[@]}" "$tmux_bin" -f /dev/null -S "$smoke_socket" kill-server >/dev/null 2>&1 || true
  fi
  rm -f "$smoke_socket"
  security delete-generic-password -s "$keychain_service" -a "$smoke_account" >/dev/null 2>&1 || true
  rm -rf "$smoke_dir"
}
trap cleanup EXIT

"${tmux_environment[@]}" "$tmux_bin" -f /dev/null -S "$smoke_socket" new-session -d -s smoke '/bin/zsh -lc "printf bundled-tmux-ok; sleep 30"'
"${tmux_environment[@]}" "$tmux_bin" -f /dev/null -S "$smoke_socket" has-session -t smoke
"${tmux_environment[@]}" "$tmux_bin" -f /dev/null -S "$smoke_socket" kill-server

if otool -L "$tmux_bin" | rg '/opt/homebrew|/usr/local'; then
  echo "packaged tmux references Homebrew" >&2
  exit 1
fi

find "$APP/Contents" -type f -print0 | while IFS= read -r -d '' candidate; do
  if file "$candidate" | rg -q 'Mach-O'; then
    codesign --verify --strict "$candidate"
  fi
done

# Launch through LaunchServices to exercise the same bundle/resource discovery
# path as Finder and Start at Login. No release or Homebrew path is injected.
CASEIN_DESKTOP_DATA_DIR="$smoke_dir" CASEIN_DESKTOP_RELEASE_NODE="$smoke_release_node" open -n "$APP"
for _ in $(seq 1 15); do
  host_pid="$(pgrep -f "^$APP/Contents/MacOS/casein-menubar$" | tail -n 1 || true)"
  [[ -n "$host_pid" ]] && break
  sleep 1
done
[[ -n "$host_pid" ]] || { echo "packaged menu host did not launch" >&2; exit 1; }
for _ in $(seq 1 90); do
  [[ -f "$runtime_file" ]] && break
  sleep 1
done
[[ -f "$runtime_file" ]] || { echo "packaged app did not publish runtime.json" >&2; exit 1; }

port="$(plutil -extract port raw "$runtime_file")"
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$port/desktop/health" >/dev/null && break
  sleep 1
done
health_file="$smoke_dir/health.json"
curl -fsS "http://127.0.0.1:$port/desktop/health" > "$health_file"
expected_version="$(plutil -extract version raw "$metadata")"
expected_revision="$(plutil -extract revision raw "$metadata")"
[[ "$(plutil -extract version raw "$runtime_file")" == "$expected_version" ]]
[[ "$(plutil -extract revision raw "$runtime_file")" == "$expected_revision" ]]
[[ "$(plutil -extract version raw "$health_file")" == "$expected_version" ]]
[[ "$(plutil -extract revision raw "$health_file")" == "$expected_revision" ]]

unauthenticated="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")"
[[ "$unauthenticated" == "401" ]]
[[ ! -e "$smoke_dir/host-secrets.json" ]]
nonce="$(openssl rand 16 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
timestamp="$(date +%s)"
proof="$(printf 'v1.%s.%s' "$timestamp" "$nonce" | \
  openssl dgst -sha256 -mac HMAC -macopt "key:$launch_token" -binary | \
  openssl base64 -A | tr '+/' '-_' | tr -d '=')"
launch_url="http://127.0.0.1:$port/?desktop_nonce=$nonce&desktop_timestamp=$timestamp&desktop_proof=$proof"
cookies="$smoke_dir/cookies.txt"
effective_url="$(curl -fsS -L -c "$cookies" -b "$cookies" -o /dev/null -w '%{url_effective}' \
  "$launch_url")"
[[ "$effective_url" == "http://127.0.0.1:$port/" ]]
authenticated="$(curl -sS -b "$cookies" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")"
[[ "$authenticated" == "200" ]]
replayed="$(curl -sS -o /dev/null -w '%{http_code}' "$launch_url")"
[[ "$replayed" == "401" ]]
codesign --verify --deep --strict "$APP"

echo "macOS package structure, signatures, Finder launch, and auth smoke are valid"
