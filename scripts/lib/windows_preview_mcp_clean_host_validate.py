#!/usr/bin/env python3
"""Fail-closed validator for #463 clean-host Preview MCP evidence JSON."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

STEP_IDS = (
    "discover",
    "open",
    "observe",
    "click",
    "type",
    "press",
    "screenshot",
    "close",
)

SECRET_PATTERNS = [
    re.compile(r"(?i)bearer\s+[a-z0-9._\-]+"),
    re.compile(r"(?i)authorization\s*[:=]\s*\S+"),
    re.compile(
        r"(?i)(api[_-]?token|access[_-]?token|refresh[_-]?token|CASEIN_API_TOKEN)\s*[:=]\s*\S+"
    ),
    re.compile(r"(?i)pairing[_-]?token"),
    re.compile(r"casein://[^\s\"']+"),
    re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)password\s*[:=]\s*\S+"),
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


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: windows_preview_mcp_clean_host_validate.py PATH SCHEMA", file=sys.stderr)
        return 1

    path = Path(argv[1])
    schema_path = Path(argv[2])

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

    if doc.get("schema") != "casein_windows_preview_mcp_clean_host":
        fail("schema must be casein_windows_preview_mcp_clean_host")
    if doc.get("schema_version") != 1:
        fail("schema_version must be 1")
    if doc.get("issue") != 463:
        fail("issue must be 463")

    for key in ("product_revision", "package_sha"):
        val = doc.get(key)
        if not isinstance(val, str) or not re.fullmatch(r"[0-9a-f]{40}", val):
            fail(f"{key} must be a 40-char lowercase git sha")

    recorded = doc.get("recorded_at_utc")
    if not isinstance(recorded, str) or not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", recorded
    ):
        fail("recorded_at_utc must be UTC Zulu second precision")

    host = doc.get("host")
    if not isinstance(host, dict):
        fail("host object required")
    for key in ("os", "kind", "package_signed"):
        if key not in host:
            fail(f"host.{key} required")
    if not isinstance(host.get("os"), str) or not (1 <= len(host["os"]) <= 64):
        fail("host.os invalid")
    if host.get("kind") not in (
        "clean_win11_signed_install",
        "linux_dry_run",
        "package_smoke_ci",
        "other",
    ):
        fail("host.kind invalid")
    if not isinstance(host.get("package_signed"), bool):
        fail("host.package_signed must be boolean")

    claims = doc.get("claims")
    if not isinstance(claims, dict):
        fail("claims object required")
    for key in (
        "clean_host_exercised",
        "agent_inside_installed_workspace",
        "package_smoke_only",
        "linux_dry_run",
        "secrets_redacted",
    ):
        if key not in claims or not isinstance(claims[key], bool):
            fail(f"claims.{key} must be boolean")

    if claims.get("secrets_redacted") is not True:
        fail("claims.secrets_redacted must be true")

    verdict = doc.get("verdict")
    allowed = {
        "walk_passed",
        "walk_failed",
        "lab_incomplete",
        "lab_unreachable_on_this_host",
        "rejected_secrets_or_schema",
    }
    if verdict not in allowed:
        fail(f"verdict not in {sorted(allowed)}")
    if verdict == "rejected_secrets_or_schema":
        fail("verdict rejected_secrets_or_schema is not acceptable input")

    steps = doc.get("mcp_steps")
    if not isinstance(steps, list) or len(steps) != 8:
        fail("mcp_steps must be an array of exactly 8 steps")

    seen: list[str] = []
    outcomes: list[str] = []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            fail(f"mcp_steps[{i}] must be object")
        sid = step.get("id")
        if sid not in STEP_IDS:
            fail(f"mcp_steps[{i}].id invalid")
        if sid in seen:
            fail(f"duplicate mcp step id {sid}")
        seen.append(sid)
        if sid != STEP_IDS[i]:
            fail(f"mcp_steps[{i}].id must be {STEP_IDS[i]} (fixed order)")
        outcome = step.get("outcome")
        if outcome not in ("passed", "failed", "skipped", "not_run"):
            fail(f"mcp_steps[{i}].outcome invalid")
        outcomes.append(outcome)
        notes = step.get("notes", "")
        if notes is not None and (not isinstance(notes, str) or len(notes) > 512):
            fail(f"mcp_steps[{i}].notes too long")
        at = step.get("at_utc")
        if at is not None and (
            not isinstance(at, str)
            or not re.fullmatch(
                r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", at
            )
        ):
            fail(f"mcp_steps[{i}].at_utc invalid")

    if seen != list(STEP_IDS):
        fail("mcp_steps must be discover,open,observe,click,type,press,screenshot,close")

    strings: list[str] = []
    walk_strings(doc, strings)
    blob = "\n".join(strings)
    for pat in SECRET_PATTERNS:
        if pat.search(blob):
            fail("secret-like pattern detected; redact and set claims.secrets_redacted")

    def all_passed() -> bool:
        return all(o == "passed" for o in outcomes)

    def any_failed() -> bool:
        return any(o == "failed" for o in outcomes)

    def any_incomplete() -> bool:
        return any(o in ("skipped", "not_run") for o in outcomes)

    if claims["package_smoke_only"] and claims["clean_host_exercised"]:
        fail("package_smoke_only and clean_host_exercised cannot both be true")
    if claims["linux_dry_run"] and claims["clean_host_exercised"]:
        fail("linux_dry_run and clean_host_exercised cannot both be true")

    if claims["clean_host_exercised"] is True:
        if claims["package_smoke_only"] or claims["linux_dry_run"]:
            fail("clean_host_exercised forbids package_smoke_only/linux_dry_run")
        if host.get("kind") != "clean_win11_signed_install":
            fail("clean_host_exercised requires host.kind=clean_win11_signed_install")
        if any_incomplete() and not any_failed():
            fail("clean_host_exercised requires completed mcp_steps")

    if claims["agent_inside_installed_workspace"] is True:
        if not claims["clean_host_exercised"]:
            fail("agent_inside_installed_workspace requires clean_host_exercised")

    if verdict == "walk_passed":
        if claims["linux_dry_run"] or claims["package_smoke_only"]:
            fail("walk_passed forbids linux_dry_run and package_smoke_only")
        if not claims["clean_host_exercised"]:
            fail("walk_passed requires clean_host_exercised")
        if not claims["agent_inside_installed_workspace"]:
            fail("walk_passed requires agent_inside_installed_workspace")
        if host.get("kind") != "clean_win11_signed_install":
            fail("walk_passed requires host.kind=clean_win11_signed_install")
        if host.get("package_signed") is not True:
            fail("walk_passed requires host.package_signed=true")
        if not all_passed():
            fail("walk_passed requires every mcp_steps outcome=passed")
    elif verdict == "lab_unreachable_on_this_host":
        if claims["clean_host_exercised"] or claims["agent_inside_installed_workspace"]:
            fail("lab_unreachable_on_this_host forbids clean_host claims true")
        if not claims["linux_dry_run"] and not claims["package_smoke_only"]:
            if host.get("kind") not in ("linux_dry_run", "package_smoke_ci", "other"):
                fail(
                    "lab_unreachable_on_this_host needs linux_dry_run or package_smoke_only or non-clean host.kind"
                )
    elif verdict == "walk_failed":
        if not any_failed():
            fail("walk_failed requires at least one failed mcp step")
    elif verdict == "lab_incomplete":
        if (
            claims["clean_host_exercised"]
            and claims["agent_inside_installed_workspace"]
            and all_passed()
            and host.get("package_signed") is True
        ):
            fail("lab_incomplete with full passes should be walk_passed")

    if not schema_path.is_file():
        fail("committed schema file missing")

    print(verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
