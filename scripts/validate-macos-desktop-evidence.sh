#!/usr/bin/env bash
# Validate a macOS desktop release evidence JSON document (issue #382 schema).
#
# This is a software gate only. It never claims Developer ID / notarization
# succeeded without the material fields present in the JSON. It rejects silent
# green documents that omit explicit missing[] when incomplete.
#
# Usage:
#   scripts/validate-macos-desktop-evidence.sh path/to/*.evidence.json
#   scripts/validate-macos-desktop-evidence.sh --print-needs path/to/*.evidence.json
#
# Exit codes:
#   0  document is schema-valid and honest for its result
#   1  usage / IO error
#   2  schema or honesty failure (overclaim, missing fields, bad shape)
set -euo pipefail

cd "$(dirname "$0")/.."

print_needs=0
path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-needs) print_needs=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
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

if [[ -z "$path" ]]; then
  echo "usage: $0 [--print-needs] path/to/evidence.json" >&2
  exit 1
fi

if [[ ! -f "$path" ]]; then
  echo "evidence file not found: $path" >&2
  exit 1
fi

export CASEIN_EVIDENCE_PATH="$path"
export CASEIN_EVIDENCE_PRINT_NEEDS="$print_needs"

python3 - <<'PY'
import json
import os
import sys

path = os.environ["CASEIN_EVIDENCE_PATH"]
print_needs = os.environ.get("CASEIN_EVIDENCE_PRINT_NEEDS") == "1"

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

# Canonical incomplete set for dry-run / pre-operator evidence (#382).
CANONICAL_MISSING = ("developer_id", "notary_profile", "signed_lifecycle")

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


def fail(msg: str) -> None:
    print(f"INVALID: {msg}", file=sys.stderr)
    sys.exit(2)


def main() -> None:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        print(f"read failed: {exc}", file=sys.stderr)
        sys.exit(1)

    # Secrets hygiene — never allow credential material in evidence.
    lowered = raw.lower()
    for needle in (
        "begin certificate",
        "begin private key",
        "begin rsa private key",
        "casein_notary_app_password",
        "authkey_",
    ):
        if needle in lowered:
            fail(f"evidence must not embed secret material ({needle})")

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"not JSON: {exc}")

    if not isinstance(data, dict):
        fail("root must be object")

    for key in REQUIRED_TOP:
        if key not in data:
            fail(f"missing top-level field: {key}")

    if data.get("schema") != 1:
        fail(f"schema must be 1, got {data.get('schema')!r}")
    if data.get("kind") != "macos_desktop_release_evidence":
        fail(f"kind must be macos_desktop_release_evidence, got {data.get('kind')!r}")
    if data.get("issue") != 382:
        fail(f"issue must be 382, got {data.get('issue')!r}")

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
    if claims is not None and not isinstance(claims, dict):
        fail("claims must be object when present")

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
        if not archive.get("sha256"):
            fail("passed_release requires archive.sha256")
        if claims:
            for key in ("developer_id", "notarized", "stapled", "signed_lifecycle"):
                if claims.get(key) is False:
                    fail(f"passed_release cannot claim {key}=false")
    else:
        if result not in INCOMPLETE_OK:
            fail(f"unknown result {result!r}")
        # Incomplete documents must not silently pass — require explicit missing[].
        if not missing:
            fail(
                "non-release result requires explicit missing[] "
                f"(expected at least one of {list(CANONICAL_MISSING)})"
            )
        unknown = [m for m in missing if m not in CANONICAL_MISSING and m not in (
            "app_bundle",
            "archive",
            "darwin_host",
            "codesign_tools",
        )]
        # Allow a small extension set; unknown codes still fail so typos surface.
        allowed_extra = {
            "app_bundle",
            "archive",
            "darwin_host",
            "codesign_tools",
        }
        bad = [m for m in missing if m not in CANONICAL_MISSING and m not in allowed_extra]
        if bad:
            fail(f"unknown missing codes: {bad}")

        # Dry-run / blocked host path must never look like success via claims.
        if claims:
            if claims.get("passed_release") is True:
                fail("claims.passed_release cannot be true when result is incomplete")
            if result in {"incomplete", "blocked", "adhoc_smoke_only"}:
                for key in ("developer_id", "notarized", "stapled", "signed_lifecycle"):
                    if claims.get(key) is True:
                        fail(f"result={result} cannot claim {key}=true without material")

    print(f"VALID: {path}")
    print(f"result={result}")
    print(f"missing={json.dumps(missing)}")

    # Operator checklist as NEED codes (always when incomplete or --print-needs).
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
