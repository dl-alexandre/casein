#!/usr/bin/env python3

from __future__ import annotations

import base64
import errno
import importlib.util
import io
import json
import os
import selectors
import signal
import stat
import subprocess
import sys
import unittest
from collections import deque
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE_SCRIPT = ROOT / "scripts/lib/mobile_feed_timing_source_supervisor.py"

SOURCE_SPEC = importlib.util.spec_from_file_location(
    "mobile_feed_timing_source_supervisor", SOURCE_SCRIPT
)
assert SOURCE_SPEC and SOURCE_SPEC.loader
source_module = importlib.util.module_from_spec(SOURCE_SPEC)
sys.modules[SOURCE_SPEC.name] = source_module
SOURCE_SPEC.loader.exec_module(source_module)


ANDROID_SERIAL = "R52M1234.ADB-1:5555"
IOS_UDID = "00008101-001234560123001E"
PID = 4242
SECRET = "password=must-never-appear"


def marker_line(
    *,
    prefix: bytes = b"",
    generation: str = "A" * 22,
    stage: str = "connect_requested",
    cycle: str = "cold",
    outcome: str | None = None,
    reason_code: str = "none",
    duration: int = 1,
    elapsed: int = 1,
) -> bytes:
    if outcome is None:
        outcome = (
            "started"
            if stage in {"connect_requested", "tcp_connect_started"}
            else "succeeded"
        )
    return (
        prefix
        + b"mobile_feed_stage "
        + f"connection_generation={generation} ".encode()
        + f"cycle={cycle} stage={stage} duration_ms={duration} elapsed_ms={elapsed} ".encode()
        + f"outcome={outcome} reason_code={reason_code}\n".encode()
    )


def generation(index: int) -> str:
    return base64.urlsafe_b64encode(index.to_bytes(16, "big")).rstrip(b"=").decode()


def devicectl_success(pid: object | None = None) -> dict[str, object]:
    result: dict[str, object] = {}
    if pid is not None:
        result["processIdentifier"] = pid
    return {"info": {"outcome": "success"}, "result": result}


class FakeReader:
    def __init__(self, events: list[bytes | BaseException]):
        self.events = deque(events)
        self.timeouts: list[float | None] = []
        self.closed = False

    def readline(self, timeout: float | None = None) -> bytes:
        self.timeouts.append(timeout)
        if not self.events:
            return b""
        event = self.events.popleft()
        if isinstance(event, BaseException):
            raise event
        return event

    def close(self) -> None:
        self.closed = True


class FakeProcess:
    def __init__(
        self,
        *,
        pid: int = 700,
        wait_outcomes: list[int | Exception] | None = None,
        poll_outcomes: list[int | None] | None = None,
        stdout: object | None = None,
    ):
        self.pid = pid
        self.stdout = stdout if stdout is not None else io.BytesIO()
        self._wait_outcomes = deque(wait_outcomes or [0])
        self._poll_outcomes = (
            deque(poll_outcomes) if poll_outcomes is not None else None
        )
        self._returncode: int | None = None
        self.wait_timeouts: list[float | None] = []

    def poll(self) -> int | None:
        if self._poll_outcomes:
            self._returncode = self._poll_outcomes.popleft()
        return self._returncode

    def wait(self, timeout: float | None = None) -> int:
        self.wait_timeouts.append(timeout)
        outcome = self._wait_outcomes.popleft() if self._wait_outcomes else 0
        if isinstance(outcome, Exception):
            raise outcome
        self._returncode = outcome
        return outcome


class RecordingFactory:
    def __init__(self, processes: list[FakeProcess], events: list[str] | None = None):
        self.processes = deque(processes)
        self.calls: list[tuple[list[str], dict[str, object]]] = []
        self.events = events

    def __call__(self, argv: list[str], **kwargs):
        self.calls.append((argv, kwargs))
        if self.events is not None:
            self.events.append("source_spawned")
        return self.processes.popleft()


class FakeCommandRunner:
    def __init__(
        self,
        results: list[dict[str, object] | Exception],
        events: list[str] | None = None,
    ):
        self.results = deque(results)
        self.calls: list[tuple[str, ...]] = []
        self.events = events

    def run_json(self, argv: tuple[str, ...]):
        self.calls.append(argv)
        if self.events is not None:
            action = "launch" if "launch" in argv else "resume"
            self.events.append(action)
        result = self.results.popleft()
        if isinstance(result, Exception):
            raise result
        return result


class FakeStream:
    def __init__(self, descriptor: int = 42):
        self.descriptor = descriptor

    def fileno(self) -> int:
        return self.descriptor


class FakeSelector:
    def __init__(self, readiness: list[bool] | None = None):
        self.readiness = deque(readiness or [])
        self.registered: list[tuple[object, int]] = []
        self.closed = False

    def register(self, stream: object, events: int) -> None:
        self.registered.append((stream, events))

    def select(self, _timeout: float | None = None):
        ready = self.readiness.popleft() if self.readiness else False
        return [(object(), selectors.EVENT_READ)] if ready else []

    def close(self) -> None:
        self.closed = True


class BrokenOutput:
    def write(self, _payload: bytes) -> int:
        raise BrokenPipeError

    def flush(self) -> None:
        return None

    def fileno(self) -> int:
        raise OSError


class ErrorOutput(BrokenOutput):
    def __init__(self, error_number: int):
        self.error_number = error_number

    def write(self, _payload: bytes) -> int:
        raise OSError(self.error_number, "fixed")


class MobileFeedTimingSourceSupervisorTest(unittest.TestCase):
    def run_supervisor(
        self,
        plan: source_module.SourcePlan,
        events: list[bytes | BaseException],
        *,
        process: FakeProcess | None = None,
        command_runner: FakeCommandRunner | None = None,
        downstream_status=None,
        output=None,
    ):
        process = process or FakeProcess()
        reader = FakeReader(events)
        factory = RecordingFactory([process])
        kills: list[tuple[int, int]] = []
        supervisor = source_module.SourceSupervisor(
            process_factory=factory,
            line_reader_factory=lambda _stream: reader,
            command_runner=command_runner or FakeCommandRunner([]),
            downstream_status=downstream_status,
            kill_process_group=lambda pid, sig: kills.append((pid, sig)),
        )
        stdout = output or io.BytesIO()
        stderr = io.StringIO()
        status = supervisor.run(plan, stdout, stderr)
        return {
            "status": status,
            "stdout": stdout,
            "stderr": stderr.getvalue(),
            "report": json.loads(stderr.getvalue()),
            "supervisor": supervisor,
            "factory": factory,
            "reader": reader,
            "kills": kills,
            "process": process,
        }

    def assert_fixed_report(self, report: dict[str, object]) -> None:
        self.assertEqual(
            {
                "supervisor",
                "status",
                "platform",
                "lines_seen",
                "markers_forwarded",
                "status_lines_discarded",
                "input_truncated",
                "downstream_completion",
                "source_exit",
                "cleanup",
            },
            set(report),
        )
        self.assertEqual(source_module.SUPERVISOR_NAME, report["supervisor"])
        self.assertNotIn(ANDROID_SERIAL, json.dumps(report))
        self.assertNotIn(IOS_UDID, json.dumps(report))
        self.assertNotIn(str(PID), json.dumps(report))
        self.assertNotIn(SECRET, json.dumps(report))

    def test_android_argv_is_one_exact_constant_remote_command(self):
        argv = source_module.build_android_source_argv(ANDROID_SERIAL)

        self.assertEqual(
            (
                "adb",
                "--exit-on-write-error",
                "-s",
                ANDROID_SERIAL,
                "exec-out",
                "exec run-as com.example.casein_mob "
                "logcat -b main -v raw -T 1 "
                "--regex='^mobile_feed_stage[ ]connection_generation=' "
                "'Elixir:I' '*:S'",
            ),
            argv,
        )
        self.assertEqual(6, len(argv))
        self.assertEqual(source_module.ANDROID_REMOTE_COMMAND, argv[-1])
        self.assertNotIn("--pid", argv)
        self.assertNotIn("--uid", argv)

    def test_android_identifier_validation_blocks_option_and_shell_injection(self):
        valid = ("emulator-5554", "192.0.2.1:5555", "ABC_123.device")
        for serial in valid:
            self.assertEqual(serial, source_module.build_android_source_argv(serial)[3])

        invalid = (
            "",
            "-d",
            "device;echo secret",
            "device value",
            "device\nnext",
            "x" * 129,
        )
        for serial in invalid:
            with self.subTest(serial=repr(serial)):
                with self.assertRaises(source_module.InvalidArguments):
                    source_module.build_android_source_argv(serial)

    def test_ios_argv_shapes_are_exact_and_have_no_fallback_flags(self):
        self.assertEqual(
            (
                "idevicesyslog",
                "-u",
                IOS_UDID,
                "-p",
                str(PID),
                "-m",
                "mobile_feed_stage ",
                "--no-colors",
                "-x",
            ),
            source_module.build_ios_source_argv(IOS_UDID, PID),
        )
        self.assertEqual(
            (
                "xcrun",
                "devicectl",
                "device",
                "process",
                "launch",
                "--device",
                IOS_UDID,
                "--start-stopped",
                "--terminate-existing",
                "--activate",
                "--quiet",
                "--timeout",
                "30",
                "--json-output",
                "-",
                "com.alexandrefamilyfarm.casein-mob",
            ),
            source_module.build_ios_launch_suspended_argv(IOS_UDID),
        )
        self.assertEqual(
            (
                "xcrun",
                "devicectl",
                "device",
                "process",
                "resume",
                "--device",
                IOS_UDID,
                "--pid",
                str(PID),
                "--quiet",
                "--timeout",
                "30",
                "--json-output",
                "-",
            ),
            source_module.build_ios_resume_argv(IOS_UDID, PID),
        )

    def test_ios_bundle_id_is_anchored_to_both_tracked_production_sources(self):
        info_plist = (
            ROOT / "native/casein_mob/ios/Info.plist"
        ).read_text(encoding="utf-8")
        project = (
            ROOT / "native/casein_mob/ios/Provision.xcodeproj/project.pbxproj"
        ).read_text(encoding="utf-8")

        self.assertEqual(
            "com.alexandrefamilyfarm.casein-mob", source_module.IOS_BUNDLE_ID
        )
        self.assertIn(
            "<string>com.alexandrefamilyfarm.casein-mob</string>", info_plist
        )
        self.assertIn(
            "PRODUCT_BUNDLE_IDENTIFIER = com.alexandrefamilyfarm.casein-mob;",
            project,
        )
        self.assertEqual(
            source_module.IOS_BUNDLE_ID,
            source_module.build_ios_launch_suspended_argv(IOS_UDID)[-1],
        )

    def test_ios_identifier_and_pid_validation_fail_closed(self):
        invalid_udids = ("", "-device", "not a udid", "abcd;id", "A" * 65)
        for udid in invalid_udids:
            with self.subTest(udid=repr(udid)):
                with self.assertRaises(source_module.InvalidArguments):
                    source_module.build_ios_launch_suspended_argv(udid)

        for pid in (True, False, 0, -1, source_module.MAX_PID + 1, "42", 1.5):
            with self.subTest(pid=pid):
                with self.assertRaises(source_module.SourceFailure):
                    source_module.build_ios_source_argv(IOS_UDID, pid)

    def test_plan_rejects_cross_platform_and_ambiguous_lifecycle_arguments(self):
        android = source_module.build_plan("android", ANDROID_SERIAL)
        self.assertEqual("android", android.platform)
        self.assertIsNone(android.ios_pid)

        running = source_module.build_plan("ios", IOS_UDID, ios_pid=PID)
        self.assertEqual(PID, running.ios_pid)
        self.assertIsNone(running.ios_launch_mode)

        suspended = source_module.build_plan(
            "ios", IOS_UDID, ios_suspended_launch=True
        )
        self.assertEqual("cold_once", suspended.ios_launch_mode)
        self.assertEqual((), suspended.source_argv)

        continuous = source_module.build_plan(
            "ios", IOS_UDID, ios_suspended_continuous=True
        )
        self.assertEqual("continuous", continuous.ios_launch_mode)
        self.assertEqual((), continuous.source_argv)

        invalid_calls = (
            lambda: source_module.build_plan("android", ANDROID_SERIAL, ios_pid=PID),
            lambda: source_module.build_plan(
                "android", ANDROID_SERIAL, ios_suspended_launch=True
            ),
            lambda: source_module.build_plan(
                "android", ANDROID_SERIAL, ios_suspended_continuous=True
            ),
            lambda: source_module.build_plan("ios", IOS_UDID),
            lambda: source_module.build_plan(
                "ios", IOS_UDID, ios_pid=PID, ios_suspended_launch=True
            ),
            lambda: source_module.build_plan(
                "ios",
                IOS_UDID,
                ios_suspended_launch=True,
                ios_suspended_continuous=True,
            ),
            lambda: source_module.build_plan(
                "ios",
                IOS_UDID,
                ios_pid=PID,
                ios_suspended_continuous=True,
            ),
            lambda: source_module.build_plan("windows", "device"),
        )
        for invalid_call in invalid_calls:
            with self.assertRaises(source_module.InvalidArguments):
                invalid_call()

    def test_source_process_is_shell_free_app_scoped_and_has_suppressed_stderr(self):
        os.environ["CASEIN_API_TOKEN"] = SECRET
        self.addCleanup(os.environ.pop, "CASEIN_API_TOKEN", None)
        plan = source_module.build_plan("android", ANDROID_SERIAL)
        result = self.run_supervisor(plan, [marker_line(), b""])

        self.assertEqual(2, result["status"])
        self.assertEqual(marker_line(), result["stdout"].getvalue())
        argv, kwargs = result["factory"].calls[0]
        self.assertEqual(list(plan.source_argv), argv)
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
        self.assertIs(kwargs["stdout"], subprocess.PIPE)
        self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
        self.assertIs(kwargs["shell"], False)
        self.assertIs(kwargs["close_fds"], True)
        self.assertIs(kwargs["start_new_session"], True)
        self.assertEqual(0, kwargs["bufsize"])
        self.assertNotIn("CASEIN_API_TOKEN", kwargs["env"])
        self.assertEqual("C", kwargs["env"]["LC_ALL"])
        self.assertEqual("1", kwargs["env"]["PYTHONDONTWRITEBYTECODE"])
        self.assert_fixed_report(result["report"])

    def test_library_rejects_forged_plan_before_any_process_can_start(self):
        forged = source_module.SourcePlan(
            platform="android",
            device_id=ANDROID_SERIAL,
            source_argv=("sh", "-c", SECRET),
        )
        result = self.run_supervisor(forged, [])

        self.assertEqual(3, result["status"])
        self.assertEqual("source_capability_failed", result["report"]["status"])
        self.assertEqual([], result["factory"].calls)
        self.assertNotIn(SECRET, result["stderr"])
        self.assertNotIn(ANDROID_SERIAL, result["stderr"])

    def test_android_forwards_marker_at_byte_zero_and_nothing_else(self):
        plan = source_module.build_plan("android", ANDROID_SERIAL)
        generation = "S" * 22
        result = self.run_supervisor(plan, [marker_line(generation=generation), b""])

        self.assertEqual(marker_line(generation=generation), result["stdout"].getvalue())
        self.assertNotIn(generation, result["stderr"])
        self.assertEqual(1, result["report"]["markers_forwarded"])

        for unsafe in (
            b"run-as: package not debuggable " + SECRET.encode() + b"\n",
            b"prefix " + marker_line(),
            marker_line()[:-1] + b" mobile_feed_stage duplicate\n",
        ):
            with self.subTest(unsafe=unsafe[:12]):
                rejected = self.run_supervisor(plan, [unsafe])
                self.assertEqual(3, rejected["status"])
                self.assertEqual(b"", rejected["stdout"].getvalue())
                self.assertNotIn(SECRET, rejected["stderr"])
                self.assertNotIn(ANDROID_SERIAL, rejected["stderr"])

    def test_ios_running_attach_requires_exact_connected_frame_and_strips_prefix(self):
        plan = source_module.build_plan("ios", IOS_UDID, ios_pid=PID)
        prefix = "2026-08-02 10:20:30 CaseinMob[42:7] … ".encode()
        result = self.run_supervisor(
            plan,
            [
                f"[connected:{IOS_UDID}]\n".encode(),
                marker_line(prefix=prefix),
                f"[disconnected:{IOS_UDID}]\n".encode(),
                b"",
            ],
        )

        self.assertEqual(2, result["status"])
        self.assertEqual(marker_line(), result["stdout"].getvalue())
        self.assertEqual(2, result["report"]["status_lines_discarded"])
        self.assertEqual(source_module.IOS_READY_TIMEOUT_SECONDS, result["reader"].timeouts[0])
        self.assertNotIn(IOS_UDID, result["stderr"])
        self.assertNotIn(str(PID), result["stderr"])

    def test_ios_pre_ready_framing_is_exact_and_never_resumes_on_failure(self):
        plan = source_module.build_plan(
            "ios", IOS_UDID, ios_suspended_launch=True
        )
        launch_payload = devicectl_success(PID)
        resume_payload = devicectl_success()
        cases = (
            b"[connected:other-device]\n",
            marker_line(),
            f"[disconnected:{IOS_UDID}]\n".encode(),
            (SECRET + "\n").encode(),
            b"",
        )
        for first_line in cases:
            with self.subTest(first_line=first_line[:16]):
                runner = FakeCommandRunner([launch_payload, resume_payload])
                result = self.run_supervisor(
                    plan,
                    [first_line],
                    command_runner=runner,
                )
                self.assertEqual(3, result["status"])
                self.assertEqual(1, len(runner.calls))
                self.assertIn("launch", runner.calls[0])
                self.assertNotIn(SECRET, result["stderr"])
                self.assertNotIn(IOS_UDID, result["stderr"])

        timeout_runner = FakeCommandRunner([launch_payload, resume_payload])
        timed_out = self.run_supervisor(
            plan,
            [source_module.ReadTimeout()],
            command_runner=timeout_runner,
        )
        self.assertEqual(3, timed_out["status"])
        self.assertEqual(1, len(timeout_runner.calls))

    def test_ios_suspended_launch_attach_resume_order_and_pid_reattach_shape(self):
        events: list[str] = []
        launch_payload = devicectl_success(PID)
        resume_payload = devicectl_success()
        runner = FakeCommandRunner([launch_payload, resume_payload], events)
        process = FakeProcess()
        reader = FakeReader(
            [
                f"[connected:{IOS_UDID}]\n".encode(),
                marker_line(prefix=b"fixed-prefix "),
                f"[disconnected:{IOS_UDID}]\n".encode(),
                b"",
            ]
        )
        factory = RecordingFactory([process], events)
        supervisor = source_module.SourceSupervisor(
            process_factory=factory,
            line_reader_factory=lambda _stream: reader,
            command_runner=runner,
            kill_process_group=lambda _pid, _signal: None,
        )
        stdout = io.BytesIO()
        stderr = io.StringIO()

        status = supervisor.run(
            source_module.build_plan(
                "ios", IOS_UDID, ios_suspended_launch=True
            ),
            stdout,
            stderr,
        )

        self.assertEqual(2, status)
        self.assertEqual(["launch", "source_spawned", "resume"], events)
        self.assertEqual(
            source_module.build_ios_launch_suspended_argv(IOS_UDID), runner.calls[0]
        )
        self.assertEqual(source_module.build_ios_resume_argv(IOS_UDID, PID), runner.calls[1])
        self.assertEqual(
            list(source_module.build_ios_source_argv(IOS_UDID, PID)),
            factory.calls[0][0],
        )
        self.assertEqual(marker_line(), stdout.getvalue())

    def test_ios_continuous_launch_forwards_initial_cold_then_reconnect_until_probe(self):
        launch_payload = devicectl_success(PID)
        resume_payload = devicectl_success()
        runner = FakeCommandRunner([launch_payload, resume_payload])
        cold_terminal = marker_line(stage="first_cards_render_ready")
        reconnect_start = marker_line(
            generation="B" * 22,
            cycle="reconnect",
            stage="connect_requested",
        )
        reconnect_terminal = marker_line(
            generation="B" * 22,
            cycle="reconnect",
            stage="first_cards_render_ready",
        )
        reader = FakeReader(
            [
                f"[connected:{IOS_UDID}]\n".encode(),
                cold_terminal,
                reconnect_start,
                reconnect_terminal,
                source_module.ReadTimeout(),
            ]
        )
        process = FakeProcess(pid=9_001, wait_outcomes=[0])
        factory = RecordingFactory([process])
        kills: list[tuple[int, int]] = []

        def completion_probe():
            if reader.events and isinstance(
                reader.events[0], source_module.ReadTimeout
            ):
                return 0
            return None

        supervisor = source_module.SourceSupervisor(
            process_factory=factory,
            line_reader_factory=lambda _stream: reader,
            command_runner=runner,
            downstream_status=completion_probe,
            kill_process_group=lambda child_pid, sig: kills.append((child_pid, sig)),
        )
        stdout = io.BytesIO()
        stderr = io.StringIO()

        status = supervisor.run(
            source_module.build_plan(
                "ios", IOS_UDID, ios_suspended_continuous=True
            ),
            stdout,
            stderr,
        )

        self.assertEqual(0, status)
        self.assertEqual(
            cold_terminal + reconnect_start + reconnect_terminal,
            stdout.getvalue(),
        )
        report = json.loads(stderr.getvalue())
        self.assertEqual("downstream_complete", report["status"])
        self.assertEqual("probe", report["downstream_completion"])
        self.assertEqual(3, report["markers_forwarded"])
        self.assertEqual("terminated", report["cleanup"])
        self.assertEqual([(process.pid, signal.SIGTERM)], kills)
        self.assertEqual(2, len(runner.calls))

    def test_twenty_ios_cold_sessions_end_at_terminal_and_concatenate_cleanly(self):
        combined = io.BytesIO()
        stages = (
            "connect_requested",
            "tcp_connect_started",
            "tcp_connected",
            "transport_connected",
            "mobile_join_replied",
            "snapshot_received",
            "snapshot_accepted",
            "first_cards_render_ready",
        )

        for index in range(1, 21):
            pid = 10_000 + index
            runner = FakeCommandRunner(
                [devicectl_success(pid), devicectl_success()]
            )
            process = FakeProcess(pid=20_000 + index, wait_outcomes=[0])
            reader = FakeReader(
                [f"[connected:{IOS_UDID}]\n".encode()]
                + [
                    marker_line(
                        generation=generation(index),
                        stage=stage,
                        elapsed=offset,
                    )
                    for offset, stage in enumerate(stages, 1)
                ]
            )
            factory = RecordingFactory([process])
            kills: list[tuple[int, int]] = []
            supervisor = source_module.SourceSupervisor(
                process_factory=factory,
                line_reader_factory=lambda _stream, reader=reader: reader,
                command_runner=runner,
                kill_process_group=lambda child_pid, sig, kills=kills: kills.append(
                    (child_pid, sig)
                ),
            )
            stderr = io.StringIO()

            status = supervisor.run(
                source_module.build_plan(
                    "ios", IOS_UDID, ios_suspended_launch=True
                ),
                combined,
                stderr,
            )

            self.assertEqual(0, status)
            report = json.loads(stderr.getvalue())
            self.assertEqual("ios_cold_generation_complete", report["status"])
            self.assertEqual("terminated", report["cleanup"])
            self.assertEqual([(process.pid, signal.SIGTERM)], kills)
            self.assertEqual(8, report["markers_forwarded"])
            self.assertEqual(2, len(runner.calls))

        marker_payload = combined.getvalue()
        self.assertEqual(20 * 8, len(marker_payload.splitlines()))
        stream_script = ROOT / "scripts/lib/mobile_feed_timing_stream.py"
        adapter = subprocess.run(
            [
                sys.executable,
                str(stream_script),
                "--source",
                "ios",
                "--cycle",
                "cold",
            ],
            input=marker_payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=10,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(0, adapter.returncode, adapter.stderr.decode())
        self.assertEqual(20 * 8, len(adapter.stdout.splitlines()))
        adapter_report = json.loads(adapter.stderr)
        self.assertEqual("complete", adapter_report["status"])
        self.assertEqual(20, adapter_report["terminal_generations"])

    def test_ios_cold_terminal_race_with_natural_nonzero_exit_fails_closed(self):
        terminal = marker_line(stage="first_cards_render_ready")
        process = FakeProcess(
            pid=30_001,
            wait_outcomes=[0],
            poll_outcomes=[None, 9, 9, 9],
        )
        runner = FakeCommandRunner(
            [devicectl_success(PID), devicectl_success()]
        )

        result = self.run_supervisor(
            source_module.build_plan(
                "ios", IOS_UDID, ios_suspended_launch=True
            ),
            [f"[connected:{IOS_UDID}]\n".encode(), terminal],
            process=process,
            command_runner=runner,
        )

        self.assertEqual(3, result["status"])
        self.assertEqual(terminal, result["stdout"].getvalue())
        self.assertEqual("source_capability_failed", result["report"]["status"])
        self.assertEqual("not_needed", result["report"]["cleanup"])
        self.assertEqual("nonzero", result["report"]["source_exit"])
        self.assertEqual([], result["kills"])

    def test_ios_cold_completed_source_with_unknown_final_exit_fails_closed(self):
        terminal = marker_line(stage="first_cards_render_ready")
        process = FakeProcess(
            pid=30_002,
            wait_outcomes=[0],
            poll_outcomes=[None, 0, None, 0],
        )
        runner = FakeCommandRunner(
            [devicectl_success(PID), devicectl_success()]
        )

        result = self.run_supervisor(
            source_module.build_plan(
                "ios", IOS_UDID, ios_suspended_launch=True
            ),
            [f"[connected:{IOS_UDID}]\n".encode(), terminal],
            process=process,
            command_runner=runner,
        )

        self.assertEqual(3, result["status"])
        self.assertEqual(terminal, result["stdout"].getvalue())
        self.assertEqual("source_capability_failed", result["report"]["status"])
        self.assertEqual("not_needed", result["report"]["cleanup"])
        self.assertEqual("unknown", result["report"]["source_exit"])
        self.assertEqual([], result["kills"])

    def test_devicectl_json_pid_is_strict_and_resume_must_match(self):
        valid = source_module.IOSLifecycle(
            FakeCommandRunner([devicectl_success(PID)])
        )
        self.assertEqual(PID, valid.launch_suspended(IOS_UDID))

        malformed = (
            {},
            {"result": None},
            {"info": {"outcome": "failure"}, "result": {}},
            {"info": {"outcome": "success"}, "result": {}, "extra": {}},
            devicectl_success(str(PID)),
            devicectl_success(True),
            devicectl_success(0),
            devicectl_success(source_module.MAX_PID + 1),
        )
        for payload in malformed:
            with self.subTest(payload=payload):
                lifecycle = source_module.IOSLifecycle(FakeCommandRunner([payload]))
                with self.assertRaises(source_module.SourceFailure):
                    lifecycle.launch_suspended(IOS_UDID)

        mismatched = source_module.IOSLifecycle(
            FakeCommandRunner([devicectl_success(PID + 1)])
        )
        with self.assertRaises(source_module.SourceFailure):
            mismatched.resume(IOS_UDID, PID)

        # Xcode 27 resume legitimately returns a successful result map without
        # repeating processIdentifier. The envelope remains exact and bounded.
        source_module.IOSLifecycle(FakeCommandRunner([devicectl_success()])).resume(
            IOS_UDID, PID
        )
        for payload in (
            {},
            {"info": {"outcome": "failure"}, "result": {}},
            {"info": {"outcome": "success"}, "result": None},
            {"info": {"outcome": "success"}, "result": {}, "extra": {}},
            devicectl_success("not-a-pid"),
        ):
            with self.subTest(resume_payload=payload):
                lifecycle = source_module.IOSLifecycle(FakeCommandRunner([payload]))
                with self.assertRaises(source_module.SourceFailure):
                    lifecycle.resume(IOS_UDID, PID)

    def test_capability_failures_never_fallback_or_reflect_child_output(self):
        plan = source_module.build_plan("android", ANDROID_SERIAL)
        process = FakeProcess(wait_outcomes=[127])
        result = self.run_supervisor(plan, [b""], process=process)

        self.assertEqual(3, result["status"])
        self.assertEqual("source_capability_failed", result["report"]["status"])
        self.assertEqual("nonzero", result["report"]["source_exit"])
        self.assertEqual(1, len(result["factory"].calls))
        self.assertEqual(list(plan.source_argv), result["factory"].calls[0][0])
        self.assertNotIn("127", result["stderr"])
        self.assertNotIn(ANDROID_SERIAL, result["stderr"])

        launch_failure = FakeCommandRunner(
            [source_module.SourceFailure("source_capability_failed")]
        )
        suspended = self.run_supervisor(
            source_module.build_plan("ios", IOS_UDID, ios_suspended_launch=True),
            [],
            command_runner=launch_failure,
        )
        self.assertEqual(3, suspended["status"])
        self.assertEqual(0, len(suspended["factory"].calls))

    def test_interrupt_and_unexpected_reader_failure_each_emit_one_fixed_status(self):
        plan = source_module.build_plan("android", ANDROID_SERIAL)
        unexpected = self.run_supervisor(plan, [RuntimeError(SECRET)])
        self.assertEqual(70, unexpected["status"])
        self.assertEqual("internal_error", unexpected["report"]["status"])
        self.assertEqual(1, len(unexpected["stderr"].splitlines()))
        self.assertNotIn(SECRET, unexpected["stderr"])

        interrupted = self.run_supervisor(plan, [KeyboardInterrupt()])
        self.assertEqual(130, interrupted["status"])
        self.assertEqual("interrupted", interrupted["report"]["status"])
        self.assertEqual(1, len(interrupted["stderr"].splitlines()))

    def test_epipe_is_normalized_only_for_exact_injected_zero_status(self):
        plan = source_module.build_plan("android", ANDROID_SERIAL)
        completes_after_write = iter((None, 0))
        probes = (
            (completes_after_write.__next__, 0, "epipe", "downstream_complete"),
            (lambda: 1, 3, "unverified_epipe", "downstream_unverified"),
            (lambda: None, 3, "unverified_epipe", "downstream_unverified"),
            (lambda: True, 3, "unverified_epipe", "downstream_unverified"),
            (None, 3, "unverified_epipe", "downstream_unverified"),
        )
        for probe, expected_status, expected_epipe, expected_label in probes:
            with self.subTest(probe=probe):
                process = FakeProcess(wait_outcomes=[0])
                result = self.run_supervisor(
                    plan,
                    [marker_line()],
                    process=process,
                    downstream_status=probe,
                    output=BrokenOutput(),
                )
                self.assertEqual(expected_status, result["status"])
                self.assertEqual(
                    expected_epipe, result["report"]["downstream_completion"]
                )
                self.assertEqual(expected_label, result["report"]["status"])

        def failing_probe():
            raise RuntimeError(SECRET)

        failed = self.run_supervisor(
            plan,
            [marker_line()],
            downstream_status=failing_probe,
            output=BrokenOutput(),
        )
        self.assertEqual(3, failed["status"])
        self.assertNotIn(SECRET, failed["stderr"])

        non_epipe_probe = iter((None, 0))
        non_epipe = self.run_supervisor(
            plan,
            [marker_line()],
            downstream_status=non_epipe_probe.__next__,
            output=ErrorOutput(errno.ENOSPC),
        )
        self.assertEqual(3, non_epipe["status"])
        self.assertEqual("invalid_source_output", non_epipe["report"]["status"])
        self.assertEqual("none", non_epipe["report"]["downstream_completion"])

    def test_verified_completion_probe_stops_a_quiet_source_without_next_marker(self):
        plan = source_module.build_plan("android", ANDROID_SERIAL)
        statuses = deque([None, 0])
        process = FakeProcess(pid=876, wait_outcomes=[0])
        result = self.run_supervisor(
            plan,
            [source_module.ReadTimeout()],
            process=process,
            downstream_status=lambda: statuses.popleft(),
        )

        self.assertEqual(0, result["status"])
        self.assertEqual("downstream_complete", result["report"]["status"])
        self.assertEqual("probe", result["report"]["downstream_completion"])
        self.assertEqual("terminated", result["report"]["cleanup"])
        self.assertEqual([(876, signal.SIGTERM)], result["kills"])
        self.assertEqual(
            source_module.DOWNSTREAM_POLL_SECONDS, result["reader"].timeouts[0]
        )

    def test_false_or_throwing_completion_probe_never_makes_term_success(self):
        plan = source_module.build_plan("android", ANDROID_SERIAL)

        def throwing_probe():
            raise RuntimeError(SECRET)

        for probe in (lambda: 1, lambda: None, lambda: True, throwing_probe):
            with self.subTest(probe=probe):
                result = self.run_supervisor(
                    plan,
                    [source_module.ReadTimeout(), b""],
                    downstream_status=probe,
                )
                self.assertEqual(2, result["status"])
                self.assertEqual("incomplete", result["report"]["status"])
                self.assertEqual("none", result["report"]["downstream_completion"])
                self.assertEqual([], result["kills"])
                self.assertNotIn(SECRET, result["stderr"])

        standalone = self.run_supervisor(plan, [b""])
        self.assertEqual(2, standalone["status"])
        self.assertEqual([None], standalone["reader"].timeouts)

    def test_process_group_cleanup_escalates_and_never_targets_any_other_pid(self):
        plan = source_module.build_plan("android", ANDROID_SERIAL)
        process = FakeProcess(
            pid=987,
            wait_outcomes=[subprocess.TimeoutExpired("fixed", 1), 9],
        )
        result = self.run_supervisor(
            plan,
            [marker_line(prefix=b"invalid ")],
            process=process,
        )

        self.assertEqual(3, result["status"])
        self.assertEqual([(987, signal.SIGTERM), (987, signal.SIGKILL)], result["kills"])
        self.assertEqual("killed", result["report"]["cleanup"])

        already_done = FakeProcess(pid=988, wait_outcomes=[0])
        already_done._returncode = 0
        self.assertEqual(
            "not_needed",
            source_module._terminate_process_group(already_done, lambda *_args: None),
        )

    def test_hard_line_count_byte_prefix_and_framing_bounds(self):
        android = source_module.build_plan("android", ANDROID_SERIAL)
        oversized = b"mobile_feed_stage " + b"x" * source_module.MAX_LINE_BYTES + b"\n"
        result = self.run_supervisor(android, [oversized])
        self.assertEqual(3, result["status"])
        self.assertEqual("source_output_limit", result["report"]["status"])
        self.assertTrue(result["report"]["input_truncated"])

        unterminated = self.run_supervisor(android, [marker_line()[:-1]])
        self.assertEqual(3, unterminated["status"])
        self.assertEqual("invalid_source_output", unterminated["report"]["status"])

        ios = source_module.build_plan("ios", IOS_UDID, ios_pid=PID)
        bad_prefixes = (
            b"x" * (source_module.MAX_IOS_PREFIX_BYTES + 1),
            b"bad\x00prefix",
            b"bad\xffprefix",
        )
        for prefix in bad_prefixes:
            rejected = self.run_supervisor(
                ios,
                [f"[connected:{IOS_UDID}]\n".encode(), marker_line(prefix=prefix)],
            )
            self.assertEqual(3, rejected["status"])
            self.assertEqual("invalid_source_output", rejected["report"]["status"])

        with mock.patch.object(source_module, "MAX_LINES", 1):
            too_many = self.run_supervisor(android, [marker_line(), marker_line()])
        self.assertEqual(3, too_many["status"])
        self.assertEqual("source_output_limit", too_many["report"]["status"])

        with mock.patch.object(source_module, "MAX_INPUT_BYTES", len(marker_line())):
            too_many_bytes = self.run_supervisor(
                android, [marker_line(), marker_line()]
            )
        self.assertEqual(3, too_many_bytes["status"])
        self.assertEqual("source_output_limit", too_many_bytes["report"]["status"])

    def test_selector_line_reader_is_fragment_safe_bounded_and_timeout_aware(self):
        stream = FakeStream()
        selector = FakeSelector([True, True, True])
        chunks = deque([b"first\nsec", b"ond\n", b""])
        reader = source_module.SelectorLineReader(
            stream,
            selector_factory=lambda: selector,
            read_fn=lambda _fd, _size: chunks.popleft(),
            monotonic=lambda: 0.0,
        )
        self.assertEqual(b"first\n", reader.readline(1))
        self.assertEqual(b"second\n", reader.readline(1))
        self.assertEqual(b"", reader.readline(1))
        reader.close()
        self.assertTrue(selector.closed)

        oversized_selector = FakeSelector([True])
        oversized_reader = source_module.SelectorLineReader(
            FakeStream(),
            selector_factory=lambda: oversized_selector,
            read_fn=lambda _fd, _size: b"x" * (source_module.MAX_LINE_BYTES + 1),
            monotonic=lambda: 0.0,
        )
        with self.assertRaises(source_module.SourceFailure) as oversized:
            oversized_reader.readline(1)
        self.assertEqual("source_output_limit", oversized.exception.status)
        oversized_reader.close()

        partial_selector = FakeSelector([True, True])
        partial_chunks = deque([b"unterminated", b""])
        partial_reader = source_module.SelectorLineReader(
            FakeStream(),
            selector_factory=lambda: partial_selector,
            read_fn=lambda _fd, _size: partial_chunks.popleft(),
            monotonic=lambda: 0.0,
        )
        with self.assertRaises(source_module.SourceFailure) as partial:
            partial_reader.readline(1)
        self.assertEqual("invalid_source_output", partial.exception.status)
        partial_reader.close()

        timeout_selector = FakeSelector([False])
        timeout_reader = source_module.SelectorLineReader(
            FakeStream(),
            selector_factory=lambda: timeout_selector,
            read_fn=lambda _fd, _size: b"",
            monotonic=lambda: 0.0,
        )
        with self.assertRaises(source_module.ReadTimeout):
            timeout_reader.readline(1)
        timeout_reader.close()

    def test_lifecycle_json_reader_enforces_timeout_and_total_byte_bound(self):
        process = FakeProcess(stdout=FakeStream())

        selector = FakeSelector([True, True])
        chunks = deque([b"{}", b""])
        runner = source_module.BoundedSubprocessJSONRunner(
            selector_factory=lambda: selector,
            read_fn=lambda _fd, _size: chunks.popleft(),
            monotonic=lambda: 0.0,
        )
        self.assertEqual(b"{}", runner._read_all(process, process.stdout))
        self.assertTrue(selector.closed)

        oversized_selector = FakeSelector([True])
        with mock.patch.object(source_module, "MAX_COMMAND_JSON_BYTES", 4):
            oversized_runner = source_module.BoundedSubprocessJSONRunner(
                selector_factory=lambda: oversized_selector,
                read_fn=lambda _fd, _size: b"12345",
                monotonic=lambda: 0.0,
            )
            with self.assertRaises(source_module.SourceFailure) as oversized:
                oversized_runner._read_all(process, process.stdout)
        self.assertEqual("source_output_limit", oversized.exception.status)
        self.assertTrue(oversized_selector.closed)

        timeout_selector = FakeSelector([False])
        timeout_runner = source_module.BoundedSubprocessJSONRunner(
            selector_factory=lambda: timeout_selector,
            read_fn=lambda _fd, _size: b"",
            monotonic=lambda: 0.0,
        )
        with self.assertRaises(source_module.ReadTimeout):
            timeout_runner._read_all(process, process.stdout)
        self.assertTrue(timeout_selector.closed)

    def test_bounded_json_runner_uses_fixed_safe_process_contract(self):
        process = FakeProcess(wait_outcomes=[0], stdout=io.BytesIO())
        factory = RecordingFactory([process])
        runner = source_module.BoundedSubprocessJSONRunner(
            process_factory=factory,
            kill_process_group=lambda _pid, _signal: None,
        )
        runner._read_all = lambda _process, _stdout: (
            b'{"info":{"outcome":"success"},'
            b'"result":{"processIdentifier":4242}}'
        )
        argv = source_module.build_ios_launch_suspended_argv(IOS_UDID)

        payload = runner.run_json(argv)

        self.assertEqual(PID, payload["result"]["processIdentifier"])
        called_argv, kwargs = factory.calls[0]
        self.assertEqual(list(argv), called_argv)
        self.assertIs(kwargs["shell"], False)
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
        self.assertIs(kwargs["stdout"], subprocess.PIPE)
        self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
        self.assertIs(kwargs["start_new_session"], True)
        self.assertNotIn(IOS_UDID, json.dumps(kwargs))

    def test_bounded_json_runner_rejects_invalid_nonzero_and_oversize_without_reflection(self):
        cases = (
            (b"not-json " + SECRET.encode(), 0, "source_capability_failed"),
            (
                b'{"info":{"outcome":"success"},'
                b'"result":{},"result":{"processIdentifier":4242}}',
                0,
                "source_capability_failed",
            ),
            (b'{"result":{}}', 64, "source_capability_failed"),
        )
        for raw, returncode, expected in cases:
            process = FakeProcess(wait_outcomes=[returncode], stdout=io.BytesIO())
            factory = RecordingFactory([process])
            runner = source_module.BoundedSubprocessJSONRunner(
                process_factory=factory,
                kill_process_group=lambda _pid, _signal: None,
            )
            runner._read_all = lambda _process, _stdout, raw=raw: raw
            with self.assertRaises(source_module.SourceFailure) as failure:
                runner.run_json(source_module.build_ios_launch_suspended_argv(IOS_UDID))
            self.assertEqual(expected, failure.exception.status)
            self.assertNotIn(SECRET, str(failure.exception))
            self.assertNotIn(IOS_UDID, str(failure.exception))

        process = FakeProcess(wait_outcomes=[0], stdout=io.BytesIO())
        runner = source_module.BoundedSubprocessJSONRunner(
            process_factory=RecordingFactory([process]),
            kill_process_group=lambda _pid, _signal: None,
        )
        runner._read_all = lambda _process, _stdout: (_ for _ in ()).throw(
            source_module.SourceFailure("source_output_limit")
        )
        with self.assertRaises(source_module.SourceFailure) as failure:
            runner.run_json(source_module.build_ios_launch_suspended_argv(IOS_UDID))
        self.assertEqual("source_output_limit", failure.exception.status)

    def test_cli_argument_failures_use_one_fixed_identity_free_status(self):
        cases = (
            ["--platform", "android", "--device", "-secret"],
            ["--platform", "ios", "--device", IOS_UDID],
            [
                "--platform",
                "ios",
                "--device",
                IOS_UDID,
                "--pid",
                str(PID),
                "--ios-suspended-launch",
            ],
            [
                "--platform",
                "ios",
                "--device",
                IOS_UDID,
                "--ios-suspended-continuous",
            ],
            [
                "--platform",
                "ios",
                "--device",
                IOS_UDID,
                "--ios-suspended-launch",
                "--ios-suspended-continuous",
            ],
            ["--platform", "unknown", "--device", SECRET],
        )
        for argv in cases:
            stderr = io.StringIO()
            with mock.patch.object(source_module.sys, "stderr", stderr):
                self.assertEqual(64, source_module.main(argv))
            lines = stderr.getvalue().splitlines()
            self.assertEqual(1, len(lines))
            self.assertEqual(
                {
                    "status": "invalid_arguments",
                    "supervisor": source_module.SUPERVISOR_NAME,
                },
                json.loads(lines[0]),
            )
            self.assertNotIn(SECRET, stderr.getvalue())
            self.assertNotIn(IOS_UDID, stderr.getvalue())

    def test_source_has_no_raw_file_tee_shell_or_bytecode_path(self):
        source = SOURCE_SCRIPT.read_text(encoding="utf-8")
        self.assertNotEqual(0, SOURCE_SCRIPT.stat().st_mode & stat.S_IXUSR)
        self.assertNotIn("shell=True", source)
        self.assertNotIn("os.system", source)
        self.assertNotIn("tee ", source)
        self.assertNotIn("NamedTemporaryFile", source)
        self.assertNotIn("mkstemp", source)
        self.assertIn("sys.dont_write_bytecode = True", source)


if __name__ == "__main__":
    unittest.main()
