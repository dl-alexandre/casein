#!/usr/bin/env python3
"""Validate the frozen Casein/Dash Gate 0 fixture pack.

This runner intentionally uses only the Python standard library. It validates
the contract fixtures without starting Phoenix, contacting GitHub, or changing
any worktree state.

Usage:
    scripts/casein/validate_gate0_fixtures.py
    scripts/casein/validate_gate0_fixtures.py path/to/fixture_pack.json
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PACK = ROOT / "docs/operations/casein-v3-worker/gate0_fixture_pack.json"

EXPECTED_DOCUMENTS = {
    "casein_handoff_waiting",
    "mira_originated_handoff_waiting",
    "dash_merged_receipt",
    "mira_originated_dash_merged_receipt",
}
EXPECTED_ACTIONS = {"review_thread_action"}

REQUIRED_ERROR_CODES = {
    "unauthorized",
    "forbidden",
    "not_found",
    "unavailable",
    "timeout",
    "missing_id",
    "invalid_id",
    "invalid_owner_ref",
    "foreign_lane_id",
    "invalid_source",
    "invalid_source_outcome",
    "invalid_sha",
    "merged_sha_not_allowed",
    "merged_sha_required",
    "merge_actor_required",
    "invalid_actor_ref",
    "post_merge_evidence_required",
    "post_merge_evidence_not_allowed",
    "invalid_authorization_decision",
    "invalid_thread_id",
    "content_based_approval_forbidden",
    "invalid_dash_identity",
    "correlation_mismatch",
    "idempotency_mismatch",
    "idempotency_namespace_mismatch",
    "reused_handoff_new_sha",
    "unknown_field",
    "forbidden_alias",
    "absolute_path_forbidden",
    "schema_version_unsupported",
    "missing_contract_version",
    "invalid_task_id",
    "invalid_git_outcome",
    "input_too_large",
    "rate_limited",
}

RECEIPT_KEYS = {
    "schema_version",
    "contract",
    "receipt_id",
    "request_id",
    "source",
    "handoff_id",
    "workspace_id",
    "owner_ref",
    "runtime_id",
    "worker_id",
    "session_id",
    "workcell_id",
    "task_id",
    "lease_id",
    "correlation_id",
    "authorization",
    "evidence_ref",
    "idempotency",
    "git",
    "tests",
    "files",
}

GIT_KEYS = {
    "repository",
    "base_branch",
    "head_branch",
    "head_sha",
    "release_sha",
    "pr_number",
    "pr_url",
    "outcome",
    "merged_sha",
    "merge_actor_ref",
    "post_merge_evidence_ref",
}

ACTION_KEYS = {
    "schema_version",
    "contract",
    "action_id",
    "request_id",
    "source",
    "handoff_id",
    "git",
    "thread_id",
    "operation",
    "target_only",
    "content_inspected",
    "actor_ref",
    "idempotency_key",
}

ACTION_GIT_KEYS = {"repository", "pr_number", "head_sha"}

ALIAS_KEYS = {"pr_number", "pr_url", "merged_sha", "merge_actor_ref", "post_merge_evidence_ref"}


class FixtureFailure(Exception):
    """Raised when the fixture pack itself violates the frozen contract."""


def fail(code: str) -> str:
    return code


def get_path(value: Any, path: list[Any]) -> Any:
    current = value
    for part in path:
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and isinstance(part, int) and 0 <= part < len(current):
            current = current[part]
        else:
            return None
    return current


def has_path(value: Any, path: list[Any]) -> bool:
    current = value
    for part in path:
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and isinstance(part, int) and 0 <= part < len(current):
            current = current[part]
        else:
            return False
    return True


def remove_path(value: Any, path: list[Any]) -> None:
    if not path:
        raise FixtureFailure("cannot remove the document root")

    parent = get_path(value, path[:-1])
    key = path[-1]
    if isinstance(parent, dict) and key in parent:
        del parent[key]
        return
    if isinstance(parent, list) and isinstance(key, int) and 0 <= key < len(parent):
        del parent[key]
        return
    raise FixtureFailure(f"mutation path does not exist: {path!r}")


def set_path(value: Any, path: list[Any], replacement: Any) -> None:
    if not path:
        raise FixtureFailure("cannot set the document root")

    parent = get_path(value, path[:-1])
    key = path[-1]
    if isinstance(parent, dict):
        parent[key] = copy.deepcopy(replacement)
        return
    if isinstance(parent, list) and isinstance(key, int) and 0 <= key < len(parent):
        parent[key] = copy.deepcopy(replacement)
        return
    raise FixtureFailure(f"mutation parent does not exist: {path!r}")


def apply_mutation(value: Any, mutation: dict[str, Any] | None) -> Any:
    if mutation is None:
        return value

    operation = mutation.get("op")
    path = mutation.get("path", [])
    if not isinstance(path, list):
        raise FixtureFailure(f"mutation path must be a list: {mutation!r}")

    if operation == "remove":
        remove_path(value, path)
    elif operation in {"set", "add"}:
        set_path(value, path, mutation.get("value"))
    else:
        raise FixtureFailure(f"unsupported mutation operation: {operation!r}")
    return value


def is_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def valid_scalar_id(value: Any, pattern: re.Pattern[str]) -> bool:
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def valid_sha(value: Any, sha_pattern: re.Pattern[str]) -> bool:
    return isinstance(value, str) and sha_pattern.fullmatch(value) is not None


def check_exact_keys(value: dict[str, Any], allowed: set[str]) -> str | None:
    unknown = sorted(set(value) - allowed)
    return fail("unknown_field") if unknown else None


def check_contract(body: dict[str, Any], contract: dict[str, Any]) -> str | None:
    if body.get("schema_version") != 1 or isinstance(body.get("schema_version"), bool):
        return fail("schema_version_unsupported")

    received = body.get("contract")
    if not isinstance(received, dict):
        return fail("missing_contract_version")
    if received.get("name") != contract.get("name"):
        return fail("missing_contract_version")
    if received.get("version") != contract.get("version"):
        return fail("missing_contract_version")
    return None


def check_ids(
    body: dict[str, Any],
    profile: dict[str, Any],
    scalar_pattern: re.Pattern[str],
    task_pattern: re.Pattern[str],
) -> str | None:
    for field in profile["required_fields"]:
        if field not in body:
            return fail("missing_id")

    for field in profile["forbidden_fields"]:
        if field in body:
            return fail("foreign_lane_id")

    for field in [
        "receipt_id",
        "request_id",
        "workspace_id",
        "runtime_id",
        "worker_id",
        "session_id",
        "workcell_id",
        "lease_id",
        "handoff_id",
    ]:
        if field in body and not valid_scalar_id(body[field], scalar_pattern):
            return fail("invalid_id")

    if "workspace_id" in body and isinstance(body["workspace_id"], str) and body["workspace_id"].startswith("site-"):
        return fail("foreign_lane_id")

    if "task_id" in body and not valid_scalar_id(body["task_id"], task_pattern):
        return fail("invalid_task_id")

    if "correlation_id" in body:
        if not isinstance(body["correlation_id"], str) or not body["correlation_id"]:
            return fail("invalid_id")
        if "task_id" in body and body["correlation_id"] != body["task_id"]:
            return fail("correlation_mismatch")

    owner_ref = body.get("owner_ref")
    if not isinstance(owner_ref, dict):
        return fail("invalid_owner_ref")
    owner_error = check_exact_keys(owner_ref, {"provider", "id", "role"})
    if owner_error:
        return owner_error
    if "id" not in owner_ref:
        return fail("missing_id")
    if not valid_scalar_id(owner_ref["id"], scalar_pattern) or "@" in owner_ref["id"]:
        return fail("invalid_owner_ref")
    if not is_string(owner_ref.get("provider")) or not is_string(owner_ref.get("role")):
        return fail("invalid_owner_ref")
    return None


def check_authorization(body: dict[str, Any], decisions: set[str]) -> str | None:
    authorization = body.get("authorization")
    if not isinstance(authorization, dict):
        return fail("invalid_authorization_decision")
    decision = authorization.get("decision")
    if decision not in decisions:
        return fail("invalid_authorization_decision")
    for field in ["decision_id"]:
        if field in authorization and not is_string(authorization[field]):
            return fail("invalid_authorization_decision")
    return None


def check_git(
    body: dict[str, Any],
    profile: dict[str, Any],
    constants: dict[str, Any],
    expected_contract: dict[str, Any],
) -> str | None:
    git = body.get("git")
    if not isinstance(git, dict):
        return fail("unknown_field")
    unknown_error = check_exact_keys(git, GIT_KEYS)
    if unknown_error:
        if "status" in git:
            return fail("forbidden_alias")
        return unknown_error

    for field in ["repository", "base_branch", "head_branch"]:
        if not is_string(git.get(field)):
            return fail("invalid_id")
    if not is_string(git.get("repository")) or git["repository"].startswith("/"):
        return fail("invalid_id")
    if not is_string(git.get("head_branch")) or not is_string(git.get("base_branch")):
        return fail("invalid_id")

    sha_pattern = re.compile(constants["sha_pattern"])
    for field in ["head_sha", "release_sha", "merged_sha"]:
        if field in git and git[field] is not None and not valid_sha(git[field], sha_pattern):
            return fail("invalid_sha")
    if "head_sha" not in git or not valid_sha(git["head_sha"], sha_pattern):
        return fail("invalid_sha")

    outcome = git.get("outcome")
    outcomes = set(constants["git_outcomes"])
    if outcome not in outcomes:
        return fail("invalid_git_outcome")
    if body.get("source") not in profile["allowed_sources"]:
        return fail("invalid_source")
    if outcome not in profile["allowed_outcomes"]:
        return fail("invalid_source_outcome")

    if "pr_number" in git and (
        not isinstance(git["pr_number"], int)
        or isinstance(git["pr_number"], bool)
        or git["pr_number"] <= 0
    ):
        return fail("invalid_id")
    if "pr_url" in git and (not is_string(git["pr_url"]) or not git["pr_url"].startswith("https://")):
        return fail("invalid_id")

    merged = outcome == "merged"
    if merged:
        if "merged_sha" not in git or git["merged_sha"] is None:
            return fail("merged_sha_required")
        if "merge_actor_ref" not in git or not is_string(git["merge_actor_ref"]):
            return fail("merge_actor_required")
        actor_pattern = re.compile(r"^[a-z0-9._-]+/[a-z0-9._-]+$")
        if actor_pattern.fullmatch(git["merge_actor_ref"]) is None:
            return fail("invalid_actor_ref")
        if "post_merge_evidence_ref" not in git or not is_string(git["post_merge_evidence_ref"]):
            return fail("post_merge_evidence_required")
    else:
        if git.get("merged_sha") is not None:
            return fail("merged_sha_not_allowed")
        if git.get("post_merge_evidence_ref") is not None:
            return fail("post_merge_evidence_not_allowed")
        if git.get("merge_actor_ref") is not None:
            return fail("post_merge_evidence_not_allowed")

    idempotency = body.get("idempotency")
    if not isinstance(idempotency, dict) or not is_string(idempotency.get("handoff_key")):
        return fail("idempotency_mismatch")
    expected_key = f"handoff:v1:{body['handoff_id']}:{git['head_sha']}"
    if idempotency["handoff_key"] != expected_key:
        return fail("idempotency_mismatch")

    return None


def check_tests_and_files(body: dict[str, Any]) -> str | None:
    tests = body.get("tests")
    if not isinstance(tests, list):
        return fail("unknown_field")
    for test in tests:
        if not isinstance(test, dict):
            return fail("unknown_field")
        if "name" in test:
            return fail("forbidden_alias")
        if set(test) - {"command", "status"}:
            return fail("unknown_field")
        if not is_string(test.get("command")) or test.get("status") not in {"passed", "failed", "skipped"}:
            return fail("unknown_field")

    if "files" in body:
        files = body["files"]
        if not isinstance(files, list):
            return fail("unknown_field")
        for entry in files:
            if not isinstance(entry, dict) or set(entry) - {"path"} or not is_string(entry.get("path")):
                return fail("unknown_field")
            if entry["path"].startswith(("/", "~")):
                return fail("absolute_path_forbidden")
    return None


def validate_receipt(body: Any, profile: dict[str, Any], pack: dict[str, Any]) -> str | None:
    if not isinstance(body, dict):
        return fail("unknown_field")

    alias_paths = [
        ["pr_number"],
        ["pr_url"],
        ["merged_sha"],
        ["merge_actor_ref"],
        ["post_merge_evidence_ref"],
        ["git", "status"],
    ]
    if any(has_path(body, path) for path in alias_paths):
        return fail("forbidden_alias")

    unknown_error = check_exact_keys(body, RECEIPT_KEYS)
    if unknown_error:
        return unknown_error

    contract_error = check_contract(body, pack["contract"])
    if contract_error:
        return contract_error

    source = body.get("source")
    if source not in set(pack["constants"]["source_enum"]):
        return fail("invalid_source")

    scalar_pattern = re.compile(pack["constants"]["gate0_scalar_id_pattern"])
    task_pattern = re.compile(pack["constants"]["task_id_pattern"])
    ids_error = check_ids(body, profile, scalar_pattern, task_pattern)
    if ids_error:
        return ids_error

    auth_error = check_authorization(body, set(pack["constants"]["authorization_decisions"]))
    if auth_error:
        return auth_error

    git_error = check_git(body, profile, pack["constants"], pack["contract"])
    if git_error:
        return git_error

    return check_tests_and_files(body)


def validate_action(body: Any, pack: dict[str, Any]) -> str | None:
    if not isinstance(body, dict):
        return fail("unknown_field")
    unknown_error = check_exact_keys(body, ACTION_KEYS)
    if unknown_error:
        return unknown_error
    contract_error = check_contract(body, pack["contract"])
    if contract_error:
        return contract_error

    scalar_pattern = re.compile(pack["constants"]["gate0_scalar_id_pattern"])
    for field in ["action_id", "request_id", "handoff_id"]:
        if field not in body:
            return fail("missing_id")
        if not valid_scalar_id(body[field], scalar_pattern):
            return fail("invalid_id")

    if body.get("source") != "dash_verda":
        return fail("invalid_source")
    git = body.get("git")
    if not isinstance(git, dict) or check_exact_keys(git, ACTION_GIT_KEYS):
        return fail("unknown_field")
    if not is_string(git.get("repository")) or not isinstance(git.get("pr_number"), int) or git["pr_number"] <= 0:
        return fail("invalid_id")
    sha_pattern = re.compile(pack["constants"]["sha_pattern"])
    if not valid_sha(git.get("head_sha"), sha_pattern):
        return fail("invalid_sha")

    if not isinstance(body.get("thread_id"), str) or not body["thread_id"]:
        return fail("invalid_thread_id")
    if body.get("operation") != "resolve" or body.get("target_only") is not True:
        return fail("content_based_approval_forbidden")
    if body.get("content_inspected") is not False:
        return fail("content_based_approval_forbidden")
    actor_pattern = re.compile(r"^[a-z0-9._-]+/[a-z0-9._-]+$")
    if actor_pattern.fullmatch(body.get("actor_ref", "")) is None:
        return fail("invalid_actor_ref")

    expected_key = f"review-thread:v1:{body['handoff_id']}:{git['head_sha']}:{body['thread_id']}"
    if body.get("idempotency_key") != expected_key:
        return fail("idempotency_namespace_mismatch")
    return None


def resolve_base(pack: dict[str, Any], name: str) -> tuple[Any, str]:
    if name in pack["valid_documents"]:
        fixture = pack["valid_documents"][name]
        return copy.deepcopy(fixture["body"]), fixture["profile"]
    if name in pack["valid_actions"]:
        return copy.deepcopy(pack["valid_actions"][name]["body"]), "action"
    raise FixtureFailure(f"unknown fixture base: {name}")


def validate_replay(vector: dict[str, Any]) -> str | None:
    replay = vector.get("replay", {})
    if "existing" in replay and "incoming" in replay:
        existing = replay["existing"]
        incoming = replay["incoming"]
        if (
            existing.get("handoff_id") == incoming.get("handoff_id")
            and existing.get("head_sha") != incoming.get("head_sha")
        ):
            return fail("reused_handoff_new_sha")
        if existing.get("handoff_key") != incoming.get("handoff_key"):
            return fail("idempotency_mismatch")
        if existing.get("fingerprint") != incoming.get("fingerprint"):
            return fail("idempotency_mismatch")
        return None

    if "handoff_key" in replay and str(replay["handoff_key"]).startswith("review-thread:v1:"):
        return fail("idempotency_namespace_mismatch")
    if "action_key" in replay and str(replay["action_key"]).startswith("handoff:v1:"):
        return fail("idempotency_namespace_mismatch")
    return fail("idempotency_namespace_mismatch")


def validate_live(vector: dict[str, Any], base: dict[str, Any]) -> tuple[str | None, str | None]:
    live = vector.get("live", {})
    provider_error = live.get("provider_error")
    if provider_error in {"unauthorized", "forbidden", "not_found", "unavailable", "timeout"}:
        return fail(provider_error), None
    if live.get("rate_limited") is True:
        return fail("rate_limited"), None
    git = base.get("git", {})
    if live.get("head_sha") is not None and live["head_sha"] != git.get("head_sha"):
        return None, "head_sha_changed"
    if live.get("checks") == "pending":
        return None, "waiting"
    if live.get("checks") == "failed":
        return None, "blocked"
    return fail("invalid_git_outcome"), None


def assert_expectation(
    name: str,
    actual_error: str | None,
    actual_outcome: str | None,
    expected: dict[str, Any],
) -> None:
    if "error_code" in expected and actual_error != expected["error_code"]:
        raise FixtureFailure(f"{name}: expected error {expected['error_code']!r}, got {actual_error!r}")
    if "git_outcome" in expected and actual_outcome != expected["git_outcome"]:
        raise FixtureFailure(f"{name}: expected git outcome {expected['git_outcome']!r}, got {actual_outcome!r}")
    if "error_envelope" in expected and expected["error_envelope"] is None and actual_error is not None:
        raise FixtureFailure(f"{name}: expected no error envelope, got {actual_error!r}")
    if expected.get("valid") is True and actual_error is not None:
        raise FixtureFailure(f"{name}: expected a valid document, got {actual_error!r}")


def validate_pack(pack: dict[str, Any]) -> tuple[int, int]:
    if pack.get("schema_version") != 1 or isinstance(pack.get("schema_version"), bool):
        raise FixtureFailure("pack schema_version must be integer 1")
    if pack.get("contract") != {"name": "casein-dash-handoff", "version": "1.0"}:
        raise FixtureFailure("pack contract is not frozen at casein-dash-handoff/1.0")

    constants = pack.get("constants", {})
    if constants.get("CASEIN_INPUT_MAX_BYTES") != 8192:
        raise FixtureFailure("CASEIN_INPUT_MAX_BYTES must be 8192")
    if set(constants.get("source_enum", [])) != {"v3_casein", "casein_worker", "dash_verda"}:
        raise FixtureFailure("source enum is not frozen")
    if set(pack.get("boundary_error_mapping", {})) < REQUIRED_ERROR_CODES:
        missing = sorted(REQUIRED_ERROR_CODES - set(pack.get("boundary_error_mapping", {})))
        raise FixtureFailure(f"boundary error mapping is missing: {missing}")

    documents = pack.get("valid_documents", {})
    actions = pack.get("valid_actions", {})
    if set(documents) != EXPECTED_DOCUMENTS:
        raise FixtureFailure(f"valid document set differs: {sorted(documents)}")
    if set(actions) != EXPECTED_ACTIONS:
        raise FixtureFailure(f"valid action set differs: {sorted(actions)}")

    for name, fixture in documents.items():
        profile_name = fixture.get("profile")
        profile = pack["profiles"].get(profile_name)
        if profile is None:
            raise FixtureFailure(f"{name}: unknown profile {profile_name!r}")
        error = validate_receipt(fixture.get("body"), profile, pack)
        if error:
            raise FixtureFailure(f"valid document {name} failed with {error}")

    for name, fixture in actions.items():
        error = validate_action(fixture.get("body"), pack)
        if error:
            raise FixtureFailure(f"valid action {name} failed with {error}")

    vectors = pack.get("fail_vectors", [])
    names = [vector.get("name") for vector in vectors]
    if len(names) != len(set(names)):
        raise FixtureFailure("fail vector names must be unique")

    passed = 0
    for vector in vectors:
        name = vector.get("name", "<unnamed>")
        mode = vector.get("mode")
        base, profile_name = resolve_base(pack, vector["base"])
        expected = vector.get("expect", {})
        actual_error: str | None = None
        actual_outcome: str | None = None

        if mode == "document":
            body = apply_mutation(base, vector.get("mutation"))
            static_identity = vector.get("static_identity")
            if static_identity:
                git = body.get("git", {})
                identity_fields = ["repository", "pr_number", "head_sha"]
                if any(git.get(field) != static_identity.get(field) for field in identity_fields):
                    actual_error = "invalid_dash_identity"
            if actual_error is None:
                if profile_name == "action":
                    actual_error = validate_action(body, pack)
                else:
                    profile = pack["profiles"][profile_name]
                    actual_error = validate_receipt(body, profile, pack)
        elif mode == "replay":
            actual_error = validate_replay(vector)
        elif mode == "protocol":
            if vector.get("protocol", {}).get("body_bytes", 0) > constants["CASEIN_INPUT_MAX_BYTES"]:
                actual_error = "input_too_large"
            else:
                actual_error = "invalid_git_outcome"
        elif mode == "live_github":
            if profile_name == "action":
                raise FixtureFailure(f"{name}: live GitHub vectors must use a receipt base")
            actual_error, actual_outcome = validate_live(vector, base)
        else:
            raise FixtureFailure(f"{name}: unsupported mode {mode!r}")

        assert_expectation(name, actual_error, actual_outcome, expected)
        passed += 1

    return len(documents) + len(actions), passed


def producer_profile(body: dict[str, Any]) -> str:
    source = body.get("source")
    if source == "dash_verda":
        return "mira_dash_merged" if "task_id" in body else "dash_merged"
    return "mira_waiting" if "task_id" in body else "casein_waiting"


def producer_mismatches(body: dict[str, Any], pack: dict[str, Any]) -> tuple[str, list[str]]:
    """Report raw producer shape mismatches without normalizing the payload."""
    profile_name = producer_profile(body)
    profile = pack["profiles"].get(profile_name)
    if profile is None:
        return profile_name, [f"unknown producer profile: {profile_name}"]

    mismatches: list[str] = []
    frozen_error = validate_receipt(body, profile, pack)
    if frozen_error:
        mismatches.append(f"frozen_validator_error={frozen_error}")

    unknown_root = sorted(set(body) - RECEIPT_KEYS)
    if unknown_root:
        mismatches.append(f"unknown_root_fields={','.join(unknown_root)}")

    missing_root = sorted(field for field in profile["required_fields"] if field not in body)
    if missing_root:
        mismatches.append(f"missing_required_fields={','.join(missing_root)}")

    git = body.get("git")
    if not isinstance(git, dict):
        mismatches.append("git must be an object")
    else:
        unknown_git = sorted(set(git) - GIT_KEYS)
        if unknown_git:
            mismatches.append(f"unknown_git_fields={','.join(unknown_git)}")

        required_git = {"repository", "base_branch", "head_branch", "head_sha", "release_sha", "outcome"}
        missing_git = sorted(required_git - set(git))
        if missing_git:
            mismatches.append(f"missing_git_fields={','.join(missing_git)}")

    if "idempotency_key" in body and "idempotency" not in body:
        mismatches.append("idempotency_key must be idempotency.handoff_key")
    if "changed_files" in body and "files" not in body:
        mismatches.append("changed_files must use the frozen files field")
    if "head_sha" in body and isinstance(git, dict) and "head_sha" not in git:
        mismatches.append("head_sha must be nested under git")
    if "release_sha" in body and isinstance(git, dict) and "release_sha" not in git:
        mismatches.append("release_sha must be nested under git")
    if "repository" in body and isinstance(git, dict) and "repository" not in git:
        mismatches.append("repository must be nested under git")
    if "base_branch" in body and isinstance(git, dict) and "base_branch" not in git:
        mismatches.append("base_branch must be nested under git")
    if "head_branch" in body and isinstance(git, dict) and "head_branch" not in git:
        mismatches.append("head_branch must be nested under git")

    return profile_name, mismatches


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", nargs="?", type=Path, help="fixture pack JSON path")
    parser.add_argument(
        "--producer-output",
        type=Path,
        help="validate one raw producer JSON receipt against the frozen pack",
    )
    return parser.parse_args(argv[1:])


def gate_status(pack: dict[str, Any]) -> str:
    return str(pack.get("status", {}).get("gate_0", "not_advanced"))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    pack_path = (args.pack or DEFAULT_PACK).resolve()
    try:
        pack = json.loads(pack_path.read_text(encoding="utf-8"))
        valid_count, vector_count = validate_pack(pack)
    except (OSError, json.JSONDecodeError, FixtureFailure, KeyError, TypeError) as error:
        print(f"GATE0 FIXTURES: FAIL — {error}", file=sys.stderr)
        return 1

    print(f"GATE0 FIXTURES: PASS — {valid_count} valid fixtures; {vector_count} vectors")
    if args.producer_output is None:
        print(f"Gate 0 status: {gate_status(pack)}; this runner validates the pack only.")
        return 0

    try:
        producer_path = args.producer_output.resolve()
        producer = json.loads(producer_path.read_text(encoding="utf-8"))
        profile_name, mismatches = producer_mismatches(producer, pack)
    except (OSError, json.JSONDecodeError, FixtureFailure, KeyError, TypeError) as error:
        print(f"GATE0 PRODUCER: FAIL — {error}", file=sys.stderr)
        return 1

    if mismatches:
        print(f"GATE0 PRODUCER: FAIL — profile={profile_name}; {len(mismatches)} mismatches")
        for mismatch in mismatches:
            print(f"- {mismatch}")
        print(f"Gate 0 status: {gate_status(pack)}; producer compatibility is integration-red.")
        return 1

    print(f"GATE0 PRODUCER: PASS — profile={profile_name}")
    print(f"Gate 0 status: {gate_status(pack)}; producer compatibility is contract-green.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
