#!/usr/bin/env python3
"""Supervise app-scoped native timing sources without retaining native logs.

This is a narrow producer building block.  It starts exactly one allowlisted
native source command, removes the fixed iOS transport framing in memory, and
writes only ``mobile_feed_stage `` marker lines to stdout.  It never reflects
child output, device identifiers, process identifiers, or command failures.

A later in-memory cohort coordinator supplies ``downstream_status``.  The
standalone CLI deliberately cannot call a broken downstream pipe successful.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import BinaryIO, Callable, Mapping, Protocol, Sequence, TextIO


# A normal source invocation must not create bytecode beside this script.
sys.dont_write_bytecode = True


SUPERVISOR_NAME = "casein_mobile_feed_timing_source_supervisor"
ANDROID_PACKAGE = "com.example.casein_mob"
IOS_BUNDLE_ID = "com.alexandrefamilyfarm.casein-mob"
MARKER = b"mobile_feed_stage "

MAX_LINE_BYTES = 1_024
MAX_INPUT_BYTES = 10 * 1_024 * 1_024
MAX_LINES = 10_000
MAX_IOS_PREFIX_BYTES = 768
MAX_COMMAND_JSON_BYTES = 16 * 1_024
COMMAND_TIMEOUT_SECONDS = 35.0
IOS_READY_TIMEOUT_SECONDS = 10.0
DOWNSTREAM_POLL_SECONDS = 0.25
PROCESS_TERM_TIMEOUT_SECONDS = 1.0
PROCESS_KILL_TIMEOUT_SECONDS = 1.0
MAX_PID = 2_147_483_647

ANDROID_REMOTE_COMMAND = (
    f"exec run-as {ANDROID_PACKAGE} "
    "logcat -b main -v raw -T 1 "
    "--regex='^mobile_feed_stage[ ]connection_generation=' "
    "'Elixir:I' '*:S'"
)

_ANDROID_SERIAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_IOS_UDID_RE = re.compile(r"^[A-Fa-f0-9][A-Fa-f0-9-]{7,63}$")
_TIMING_TOKEN = rb"(?:0|[1-9][0-9]*)(?:\.[0-9]{1,3})?"
_IOS_COLD_TERMINAL_RE = re.compile(
    rb"mobile_feed_stage "
    rb"connection_generation=[A-Za-z0-9_-]{22} "
    rb"cycle=cold "
    rb"stage=first_cards_render_ready "
    rb"duration_ms=" + _TIMING_TOKEN + rb" "
    rb"elapsed_ms=" + _TIMING_TOKEN + rb" "
    rb"outcome=succeeded "
    rb"reason_code=none\n"
)

STATUS_VALUES = frozenset(
    {
        "downstream_complete",
        "ios_cold_generation_complete",
        "incomplete",
        "invalid_arguments",
        "invalid_source_output",
        "source_capability_failed",
        "source_output_limit",
        "downstream_unverified",
        "interrupted",
        "internal_error",
    }
)


class InvalidArguments(Exception):
    """Raised without argparse's value-reflecting diagnostics."""


class SourceFailure(Exception):
    """A fixed, identity-free source failure."""

    def __init__(self, status: str):
        self.status = status if status in STATUS_VALUES else "internal_error"
        super().__init__(self.status)


class ReadTimeout(Exception):
    """A bounded source read did not become ready in time."""


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        raise InvalidArguments


class ProcessLike(Protocol):
    pid: int
    stdout: BinaryIO | None

    def poll(self) -> int | None: ...

    def wait(self, timeout: float | None = None) -> int: ...


ProcessFactory = Callable[..., ProcessLike]
DownstreamStatus = Callable[[], int | None]
KillProcessGroup = Callable[[int, int], None]
ProcessGroupExists = Callable[[int], bool]


@dataclass(frozen=True, slots=True)
class SourcePlan:
    platform: str
    device_id: str
    source_argv: tuple[str, ...]
    ios_pid: int | None = None
    ios_launch_mode: str | None = None


class CommandRunner(Protocol):
    def run_json(self, argv: tuple[str, ...]) -> Mapping[str, object]: ...


def build_android_source_argv(serial: str) -> tuple[str, ...]:
    """Return the sole audited Android app-UID log source command."""

    _validate_android_serial(serial)
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "exec-out",
        ANDROID_REMOTE_COMMAND,
    )


def build_ios_source_argv(udid: str, pid: int) -> tuple[str, ...]:
    """Return the sole audited idevicesyslog 1.4 PID attachment command."""

    _validate_ios_udid(udid)
    safe_pid = _validate_pid(pid)
    return (
        "idevicesyslog",
        "-u",
        udid,
        "-p",
        str(safe_pid),
        "-m",
        "mobile_feed_stage ",
        "--no-colors",
        "-x",
    )


def build_ios_launch_suspended_argv(udid: str) -> tuple[str, ...]:
    """Return the audited Xcode 27 start-stopped launch command."""

    _validate_ios_udid(udid)
    return (
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        udid,
        "--start-stopped",
        "--terminate-existing",
        "--activate",
        "--quiet",
        "--timeout",
        "30",
        "--json-output",
        "-",
        IOS_BUNDLE_ID,
    )


def build_ios_resume_argv(udid: str, pid: int) -> tuple[str, ...]:
    """Return the audited Xcode 27 process-resume command."""

    _validate_ios_udid(udid)
    safe_pid = _validate_pid(pid)
    return (
        "xcrun",
        "devicectl",
        "device",
        "process",
        "resume",
        "--device",
        udid,
        "--pid",
        str(safe_pid),
        "--quiet",
        "--timeout",
        "30",
        "--json-output",
        "-",
    )


def build_plan(
    platform: str,
    device_id: str,
    *,
    ios_pid: int | None = None,
    ios_suspended_launch: bool = False,
    ios_suspended_continuous: bool = False,
) -> SourcePlan:
    if platform == "android":
        if ios_pid is not None or ios_suspended_launch or ios_suspended_continuous:
            raise InvalidArguments
        return SourcePlan(
            platform="android",
            device_id=device_id,
            source_argv=build_android_source_argv(device_id),
        )

    if platform != "ios":
        raise InvalidArguments

    _validate_ios_udid(device_id)
    if ios_suspended_launch and ios_suspended_continuous:
        raise InvalidArguments
    if ios_suspended_launch or ios_suspended_continuous:
        if ios_pid is not None:
            raise InvalidArguments
        return SourcePlan(
            platform="ios",
            device_id=device_id,
            source_argv=(),
            ios_launch_mode=(
                "cold_once" if ios_suspended_launch else "continuous"
            ),
        )

    if ios_pid is None:
        raise InvalidArguments
    safe_pid = _validate_pid(ios_pid)
    return SourcePlan(
        platform="ios",
        device_id=device_id,
        source_argv=build_ios_source_argv(device_id, safe_pid),
        ios_pid=safe_pid,
    )


class SelectorLineReader:
    """Read newline frames from one pipe with fixed memory and time bounds."""

    def __init__(
        self,
        stream: BinaryIO,
        *,
        selector_factory: Callable[[], selectors.BaseSelector] = selectors.DefaultSelector,
        read_fn: Callable[[int, int], bytes] = os.read,
        monotonic: Callable[[], float] = time.monotonic,
    ):
        self._stream = stream
        self._selector = selector_factory()
        self._selector.register(stream, selectors.EVENT_READ)
        self._read_fn = read_fn
        self._monotonic = monotonic
        self._buffer = bytearray()
        self._eof = False

    def readline(self, timeout: float | None = None) -> bytes:
        deadline = None if timeout is None else self._monotonic() + timeout

        while True:
            newline_index = self._buffer.find(b"\n")
            if newline_index >= 0:
                line_end = newline_index + 1
                if line_end > MAX_LINE_BYTES:
                    raise SourceFailure("source_output_limit")
                line = bytes(self._buffer[:line_end])
                del self._buffer[:line_end]
                return line

            if len(self._buffer) > MAX_LINE_BYTES:
                raise SourceFailure("source_output_limit")
            if self._eof:
                if self._buffer:
                    self._buffer.clear()
                    raise SourceFailure("invalid_source_output")
                return b""

            wait = None
            if deadline is not None:
                wait = deadline - self._monotonic()
                if wait <= 0:
                    raise ReadTimeout

            if not self._selector.select(wait):
                raise ReadTimeout

            capacity = MAX_LINE_BYTES + 1 - len(self._buffer)
            chunk = self._read_fn(self._stream.fileno(), min(4_096, capacity))
            if not chunk:
                self._eof = True
            else:
                self._buffer.extend(chunk)

    def close(self) -> None:
        self._buffer.clear()
        self._selector.close()


class BoundedSubprocessJSONRunner:
    """Run a fixed lifecycle command and retain at most one bounded JSON reply."""

    def __init__(
        self,
        *,
        process_factory: ProcessFactory = subprocess.Popen,
        selector_factory: Callable[[], selectors.BaseSelector] = selectors.DefaultSelector,
        read_fn: Callable[[int, int], bytes] = os.read,
        monotonic: Callable[[], float] = time.monotonic,
        kill_process_group: KillProcessGroup = os.killpg,
        process_group_exists: ProcessGroupExists | None = None,
    ):
        self._process_factory = process_factory
        self._selector_factory = selector_factory
        self._read_fn = read_fn
        self._monotonic = monotonic
        self._kill_process_group = kill_process_group
        self._process_group_exists = process_group_exists or _process_group_exists

    def run_json(self, argv: tuple[str, ...]) -> Mapping[str, object]:
        process = self._process_factory(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            shell=False,
            close_fds=True,
            start_new_session=True,
            bufsize=0,
            env=_safe_child_env(),
        )
        stdout = process.stdout
        if stdout is None:
            _terminate_process_group(
                process,
                self._kill_process_group,
                self._process_group_exists,
            )
            raise SourceFailure("source_capability_failed")

        try:
            raw = self._read_all(process, stdout)
            returncode = process.wait(timeout=PROCESS_TERM_TIMEOUT_SECONDS)
            if returncode != 0:
                raise SourceFailure("source_capability_failed")
            try:
                payload = json.loads(raw, object_pairs_hook=_strict_json_object)
            except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, TypeError):
                raise SourceFailure("source_capability_failed") from None
            finally:
                del raw
            if not isinstance(payload, dict):
                raise SourceFailure("source_capability_failed")
            return payload
        except (ReadTimeout, subprocess.TimeoutExpired):
            _terminate_process_group(
                process,
                self._kill_process_group,
                self._process_group_exists,
            )
            raise SourceFailure("source_capability_failed") from None
        except SourceFailure:
            if process.poll() is None:
                _terminate_process_group(
                    process,
                    self._kill_process_group,
                    self._process_group_exists,
                )
            raise
        finally:
            try:
                stdout.close()
            except (OSError, ValueError):
                pass

    def _read_all(self, process: ProcessLike, stdout: BinaryIO) -> bytes:
        selector = self._selector_factory()
        selector.register(stdout, selectors.EVENT_READ)
        deadline = self._monotonic() + COMMAND_TIMEOUT_SECONDS
        output = bytearray()
        try:
            while True:
                remaining = deadline - self._monotonic()
                if remaining <= 0:
                    raise ReadTimeout
                if not selector.select(remaining):
                    raise ReadTimeout
                chunk = self._read_fn(stdout.fileno(), 4_096)
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > MAX_COMMAND_JSON_BYTES:
                    output.clear()
                    raise SourceFailure("source_output_limit")
            return bytes(output)
        finally:
            output.clear()
            selector.close()


class IOSLifecycle:
    """Strict start-stopped and resume interface for a cold iOS attachment."""

    def __init__(self, runner: CommandRunner):
        self._runner = runner

    def launch_suspended(self, udid: str) -> int:
        payload = self._runner.run_json(build_ios_launch_suspended_argv(udid))
        return _pid_from_result(payload)

    def resume(self, udid: str, pid: int) -> None:
        safe_pid = _validate_pid(pid)
        payload = self._runner.run_json(build_ios_resume_argv(udid, safe_pid))
        result = _devicectl_success_result(payload)
        returned_pid = result.get("processIdentifier")
        if returned_pid is not None and _validate_pid(returned_pid) != safe_pid:
            raise SourceFailure("source_capability_failed")


class SourceSupervisor:
    """Own one app-scoped source process and forward marker frames only."""

    def __init__(
        self,
        *,
        process_factory: ProcessFactory = subprocess.Popen,
        line_reader_factory: Callable[[BinaryIO], SelectorLineReader] = SelectorLineReader,
        command_runner: CommandRunner | None = None,
        downstream_status: DownstreamStatus | None = None,
        kill_process_group: KillProcessGroup = os.killpg,
        process_group_exists: ProcessGroupExists | None = None,
    ):
        self._process_factory = process_factory
        self._line_reader_factory = line_reader_factory
        self._command_runner = command_runner or BoundedSubprocessJSONRunner(
            process_factory=process_factory,
            kill_process_group=kill_process_group,
            process_group_exists=process_group_exists,
        )
        self._downstream_status = downstream_status
        self._kill_process_group = kill_process_group
        self._process_group_exists = process_group_exists or _process_group_exists
        self.lines_seen = 0
        self.input_bytes = 0
        self.markers_forwarded = 0
        self.status_lines_discarded = 0
        self.input_truncated = False
        self.downstream_completion = "none"
        self.source_exit = "unknown"
        self.cleanup = "not_needed"

    def run(
        self,
        plan: SourcePlan,
        output: BinaryIO,
        status_output: TextIO,
    ) -> int:
        process: ProcessLike | None = None
        reader: SelectorLineReader | None = None
        status = "internal_error"
        exit_code = 70

        try:
            self._validate_plan(plan)
            source_argv = plan.source_argv
            if plan.ios_launch_mode is not None:
                pid = IOSLifecycle(self._command_runner).launch_suspended(plan.device_id)
                source_argv = build_ios_source_argv(plan.device_id, pid)

            process = self._spawn_source(source_argv)
            stdout = process.stdout
            if stdout is None:
                raise SourceFailure("source_capability_failed")
            reader = self._line_reader_factory(stdout)

            if plan.platform == "ios":
                self._consume_ios_connected(reader, plan.device_id)
                if plan.ios_launch_mode is not None:
                    IOSLifecycle(self._command_runner).resume(plan.device_id, pid)

            while True:
                if self._downstream_status is not None and self._verified_downstream_success():
                    self.cleanup = self._cleanup_process(process)
                    if self.cleanup == "failed":
                        status, exit_code = "source_capability_failed", 3
                    else:
                        self.downstream_completion = "probe"
                        status, exit_code = "downstream_complete", 0
                    break

                try:
                    raw_line = reader.readline(
                        DOWNSTREAM_POLL_SECONDS
                        if self._downstream_status is not None
                        else None
                    )
                except ReadTimeout:
                    # A coordinator-supplied status callback is the only safe
                    # wakeup while an otherwise quiet native source is live.
                    # False, unavailable, and throwing probes keep waiting.
                    continue
                if not raw_line:
                    returncode = self._wait_for_source(process)
                    if returncode == 0:
                        status, exit_code = "incomplete", 2
                    else:
                        status, exit_code = "source_capability_failed", 3
                    break

                self._account_line(raw_line)
                marker_line = self._marker_line(plan, raw_line)
                if marker_line is None:
                    continue

                try:
                    output.write(marker_line)
                    output.flush()
                except BrokenPipeError:
                    _suppress_failed_output(output)
                    cleanup = self._cleanup_process(process)
                    self.cleanup = cleanup
                    if cleanup == "failed":
                        status, exit_code = "source_capability_failed", 3
                    elif self._verified_downstream_success():
                        self.downstream_completion = "epipe"
                        status, exit_code = "downstream_complete", 0
                    else:
                        self.downstream_completion = "unverified_epipe"
                        status, exit_code = "downstream_unverified", 3
                    break
                except OSError as error:
                    if error.errno == errno.EPIPE:
                        _suppress_failed_output(output)
                        cleanup = self._cleanup_process(process)
                        self.cleanup = cleanup
                        if cleanup == "failed":
                            status, exit_code = "source_capability_failed", 3
                        elif self._verified_downstream_success():
                            self.downstream_completion = "epipe"
                            status, exit_code = "downstream_complete", 0
                        else:
                            self.downstream_completion = "unverified_epipe"
                            status, exit_code = "downstream_unverified", 3
                    else:
                        status, exit_code = "invalid_source_output", 3
                    break
                except ValueError:
                    status, exit_code = "invalid_source_output", 3
                    break
                self.markers_forwarded += 1

                if (
                    plan.ios_launch_mode == "cold_once"
                    and _IOS_COLD_TERMINAL_RE.fullmatch(marker_line) is not None
                ):
                    exited_before_cleanup = process.poll()
                    self.cleanup = self._cleanup_process(process)
                    source_exit_failed_or_unverified = (
                        exited_before_cleanup is not None
                        and exited_before_cleanup != 0
                    ) or (
                        self.cleanup == "not_needed"
                        and self.source_exit != "zero"
                    )
                    if (
                        self.cleanup == "failed"
                        or source_exit_failed_or_unverified
                    ):
                        status, exit_code = "source_capability_failed", 3
                    else:
                        status, exit_code = "ios_cold_generation_complete", 0
                    break

        except SourceFailure as failure:
            status, exit_code = failure.status, 3
        except KeyboardInterrupt:
            status, exit_code = "interrupted", 130
        except (OSError, ValueError, subprocess.SubprocessError):
            status, exit_code = "source_capability_failed", 3
        except Exception:
            # The process boundary must collapse unexpected implementation
            # failures to one fixed status without reflecting exception text.
            status, exit_code = "internal_error", 70
        finally:
            if reader is not None:
                try:
                    reader.close()
                except Exception:
                    pass
            if process is not None and process.poll() is None:
                self.cleanup = self._cleanup_process(process)
            self._write_status(status_output, plan.platform, status)

        return exit_code

    def _validate_plan(self, plan: SourcePlan) -> None:
        if not isinstance(plan, SourcePlan):
            raise SourceFailure("source_capability_failed")
        try:
            if plan.platform == "android":
                expected = build_plan("android", plan.device_id)
            elif plan.ios_launch_mode == "cold_once":
                expected = build_plan(
                    "ios", plan.device_id, ios_suspended_launch=True
                )
            elif plan.ios_launch_mode == "continuous":
                expected = build_plan(
                    "ios", plan.device_id, ios_suspended_continuous=True
                )
            elif plan.ios_launch_mode is None and plan.ios_pid is not None:
                expected = build_plan("ios", plan.device_id, ios_pid=plan.ios_pid)
            else:
                raise InvalidArguments
        except (InvalidArguments, SourceFailure, TypeError, ValueError):
            raise SourceFailure("source_capability_failed") from None
        if plan != expected:
            raise SourceFailure("source_capability_failed")

    def _spawn_source(self, argv: tuple[str, ...]) -> ProcessLike:
        if not argv:
            raise SourceFailure("source_capability_failed")
        return self._process_factory(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            shell=False,
            close_fds=True,
            start_new_session=True,
            bufsize=0,
            env=_safe_child_env(),
        )

    def _consume_ios_connected(
        self, reader: SelectorLineReader, udid: str
    ) -> None:
        try:
            raw_line = reader.readline(IOS_READY_TIMEOUT_SECONDS)
        except ReadTimeout:
            raise SourceFailure("source_capability_failed") from None
        if not raw_line:
            raise SourceFailure("source_capability_failed")
        self._account_line(raw_line)
        expected = f"[connected:{udid}]\n".encode("ascii")
        if raw_line != expected:
            raise SourceFailure("source_capability_failed")
        self.status_lines_discarded += 1

    def _account_line(self, raw_line: bytes) -> None:
        self.lines_seen += 1
        self.input_bytes += len(raw_line)
        if self.lines_seen > MAX_LINES or self.input_bytes > MAX_INPUT_BYTES:
            self.input_truncated = True
            raise SourceFailure("source_output_limit")
        if len(raw_line) > MAX_LINE_BYTES:
            self.input_truncated = True
            raise SourceFailure("source_output_limit")
        if not raw_line.endswith(b"\n"):
            raise SourceFailure("invalid_source_output")

    def _marker_line(self, plan: SourcePlan, raw_line: bytes) -> bytes | None:
        marker_count = raw_line.count(MARKER)
        if marker_count == 0:
            if plan.platform == "ios":
                disconnected = f"[disconnected:{plan.device_id}]\n".encode("ascii")
                if raw_line == disconnected:
                    self.status_lines_discarded += 1
                    return None
            # With the exact source filters, any other stdout means run-as,
            # logcat-regex, idevicesyslog, or attachment capability drift.
            raise SourceFailure("source_capability_failed")
        if marker_count != 1:
            raise SourceFailure("invalid_source_output")

        prefix, suffix = raw_line.split(MARKER, 1)
        if plan.platform == "android" and prefix:
            raise SourceFailure("invalid_source_output")
        if plan.platform == "ios":
            _validate_ios_prefix(prefix)

        return MARKER + suffix

    def _wait_for_source(self, process: ProcessLike) -> int:
        try:
            returncode = process.wait(timeout=PROCESS_TERM_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            self.cleanup = self._cleanup_process(process)
            returncode = process.poll()
            return -1 if returncode is None else returncode
        self.source_exit = "zero" if returncode == 0 else "nonzero"
        return returncode

    def _cleanup_process(self, process: ProcessLike) -> str:
        cleanup = _terminate_process_group(
            process,
            self._kill_process_group,
            self._process_group_exists,
        )
        returncode = process.poll()
        if returncode is not None:
            self.source_exit = "zero" if returncode == 0 else "nonzero"
        return cleanup

    def _verified_downstream_success(self) -> bool:
        if self._downstream_status is None:
            return False
        try:
            status = self._downstream_status()
        except Exception:
            return False
        return type(status) is int and status == 0

    def _write_status(self, output: TextIO, platform: str, status: str) -> None:
        payload = {
            "supervisor": SUPERVISOR_NAME,
            "status": status if status in STATUS_VALUES else "internal_error",
            "platform": platform if platform in {"android", "ios"} else "unknown",
            "lines_seen": self.lines_seen,
            "markers_forwarded": self.markers_forwarded,
            "status_lines_discarded": self.status_lines_discarded,
            "input_truncated": self.input_truncated,
            "downstream_completion": self.downstream_completion,
            "source_exit": self.source_exit,
            "cleanup": self.cleanup,
        }
        try:
            output.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
            output.flush()
        except (BrokenPipeError, OSError, ValueError):
            return


def _pid_from_result(payload: Mapping[str, object]) -> int:
    result = _devicectl_success_result(payload)
    pid = result.get("processIdentifier")
    return _validate_pid(pid)


def _strict_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise SourceFailure("source_capability_failed")
        result[key] = value
    return result


def _devicectl_success_result(payload: Mapping[str, object]) -> dict[str, object]:
    if set(payload) != {"info", "result"}:
        raise SourceFailure("source_capability_failed")
    info = payload.get("info")
    result = payload.get("result")
    if (
        not isinstance(info, dict)
        or info.get("outcome") != "success"
        or not isinstance(result, dict)
    ):
        raise SourceFailure("source_capability_failed")
    return result


def _validate_android_serial(serial: str) -> None:
    if not isinstance(serial, str) or _ANDROID_SERIAL_RE.fullmatch(serial) is None:
        raise InvalidArguments


def _validate_ios_udid(udid: str) -> None:
    if not isinstance(udid, str) or _IOS_UDID_RE.fullmatch(udid) is None:
        raise InvalidArguments


def _validate_pid(pid: object) -> int:
    if type(pid) is not int or pid < 1 or pid > MAX_PID:
        raise SourceFailure("source_capability_failed")
    return pid


def _validate_ios_prefix(prefix: bytes) -> None:
    if len(prefix) > MAX_IOS_PREFIX_BYTES:
        raise SourceFailure("invalid_source_output")
    if any(byte < 0x20 and byte != 0x09 for byte in prefix):
        raise SourceFailure("invalid_source_output")
    try:
        prefix.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise SourceFailure("invalid_source_output") from None


def _safe_child_env() -> dict[str, str]:
    allowed = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR")
    environment = {key: os.environ[key] for key in allowed if key in os.environ}
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def _terminate_process_group(
    process: ProcessLike,
    kill_process_group: KillProcessGroup,
    process_group_exists: ProcessGroupExists | None = None,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> str:
    group_exists = process_group_exists or _process_group_exists
    leader_running = process.poll() is None
    if not leader_running:
        # A numeric PGID is not an owned capability after its tracked leader
        # exits. It may already refer to an unrelated, reused process group.
        return "failed" if group_exists(process.pid) else "not_needed"
    if not group_exists(process.pid):
        return "failed"

    try:
        kill_process_group(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        if process.poll() is None:
            return "failed"
        return "failed" if group_exists(process.pid) else "not_needed"
    except OSError:
        pass

    try:
        process.wait(timeout=PROCESS_TERM_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    else:
        return "failed" if group_exists(process.pid) else "terminated"

    # Revalidate the tracked child identity immediately before escalation. A
    # surviving numeric group after leader exit is ambiguous and must not be
    # signalled.
    if process.poll() is not None:
        return "failed" if group_exists(process.pid) else "terminated"
    if not group_exists(process.pid):
        return "failed"

    try:
        kill_process_group(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        if process.poll() is None:
            return "failed"
        return "failed" if group_exists(process.pid) else "killed"
    except OSError:
        pass

    leader_kill_timed_out = False
    if process.poll() is None:
        try:
            process.wait(timeout=PROCESS_KILL_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            leader_kill_timed_out = True
    group_gone = _wait_for_process_group_exit(
        process.pid,
        PROCESS_KILL_TIMEOUT_SECONDS,
        group_exists,
        monotonic,
        sleeper,
    )
    if leader_kill_timed_out or not group_gone or process.poll() is None:
        return "failed"
    return "killed"


def _process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def _wait_for_process_group_exit(
    process_group_id: int,
    timeout: float,
    process_group_exists: ProcessGroupExists,
    monotonic: Callable[[], float],
    sleeper: Callable[[float], None],
) -> bool:
    deadline = monotonic() + timeout
    while process_group_exists(process_group_id):
        remaining = deadline - monotonic()
        if remaining <= 0:
            return False
        sleeper(min(0.05, remaining))
    return True


def _suppress_failed_output(output: BinaryIO) -> None:
    descriptor = -1
    try:
        output_descriptor = output.fileno()
        flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(os.devnull, flags)
        if descriptor == output_descriptor:
            descriptor = -1
        else:
            os.dup2(descriptor, output_descriptor)
    except (AttributeError, OSError, ValueError):
        return
    finally:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(add_help=False)
    parser.add_argument("--platform", required=True, choices=("android", "ios"))
    parser.add_argument("--device", required=True)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--ios-suspended-launch", action="store_true")
    return parser


def _fixed_cli_status(output: TextIO, status: str) -> None:
    payload = {"supervisor": SUPERVISOR_NAME, "status": status}
    try:
        output.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
        output.flush()
    except (BrokenPipeError, OSError, ValueError):
        return


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
        plan = build_plan(
            args.platform,
            args.device,
            ios_pid=args.pid,
            ios_suspended_launch=args.ios_suspended_launch,
        )
    except (InvalidArguments, SourceFailure, ValueError, TypeError):
        _fixed_cli_status(sys.stderr, "invalid_arguments")
        return 64

    supervisor = SourceSupervisor()
    return supervisor.run(plan, sys.stdout.buffer, sys.stderr)


if __name__ == "__main__":
    try:
        exit_code = main()
    except KeyboardInterrupt:
        _fixed_cli_status(sys.stderr, "interrupted")
        exit_code = 130
    except Exception:
        _fixed_cli_status(sys.stderr, "internal_error")
        exit_code = 70
    raise SystemExit(exit_code)
