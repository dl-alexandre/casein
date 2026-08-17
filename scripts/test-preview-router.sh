#!/usr/bin/env bash
#
# Hermetic tests for scripts/preview-router.sh Caddyfile generation.
# Asserts the generated config cannot send a plaintext-derived scheme to the
# authz upstream (Plug.SSL 301-loops /api/previews/authz when it does).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CASEIN_PREVIEW_HOME="$TMP"
generated="$(bash "$ROOT/scripts/preview-router.sh" config)"
caddyfile="$TMP/router/Caddyfile"
[ -f "$caddyfile" ] || fail "config did not write $caddyfile"
[ -n "$generated" ] || fail "config printed nothing"

authz_block="$(awk '
  /forward_auth / { take=1; buf=$0 ORS; next }
  take { buf = buf $0 ORS }
  take && /^[[:space:]]*}[[:space:]]*$/ {
    if (buf ~ /\/api\/previews\/authz/) printf "%s", buf
    take=0
    buf=""
  }
' "$caddyfile")"
[ -n "$authz_block" ] || fail "generated Caddyfile has no /api/previews/authz forward_auth block"

printf '%s' "$authz_block" | grep -q 'header_up X-Forwarded-Proto https' \
  || fail "authz forward_auth must pin header_up X-Forwarded-Proto https; got:"$'\n'"$authz_block"
ok

printf '%s' "$authz_block" | grep -q '{scheme}' \
  && fail "authz forward_auth must not derive scheme from {scheme}; got:"$'\n'"$authz_block"
ok

printf '%s' "$authz_block" | grep -Eq 'X-Forwarded-Proto[[:space:]]+\{' \
  && fail "authz X-Forwarded-Proto must be literal https, not a placeholder; got:"$'\n'"$authz_block"
ok

printf '%s' "$authz_block" | grep -Eqi 'X-Forwarded-Proto[[:space:]]+http([^s]|$)' \
  && fail "authz forward_auth must not send X-Forwarded-Proto http; got:"$'\n'"$authz_block"
ok

grep -q 'rd=https://{host}{uri}' "$caddyfile" \
  || fail "login bounce must use rd=https://{host}{uri}"
ok

grep -q 'rd={scheme}://' "$caddyfile" \
  && fail "login bounce must not use rd={scheme}://"
ok

grep -q 'trusted_proxies static 127.0.0.1/32 ::1/128' "$caddyfile" \
  || fail "global options must declare trusted_proxies for the edge hop"
ok

if command -v caddy >/dev/null 2>&1; then
  caddy validate --adapter caddyfile --config "$caddyfile" >/dev/null 2>&1 \
    || fail "generated Caddyfile failed caddy validate"
  ok
fi

echo "OK: preview-router generated Caddyfile scheme checks passed ($pass assertions)"
