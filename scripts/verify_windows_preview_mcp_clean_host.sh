#!/usr/bin/env bash
#
# verify_windows_preview_mcp_clean_host.sh — #463 clean Win11 Preview MCP gate.
#
# NEVER pretends a clean-machine Preview MCP walk passed.
# Modes: --dry-run/--self-check, --validate-evidence PATH, --print-template
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEMA_PATH="${ROOT}/scripts/schemas/windows_preview_mcp_clean_host_evidence.schema.json"
MODE=""
EVIDENCE_PATH=""
VALIDATE_PATH=""

usage() {
  cat <<'USAGE'
Usage: verify_windows_preview_mcp_clean_host.sh --dry-run [--evidence PATH]
       verify_windows_preview_mcp_clean_host.sh --self-check [--evidence PATH]
       verify_windows_preview_mcp_clean_host.sh --validate-evidence PATH
       verify_windows_preview_mcp_clean_host.sh --print-template

Clean Win11 Preview MCP acceptance gate for issue #463.

  --dry-run / --self-check   Linux definition check; never sets clean_host true.
  --evidence PATH            Where dry-run writes JSON.
  --validate-evidence P      Validate an operator evidence file (fail closed).
  --print-template           Print an empty lab_incomplete template JSON.

A Linux dry-run is not clean-machine acceptance. Do not close #463 on it.
Package smoke (preview_playwright daemon walk) is also not this gate.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--self-check) MODE="dry-run"; shift ;;
    --validate-evidence)
      MODE="validate"
      VALIDATE_PATH="${2:-}"
      [[ -n "$VALIDATE_PATH" ]] || { echo "ERROR: --validate-evidence needs a path" >&2; exit 1; }
      shift 2
      ;;
    --evidence)
      EVIDENCE_PATH="${2:-}"
      [[ -n "$EVIDENCE_PATH" ]] || { echo "ERROR: --evidence needs a path" >&2; exit 1; }
      shift 2
      ;;
    --print-template) MODE="template"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  usage >&2
  exit 1
fi

log() { printf '>>> %s\n' "$*"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
git_sha() { git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf '%040d' 0; }

print_template() {
  local sha
  sha="$(git_sha)"
  python3 - "$sha" <<'PY'
import json, sys
from datetime import datetime, timezone
sha = sys.argv[1]
step_ids = ["discover","open","observe","click","type","press","screenshot","close"]
doc = {
  "schema": "casein_windows_preview_mcp_clean_host",
  "schema_version": 1,
  "issue": 463,
  "recorded_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "product_revision": sha if len(sha)==40 else "0"*40,
  "package_sha": sha if len(sha)==40 else "0"*40,
  "operator": "replace-me",
  "host": {
    "os": "Windows 11",
    "kind": "clean_win11_signed_install",
    "package_signed": False,
    "hostname_redacted": "win11-*",
    "notes": "",
  },
  "claims": {
    "clean_host_exercised": False,
    "agent_inside_installed_workspace": False,
    "package_smoke_only": False,
    "linux_dry_run": False,
    "secrets_redacted": True,
  },
  "mcp_steps": [{"id": s, "outcome": "not_run", "notes": ""} for s in step_ids],
  "attachments": {"screenshot_count": 0, "log_refs": [], "issue_comment_urls": []},
  "verdict": "lab_incomplete",
}
json.dump(doc, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}

run_dry_run() {
  local uname_s notes sha recorded is_windows
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  is_windows=false
  case "$uname_s" in MINGW*|MSYS*|CYGWIN*|Windows_NT) is_windows=true ;; esac
  notes="Dry-run only. clean_host_exercised stays false. Use a disposable signed Win11 host + installed package; agent inside workspace; Preview MCP discover→open→observe→click→type→press→screenshot→close; then --validate-evidence."
  sha="$(git_sha)"; recorded="$(utc_now)"
  python3 - "$sha" "$recorded" "$uname_s" "$is_windows" "$notes" "${EVIDENCE_PATH:--}" <<'PY'
import json, sys
sha, recorded, uname_s, is_windows, notes, dest = sys.argv[1:7]
step_ids = ["discover","open","observe","click","type","press","screenshot","close"]
doc = {
  "schema": "casein_windows_preview_mcp_clean_host",
  "schema_version": 1,
  "issue": 463,
  "recorded_at_utc": recorded,
  "product_revision": sha if len(sha)==40 else "0"*40,
  "package_sha": sha if len(sha)==40 else "0"*40,
  "operator": "dry-run",
  "host": {
    "os": uname_s[:64],
    "kind": "linux_dry_run",
    "package_signed": False,
    "hostname_redacted": "dry-run",
    "notes": "not a clean Win11 install",
  },
  "claims": {
    "clean_host_exercised": False,
    "agent_inside_installed_workspace": False,
    "package_smoke_only": False,
    "linux_dry_run": True,
    "secrets_redacted": True,
  },
  "mcp_steps": [{"id": s, "outcome": "not_run", "notes": "dry-run"} for s in step_ids],
  "attachments": {"screenshot_count": 0, "log_refs": [], "issue_comment_urls": []},
  "host_probe": {
    "uname": uname_s[:128],
    "is_windows": is_windows == "true",
    "notes": notes[:512],
  },
  "verdict": "lab_unreachable_on_this_host",
}
text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
if dest == "-":
    sys.stdout.write(text)
else:
    open(dest, "w", encoding="utf-8").write(text)
print(doc["verdict"], file=sys.stderr)
PY
}

validate_evidence() {
  local path="$1"
  [[ -f "$path" ]] || { echo "ERROR: evidence file not found: $path" >&2; exit 4; }
  [[ -f "$SCHEMA_PATH" ]] || { echo "ERROR: missing schema at $SCHEMA_PATH" >&2; exit 3; }
  # Validator lives beside this script so shell quoting cannot corrupt regexes.
  python3 "${ROOT}/scripts/lib/windows_preview_mcp_clean_host_validate.py" "$path" "$SCHEMA_PATH"
}

case "$MODE" in
  template) print_template; exit 0 ;;
  dry-run)
    log "dry-run for #463 (never claims clean-host Preview MCP pass)"
    if ! run_dry_run; then echo "ERROR: dry-run failed to write evidence" >&2; exit 2; fi
    if [[ -n "$EVIDENCE_PATH" ]]; then
      log "wrote $EVIDENCE_PATH"
      validate_evidence "$EVIDENCE_PATH"
    fi
    log "OK: lab_unreachable_on_this_host (definition check only)"
    exit 0
    ;;
  validate)
    log "validating evidence $VALIDATE_PATH"
    verdict="$(validate_evidence "$VALIDATE_PATH")"
    log "verdict: $verdict"
    log "OK: evidence accepted as $verdict"
    exit 0
    ;;
  *) usage >&2; exit 1 ;;
esac
