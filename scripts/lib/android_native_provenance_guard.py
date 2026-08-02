#!/usr/bin/env python3
"""Fail closed when an Android app's native runtime is not the reviewed APK.

The guard is intentionally read-only.  It compares the allowlisted ARMv7 native
library in a caller-supplied reviewed APK with the same library in the device's
installed base APK.  Child output, identifiers, paths, and digests never cross
the process boundary: the only public value is a fixed-schema classification.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Protocol, Sequence, TextIO


sys.dont_write_bytecode = True

COMPONENT = "casein_android_native_provenance_guard"
SCHEMA_VERSION = 1
ANDROID_PACKAGE = "com.example.casein_mob"
NATIVE_MEMBER = "lib/armeabi-v7a/libcasein_mob.so"
REQUIRED_NATIVE_MARKERS = (b"tcp_connect_started", b"tcp_connected")

MAX_PM_PATH_BYTES = 16 * 1024
MAX_APK_BYTES = 512 * 1024 * 1024
MAX_NATIVE_LIB_BYTES = 128 * 1024 * 1024
COMMAND_TIMEOUT_SECONDS = 90.0
PROCESS_TERM_TIMEOUT_SECONDS = 1.0
PROCESS_KILL_TIMEOUT_SECONDS = 1.0
POLL_SECONDS = 0.05

_SERIAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_BASE_APK_RE = re.compile(r"^/data/app/[A-Za-z0-9._~+=/@%:-]+/base\.apk$")

STATUSES = frozenset(
    {
        "exact",
        "invalid_arguments",
        "expected_apk_invalid",
        "expected_native_lib_missing",
        "expected_schema_stale",
        "device_query_failed",
        "device_query_limited",
        "installed_base_missing",
        "installed_base_ambiguous",
        "installed_base_invalid",
        "installed_apk_unavailable",
        "installed_apk_limited",
        "installed_apk_invalid",
        "installed_native_lib_missing",
        "installed_schema_stale",
        "digest_mismatch",
        "extension_failed",
        "cleanup_failed",
        "internal_error",
    }
)

EXIT_CODES = {
    "exact": 0,
    "invalid_arguments": 64,
    "cleanup_failed": 74,
    "internal_error": 70,
}


class InvalidArguments(Exception):
    """An input was rejected without retaining or reflecting it."""


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        raise InvalidArguments


@dataclass(frozen=True, slots=True, repr=False)
class CommandResult:
    category: str
    returncode: int | None = None
    stdout: bytes = b""


class CommandRunner(Protocol):
    def run(
        self,
        argv: tuple[str, ...],
        *,
        stdout_limit: int,
        timeout_seconds: float,
        artifact_path: Path | None = None,
        artifact_limit: int | None = None,
    ) -> CommandResult: ...


@dataclass(frozen=True, slots=True, repr=False)
class ExtensionVerdict:
    applied: bool
    passed: bool


class RuntimeProvenanceExtension(Protocol):
    """Typed seam for a future bounded BEAM-manifest comparison."""

    def verify(self, expected_apk: Path, installed_apk: Path) -> ExtensionVerdict: ...


@dataclass(frozen=True, slots=True, repr=False)
class GuardResult:
    status: str
    expected_native_lib_present: bool = False
    expected_schema_complete: bool = False
    base_apk_unique: bool = False
    installed_apk_readable: bool = False
    installed_native_lib_present: bool = False
    installed_schema_complete: bool = False
    native_digest_match: bool = False
    extension_applied: bool = False
    extension_passed: bool = False

    def __post_init__(self) -> None:
        if self.status not in STATUSES:
            object.__setattr__(self, "status", "internal_error")

    @property
    def exact(self) -> bool:
        return self.status == "exact"

    def public(self) -> Mapping[str, object]:
        return {
            "schema_version": SCHEMA_VERSION,
            "component": COMPONENT,
            "status": self.status,
            "expected_native_lib_present": self.expected_native_lib_present,
            "expected_schema_complete": self.expected_schema_complete,
            "base_apk_unique": self.base_apk_unique,
            "installed_apk_readable": self.installed_apk_readable,
            "installed_native_lib_present": self.installed_native_lib_present,
            "installed_schema_complete": self.installed_schema_complete,
            "native_digest_match": self.native_digest_match,
            "extension_applied": self.extension_applied,
            "extension_passed": self.extension_passed,
            "exact": self.exact,
        }


@dataclass(frozen=True, slots=True, repr=False)
class NativeLibrary:
    category: str
    digest: bytes | None = None
    schema_complete: bool = False


class SubprocessCommandRunner:
    """Bounded argv-only subprocess runner with discarded stderr."""

    def run(
        self,
        argv: tuple[str, ...],
        *,
        stdout_limit: int,
        timeout_seconds: float,
        artifact_path: Path | None = None,
        artifact_limit: int | None = None,
    ) -> CommandResult:
        if (
            not argv
            or stdout_limit < 0
            or timeout_seconds <= 0
            or (artifact_path is None) != (artifact_limit is None)
            or (artifact_limit is not None and artifact_limit <= 0)
        ):
            return CommandResult("failed")

        stdout_target: int = subprocess.DEVNULL
        if stdout_limit:
            stdout_target = subprocess.PIPE

        try:
            process = subprocess.Popen(
                list(argv),
                stdin=subprocess.DEVNULL,
                stdout=stdout_target,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                start_new_session=True,
                shell=False,
            )
        except (OSError, ValueError):
            return CommandResult("failed")

        selector: selectors.BaseSelector | None = None
        collected = bytearray()
        deadline = time.monotonic() + timeout_seconds
        category = "ok"

        try:
            if process.stdout is not None:
                os.set_blocking(process.stdout.fileno(), False)
                selector = selectors.DefaultSelector()
                selector.register(process.stdout, selectors.EVENT_READ)

            while process.poll() is None:
                if time.monotonic() >= deadline:
                    category = "timeout"
                    break

                if artifact_path is not None and artifact_limit is not None:
                    try:
                        if (
                            artifact_path.exists()
                            and artifact_path.stat().st_size > artifact_limit
                        ):
                            category = "artifact_limit"
                            break
                    except OSError:
                        category = "failed"
                        break

                if selector is not None:
                    remaining = max(0.0, deadline - time.monotonic())
                    if selector.select(min(POLL_SECONDS, remaining)):
                        if not _read_bounded(process.stdout, collected, stdout_limit):
                            category = "output_limit"
                            break
                else:
                    time.sleep(min(POLL_SECONDS, max(0.0, deadline - time.monotonic())))

            if category == "ok" and process.stdout is not None:
                if not _drain_bounded(process.stdout, collected, stdout_limit):
                    category = "output_limit"

            if category != "ok":
                _terminate_process_group(process)

            try:
                returncode = process.wait(timeout=PROCESS_TERM_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                _kill_process_group(process)
                try:
                    returncode = process.wait(timeout=PROCESS_KILL_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    returncode = None
                    category = "failed"

            if category == "ok" and artifact_path is not None and artifact_limit is not None:
                try:
                    if artifact_path.exists() and artifact_path.stat().st_size > artifact_limit:
                        category = "artifact_limit"
                except OSError:
                    category = "failed"

            return CommandResult(category, returncode, bytes(collected))
        finally:
            if selector is not None:
                selector.close()
            if process.stdout is not None:
                process.stdout.close()


def _read_bounded(stream: object, collected: bytearray, limit: int) -> bool:
    if limit <= 0:
        return True
    try:
        chunk = os.read(stream.fileno(), min(4096, limit + 1 - len(collected)))
    except (BlockingIOError, OSError):
        return True
    collected.extend(chunk)
    return len(collected) <= limit


def _drain_bounded(stream: object, collected: bytearray, limit: int) -> bool:
    """Drain an exited child's pipe through EOF or the first over-limit byte."""

    if limit <= 0:
        return True

    while True:
        read_size = min(4096, limit + 1 - len(collected))
        if read_size <= 0:
            return False
        try:
            chunk = os.read(stream.fileno(), read_size)
        except (BlockingIOError, OSError):
            return False
        if not chunk:
            return True
        collected.extend(chunk)
        if len(collected) > limit:
            return False


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        return


def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        return


def build_pm_path_argv(serial: str, package: str) -> tuple[str, ...]:
    _validate_serial(serial)
    _validate_package(package)
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "shell",
        "pm",
        "path",
        package,
    )


def build_pull_argv(serial: str, remote_path: str, destination: Path) -> tuple[str, ...]:
    _validate_serial(serial)
    _validate_base_apk_path(remote_path)
    if not destination.is_absolute() or destination.name != "installed-base.apk":
        raise InvalidArguments
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "pull",
        remote_path,
        str(destination),
    )


def verify_android_native_provenance(
    serial: str,
    package: str,
    expected_apk: Path,
    *,
    runner: CommandRunner | None = None,
    temp_factory: Callable[[], Path] | None = None,
    cleanup: Callable[[Path], bool] | None = None,
    extension: RuntimeProvenanceExtension | None = None,
) -> GuardResult:
    """Compare the reviewed and installed ARMv7 runtimes without device mutation."""

    runner = runner or SubprocessCommandRunner()
    temp_factory = temp_factory or _make_temp_dir
    cleanup = cleanup or _cleanup_temp_dir

    try:
        build_pm_path_argv(serial, package)
        expected_apk = _validate_expected_apk(expected_apk)
    except (InvalidArguments, OSError, ValueError):
        return GuardResult("invalid_arguments")

    expected = _native_library(expected_apk)
    if expected.category == "missing":
        return GuardResult("expected_native_lib_missing")
    if expected.category != "ok":
        return GuardResult("expected_apk_invalid")
    if not expected.schema_complete:
        return GuardResult(
            "expected_schema_stale",
            expected_native_lib_present=True,
        )

    query = runner.run(
        build_pm_path_argv(serial, package),
        stdout_limit=MAX_PM_PATH_BYTES,
        timeout_seconds=COMMAND_TIMEOUT_SECONDS,
    )
    common = {
        "expected_native_lib_present": True,
        "expected_schema_complete": True,
    }
    if query.category == "output_limit":
        return GuardResult("device_query_limited", **common)
    if query.category != "ok" or query.returncode != 0:
        return GuardResult("device_query_failed", **common)

    base_category, remote_path = _parse_base_apk_path(query.stdout)
    if base_category != "ok":
        status = {
            "missing": "installed_base_missing",
            "ambiguous": "installed_base_ambiguous",
            "invalid": "installed_base_invalid",
        }.get(base_category, "internal_error")
        return GuardResult(status, **common)

    temp_root: Path | None = None
    result = GuardResult("internal_error", base_apk_unique=True, **common)
    try:
        created_root = temp_factory()
        if (
            not isinstance(created_root, Path)
            or not created_root.is_absolute()
            or not created_root.is_dir()
        ):
            result = GuardResult("internal_error", base_apk_unique=True, **common)
        else:
            temp_root = created_root
            installed_apk = temp_root / "installed-base.apk"
            pull = runner.run(
                build_pull_argv(serial, remote_path, installed_apk),
                stdout_limit=0,
                timeout_seconds=COMMAND_TIMEOUT_SECONDS,
                artifact_path=installed_apk,
                artifact_limit=MAX_APK_BYTES,
            )
            if pull.category == "artifact_limit":
                result = GuardResult(
                    "installed_apk_limited", base_apk_unique=True, **common
                )
            elif (
                pull.category != "ok"
                or pull.returncode != 0
                or not installed_apk.is_file()
            ):
                result = GuardResult(
                    "installed_apk_unavailable", base_apk_unique=True, **common
                )
            else:
                result = _compare_installed(
                    expected_apk,
                    expected,
                    installed_apk,
                    extension,
                    common,
                )
    except (InvalidArguments, OSError, ValueError):
        result = GuardResult("internal_error", base_apk_unique=True, **common)
    finally:
        if temp_root is not None:
            try:
                cleanup_ok = cleanup(temp_root)
            except Exception:
                cleanup_ok = False
            if cleanup_ok is not True:
                result = GuardResult("cleanup_failed", base_apk_unique=True, **common)

    return result


def _compare_installed(
    expected_apk: Path,
    expected: NativeLibrary,
    installed_apk: Path,
    extension: RuntimeProvenanceExtension | None,
    common: Mapping[str, bool],
) -> GuardResult:
    installed = _native_library(installed_apk)
    installed_common = {**common, "base_apk_unique": True, "installed_apk_readable": True}
    if installed.category == "missing":
        return GuardResult("installed_native_lib_missing", **installed_common)
    if installed.category != "ok":
        return GuardResult("installed_apk_invalid", **installed_common)
    if not installed.schema_complete:
        return GuardResult(
            "installed_schema_stale",
            installed_native_lib_present=True,
            **installed_common,
        )
    if expected.digest is None or installed.digest is None or expected.digest != installed.digest:
        return GuardResult(
            "digest_mismatch",
            installed_native_lib_present=True,
            installed_schema_complete=True,
            **installed_common,
        )

    extension_applied = False
    extension_passed = False
    if extension is not None:
        try:
            verdict = extension.verify(expected_apk, installed_apk)
            if not isinstance(verdict, ExtensionVerdict):
                raise TypeError
            extension_applied = verdict.applied is True
            extension_passed = verdict.passed is True
        except Exception:
            extension_applied = True
            extension_passed = False
        if extension_applied and not extension_passed:
            return GuardResult(
                "extension_failed",
                installed_native_lib_present=True,
                installed_schema_complete=True,
                native_digest_match=True,
                extension_applied=True,
                extension_passed=False,
                **installed_common,
            )

    return GuardResult(
        "exact",
        installed_native_lib_present=True,
        installed_schema_complete=True,
        native_digest_match=True,
        extension_applied=extension_applied,
        extension_passed=extension_passed,
        **installed_common,
    )


def _native_library(apk_path: Path) -> NativeLibrary:
    try:
        info = apk_path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or info.st_size <= 0
            or info.st_size > MAX_APK_BYTES
        ):
            return NativeLibrary("invalid")

        with zipfile.ZipFile(apk_path, "r") as archive:
            members = [item for item in archive.infolist() if item.filename == NATIVE_MEMBER]
            if not members:
                return NativeLibrary("missing")
            if len(members) != 1:
                return NativeLibrary("invalid")
            member = members[0]
            if (
                member.is_dir()
                or member.flag_bits & 0x1
                or member.file_size <= 0
                or member.file_size > MAX_NATIVE_LIB_BYTES
            ):
                return NativeLibrary("invalid")
            with archive.open(member, "r") as stream:
                payload = stream.read(MAX_NATIVE_LIB_BYTES + 1)
            if len(payload) != member.file_size or len(payload) > MAX_NATIVE_LIB_BYTES:
                return NativeLibrary("invalid")
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile):
        return NativeLibrary("invalid")

    return NativeLibrary(
        "ok",
        hashlib.sha256(payload).digest(),
        all(marker in payload for marker in REQUIRED_NATIVE_MARKERS),
    )


def _parse_base_apk_path(payload: bytes) -> tuple[str, str]:
    try:
        text = payload.decode("ascii")
    except UnicodeDecodeError:
        return ("invalid", "")

    paths: list[str] = []
    for line in text.splitlines():
        if not line or not line.startswith("package:"):
            return ("invalid", "")
        path = line.removeprefix("package:")
        if path.endswith("/base.apk"):
            try:
                _validate_base_apk_path(path)
            except InvalidArguments:
                return ("invalid", "")
            paths.append(path)

    if not paths:
        return ("missing", "")
    if len(paths) != 1:
        return ("ambiguous", "")
    return ("ok", paths[0])


def _validate_serial(serial: str) -> None:
    if not isinstance(serial, str) or _SERIAL_RE.fullmatch(serial) is None:
        raise InvalidArguments


def _validate_package(package: str) -> None:
    if package != ANDROID_PACKAGE:
        raise InvalidArguments


def _validate_base_apk_path(remote_path: str) -> None:
    if not isinstance(remote_path, str) or _BASE_APK_RE.fullmatch(remote_path) is None:
        raise InvalidArguments
    parsed = PurePosixPath(remote_path)
    if not parsed.is_absolute() or ".." in parsed.parts or parsed.name != "base.apk":
        raise InvalidArguments


def _validate_expected_apk(path: Path) -> Path:
    if not isinstance(path, Path) or not path.is_absolute():
        raise InvalidArguments
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise InvalidArguments
    return path


def _make_temp_dir() -> Path:
    return Path(tempfile.mkdtemp(prefix="casein-android-provenance-"))


def _cleanup_temp_dir(path: Path) -> bool:
    try:
        shutil.rmtree(path)
    except OSError:
        return False
    return not path.exists()


def _parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(add_help=False)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--expected-apk", required=True)
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    runner: CommandRunner | None = None,
    output: TextIO | None = None,
    temp_factory: Callable[[], Path] | None = None,
    cleanup: Callable[[Path], bool] | None = None,
    extension: RuntimeProvenanceExtension | None = None,
) -> int:
    output = output or sys.stdout
    try:
        args = _parser().parse_args(argv)
        result = verify_android_native_provenance(
            args.serial,
            args.package,
            Path(args.expected_apk),
            runner=runner,
            temp_factory=temp_factory,
            cleanup=cleanup,
            extension=extension,
        )
    except (InvalidArguments, OSError, ValueError):
        result = GuardResult("invalid_arguments")
    except Exception:
        result = GuardResult("internal_error")

    try:
        output.write(json.dumps(result.public(), sort_keys=True, separators=(",", ":")))
        output.write("\n")
        output.flush()
    except (BrokenPipeError, OSError, ValueError):
        return 74
    return EXIT_CODES.get(result.status, 3)


if __name__ == "__main__":
    raise SystemExit(main())
