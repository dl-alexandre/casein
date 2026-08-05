#!/usr/bin/env python3
"""Fail closed unless installed Android app BEAMs match a reviewed runtime build.

The guard is read-only and intentionally narrow.  It compares the regular,
non-symlink ``*.beam`` files selected by ``MobDev.HotPush.runtime_beam_dirs/0``
plus the EEx and SSL roots appended by ``MobDev.Deployer`` with the flat app
BEAM directory owned by the fixed Android package.  Child output, identifiers,
paths, filenames, file bytes, and digests never cross the public boundary:
stdout is exactly one fixed-schema JSON classification.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Mapping, Protocol, Sequence, TextIO


sys.dont_write_bytecode = True

COMPONENT = "casein_android_beam_provenance_guard"
SCHEMA_VERSION = 1
ANDROID_PACKAGE = "com.example.casein_mob"
INSTALLED_BEAM_DIR = "files/otp/casein_mob"

MAX_BEAMS = 4096
MAX_SOURCE_DIRS = 512
MAX_BEAM_NAME_BYTES = 128
MAX_SOURCE_NAME_BYTES = 128
MAX_SOURCE_PATH_BYTES = 4096
MAX_INSTALLED_IDENTITY_BYTES = 96
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
READ_FRAME_OVERHEAD_BYTES = 256
MAX_RUNTIME_RESOLUTION_BYTES = 64 * 1024
MAX_BEAM_BYTES = 16 * 1024 * 1024
MAX_AGGREGATE_BEAM_BYTES = 128 * 1024 * 1024
READ_CHUNK_BYTES = 64 * 1024
COMMAND_TIMEOUT_SECONDS = 60.0
MANIFEST_TIMEOUT_BASE_SECONDS = 30.0
MANIFEST_TIMEOUT_PER_BEAM_SECONDS = 0.12
MANIFEST_TIMEOUT_MIN_SECONDS = 60.0
MANIFEST_TIMEOUT_MAX_SECONDS = 240.0
MANIFEST_IDLE_TIMEOUT_SECONDS = 15.0
PROCESS_TERM_TIMEOUT_SECONDS = 1.0
PROCESS_KILL_TIMEOUT_SECONDS = 1.0
POLL_SECONDS = 0.05

_POSIX_GROUP_API = all(
    hasattr(os, name)
    for name in ("killpg", "waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
)

_SERIAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_BEAM_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,122}\.beam$")
_SOURCE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_INSTALLED_IDENTITY_RE = re.compile(
    r"^[0-9]+:[0-9]+:[0-9a-f]+:[0-9]+:-?[0-9]+:-?[0-9]+$"
)
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_TIMEOUT_REASONS = frozenset({"none", "idle", "total"})
_MANIFEST_CAPTURE_SCOPES = frozenset({"none", "complete", "incomplete_prefix"})
_INVALID_FRAME_PATTERNS = frozenset(
    {"none", "interleaved", "suffix", "prefix", "mixed"}
)

_MANIFEST_HEADER = b"CASEIN_BEAMS_V5"
_MANIFEST_END = b"END"
_MANIFEST_STATUS_TAG = b"STATUS"
_MANIFEST_STATUSES = frozenset(
    {b"OK", b"MISSING", b"INVALID", b"LIMITED", b"CHANGED", b"HASH_FAILED"}
)
_READ_HEADER = b"CASEIN_BEAM_READ_V1\n"
_READ_DATA = b"DATA\n"
_READ_STATUS_RECORDS = {
    b"OK": b"STATUS\tOK\nEND\n",
    b"MISSING": b"STATUS\tMISSING\nEND\n",
    b"INVALID": b"STATUS\tINVALID\nEND\n",
    b"LIMITED": b"STATUS\tLIMITED\nEND\n",
    b"CHANGED": b"STATUS\tCHANGED\nEND\n",
    b"READ_FAILED": b"STATUS\tREAD_FAILED\nEND\n",
}
_RUNTIME_HEADER = b"CASEIN_RUNTIME_BEAM_DIRS_V4"

_RUNTIME_DIRS_ELIXIR = r"""
encode = fn value -> Base.url_encode64(value, padding: false) end
runtime = MobDev.HotPush.runtime_beam_dirs()
eex = Path.join(to_string(:code.lib_dir(:eex)), "ebin")
ssl = Path.join(to_string(:code.lib_dir(:ssl)), "ebin")
cache = Path.join([System.user_home!(), ".mob", "cache"])
real_crypto =
  Path.wildcard(Path.join([cache, "otp-*", "lib", "crypto-*", "ebin", "crypto.beam"]))
  |> Enum.any?()

IO.binwrite("CASEIN_RUNTIME_BEAM_DIRS_V4\n")
Enum.each(runtime, fn path ->
  IO.binwrite(["RUNTIME\t", encode.(Path.expand(path)), "\n"])
end)
IO.binwrite(["EEX\t", encode.(Path.expand(eex)), "\n"])
IO.binwrite(["SSL\t", encode.(Path.expand(ssl)), "\n"])
IO.binwrite(["CRYPTO\t", if(real_crypto, do: "REAL", else: "SHIM_REQUIRED"), "\n"])
IO.binwrite("END\n")
"""

# The script is fixed program text.  The serial and package are separate,
# validated argv elements; no caller value is interpolated into this program.
_MANIFEST_SCRIPT = f"""\
exec 2>/dev/null
finish() {{
  printf 'STATUS\\t%s\\nEND\\n' "$1"
  exit 0
}}
dir='{INSTALLED_BEAM_DIR}'
printf 'CASEIN_BEAMS_V5\\n' || exit 0
[ -d \"$dir\" ] || finish MISSING
count=0
found=0
for path in \"$dir\"/*.beam \"$dir\"/.*.beam; do
  [ -e \"$path\" ] || [ -L \"$path\" ] || continue
  found=1
  [ -f \"$path\" ] && [ ! -L \"$path\" ] || finish INVALID
  count=$((count + 1))
  [ \"$count\" -le {MAX_BEAMS} ] || finish LIMITED
  name=${{path##*/}}
  before=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || finish CHANGED
  exec 3<\"$path\" || finish CHANGED
  [ \"$path\" -ef \"/proc/$$/fd/3\" ] || finish CHANGED
  after_open=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || finish CHANGED
  [ -f \"$path\" ] && [ ! -L \"$path\" ] || finish CHANGED
  [ \"$before\" = \"$after_open\" ] || finish CHANGED
  opened=\"$after_open\"
  digest_line=$(sha256sum <&3) || finish HASH_FAILED
  digest=${{digest_line%% *}}
  [ \"$path\" -ef \"/proc/$$/fd/3\" ] || finish CHANGED
  after_path=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || finish CHANGED
  [ -f \"$path\" ] && [ ! -L \"$path\" ] || finish CHANGED
  [ \"$after_path\" = \"$opened\" ] || finish CHANGED
  exec 3<&-
  printf '%s\\t%s\\t%s\\n' \"$name\" \"$opened\" \"$digest\"
done
[ \"$found\" -eq 1 ] || finish MISSING
finish OK
"""

_READ_SCRIPT = f"""\
exec 2>/dev/null
finish() {{
  printf 'STATUS\\t%s\\nEND\\n' "$1"
  exit 0
}}
finish_data() {{
  printf '\\nSTATUS\\t%s\\nEND\\n' "$1"
  exit 0
}}
dir='{INSTALLED_BEAM_DIR}'
path="$dir/$1"
expected="$2"
printf 'CASEIN_BEAM_READ_V1\\n' || exit 0
[ -e \"$path\" ] || [ -L \"$path\" ] || finish MISSING
[ -f \"$path\" ] && [ ! -L \"$path\" ] || finish INVALID
rest=${{expected#*:}}
rest=${{rest#*:}}
rest=${{rest#*:}}
expected_size=${{rest%%:*}}
[ \"$expected_size\" -gt 0 ] && [ \"$expected_size\" -le {MAX_BEAM_BYTES} ] || finish LIMITED
before=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || finish MISSING
exec 3<\"$path\" || finish MISSING
[ \"$path\" -ef \"/proc/$$/fd/3\" ] || finish INVALID
after_open=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || finish CHANGED
[ -f \"$path\" ] && [ ! -L \"$path\" ] || finish CHANGED
[ \"$expected\" = \"$before\" ] &&
  [ \"$before\" = \"$after_open\" ] || finish CHANGED
opened=\"$after_open\"
printf 'DATA\\n' || exit 0
cat <&3 || finish_data READ_FAILED
[ \"$path\" -ef \"/proc/$$/fd/3\" ] || finish_data CHANGED
after_path=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || finish_data CHANGED
[ -f \"$path\" ] && [ ! -L \"$path\" ] || finish_data CHANGED
[ \"$after_path\" = \"$opened\" ] || finish_data CHANGED
exec 3<&-
finish_data OK
"""

STATUSES = frozenset(
    {
        "exact",
        "invalid_arguments",
        "expected_manifest_missing",
        "expected_manifest_unsafe_name",
        "expected_manifest_symlink",
        "expected_manifest_invalid_entry",
        "expected_manifest_limited",
        "expected_manifest_read_failed",
        "expected_manifest_collision",
        "expected_runtime_resolution_failed",
        "expected_runtime_resolution_malformed",
        "expected_runtime_unsupported",
        "installed_manifest_failed",
        "installed_manifest_missing",
        "installed_manifest_invalid_entry",
        "installed_manifest_limited",
        "installed_manifest_malformed",
        "installed_manifest_duplicate",
        "installed_manifest_unsafe_name",
        "installed_manifest_changed",
        "beam_name_set_mismatch",
        "installed_beam_missing",
        "installed_beam_invalid_entry",
        "installed_beam_failed",
        "installed_beam_limited",
        "installed_beam_invalid",
        "installed_beam_changed",
        "beam_digest_mismatch",
        "internal_error",
    }
)

EXIT_CODES = {
    "exact": 0,
    "invalid_arguments": 64,
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
    timeout_reason: str = "none"


class CommandRunner(Protocol):
    def run(
        self,
        argv: tuple[str, ...],
        *,
        stdout_limit: int,
        timeout_seconds: float,
        idle_timeout_seconds: float | None = None,
        cwd: Path | None = None,
        env_overrides: Mapping[str, str] | None = None,
    ) -> CommandResult: ...


@dataclass(frozen=True, slots=True, repr=False)
class GuardResult:
    status: str
    expected_manifest_valid: bool = False
    installed_manifest_complete: bool = False
    beam_name_set_match: bool = False
    beam_digest_match: bool = False
    timeout_reason: str = "none"
    completed_record_count: int = 0
    valid_record_count: int = 0
    unique_name_count: int = 0
    duplicate_name_count: int = 0
    expected_name_match_count: int = 0
    unexpected_name_count: int = 0
    missing_name_count: int = 0
    manifest_capture_scope: str = "none"
    invalid_field_count: int = 0
    invalid_name_encoding_or_grammar_count: int = 0
    invalid_digest_shape_count: int = 0
    invalid_numeric_or_stat_count: int = 0
    invalid_control_or_other_count: int = 0
    invalid_frame_pattern: str = "none"

    def __post_init__(self) -> None:
        if self.status not in STATUSES:
            object.__setattr__(self, "status", "internal_error")
        if self.timeout_reason not in _TIMEOUT_REASONS:
            object.__setattr__(self, "timeout_reason", "none")
        if self.manifest_capture_scope not in _MANIFEST_CAPTURE_SCOPES:
            object.__setattr__(self, "manifest_capture_scope", "none")
        if self.invalid_frame_pattern not in _INVALID_FRAME_PATTERNS:
            object.__setattr__(self, "invalid_frame_pattern", "none")
        for field_name in (
            "completed_record_count",
            "valid_record_count",
            "unique_name_count",
            "duplicate_name_count",
            "expected_name_match_count",
            "unexpected_name_count",
            "missing_name_count",
            "invalid_field_count",
            "invalid_name_encoding_or_grammar_count",
            "invalid_digest_shape_count",
            "invalid_numeric_or_stat_count",
            "invalid_control_or_other_count",
        ):
            value = getattr(self, field_name)
            if (
                not isinstance(value, int)
                or isinstance(value, bool)
                or not 0 <= value <= MAX_BEAMS
            ):
                object.__setattr__(self, field_name, 0)
        if self.exact:
            object.__setattr__(self, "timeout_reason", "none")
            object.__setattr__(self, "manifest_capture_scope", "none")
            for field_name in (
                "completed_record_count",
                "valid_record_count",
                "unique_name_count",
                "duplicate_name_count",
                "expected_name_match_count",
                "unexpected_name_count",
                "missing_name_count",
                "invalid_field_count",
                "invalid_name_encoding_or_grammar_count",
                "invalid_digest_shape_count",
                "invalid_numeric_or_stat_count",
                "invalid_control_or_other_count",
            ):
                object.__setattr__(self, field_name, 0)
            object.__setattr__(self, "invalid_frame_pattern", "none")

    @property
    def exact(self) -> bool:
        return self.status == "exact"

    def public(self) -> Mapping[str, object]:
        return {
            "schema_version": SCHEMA_VERSION,
            "component": COMPONENT,
            "status": self.status,
            "expected_manifest_valid": self.expected_manifest_valid,
            "installed_manifest_complete": self.installed_manifest_complete,
            "beam_name_set_match": self.beam_name_set_match,
            "beam_digest_match": self.beam_digest_match,
            "timeout_reason": self.timeout_reason,
            "completed_record_count": self.completed_record_count,
            "valid_record_count": self.valid_record_count,
            "unique_name_count": self.unique_name_count,
            "duplicate_name_count": self.duplicate_name_count,
            "expected_name_match_count": self.expected_name_match_count,
            "unexpected_name_count": self.unexpected_name_count,
            "missing_name_count": self.missing_name_count,
            "manifest_capture_scope": self.manifest_capture_scope,
            "invalid_field_count": self.invalid_field_count,
            "invalid_name_encoding_or_grammar_count": (
                self.invalid_name_encoding_or_grammar_count
            ),
            "invalid_digest_shape_count": self.invalid_digest_shape_count,
            "invalid_numeric_or_stat_count": self.invalid_numeric_or_stat_count,
            "invalid_control_or_other_count": self.invalid_control_or_other_count,
            "invalid_frame_pattern": self.invalid_frame_pattern,
            "exact": self.exact,
        }


@dataclass(frozen=True, slots=True, repr=False)
class ManifestDiagnostics:
    timeout_reason: str = "none"
    completed_record_count: int = 0
    valid_record_count: int = 0
    unique_name_count: int = 0
    duplicate_name_count: int = 0
    expected_name_match_count: int = 0
    unexpected_name_count: int = 0
    missing_name_count: int = 0
    manifest_capture_scope: str = "none"
    invalid_field_count: int = 0
    invalid_name_encoding_or_grammar_count: int = 0
    invalid_digest_shape_count: int = 0
    invalid_numeric_or_stat_count: int = 0
    invalid_control_or_other_count: int = 0
    invalid_frame_pattern: str = "none"

    def guard_fields(self) -> dict[str, object]:
        return {
            "timeout_reason": self.timeout_reason,
            "completed_record_count": self.completed_record_count,
            "valid_record_count": self.valid_record_count,
            "unique_name_count": self.unique_name_count,
            "duplicate_name_count": self.duplicate_name_count,
            "expected_name_match_count": self.expected_name_match_count,
            "unexpected_name_count": self.unexpected_name_count,
            "missing_name_count": self.missing_name_count,
            "manifest_capture_scope": self.manifest_capture_scope,
            "invalid_field_count": self.invalid_field_count,
            "invalid_name_encoding_or_grammar_count": (
                self.invalid_name_encoding_or_grammar_count
            ),
            "invalid_digest_shape_count": self.invalid_digest_shape_count,
            "invalid_numeric_or_stat_count": self.invalid_numeric_or_stat_count,
            "invalid_control_or_other_count": self.invalid_control_or_other_count,
            "invalid_frame_pattern": self.invalid_frame_pattern,
        }


@dataclass(frozen=True, slots=True, repr=False)
class LocalManifest:
    category: str
    digests: Mapping[str, bytes]


@dataclass(frozen=True, slots=True, repr=False)
class RuntimeSources:
    category: str
    roots: tuple[Path, ...] = ()


@dataclass(frozen=True, slots=True, repr=False)
class InstalledEntry:
    identity: str
    digest: bytes


@dataclass(frozen=True, slots=True, repr=False)
class InstalledManifest:
    category: str
    entries: Mapping[str, InstalledEntry]

    @property
    def names(self) -> frozenset[str]:
        return frozenset(self.entries)


@dataclass(frozen=True, slots=True, repr=False)
class InstalledRead:
    category: str
    payload: bytes = b""


@dataclass(frozen=True, slots=True, repr=False)
class FileIdentity:
    device: int
    inode: int
    mode: int
    size: int
    modified_ns: int
    changed_ns: int


class SubprocessCommandRunner:
    """Bounded argv-only subprocess runner with discarded stderr."""

    def run(
        self,
        argv: tuple[str, ...],
        *,
        stdout_limit: int,
        timeout_seconds: float,
        idle_timeout_seconds: float | None = None,
        cwd: Path | None = None,
        env_overrides: Mapping[str, str] | None = None,
    ) -> CommandResult:
        if (
            not argv
            or stdout_limit <= 0
            or timeout_seconds <= 0
            or (idle_timeout_seconds is not None and idle_timeout_seconds <= 0)
        ):
            return CommandResult("failed")
        if not _POSIX_GROUP_API:
            return CommandResult("failed")

        environment = None
        if env_overrides:
            environment = os.environ.copy()
            environment.update(env_overrides)

        try:
            process = subprocess.Popen(
                list(argv),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                start_new_session=True,
                shell=False,
                cwd=cwd,
                env=environment,
            )
        except (OSError, ValueError):
            return CommandResult("failed")

        selector: selectors.BaseSelector | None = None
        collected = bytearray()
        deadline = time.monotonic() + timeout_seconds
        idle_deadline = (
            time.monotonic() + idle_timeout_seconds
            if idle_timeout_seconds is not None
            else None
        )
        category = "ok"
        timeout_reason = "none"
        reaped = False

        try:
            if process.stdout is None:
                _terminate_process_group(process)
                _wait_for_process_exit_unreaped(
                    process, PROCESS_TERM_TIMEOUT_SECONDS
                )
                _kill_process_group(process)
                try:
                    returncode = process.wait(timeout=PROCESS_KILL_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    returncode = None
                reaped = returncode is not None
                return CommandResult("failed", returncode)

            os.set_blocking(process.stdout.fileno(), False)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)

            while not _process_exited_unreaped(process):
                now = time.monotonic()
                if now >= deadline:
                    category = "timeout"
                    timeout_reason = "total"
                    break
                if idle_deadline is not None and now >= idle_deadline:
                    category = "timeout"
                    timeout_reason = "idle"
                    break

                remaining = max(0.0, deadline - now)
                if idle_deadline is not None:
                    remaining = min(remaining, max(0.0, idle_deadline - now))
                if selector.select(min(POLL_SECONDS, remaining)):
                    before_read = len(collected)
                    if not _read_bounded(process.stdout, collected, stdout_limit):
                        category = "output_limit"
                        break
                    if (
                        idle_timeout_seconds is not None
                        and len(collected) > before_read
                    ):
                        idle_deadline = time.monotonic() + idle_timeout_seconds

            if category == "ok":
                category = _drain_bounded(process.stdout, collected, stdout_limit)

            if category != "ok":
                _terminate_process_group(process)
                _wait_for_process_exit_unreaped(
                    process, PROCESS_TERM_TIMEOUT_SECONDS
                )

            # Signal while the unreaped leader still anchors ownership of this
            # numeric process-group id.  This also removes silent descendants
            # after a normal or nonzero leader exit without a PGID-reuse race.
            _kill_process_group(process)
            try:
                returncode = process.wait(timeout=PROCESS_KILL_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                returncode = None
                category = "failed"
            reaped = returncode is not None

            return CommandResult(
                category, returncode, bytes(collected), timeout_reason
            )
        except (OSError, ValueError):
            return CommandResult("failed")
        finally:
            if not reaped:
                _terminate_process_group(process)
                try:
                    _wait_for_process_exit_unreaped(
                        process, PROCESS_TERM_TIMEOUT_SECONDS
                    )
                except OSError:
                    pass
                _kill_process_group(process)
                try:
                    process.wait(timeout=PROCESS_KILL_TIMEOUT_SECONDS)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            if selector is not None:
                try:
                    selector.close()
                except OSError:
                    pass
            if process.stdout is not None:
                try:
                    process.stdout.close()
                except OSError:
                    pass


def _read_bounded(stream: object, collected: bytearray, limit: int) -> bool:
    try:
        chunk = os.read(stream.fileno(), min(4096, limit + 1 - len(collected)))
    except BlockingIOError:
        return True
    except OSError:
        return False
    collected.extend(chunk)
    return len(collected) <= limit


def _drain_bounded(stream: object, collected: bytearray, limit: int) -> str:
    """Drain an exited child's pipe through EOF or the first over-limit byte."""

    while True:
        read_size = min(4096, limit + 1 - len(collected))
        if read_size <= 0:
            return "output_limit"
        try:
            chunk = os.read(stream.fileno(), read_size)
        except BlockingIOError:
            # The group leader exited while another group member retained the
            # pipe.  Treat missing EOF as failure, then bound the whole group.
            return "failed"
        except OSError:
            return "failed"
        if not chunk:
            return "ok"
        collected.extend(chunk)
        if len(collected) > limit:
            return "output_limit"


def _process_exited_unreaped(process: subprocess.Popen[bytes]) -> bool:
    if process.returncode is not None:
        return True
    try:
        info = os.waitid(
            os.P_PID,
            process.pid,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
    except ChildProcessError:
        return True
    return info is not None


def _wait_for_process_exit_unreaped(
    process: subprocess.Popen[bytes], timeout_seconds: float
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if _process_exited_unreaped(process):
            return True
        time.sleep(min(POLL_SECONDS, max(0.0, deadline - time.monotonic())))
    return _process_exited_unreaped(process)


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        return


def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        return


def build_manifest_argv(serial: str, package: str) -> tuple[str, ...]:
    _validate_serial(serial)
    _validate_package(package)
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "exec-out",
        "run-as",
        ANDROID_PACKAGE,
        "sh",
        "-c",
        _MANIFEST_SCRIPT,
    )


def build_read_argv(
    serial: str,
    package: str,
    beam_name: str,
    expected_identity: str,
) -> tuple[str, ...]:
    _validate_serial(serial)
    _validate_package(package)
    _validate_beam_name(beam_name)
    _validate_installed_identity(expected_identity)
    return (
        "adb",
        "--exit-on-write-error",
        "-s",
        serial,
        "exec-out",
        "run-as",
        ANDROID_PACKAGE,
        "sh",
        "-c",
        _READ_SCRIPT,
        "casein-beam-read",
        beam_name,
        expected_identity,
    )


def build_runtime_resolution_argv() -> tuple[str, ...]:
    return (
        "mise",
        "exec",
        "--",
        "mix",
        "run",
        "--no-start",
        "--no-compile",
        "--no-deps-check",
        "-e",
        _RUNTIME_DIRS_ELIXIR,
    )


def verify_android_beam_provenance(
    serial: str,
    package: str,
    expected_build_lib_root: Path,
    *,
    runner: CommandRunner | None = None,
) -> GuardResult:
    """Compare reviewed and installed app BEAM sets without device mutation."""

    try:
        return _verify_android_beam_provenance(
            serial,
            package,
            expected_build_lib_root,
            runner=runner,
        )
    except Exception:
        return GuardResult("internal_error")


def _verify_android_beam_provenance(
    serial: str,
    package: str,
    expected_build_lib_root: Path,
    *,
    runner: CommandRunner | None = None,
) -> GuardResult:

    runner = runner or SubprocessCommandRunner()
    try:
        build_manifest_argv(serial, package)
        expected_build_lib_root = _validate_expected_build_lib_root(
            expected_build_lib_root
        )
    except (InvalidArguments, OSError, ValueError):
        return GuardResult("invalid_arguments")

    sources = _resolve_runtime_sources(expected_build_lib_root, runner)
    if sources.category != "ok":
        status = {
            "failed": "expected_runtime_resolution_failed",
            "malformed": "expected_runtime_resolution_malformed",
            "unsupported": "expected_runtime_unsupported",
        }.get(sources.category, "internal_error")
        return GuardResult(status)

    expected = _read_flat_local_manifest(sources.roots)
    if expected.category != "ok":
        status = {
            "missing": "expected_manifest_missing",
            "unsafe_name": "expected_manifest_unsafe_name",
            "symlink": "expected_manifest_symlink",
            "invalid_entry": "expected_manifest_invalid_entry",
            "limited": "expected_manifest_limited",
            "read_failed": "expected_manifest_read_failed",
            "collision": "expected_manifest_collision",
        }.get(expected.category, "internal_error")
        return GuardResult(status)

    common = {"expected_manifest_valid": True}
    expected_names = frozenset(expected.digests)
    status, installed, diagnostics = _read_installed_manifest(
        serial, package, runner, expected_names
    )
    if status != "ok" or installed is None:
        return GuardResult(
            status,
            **diagnostics.guard_fields(),
            **common,
        )

    complete = {**common, "installed_manifest_complete": True}
    if installed.names != expected_names:
        return GuardResult(
            "beam_name_set_mismatch",
            **diagnostics.guard_fields(),
            **complete,
        )

    matched = {**complete, "beam_name_set_match": True}
    for beam_name in sorted(expected_names):
        if not hmac.compare_digest(
            installed.entries[beam_name].digest,
            expected.digests[beam_name],
        ):
            return GuardResult("beam_digest_mismatch", **matched)

    installed_total = 0
    for beam_name in sorted(expected_names):
        expected_size = _validate_installed_identity(
            installed.entries[beam_name].identity
        )
        read_result = runner.run(
            build_read_argv(
                serial,
                package,
                beam_name,
                installed.entries[beam_name].identity,
            ),
            stdout_limit=MAX_BEAM_BYTES + READ_FRAME_OVERHEAD_BYTES,
            timeout_seconds=COMMAND_TIMEOUT_SECONDS,
        )
        if read_result.category == "output_limit":
            return GuardResult("installed_beam_limited", **matched)
        if read_result.category != "ok":
            return GuardResult("installed_beam_failed", **matched)
        if read_result.returncode != 0:
            return GuardResult("installed_beam_failed", **matched)

        installed_read = _parse_installed_read(read_result.stdout, expected_size)
        if installed_read.category == "size_mismatch":
            if (
                installed_total + len(installed_read.payload)
                > MAX_AGGREGATE_BEAM_BYTES
            ):
                return GuardResult("installed_beam_limited", **matched)
            return GuardResult("installed_beam_invalid", **matched)
        if installed_read.category != "ok":
            status = {
                "missing": "installed_beam_missing",
                "invalid_entry": "installed_beam_invalid_entry",
                "limited": "installed_beam_limited",
                "changed": "installed_beam_changed",
                "read_failed": "installed_beam_failed",
                "malformed": "installed_beam_invalid",
            }.get(installed_read.category, "internal_error")
            return GuardResult(status, **matched)

        installed_total += len(installed_read.payload)
        if installed_total > MAX_AGGREGATE_BEAM_BYTES:
            return GuardResult("installed_beam_limited", **matched)
        if not hmac.compare_digest(
            hashlib.sha256(installed_read.payload).digest(),
            expected.digests[beam_name],
        ):
            return GuardResult("beam_digest_mismatch", **matched)

    closing_status, closing_manifest, closing_diagnostics = _read_installed_manifest(
        serial, package, runner, expected_names
    )
    if closing_status != "ok" or closing_manifest is None:
        return GuardResult(
            closing_status,
            **closing_diagnostics.guard_fields(),
            **matched,
        )
    if closing_manifest.entries != installed.entries:
        return GuardResult("installed_manifest_changed", **matched)

    return GuardResult(
        "exact",
        beam_digest_match=True,
        **matched,
    )


def _read_installed_manifest(
    serial: str,
    package: str,
    runner: CommandRunner,
    expected_names: frozenset[str],
) -> tuple[str, InstalledManifest | None, ManifestDiagnostics]:
    expected_count = len(expected_names)
    timeout_seconds = _manifest_timeout_seconds(expected_count)
    if timeout_seconds is None:
        return ("installed_manifest_failed", None, ManifestDiagnostics())
    result = runner.run(
        build_manifest_argv(serial, package),
        stdout_limit=MAX_MANIFEST_BYTES,
        timeout_seconds=timeout_seconds,
        idle_timeout_seconds=MANIFEST_IDLE_TIMEOUT_SECONDS,
    )
    diagnostics = _manifest_diagnostics(result.stdout, expected_names)
    diagnostics = replace(
        diagnostics,
        timeout_reason=(
            result.timeout_reason
            if result.timeout_reason in _TIMEOUT_REASONS
            else "none"
        ),
    )
    if result.category == "output_limit":
        return ("installed_manifest_limited", None, diagnostics)
    if result.category != "ok":
        return ("installed_manifest_failed", None, diagnostics)
    if result.returncode != 0:
        return ("installed_manifest_failed", None, diagnostics)

    manifest = _parse_installed_manifest(result.stdout)
    if manifest.category != "ok":
        status = {
            "remote_missing": "installed_manifest_missing",
            "remote_invalid": "installed_manifest_invalid_entry",
            "remote_limited": "installed_manifest_limited",
            "remote_changed": "installed_manifest_changed",
            "remote_hash_failed": "installed_manifest_failed",
            "malformed": "installed_manifest_malformed",
            "duplicate": "installed_manifest_duplicate",
            "unsafe_name": "installed_manifest_unsafe_name",
            "limited": "installed_manifest_limited",
        }.get(manifest.category, "internal_error")
        return (status, None, diagnostics)
    return ("ok", manifest, diagnostics)


def _completed_manifest_record_count(payload: bytes) -> int:
    if not payload.startswith(_MANIFEST_HEADER + b"\n"):
        return 0
    lines = payload.split(b"\n")
    completed = 0
    for line in lines[1:-1]:
        if len(line.split(b"\t")) != 3:
            break
        completed += 1
        if completed >= MAX_BEAMS:
            return MAX_BEAMS
    return completed


def _manifest_diagnostics(
    payload: bytes, expected_names: frozenset[str]
) -> ManifestDiagnostics:
    completed = _completed_manifest_record_count(payload)
    if not payload.startswith(_MANIFEST_HEADER + b"\n"):
        return ManifestDiagnostics()

    lines = payload.split(b"\n")
    complete = (
        payload.endswith(b"\n")
        and len(lines) >= 4
        and lines[-2] == _MANIFEST_END
        and len(lines[-3].split(b"\t")) == 2
        and lines[-3].split(b"\t")[0] == _MANIFEST_STATUS_TAG
        and lines[-3].split(b"\t")[1] in _MANIFEST_STATUSES
    )
    record_lines = lines[1:-3] if complete else lines[1:-1]
    names: set[str] = set()
    valid = 0
    duplicates = 0
    invalid_counts = {
        "field_count": 0,
        "name_encoding_or_grammar": 0,
        "digest_shape": 0,
        "numeric_or_stat": 0,
        "control_or_other": 0,
    }
    validity: list[bool] = []
    for encoded_entry in record_lines[:MAX_BEAMS]:
        category, name = _classify_manifest_diagnostic_record(encoded_entry)
        record_valid = category == "valid" and name is not None
        validity.append(record_valid)
        if not record_valid:
            invalid_counts[category] += 1
            continue
        valid += 1
        if name in names:
            duplicates += 1
        else:
            names.add(name)

    expected_matches = len(names.intersection(expected_names))
    return ManifestDiagnostics(
        completed_record_count=completed,
        valid_record_count=valid,
        unique_name_count=len(names),
        duplicate_name_count=duplicates,
        expected_name_match_count=expected_matches,
        unexpected_name_count=len(names) - expected_matches,
        missing_name_count=len(expected_names) - expected_matches,
        manifest_capture_scope="complete" if complete else "incomplete_prefix",
        invalid_field_count=invalid_counts["field_count"],
        invalid_name_encoding_or_grammar_count=invalid_counts[
            "name_encoding_or_grammar"
        ],
        invalid_digest_shape_count=invalid_counts["digest_shape"],
        invalid_numeric_or_stat_count=invalid_counts["numeric_or_stat"],
        invalid_control_or_other_count=invalid_counts["control_or_other"],
        invalid_frame_pattern=_invalid_frame_pattern(validity),
    )


def _classify_manifest_diagnostic_record(
    encoded_entry: bytes,
) -> tuple[str, str | None]:
    if (
        not encoded_entry
        or encoded_entry == _MANIFEST_END
        or encoded_entry.startswith(_MANIFEST_STATUS_TAG + b"\t")
    ):
        return ("control_or_other", None)

    fields = encoded_entry.split(b"\t")
    if len(fields) != 3:
        return ("field_count", None)
    encoded_name, encoded_identity, encoded_digest = fields
    if len(encoded_name) > MAX_BEAM_NAME_BYTES:
        return ("name_encoding_or_grammar", None)
    try:
        name = encoded_name.decode("ascii")
        _validate_beam_name(name)
    except (UnicodeDecodeError, InvalidArguments):
        return ("name_encoding_or_grammar", None)

    try:
        digest_text = encoded_digest.decode("ascii")
    except UnicodeDecodeError:
        return ("digest_shape", None)
    if _SHA256_RE.fullmatch(digest_text) is None:
        return ("digest_shape", None)

    try:
        identity = encoded_identity.decode("ascii")
        installed_size = _validate_installed_identity(identity)
    except (UnicodeDecodeError, InvalidArguments):
        return ("numeric_or_stat", None)
    if installed_size <= 0 or installed_size > MAX_BEAM_BYTES:
        return ("numeric_or_stat", None)
    return ("valid", name)


def _invalid_frame_pattern(validity: Sequence[bool]) -> str:
    invalid_positions = [index for index, valid in enumerate(validity) if not valid]
    if not invalid_positions:
        return "none"
    valid_positions = [index for index, valid in enumerate(validity) if valid]
    if not valid_positions:
        # With no valid anchor, every captured invalid frame is a prefix.
        return "prefix"

    first_valid = valid_positions[0]
    last_valid = valid_positions[-1]
    regions = set()
    for position in invalid_positions:
        if position < first_valid:
            regions.add("prefix")
        elif position > last_valid:
            regions.add("suffix")
        else:
            regions.add("interleaved")
    return next(iter(regions)) if len(regions) == 1 else "mixed"


def _manifest_timeout_seconds(expected_count: int) -> float | None:
    if (
        not isinstance(expected_count, int)
        or isinstance(expected_count, bool)
        or expected_count <= 0
        or expected_count > MAX_BEAMS
    ):
        return None
    calibrated = (
        MANIFEST_TIMEOUT_BASE_SECONDS
        + expected_count * MANIFEST_TIMEOUT_PER_BEAM_SECONDS
    )
    return min(
        MANIFEST_TIMEOUT_MAX_SECONDS,
        max(MANIFEST_TIMEOUT_MIN_SECONDS, calibrated),
    )


def _resolve_runtime_sources(
    build_lib_root: Path,
    runner: CommandRunner,
) -> RuntimeSources:
    result = runner.run(
        build_runtime_resolution_argv(),
        stdout_limit=MAX_RUNTIME_RESOLUTION_BYTES,
        timeout_seconds=COMMAND_TIMEOUT_SECONDS,
        cwd=build_lib_root.parent.parent.parent,
        env_overrides={"MIX_ENV": "dev"},
    )
    if result.category != "ok" or result.returncode != 0:
        return RuntimeSources("failed")
    return _parse_runtime_sources(result.stdout, build_lib_root)


def _parse_runtime_sources(payload: bytes, build_lib_root: Path) -> RuntimeSources:
    if (
        not payload
        or len(payload) > MAX_RUNTIME_RESOLUTION_BYTES
        or not payload.endswith(b"\n")
    ):
        return RuntimeSources("malformed")
    lines = payload.split(b"\n")
    if (
        len(lines) < 7
        or lines[0] != _RUNTIME_HEADER
        or lines[-2] != _MANIFEST_END
        or lines[-1] != b""
        or any(not line for line in lines[1:-2])
    ):
        return RuntimeSources("malformed")

    runtime: list[Path] = []
    eex: Path | None = None
    ssl: Path | None = None
    crypto: bytes | None = None
    stage = "runtime"
    for line in lines[1:-2]:
        fields = line.split(b"\t")
        if len(fields) != 2:
            return RuntimeSources("malformed")
        tag, encoded = fields
        if tag == b"RUNTIME" and stage == "runtime":
            path = _decode_source_path(encoded)
            if path is None or not _runtime_source_path_valid(path, build_lib_root):
                return RuntimeSources("malformed")
            runtime.append(path)
            continue
        if tag == b"EEX" and stage == "runtime" and runtime:
            eex = _decode_source_path(encoded)
            stage = "eex"
            continue
        if tag == b"SSL" and stage == "eex":
            ssl = _decode_source_path(encoded)
            stage = "ssl"
            continue
        if tag == b"CRYPTO" and stage == "ssl":
            crypto = encoded
            stage = "crypto"
            continue
        return RuntimeSources("malformed")

    if (
        stage != "crypto"
        or eex is None
        or ssl is None
        or not _auxiliary_source_path_valid(eex, "eex")
        or not _auxiliary_source_path_valid(ssl, "ssl")
    ):
        return RuntimeSources("malformed")
    if crypto != b"REAL":
        return RuntimeSources("unsupported")

    roots = tuple(runtime) + (eex, ssl)
    if len(roots) > MAX_SOURCE_DIRS or len(set(roots)) != len(roots):
        return RuntimeSources("malformed")
    return RuntimeSources("ok", roots)


def _decode_source_path(encoded: bytes) -> Path | None:
    if not encoded or len(encoded) > MAX_SOURCE_PATH_BYTES * 2:
        return None
    try:
        padded = encoded + b"=" * ((4 - len(encoded) % 4) % 4)
        raw = base64.b64decode(padded, altchars=b"-_", validate=True)
        if len(raw) > MAX_SOURCE_PATH_BYTES:
            return None
        text = raw.decode("ascii")
    except (ValueError, UnicodeDecodeError):
        return None
    path = Path(text)
    if not path.is_absolute() or "\x00" in text:
        return None
    return path


def _runtime_source_path_valid(path: Path, build_lib_root: Path) -> bool:
    if path.name != "ebin" or path.parent.parent != build_lib_root:
        return False
    source_name = path.parent.name
    try:
        encoded = source_name.encode("ascii")
    except UnicodeEncodeError:
        return False
    return (
        len(encoded) <= MAX_SOURCE_NAME_BYTES
        and _SOURCE_NAME_RE.fullmatch(source_name) is not None
        and path == build_lib_root / source_name / "ebin"
    )


def _auxiliary_source_path_valid(path: Path, expected_name: str) -> bool:
    if path.name != "ebin" or not path.is_absolute():
        return False
    source_name = path.parent.name
    try:
        source_name.encode("ascii")
    except UnicodeEncodeError:
        return False
    return source_name == expected_name or source_name.startswith(expected_name + "-")


def _read_flat_local_manifest(roots: tuple[Path, ...]) -> LocalManifest:
    if not roots or len(roots) > MAX_SOURCE_DIRS:
        return LocalManifest("missing", {})

    opened: list[tuple[Path, int, FileIdentity]] = []
    snapshots: list[Mapping[str, FileIdentity]] = []
    digests: dict[str, bytes] = {}
    seen_names: set[str] = set()
    aggregate = 0
    count = 0
    try:
        for root in roots:
            category, opened_root = _open_local_source(root)
            if category != "ok" or opened_root is None:
                return LocalManifest(category, {})
            opened.append((root, *opened_root))

        for _root, root_fd, _identity in opened:
            category, identities = _snapshot_local_beams(root_fd)
            if category != "ok":
                return LocalManifest(category, {})
            for name, identity in identities.items():
                if name in seen_names:
                    return LocalManifest("collision", {})
                seen_names.add(name)
                count += 1
                aggregate += identity.size
                if count > MAX_BEAMS or aggregate > MAX_AGGREGATE_BEAM_BYTES:
                    return LocalManifest("limited", {})
            snapshots.append(identities)

        for (_root, root_fd, _identity), identities in zip(opened, snapshots):
            for name in sorted(identities):
                category, digest = _hash_local_beam(root_fd, name, identities[name])
                if category != "ok" or digest is None:
                    return LocalManifest(category, {})
                digests[name] = digest

        for (root, root_fd, root_identity), opening in zip(opened, snapshots):
            closing_category, closing = _snapshot_local_beams(root_fd)
            if closing_category != "ok" or closing != opening:
                return LocalManifest("read_failed", {})
            try:
                closing_root = root.lstat()
            except OSError:
                return LocalManifest("read_failed", {})
            if _file_identity(closing_root) != root_identity:
                return LocalManifest("read_failed", {})
    except OSError:
        return LocalManifest("read_failed", {})
    finally:
        for _root, root_fd, _identity in opened:
            os.close(root_fd)

    if not digests:
        return LocalManifest("missing", {})
    return LocalManifest("ok", digests)


def _open_local_source(
    root: Path,
) -> tuple[str, tuple[int, FileIdentity] | None]:
    try:
        parent_info = root.parent.lstat()
        root_info = root.lstat()
    except OSError:
        return ("read_failed", None)
    if stat.S_ISLNK(parent_info.st_mode) or stat.S_ISLNK(root_info.st_mode):
        return ("symlink", None)
    if not stat.S_ISDIR(parent_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
        return ("invalid_entry", None)

    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    root_fd: int | None = None
    try:
        root_fd = os.open(root, flags)
        opened_info = os.fstat(root_fd)
    except OSError:
        if root_fd is not None:
            os.close(root_fd)
        return ("read_failed", None)
    assert root_fd is not None
    identity = _file_identity(root_info)
    if not stat.S_ISDIR(opened_info.st_mode) or _file_identity(opened_info) != identity:
        os.close(root_fd)
        return ("read_failed", None)
    return ("ok", (root_fd, identity))


def _snapshot_local_beams(root_fd: int) -> tuple[str, Mapping[str, FileIdentity]]:
    identities: dict[str, FileIdentity] = {}
    aggregate = 0
    try:
        entries = os.scandir(root_fd)
        with entries:
            for entry in entries:
                name = entry.name
                if not name.endswith(".beam"):
                    continue
                try:
                    _validate_beam_name(name)
                except InvalidArguments:
                    return ("unsafe_name", {})
                if entry.is_symlink():
                    return ("symlink", {})
                info = entry.stat(follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
                    return ("invalid_entry", {})
                if info.st_size > MAX_BEAM_BYTES or len(identities) >= MAX_BEAMS:
                    return ("limited", {})
                aggregate += info.st_size
                if aggregate > MAX_AGGREGATE_BEAM_BYTES:
                    return ("limited", {})
                if name in identities:
                    return ("read_failed", {})
                identities[name] = _file_identity(info)
    except OSError:
        return ("read_failed", {})
    if not identities:
        return ("missing", {})
    return ("ok", identities)


def _hash_local_beam(
    root_fd: int,
    name: str,
    expected_identity: FileIdentity,
) -> tuple[str, bytes | None]:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, dir_fd=root_fd)
    except OSError:
        return ("read_failed", None)

    digest = hashlib.sha256()
    total = 0
    try:
        before = os.fstat(fd)
        if _file_identity(before) != expected_identity:
            return ("read_failed", None)
        while True:
            chunk = os.read(fd, min(READ_CHUNK_BYTES, MAX_BEAM_BYTES + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_BEAM_BYTES:
                return ("limited", None)
            digest.update(chunk)
        after = os.fstat(fd)
        if total != expected_identity.size or _file_identity(after) != expected_identity:
            return ("read_failed", None)
        return ("ok", digest.digest())
    except OSError:
        return ("read_failed", None)
    finally:
        os.close(fd)


def _file_identity(info: os.stat_result) -> FileIdentity:
    return FileIdentity(
        device=info.st_dev,
        inode=info.st_ino,
        mode=info.st_mode,
        size=info.st_size,
        modified_ns=info.st_mtime_ns,
        changed_ns=info.st_ctime_ns,
    )


def _parse_installed_manifest(payload: bytes) -> InstalledManifest:
    if not payload or len(payload) > MAX_MANIFEST_BYTES or not payload.endswith(b"\n"):
        return InstalledManifest("malformed", {})
    lines = payload.split(b"\n")
    if (
        len(lines) < 4
        or lines[0] != _MANIFEST_HEADER
        or lines[-2] != _MANIFEST_END
        or lines[-1] != b""
    ):
        return InstalledManifest("malformed", {})
    if any(not line for line in lines[1:-2]):
        return InstalledManifest("malformed", {})
    status_fields = lines[-3].split(b"\t")
    if (
        len(status_fields) != 2
        or status_fields[0] != _MANIFEST_STATUS_TAG
        or status_fields[1] not in _MANIFEST_STATUSES
    ):
        return InstalledManifest("malformed", {})
    remote_status = status_fields[1]

    entries: dict[str, InstalledEntry] = {}
    aggregate_size = 0
    for encoded_entry in lines[1:-3]:
        fields = encoded_entry.split(b"\t")
        if len(fields) != 3:
            return InstalledManifest("malformed", {})
        encoded_name, encoded_identity, encoded_digest = fields
        if len(encoded_name) > MAX_BEAM_NAME_BYTES:
            return InstalledManifest("unsafe_name", {})
        try:
            name = encoded_name.decode("ascii")
            _validate_beam_name(name)
        except (UnicodeDecodeError, InvalidArguments):
            return InstalledManifest("unsafe_name", {})
        try:
            identity = encoded_identity.decode("ascii")
            installed_size = _validate_installed_identity(identity)
        except (UnicodeDecodeError, InvalidArguments):
            return InstalledManifest("malformed", {})
        try:
            digest_text = encoded_digest.decode("ascii")
        except UnicodeDecodeError:
            return InstalledManifest("malformed", {})
        if _SHA256_RE.fullmatch(digest_text) is None:
            return InstalledManifest("malformed", {})
        if name in entries:
            return InstalledManifest("duplicate", {})
        if len(entries) >= MAX_BEAMS:
            return InstalledManifest("limited", {})
        if installed_size <= 0 or installed_size > MAX_BEAM_BYTES:
            return InstalledManifest("limited", {})
        aggregate_size += installed_size
        if aggregate_size > MAX_AGGREGATE_BEAM_BYTES:
            return InstalledManifest("limited", {})
        entries[name] = InstalledEntry(identity, bytes.fromhex(digest_text))

    if remote_status == b"OK" and not entries:
        return InstalledManifest("malformed", {})
    category = {
        b"OK": "ok",
        b"MISSING": "remote_missing",
        b"INVALID": "remote_invalid",
        b"LIMITED": "remote_limited",
        b"CHANGED": "remote_changed",
        b"HASH_FAILED": "remote_hash_failed",
    }[remote_status]
    return InstalledManifest(category, entries)


def _parse_installed_read(payload: bytes, expected_size: int) -> InstalledRead:
    if (
        not payload
        or not isinstance(expected_size, int)
        or expected_size <= 0
        or expected_size > MAX_BEAM_BYTES
        or len(payload) > MAX_BEAM_BYTES + READ_FRAME_OVERHEAD_BYTES
        or not payload.startswith(_READ_HEADER)
    ):
        category = (
            "limited"
            if isinstance(expected_size, int) and expected_size > MAX_BEAM_BYTES
            else "malformed"
        )
        return InstalledRead(category)

    matching_statuses = [
        status
        for status, record in _READ_STATUS_RECORDS.items()
        if payload.endswith(record)
    ]
    if len(matching_statuses) != 1:
        return InstalledRead("malformed")
    remote_status = matching_statuses[0]
    record = _READ_STATUS_RECORDS[remote_status]
    prefix = payload[: -len(record)]

    if remote_status == b"OK":
        data_prefix = _READ_HEADER + _READ_DATA
        if not prefix.startswith(data_prefix) or not prefix.endswith(b"\n"):
            return InstalledRead("malformed")
        beam = prefix[len(data_prefix) : -1]
        if len(beam) > MAX_BEAM_BYTES:
            return InstalledRead("limited")
        if len(beam) != expected_size:
            return InstalledRead("size_mismatch", beam)
        return InstalledRead("ok", beam)

    before_data = prefix == _READ_HEADER
    after_data = prefix.startswith(_READ_HEADER + _READ_DATA) and prefix.endswith(b"\n")
    partial_size = (
        len(prefix) - len(_READ_HEADER) - len(_READ_DATA) - 1
        if after_data
        else -1
    )
    if remote_status in {b"MISSING", b"INVALID", b"LIMITED"}:
        if not before_data:
            return InstalledRead("malformed")
    elif remote_status == b"CHANGED":
        if not before_data and not (after_data and 0 <= partial_size <= expected_size):
            return InstalledRead("malformed")
    elif remote_status == b"READ_FAILED":
        if not after_data or not 0 <= partial_size <= expected_size:
            return InstalledRead("malformed")
    else:
        return InstalledRead("malformed")

    category = {
        b"MISSING": "missing",
        b"INVALID": "invalid_entry",
        b"LIMITED": "limited",
        b"CHANGED": "changed",
        b"READ_FAILED": "read_failed",
    }[remote_status]
    return InstalledRead(category)


def _validate_serial(serial: str) -> None:
    if not isinstance(serial, str) or _SERIAL_RE.fullmatch(serial) is None:
        raise InvalidArguments


def _validate_package(package: str) -> None:
    if package != ANDROID_PACKAGE:
        raise InvalidArguments


def _validate_beam_name(name: str) -> None:
    try:
        encoded_name = name.encode("utf-8") if isinstance(name, str) else b""
    except UnicodeEncodeError as exc:
        raise InvalidArguments from exc
    if (
        not isinstance(name, str)
        or len(encoded_name) > MAX_BEAM_NAME_BYTES
        or _BEAM_NAME_RE.fullmatch(name) is None
        or ".." in name
    ):
        raise InvalidArguments


def _validate_installed_identity(identity: str) -> int:
    try:
        encoded_identity = identity.encode("ascii") if isinstance(identity, str) else b""
    except UnicodeEncodeError as exc:
        raise InvalidArguments from exc
    if (
        not isinstance(identity, str)
        or len(encoded_identity) > MAX_INSTALLED_IDENTITY_BYTES
        or _INSTALLED_IDENTITY_RE.fullmatch(identity) is None
    ):
        raise InvalidArguments
    return int(identity.split(":", 4)[3])


def _validate_expected_build_lib_root(root: Path) -> Path:
    try:
        encoded_root = str(root).encode("ascii") if isinstance(root, Path) else b""
    except UnicodeEncodeError as exc:
        raise InvalidArguments from exc
    if (
        not isinstance(root, Path)
        or not root.is_absolute()
        or len(encoded_root) > MAX_SOURCE_PATH_BYTES
        or root.name != "lib"
        or root.parent.name != "dev"
        or root.parent.parent.name != "_build"
    ):
        raise InvalidArguments
    info = root.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise InvalidArguments
    return root


def _parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(add_help=False)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--expected-build-lib-root", required=True)
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    runner: CommandRunner | None = None,
    output: TextIO | None = None,
) -> int:
    output = output or sys.stdout
    try:
        args = _parser().parse_args(argv)
        result = verify_android_beam_provenance(
            args.serial,
            args.package,
            Path(args.expected_build_lib_root),
            runner=runner,
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
