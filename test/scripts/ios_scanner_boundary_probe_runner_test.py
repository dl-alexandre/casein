#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import unittest
from collections import deque
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts/lib"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


source = load_module(
    "mobile_feed_timing_source_supervisor",
    LIB / "mobile_feed_timing_source_supervisor.py",
)
runner = load_module(
    "ios_scanner_boundary_probe_runner",
    LIB / "ios_scanner_boundary_probe_runner.py",
)


IOS_UDID = "00008101-001234560123001E"
PID = 4242
SECRET = "password=must-never-appear"


def devicectl_success(pid: object | None = None) -> dict[str, object]:
    result: dict[str, object] = {}
    if pid is not None:
        result["processIdentifier"] = pid
    return {"info": {"outcome": "success"}, "result": result}


def diagnostic_line(*, prefix: bytes = b"fixed-prefix ") -> bytes:
    return prefix + runner.DIAGNOSTIC_MARKER + runner.DIAGNOSTIC_SUFFIX


class FakeCommandRunner:
    def __init__(self, results: list[dict[str, object] | BaseException]):
        self.results = deque(results)
        self.calls: list[tuple[str, ...]] = []

    def run_json(self, argv: tuple[str, ...]) -> dict[str, object]:
        self.calls.append(argv)
        result = self.results.popleft()
        if isinstance(result, BaseException):
            raise result
        return result


class FakeReader:
    def __init__(
        self,
        events: list[bytes | BaseException],
        *,
        close_result: BaseException | None = None,
    ):
        self.events = deque(events)
        self.timeouts: list[float | None] = []
        self.closed = False
        self.close_result = close_result

    def readline(self, timeout: float | None = None) -> bytes:
        self.timeouts.append(timeout)
        if not self.events:
            raise AssertionError("unexpected additional read")
        event = self.events.popleft()
        if isinstance(event, BaseException):
            raise event
        return event

    def close(self) -> None:
        self.closed = True
        if self.close_result is not None:
            raise self.close_result


class FakeProcess:
    def __init__(self, *, pid: int = 700, stdout: object | None = None):
        self.pid = pid
        self.stdout = stdout if stdout is not None else io.BytesIO()
        self.returncode: int | None = None

    def poll(self) -> int | None:
        return self.returncode


class RecordingFactory:
    def __init__(self, result: FakeProcess | BaseException):
        self.result = result
        self.calls: list[tuple[list[str], dict[str, object]]] = []

    def __call__(self, argv: list[str], **kwargs):
        self.calls.append((argv, kwargs))
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result


class IOSScannerBoundaryProbeRunnerTest(unittest.TestCase):
    def run_probe(
        self,
        *,
        command_results: list[dict[str, object] | BaseException] | None = None,
        reader_events: list[bytes | BaseException] | None = None,
        cleanup: str | BaseException = "terminated",
        process: FakeProcess | None = None,
        process_error: BaseException | None = None,
        reader_close_result: BaseException | None = None,
        device_id: str = IOS_UDID,
    ):
        commands = FakeCommandRunner(
            command_results
            or [devicectl_success(PID), devicectl_success(PID)]
        )
        process = process or FakeProcess()
        factory = RecordingFactory(process_error or process)
        reader = FakeReader(
            reader_events
            or [
                f"[connected:{IOS_UDID}]\n".encode("ascii"),
                diagnostic_line(),
                source.ReadTimeout(),
            ],
            close_result=reader_close_result,
        )
        cleanup_calls: list[FakeProcess] = []

        def cleanup_process_group(target: FakeProcess) -> str:
            cleanup_calls.append(target)
            if isinstance(cleanup, BaseException):
                raise cleanup
            return cleanup

        probe = runner.ScannerBoundaryProbeRunner(
            process_factory=factory,
            line_reader_factory=lambda _stream: reader,
            command_runner=commands,
            cleanup_process_group=cleanup_process_group,
        )
        outcome = probe.run(device_id)
        return {
            "outcome": outcome,
            "commands": commands,
            "factory": factory,
            "reader": reader,
            "cleanup_calls": cleanup_calls,
        }

    def test_exact_one_shot_launch_attach_resume_and_diagnostic(self):
        self.assertEqual(16 * 1_024, source.MAX_COMMAND_JSON_BYTES)
        result = self.run_probe()

        self.assertEqual(
            runner.Outcome("accepted", "complete", 0), result["outcome"]
        )
        self.assertEqual(2, len(result["commands"].calls))
        launch, resume = result["commands"].calls
        self.assertEqual(runner.build_launch_argv(IOS_UDID), launch)
        self.assertEqual(source.build_ios_resume_argv(IOS_UDID, PID), resume)
        self.assertEqual(
            (
                "xcrun",
                "devicectl",
                "device",
                "process",
                "terminate",
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
            runner.build_terminate_argv(IOS_UDID, PID),
        )
        self.assertEqual(1, launch.count(runner.DIAGNOSTIC_URL))
        self.assertIn("--start-stopped", launch)
        self.assertIn("--terminate-existing", launch)
        self.assertEqual(1, len(result["factory"].calls))

        source_argv, source_opts = result["factory"].calls[0]
        self.assertEqual(list(runner.build_source_argv(IOS_UDID, PID)), source_argv)
        self.assertEqual(subprocess.DEVNULL, source_opts["stdin"])
        self.assertEqual(subprocess.PIPE, source_opts["stdout"])
        self.assertEqual(subprocess.DEVNULL, source_opts["stderr"])
        self.assertFalse(source_opts["shell"])
        self.assertTrue(source_opts["close_fds"])
        self.assertTrue(source_opts["start_new_session"])
        self.assertEqual(0, source_opts["bufsize"])
        self.assertEqual(
            [source.IOS_READY_TIMEOUT_SECONDS, 15.0, 0.25],
            result["reader"].timeouts,
        )
        self.assertTrue(result["reader"].closed)
        self.assertEqual(1, len(result["cleanup_calls"]))

    def test_malformed_and_oversize_launch_results_fail_without_retry_or_source(self):
        for failure in (
            source.SourceFailure("source_capability_failed"),
            source.SourceFailure("source_output_limit"),
        ):
            with self.subTest(failure=failure.status):
                result = self.run_probe(command_results=[failure])
                self.assertEqual("failed", result["outcome"].status)
                self.assertEqual("launch_suspended", result["outcome"].phase)
                self.assertEqual(3, result["outcome"].exit_code)
                self.assertEqual(1, len(result["commands"].calls))
                self.assertEqual([], result["factory"].calls)
                self.assertEqual([], result["cleanup_calls"])

        malformed = self.run_probe(command_results=[{}])
        self.assertEqual("pid_parse", malformed["outcome"].phase)
        self.assertEqual(1, len(malformed["commands"].calls))
        self.assertEqual([], malformed["factory"].calls)

    def test_missing_boolean_zero_oversize_and_wrong_pid_fail_at_parse(self):
        invalid_pids = [None, True, 0, source.MAX_PID + 1, "4242"]
        for invalid_pid in invalid_pids:
            with self.subTest(pid=invalid_pid):
                result = self.run_probe(
                    command_results=[devicectl_success(invalid_pid)]
                )
                self.assertEqual("pid_parse", result["outcome"].phase)
                self.assertEqual(1, len(result["commands"].calls))
                self.assertEqual([], result["factory"].calls)

    def test_resume_must_return_the_same_exact_pid(self):
        result = self.run_probe(
            command_results=[
                devicectl_success(PID),
                devicectl_success(PID + 1),
                devicectl_success(PID),
            ]
        )
        self.assertEqual("resume", result["outcome"].phase)
        self.assertEqual(3, len(result["commands"].calls))
        self.assertEqual(
            runner.build_terminate_argv(IOS_UDID, PID),
            result["commands"].calls[-1],
        )
        self.assertEqual(1, len(result["factory"].calls))

    def test_connection_timeout_and_wrong_frame_fail_closed(self):
        cleanup_results = [devicectl_success(PID), devicectl_success(PID)]
        timeout = self.run_probe(
            command_results=cleanup_results,
            reader_events=[source.ReadTimeout()],
        )
        self.assertEqual("source_connected", timeout["outcome"].phase)
        self.assertEqual(2, len(timeout["commands"].calls))
        self.assertEqual(
            runner.build_terminate_argv(IOS_UDID, PID),
            timeout["commands"].calls[-1],
        )

        wrong = self.run_probe(
            command_results=cleanup_results,
            reader_events=[b"[connected:other]\n"],
        )
        self.assertEqual("source_connected", wrong["outcome"].phase)
        self.assertEqual(2, len(wrong["commands"].calls))
        self.assertEqual(
            runner.build_terminate_argv(IOS_UDID, PID),
            wrong["commands"].calls[-1],
        )

    def test_source_spawn_and_resume_failure_rollback_exact_launched_pid(self):
        spawned = self.run_probe(
            command_results=[devicectl_success(PID), devicectl_success(PID)],
            process_error=OSError(SECRET),
        )
        self.assertEqual("source_spawn", spawned["outcome"].phase)
        self.assertEqual(2, len(spawned["commands"].calls))
        self.assertEqual(
            runner.build_terminate_argv(IOS_UDID, PID),
            spawned["commands"].calls[-1],
        )
        self.assertEqual([], spawned["cleanup_calls"])

        resume = self.run_probe(
            command_results=[
                devicectl_success(PID),
                source.SourceFailure("source_capability_failed"),
                devicectl_success(PID),
            ]
        )
        self.assertEqual("resume", resume["outcome"].phase)
        self.assertEqual(3, len(resume["commands"].calls))
        self.assertEqual(
            runner.build_terminate_argv(IOS_UDID, PID),
            resume["commands"].calls[-1],
        )
        self.assertEqual(
            1,
            sum(
                call[:5]
                == ("xcrun", "devicectl", "device", "process", "launch")
                for call in resume["commands"].calls
            ),
        )

    def test_unproven_exact_pid_rollback_fails_as_cleanup(self):
        result = self.run_probe(
            command_results=[devicectl_success(PID), {}],
            reader_events=[source.ReadTimeout()],
        )
        self.assertEqual(runner.Outcome("failed", "cleanup", 3), result["outcome"])
        self.assertEqual(2, len(result["commands"].calls))

        for returned_pid in (None, True, "4242", PID + 1):
            with self.subTest(returned_pid=returned_pid):
                ambiguous = {
                    "info": {"outcome": "success"},
                    "result": {"processIdentifier": returned_pid},
                }
                result = self.run_probe(
                    command_results=[devicectl_success(PID), ambiguous],
                    reader_events=[source.ReadTimeout()],
                )
                self.assertEqual(
                    runner.Outcome("failed", "cleanup", 3), result["outcome"]
                )
                self.assertEqual(2, len(result["commands"].calls))

    def test_interruption_is_preserved_after_complete_exact_capability_cleanup(self):
        result = self.run_probe(
            command_results=[devicectl_success(PID), devicectl_success(PID)],
            reader_events=[KeyboardInterrupt()],
        )
        self.assertEqual(
            runner.Outcome("failed", "interrupted", 130), result["outcome"]
        )
        self.assertEqual(
            runner.build_terminate_argv(IOS_UDID, PID),
            result["commands"].calls[-1],
        )
        self.assertEqual(1, len(result["cleanup_calls"]))
        self.assertTrue(result["reader"].closed)

    def test_diagnostic_timeout_wrong_line_and_oversize_fail_closed(self):
        connected = f"[connected:{IOS_UDID}]\n".encode("ascii")
        cases = {
            "timeout": source.ReadTimeout(),
            "wrong": b"fixed-prefix ios_scanner_boundary_probe wrong\n",
            "oversize": source.SourceFailure("source_output_limit"),
        }
        for name, event in cases.items():
            with self.subTest(name=name):
                result = self.run_probe(reader_events=[connected, event])
                self.assertEqual("diagnostic", result["outcome"].phase)
                self.assertEqual(2, len(result["commands"].calls))

    def test_duplicate_marker_and_second_line_fail_closed(self):
        connected = f"[connected:{IOS_UDID}]\n".encode("ascii")
        duplicate_marker = (
            diagnostic_line()
            .rstrip(b"\n")
            .join([b"", runner.DIAGNOSTIC_MARKER + runner.DIAGNOSTIC_SUFFIX])
        )
        in_one_line = self.run_probe(
            reader_events=[connected, duplicate_marker]
        )
        self.assertEqual("diagnostic", in_one_line["outcome"].phase)

        second_line = self.run_probe(
            reader_events=[connected, diagnostic_line(), diagnostic_line()]
        )
        self.assertEqual("diagnostic", second_line["outcome"].phase)

    def test_source_cleanup_must_be_proven(self):
        for cleanup in ("failed", "not_needed", RuntimeError(SECRET)):
            with self.subTest(cleanup=type(cleanup).__name__):
                result = self.run_probe(cleanup=cleanup)
                self.assertEqual("failed", result["outcome"].status)
                self.assertEqual("cleanup", result["outcome"].phase)
                self.assertEqual(1, len(result["cleanup_calls"]))

        exited = FakeProcess()
        exited.returncode = 0
        result = self.run_probe(cleanup="not_needed", process=exited)
        self.assertEqual("accepted", result["outcome"].status)

    def test_cleanup_interruptions_do_not_skip_later_cleanup_steps(self):
        reader_close = self.run_probe(
            reader_close_result=KeyboardInterrupt()
        )
        self.assertEqual(
            runner.Outcome("failed", "cleanup", 3), reader_close["outcome"]
        )
        self.assertEqual(1, len(reader_close["cleanup_calls"]))
        self.assertTrue(reader_close["reader"].closed)

        source_cleanup = self.run_probe(cleanup=KeyboardInterrupt())
        self.assertEqual(
            runner.Outcome("failed", "cleanup", 3), source_cleanup["outcome"]
        )
        self.assertEqual(1, len(source_cleanup["cleanup_calls"]))
        self.assertTrue(source_cleanup["reader"].closed)
        self.assertTrue(source_cleanup["factory"].result.stdout.closed)

        pre_resume = self.run_probe(
            command_results=[devicectl_success(PID), devicectl_success(PID)],
            reader_events=[source.ReadTimeout()],
            cleanup=KeyboardInterrupt(),
            reader_close_result=KeyboardInterrupt(),
        )
        self.assertEqual(runner.Outcome("failed", "cleanup", 3), pre_resume["outcome"])
        self.assertEqual(
            runner.build_terminate_argv(IOS_UDID, PID),
            pre_resume["commands"].calls[-1],
        )
        self.assertEqual(1, len(pre_resume["cleanup_calls"]))
        self.assertTrue(pre_resume["reader"].closed)
        self.assertTrue(pre_resume["factory"].result.stdout.closed)

    def test_interrupt_at_cleanup_mask_boundaries_preserves_exhaustive_cleanup(self):
        with mock.patch.object(
            runner, "_suppress_cleanup_interrupts", side_effect=KeyboardInterrupt()
        ):
            suppress = self.run_probe()

        with (
            mock.patch.object(runner, "_suppress_cleanup_interrupts", return_value=None),
            mock.patch.object(
                runner, "_restore_interrupt_mask", side_effect=KeyboardInterrupt()
            ),
        ):
            restore = self.run_probe()

        for result in (suppress, restore):
            self.assertEqual(
                runner.Outcome("failed", "interrupted", 130), result["outcome"]
            )
            self.assertEqual(1, len(result["cleanup_calls"]))
            self.assertTrue(result["reader"].closed)
            self.assertTrue(result["factory"].result.stdout.closed)

    def test_fixed_status_never_reflects_device_or_child_content(self):
        output = io.StringIO()
        runner._fixed_status(output, runner.Outcome("failed", "diagnostic", 3))
        payload = output.getvalue()
        self.assertEqual(
            {
                "phase": "diagnostic",
                "runner": runner.RUNNER_NAME,
                "status": "failed",
            },
            json.loads(payload),
        )
        self.assertNotIn(IOS_UDID, payload)
        self.assertNotIn(SECRET, payload)
        self.assertNotIn(runner.DIAGNOSTIC_URL, payload)

    def test_cli_rejects_missing_duplicate_and_malformed_device_without_execution(self):
        for argv in (
            [],
            ["--device", IOS_UDID, "--device", IOS_UDID],
            ["--device", SECRET],
        ):
            with self.subTest(argv_length=len(argv)):
                stderr = io.StringIO()
                with mock.patch.object(sys, "stderr", stderr):
                    exit_code = runner.main(argv)
                self.assertEqual(64, exit_code)
                self.assertEqual("arguments", json.loads(stderr.getvalue())["phase"])
                self.assertNotIn(IOS_UDID, stderr.getvalue())
                self.assertNotIn(SECRET, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
