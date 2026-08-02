#!/usr/bin/env python3
"""Run one privacy-safe physical iOS scanner-boundary probe.

The caller owns the durable, external exactly-once fence.  This process never
retries or relaunches: it performs one start-stopped launch carrying the fixed
public diagnostic URL, attaches one PID-scoped allowlisted source, resumes the
same PID, and accepts exactly one fixed diagnostic line.  Child output is
consumed in memory under fixed bounds and is never reflected or retained.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import resource
import signal
import subprocess
import sys
from dataclasses import dataclass
from typing import BinaryIO, Callable, Protocol, Sequence, TextIO

sys.dont_write_bytecode = True
source_contract = importlib.import_module("mobile_feed_timing_source_supervisor")

RUNNER_NAME = "casein_ios_scanner_boundary_probe_runner"
BUNDLE_ID = "com.alexandrefamilyfarm.casein-mob"
DIAGNOSTIC_URL = "casein://diagnostic/scanner-boundary"
DIAGNOSTIC_MARKER = b"ios_scanner_boundary_probe "
DIAGNOSTIC_SUFFIX = (
    b"scan_type=qr byte_count=146 compact_prefix=true "
    b"base64url_segment=true rejection_stage=none rejection_reason=none\n"
)

DIAGNOSTIC_TIMEOUT_SECONDS = 15.0
DUPLICATE_GUARD_SECONDS = 0.25

PHASES = frozenset(
    {
        "arguments",
        "launch_suspended",
        "pid_parse",
        "source_spawn",
        "source_connected",
        "resume",
        "diagnostic",
        "cleanup",
        "interrupted",
        "complete",
    }
)
STATUSES = frozenset({"accepted", "failed"})


class InvalidArguments(Exception):
    """A CLI rejection that never reflects the supplied value."""


class ProbeFailure(Exception):
    """One fixed scanner-probe failure boundary."""

    def __init__(self, phase: str):
        self.phase = phase if phase in PHASES else "diagnostic"
        super().__init__(self.phase)

    def __repr__(self) -> str:
        return f"ProbeFailure(phase={self.phase!r})"


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        raise InvalidArguments


class StoreOnceAction(argparse.Action):
    def __call__(
        self,
        _parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: object,
        _option_string: str | None = None,
    ) -> None:
        seen = f"_{self.dest}_seen"
        if getattr(namespace, seen, False):
            raise InvalidArguments
        setattr(namespace, seen, True)
        setattr(namespace, self.dest, values)


class ProcessLike(Protocol):
    pid: int
    stdout: BinaryIO | None

    def poll(self) -> int | None: ...


class JSONRunner(Protocol):
    def run_json(self, argv: tuple[str, ...]) -> dict[str, object]: ...


class LineReader(Protocol):
    def readline(self, timeout: float | None = None) -> bytes: ...

    def close(self) -> None: ...


ProcessFactory = Callable[..., ProcessLike]
LineReaderFactory = Callable[[BinaryIO], LineReader]
CleanupProcessGroup = Callable[[ProcessLike], str]


@dataclass(frozen=True, slots=True)
class Outcome:
    status: str
    phase: str
    exit_code: int

    def __post_init__(self) -> None:
        if (
            self.status not in STATUSES
            or self.phase not in PHASES
            or self.exit_code not in {0, 3, 64, 130}
            or (self.status == "accepted") != (
                self.phase == "complete" and self.exit_code == 0
            )
        ):
            raise ValueError("invalid scanner-probe outcome")


def build_launch_argv(device_id: str) -> tuple[str, ...]:
    """Return the sole launch command; validating the private device first."""

    # Reuse the timing source's strict device grammar before building the one
    # diagnostic-specific argv.  The URL is a checked-in public literal.
    source_contract.build_ios_launch_suspended_argv(device_id)
    return (
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        device_id,
        "--start-stopped",
        "--terminate-existing",
        "--activate",
        "--payload-url",
        DIAGNOSTIC_URL,
        "--quiet",
        "--timeout",
        "30",
        "--json-output",
        "-",
        BUNDLE_ID,
    )


def build_source_argv(device_id: str, pid: int) -> tuple[str, ...]:
    """Return the sole exact-PID, exact-marker native source command."""

    source_contract.build_ios_source_argv(device_id, pid)
    return (
        "idevicesyslog",
        "-u",
        device_id,
        "-p",
        str(pid),
        "-m",
        DIAGNOSTIC_MARKER.decode("ascii"),
        "--no-colors",
        "-x",
    )


def build_terminate_argv(device_id: str, pid: int) -> tuple[str, ...]:
    """Return the bounded rollback for the exact PID launched suspended."""

    # The resume builder applies both private-device and positive-PID grammar.
    # Termination is permitted only for that already parsed launch capability.
    source_contract.build_ios_resume_argv(device_id, pid)
    return (
        "xcrun",
        "devicectl",
        "device",
        "process",
        "terminate",
        "--device",
        device_id,
        "--pid",
        str(pid),
        "--quiet",
        "--timeout",
        "30",
        "--json-output",
        "-",
    )


def _default_cleanup(process: ProcessLike) -> str:
    return source_contract._terminate_process_group(  # noqa: SLF001
        process,
        os.killpg,
        source_contract._process_group_exists,  # noqa: SLF001
    )


def _suppress_cleanup_interrupts() -> set[signal.Signals] | None:
    """Block process-directed interrupts until all cleanup has been attempted."""

    try:
        return signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM}
        )
    except (AttributeError, OSError, RuntimeError, ValueError):
        # Per-boundary BaseException handling below remains the fail-closed
        # fallback on an unsupported interpreter or non-main execution model.
        return None


def _restore_interrupt_mask(
    prior_mask: set[signal.Signals] | None,
) -> None:
    if prior_mask is None:
        return
    signal.pthread_sigmask(signal.SIG_SETMASK, prior_mask)


class ScannerBoundaryProbeRunner:
    """Execute one launch/attach/resume/read sequence without fallback."""

    def __init__(
        self,
        *,
        process_factory: ProcessFactory = subprocess.Popen,
        line_reader_factory: LineReaderFactory = source_contract.SelectorLineReader,
        command_runner: JSONRunner | None = None,
        cleanup_process_group: CleanupProcessGroup = _default_cleanup,
    ) -> None:
        self._process_factory = process_factory
        self._line_reader_factory = line_reader_factory
        self._command_runner = (
            command_runner or source_contract.BoundedSubprocessJSONRunner()
        )
        self._cleanup_process_group = cleanup_process_group

    def run(self, device_id: str) -> Outcome:
        phase = "arguments"
        process: ProcessLike | None = None
        reader: LineReader | None = None
        launched_pid: int | None = None
        resume_confirmed = False
        outcome = Outcome("failed", phase, 64)

        try:
            launch_argv = build_launch_argv(device_id)
            lifecycle = source_contract.IOSLifecycle(self._command_runner)

            phase = "launch_suspended"
            launch_payload = self._command_runner.run_json(launch_argv)

            phase = "pid_parse"
            pid = source_contract._pid_from_result(launch_payload)  # noqa: SLF001
            launched_pid = pid
            del launch_payload

            phase = "source_spawn"
            process = self._spawn_source(build_source_argv(device_id, pid))
            if process.stdout is None:
                raise ProbeFailure(phase)
            reader = self._line_reader_factory(process.stdout)

            phase = "source_connected"
            connected = reader.readline(source_contract.IOS_READY_TIMEOUT_SECONDS)
            if connected != f"[connected:{device_id}]\n".encode("ascii"):
                raise ProbeFailure(phase)

            phase = "resume"
            lifecycle.resume(device_id, pid)
            resume_confirmed = True

            phase = "diagnostic"
            self._accept_one_diagnostic(reader)
            outcome = Outcome("accepted", "complete", 0)
        except (InvalidArguments, source_contract.InvalidArguments):
            outcome = Outcome("failed", "arguments", 64)
        except KeyboardInterrupt:
            outcome = Outcome("failed", "interrupted", 130)
        except ProbeFailure as failure:
            outcome = Outcome("failed", failure.phase, 3)
        except (
            OSError,
            TypeError,
            ValueError,
            subprocess.SubprocessError,
            source_contract.ReadTimeout,
            source_contract.SourceFailure,
        ):
            outcome = Outcome("failed", phase, 3)
        except Exception:
            outcome = Outcome("failed", phase, 3)
        finally:
            # Suppress process-directed interrupts only while releasing the
            # exact capabilities acquired above.  If an interrupt established
            # the preliminary outcome, keep it unless cleanup itself is
            # unproven.  Synthetic BaseException injection is still caught at
            # each boundary so no later cleanup step is skipped.
            cleanup_failed = False
            cleanup_interrupted = False
            prior_mask: set[signal.Signals] | None = None
            try:
                prior_mask = _suppress_cleanup_interrupts()
            except KeyboardInterrupt:
                # _interrupt has already changed both dispositions to ignore,
                # so cleanup can still be exhausted without a signal mask.
                cleanup_interrupted = True
            except BaseException:
                cleanup_failed = True

            if launched_pid is not None and not resume_confirmed:
                try:
                    self._terminate_launched_pid(device_id, launched_pid)
                except BaseException:
                    cleanup_failed = True

            if process is not None:
                try:
                    cleanup = self._cleanup_process_group(process)
                    cleanup_ok = cleanup in {"terminated", "killed"}
                    if cleanup == "not_needed":
                        cleanup_ok = process.poll() == 0
                    if not cleanup_ok:
                        cleanup_failed = True
                except BaseException:
                    cleanup_failed = True

            if reader is not None:
                try:
                    reader.close()
                except BaseException:
                    cleanup_failed = True

            if process is not None:
                if process.stdout is not None:
                    try:
                        process.stdout.close()
                    except BaseException:
                        cleanup_failed = True

            try:
                _restore_interrupt_mask(prior_mask)
            except KeyboardInterrupt:
                cleanup_interrupted = True
            except BaseException:
                cleanup_failed = True
            if cleanup_failed:
                outcome = Outcome("failed", "cleanup", 3)
            elif cleanup_interrupted:
                outcome = Outcome("failed", "interrupted", 130)

        return outcome

    def _spawn_source(self, argv: tuple[str, ...]) -> ProcessLike:
        return self._process_factory(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            shell=False,
            close_fds=True,
            start_new_session=True,
            bufsize=0,
            env=source_contract._safe_child_env(),  # noqa: SLF001
        )

    def _terminate_launched_pid(self, device_id: str, pid: int) -> None:
        payload = self._command_runner.run_json(
            build_terminate_argv(device_id, pid)
        )
        result = source_contract._devicectl_success_result(payload)  # noqa: SLF001
        if (
            "processIdentifier" in result
            and source_contract._pid_from_result(payload) != pid  # noqa: SLF001
        ):
            raise ProbeFailure("cleanup")

    def _accept_one_diagnostic(self, reader: LineReader) -> None:
        line = reader.readline(DIAGNOSTIC_TIMEOUT_SECONDS)
        if line.count(DIAGNOSTIC_MARKER) != 1:
            raise ProbeFailure("diagnostic")
        prefix, suffix = line.split(DIAGNOSTIC_MARKER, 1)
        source_contract._validate_ios_prefix(prefix)  # noqa: SLF001
        if suffix != DIAGNOSTIC_SUFFIX:
            raise ProbeFailure("diagnostic")

        # The native diagnostic coalesces duplicate opens.  Hold the exact
        # filtered PID source for one short bounded guard so an immediate
        # duplicate or any second allowlisted line cannot be called accepted.
        try:
            duplicate = reader.readline(DUPLICATE_GUARD_SECONDS)
        except source_contract.ReadTimeout:
            return
        if duplicate != b"":
            raise ProbeFailure("diagnostic")
        # EOF is also ambiguous: the source must still be live when accepted.
        raise ProbeFailure("diagnostic")

    def __repr__(self) -> str:
        return "ScannerBoundaryProbeRunner(device=<external>, source=<bounded>)"


def _parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--device", required=True, action=StoreOnceAction)
    return parser


def disable_process_artifacts() -> None:
    sys.dont_write_bytecode = True
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except (OSError, ValueError):
        raise InvalidArguments from None


def _fixed_status(output: TextIO, outcome: Outcome) -> None:
    payload = {
        "phase": outcome.phase,
        "runner": RUNNER_NAME,
        "status": outcome.status,
    }
    try:
        output.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
        output.flush()
    except (BrokenPipeError, OSError, ValueError):
        return


def main(argv: Sequence[str] | None = None) -> int:
    try:
        disable_process_artifacts()
        args = _parser().parse_args(argv)
        outcome = ScannerBoundaryProbeRunner().run(args.device)
    except (InvalidArguments, TypeError, ValueError):
        outcome = Outcome("failed", "arguments", 64)
    except KeyboardInterrupt:
        outcome = Outcome("failed", "interrupted", 130)
    except Exception:
        outcome = Outcome("failed", "arguments", 64)
    _fixed_status(sys.stderr, outcome)
    return outcome.exit_code


def _interrupt(_signum: int, _frame: object) -> None:
    for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(interrupt_signal, signal.SIG_IGN)
        except (OSError, ValueError):
            pass
    raise KeyboardInterrupt


if __name__ == "__main__":
    try:
        for interrupt_signal in (signal.SIGINT, signal.SIGTERM):
            signal.signal(interrupt_signal, _interrupt)
        raise SystemExit(main())
    except KeyboardInterrupt:
        interrupted = Outcome("failed", "interrupted", 130)
        _fixed_status(sys.stderr, interrupted)
        raise SystemExit(interrupted.exit_code) from None
