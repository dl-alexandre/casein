#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVIDE_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
TOKEN="${DEV_IDE_API_TOKEN:-}"
CI_MODE=0

usage() {
  cat <<'EOF'
Usage: verify_deploy_handoff.sh [--ci]

Smoke-checks the deploy handoff endpoint exposed by the running release.

Environment:
  DEVIDE_URL          Base URL (default http://127.0.0.1:4000)
  DEV_IDE_API_TOKEN   Bearer token (optional; endpoint is unauthenticated today)

  --ci                Strict mode: non-200 responses fail the script
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
  auth_header=( -H "authorization: Bearer $TOKEN" )
fi

echo "==> DevIDE deploy handoff verification"
echo "    URL: $DEVIDE_URL/api/deploy_status"

response="$(curl -fsS "${auth_header[@]}" "$DEVIDE_URL/api/deploy_status" || true)"
status="${response:+ok}"

if [[ -z "$response" ]]; then
  echo "ERROR: failed to reach /api/deploy_status" >&2
  exit 1
fi

echo "$response" | python3 -c '
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
  ok="$(echo "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
  if [[ "$ok" != "True" && "$ok" != "true" ]]; then
    echo "ERROR: deploy handoff checks failed in --ci mode" >&2
    exit 1
  fi
fi

echo "==> deploy handoff verification complete"