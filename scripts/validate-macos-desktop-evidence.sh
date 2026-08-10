#!/usr/bin/env bash
# Validate a macOS desktop release evidence JSON document (issue #382 schema).
#
# This is a software gate only. It never claims Developer ID / notarization
# succeeded without the material fields present in the JSON. It rejects silent
# green documents that omit explicit missing[] when incomplete.
#
# Strong claims (developer_id / notarized / stapled / signed_lifecycle /
# passed_release) may optionally be backed by operator fixture files under
# --fixture-dir (named by fixture_refs). Without those fixtures, true strong
# claims that are not already proven by app.* material fields are rejected.
#
# Usage:
#   scripts/validate-macos-desktop-evidence.sh path/to/*.evidence.json
#   scripts/validate-macos-desktop-evidence.sh --print-needs path/to/*.evidence.json
#   scripts/validate-macos-desktop-evidence.sh --fixture-dir DIR path/to/*.evidence.json
#   scripts/validate-macos-desktop-evidence.sh --print-template
#   scripts/validate-macos-desktop-evidence.sh --print-operator-steps
#   scripts/validate-macos-desktop-evidence.sh --check-schema
#
# Exit codes:
#   0  document is schema-valid and honest for its result (or print mode ok)
#   1  usage / IO error
#   2  schema or honesty failure (overclaim, missing fields, bad shape)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEMA_PATH="${ROOT}/scripts/schemas/macos_desktop_release_evidence.schema.json"
print_needs=0
print_template=0
print_operator_steps=0
check_schema=0
fixture_dir=""
path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-needs) print_needs=1; shift ;;
    --print-template) print_template=1; shift ;;
    --print-operator-steps) print_operator_steps=1; shift ;;
    --check-schema) check_schema=1; shift ;;
    --fixture-dir)
      fixture_dir="${2:-}"
      [[ -n "$fixture_dir" ]] || { echo "ERROR: --fixture-dir needs a path" >&2; exit 1; }
      shift 2
      ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$path" ]]; then
        echo "only one evidence path accepted" >&2
        exit 1
      fi
      path="$1"
      shift
      ;;
  esac
done

if [[ "$print_operator_steps" -eq 1 ]]; then
  cat <<'EOF'
NEED (human): Apple notarize credentials (Developer ID Application/Installer + notary profile on release Mac)

Operator steps:
1. On a release Mac with Xcode CLT: security find-identity -v -p codesigning
2. Install Developer ID Application (and Developer ID Installer if shipping a pkg).
3. Store notary credentials (never commit them):
     xcrun notarytool store-credentials casein-notary \
       --apple-id 'operator@example.com' \
       --team-id 'TEAMID' \
       --password '<app-specific-password>'
4. Clean tree package:
     export CASEIN_CODESIGN_IDENTITY='Developer ID Application: Example Org (TEAMID)'
     export CASEIN_REQUIRE_DEVELOPER_ID=1
     scripts/package-macos-desktop.sh
5. Verify:
     scripts/verify-macos-desktop-release.sh --require-developer-id --require-hardened-runtime
6. Notarize + staple:
     export CASEIN_NOTARY_KEYCHAIN_PROFILE=casein-notary
     scripts/notarize-macos-desktop.sh native/casein_menubar/build/artifacts/Casein-*-macos-*.zip
7. Clean-Mac lifecycle checklist (docs/desktop/macos_release_evidence.md):
   first launch, login-item, update/rollback if applicable, uninstall.
8. Collect + attest lifecycle (after material sign+staple):
     CASEIN_LIFECYCLE_ATTESTED=1 scripts/collect-macos-desktop-evidence.sh \
       --app 'native/casein_menubar/build/Casein MenuBar.app' \
       --archive native/casein_menubar/build/artifacts/Casein-*-macos-*.zip
9. Optional local stage (survives Actions artifact quota):
     scripts/stage-macos-desktop-artifacts.sh --mode skip
10. Validate honesty gate:
     scripts/validate-macos-desktop-evidence.sh --print-needs \
       native/casein_menubar/build/artifacts/*.evidence.json
11. Attach *.evidence.json + zip sha256 + Team ID + redacted logs to issue #382.
    Do not rely on actions/upload-artifact (account-level quota may refuse).

Unblocks when: validate exits 0 on result=passed_release with empty missing[],
and hashes/Team ID/redacted logs are attached on #382.
EOF
  exit 0
fi

if [[ "$check_schema" -eq 1 ]]; then
  if [[ ! -f "$SCHEMA_PATH" ]]; then
    echo "schema missing: $SCHEMA_PATH" >&2
    exit 1
  fi
  python3 - <<'PY' "$SCHEMA_PATH"
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
assert data.get("$schema"), "schema must declare $schema"
assert data.get("title"), "schema must have title"
assert data.get("properties", {}).get("kind", {}).get("const") == "macos_desktop_release_evidence"
print(f"SCHEMA_OK: {path}")
PY
  exit 0
fi

if [[ "$print_template" -eq 1 ]]; then
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rev="$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"
  desc="$(git describe --always --dirty 2>/dev/null || echo template)"
  python3 - <<PY
import json
doc = {
  "schema": 1,
  "kind": "macos_desktop_release_evidence",
  "issue": 382,
  "started_at_utc": "$started",
  "completed_at_utc": "$started",
  "result": "incomplete",
  "error": "operator template — fill on release Mac; do not claim passed_release without material",
  "missing": ["developer_id", "notary_profile", "signed_lifecycle"],
  "claims": {
    "developer_id": False,
    "notarized": False,
    "stapled": False,
    "signed_lifecycle": False,
    "passed_release": False,
  },
  "fixture_refs": {},
  "staging": {
    "receipt_path": "",
    "receipt_mode": "skip",
    "upload_attempted": False,
    "upload_succeeded": False,
  },
  "git": {"revision": "$rev", "describe": "$desc", "github_sha": ""},
  "host": {
    "os": "Darwin",
    "arch": "arm64",
    "release": "",
    "runner_name": "",
    "runner_os": "",
    "runner_arch": "",
    "github_run_id": "",
  },
  "app": {
    "path": "native/casein_menubar/build/Casein MenuBar.app",
    "exists": False,
    "bundle_identifier": "",
    "signature_kind": "missing",
    "signer_authority": "",
    "team_identifier": "",
    "codesign_flags": "",
    "hardened_runtime": False,
    "codesign_verify": "skipped",
    "spctl": "skipped",
    "stapler": "skipped",
  },
  "archive": {"path": "", "exists": False, "sha256": "", "bytes": 0},
  "phases": ["operator_template"],
  "notes": [
    "Template only — not release evidence until filled on a credentialed Mac.",
    "Never store Apple credentials, certificates, or notarization tokens in this file.",
  ],
}
print(json.dumps(doc, indent=2))
PY
  exit 0
fi

if [[ -z "$path" ]]; then
  echo "usage: $0 [--print-needs] [--fixture-dir DIR] path/to/evidence.json" >&2
  echo "       $0 --print-template | --print-operator-steps | --check-schema" >&2
  exit 1
fi

if [[ ! -f "$path" ]]; then
  echo "evidence file not found: $path" >&2
  exit 1
fi

export CASEIN_EVIDENCE_PATH="$path"
export CASEIN_EVIDENCE_PRINT_NEEDS="$print_needs"
export CASEIN_EVIDENCE_FIXTURE_DIR="$fixture_dir"
export CASEIN_EVIDENCE_SCHEMA_PATH="$SCHEMA_PATH"

python3 - <<'PY'
import json
import os
import re
import sys
from pathlib import Path

path = os.environ["CASEIN_EVIDENCE_PATH"]
print_needs = os.environ.get("CASEIN_EVIDENCE_PRINT_NEEDS") == "1"
fixture_dir = os.environ.get("CASEIN_EVIDENCE_FIXTURE_DIR") or ""
schema_path = os.environ.get("CASEIN_EVIDENCE_SCHEMA_PATH") or ""

REQUIRED_TOP = (
    "schema",
    "kind",
    "issue",
    "started_at_utc",
    "completed_at_utc",
    "result",
    "git",
    "host",
    "app",
    "archive",
    "phases",
    "notes",
)
REQUIRED_APP = (
    "path",
    "exists",
    "signature_kind",
    "signer_authority",
    "team_identifier",
    "hardened_runtime",
    "codesign_verify",
    "spctl",
    "stapler",
)
REQUIRED_ARCHIVE = ("path", "exists", "sha256", "bytes")
REQUIRED_GIT = ("revision", "describe")
REQUIRED_HOST = ("os", "arch")

CANONICAL_MISSING = ("developer_id", "notary_profile", "signed_lifecycle")
ALLOWED_EXTRA_MISSING = {
    "app_bundle",
    "archive",
    "darwin_host",
    "codesign_tools",
}

RELEASE_RESULTS = frozenset({"passed_release"})
INCOMPLETE_OK = frozenset(
    {
        "incomplete",
        "blocked",
        "failed",
        "adhoc_smoke_only",
        "signed_unnotarized",
        "running",
    }
)

UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
FIXTURE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")

NEED_LINES = {
    "developer_id": (
        "NEED (human): developer_id",
        "Install Developer ID Application (and Installer if shipping a pkg) on the release Mac keychain.",
        "security find-identity -v -p codesigning shows Developer ID Application: …",
    ),
    "notary_profile": (
        "NEED (human): notary_profile",
        "Store notarytool credentials: xcrun notarytool store-credentials casein-notary …",
        "CASEIN_NOTARY_KEYCHAIN_PROFILE is set and notarize-macos-desktop.sh staples green",
    ),
    "signed_lifecycle": (
        "NEED (human): signed_lifecycle",
        "On a clean supported macOS: first launch, login-item, update/rollback if applicable, uninstall; attach notes.",
        "Lifecycle checklist in docs/desktop/macos_release_evidence.md completed and attached",
    ),
}

SECRET_NEEDLES = (
    "begin certificate",
    "begin private key",
    "begin rsa private key",
    "casein_notary_app_password",
    "authkey_",
    "-----begin",
)


def fail(msg: str) -> None:
    print(f"INVALID: {msg}", file=sys.stderr)
    sys.exit(2)


def material_proves_developer_id(app: dict) -> bool:
    return (
        app.get("signature_kind") == "developer_id"
        and app.get("hardened_runtime") is True
        and app.get("codesign_verify") == "passed"
        and bool(app.get("team_identifier"))
    )


def material_proves_notarized(app: dict) -> bool:
    return material_proves_developer_id(app) and app.get("spctl") == "accepted"


def material_proves_stapled(app: dict) -> bool:
    return material_proves_developer_id(app) and app.get("stapler") == "valid"


def fixture_present(refs: dict, key: str) -> bool:
    if not fixture_dir:
        return False
    name = refs.get(key)
    if not isinstance(name, str) or not name:
        return False
    if not FIXTURE_NAME_RE.match(name):
        fail(f"fixture_refs.{key} has illegal name {name!r}")
    base = Path(fixture_dir)
    # Allow bare name or name with common suffixes staged by operators.
    candidates = [
        base / name,
        base / f"{name}.txt",
        base / f"{name}.json",
        base / f"{name}.log",
    ]
    return any(p.is_file() and p.stat().st_size > 0 for p in candidates)


def main() -> None:
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"read failed: {exc}", file=sys.stderr)
        sys.exit(1)

    lowered = raw.lower()
    for needle in SECRET_NEEDLES:
        if needle in lowered:
            fail(f"evidence must not embed secret material ({needle})")

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"not JSON: {exc}")

    if not isinstance(data, dict):
        fail("root must be object")

    # Optional structural check against checked-in schema file (const/required only;
    # full JSON Schema draft engines are not a repo dependency).
    if schema_path and Path(schema_path).is_file():
        try:
            schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"schema file unreadable: {exc}")
        if schema.get("properties", {}).get("kind", {}).get("const") != data.get("kind"):
            fail("kind does not match scripts/schemas/macos_desktop_release_evidence.schema.json")
        if schema.get("properties", {}).get("issue", {}).get("const") != data.get("issue"):
            fail("issue does not match schema const 382")
        if schema.get("properties", {}).get("schema", {}).get("const") != data.get("schema"):
            fail("schema version does not match schema const 1")

    for key in REQUIRED_TOP:
        if key not in data:
            fail(f"missing top-level field: {key}")

    if data.get("schema") != 1:
        fail(f"schema must be 1, got {data.get('schema')!r}")
    if data.get("kind") != "macos_desktop_release_evidence":
        fail(f"kind must be macos_desktop_release_evidence, got {data.get('kind')!r}")
    if data.get("issue") != 382:
        fail(f"issue must be 382, got {data.get('issue')!r}")

    for ts_key in ("started_at_utc", "completed_at_utc"):
        ts = data.get(ts_key)
        if not isinstance(ts, str) or not UTC_RE.match(ts):
            fail(f"{ts_key} must be UTC ISO-8601 ending in Z")

    result = data.get("result")
    if not isinstance(result, str) or not result:
        fail("result must be non-empty string")

    for section, keys in (
        ("git", REQUIRED_GIT),
        ("host", REQUIRED_HOST),
        ("app", REQUIRED_APP),
        ("archive", REQUIRED_ARCHIVE),
    ):
        obj = data.get(section)
        if not isinstance(obj, dict):
            fail(f"{section} must be object")
        for key in keys:
            if key not in obj:
                fail(f"{section}.{key} missing")

    if not isinstance(data.get("phases"), list):
        fail("phases must be list")
    if not isinstance(data.get("notes"), list):
        fail("notes must be list")

    missing = data.get("missing")
    if missing is None:
        missing = []
    if not isinstance(missing, list) or not all(isinstance(x, str) for x in missing):
        fail("missing must be a list of strings when present")

    claims = data.get("claims")
    if claims is None:
        claims = {}
    if not isinstance(claims, dict):
        fail("claims must be object when present")

    fixture_refs = data.get("fixture_refs") or {}
    if not isinstance(fixture_refs, dict):
        fail("fixture_refs must be object when present")

    staging = data.get("staging")
    if staging is not None:
        if not isinstance(staging, dict):
            fail("staging must be object when present")
        # Staging never proves release; upload success is not #382 completion.
        if staging.get("upload_succeeded") is True and result not in RELEASE_RESULTS:
            # Allowed — local stage/upload of incomplete evidence is fine.
            pass
        if claims.get("passed_release") is True and staging.get("upload_succeeded") is True:
            # upload success must not be the only proof; material still required below.
            pass

    app = data["app"]
    archive = data["archive"]

    # Honesty: never accept passed_release without material proof fields.
    if result in RELEASE_RESULTS:
        if missing:
            fail("passed_release must not list missing[] items")
        if app.get("signature_kind") != "developer_id":
            fail("passed_release requires app.signature_kind=developer_id")
        if app.get("hardened_runtime") is not True:
            fail("passed_release requires app.hardened_runtime=true")
        if app.get("spctl") != "accepted":
            fail("passed_release requires app.spctl=accepted")
        if app.get("stapler") != "valid":
            fail("passed_release requires app.stapler=valid")
        if app.get("codesign_verify") != "passed":
            fail("passed_release requires app.codesign_verify=passed")
        if not app.get("team_identifier"):
            fail("passed_release requires app.team_identifier")
        if not archive.get("exists"):
            fail("passed_release requires archive.exists=true")
        sha = archive.get("sha256") or ""
        if not isinstance(sha, str) or len(sha) < 64:
            fail("passed_release requires archive.sha256 (>=64 hex chars)")
        for key in ("developer_id", "notarized", "stapled", "signed_lifecycle", "passed_release"):
            if claims.get(key) is False:
                fail(f"passed_release cannot claim {key}=false")
        # Lifecycle is operator-attested: require fixture when fixture_dir given,
        # otherwise require claims.signed_lifecycle true (collect sets via env).
        if fixture_dir:
            if not fixture_present(fixture_refs, "signed_lifecycle"):
                fail(
                    "passed_release with --fixture-dir requires fixture_refs.signed_lifecycle "
                    "pointing at a non-empty file under the fixture dir"
                )
        elif claims.get("signed_lifecycle") is not True:
            fail("passed_release requires claims.signed_lifecycle=true (operator attestation)")
    else:
        if result not in INCOMPLETE_OK:
            fail(f"unknown result {result!r}")
        if not missing:
            fail(
                "non-release result requires explicit missing[] "
                f"(expected at least one of {list(CANONICAL_MISSING)})"
            )
        bad = [m for m in missing if m not in CANONICAL_MISSING and m not in ALLOWED_EXTRA_MISSING]
        if bad:
            fail(f"unknown missing codes: {bad}")

        if claims.get("passed_release") is True:
            fail("claims.passed_release cannot be true when result is incomplete")

        # Strong claims need material and/or fixtures — never silent true.
        if claims.get("developer_id") is True:
            if not material_proves_developer_id(app):
                if not (fixture_dir and fixture_present(fixture_refs, "developer_id")):
                    fail(
                        "claims.developer_id=true requires app material "
                        "(signature_kind=developer_id + hardened_runtime + verify + team) "
                        "or --fixture-dir + fixture_refs.developer_id"
                    )
        if claims.get("notarized") is True:
            if not material_proves_notarized(app):
                if not (fixture_dir and fixture_present(fixture_refs, "notary_profile")):
                    fail(
                        "claims.notarized=true requires app.spctl=accepted with Developer ID "
                        "or --fixture-dir + fixture_refs.notary_profile"
                    )
        if claims.get("stapled") is True:
            if not material_proves_stapled(app):
                if not (fixture_dir and fixture_present(fixture_refs, "notary_profile")):
                    fail(
                        "claims.stapled=true requires app.stapler=valid with Developer ID "
                        "or --fixture-dir + fixture_refs.notary_profile"
                    )
        if claims.get("signed_lifecycle") is True:
            if result in {"incomplete", "blocked", "adhoc_smoke_only"}:
                if not (fixture_dir and fixture_present(fixture_refs, "signed_lifecycle")):
                    fail(
                        f"result={result} cannot claim signed_lifecycle=true without "
                        "--fixture-dir + fixture_refs.signed_lifecycle"
                    )

        if result in {"incomplete", "blocked", "adhoc_smoke_only"}:
            for key in ("developer_id", "notarized", "stapled"):
                if claims.get(key) is True and not material_proves_developer_id(app):
                    # Already checked above with fixture escape; if material missing and
                    # fixture missing we already failed. If material missing but fixture
                    # present, still forbid for adhoc/blocked dry hosts without material.
                    if app.get("signature_kind") in {"missing", "adhoc"} and not (
                        fixture_dir and fixture_present(fixture_refs, "developer_id" if key == "developer_id" else "notary_profile")
                    ):
                        fail(f"result={result} cannot claim {key}=true without material")

    print(f"VALID: {path}")
    print(f"result={result}")
    print(f"missing={json.dumps(missing)}")
    if fixture_dir:
        print(f"fixture_dir={fixture_dir}")

    codes = list(missing) if missing else []
    if print_needs or result not in RELEASE_RESULTS:
        if not codes:
            codes = list(CANONICAL_MISSING)
        print("---- operator checklist ----")
        for code in codes:
            title, steps, unblocks = NEED_LINES.get(
                code,
                (
                    f"NEED (human): {code}",
                    f"Resolve missing evidence code `{code}` on the release Mac.",
                    f"`{code}` no longer appears in missing[] and validate exits 0 on passed_release",
                ),
            )
            print(title)
            print(f"Operator steps: {steps}")
            print(f"Unblocks when: {unblocks}")
            print("")

    sys.exit(0)


if __name__ == "__main__":
    main()
PY
