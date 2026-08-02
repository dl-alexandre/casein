#!/usr/bin/env python3
"""Coordinate one privacy-safe physical native/server feed timing cohort.

The coordinator is deliberately narrower than a general process runner.  It
opens the release-only server fence first, composes the app-scoped source with
the strict native adapter and aggregate collector entirely in memory, and sends
the twenty terminal connection generations to the fence exactly once.  Only
the two validated aggregate objects may reach disk.
"""

from __future__ import annotations

import argparse
import importlib
import io
import json
import math
import os
import re
import resource
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Callable, Mapping, Protocol, Sequence, TextIO


sys.dont_write_bytecode = True
collector_contract = importlib.import_module("mobile_feed_timing_collector")
stream_contract = importlib.import_module("mobile_feed_timing_stream")
source_contract = importlib.import_module("mobile_feed_timing_source_supervisor")


COORDINATOR_NAME = "casein_mobile_feed_timing_coordinator"
TARGET_GENERATIONS = 20
GENERATION_BYTES = 22
GENERATION_LINE_BYTES = 23
GENERATION_PAYLOAD_BYTES = TARGET_GENERATIONS * GENERATION_LINE_BYTES

BRIDGE_READY = b"CASEIN_MOBILE_FEED_SOAK_READY\n"
BRIDGE_FAILED = b"CASEIN_MOBILE_FEED_SOAK_FAILED\n"
BRIDGE_SSH_HOST = "devbox"
BRIDGE_RELEASE_HELPER = "/opt/casein/release/bin/mobile_feed_timing_soak"

ANDROID_PACKAGE = "com.example.casein_mob"
ANDROID_ACTIVITY = "com.example.casein_mob.MainActivity"
ANDROID_RECONNECT_TEST = (
    "com.example.casein_mob.CaseinFeedLifecycleSoakTest"
    "#twentyExplicitCurrentOriginReconnects"
)
ANDROID_TEST_RUNNER = (
    "com.example.casein_mob.test/androidx.test.runner.AndroidJUnitRunner"
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
IOS_RECONNECT_RUNNER = (
    REPOSITORY_ROOT / "native/casein_mob/ios/run_feed_lifecycle_soak.sh"
)

PIPELINE_TIMEOUT_SECONDS = 45 * 60.0
SOURCE_READY_TIMEOUT_SECONDS = 20.0
SOURCE_JOIN_TIMEOUT_SECONDS = 5.0
BRIDGE_READY_TIMEOUT_SECONDS = 15.0
BRIDGE_FINISH_TIMEOUT_SECONDS = 15.0
BRIDGE_ABORT_TIMEOUT_SECONDS = 5.0
PROCESS_TERM_TIMEOUT_SECONDS = 2.0
PROCESS_KILL_TIMEOUT_SECONDS = 2.0
ANDROID_COMMAND_TIMEOUT_SECONDS = 60.0
ANDROID_RECONNECT_TIMEOUT_SECONDS = 45 * 60.0
IOS_RECONNECT_TIMEOUT_SECONDS = 45 * 60.0
MAX_BRIDGE_AGGREGATE_BYTES = 65_536
MAX_BRIDGE_AGGREGATE_WIRE_BYTES = MAX_BRIDGE_AGGREGATE_BYTES + 1
MAX_AGGREGATE_RECORDS = 2_000
MAX_DURATION_MS = 86_400_000
MAX_CARD_COUNT = 1_000
MAX_SNAPSHOT_JSON_BYTES = 1_000_000

PLATFORMS = ("ios", "android")
CYCLES = ("cold", "reconnect")

STATUS_VALUES = frozenset(
    {
        "complete",
        "cohort_mismatch",
        "invalid_arguments",
        "bridge_not_ready",
        "pipeline_failed",
        "source_failed",
        "bridge_finish_ambiguous",
        "server_aggregate_invalid",
        "publication_failed",
        "interrupted",
        "internal_error",
    }
)

EXIT_CODES = {
    "complete": 0,
    "cohort_mismatch": 5,
    "invalid_arguments": 64,
    "bridge_not_ready": 3,
    "pipeline_failed": 3,
    "source_failed": 3,
    "bridge_finish_ambiguous": 6,
    "server_aggregate_invalid": 6,
    "publication_failed": 4,
    "interrupted": 130,
    "internal_error": 70,
}

_GENERATION_RE = re.compile(r"^[A-Za-z0-9_-]{22}$")
_GENERATION_SEARCH_RE = re.compile(
    r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{22}(?![A-Za-z0-9_-])"
)
_SECRET_RE = re.compile(
    r"(?i)(?:bearer\s+|(?:api[_-]?key|access[_-]?token|password|passwd|secret|"
    r"credential)\s*[:=]|-----BEGIN\s+[^-]*PRIVATE\s+KEY-----)"
)

SERVER_STAGES = (
    "token_verified",
    "mobile_join_started",
    "mobile_join_replied",
    "workspace_watch_started",
    "workspace_watch_replied",
    "session_hydration_started",
    "session_hydration_finished",
    "clarification_hydration_finished",
    "observer_snapshot",
    "projection_broadcast",
    "snapshot_rendered",
    "push_queued",
)
SERVER_OUTCOMES = ("started", "succeeded", "failed", "skipped")
SERVER_REASONS = (
    "none",
    "user_token",
    "pairing_token",
    "device_link_token",
    "invalid_token",
    "mobile_join",
    "workspace_watch",
    "workspace_watched",
    "already_watched",
    "hydrated",
    "no_changes",
    "stale_hydration",
    "rendered",
    "pushed",
    "unauthorized",
)
SERVER_OPTIONAL_MEASUREMENTS = frozenset({"card_count", "snapshot_json_bytes"})
SERVER_KEYS = frozenset(
    {
        "schema_version",
        "component",
        "platform",
        "cycle",
        "expected_generation_count",
        "observed_generation_count",
        "cohort_match",
        "stage_timings",
        "outcome_counts",
        "reason_counts",
        "optional_measurements",
    }
)
SUMMARY_KEYS = frozenset({"min", "p50", "p95", "max"})


class InvalidArguments(Exception):
    """A CLI/config rejection with no reflected value."""


class CoordinatorFailure(Exception):
    """A fixed identity-free coordinator failure."""

    def __init__(self, status: str):
        self.status = status if status in STATUS_VALUES else "internal_error"
        super().__init__(self.status)

    def __repr__(self) -> str:
        return f"CoordinatorFailure(status={self.status!r})"


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        raise InvalidArguments


@dataclass(frozen=True, slots=True, repr=False)
class CohortConfig:
    platform: str
    cycle: str
    device: str
    output_root: Path
    ios_pid: int | None = None

    def __post_init__(self) -> None:
        if self.platform not in PLATFORMS or self.cycle not in CYCLES:
            raise InvalidArguments
        if not isinstance(self.output_root, Path) or not self.output_root.is_absolute():
            raise InvalidArguments

        try:
            if self.platform == "android":
                source_contract.build_android_source_argv(self.device)
                if self.ios_pid is not None:
                    raise InvalidArguments
            else:
                source_contract.build_plan(
                    "ios",
                    self.device,
                    ios_suspended_launch=self.cycle == "cold",
                    ios_pid=self.ios_pid if self.cycle == "reconnect" else None,
                )
                if self.cycle == "cold" and self.ios_pid is not None:
                    raise InvalidArguments
                if self.cycle == "reconnect" and self.ios_pid is None:
                    raise InvalidArguments
        except (
            source_contract.InvalidArguments,
            source_contract.SourceFailure,
            TypeError,
            ValueError,
        ):
            raise InvalidArguments from None

    def __repr__(self) -> str:
        return (
            "CohortConfig("
            f"platform={self.platform!r}, cycle={self.cycle!r}, "
            "device=<redacted>, output_root=<redacted>, "
            f"ios_pid={'set' if self.ios_pid is not None else 'unset'}"
            ")"
        )


@dataclass(frozen=True, slots=True)
class RunOutcome:
    status: str
    exit_code: int
    published: bool

    def __post_init__(self) -> None:
        if self.status not in STATUS_VALUES or self.exit_code != EXIT_CODES[self.status]:
            raise ValueError("invalid fixed outcome")


def build_bridge_argv(platform: str, cycle: str) -> tuple[str, ...]:
    if platform not in PLATFORMS or cycle not in CYCLES:
        raise InvalidArguments
    return (
        "ssh",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "LogLevel=ERROR",
        BRIDGE_SSH_HOST,
        "--",
        BRIDGE_RELEASE_HELPER,
        platform,
        cycle,
    )


def build_android_force_stop_argv(serial: str) -> tuple[str, ...]:
    source_contract.build_android_source_argv(serial)
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "shell",
        "am",
        "force-stop",
        ANDROID_PACKAGE,
    )


def build_android_start_argv(serial: str) -> tuple[str, ...]:
    source_contract.build_android_source_argv(serial)
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "shell",
        "am",
        "start",
        "-W",
        "-n",
        f"{ANDROID_PACKAGE}/{ANDROID_ACTIVITY}",
    )


def build_android_reconnect_runner_argv(serial: str) -> tuple[str, ...]:
    source_contract.build_android_source_argv(serial)
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "shell",
        "am",
        "instrument",
        "-w",
        "-r",
        "-e",
        "class",
        ANDROID_RECONNECT_TEST,
        ANDROID_TEST_RUNNER,
    )


def build_ios_reconnect_runner_argv(udid: str) -> tuple[str, ...]:
    source_contract.build_ios_source_argv(udid, 1)
    return (os.fspath(IOS_RECONNECT_RUNNER), udid)


class CompletionLatch:
    """Separate pipeline completion from final cohort acceptance."""

    _PIPELINE_VALUES = frozenset({"pending", "complete", "failed"})
    _COHORT_VALUES = frozenset({"pending", "matched", "mismatched", "failed"})

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._pipeline_event = threading.Event()
        self._pipeline = "pending"
        self._cohort = "pending"

    def mark_pipeline_complete(self) -> None:
        self._set_pipeline("complete")

    def mark_pipeline_failed(self) -> None:
        self._set_pipeline("failed")

    def _set_pipeline(self, value: str) -> None:
        if value not in self._PIPELINE_VALUES:
            raise ValueError("invalid pipeline state")
        with self._lock:
            if self._pipeline != "pending":
                raise CoordinatorFailure("internal_error")
            self._pipeline = value
            self._pipeline_event.set()

    def wait_pipeline(self, timeout: float) -> bool:
        if not self._pipeline_event.wait(timeout):
            return False
        with self._lock:
            return self._pipeline == "complete"

    def downstream_status(self) -> int | None:
        with self._lock:
            return 0 if self._pipeline == "complete" else None

    def mark_cohort(self, *, matched: bool | None) -> None:
        value = "failed" if matched is None else ("matched" if matched else "mismatched")
        with self._lock:
            if self._cohort != "pending":
                raise CoordinatorFailure("internal_error")
            self._cohort = value

    @property
    def pipeline_state(self) -> str:
        with self._lock:
            return self._pipeline

    @property
    def cohort_state(self) -> str:
        with self._lock:
            return self._cohort

    def __repr__(self) -> str:
        return (
            "CompletionLatch("
            f"pipeline={self.pipeline_state!r}, cohort={self.cohort_state!r}"
            ")"
        )


class TerminalGenerationVault:
    """The sole owner of raw terminal generations during a run."""

    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._ordered: list[str] = []
        self._seen: set[str] = set()
        self._sealed = False

    def add_terminal(self, generation: object) -> None:
        if not isinstance(generation, str) or _GENERATION_RE.fullmatch(generation) is None:
            raise CoordinatorFailure("pipeline_failed")
        try:
            collector_contract._generation_surrogate(generation, b"v" * 32)
        except collector_contract.RejectedRecord:
            raise CoordinatorFailure("pipeline_failed") from None

        with self._condition:
            if self._sealed or generation in self._seen:
                raise CoordinatorFailure("pipeline_failed")
            if len(self._ordered) >= TARGET_GENERATIONS:
                raise CoordinatorFailure("pipeline_failed")
            self._ordered.append(generation)
            self._seen.add(generation)
            self._condition.notify_all()

    def wait_for_count(self, count: int, timeout: float) -> bool:
        if type(count) is not int or count < 1 or count > TARGET_GENERATIONS:
            raise ValueError("invalid terminal count")
        deadline = time.monotonic() + timeout
        with self._condition:
            while len(self._ordered) < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not self._condition.wait(remaining):
                    return False
            return True

    @property
    def count(self) -> int:
        with self._condition:
            return len(self._ordered)

    def seal_payload(self) -> bytes:
        with self._condition:
            if self._sealed or len(self._ordered) != TARGET_GENERATIONS:
                raise CoordinatorFailure("pipeline_failed")
            payload = "".join(f"{value}\n" for value in self._ordered).encode("ascii")
            if len(payload) != GENERATION_PAYLOAD_BYTES:
                raise CoordinatorFailure("pipeline_failed")
            self._sealed = True
            return payload

    def aggregate_contains_generation(self, encoded: bytes) -> bool:
        with self._condition:
            return any(value.encode("ascii") in encoded for value in self._ordered)

    def clear(self) -> None:
        with self._condition:
            for index in range(len(self._ordered)):
                self._ordered[index] = ""
            self._ordered.clear()
            self._seen.clear()

    def __repr__(self) -> str:
        with self._condition:
            return (
                "TerminalGenerationVault("
                f"count={len(self._ordered)}, sealed={self._sealed}"
                ")"
            )


def _strict_object(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
    keys = [key for key, _value in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)


class FixedStatusSink:
    """Accept exactly one identity-free component status object."""

    def __init__(self, component_key: str) -> None:
        contracts = {
            "adapter": (
                stream_contract.ADAPTER_NAME,
                frozenset({"complete", "incomplete", "invalid"}),
            ),
            "supervisor": (
                source_contract.SUPERVISOR_NAME,
                source_contract.STATUS_VALUES,
            ),
        }
        if component_key not in contracts:
            raise ValueError("invalid status component")
        self._component_key = component_key
        self._component_name, self._allowed_statuses = contracts[component_key]
        self._status: str | None = None

    def write(self, payload: str) -> int:
        if self._status is not None or not isinstance(payload, str) or not payload.endswith("\n"):
            raise ValueError("invalid status")
        if _SECRET_RE.search(payload) or _GENERATION_SEARCH_RE.search(payload):
            raise ValueError("invalid status")
        try:
            parsed = json.loads(payload, object_pairs_hook=_strict_object)
        except (json.JSONDecodeError, TypeError, ValueError):
            raise ValueError("invalid status") from None
        if (
            not isinstance(parsed, dict)
            or parsed.get(self._component_key) != self._component_name
        ):
            raise ValueError("invalid status")
        status = parsed.get("status")
        if not isinstance(status, str) or status not in self._allowed_statuses:
            raise ValueError("invalid status")
        self._status = status
        return len(payload)

    def flush(self) -> None:
        return None

    @property
    def status(self) -> str | None:
        return self._status

    def __repr__(self) -> str:
        return f"FixedStatusSink(status={self._status!r})"


class NativeCollectorSink:
    """Forward adapter JSONL directly to the collector and terminal vault."""

    def __init__(
        self,
        collector: collector_contract.Collector,
        vault: TerminalGenerationVault,
    ) -> None:
        self._collector = collector
        self._vault = vault
        self._lines = 0

    def write(self, payload: str) -> int:
        if (
            not isinstance(payload, str)
            or len(payload.encode("utf-8")) > collector_contract.MAX_LINE_BYTES
            or payload.count("\n") != 1
            or not payload.endswith("\n")
        ):
            raise ValueError("invalid adapter record")
        try:
            parsed = json.loads(payload, object_pairs_hook=_strict_object)
        except (json.JSONDecodeError, TypeError, ValueError):
            raise ValueError("invalid adapter record") from None
        if not isinstance(parsed, dict) or set(parsed) != collector_contract.INPUT_FIELDS:
            raise ValueError("invalid adapter record")

        raw = payload.encode("utf-8")
        rejected_before = sum(self._collector.rejections.values())
        self._collector.add_line(raw)
        if sum(self._collector.rejections.values()) != rejected_before:
            raise ValueError("collector rejected adapter record")

        if parsed.get("stage") == "first_cards_render_ready":
            self._vault.add_terminal(parsed.get("connection_generation"))
        self._lines += 1
        return len(payload)

    def flush(self) -> None:
        return None

    @property
    def lines(self) -> int:
        return self._lines

    def __repr__(self) -> str:
        return f"NativeCollectorSink(lines={self._lines})"


class ProcessLike(Protocol):
    pid: int
    stdin: BinaryIO | None
    stdout: BinaryIO | None
    stderr: BinaryIO | None

    def poll(self) -> int | None: ...

    def wait(self, timeout: float | None = None) -> int: ...


def _safe_native_child_env() -> dict[str, str]:
    allowed = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR")
    environment = {key: os.environ[key] for key in allowed if key in os.environ}
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def _safe_bridge_child_env() -> dict[str, str]:
    environment = _safe_native_child_env()
    if "SSH_AUTH_SOCK" in os.environ:
        environment["SSH_AUTH_SOCK"] = os.environ["SSH_AUTH_SOCK"]
    return environment


def _terminate_process_group(
    process: ProcessLike,
    kill_process_group: Callable[[int, int], None] = os.killpg,
) -> str:
    if process.poll() is not None:
        return "not_needed"
    try:
        kill_process_group(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        pass
    try:
        process.wait(timeout=PROCESS_TERM_TIMEOUT_SECONDS)
        return "terminated"
    except subprocess.TimeoutExpired:
        pass
    try:
        kill_process_group(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass
    try:
        process.wait(timeout=PROCESS_KILL_TIMEOUT_SECONDS)
        return "killed"
    except subprocess.TimeoutExpired:
        return "failed"


class ScopedProcessRegistry:
    """Track only coordinator-spawned process groups for bounded cleanup."""

    def __init__(self, kill_process_group: Callable[[int, int], None] = os.killpg):
        self._lock = threading.Lock()
        self._processes: list[ProcessLike] = []
        self._kill_process_group = kill_process_group

    def add(self, process: ProcessLike) -> None:
        with self._lock:
            self._processes.append(process)

    def terminate_all(self) -> bool:
        with self._lock:
            processes = list(self._processes)
        successful = True
        for process in processes:
            if (
                _terminate_process_group(process, self._kill_process_group)
                == "failed"
            ):
                successful = False
        return successful

    def __repr__(self) -> str:
        with self._lock:
            active = sum(process.poll() is None for process in self._processes)
        return f"ScopedProcessRegistry(active={active})"


class TrackingProcessFactory:
    def __init__(
        self,
        registry: ScopedProcessRegistry,
        *,
        process_factory: Callable[..., ProcessLike] = subprocess.Popen,
        on_spawn: Callable[[tuple[str, ...]], None] | None = None,
    ) -> None:
        self._registry = registry
        self._process_factory = process_factory
        self._on_spawn = on_spawn

    def __call__(self, argv: Sequence[str], **kwargs: object) -> ProcessLike:
        if kwargs.get("shell") is not False or kwargs.get("start_new_session") is not True:
            raise CoordinatorFailure("internal_error")
        process = self._process_factory(list(argv), **kwargs)
        self._registry.add(process)
        if self._on_spawn is not None:
            self._on_spawn(tuple(argv))
        return process


class BoundedCommandRunner:
    def __init__(self, process_factory: Callable[..., ProcessLike]):
        self._process_factory = process_factory

    def run(self, argv: tuple[str, ...], timeout: float) -> None:
        process = self._process_factory(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            shell=False,
            close_fds=True,
            start_new_session=True,
            env=_safe_native_child_env(),
        )
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _terminate_process_group(process)
            raise CoordinatorFailure("source_failed") from None
        if returncode != 0:
            raise CoordinatorFailure("source_failed")


class IOSReadyLineReader:
    """Signal only after the exact source-supervisor connected frame is read."""

    def __init__(self, stream: BinaryIO, udid: str, ready: threading.Event):
        self._reader = source_contract.SelectorLineReader(stream)
        self._expected = f"[connected:{udid}]\n".encode("ascii")
        self._ready = ready
        self._first = True

    def readline(self, timeout: float | None = None) -> bytes:
        line = self._reader.readline(timeout)
        if self._first:
            self._first = False
            if line == self._expected:
                self._ready.set()
        return line

    def close(self) -> None:
        self._reader.close()


class SourceDriver(Protocol):
    def run(
        self,
        output: BinaryIO,
        latch: CompletionLatch,
        vault: TerminalGenerationVault,
        registry: ScopedProcessRegistry,
    ) -> bool: ...


class PhysicalSourceDriver:
    """Run only the exact app-scoped lifecycle for one explicit device."""

    def __init__(
        self,
        config: CohortConfig,
        *,
        process_factory: Callable[..., ProcessLike] = subprocess.Popen,
        supervisor_factory: Callable[..., source_contract.SourceSupervisor] = (
            source_contract.SourceSupervisor
        ),
        json_runner_factory: Callable[..., source_contract.BoundedSubprocessJSONRunner] = (
            source_contract.BoundedSubprocessJSONRunner
        ),
    ) -> None:
        self._config = config
        self._process_factory = process_factory
        self._supervisor_factory = supervisor_factory
        self._json_runner_factory = json_runner_factory

    def run(
        self,
        output: BinaryIO,
        latch: CompletionLatch,
        vault: TerminalGenerationVault,
        registry: ScopedProcessRegistry,
    ) -> bool:
        try:
            if self._config.platform == "ios" and self._config.cycle == "cold":
                return self._run_ios_cold(output, registry)
            return self._run_continuous(output, latch, vault, registry)
        except CoordinatorFailure:
            return False
        except Exception:
            return False

    def _run_ios_cold(
        self, output: BinaryIO, registry: ScopedProcessRegistry
    ) -> bool:
        factory = TrackingProcessFactory(
            registry, process_factory=self._process_factory
        )
        lifecycle_runner = self._json_runner_factory(
            process_factory=factory
        )
        plan = source_contract.build_plan(
            "ios", self._config.device, ios_suspended_launch=True
        )

        for _index in range(TARGET_GENERATIONS):
            status = FixedStatusSink("supervisor")
            supervisor = self._supervisor_factory(
                process_factory=factory,
                command_runner=lifecycle_runner,
            )
            result = supervisor.run(plan, output, status)
            if result != 0 or status.status != "ios_cold_generation_complete":
                return False
        return True

    def _run_continuous(
        self,
        output: BinaryIO,
        latch: CompletionLatch,
        vault: TerminalGenerationVault,
        registry: ScopedProcessRegistry,
    ) -> bool:
        source_ready = threading.Event()
        expected_android_source = (
            source_contract.build_android_source_argv(self._config.device)
            if self._config.platform == "android"
            else None
        )

        def on_spawn(argv: tuple[str, ...]) -> None:
            if expected_android_source is not None and argv == expected_android_source:
                source_ready.set()

        factory = TrackingProcessFactory(
            registry,
            process_factory=self._process_factory,
            on_spawn=on_spawn,
        )
        if self._config.platform == "android":
            plan = source_contract.build_plan("android", self._config.device)
            line_reader_factory = source_contract.SelectorLineReader
        else:
            if self._config.ios_pid is None:
                return False
            plan = source_contract.build_plan(
                "ios", self._config.device, ios_pid=self._config.ios_pid
            )
            line_reader_factory = lambda stream: IOSReadyLineReader(
                stream, self._config.device, source_ready
            )

        status = FixedStatusSink("supervisor")
        result: dict[str, object] = {"exit": None}

        def supervise() -> None:
            try:
                supervisor = self._supervisor_factory(
                    process_factory=factory,
                    line_reader_factory=line_reader_factory,
                    downstream_status=latch.downstream_status,
                )
                result["exit"] = supervisor.run(plan, output, status)
            except Exception:
                result["exit"] = 70

        source_thread = threading.Thread(
            target=supervise,
            name="casein-mobile-timing-source",
            daemon=True,
        )
        source_thread.start()

        if not source_ready.wait(SOURCE_READY_TIMEOUT_SECONDS):
            registry.terminate_all()
            source_thread.join(SOURCE_JOIN_TIMEOUT_SECONDS)
            return False

        command_runner = BoundedCommandRunner(factory)
        try:
            if self._config.platform == "android" and self._config.cycle == "cold":
                self._run_android_cold(command_runner, vault)
            elif self._config.platform == "android":
                command_runner.run(
                    build_android_reconnect_runner_argv(self._config.device),
                    ANDROID_RECONNECT_TIMEOUT_SECONDS,
                )
            else:
                command_runner.run(
                    build_ios_reconnect_runner_argv(self._config.device),
                    IOS_RECONNECT_TIMEOUT_SECONDS,
                )

            if not latch.wait_pipeline(PIPELINE_TIMEOUT_SECONDS):
                raise CoordinatorFailure("source_failed")
        except CoordinatorFailure:
            registry.terminate_all()
            source_thread.join(SOURCE_JOIN_TIMEOUT_SECONDS)
            return False

        source_thread.join(SOURCE_JOIN_TIMEOUT_SECONDS)
        if source_thread.is_alive():
            registry.terminate_all()
            source_thread.join(SOURCE_JOIN_TIMEOUT_SECONDS)

        return (
            not source_thread.is_alive()
            and result["exit"] == 0
            and status.status == "downstream_complete"
        )

    def _run_android_cold(
        self,
        command_runner: BoundedCommandRunner,
        vault: TerminalGenerationVault,
    ) -> None:
        for index in range(1, TARGET_GENERATIONS + 1):
            command_runner.run(
                build_android_force_stop_argv(self._config.device),
                ANDROID_COMMAND_TIMEOUT_SECONDS,
            )
            command_runner.run(
                build_android_start_argv(self._config.device),
                ANDROID_COMMAND_TIMEOUT_SECONDS,
            )
            if not vault.wait_for_count(index, ANDROID_COMMAND_TIMEOUT_SECONDS):
                raise CoordinatorFailure("source_failed")


class BridgeSession:
    """One fixed READY/finalize exchange with no retryable finish state."""

    def __init__(
        self,
        platform: str,
        cycle: str,
        *,
        process_factory: Callable[..., ProcessLike] = subprocess.Popen,
        selector_factory: Callable[[], selectors.BaseSelector] = selectors.DefaultSelector,
        read_fn: Callable[[int, int], bytes] = os.read,
        kill_process_group: Callable[[int, int], None] = os.killpg,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._argv = build_bridge_argv(platform, cycle)
        self._process_factory = process_factory
        self._selector_factory = selector_factory
        self._read_fn = read_fn
        self._kill_process_group = kill_process_group
        self._monotonic = monotonic
        self._process: ProcessLike | None = None
        self._ready = False
        self._finish_attempted = False
        self._stdin_closed = False

    def open(self) -> None:
        if self._process is not None:
            raise CoordinatorFailure("internal_error")
        process = self._process_factory(
            list(self._argv),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
            close_fds=True,
            start_new_session=True,
            bufsize=0,
            env=_safe_bridge_child_env(),
        )
        self._process = process
        if process.stdin is None or process.stdout is None or process.stderr is None:
            self.abort()
            raise CoordinatorFailure("bridge_not_ready")
        if not self._wait_ready(process):
            self.abort()
            raise CoordinatorFailure("bridge_not_ready")
        self._ready = True

    def assert_waiting(self) -> None:
        process = self._process
        if not self._ready or self._finish_attempted or process is None:
            raise CoordinatorFailure("bridge_not_ready")
        if process.poll() is not None or process.stdout is None or process.stderr is None:
            raise CoordinatorFailure("bridge_not_ready")

        selector = self._selector_factory()
        selector.register(process.stdout, selectors.EVENT_READ)
        selector.register(process.stderr, selectors.EVENT_READ)
        try:
            # Any readable protocol descriptor before the one-shot send is
            # stale output, an early failure, or EOF. None is safe to consume.
            if selector.select(0):
                raise CoordinatorFailure("bridge_not_ready")
        finally:
            selector.close()

    def _wait_ready(self, process: ProcessLike) -> bool:
        stdout = process.stdout
        stderr = process.stderr
        if stdout is None or stderr is None:
            return False
        selector = self._selector_factory()
        selector.register(stdout, selectors.EVENT_READ, "stdout")
        selector.register(stderr, selectors.EVENT_READ, "stderr")
        deadline = self._monotonic() + BRIDGE_READY_TIMEOUT_SECONDS
        ready_buffer = bytearray()
        try:
            while self._monotonic() < deadline:
                events = selector.select(max(0.0, deadline - self._monotonic()))
                if not events:
                    return False
                for key, _mask in events:
                    try:
                        chunk = self._read_fn(key.fileobj.fileno(), 1024)
                    except (OSError, ValueError):
                        return False
                    if key.data == "stdout":
                        if chunk:
                            return False
                        return False
                    if not chunk:
                        return False
                    ready_buffer.extend(chunk)
                    if len(ready_buffer) > len(BRIDGE_READY):
                        ready_buffer.clear()
                        return False
                    if b"\n" in ready_buffer:
                        valid = bytes(ready_buffer) == BRIDGE_READY
                        ready_buffer.clear()
                        return valid
            return False
        finally:
            ready_buffer.clear()
            selector.close()

    def finish(self, payload: bytes) -> Mapping[str, object]:
        if (
            not self._ready
            or self._finish_attempted
            or not _generation_payload_valid(payload)
        ):
            raise CoordinatorFailure("bridge_finish_ambiguous")
        process = self._process
        if process is None or process.stdin is None:
            raise CoordinatorFailure("bridge_finish_ambiguous")
        self._finish_attempted = True

        try:
            written = process.stdin.write(payload)
            if written != len(payload):
                raise OSError("partial bridge write")
            process.stdin.flush()
            process.stdin.close()
            self._stdin_closed = True
        except (BrokenPipeError, OSError, ValueError):
            self._close_stdin()
            self._terminate()
            raise CoordinatorFailure("bridge_finish_ambiguous") from None

        aggregate_line = self._read_finish(process)
        if aggregate_line is None:
            self._terminate()
            raise CoordinatorFailure("bridge_finish_ambiguous")
        try:
            parsed = json.loads(
                aggregate_line,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
                object_pairs_hook=_strict_object,
            )
        except (json.JSONDecodeError, RecursionError, TypeError, ValueError):
            raise CoordinatorFailure("server_aggregate_invalid") from None
        finally:
            aggregate_line = b""
        if not isinstance(parsed, dict):
            raise CoordinatorFailure("server_aggregate_invalid")
        return parsed

    def _read_finish(self, process: ProcessLike) -> bytes | None:
        stdout = process.stdout
        stderr = process.stderr
        if stdout is None or stderr is None:
            return None
        selector = self._selector_factory()
        selector.register(stdout, selectors.EVENT_READ, "stdout")
        selector.register(stderr, selectors.EVENT_READ, "stderr")
        deadline = self._monotonic() + BRIDGE_FINISH_TIMEOUT_SECONDS
        aggregate = bytearray()
        stderr_seen = False
        stdout_eof = False
        stderr_eof = False
        try:
            while self._monotonic() < deadline and not (stdout_eof and stderr_eof):
                events = selector.select(max(0.0, deadline - self._monotonic()))
                if not events:
                    break
                for key, _mask in events:
                    try:
                        chunk = self._read_fn(key.fileobj.fileno(), 4096)
                    except (OSError, ValueError):
                        return None
                    if key.data == "stdout":
                        if not chunk:
                            stdout_eof = True
                            selector.unregister(key.fileobj)
                        else:
                            aggregate.extend(chunk)
                            if len(aggregate) > MAX_BRIDGE_AGGREGATE_WIRE_BYTES:
                                aggregate.clear()
                                return None
                    else:
                        if not chunk:
                            stderr_eof = True
                            selector.unregister(key.fileobj)
                        else:
                            stderr_seen = True

            try:
                returncode = process.wait(timeout=max(0.0, deadline - self._monotonic()))
            except subprocess.TimeoutExpired:
                return None
            if returncode != 0 or stderr_seen:
                return None
            if aggregate.count(b"\n") != 1 or not aggregate.endswith(b"\n"):
                return None
            return bytes(aggregate[:-1])
        finally:
            aggregate.clear()
            selector.close()
            self._close_pipes()

    def abort(self) -> None:
        process = self._process
        if process is None:
            return
        self._close_stdin()
        try:
            process.wait(timeout=BRIDGE_ABORT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            self._terminate()
        self._close_pipes()

    def _close_stdin(self) -> None:
        process = self._process
        if self._stdin_closed or process is None or process.stdin is None:
            return
        try:
            process.stdin.close()
        except (OSError, ValueError):
            pass
        self._stdin_closed = True

    def _close_pipes(self) -> None:
        process = self._process
        if process is None:
            return
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except (OSError, ValueError):
                    pass

    def _terminate(self) -> None:
        process = self._process
        if process is not None:
            _terminate_process_group(process, self._kill_process_group)

    def __repr__(self) -> str:
        state = "new"
        if self._finish_attempted:
            state = "finish_attempted"
        elif self._ready:
            state = "ready"
        elif self._process is not None:
            state = "started"
        return f"BridgeSession(state={state!r})"


class BridgeLike(Protocol):
    def open(self) -> None: ...

    def assert_waiting(self) -> None: ...

    def finish(self, payload: bytes) -> Mapping[str, object]: ...

    def abort(self) -> None: ...


def _close_stream(stream: object | None) -> None:
    if stream is None:
        return
    try:
        stream.close()
    except BaseException:
        pass


def _close_fd(descriptor: int | None) -> None:
    if descriptor is None:
        return
    try:
        os.close(descriptor)
    except BaseException:
        pass


def _abort_bridge(bridge: BridgeLike) -> None:
    try:
        bridge.abort()
    except BaseException:
        pass


def _bounded_count(value: object) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, int)
        and 0 <= value <= MAX_AGGREGATE_RECORDS
    )


def _bounded_number(value: object, maximum: int) -> bool:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or value < 0
        or value > maximum
    ):
        return False
    return not isinstance(value, float) or math.isfinite(value)


def _generation_payload_valid(payload: object) -> bool:
    if not isinstance(payload, bytes) or len(payload) != GENERATION_PAYLOAD_BYTES:
        return False
    if b"\r" in payload or b"\0" in payload or not payload.endswith(b"\n"):
        return False
    try:
        text = payload.decode("ascii", "strict")
    except UnicodeDecodeError:
        return False
    parts = text.split("\n")
    generations = parts[:-1]
    return (
        parts[-1] == ""
        and len(generations) == TARGET_GENERATIONS
        and len(set(generations)) == TARGET_GENERATIONS
        and all(_GENERATION_RE.fullmatch(value) for value in generations)
    )


def _contains_generation_value(value: object) -> bool:
    if isinstance(value, str):
        return _GENERATION_SEARCH_RE.search(value) is not None
    if isinstance(value, dict):
        return any(_contains_generation_value(item) for item in value.values())
    if isinstance(value, (list, tuple)):
        return any(_contains_generation_value(item) for item in value)
    return False


def _summary_valid(
    value: object,
    sample_count: int,
    validator: Callable[[object], bool],
) -> bool:
    if not isinstance(value, dict) or set(value) != SUMMARY_KEYS:
        return False
    if sample_count == 0:
        return all(value[key] is None for key in SUMMARY_KEYS)
    if sample_count < 0:
        return False

    minimum = value["min"]
    p50 = value["p50"]
    p95 = value["p95"]
    maximum = value["max"]
    if not validator(minimum) or not validator(p50) or not validator(maximum):
        return False
    if sample_count < 10:
        if p95 is not None:
            return False
        return minimum <= p50 <= maximum
    return validator(p95) and minimum <= p50 <= p95 <= maximum


def _bounded_count_sum(values: Sequence[int]) -> int | None:
    total = 0
    for value in values:
        if not _bounded_count(value) or total + value > MAX_AGGREGATE_RECORDS:
            return None
        total += value
    return total


def validate_server_aggregate(
    value: object, platform: str, cycle: str
) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != SERVER_KEYS:
        raise CoordinatorFailure("server_aggregate_invalid")
    if (
        value.get("schema_version") != 1
        or value.get("component") != "server"
        or value.get("platform") != platform
        or value.get("cycle") != cycle
        or value.get("expected_generation_count") != TARGET_GENERATIONS
        or not _bounded_count(value.get("observed_generation_count"))
        or not isinstance(value.get("cohort_match"), bool)
        or (
            value.get("cohort_match") is True
            and value.get("observed_generation_count") != TARGET_GENERATIONS
        )
    ):
        raise CoordinatorFailure("server_aggregate_invalid")

    stage_timings = value.get("stage_timings")
    if not isinstance(stage_timings, dict) or set(stage_timings) != set(SERVER_STAGES):
        raise CoordinatorFailure("server_aggregate_invalid")
    stage_counts: list[int] = []
    for timing in stage_timings.values():
        if (
            not isinstance(timing, dict)
            or set(timing) != {"sample_count", "duration_ms", "elapsed_ms"}
            or not _bounded_count(timing["sample_count"])
            or not _summary_valid(
                timing["duration_ms"],
                timing["sample_count"],
                lambda item: _bounded_number(item, MAX_DURATION_MS),
            )
            or not _summary_valid(
                timing["elapsed_ms"],
                timing["sample_count"],
                lambda item: _bounded_number(item, MAX_DURATION_MS),
            )
        ):
            raise CoordinatorFailure("server_aggregate_invalid")
        stage_counts.append(timing["sample_count"])

    fixed_totals: list[int] = []
    for key, expected in (
        ("outcome_counts", SERVER_OUTCOMES),
        ("reason_counts", SERVER_REASONS),
    ):
        counts = value.get(key)
        if not isinstance(counts, dict) or set(counts) != set(expected):
            raise CoordinatorFailure("server_aggregate_invalid")
        total = _bounded_count_sum(list(counts.values()))
        if total is None:
            raise CoordinatorFailure("server_aggregate_invalid")
        fixed_totals.append(total)

    optional = value.get("optional_measurements")
    if not isinstance(optional, dict) or not set(optional).issubset(
        SERVER_OPTIONAL_MEASUREMENTS
    ):
        raise CoordinatorFailure("server_aggregate_invalid")
    optional_counts: list[int] = []
    for name, measurement in optional.items():
        maximum = (
            MAX_CARD_COUNT if name == "card_count" else MAX_SNAPSHOT_JSON_BYTES
        )
        if (
            not isinstance(measurement, dict)
            or set(measurement) != SUMMARY_KEYS | {"sample_count"}
            or not _bounded_count(measurement["sample_count"])
            or measurement["sample_count"] == 0
            or not _summary_valid(
                {key: measurement[key] for key in SUMMARY_KEYS},
                measurement["sample_count"],
                lambda item, maximum=maximum: (
                    not isinstance(item, bool)
                    and isinstance(item, int)
                    and 0 <= item <= maximum
                ),
            )
        ):
            raise CoordinatorFailure("server_aggregate_invalid")
        optional_counts.append(measurement["sample_count"])

    stage_total = _bounded_count_sum(stage_counts)
    if (
        stage_total is None
        or fixed_totals != [stage_total, stage_total]
        or any(count > stage_total for count in optional_counts)
        or (stage_total > 0 and value["observed_generation_count"] == 0)
        or (value["cohort_match"] and stage_total < TARGET_GENERATIONS)
    ):
        raise CoordinatorFailure("server_aggregate_invalid")

    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if (
        len(encoded.encode("utf-8")) > MAX_BRIDGE_AGGREGATE_BYTES
        or _SECRET_RE.search(encoded)
        or _contains_generation_value(value)
    ):
        raise CoordinatorFailure("server_aggregate_invalid")
    return value


def validate_native_aggregate(
    value: object, platform: str, cycle: str
) -> dict[str, object]:
    if not isinstance(value, dict):
        raise CoordinatorFailure("pipeline_failed")
    if (
        value.get("schema_version") != collector_contract.SCHEMA_VERSION
        or value.get("collector") != "casein_mobile_feed_timing"
        or value.get("platform") != platform
        or value.get("cycle") != cycle
        or value.get("status") != "complete"
        or value.get("target_complete_generations") != TARGET_GENERATIONS
        or value.get("complete_generations") != TARGET_GENERATIONS
        or value.get("observed_generations") != TARGET_GENERATIONS
    ):
        raise CoordinatorFailure("pipeline_failed")
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if _SECRET_RE.search(encoded) or _contains_generation_value(value):
        raise CoordinatorFailure("pipeline_failed")
    return value


class AtomicAggregatePublisher:
    """Atomically reveal one new private directory containing two aggregates."""

    def preflight(self, output_root: Path) -> None:
        descriptor = self._open_root(output_root)
        try:
            if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
                raise CoordinatorFailure("publication_failed")
        finally:
            _close_fd(descriptor)

    def publish(
        self,
        output_root: Path,
        native: Mapping[str, object],
        server: Mapping[str, object],
        vault: TerminalGenerationVault,
    ) -> None:
        token = secrets.token_hex(12)
        staging = f".casein-mobile-feed-timing-{token}.tmp"
        final = f"casein-mobile-feed-timing-{token}"
        root_fd = self._open_root(output_root)
        staging_fd: int | None = None
        created = False
        revealed = False
        try:
            os.mkdir(staging, 0o700, dir_fd=root_fd)
            created = True
            staging_fd = os.open(
                staging,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=root_fd,
            )
            os.fchmod(staging_fd, 0o700)
            self._write_one(staging_fd, "native.json", native, vault)
            self._write_one(staging_fd, "server.json", server, vault)
            os.fsync(staging_fd)
            os.replace(
                staging,
                final,
                src_dir_fd=root_fd,
                dst_dir_fd=root_fd,
            )
            created = False
            revealed = True
            try:
                self._fsync_root(root_fd)
            except OSError:
                if self._retire_revealed(
                    root_fd, staging_fd, final, staging
                ):
                    revealed = False
                    raise CoordinatorFailure("publication_failed") from None
                # The private aggregate is already atomically visible. If an
                # adversarial filesystem refuses both the durability sync and
                # rollback, reporting published=false would be untrue.
        except KeyboardInterrupt:
            if created:
                self._remove_private_directory(root_fd, staging_fd, staging)
            if revealed:
                if not self._retire_revealed(
                    root_fd, staging_fd, final, staging
                ):
                    return
            raise
        except Exception:
            if created:
                self._remove_private_directory(root_fd, staging_fd, staging)
            if revealed:
                if not self._retire_revealed(
                    root_fd, staging_fd, final, staging
                ):
                    return
            raise CoordinatorFailure("publication_failed") from None
        finally:
            if staging_fd is not None:
                try:
                    os.close(staging_fd)
                except OSError:
                    pass
            try:
                os.close(root_fd)
            except OSError:
                pass

    def _write_one(
        self,
        directory_fd: int,
        name: str,
        payload: Mapping[str, object],
        vault: TerminalGenerationVault,
    ) -> None:
        encoded = (
            json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        if vault.aggregate_contains_generation(encoded) or _SECRET_RE.search(
            encoded.decode("utf-8")
        ):
            raise CoordinatorFailure("publication_failed")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
        try:
            os.fchmod(descriptor, 0o600)
            view = memoryview(encoded)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise OSError("aggregate write failed")
                view = view[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def _open_root(self, output_root: Path) -> int:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        flags |= getattr(os, "O_CLOEXEC", 0)
        try:
            descriptor = os.open(output_root, flags)
            if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
                os.close(descriptor)
                raise OSError("aggregate root is not a directory")
            return descriptor
        except OSError:
            raise CoordinatorFailure("publication_failed") from None

    def _fsync_root(self, root_fd: int) -> None:
        os.fsync(root_fd)

    def _remove_private_directory(
        self,
        root_fd: int,
        directory_fd: int | None,
        name: str,
    ) -> bool:
        cleanup_fd = directory_fd
        opened_for_cleanup = False
        try:
            if cleanup_fd is None:
                cleanup_fd = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=root_fd,
                )
                opened_for_cleanup = True
            for filename in ("native.json", "server.json"):
                try:
                    os.unlink(filename, dir_fd=cleanup_fd)
                except FileNotFoundError:
                    pass
            os.rmdir(name, dir_fd=root_fd)
            try:
                os.fsync(root_fd)
            except OSError:
                pass
            return True
        except OSError:
            return False
        finally:
            if opened_for_cleanup and cleanup_fd is not None:
                try:
                    os.close(cleanup_fd)
                except OSError:
                    pass

    def _retire_revealed(
        self,
        root_fd: int,
        directory_fd: int,
        final_name: str,
        retired_name: str,
    ) -> bool:
        try:
            os.replace(
                final_name,
                retired_name,
                src_dir_fd=root_fd,
                dst_dir_fd=root_fd,
            )
        except OSError:
            return False
        self._remove_private_directory(root_fd, directory_fd, retired_name)
        return True


class CohortCoordinator:
    def __init__(
        self,
        *,
        bridge_factory: Callable[[CohortConfig], BridgeLike] | None = None,
        source_factory: Callable[[CohortConfig], SourceDriver] | None = None,
        publisher: AtomicAggregatePublisher | None = None,
    ) -> None:
        self._bridge_factory = bridge_factory or (
            lambda config: BridgeSession(config.platform, config.cycle)
        )
        self._source_factory = source_factory or PhysicalSourceDriver
        self._publisher = publisher or AtomicAggregatePublisher()

    def run(self, config: CohortConfig) -> RunOutcome:
        try:
            disable_process_artifacts()
        except KeyboardInterrupt:
            return _outcome("interrupted", False)
        except CoordinatorFailure:
            return _outcome("internal_error", False)

        latch = CompletionLatch()
        vault = TerminalGenerationVault()
        registry = ScopedProcessRegistry()
        bridge: BridgeLike | None = None
        reader: BinaryIO | None = None
        writer: BinaryIO | None = None
        source_thread: threading.Thread | None = None
        finish_attempted = False
        finish_completed = False
        generation_payload = b""

        try:
            try:
                self._publisher.preflight(config.output_root)
            except Exception:
                raise CoordinatorFailure("publication_failed") from None

            try:
                bridge = self._bridge_factory(config)
                bridge.open()
                bridge.assert_waiting()
            except Exception:
                raise CoordinatorFailure("bridge_not_ready") from None

            read_fd: int | None = None
            write_fd: int | None = None
            try:
                read_fd, write_fd = os.pipe()
                reader = os.fdopen(read_fd, "rb", buffering=0)
                read_fd = None
                writer = os.fdopen(write_fd, "wb", buffering=0)
                write_fd = None
                source_driver = self._source_factory(config)
            except Exception:
                _close_fd(read_fd)
                _close_fd(write_fd)
                raise CoordinatorFailure("pipeline_failed") from None

            source_result: dict[str, bool | None] = {"success": None}

            def run_source() -> None:
                try:
                    source_result["success"] = source_driver.run(
                        writer, latch, vault, registry
                    )
                except Exception:
                    source_result["success"] = False
                finally:
                    _close_stream(writer)

            source_thread = threading.Thread(
                target=run_source,
                name="casein-mobile-timing-lifecycle",
                daemon=True,
            )
            try:
                source_thread.start()
            except Exception:
                raise CoordinatorFailure("pipeline_failed") from None

            try:
                collector = collector_contract.Collector(
                    config.platform, config.cycle
                )
                sink = NativeCollectorSink(collector, vault)
                adapter_status = FixedStatusSink("adapter")
                adapter = stream_contract.StreamAdapter(
                    config.platform, config.cycle
                )
                adapter_exit = adapter.run(reader, sink, adapter_status)
                native = validate_native_aggregate(
                    collector.report(), config.platform, config.cycle
                )
                if (
                    adapter_exit != 0
                    or adapter_status.status != "complete"
                    or vault.count != TARGET_GENERATIONS
                ):
                    raise CoordinatorFailure("pipeline_failed")
                latch.mark_pipeline_complete()
            except Exception:
                if latch.pipeline_state == "pending":
                    latch.mark_pipeline_failed()
                raise CoordinatorFailure("pipeline_failed")
            finally:
                _close_stream(reader)

            source_thread.join(SOURCE_JOIN_TIMEOUT_SECONDS)
            if source_thread.is_alive():
                registry.terminate_all()
                _close_stream(writer)
                source_thread.join(SOURCE_JOIN_TIMEOUT_SECONDS)

            if (
                latch.pipeline_state != "complete"
                or source_thread.is_alive()
                or source_result["success"] is not True
            ):
                raise CoordinatorFailure("source_failed")

            try:
                bridge.assert_waiting()
            except Exception:
                raise CoordinatorFailure("bridge_not_ready") from None
            generation_payload = vault.seal_payload()
            finish_attempted = True
            server_raw = bridge.finish(generation_payload)
            finish_completed = True
            generation_payload = b""
            server = validate_server_aggregate(
                server_raw, config.platform, config.cycle
            )
            matched = bool(server["cohort_match"])
            latch.mark_cohort(matched=matched)
            self._publisher.publish(config.output_root, native, server, vault)
            return _outcome("complete" if matched else "cohort_mismatch", True)
        except KeyboardInterrupt:
            if latch.cohort_state == "pending" and finish_attempted:
                latch.mark_cohort(matched=None)
            return _outcome("interrupted", False)
        except CoordinatorFailure as failure:
            if latch.cohort_state == "pending" and finish_attempted:
                latch.mark_cohort(matched=None)
            return _outcome(failure.status, False)
        except Exception:
            if latch.cohort_state == "pending" and finish_attempted:
                latch.mark_cohort(matched=None)
            status = (
                "bridge_finish_ambiguous"
                if finish_attempted and not finish_completed
                else "internal_error"
            )
            return _outcome(status, False)
        finally:
            try:
                registry.terminate_all()
            except BaseException:
                pass
            _close_stream(reader)
            _close_stream(writer)
            if source_thread is not None and source_thread.is_alive():
                try:
                    source_thread.join(SOURCE_JOIN_TIMEOUT_SECONDS)
                except BaseException:
                    pass
            if bridge is not None and not finish_completed:
                _abort_bridge(bridge)
            generation_payload = b""
            try:
                vault.clear()
            except BaseException:
                pass

    def __repr__(self) -> str:
        return "CohortCoordinator(bridge=<factory>, source=<factory>, publisher=<private>)"


def _outcome(status: str, published: bool) -> RunOutcome:
    safe_status = status if status in STATUS_VALUES else "internal_error"
    return RunOutcome(safe_status, EXIT_CODES[safe_status], published)


def disable_process_artifacts() -> None:
    sys.dont_write_bytecode = True
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except (OSError, ValueError):
        raise CoordinatorFailure("internal_error") from None


def _parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(add_help=False)
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    parser.add_argument("--cycle", required=True, choices=CYCLES)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--ios-pid", type=int)
    return parser


def _fixed_status(output: TextIO, status: str) -> None:
    safe_status = status if status in STATUS_VALUES else "internal_error"
    payload = {"coordinator": COORDINATOR_NAME, "status": safe_status}
    try:
        output.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
        output.flush()
    except (BrokenPipeError, OSError, ValueError):
        return


def _interrupt_on_sigterm(signum: int, _frame: object) -> None:
    try:
        signal.signal(signum, signal.SIG_IGN)
    except (OSError, ValueError):
        pass
    raise KeyboardInterrupt


def main(argv: Sequence[str] | None = None) -> int:
    try:
        disable_process_artifacts()
        args = _parser().parse_args(argv)
        config = CohortConfig(
            platform=args.platform,
            cycle=args.cycle,
            device=args.device,
            output_root=args.output_root,
            ios_pid=args.ios_pid,
        )
    except (CoordinatorFailure, InvalidArguments, ValueError, TypeError):
        _fixed_status(sys.stderr, "invalid_arguments")
        return EXIT_CODES["invalid_arguments"]

    previous_sigterm: object | None = None
    sigterm_installed = False
    try:
        if threading.current_thread() is threading.main_thread():
            previous_sigterm = signal.getsignal(signal.SIGTERM)
            signal.signal(signal.SIGTERM, _interrupt_on_sigterm)
            sigterm_installed = True
        outcome = CohortCoordinator().run(config)
    except KeyboardInterrupt:
        outcome = _outcome("interrupted", False)
    except Exception:
        outcome = _outcome("internal_error", False)
    finally:
        if sigterm_installed and previous_sigterm is not None:
            try:
                signal.signal(signal.SIGTERM, previous_sigterm)
            except (OSError, ValueError):
                pass
    _fixed_status(sys.stderr, outcome.status)
    return outcome.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
