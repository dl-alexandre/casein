#!/usr/bin/env bash
#
# verify_deploy_handoff.sh — smoke-check /api/deploy_status on the live release.
#
# Never uses curl -f: a workspace-scoped token gets HTTP 403, an unauthenticated
# call gets 401, and both must remain visible. Prefer unix socket when the
# loopback URL is down so the check still pins the process behind current.sock.
#
# Usage:
#   bash scripts/verify_deploy_handoff.sh
#   bash scripts/verify_deploy_handoff.sh --ci
#
# Exit codes:
#   0  reachable with expected shape (200 global, or 401/403 without --ci strict ok)
#   1  usage / unreachable / unparseable
#   2  --ci and body.ok is not true on HTTP 200
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CASEIN_URL="${CASEIN_URL:-http://127.0.0.1:4000}"
CURRENT_SOCK="${CASEIN_CURRENT_SOCK:-/run/casein/current.sock}"
TOKEN="${CASEIN_API_TOKEN:-}"
CI_MODE=0

usage() {
  cat <<'EOF'
Usage: verify_deploy_handoff.sh [--ci]

Smoke-checks the deploy handoff endpoint exposed by the running release.

Environment:
  CASEIN_URL            Base URL (default http://127.0.0.1:4000)
  CASEIN_CURRENT_SOCK   Active socket symlink (fallback transport)
  CASEIN_API_TOKEN      Bearer token (global required for full JSON; workspace → 403)

  --ci                  Strict mode: require HTTP 200 and body.ok == true
                        (workspace tokens will fail --ci; use a global token)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) CI_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

auth_header=()
if [[ -n "$TOKEN" ]]; then
  auth_header=(-H "authorization: Bearer ${TOKEN}")
fi

body_file="$(mktemp "${TMPDIR:-/tmp}/casein-deploy-handoff-XXXXXX.json")"
cleanup() { rm -f "$body_file"; }
trap cleanup EXIT

echo "==> Casein deploy handoff verification"
echo "    URL: ${CASEIN_URL}/api/deploy_status"
echo "    sock: ${CURRENT_SOCK}"

# Never curl -f — 401/403/503 bodies must remain readable.
HTTP_CODE="000"
http_code_via_url() {
  curl -sS --max-time 5 -o "$body_file" -w '%{http_code}' \
    "${auth_header[@]}" \
    "${CASEIN_URL}/api/deploy_status" 2>/dev/null || printf '000'
}

http_code_via_sock() {
  curl -sS --max-time 5 -o "$body_file" -w '%{http_code}' \
    --unix-socket "$CURRENT_SOCK" \
    "${auth_header[@]}" \
    "http://localhost/api/deploy_status" 2>/dev/null || printf '000'
}

probe="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "${CASEIN_URL}/" 2>/dev/null || printf '000')"
if [[ "$probe" != "000" && -n "$probe" ]]; then
  HTTP_CODE="$(http_code_via_url)"
  transport="url"
elif [[ -L "$CURRENT_SOCK" || -S "$CURRENT_SOCK" ]]; then
  HTTP_CODE="$(http_code_via_sock)"
  transport="unix"
else
  echo "ERROR: loopback unreachable and ${CURRENT_SOCK} missing" >&2
  exit 1
fi

echo "    transport: ${transport}"
echo "    HTTP ${HTTP_CODE}"

body="$(cat "$body_file" 2>/dev/null || true)"
if [[ -z "$body" && "$HTTP_CODE" == "000" ]]; then
  echo "ERROR: failed to reach /api/deploy_status" >&2
  exit 1
fi

case "$HTTP_CODE" in
  200)
    echo "$body" | python3 -c '
import json, sys
body = json.load(sys.stdin)
assert "ok" in body, body
assert "version" in body, body
assert "checks" in body and isinstance(body["checks"], dict), body
print("    ok:", body["ok"])
print("    version:", body["version"])
for name, value in sorted(body["checks"].items()):
    print(f"    check {name}: {value}")
'
    if [[ "$CI_MODE" -eq 1 ]]; then
      ok="$(echo "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
      if [[ "$ok" != "True" && "$ok" != "true" ]]; then
        echo "ERROR: deploy handoff checks failed in --ci mode" >&2
        exit 2
      fi
    fi
    ;;
  401)
    echo "    unauthorized (no/invalid token) — endpoint reachable; use global token for body.ok"
    if [[ "$CI_MODE" -eq 1 ]]; then
      echo "ERROR: --ci requires HTTP 200 with global token (got 401)" >&2
      exit 1
    fi
    ;;
  403)
    echo "    workspace token correctly forbidden on global deploy_status"
    if [[ "$CI_MODE" -eq 1 ]]; then
      echo "ERROR: --ci requires HTTP 200 with global token (got 403 workspace_forbidden)" >&2
      exit 1
    fi
    ;;
  503)
    echo "    HTTP 503 (checks failed) — body retained without curl -f"
    echo "$body" | python3 -c '
import json,sys
try:
  d=json.load(sys.stdin)
  print("    ok:", d.get("ok"))
  print("    version:", d.get("version"))
  for name, value in sorted((d.get("checks") or {}).items()):
      print(f"    check {name}: {value}")
except Exception as e:
  print("    body:", sys.stdin.read() if False else open(0).read()[:300] if False else str(e))
' 2>/dev/null || echo "    body: $(printf '%s' "$body" | head -c 300)"
    if [[ "$CI_MODE" -eq 1 ]]; then
      echo "ERROR: deploy handoff returned 503 in --ci mode" >&2
      exit 2
    fi
    ;;
  000)
    echo "ERROR: failed to reach /api/deploy_status (connection failed)" >&2
    exit 1
    ;;
  *)
    echo "ERROR: unexpected HTTP ${HTTP_CODE}: $(printf '%s' "$body" | head -c 200)" >&2
    exit 1
    ;;
esac

echo "==> deploy handoff verification complete"
