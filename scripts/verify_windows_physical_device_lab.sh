#!/usr/bin/env bash
#
# verify_windows_physical_device_lab.sh — #377 physical iPad/Android lab gate.
#
# This script NEVER pretends a physical matrix passed. Modes:
#
#   --self-check
#       Probe this host for adb/idevice presence and attached device count.
#       Always writes claims.physical_*=false and verdict
#       lab_unreachable_on_this_host unless you also pass a pre-filled
#       evidence file via --validate-evidence (self-check does not validate
#       a human matrix).
#
#   --validate-evidence PATH
#       Fail-closed schema + claims + secret scan for operator-produced JSON.
#       Exit 0 only when the file is well-formed and verdict is one of
#       matrix_passed | matrix_failed | lab_incomplete | lab_unreachable_on_this_host.
#       matrix_passed additionally requires honest physical claims and every
#       row outcome == passed on both platforms.
#
#   --print-template
#       Emit an empty lab_incomplete template to stdout (for operators).
#
# Exit codes:
#   0  ok for the requested mode
#   1  usage
#   2  self-check could not write evidence
#   3  evidence rejected (schema, secrets, dishonest claims)
#   4  evidence file missing/unreadable
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEMA_PATH="${ROOT}/scripts/schemas/windows_physical_device_lab_evidence.schema.json"
MODE=""
EVIDENCE_PATH=""
VALIDATE_PATH=""

usage() {
  cat <<'EOF'
Usage: verify_windows_physical_device_lab.sh --self-check [--evidence PATH]
       verify_windows_physical_device_lab.sh --validate-evidence PATH
       verify_windows_physical_device_lab.sh --print-template

Physical Windows-origin iPad/Android lab gate for issue #377.

  --self-check            Probe this host; never sets physical_* true.
  --evidence PATH         Where self-check writes JSON (default stdout summary).
  --validate-evidence P   Validate an operator evidence file (fail closed).
  --print-template        Print an empty lab_incomplete template JSON.

A Linux/devbox self-check is not matrix completion. Do not close #377 on it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-check) MODE="self-check"; shift ;;
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

git_sha() {
  git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf '%040d' 0
}

print_template() {
  local sha
  sha="$(git_sha)"
  python3 - "$sha" <<'PY'
import json, sys
sha = sys.argv[1]
row = {"outcome": "not_run", "at_utc": None, "notes": ""}
rows = {
    k: dict(row)
    for k in (
        "initial_pair",
        "warm_resume_followup",
        "background_foreground",
        "killed_cold_cached",
        "host_restart",
        "device_restart",
        "offline_firewall_denied",
        "vpn_interface_change_repair",
        "tampered_target_fail_closed",
        "operator_verify_fail_closed",
        "pwa_escalation",
    )
}
# Drop null at_utc for stricter schema (optional field omitted).
for r in rows.values():
    r.pop("at_utc", None)

def platform(label):
    return {
        "device_label": label,
        "os_version": "",
        "app_version": "",
        "rows": {k: dict(v) for k, v in rows.items()},
    }

doc = {
    "schema": "casein_windows_physical_device_lab",
    "schema_version": 1,
    "issue": 377,
    "recorded_at_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "product_revision": sha if len(sha) == 40 else "0" * 40,
    "operator": "replace-me",
    "claims": {
        "physical_android": False,
        "physical_ipad": False,
        "windows_origin_exercised": False,
        "simulator_or_emulator": False,
        "secrets_redacted": True,
    },
    "windows_host": {
        "os": "",
        "package_signed": False,
        "origin_id_prefix": "000000000000",
        "display_name_suffix_ok": False,
        "trusted_lan": "not_applicable",
        "profiles_collision_free": False,
    },
    "platforms": {
        "android": platform("android-device"),
        "ipad": platform("ipad-device"),
    },
    "attachments": {
        "screenshot_count": 0,
        "log_refs": [],
        "issue_comment_urls": [],
    },
    "verdict": "lab_incomplete",
}
json.dump(doc, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}

count_adb_devices() {
  if ! command -v adb >/dev/null 2>&1; then
    printf '0'
    return
  fi
  # Count lines with device state "device" only (not unauthorized/offline).
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {c++} END{print c+0}'
}

run_self_check() {
  local adb_present=false idevice_present=false adb_count=0 uname_s notes
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  if command -v adb >/dev/null 2>&1; then
    adb_present=true
    adb_count="$(count_adb_devices)"
  fi
  if command -v idevice_id >/dev/null 2>&1; then
    idevice_present=true
  fi

  notes="Self-check only. physical_* claims stay false. Attach devices and a Windows origin host, then produce operator evidence and --validate-evidence."
  if [[ "$uname_s" != "Linux" && "$uname_s" != "Darwin" ]]; then
    notes="${notes} Unusual uname=${uname_s}."
  fi
  if [[ "$adb_present" == true && "$adb_count" -gt 0 ]]; then
    notes="${notes} adb reports ${adb_count} device(s); still not matrix evidence without operator rows."
  fi

  local sha recorded
  sha="$(git_sha)"
  recorded="$(utc_now)"

  python3 - "$sha" "$recorded" "$uname_s" "$adb_present" "$adb_count" "$idevice_present" "$notes" "${EVIDENCE_PATH:--}" <<'PY'
import json, sys
sha, recorded, uname_s, adb_present, adb_count, idevice_present, notes, dest = sys.argv[1:9]
doc = {
    "schema": "casein_windows_physical_device_lab",
    "schema_version": 1,
    "issue": 377,
    "recorded_at_utc": recorded,
    "product_revision": sha if len(sha) == 40 else "0" * 40,
    "operator": "self-check",
    "claims": {
        "physical_android": False,
        "physical_ipad": False,
        "windows_origin_exercised": False,
        "simulator_or_emulator": False,
        "secrets_redacted": True,
    },
    "windows_host": {
        "os": "",
        "package_signed": False,
        "origin_id_prefix": "000000000000",
        "display_name_suffix_ok": False,
        "trusted_lan": "not_applicable",
        "profiles_collision_free": False,
    },
    "attachments": {
        "screenshot_count": 0,
        "log_refs": [],
        "issue_comment_urls": [],
    },
    "host_probe": {
        "uname": uname_s[:128],
        "adb_present": adb_present == "true",
        "adb_device_count": int(adb_count),
        "idevice_id_present": idevice_present == "true",
        "notes": notes[:512],
    },
    "verdict": "lab_unreachable_on_this_host",
}
text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
if dest == "-":
    sys.stdout.write(text)
else:
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(text)
print(doc["verdict"], file=sys.stderr)
PY
}

validate_evidence() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: evidence file not found: $path" >&2
    exit 4
  fi
  if [[ ! -f "$SCHEMA_PATH" ]]; then
    echo "ERROR: missing schema at $SCHEMA_PATH" >&2
    exit 3
  fi

  python3 - "$path" "$SCHEMA_PATH" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])

ROW_IDS = (
    "initial_pair",
    "warm_resume_followup",
    "background_foreground",
    "killed_cold_cached",
    "host_restart",
    "device_restart",
    "offline_firewall_denied",
    "vpn_interface_change_repair",
    "tampered_target_fail_closed",
    "operator_verify_fail_closed",
    "pwa_escalation",
)

SECRET_PATTERNS = [
    re.compile(r"(?i)bearer\s+[a-z0-9._\-]+"),
    re.compile(r"(?i)authorization\s*[:=]\s*\S+"),
    re.compile(r"(?i)(api[_-]?token|access[_-]?token|refresh[_-]?token)\s*[:=]\s*\S+"),
    re.compile(r"(?i)pairing[_-]?token"),
    re.compile(r"(?i)qr[_\s-]?payload"),
    re.compile(r"casein://[^\s\"']+"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),  # JWT-shaped
    re.compile(r"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]

# Full windows-<uuid> must not appear; prefix-only (12 hex) is required when present.
FULL_ORIGIN = re.compile(r"windows-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-")


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(3)


def walk_strings(obj, acc: list[str]) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            acc.append(str(k))
            walk_strings(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            walk_strings(v, acc)
    elif isinstance(obj, str):
        acc.append(obj)
    elif obj is not None and not isinstance(obj, (int, float, bool)):
        acc.append(str(obj))


try:
    raw = path.read_text(encoding="utf-8")
except OSError as exc:
    fail(f"unreadable evidence: {exc.__class__.__name__}")

if len(raw) > 512_000:
    fail("evidence exceeds 512 KiB bound")

try:
    doc = json.loads(raw)
except json.JSONDecodeError:
    fail("evidence is not valid JSON")

if not isinstance(doc, dict):
    fail("evidence root must be an object")

# Lightweight schema checks (no jsonschema dependency required on every host).
if doc.get("schema") != "casein_windows_physical_device_lab":
    fail("schema must be casein_windows_physical_device_lab")
if doc.get("schema_version") != 1:
    fail("schema_version must be 1")
if doc.get("issue") != 377:
    fail("issue must be 377")

rev = doc.get("product_revision")
if not isinstance(rev, str) or not re.fullmatch(r"[0-9a-f]{40}", rev):
    fail("product_revision must be a 40-char lowercase git sha")

recorded = doc.get("recorded_at_utc")
if not isinstance(recorded, str) or not re.fullmatch(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", recorded
):
    fail("recorded_at_utc must be UTC Zulu second precision")

claims = doc.get("claims")
if not isinstance(claims, dict):
    fail("claims object required")
for key in (
    "physical_android",
    "physical_ipad",
    "windows_origin_exercised",
    "simulator_or_emulator",
    "secrets_redacted",
):
    if key not in claims or not isinstance(claims[key], bool):
        fail(f"claims.{key} must be boolean")

if claims.get("secrets_redacted") is not True:
    fail("claims.secrets_redacted must be true")

if claims.get("simulator_or_emulator") is True:
    fail("simulator_or_emulator=true is forbidden for this lab")

verdict = doc.get("verdict")
allowed = {
    "matrix_passed",
    "matrix_failed",
    "lab_incomplete",
    "lab_unreachable_on_this_host",
    "rejected_secrets_or_schema",
}
if verdict not in allowed:
    fail(f"verdict not in {sorted(allowed)}")

if verdict == "rejected_secrets_or_schema":
    fail("verdict rejected_secrets_or_schema is not acceptable input")

# Secret scan over all strings.
strings: list[str] = []
walk_strings(doc, strings)
blob = "\n".join(strings)
for pat in SECRET_PATTERNS:
    if pat.search(blob):
        fail("secret-like pattern detected; redact and set claims.secrets_redacted")
if FULL_ORIGIN.search(blob):
    fail("full windows-<uuid> origin id is forbidden; use origin_id_prefix only")

wh = doc.get("windows_host")
if wh is not None:
    if not isinstance(wh, dict):
        fail("windows_host must be object")
    prefix = wh.get("origin_id_prefix")
    if prefix is not None and (
        not isinstance(prefix, str) or not re.fullmatch(r"[0-9a-f]{12}", prefix)
    ):
        fail("windows_host.origin_id_prefix must be 12 lowercase hex chars")

platforms = doc.get("platforms") or {}
if platforms is not None and not isinstance(platforms, dict):
    fail("platforms must be object")


def row_outcomes(platform_name: str) -> list[str]:
    if not isinstance(platforms, dict) or platform_name not in platforms:
        return []
    plat = platforms[platform_name]
    if not isinstance(plat, dict):
        fail(f"platforms.{platform_name} must be object")
    label = plat.get("device_label")
    if not isinstance(label, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", label
    ):
        fail(f"platforms.{platform_name}.device_label invalid")
    rows = plat.get("rows")
    if not isinstance(rows, dict):
        fail(f"platforms.{platform_name}.rows required")
    out = []
    for rid in ROW_IDS:
        if rid not in rows:
            fail(f"platforms.{platform_name}.rows.{rid} missing")
        row = rows[rid]
        if not isinstance(row, dict):
            fail(f"row {rid} must be object")
        outcome = row.get("outcome")
        if outcome not in ("passed", "failed", "skipped", "not_run"):
            fail(f"row {rid} outcome invalid")
        notes = row.get("notes", "")
        if notes is not None and (not isinstance(notes, str) or len(notes) > 512):
            fail(f"row {rid} notes too long")
        at = row.get("at_utc")
        if at is not None and (
            not isinstance(at, str)
            or not re.fullmatch(
                r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", at
            )
        ):
            fail(f"row {rid} at_utc invalid")
        out.append(outcome)
    return out


android_out = row_outcomes("android") if "android" in (platforms or {}) else []
ipad_out = row_outcomes("ipad") if "ipad" in (platforms or {}) else []


def all_passed(outcomes: list[str]) -> bool:
    return bool(outcomes) and all(o == "passed" for o in outcomes)


def any_failed(outcomes: list[str]) -> bool:
    return any(o == "failed" for o in outcomes)


# Claim honesty.
if claims["physical_android"] and not all_passed(android_out) and not any_failed(android_out):
    # physical true requires a completed platform (all passed or at least one failed)
    if not android_out or any(o in ("skipped", "not_run") for o in android_out):
        fail("claims.physical_android=true requires completed android rows (no not_run/skipped)")

if claims["physical_ipad"] and (
    not ipad_out or any(o in ("skipped", "not_run") for o in ipad_out)
):
    fail("claims.physical_ipad=true requires completed ipad rows (no not_run/skipped)")

if claims["windows_origin_exercised"] is True:
    if not claims["physical_android"] and not claims["physical_ipad"]:
        fail("windows_origin_exercised=true requires a physical platform claim")

if verdict == "matrix_passed":
    if claims["simulator_or_emulator"]:
        fail("matrix_passed forbids simulator_or_emulator")
    if not claims["physical_android"] or not claims["physical_ipad"]:
        fail("matrix_passed requires physical_android and physical_ipad")
    if not claims["windows_origin_exercised"]:
        fail("matrix_passed requires windows_origin_exercised")
    if not all_passed(android_out) or not all_passed(ipad_out):
        fail("matrix_passed requires every android and ipad row outcome=passed")
    wh = doc.get("windows_host") or {}
    if not isinstance(wh, dict) or wh.get("profiles_collision_free") is not True:
        fail("matrix_passed requires windows_host.profiles_collision_free=true")
    if wh.get("trusted_lan") != "private_rfc1918":
        fail("matrix_passed requires windows_host.trusted_lan=private_rfc1918")
elif verdict == "lab_unreachable_on_this_host":
    if claims["physical_android"] or claims["physical_ipad"] or claims["windows_origin_exercised"]:
        fail("lab_unreachable_on_this_host forbids physical/windows claims true")
elif verdict == "matrix_failed":
    if not (any_failed(android_out) or any_failed(ipad_out)):
        fail("matrix_failed requires at least one failed row")
elif verdict == "lab_incomplete":
    # Must not claim full physical pass bits inconsistently with incomplete rows
    if claims["physical_android"] and claims["physical_ipad"] and claims["windows_origin_exercised"]:
        if all_passed(android_out) and all_passed(ipad_out):
            fail("lab_incomplete with full passes should be matrix_passed")

# Schema file presence is part of the contract (docs + CI pin).
if not schema_path.is_file():
    fail("committed schema file missing")

print(verdict)
sys.exit(0)
PY
}

case "$MODE" in
  template)
    print_template
    exit 0
    ;;
  self-check)
    log "self-check for #377 (never claims physical pass)"
    if ! run_self_check; then
      echo "ERROR: self-check failed to write evidence" >&2
      exit 2
    fi
    if [[ -n "$EVIDENCE_PATH" ]]; then
      log "wrote $EVIDENCE_PATH"
      # Ensure self-check output validates.
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
  *)
    usage >&2
    exit 1
    ;;
esac
