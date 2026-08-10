#!/usr/bin/env bash
#
# verify_windows_release_gate_evidence.sh — #376 Windows release-gate evidence.
#
# This script NEVER pretends production Authenticode, clean-machine, or real
# reboot passed on a Linux/devbox host. Modes:
#
#   --self-check / --dry-run
#       Probe this host. Always writes claims.production_signed=false,
#       claims.real_reboot=false, claims.clean_machine_no_tooling=false and
#       verdict gate_unreachable_on_this_host (definition check only).
#
#   --validate-evidence PATH [--fixture-dir DIR]
#       Fail-closed schema + claims + secret scan for operator-produced JSON.
#       Strong claims (production_signed / real_reboot / clean_machine_no_tooling)
#       require explicit fixture files under --fixture-dir named by fixture_refs.
#       Without those fixtures, true claims are rejected (no silent green).
#
#   --print-template
#       Emit an empty gate_incomplete template to stdout (for operators).
#
#   --print-operator-steps
#       Print the exact external Windows operator commands for #376.
#
# Exit codes:
#   0  ok for the requested mode
#   1  usage
#   2  self-check could not write evidence
#   3  evidence rejected (schema, secrets, dishonest claims, missing fixtures)
#   4  evidence file missing/unreadable
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEMA_PATH="${ROOT}/scripts/schemas/windows_release_gate_evidence.schema.json"
MODE=""
EVIDENCE_PATH=""
VALIDATE_PATH=""
FIXTURE_DIR=""

usage() {
  cat <<'EOF'
Usage: verify_windows_release_gate_evidence.sh --self-check|--dry-run [--evidence PATH]
       verify_windows_release_gate_evidence.sh --validate-evidence PATH [--fixture-dir DIR]
       verify_windows_release_gate_evidence.sh --print-template
       verify_windows_release_gate_evidence.sh --print-operator-steps

Windows channel release-gate evidence for issue #376 (extends #795 honesty).

  --self-check / --dry-run   Probe this host; never sets strong claims true.
  --evidence PATH            Where self-check writes JSON.
  --validate-evidence P      Validate operator evidence (fail closed).
  --fixture-dir DIR          Required when validating true strong claims.
  --print-template           Print an empty gate_incomplete template JSON.
  --print-operator-steps     Print production-sign + clean Win11 + reboot steps.

A Linux/devbox dry-run is not release-gate completion. Do not close #376 on it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-check|--dry-run) MODE="self-check"; shift ;;
    --validate-evidence)
      MODE="validate"
      VALIDATE_PATH="${2:-}"
      [[ -n "$VALIDATE_PATH" ]] || { echo "ERROR: --validate-evidence needs a path" >&2; exit 1; }
      shift 2
      ;;
    --fixture-dir)
      FIXTURE_DIR="${2:-}"
      [[ -n "$FIXTURE_DIR" ]] || { echo "ERROR: --fixture-dir needs a path" >&2; exit 1; }
      shift 2
      ;;
    --evidence)
      EVIDENCE_PATH="${2:-}"
      [[ -n "$EVIDENCE_PATH" ]] || { echo "ERROR: --evidence needs a path" >&2; exit 1; }
      shift 2
      ;;
    --print-template) MODE="template"; shift ;;
    --print-operator-steps) MODE="operator-steps"; shift ;;
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

print_operator_steps() {
  cat <<'EOF'
#376 external operator steps (Windows only — not this Linux/devbox)

NEED (human): production-authenticode + clean-win11 + real-reboot
Operator steps:
  1) On a protected Windows release runner with the production code-signing cert:
       $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
         Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) }
       $cert | Format-Table Subject, Thumbprint, NotAfter
       powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package-windows-desktop.ps1 `
         -SigningCertificateThumbprint $cert[0].Thumbprint -RequireSigned
       powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-desktop-package.ps1 `
         -PackageRoot dist\Casein-windows-x64
     Write fixture production_sign.json (subject, thumbprint, file hashes; no private key).

  2) On a disposable clean Windows 11 account (no language tooling, no WSL):
       powershell -NoProfile -ExecutionPolicy Bypass -File windows\Test-CaseinCleanMachine.ps1 `
         -PackageRoot <signed-package-root> `
         -AcceptDestructiveCleanMachineTest `
         -RequireNoDeveloperTooling `
         -EvidencePath <out>\clean_machine.json
     claims.clean_machine_no_tooling must be true; claims.real_reboot stays false.

  3) Real reboot persistence (not -SelfTestContinuation, not simulate):
       powershell -NoProfile -ExecutionPolicy Bypass -File windows\Test-CaseinRebootPersistence.ps1 `
         -PackageRoot <signed-package-root> -AcceptDestructiveCleanMachineTest -Stage prepare ...
       # reboot the host
       powershell -NoProfile -ExecutionPolicy Bypass -File windows\Test-CaseinRebootPersistence.ps1 `
         -PackageRoot <signed-package-root> -AcceptDestructiveCleanMachineTest -Stage continue ...
     Attach JSON only if claims.real_reboot=true (boot stamp changed).

  4) Assemble release-gate evidence + fixtures, then validate:
       bash scripts/verify_windows_release_gate_evidence.sh --print-template > evidence.json
       # fill claims + fixture_refs; place fixtures under ./fixtures/
       bash scripts/verify_windows_release_gate_evidence.sh \
         --validate-evidence evidence.json --fixture-dir ./fixtures

Unblocks when: validated evidence with verdict release_gate_passed is attached on #376
(and production cert / clean Win11 / real reboot fixtures are present). Never close #376
from a Linux dry-run or package -SelfTestContinuation smoke.
EOF
}

print_template() {
  local sha
  sha="$(git_sha)"
  python3 - "$sha" <<'PY'
import json, sys
from datetime import datetime, timezone
sha = sys.argv[1]
if len(sha) != 40:
    sha = "0" * 40
doc = {
    "schema": "casein_windows_release_gate",
    "schema_version": 1,
    "issue": 376,
    "recorded_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "product_revision": sha,
    "operator": "replace-me",
    "claims": {
        "production_signed": False,
        "real_reboot": False,
        "clean_machine_no_tooling": False,
        "linux_devbox_run": False,
        "secrets_redacted": True,
    },
    "host_probe": {
        "uname": "",
        "is_windows": False,
        "signtool_present": False,
        "notes": "Fill after external Windows run. Dry-run/self-check must not set strong claims.",
    },
    "fixture_refs": {
        "production_sign": "production_sign.json",
        "clean_machine": "clean_machine.json",
        "real_reboot": "real_reboot.json",
    },
    "operator_commands": [
        "scripts/package-windows-desktop.ps1 -SigningCertificateThumbprint <thumb> -RequireSigned",
        "scripts/test-windows-desktop-package.ps1 -PackageRoot dist\\Casein-windows-x64",
        "windows/Test-CaseinCleanMachine.ps1 -AcceptDestructiveCleanMachineTest -RequireNoDeveloperTooling",
        "windows/Test-CaseinRebootPersistence.ps1 -Stage prepare|continue (real reboot between)",
    ],
    "attachments": {"log_refs": [], "issue_comment_urls": []},
    "verdict": "gate_incomplete",
}
json.dump(doc, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}

run_self_check() {
  local uname_s notes signtool=false is_windows=false
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  if [[ "$uname_s" == MINGW* || "$uname_s" == MSYS* || "$uname_s" == CYGWIN* || "$uname_s" == Windows_NT ]]; then
    is_windows=true
  fi
  if command -v signtool.exe >/dev/null 2>&1 || command -v signtool >/dev/null 2>&1; then
    signtool=true
  fi

  notes="Dry-run/self-check only. Strong claims stay false. Production Authenticode, disposable clean Win11, and real reboot remain external (#376)."
  if [[ "$uname_s" == "Linux" || "$uname_s" == "Darwin" ]]; then
    notes="${notes} Host uname=${uname_s} cannot prove clean-machine or production-sign."
  fi

  local sha recorded
  sha="$(git_sha)"
  recorded="$(utc_now)"

  python3 - "$sha" "$recorded" "$uname_s" "$is_windows" "$signtool" "$notes" "${EVIDENCE_PATH:--}" <<'PY'
import json, sys
sha, recorded, uname_s, is_windows, signtool, notes, dest = sys.argv[1:8]
if len(sha) != 40:
    sha = "0" * 40
doc = {
    "schema": "casein_windows_release_gate",
    "schema_version": 1,
    "issue": 376,
    "recorded_at_utc": recorded,
    "product_revision": sha,
    "operator": "self-check",
    "claims": {
        # NEVER pretends production Authenticode / clean-machine / real reboot.
        "production_signed": False,
        "real_reboot": False,
        "clean_machine_no_tooling": False,
        "linux_devbox_run": uname_s in ("Linux", "Darwin"),
        "secrets_redacted": True,
    },
    "host_probe": {
        "uname": uname_s,
        "is_windows": is_windows == "true",
        "signtool_present": signtool == "true",
        "notes": notes,
    },
    "fixture_refs": {},
    "operator_commands": [
        "scripts/package-windows-desktop.ps1 -SigningCertificateThumbprint <thumb> -RequireSigned",
        "windows/Test-CaseinCleanMachine.ps1 -AcceptDestructiveCleanMachineTest -RequireNoDeveloperTooling",
        "windows/Test-CaseinRebootPersistence.ps1 -Stage prepare then real reboot then -Stage continue",
    ],
    "attachments": {"log_refs": [], "issue_comment_urls": []},
    "verdict": "gate_unreachable_on_this_host",
}
text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
if dest == "-":
    sys.stdout.write(text)
else:
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(text)
print("gate_unreachable_on_this_host", file=sys.stderr)
PY
}

validate_evidence() {
  local path="$1"
  local fixture_dir="${2:-}"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: evidence file missing: $path" >&2
    exit 4
  fi
  if [[ ! -f "$SCHEMA_PATH" ]]; then
    echo "ERROR: committed schema missing: $SCHEMA_PATH" >&2
    exit 3
  fi

  python3 - "$path" "$SCHEMA_PATH" "$fixture_dir" <<'PY'
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])
fixture_dir = Path(sys.argv[3]) if sys.argv[3] else None

SECRET_PATTERNS = [
    re.compile(r"BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY"),
    re.compile(r"pairing_token\s*="),
    re.compile(r"CASEIN_API_TOKEN\s*="),
    re.compile(r"password\s*[:=]\s*\S+", re.I),
    re.compile(r"thumbprint_private", re.I),
]


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

if doc.get("schema") != "casein_windows_release_gate":
    fail("schema must be casein_windows_release_gate")
if doc.get("schema_version") != 1:
    fail("schema_version must be 1")
if doc.get("issue") != 376:
    fail("issue must be 376")

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
    "production_signed",
    "real_reboot",
    "clean_machine_no_tooling",
    "linux_devbox_run",
    "secrets_redacted",
):
    if key not in claims or not isinstance(claims[key], bool):
        fail(f"claims.{key} must be boolean")

if claims.get("secrets_redacted") is not True:
    fail("claims.secrets_redacted must be true")

verdict = doc.get("verdict")
allowed = {
    "release_gate_passed",
    "release_gate_failed",
    "gate_incomplete",
    "gate_unreachable_on_this_host",
    "rejected_secrets_or_schema",
}
if verdict not in allowed:
    fail(f"verdict not in {sorted(allowed)}")
if verdict == "rejected_secrets_or_schema":
    fail("verdict rejected_secrets_or_schema is not acceptable input")

strings: list[str] = []
walk_strings(doc, strings)
blob = "\n".join(strings)
for pat in SECRET_PATTERNS:
    if pat.search(blob):
        fail("secret-like pattern detected; redact and set claims.secrets_redacted")

# Linux/devbox honesty: dry-run hosts must not claim external cells.
if claims.get("linux_devbox_run") is True:
    for strong in ("production_signed", "real_reboot", "clean_machine_no_tooling"):
        if claims.get(strong) is True:
            fail(f"linux_devbox_run=true forbids claims.{strong}=true")
    if verdict == "release_gate_passed":
        fail("linux_devbox_run=true forbids release_gate_passed")

if verdict == "gate_unreachable_on_this_host":
    for strong in ("production_signed", "real_reboot", "clean_machine_no_tooling"):
        if claims.get(strong) is True:
            fail(f"gate_unreachable_on_this_host forbids claims.{strong}=true")

fixture_refs = doc.get("fixture_refs") or {}
if fixture_refs is not None and not isinstance(fixture_refs, dict):
    fail("fixture_refs must be object")


def load_fixture(claim_key: str, ref_key: str) -> dict:
    if not isinstance(fixture_refs, dict) or ref_key not in fixture_refs:
        fail(f"claims.{claim_key}=true requires fixture_refs.{ref_key}")
    name = fixture_refs[ref_key]
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", name):
        fail(f"fixture_refs.{ref_key} invalid")
    if fixture_dir is None or not fixture_dir.is_dir():
        fail(
            f"claims.{claim_key}=true requires --fixture-dir with operator fixture files "
            f"(missing dir for {name})"
        )
    fpath = fixture_dir / name
    if not fpath.is_file():
        fail(f"claims.{claim_key}=true missing fixture file: {name}")
    try:
        raw_f = fpath.read_text(encoding="utf-8")
    except OSError:
        fail(f"unreadable fixture: {name}")
    if len(raw_f) > 512_000:
        fail(f"fixture {name} exceeds 512 KiB bound")
    f_strings: list[str] = []
    try:
        fdoc = json.loads(raw_f)
    except json.JSONDecodeError:
        fail(f"fixture {name} is not valid JSON")
    walk_strings(fdoc, f_strings)
    fblob = "\n".join(f_strings)
    for pat in SECRET_PATTERNS:
        if pat.search(fblob):
            fail(f"fixture {name} contains secret-like pattern")
    if not isinstance(fdoc, dict):
        fail(f"fixture {name} root must be object")
    return fdoc


if claims.get("production_signed") is True:
    fdoc = load_fixture("production_signed", "production_sign")
    # Explicit operator attestation — fake fixtures without these keys fail closed.
    thumb = fdoc.get("signer_thumbprint") or fdoc.get("thumbprint")
    subject = fdoc.get("signer_subject") or fdoc.get("subject")
    require_signed = fdoc.get("require_signed")
    if not isinstance(thumb, str) or not re.fullmatch(r"[0-9A-Fa-f]{40}", thumb):
        fail("production_sign fixture needs 40-hex signer_thumbprint")
    if not isinstance(subject, str) or len(subject) < 3 or len(subject) > 256:
        fail("production_sign fixture needs signer_subject")
    if require_signed is not True:
        fail("production_sign fixture requires require_signed=true (-RequireSigned path)")
    if fdoc.get("private_key_material") is not None:
        fail("production_sign fixture must not include private_key_material")
    files = fdoc.get("signed_files") or fdoc.get("file_hashes")
    if not isinstance(files, list) or len(files) < 1:
        fail("production_sign fixture needs non-empty signed_files/file_hashes")

if claims.get("real_reboot") is True:
    fdoc = load_fixture("real_reboot", "real_reboot")
    # Prefer nested claims from Test-CaseinRebootPersistence evidence, or top-level.
    nested = fdoc.get("claims") if isinstance(fdoc.get("claims"), dict) else {}
    real = nested.get("real_reboot", fdoc.get("real_reboot"))
    if real is not True:
        fail("real_reboot fixture must record claims.real_reboot=true (boot stamp changed)")
    # Boot stamps must differ when both present (fail closed on equal stamps).
    before = fdoc.get("boot_stamp_before") or nested.get("boot_stamp_before")
    after = fdoc.get("boot_stamp_after") or nested.get("boot_stamp_after")
    if before is not None and after is not None and before == after:
        fail("real_reboot fixture boot stamps must differ")
    if fdoc.get("self_test_continuation") is True or nested.get("self_test_continuation") is True:
        fail("real_reboot fixture must not be -SelfTestContinuation output")

if claims.get("clean_machine_no_tooling") is True:
    fdoc = load_fixture("clean_machine_no_tooling", "clean_machine")
    nested = fdoc.get("claims") if isinstance(fdoc.get("claims"), dict) else {}
    clean = nested.get("clean_machine_no_tooling", fdoc.get("clean_machine_no_tooling"))
    if clean is not True:
        fail("clean_machine fixture must record claims.clean_machine_no_tooling=true")
    # Clean-machine harness always keeps real_reboot false.
    nested_reboot = nested.get("real_reboot", fdoc.get("real_reboot"))
    if nested_reboot is True:
        fail("clean_machine fixture must not claim real_reboot=true")

if verdict == "release_gate_passed":
    if not claims.get("production_signed"):
        fail("release_gate_passed requires claims.production_signed=true")
    if not claims.get("real_reboot"):
        fail("release_gate_passed requires claims.real_reboot=true")
    if not claims.get("clean_machine_no_tooling"):
        fail("release_gate_passed requires claims.clean_machine_no_tooling=true")
    if claims.get("linux_devbox_run"):
        fail("release_gate_passed forbids linux_devbox_run")
elif verdict == "release_gate_failed":
    # Failed is allowed with partial strong claims + fixtures already checked above.
    pass
elif verdict == "gate_incomplete":
    if (
        claims.get("production_signed")
        and claims.get("real_reboot")
        and claims.get("clean_machine_no_tooling")
    ):
        fail("gate_incomplete with all strong claims true should be release_gate_passed")

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
  operator-steps)
    print_operator_steps
    exit 0
    ;;
  self-check)
    log "self-check/dry-run for #376 (never claims production-sign / clean-machine / real reboot)"
    if ! run_self_check; then
      echo "ERROR: self-check failed to write evidence" >&2
      exit 2
    fi
    if [[ -n "$EVIDENCE_PATH" ]]; then
      log "wrote $EVIDENCE_PATH"
      validate_evidence "$EVIDENCE_PATH" ""
    fi
    log "OK: gate_unreachable_on_this_host (definition check only)"
    exit 0
    ;;
  validate)
    log "validating evidence $VALIDATE_PATH"
    verdict="$(validate_evidence "$VALIDATE_PATH" "$FIXTURE_DIR")"
    log "verdict: $verdict"
    log "OK: evidence accepted as $verdict"
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
