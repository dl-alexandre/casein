#!/usr/bin/env python3
"""Bounded, privacy-safe host runner for the Android utility soak.

The runner owns the disposable Android test-driver lifecycle. It pins a signed
APK by SHA-256, runner, target, and reviewed-source digest; proves that the test
package is initially absent; and only removes a driver whose exact install this
run proved successful. The installed package's exact on-device base APK digest
must match the reviewed host digest before ownership or execution is allowed.
Cleanup force-stops only the disposable driver and base Casein app, proves their
instrumentation/processes are quiescent, then removes the driver before Wi-Fi
can be restored. The base app is never cleared or uninstalled.

One absolute 20-minute deadline covers preflight, driver installation,
instrumentation, fixed-metric collection, and cleanup. The final 30 seconds of
the work window are reserved for metric collection and the final 120 seconds
are reserved for Wi-Fi and driver cleanup. Child processes run without a shell
in their own POSIX process group; this Unix-only process model is checked at
construction. Timeout cleanup is TERM, bounded drain/wait, KILL, and bounded
reap. Only a bounded tail of stdout is retained. Serial numbers, argv, child
output, exception text, APK paths, and UI content are never emitted.

The in-test bounded-wait budget is derived from the reviewed Kotlin source at
runtime. A 15-minute in-app watchdog precedes the host telemetry and cleanup
boundaries. ``before_cold_metric`` means no fixed milestone completed; the first
fixed metric is deliberately emitted only after cold launch and the initial
dashboard assertions.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Callable, Sequence


SCHEMA_VERSION = 3
BASE_PACKAGE = "com.example.casein_mob"
DRIVER_PACKAGE = "com.example.casein_mob.test"
EXPECTED_RUNNER_CLASS = "androidx.test.runner.AndroidJUnitRunner"
INSTRUMENTATION_RUNNER = DRIVER_PACKAGE + "/" + EXPECTED_RUNNER_CLASS
UTILITY_SOURCE_DIGEST_METADATA = (
    "com.example.casein_mob.CASEIN_UTILITY_SOURCE_SHA256"
)
ANDROID_XML_NS = "http://schemas.android.com/apk/res/android"
TEST_CLASS = (
    "com.example.casein_mob.CaseinUtilitySoakTest"
    "#canonicalProfileSurvivesLifecycleRotationAndOfflineRecovery"
)
UTILITY_TEST_SOURCE = (
    Path(__file__).resolve().parent
    / "app/src/androidTest/java/com/example/casein_mob/CaseinUtilitySoakTest.kt"
)

WHOLE_RUN_TIMEOUT_MS = 1_200_000
CLEANUP_RESERVE_MS = 120_000
TELEMETRY_RESERVE_MS = 30_000
WIFI_RESTORE_RESERVE_MS = 40_000
DEVICE_WATCHDOG_TIMEOUT_MS = 900_000
DEVICE_QUIESCENCE_RESERVE_MS = 60_000
DEVICE_SHA256SUM = "/system/bin/sha256sum"
QUIESCENCE_MAX_POLLS = 8
MAX_CHILD_OUTPUT_BYTES = 64 * 1024
CHILD_TERM_GRACE_SECONDS = 1.0
CHILD_KILL_GRACE_SECONDS = 1.0

SERIAL_PATTERN = re.compile(r"\A[A-Za-z0-9._:-]{1,128}\Z")
SHA256_PATTERN = re.compile(r"\A[0-9a-fA-F]{64}\Z")
INSTALLED_DRIVER_APK_PATTERN = re.compile(
    r"\A/data/app/com\.example\.casein_mob\.test-"
    r"[A-Za-z0-9_+=.-]{1,160}/base\.apk\Z"
)
FIXED_METRIC_PATTERN = re.compile(
    r"^(?P<epoch>\d+(?:\.\d+)?)\s+.*?casein_soak\s+"
    r"(?P<key>cold_launch_ms|warm_resume_ms|offline_recovery_ms)="
    r"(?P<value>\d+)$"
)

RESULT_KEYS = {
    "schema_version",
    "status",
    "test_completed",
    "timed_out",
    "duration_ms",
    "whole_run_timeout_ms",
    "cleanup_reserve_ms",
    "telemetry_reserve_ms",
    "explicit_wait_budget_ms",
    "safety_margin_ms",
    "device_watchdog_timeout_ms",
    "reviewed_apk_verified",
    "cross_invocation_one_attempt",
    "last_stage",
    "failure_stage",
    "cold_launch_ms",
    "warm_resume_ms",
    "offline_recovery_ms",
    "wifi_initially_enabled",
    "wifi_restore_attempted",
    "wifi_restored",
    "driver_install_attempted",
    "driver_installed",
    "driver_cleanup_attempted",
    "driver_cleaned",
    "device_quiescent",
}


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stdout_truncated: bool = False


@dataclass
class BoundedCapture:
    data: bytearray
    total_bytes: int = 0

    @property
    def truncated(self) -> bool:
        return self.total_bytes > len(self.data)


@dataclass(frozen=True)
class WaitBudget:
    ui_count: int
    ui_ms: int
    filter_count: int
    filter_ms: int
    offline_count: int
    offline_ms: int
    recovery_count: int
    recovery_ms: int
    keyboard_count: int
    keyboard_ms: int
    idle_count: int
    idle_ms: int

    @property
    def total_ms(self) -> int:
        return (
            self.ui_count * self.ui_ms
            + self.filter_count * self.filter_ms
            + self.offline_count * self.offline_ms
            + self.recovery_count * self.recovery_ms
            + self.keyboard_count * self.keyboard_ms
            + self.idle_count * self.idle_ms
        )


@dataclass(frozen=True)
class KotlinFunction:
    name: str
    params: str
    body: str


class CommandDeadlineExceeded(Exception):
    """Fixed-message timeout that deliberately contains no argv."""

    def __init__(self, output: object = "") -> None:
        super().__init__("command deadline exceeded")
        self.output = _bounded_text(output)


class CommandCohortCleanupFailed(Exception):
    """Fixed-message failure raised when a killed leader cannot be reaped."""


class RunFailure(Exception):
    def __init__(self, status: str, stage: str) -> None:
        super().__init__("fixed run failure")
        self.status = status
        self.stage = stage


class SubprocessExecutor:
    """shell-free process-group executor with bounded streaming capture."""

    def __init__(
        self,
        *,
        monotonic: Callable[[], float] = time.monotonic,
        max_capture_bytes: int = MAX_CHILD_OUTPUT_BYTES,
        term_grace_seconds: float = CHILD_TERM_GRACE_SECONDS,
        kill_grace_seconds: float = CHILD_KILL_GRACE_SECONDS,
        platform_name: str = os.name,
    ) -> None:
        if platform_name != "posix" or not hasattr(os, "killpg"):
            raise RuntimeError("POSIX process groups required")
        self.monotonic = monotonic
        self.max_capture_bytes = max_capture_bytes
        self.term_grace_seconds = term_grace_seconds
        self.kill_grace_seconds = kill_grace_seconds

    def run(self, argv: Sequence[str], deadline: float) -> CommandResult:
        reserve = self.term_grace_seconds + self.kill_grace_seconds
        if deadline - self.monotonic() <= reserve:
            raise CommandDeadlineExceeded()

        process = subprocess.Popen(
            list(argv),
            shell=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            bufsize=0,
        )
        assert process.stdout is not None

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        capture = BoundedCapture(bytearray())
        eof = False
        soft_deadline = deadline - reserve

        try:
            completed, eof = self._stream_until(
                process, selector, capture, eof, soft_deadline
            )
            if not completed:
                self._terminate_group(process, selector, capture, eof, deadline)
                raise CommandDeadlineExceeded(bytes(capture.data))

            return CommandResult(
                process.returncode if process.returncode is not None else 1,
                _bounded_text(bytes(capture.data)),
                capture.truncated,
            )
        except CommandDeadlineExceeded:
            raise
        except Exception:
            self._terminate_group(process, selector, capture, eof, deadline)
            raise
        finally:
            selector.close()
            process.stdout.close()

    def _stream_until(
        self,
        process: subprocess.Popen[bytes],
        selector: selectors.BaseSelector,
        capture: BoundedCapture,
        eof: bool,
        deadline: float,
    ) -> tuple[bool, bool]:
        while self.monotonic() < deadline:
            if process.poll() is not None and eof:
                return True, eof

            remaining = max(0.0, deadline - self.monotonic())
            for key, _mask in selector.select(min(0.05, remaining)):
                chunk = os.read(key.fd, 16 * 1024)
                if chunk:
                    capture.total_bytes += len(chunk)
                    _append_bounded_tail(
                        capture.data, chunk, self.max_capture_bytes
                    )
                else:
                    eof = True
                    try:
                        selector.unregister(key.fileobj)
                    except KeyError:
                        pass

        return process.poll() is not None and eof, eof

    def _terminate_group(
        self,
        process: subprocess.Popen[bytes],
        selector: selectors.BaseSelector,
        capture: BoundedCapture,
        eof: bool,
        deadline: float,
    ) -> None:
        self._signal_group(process.pid, signal.SIGTERM)
        term_deadline = min(
            deadline - self.kill_grace_seconds,
            self.monotonic() + self.term_grace_seconds,
        )
        _completed, eof = self._stream_until(
            process, selector, capture, eof, term_deadline
        )

        # The leader and its stdout can both disappear while a descendant in
        # the same private process group remains alive with stdio closed and
        # SIGTERM ignored. Always kill the exact group after the TERM grace;
        # leader/EOF completion is not cohort completion.
        self._signal_group(process.pid, signal.SIGKILL)
        self._stream_until(process, selector, capture, eof, deadline)

        if process.poll() is None:
            remaining = max(0.01, deadline - self.monotonic())
            try:
                process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                self._signal_group(process.pid, signal.SIGKILL)
                raise CommandCohortCleanupFailed("cohort reap deadline exceeded") from None

    @staticmethod
    def _signal_group(pid: int, requested_signal: signal.Signals) -> None:
        try:
            os.killpg(pid, requested_signal)
        except ProcessLookupError:
            pass


def _append_bounded_tail(buffer: bytearray, chunk: bytes, limit: int) -> None:
    if limit <= 0:
        buffer.clear()
        return
    if len(chunk) >= limit:
        buffer[:] = chunk[-limit:]
        return
    overflow = len(buffer) + len(chunk) - limit
    if overflow > 0:
        del buffer[:overflow]
    buffer.extend(chunk)


def _bounded_text(value: object) -> str:
    if isinstance(value, bytes):
        return value[-MAX_CHILD_OUTPUT_BYTES:].decode("utf-8", errors="replace")
    if isinstance(value, str):
        return value[-MAX_CHILD_OUTPUT_BYTES:]
    return ""


def _result(**updates: object) -> dict[str, object]:
    result: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "status": "runner_error",
        "test_completed": False,
        "timed_out": False,
        "duration_ms": None,
        "whole_run_timeout_ms": WHOLE_RUN_TIMEOUT_MS,
        "cleanup_reserve_ms": CLEANUP_RESERVE_MS,
        "telemetry_reserve_ms": TELEMETRY_RESERVE_MS,
        "explicit_wait_budget_ms": None,
        "safety_margin_ms": None,
        "device_watchdog_timeout_ms": DEVICE_WATCHDOG_TIMEOUT_MS,
        "reviewed_apk_verified": False,
        "cross_invocation_one_attempt": "external",
        "last_stage": "not_started",
        "failure_stage": None,
        "cold_launch_ms": None,
        "warm_resume_ms": None,
        "offline_recovery_ms": None,
        "wifi_initially_enabled": None,
        "wifi_restore_attempted": False,
        "wifi_restored": False,
        "driver_install_attempted": False,
        "driver_installed": False,
        "driver_cleanup_attempted": False,
        "driver_cleaned": False,
        "device_quiescent": False,
    }
    result.update(updates)
    if set(result) != RESULT_KEYS:
        raise ValueError("invalid result schema")
    return result


def _parse_kotlin_ms(source: str, name: str) -> int:
    match = re.search(
        rf"private\s+const\s+val\s+{re.escape(name)}\s*=\s*([0-9_]+)L?",
        source,
    )
    if not match:
        raise ValueError("missing wait constant")
    return int(match.group(1).replace("_", ""))


def _mask_kotlin_noncode(source: str) -> str:
    """Mask comments and literals while preserving offsets and line breaks."""

    masked = list(source)
    index = 0
    state = "code"
    block_depth = 0
    while index < len(source):
        pair = source[index : index + 2]
        triple = source[index : index + 3]

        if state == "code":
            if pair == "//":
                masked[index : index + 2] = "  "
                index += 2
                state = "line_comment"
                continue
            if pair == "/*":
                masked[index : index + 2] = "  "
                index += 2
                block_depth = 1
                state = "block_comment"
                continue
            if triple == '\"\"\"':
                masked[index : index + 3] = "   "
                index += 3
                state = "triple_string"
                continue
            if source[index] in {'\"', "'"}:
                state = "string" if source[index] == '\"' else "char"
                masked[index] = " "
                index += 1
                continue
            index += 1
            continue

        if state == "line_comment":
            if source[index] == "\n":
                state = "code"
            else:
                masked[index] = " "
            index += 1
            continue

        if state == "block_comment":
            if pair == "/*":
                masked[index : index + 2] = "  "
                block_depth += 1
                index += 2
            elif pair == "*/":
                masked[index : index + 2] = "  "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
            else:
                if source[index] != "\n":
                    masked[index] = " "
                index += 1
            continue

        if state == "triple_string":
            if triple == '\"\"\"':
                masked[index : index + 3] = "   "
                index += 3
                state = "code"
            else:
                if source[index] != "\n":
                    masked[index] = " "
                index += 1
            continue

        delimiter = '\"' if state == "string" else "'"
        if source[index] == "\\" and index + 1 < len(source):
            masked[index : index + 2] = "  "
            index += 2
        elif source[index] == delimiter:
            masked[index] = " "
            index += 1
            state = "code"
        else:
            if source[index] != "\n":
                masked[index] = " "
            index += 1

    if state not in {"code", "line_comment"}:
        raise ValueError("unterminated Kotlin literal or comment")
    return "".join(masked)


def _kotlin_functions(source: str) -> dict[str, KotlinFunction]:
    code = _mask_kotlin_noncode(source)
    declared_names = set(
        re.findall(r"\bfun\s+([A-Za-z_]\w*)\s*\(", code)
    )
    signature = re.compile(
        r"\bfun\s+(?P<name>[A-Za-z_]\w*)\s*\((?P<params>[^)]*)\)"
        r"\s*(?::\s*[^\n{=]+)?\s*(?P<body_start>[{=])"
    )
    functions: dict[str, KotlinFunction] = {}
    for match in signature.finditer(code):
        name = match.group("name")
        if name in functions:
            raise ValueError("overloaded Kotlin helper is not statically bounded")

        if match.group("body_start") == "=":
            end = code.find("\n", match.end())
            end = len(code) if end < 0 else end
            body = code[match.end() : end]
        else:
            body_start = match.end()
            depth = 1
            end = body_start
            while end < len(code) and depth:
                if code[end] == "{":
                    depth += 1
                elif code[end] == "}":
                    depth -= 1
                end += 1
            if depth:
                raise ValueError("unterminated Kotlin function body")
            body = code[body_start : end - 1]

        functions[name] = KotlinFunction(name, match.group("params"), body)
    if set(functions) != declared_names:
        raise ValueError("unparsed Kotlin helper signature")
    return functions


def _call_arguments(body: str, name_pattern: str) -> list[str]:
    calls: list[str] = []
    pattern = re.compile(name_pattern + r"\s*\(")
    for match in pattern.finditer(body):
        start = match.end()
        depth = 1
        index = start
        while index < len(body) and depth:
            if body[index] == "(":
                depth += 1
            elif body[index] == ")":
                depth -= 1
            index += 1
        if depth:
            raise ValueError("unterminated Kotlin call")
        calls.append(body[start : index - 1])
    return calls


def _split_kotlin_args(arguments: str) -> list[str]:
    if not arguments.strip():
        return []
    parts: list[str] = []
    start = 0
    depth = 0
    for index, character in enumerate(arguments):
        if character in "([{<":
            depth += 1
        elif character in ")]}>":
            depth -= 1
            if depth < 0:
                raise ValueError("invalid Kotlin argument nesting")
        elif character == "," and depth == 0:
            parts.append(arguments[start:index].strip())
            start = index + 1
    if depth:
        raise ValueError("invalid Kotlin argument nesting")
    parts.append(arguments[start:].strip())
    return parts


def _timeout_argument(arguments: str, positional_index: int, default: str) -> str:
    parts = _split_kotlin_args(arguments)
    for part in parts:
        named = re.fullmatch(r"timeoutMs\s*=\s*(.+)", part)
        if named:
            return named.group(1).strip()
    if len(parts) > positional_index and "=" not in parts[positional_index]:
        return parts[positional_index]
    return default


def _wait_category(token: str, constants: dict[str, int]) -> str:
    normalized = re.sub(r"\s+", "", token)
    if normalized in constants:
        return normalized
    numeric = re.fullmatch(r"([0-9_]+)L?", normalized)
    if numeric:
        value = int(numeric.group(1).replace("_", ""))
        matching = [name for name, known in constants.items() if known == value]
        if len(matching) == 1:
            return matching[0]
    raise ValueError("unrecognized wait timeout")


def _validate_wait_primitives(functions: dict[str, KotlinFunction]) -> int:
    text_wait = functions.get("waitForText")
    keyboard_wait = functions.get("waitForKeyboard")
    if not text_wait or not keyboard_wait:
        raise ValueError("missing bounded wait primitive")
    if len(re.findall(r"\bdevice\.wait\s*\(", text_wait.body)) != 1:
        raise ValueError("unrecognized text wait primitive")
    if re.search(r"\b(?:SystemClock|Thread)\.sleep\s*\(", text_wait.body):
        raise ValueError("unrecognized text wait primitive")
    if re.search(r"\bdevice\.wait\s*\(", keyboard_wait.body):
        raise ValueError("unrecognized keyboard wait primitive")
    if len(re.findall(r"\bSystemClock\.sleep\s*\(", keyboard_wait.body)) != 1:
        raise ValueError("unrecognized keyboard wait primitive")
    if _call_arguments(text_wait.body, r"(?<![\w.])waitFor(?:Text|Keyboard)"):
        raise ValueError("nested recognized wait primitive")
    if _call_arguments(keyboard_wait.body, r"(?<![\w.])waitFor(?:Text|Keyboard)"):
        raise ValueError("nested recognized wait primitive")

    default = re.search(
        r"\btimeoutMs\s*:\s*Long\s*=\s*([0-9_]+)L?", keyboard_wait.params
    )
    if not default:
        raise ValueError("missing keyboard timeout")
    return int(default.group(1).replace("_", ""))


def _direct_waits(
    function: KotlinFunction,
    constants: dict[str, int],
    keyboard_ms: int,
) -> dict[str, int]:
    counts = {name: 0 for name in (*constants, "keyboard", "idle")}
    for arguments in _call_arguments(
        function.body, r"(?<![\w.])waitForText"
    ):
        category = _wait_category(
            _timeout_argument(arguments, 1, "UI_TIMEOUT_MS"), constants
        )
        counts[category] += 1

    for arguments in _call_arguments(
        function.body, r"(?<![\w.])waitForKeyboard"
    ):
        timeout = _timeout_argument(arguments, 0, str(keyboard_ms))
        numeric = re.fullmatch(r"([0-9_]+)L?", re.sub(r"\s+", "", timeout))
        if not numeric or int(numeric.group(1).replace("_", "")) != keyboard_ms:
            raise ValueError("unrecognized keyboard timeout")
        counts["keyboard"] += 1

    for arguments in _call_arguments(function.body, r"\bdevice\.waitForIdle"):
        if arguments.strip():
            raise ValueError("unrecognized idle timeout")
        counts["idle"] += 1

    if function.name not in {"waitForText", "waitForKeyboard"}:
        if re.search(r"\bdevice\.wait\s*\(", function.body):
            raise ValueError("unrecognized direct device wait")
        if re.search(r"\b(?:SystemClock|Thread)\.sleep\s*\(", function.body):
            raise ValueError("unrecognized direct sleep")
        qualified_waits = re.findall(
            r"\.\s*((?:await|sleep|wait)\w*)\s*\(",
            function.body,
            flags=re.IGNORECASE,
        )
        if any(name != "waitForIdle" for name in qualified_waits):
            raise ValueError("unrecognized qualified wait-bearing call")
        undefined_wait = re.search(
            r"(?<![\w.])(?:await\w*|sleep\w*|wait\w*)\s*\(",
            function.body,
            flags=re.IGNORECASE,
        )
        if undefined_wait and not re.match(
            r"waitFor(?:Text|Keyboard)\s*\(", undefined_wait.group(0)
        ):
            raise ValueError("unrecognized wait-bearing call")
    return counts


def _aggregate_waits(
    roots: Sequence[str],
    functions: dict[str, KotlinFunction],
    constants: dict[str, int],
    keyboard_ms: int,
) -> dict[str, int]:
    memo: dict[str, dict[str, int]] = {}
    visiting: set[str] = set()

    def visit(name: str) -> dict[str, int]:
        if name in memo:
            return memo[name]
        if name in visiting:
            raise ValueError("cyclic Kotlin helper graph")
        function = functions.get(name)
        if not function:
            raise ValueError("missing Kotlin root or helper")
        if "::" in function.body or re.search(
            r"\bthis\s*\.\s*[A-Za-z_]\w*\s*\(", function.body
        ):
            raise ValueError("indirect Kotlin helper dispatch is not bounded")

        visiting.add(name)
        totals = _direct_waits(function, constants, keyboard_ms)
        for callee in functions:
            if callee in {"waitForText", "waitForKeyboard"}:
                continue
            multiplicity = len(
                _call_arguments(
                    function.body, rf"(?<![\w.]){re.escape(callee)}"
                )
            )
            if not multiplicity:
                continue
            nested = visit(callee)
            for category, count in nested.items():
                totals[category] += multiplicity * count

        visiting.remove(name)
        if any(totals.values()) and re.search(
            r"\b(?:repeat|while|for)\s*\(", function.body
        ):
            raise ValueError("wait-bearing Kotlin loop is not statically bounded")
        memo[name] = totals
        return totals

    result = {name: 0 for name in (*constants, "keyboard", "idle")}
    for root in roots:
        for category, count in visit(root).items():
            result[category] += count
    return result


def derive_wait_budget(source: str) -> WaitBudget:
    """Derive bounded waits from every reachable Kotlin helper call graph."""

    code = _mask_kotlin_noncode(source)
    functions = _kotlin_functions(source)
    constants = {
        name: _parse_kotlin_ms(code, name)
        for name in (
            "UI_TIMEOUT_MS",
            "FILTER_TIMEOUT_MS",
            "OFFLINE_TIMEOUT_MS",
            "RECOVERY_TIMEOUT_MS",
        )
    }
    keyboard_ms = _validate_wait_primitives(functions)
    counts = _aggregate_waits(
        ("setUp", "canonicalProfileSurvivesLifecycleRotationAndOfflineRecovery"),
        functions,
        constants,
        keyboard_ms,
    )
    if any(counts[name] < 1 for name in (*constants, "keyboard", "idle")):
        raise ValueError("invalid wait call graph")

    return WaitBudget(
        ui_count=counts["UI_TIMEOUT_MS"],
        ui_ms=constants["UI_TIMEOUT_MS"],
        filter_count=counts["FILTER_TIMEOUT_MS"],
        filter_ms=constants["FILTER_TIMEOUT_MS"],
        offline_count=counts["OFFLINE_TIMEOUT_MS"],
        offline_ms=constants["OFFLINE_TIMEOUT_MS"],
        recovery_count=counts["RECOVERY_TIMEOUT_MS"],
        recovery_ms=constants["RECOVERY_TIMEOUT_MS"],
        keyboard_count=counts["keyboard"],
        keyboard_ms=keyboard_ms,
        idle_count=counts["idle"],
        idle_ms=10_000,
    )


def _stage_run(
    executor: object,
    argv: Sequence[str],
    *,
    absolute_deadline: float,
    cap_ms: int,
    monotonic: Callable[[], float],
) -> CommandResult:
    now = monotonic()
    if now >= absolute_deadline:
        raise CommandDeadlineExceeded()
    return executor.run(argv, min(absolute_deadline, now + cap_ms / 1_000))


def _adb(serial: str, *args: str) -> list[str]:
    return ["adb", "--exit-on-write-error", "-s", serial, *args]


def _authorized_target(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> bool:
    result = _stage_run(
        executor,
        ["adb", "devices", "-l"],
        absolute_deadline=deadline,
        cap_ms=20_000,
        monotonic=monotonic,
    )
    if result.returncode != 0 or result.stdout_truncated:
        return False

    matches: list[str] = []
    for raw in _bounded_text(result.stdout).splitlines()[1:]:
        fields = raw.split()
        if len(fields) < 2 or fields[1] != "device":
            continue
        attrs = dict(part.split(":", 1) for part in fields[2:] if ":" in part)
        if attrs.get("model", "").replace("_", "-") == "SM-T390":
            matches.append(fields[0])
    return matches == [serial]


def _wifi_state(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> str | None:
    result = _stage_run(
        executor,
        _adb(serial, "shell", "settings", "get", "global", "wifi_on"),
        absolute_deadline=deadline,
        cap_ms=15_000,
        monotonic=monotonic,
    )
    if result.stdout_truncated:
        return None
    state = _bounded_text(result.stdout).strip()
    return state if result.returncode == 0 and state in {"0", "1"} else None


def _device_epoch(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> float | None:
    result = _stage_run(
        executor,
        _adb(serial, "shell", "date", "+%s"),
        absolute_deadline=deadline,
        cap_ms=15_000,
        monotonic=monotonic,
    )
    try:
        if result.returncode != 0 or result.stdout_truncated:
            return None
        return float(_bounded_text(result.stdout).strip())
    except ValueError:
        return None


def _find_apkanalyzer() -> str | None:
    discovered = shutil.which("apkanalyzer")
    if discovered:
        return discovered
    for variable in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        root = os.environ.get(variable)
        if not root:
            continue
        for relative in (
            "cmdline-tools/latest/bin/apkanalyzer",
            "tools/bin/apkanalyzer",
        ):
            candidate = Path(root) / relative
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
    return None


def _find_apksigner() -> str | None:
    discovered = shutil.which("apksigner")
    if discovered:
        return discovered

    candidates: list[Path] = []
    for variable in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        root = os.environ.get(variable)
        if not root:
            continue
        candidates.extend((Path(root) / "build-tools").glob("*/apksigner"))
    executable = [
        candidate
        for candidate in candidates
        if candidate.is_file() and os.access(candidate, os.X_OK)
    ]
    if not executable:
        return None

    def version_key(candidate: Path) -> tuple[int, ...]:
        return tuple(int(part) for part in re.findall(r"\d+", candidate.parent.name))

    return str(max(executable, key=version_key))


def _stage_exact_apk(
    driver_apk: str,
    expected_apk_sha256: str,
    staging_directory: str,
) -> str | None:
    if not SHA256_PATTERN.fullmatch(expected_apk_sha256):
        return None

    requested = Path(driver_apk)
    if not requested.is_absolute():
        return None
    try:
        resolved = requested.resolve(strict=True)
    except OSError:
        return None
    if not resolved.is_file() or resolved.suffix.lower() != ".apk":
        return None

    staged = Path(staging_directory) / "reviewed-driver.apk"
    digest = hashlib.sha256()
    try:
        with resolved.open("rb") as source, staged.open("xb") as destination:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
                destination.write(chunk)
    except OSError:
        return None
    if digest.hexdigest() != expected_apk_sha256.lower():
        return None
    return str(staged)


def _manifest_matches_reviewed_contract(
    manifest_text: str,
    source_sha256: str,
) -> bool:
    if not SHA256_PATTERN.fullmatch(source_sha256):
        return False
    try:
        root = ET.fromstring(manifest_text)
    except ET.ParseError:
        return False

    android_name = f"{{{ANDROID_XML_NS}}}name"
    android_target = f"{{{ANDROID_XML_NS}}}targetPackage"
    android_value = f"{{{ANDROID_XML_NS}}}value"
    if root.tag != "manifest" or root.attrib.get("package") != DRIVER_PACKAGE:
        return False

    instrumentations = root.findall("instrumentation")
    if len(instrumentations) != 1:
        return False
    instrumentation = instrumentations[0]
    if instrumentation.attrib.get(android_name) != EXPECTED_RUNNER_CLASS:
        return False
    if instrumentation.attrib.get(android_target) != BASE_PACKAGE:
        return False

    application = root.find("application")
    if application is None:
        return False
    source_metadata = [
        item
        for item in application.findall("meta-data")
        if item.attrib.get(android_name) == UTILITY_SOURCE_DIGEST_METADATA
    ]
    return (
        len(source_metadata) == 1
        and source_metadata[0].attrib.get(android_value) == source_sha256
    )


def _signature_output_valid(output: str) -> bool:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if not lines or lines[0] != "Verifies":
        return False

    scheme = re.compile(
        r"Verified using v[0-9.]+ scheme(?: \([^)]*\))?: (true|false)"
    )
    source_stamp = re.compile(r"Verified for SourceStamp: (?:true|false)")
    signer_count = re.compile(r"Number of signers: ([1-9][0-9]*)")
    saw_verified_scheme = False
    signer_rows = 0
    for line in lines[1:]:
        scheme_match = scheme.fullmatch(line)
        if scheme_match:
            saw_verified_scheme = (
                saw_verified_scheme or scheme_match.group(1) == "true"
            )
            continue
        if source_stamp.fullmatch(line):
            continue
        if signer_count.fullmatch(line):
            signer_rows += 1
            continue
        return False
    return saw_verified_scheme and signer_rows == 1


def _validated_driver_apk(
    executor: object,
    driver_apk: str,
    expected_apk_sha256: str,
    source_sha256: str,
    staging_directory: str,
    analyzer_locator: Callable[[], str | None],
    signer_locator: Callable[[], str | None],
    deadline: float,
    monotonic: Callable[[], float],
) -> str | None:
    staged = _stage_exact_apk(
        driver_apk, expected_apk_sha256, staging_directory
    )
    if staged is None:
        return None

    analyzer = analyzer_locator()
    signer = signer_locator()
    if not analyzer or not signer:
        return None

    signature = _stage_run(
        executor,
        [signer, "verify", "--verbose", staged],
        absolute_deadline=deadline,
        cap_ms=30_000,
        monotonic=monotonic,
    )
    if (
        signature.returncode != 0
        or signature.stdout_truncated
        or not _signature_output_valid(_bounded_text(signature.stdout))
    ):
        return None

    application_id = _stage_run(
        executor,
        [analyzer, "manifest", "application-id", staged],
        absolute_deadline=deadline,
        cap_ms=30_000,
        monotonic=monotonic,
    )
    if (
        application_id.returncode != 0
        or application_id.stdout_truncated
        or _bounded_text(application_id.stdout).strip() != DRIVER_PACKAGE
    ):
        return None

    manifest = _stage_run(
        executor,
        [analyzer, "manifest", "print", staged],
        absolute_deadline=deadline,
        cap_ms=30_000,
        monotonic=monotonic,
    )
    if (
        manifest.returncode != 0
        or manifest.stdout_truncated
        or not _manifest_matches_reviewed_contract(
            _bounded_text(manifest.stdout), source_sha256
        )
    ):
        return None
    return staged


def _driver_present(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> bool | None:
    result = _stage_run(
        executor,
        _adb(serial, "shell", "pm", "list", "packages", DRIVER_PACKAGE),
        absolute_deadline=deadline,
        cap_ms=15_000,
        monotonic=monotonic,
    )
    if result.returncode != 0:
        return None
    if result.stdout_truncated:
        return None
    output = _bounded_text(result.stdout).strip()
    if not output:
        return False
    if output == f"package:{DRIVER_PACKAGE}":
        return True
    return None


def _file_digest_matches(path: str, expected_sha256: str) -> bool:
    if not SHA256_PATTERN.fullmatch(expected_sha256):
        return False
    digest = hashlib.sha256()
    try:
        with Path(path).open("rb") as artifact:
            while chunk := artifact.read(1024 * 1024):
                digest.update(chunk)
    except OSError:
        return False
    return digest.hexdigest() == expected_sha256.lower()


def _installed_driver_path(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> str | None:
    result = _stage_run(
        executor,
        _adb(serial, "shell", "pm", "path", DRIVER_PACKAGE),
        absolute_deadline=deadline,
        cap_ms=15_000,
        monotonic=monotonic,
    )
    if result.returncode != 0 or result.stdout_truncated:
        return None
    lines = _bounded_text(result.stdout).splitlines()
    if len(lines) != 1 or not lines[0].startswith("package:"):
        return None
    installed_path = lines[0][len("package:") :]
    return (
        installed_path
        if INSTALLED_DRIVER_APK_PATTERN.fullmatch(installed_path)
        else None
    )


def _installed_driver_identity(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> tuple[str, str] | None:
    installed_path = _installed_driver_path(
        executor, serial, deadline, monotonic
    )
    if installed_path is None:
        return None
    result = _stage_run(
        executor,
        _adb(serial, "shell", DEVICE_SHA256SUM, "-b", installed_path),
        absolute_deadline=deadline,
        cap_ms=30_000,
        monotonic=monotonic,
    )
    if result.returncode != 0 or result.stdout_truncated:
        return None
    output = _bounded_text(result.stdout)
    digest = (
        output.rstrip("\n")
        if re.fullmatch(r"[0-9a-f]{64}\n?", output)
        else None
    )
    return (installed_path, digest) if digest is not None else None


def _install_driver(
    executor: object,
    serial: str,
    driver_apk: str,
    expected_apk_sha256: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> tuple[str, str | None]:
    result = _stage_run(
        executor,
        _adb(serial, "install", "--no-streaming", "-t", driver_apk),
        absolute_deadline=deadline,
        cap_ms=90_000,
        monotonic=monotonic,
    )
    output = _bounded_text(result.stdout)
    if result.returncode != 0 or result.stdout_truncated:
        return (
            (
                "ownership_conflict"
                if "INSTALL_FAILED_ALREADY_EXISTS" in output
                else "ambiguous"
            ),
            None,
        )
    if "Success" not in output:
        return "ambiguous", None
    if _driver_present(executor, serial, deadline, monotonic) is not True:
        return "ambiguous", None
    installed_identity = _installed_driver_identity(
        executor, serial, deadline, monotonic
    )
    if (
        installed_identity is not None
        and installed_identity[1] == expected_apk_sha256.lower()
    ):
        return "installed", installed_identity[0]
    return "ambiguous", None


def _fixed_metrics(
    executor: object,
    serial: str,
    started_epoch: float,
    deadline: float,
    monotonic: Callable[[], float],
) -> tuple[dict[str, int], bool]:
    result = _stage_run(
        executor,
        _adb(
            serial,
            "logcat",
            "-d",
            "-v",
            "epoch",
            "-s",
            "CaseinUtilitySoak:I",
            "*:S",
        ),
        absolute_deadline=deadline,
        cap_ms=30_000,
        monotonic=monotonic,
    )
    if result.returncode != 0 or result.stdout_truncated:
        return {}, False

    metrics: dict[str, int] = {}
    for line in _bounded_text(result.stdout).splitlines():
        match = FIXED_METRIC_PATTERN.fullmatch(line.strip())
        if not match or float(match.group("epoch")) + 1 < started_epoch:
            continue
        metrics[match.group("key")] = int(match.group("value"))
    return metrics, True


def _last_metric_stage(metrics: dict[str, int]) -> str:
    if "offline_recovery_ms" in metrics:
        return "after_offline_recovery"
    if "warm_resume_ms" in metrics:
        return "after_warm_resume"
    if "cold_launch_ms" in metrics:
        return "after_cold_launch"
    return "before_cold_metric"


def _failure_stage(output: str, default: str) -> str:
    lowered = _bounded_text(output).lower()
    categories = (
        ("cold launch", "cold_launch"),
        ("dashboard did not render", "first_paint"),
        ("canonical origin", "canonical_identity"),
        ("authenticated live feed", "authentication_or_recovery"),
        ("legacy devide", "legacy_origin_separation"),
        ("landscape", "rotation"),
        ("portrait", "rotation"),
        ("root back", "back_navigation"),
        ("needs me", "attention_filter"),
        ("live did not settle", "live_filter"),
        ("software keyboard", "keyboard"),
        ("saved profile did not report offline", "offline_state"),
        ("card stream did not expose", "offline_state"),
        ("read-only state", "offline_read_only"),
        ("offline banner remained", "offline_recovery"),
    )
    for needle, category in categories:
        if needle in lowered:
            return category
    return default


def _restore_wifi(
    executor: object,
    serial: str,
    initial: str,
    deadline: float,
    monotonic: Callable[[], float],
    sleep: Callable[[float], None],
) -> tuple[bool, bool]:
    if _wifi_state(executor, serial, deadline, monotonic) == initial:
        return False, True

    action = "enable" if initial == "1" else "disable"
    result = _stage_run(
        executor,
        _adb(serial, "shell", "svc", "wifi", action),
        absolute_deadline=deadline,
        cap_ms=30_000,
        monotonic=monotonic,
    )
    if result.returncode != 0:
        return True, False
    while monotonic() < deadline:
        if _wifi_state(executor, serial, deadline, monotonic) == initial:
            return True, True
        sleep(min(0.25, max(0.0, deadline - monotonic())))
    return True, False


def _no_active_instrumentation(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> bool | None:
    for package in (BASE_PACKAGE, DRIVER_PACKAGE):
        result = _stage_run(
            executor,
            _adb(
                serial,
                "shell",
                "dumpsys",
                "activity",
                "processes",
                package,
            ),
            absolute_deadline=deadline,
            cap_ms=15_000,
            monotonic=monotonic,
        )
        if result.returncode != 0 or result.stdout_truncated:
            return None
        state = _parse_instrumentation_quiescence(
            _bounded_text(result.stdout)
        )
        if state is not True:
            return state
    return True


def _parse_instrumentation_quiescence(output: str) -> bool | None:
    lines = output.splitlines()
    if not lines or not lines[0].startswith(
        "ACTIVITY MANAGER RUNNING PROCESSES"
    ):
        return None
    if "ActiveInstrumentation{" in output or INSTRUMENTATION_RUNNER in output:
        return False
    return True


def _no_target_processes(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
) -> bool | None:
    # Android 9 toybox defines NAME as argv[0]; -w prevents package-name
    # truncation from turning an active target into a false absence.
    result = _stage_run(
        executor,
        _adb(serial, "shell", "ps", "-A", "-w", "-o", "NAME"),
        absolute_deadline=deadline,
        cap_ms=15_000,
        monotonic=monotonic,
    )
    if result.returncode != 0 or result.stdout_truncated:
        return None
    return _parse_target_process_quiescence(_bounded_text(result.stdout))


def _parse_target_process_quiescence(output: str) -> bool | None:
    rows = [line.strip() for line in output.splitlines()]
    if not rows or rows[0] != "NAME" or any(not row for row in rows):
        return None
    for process_name in rows[1:]:
        if re.search(r"\s", process_name):
            return None
        if process_name in {BASE_PACKAGE, DRIVER_PACKAGE}:
            return False
        if process_name.startswith(BASE_PACKAGE + ":"):
            return False
        if process_name.startswith(DRIVER_PACKAGE + ":"):
            return False
    return True


def _device_quiescent(
    executor: object,
    serial: str,
    deadline: float,
    monotonic: Callable[[], float],
    sleep: Callable[[float], None],
) -> bool:
    for _attempt in range(QUIESCENCE_MAX_POLLS):
        if monotonic() >= deadline:
            return False
        instrumentation = _no_active_instrumentation(
            executor, serial, deadline, monotonic
        )
        processes = _no_target_processes(
            executor, serial, deadline, monotonic
        )
        if instrumentation is True and processes is True:
            return True
        if instrumentation is None or processes is None:
            return False
        sleep(min(0.25, max(0.0, deadline - monotonic())))
    return False


def _cleanup_driver(
    executor: object,
    serial: str,
    installed_apk_path: str,
    expected_apk_sha256: str,
    deadline: float,
    monotonic: Callable[[], float],
    sleep: Callable[[float], None],
) -> tuple[bool, bool]:
    def reviewed_driver_still_installed() -> bool:
        try:
            installed_identity = _installed_driver_identity(
                executor, serial, deadline, monotonic
            )
        except Exception:
            return False
        return (
            INSTALLED_DRIVER_APK_PATTERN.fullmatch(installed_apk_path)
            is not None
            and SHA256_PATTERN.fullmatch(expected_apk_sha256) is not None
            and installed_identity
            == (installed_apk_path, expected_apk_sha256.lower())
        )

    for package in (DRIVER_PACKAGE, BASE_PACKAGE):
        # Ownership is re-proved with read-only package-path and digest queries
        # immediately before every cleanup mutation. Any package replacement,
        # disappearance, malformed/truncated reply, or query failure leaves both
        # the driver and base app untouched from this point forward.
        if not reviewed_driver_still_installed():
            return False, False
        try:
            _stage_run(
                executor,
                _adb(serial, "shell", "am", "force-stop", package),
                absolute_deadline=deadline,
                cap_ms=20_000,
                monotonic=monotonic,
            )
        except Exception:
            pass

    try:
        quiescent = _device_quiescent(
            executor, serial, deadline, monotonic, sleep
        )
    except Exception:
        quiescent = False
    if not quiescent:
        return False, False

    # Quiescence is established before this read-only revalidation and remains
    # the required gate for uninstalling the exact reviewed driver.
    if not reviewed_driver_still_installed():
        return False, True

    try:
        uninstall = _stage_run(
            executor,
            _adb(serial, "uninstall", DRIVER_PACKAGE),
            absolute_deadline=deadline,
            cap_ms=25_000,
            monotonic=monotonic,
        )
        if uninstall.returncode != 0:
            return False, True
        return (
            _driver_present(executor, serial, deadline, monotonic) is False,
            True,
        )
    except Exception:
        return False, True


def run_utility_soak(
    serial: str,
    driver_apk: str,
    expected_apk_sha256: str,
    *,
    executor: object | None = None,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    analyzer_locator: Callable[[], str | None] = _find_apkanalyzer,
    signer_locator: Callable[[], str | None] = _find_apksigner,
    utility_source: Path = UTILITY_TEST_SOURCE,
) -> dict[str, object]:
    """Run one whole bounded cohort and return only the fixed public schema."""

    run_started = monotonic()
    hard_deadline = run_started + WHOLE_RUN_TIMEOUT_MS / 1_000
    cleanup_start = hard_deadline - CLEANUP_RESERVE_MS / 1_000
    telemetry_start = cleanup_start - TELEMETRY_RESERVE_MS / 1_000
    runner = executor or SubprocessExecutor(monotonic=monotonic)
    outcome = _result()

    if not SERIAL_PATTERN.fullmatch(serial):
        outcome.update(status="invalid_target", failure_stage="preflight")
        outcome["duration_ms"] = max(0, int((monotonic() - run_started) * 1_000))
        return outcome

    try:
        if not _authorized_target(runner, serial, telemetry_start, monotonic):
            outcome.update(status="target_ambiguous", failure_stage="preflight")
            outcome["duration_ms"] = max(0, int((monotonic() - run_started) * 1_000))
            return outcome
    except CommandDeadlineExceeded:
        outcome.update(status="timeout", timed_out=True, failure_stage="target_preflight")
        outcome["duration_ms"] = max(0, int((monotonic() - run_started) * 1_000))
        return outcome
    except Exception:
        outcome.update(status="runner_error", failure_stage="target_preflight")
        outcome["duration_ms"] = max(0, int((monotonic() - run_started) * 1_000))
        return outcome

    wifi_baseline: str | None = None
    driver_owned = False
    owned_driver_apk_path: str | None = None
    wifi_may_have_changed = False
    staging_directory = None
    output = ""
    metrics: dict[str, int] = {}

    try:
        wifi_baseline = _wifi_state(runner, serial, telemetry_start, monotonic)
        if wifi_baseline is None:
            raise RunFailure("wifi_state_unreadable", "preflight")
        outcome["wifi_initially_enabled"] = wifi_baseline == "1"
        if wifi_baseline != "1":
            raise RunFailure("wifi_initially_disabled", "preflight")

        try:
            source_bytes = utility_source.read_bytes()
            source_text = source_bytes.decode("utf-8")
            wait_budget = derive_wait_budget(source_text)
            if (
                _parse_kotlin_ms(
                    source_text, "DEVICE_WATCHDOG_TIMEOUT_MS"
                )
                != DEVICE_WATCHDOG_TIMEOUT_MS
            ):
                raise ValueError("watchdog source mismatch")
        except (OSError, UnicodeError, ValueError):
            raise RunFailure("source_contract_invalid", "wait_budget") from None
        source_sha256 = hashlib.sha256(source_bytes).hexdigest()
        safety_margin_ms = (
            WHOLE_RUN_TIMEOUT_MS
            - CLEANUP_RESERVE_MS
            - TELEMETRY_RESERVE_MS
            - wait_budget.total_ms
        )
        if safety_margin_ms < 0:
            raise RunFailure("source_contract_invalid", "wait_budget")
        outcome.update(
            explicit_wait_budget_ms=wait_budget.total_ms,
            safety_margin_ms=safety_margin_ms,
        )

        started_epoch = _device_epoch(runner, serial, telemetry_start, monotonic)
        if started_epoch is None:
            raise RunFailure("device_clock_unreadable", "preflight")

        staging_directory = tempfile.TemporaryDirectory(
            prefix="casein-utility-soak-"
        )
        validated_apk = _validated_driver_apk(
            runner,
            driver_apk,
            expected_apk_sha256,
            source_sha256,
            staging_directory.name,
            analyzer_locator,
            signer_locator,
            telemetry_start,
            monotonic,
        )
        if validated_apk is None:
            raise RunFailure("driver_apk_invalid", "driver_preflight")
        outcome["reviewed_apk_verified"] = True

        initial_driver_state = _driver_present(
            runner, serial, telemetry_start, monotonic
        )
        if initial_driver_state is None:
            raise RunFailure("driver_state_unknown", "driver_preflight")
        if initial_driver_state:
            raise RunFailure("driver_preexisting", "driver_preflight")

        # Re-read the private staged copy immediately before crossing the
        # install boundary. The authoritative proof is still the on-device
        # digest below; this check rejects an already-observable host swap
        # without mutating the device.
        if not _file_digest_matches(validated_apk, expected_apk_sha256):
            raise RunFailure("driver_apk_invalid", "driver_preflight")

        outcome["driver_install_attempted"] = True
        try:
            install_status, installed_apk_path = _install_driver(
                runner,
                serial,
                validated_apk,
                expected_apk_sha256,
                telemetry_start,
                monotonic,
            )
        except CommandDeadlineExceeded:
            raise RunFailure(
                "driver_install_ambiguous", "driver_install"
            ) from None
        if install_status == "ownership_conflict":
            raise RunFailure("driver_ownership_conflict", "driver_install")
        if install_status != "installed" or installed_apk_path is None:
            raise RunFailure("driver_install_ambiguous", "driver_install")
        owned_driver_apk_path = installed_apk_path
        driver_owned = True
        outcome["driver_installed"] = True

        device_guard_budget = (
            DEVICE_WATCHDOG_TIMEOUT_MS + DEVICE_QUIESCENCE_RESERVE_MS
        ) / 1_000
        if telemetry_start - monotonic() < device_guard_budget:
            raise RunFailure("watchdog_budget_exhausted", "instrumentation")

        timed_out = False
        execution_error = False
        output_truncated = False
        returncode: int | None = None
        try:
            wifi_may_have_changed = True
            instrument = runner.run(
                _adb(
                    serial,
                    "shell",
                    "am",
                    "instrument",
                    "-w",
                    "-r",
                    "-e",
                    "class",
                    TEST_CLASS,
                    "-e",
                    "timeout_msec",
                    str(DEVICE_WATCHDOG_TIMEOUT_MS),
                    "-e",
                    "casein_watchdog_ms",
                    str(DEVICE_WATCHDOG_TIMEOUT_MS),
                    INSTRUMENTATION_RUNNER,
                ),
                telemetry_start,
            )
            output = _bounded_text(instrument.stdout)
            output_truncated = instrument.stdout_truncated
            returncode = instrument.returncode
            outcome["test_completed"] = True
        except CommandDeadlineExceeded as timeout:
            timed_out = True
            output = _bounded_text(timeout.output)
        except Exception:
            execution_error = True

        outcome["timed_out"] = timed_out
        metrics_read = False
        try:
            metrics, metrics_read = _fixed_metrics(
                runner, serial, started_epoch, cleanup_start, monotonic
            )
        except Exception:
            metrics, metrics_read = {}, False

        required_metrics = {"cold_launch_ms", "warm_resume_ms"}
        if wifi_baseline == "1":
            required_metrics.add("offline_recovery_ms")
        metrics_complete = metrics_read and required_metrics.issubset(metrics)

        outcome.update(
            last_stage=_last_metric_stage(metrics),
            cold_launch_ms=metrics.get("cold_launch_ms"),
            warm_resume_ms=metrics.get("warm_resume_ms"),
            offline_recovery_ms=metrics.get("offline_recovery_ms"),
        )
        passed = (
            outcome["test_completed"]
            and not output_truncated
            and returncode == 0
            and "OK (1 test)" in output
            and "FAILURES!!!" not in output
            and "INSTRUMENTATION_FAILED" not in output
        )

        if timed_out:
            outcome.update(
                status="timeout",
                failure_stage=_failure_stage(output, outcome["last_stage"]),
            )
        elif execution_error:
            outcome.update(status="runner_error", failure_stage="instrumentation")
        elif output_truncated:
            outcome.update(
                status="test_failed",
                failure_stage="instrumentation_output_truncated",
            )
        elif not passed:
            outcome.update(
                status="test_failed",
                failure_stage=_failure_stage(output, outcome["last_stage"]),
            )
        elif not metrics_complete:
            outcome.update(status="telemetry_incomplete", failure_stage="metric_set")
        else:
            outcome.update(status="pass", failure_stage=None)
    except RunFailure as failure:
        outcome.update(status=failure.status, failure_stage=failure.stage)
    except CommandDeadlineExceeded:
        outcome.update(status="timeout", timed_out=True, failure_stage="whole_run")
    except Exception:
        outcome.update(status="runner_error", failure_stage="runner")
    finally:
        if driver_owned:
            outcome["driver_cleanup_attempted"] = True
            cleaned, quiescent = _cleanup_driver(
                runner,
                serial,
                owned_driver_apk_path or "",
                expected_apk_sha256,
                hard_deadline - WIFI_RESTORE_RESERVE_MS / 1_000,
                monotonic,
                sleep,
            )
            outcome["driver_cleaned"] = cleaned
            outcome["device_quiescent"] = quiescent

        if wifi_baseline is not None and not wifi_may_have_changed:
            outcome["wifi_restored"] = True
        elif wifi_baseline is not None and outcome["device_quiescent"]:
            try:
                attempted, restored = _restore_wifi(
                    runner,
                    serial,
                    wifi_baseline,
                    hard_deadline,
                    monotonic,
                    sleep,
                )
                outcome["wifi_restore_attempted"] = attempted
                outcome["wifi_restored"] = restored
            except Exception:
                outcome["wifi_restored"] = False

        wifi_failed = wifi_may_have_changed and not outcome["wifi_restored"]
        driver_failed = driver_owned and not outcome["driver_cleaned"]
        if wifi_failed or driver_failed:
            outcome["status"] = "cleanup_failed"
            outcome["failure_stage"] = (
                "wifi_restore_and_driver_cleanup"
                if wifi_failed and driver_failed
                else "wifi_restore"
                if wifi_failed
                else "driver_cleanup"
            )

        if staging_directory is not None:
            try:
                staging_directory.cleanup()
            except Exception:
                # Never allow a private temporary path or exception to escape
                # the fixed result schema. Preserve any stronger device
                # cleanup failure already recorded.
                if outcome["status"] != "cleanup_failed":
                    outcome["status"] = "cleanup_failed"
                    outcome["failure_stage"] = "artifact_staging_cleanup"

        outcome["duration_ms"] = max(
            0, int((monotonic() - run_started) * 1_000)
        )

    return outcome


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv if argv is None else argv)
    try:
        result = (
            run_utility_soak(args[1], args[2], args[3])
            if len(args) == 4
            else _result(
                status="invalid_target",
                failure_stage="preflight",
                duration_ms=0,
            )
        )
    except Exception:
        result = _result(
            status="runner_error", failure_stage="runner", duration_ms=0
        )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "pass" else 74


if __name__ == "__main__":
    raise SystemExit(main())
