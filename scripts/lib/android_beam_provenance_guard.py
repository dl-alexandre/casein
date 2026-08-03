#!/usr/bin/env python3
"""Fail closed unless installed Android app BEAMs match a reviewed ebin tree.

The guard is read-only and intentionally narrow.  It compares the regular,
non-symlink ``*.beam`` files in one explicit local ``casein_mob/ebin`` directory
with the flat app BEAM directory owned by the fixed Android package.  Child
output, identifiers, paths, filenames, file bytes, and digests never cross the
public boundary: stdout is exactly one fixed-schema JSON classification.
"""

from __future__ import annotations

import argparse
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
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Protocol, Sequence, TextIO


sys.dont_write_bytecode = True

COMPONENT = "casein_android_beam_provenance_guard"
SCHEMA_VERSION = 1
ANDROID_PACKAGE = "com.example.casein_mob"
INSTALLED_BEAM_DIR = "files/otp/casein_mob"

MAX_BEAMS = 64
MAX_BEAM_NAME_BYTES = 128
MAX_INSTALLED_IDENTITY_BYTES = 96
MAX_MANIFEST_BYTES = 16 * 1024
MAX_BEAM_BYTES = 16 * 1024 * 1024
MAX_AGGREGATE_BEAM_BYTES = 64 * 1024 * 1024
READ_CHUNK_BYTES = 64 * 1024
COMMAND_TIMEOUT_SECONDS = 60.0
PROCESS_TERM_TIMEOUT_SECONDS = 1.0
PROCESS_KILL_TIMEOUT_SECONDS = 1.0
POLL_SECONDS = 0.05

_SERIAL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_BEAM_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,122}\.beam$")
_INSTALLED_IDENTITY_RE = re.compile(
    r"^[0-9]+:[0-9]+:[0-9a-f]+:[0-9]+:-?[0-9]+:-?[0-9]+$"
)
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

_MANIFEST_HEADER = b"CASEIN_BEAMS_V3"
_MANIFEST_END = b"END"

# The script is fixed program text.  The serial and package are separate,
# validated argv elements; no caller value is interpolated into this program.
_MANIFEST_SCRIPT = f"""\
dir='{INSTALLED_BEAM_DIR}'
[ -d \"$dir\" ] || exit 41
printf 'CASEIN_BEAMS_V3\\n'
count=0
found=0
for path in \"$dir\"/*.beam \"$dir\"/.*.beam; do
  [ -e \"$path\" ] || [ -L \"$path\" ] || continue
  found=1
  [ -f \"$path\" ] && [ ! -L \"$path\" ] || exit 42
  count=$((count + 1))
  [ \"$count\" -le {MAX_BEAMS} ] || exit 43
  name=${{path##*/}}
  before=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || exit 45
  exec 3<\"$path\" || exit 45
  opened=$(stat -Lc '%d:%i:%f:%s:%Y:%Z' /proc/self/fd/3) || exit 45
  after_open=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || exit 45
  [ -f \"$path\" ] && [ ! -L \"$path\" ] || exit 45
  [ \"$before\" = \"$opened\" ] && [ \"$after_open\" = \"$opened\" ] || exit 45
  digest_line=$(sha256sum <&3) || exit 46
  digest=${{digest_line%% *}}
  after_hash=$(stat -Lc '%d:%i:%f:%s:%Y:%Z' /proc/self/fd/3) || exit 45
  after_path=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || exit 45
  [ -f \"$path\" ] && [ ! -L \"$path\" ] || exit 45
  [ \"$opened\" = \"$after_hash\" ] && [ \"$after_path\" = \"$opened\" ] || exit 45
  exec 3<&-
  printf '%s\\t%s\\t%s\\n' \"$name\" \"$opened\" \"$digest\"
done
[ \"$found\" -eq 1 ] || exit 44
printf 'END\\n'
"""

_READ_SCRIPT = f"""\
dir='{INSTALLED_BEAM_DIR}'
path="$dir/$1"
expected="$2"
[ -e \"$path\" ] || [ -L \"$path\" ] || exit 41
[ -f \"$path\" ] && [ ! -L \"$path\" ] || exit 42
before=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || exit 41
exec 3<\"$path\" || exit 41
opened=$(stat -Lc '%d:%i:%f:%s:%Y:%Z' /proc/self/fd/3) || exit 42
after_open=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || exit 45
[ -f \"$path\" ] && [ ! -L \"$path\" ] || exit 45
[ \"$expected\" = \"$before\" ] && [ \"$before\" = \"$opened\" ] && [ \"$after_open\" = \"$opened\" ] || exit 45
cat <&3 || exit 46
after_read=$(stat -Lc '%d:%i:%f:%s:%Y:%Z' /proc/self/fd/3) || exit 45
after_path=$(stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\") || exit 45
[ -f \"$path\" ] && [ ! -L \"$path\" ] || exit 45
[ \"$opened\" = \"$after_read\" ] && [ \"$after_path\" = \"$opened\" ] || exit 45
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


class CommandRunner(Protocol):
    def run(
        self,
        argv: tuple[str, ...],
        *,
        stdout_limit: int,
        timeout_seconds: float,
    ) -> CommandResult: ...


@dataclass(frozen=True, slots=True, repr=False)
class GuardResult:
    status: str
    expected_manifest_valid: bool = False
    installed_manifest_complete: bool = False
    beam_name_set_match: bool = False
    beam_digest_match: bool = False

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
            "expected_manifest_valid": self.expected_manifest_valid,
            "installed_manifest_complete": self.installed_manifest_complete,
            "beam_name_set_match": self.beam_name_set_match,
            "beam_digest_match": self.beam_digest_match,
            "exact": self.exact,
        }


@dataclass(frozen=True, slots=True, repr=False)
class LocalManifest:
    category: str
    digests: Mapping[str, bytes]


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
    ) -> CommandResult:
        if not argv or stdout_limit <= 0 or timeout_seconds <= 0:
            return CommandResult("failed")

        try:
            process = subprocess.Popen(
                list(argv),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
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
            if process.stdout is None:
                _terminate_process_group(process)
                return CommandResult("failed")

            os.set_blocking(process.stdout.fileno(), False)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)

            while process.poll() is None:
                if time.monotonic() >= deadline:
                    category = "timeout"
                    break

                remaining = max(0.0, deadline - time.monotonic())
                if selector.select(min(POLL_SECONDS, remaining)):
                    if not _read_bounded(process.stdout, collected, stdout_limit):
                        category = "output_limit"
                        break

            if category == "ok":
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

            return CommandResult(category, returncode, bytes(collected))
        finally:
            if selector is not None:
                selector.close()
            if process.stdout is not None:
                process.stdout.close()


def _read_bounded(stream: object, collected: bytearray, limit: int) -> bool:
    try:
        chunk = os.read(stream.fileno(), min(4096, limit + 1 - len(collected)))
    except BlockingIOError:
        return True
    except OSError:
        return False
    collected.extend(chunk)
    return len(collected) <= limit


def _drain_bounded(stream: object, collected: bytearray, limit: int) -> bool:
    """Drain an exited child's pipe through EOF or the first over-limit byte."""

    while True:
        read_size = min(4096, limit + 1 - len(collected))
        if read_size <= 0:
            return False
        try:
            chunk = os.read(stream.fileno(), read_size)
        except BlockingIOError:
            return False
        except OSError:
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


def verify_android_beam_provenance(
    serial: str,
    package: str,
    expected_ebin_root: Path,
    *,
    runner: CommandRunner | None = None,
) -> GuardResult:
    """Compare reviewed and installed app BEAM sets without device mutation."""

    try:
        return _verify_android_beam_provenance(
            serial,
            package,
            expected_ebin_root,
            runner=runner,
        )
    except Exception:
        return GuardResult("internal_error")


def _verify_android_beam_provenance(
    serial: str,
    package: str,
    expected_ebin_root: Path,
    *,
    runner: CommandRunner | None = None,
) -> GuardResult:

    runner = runner or SubprocessCommandRunner()
    try:
        build_manifest_argv(serial, package)
        expected_ebin_root = _validate_expected_ebin_root(expected_ebin_root)
    except (InvalidArguments, OSError, ValueError):
        return GuardResult("invalid_arguments")

    expected = _read_local_manifest(expected_ebin_root)
    if expected.category != "ok":
        status = {
            "missing": "expected_manifest_missing",
            "unsafe_name": "expected_manifest_unsafe_name",
            "symlink": "expected_manifest_symlink",
            "invalid_entry": "expected_manifest_invalid_entry",
            "limited": "expected_manifest_limited",
            "read_failed": "expected_manifest_read_failed",
        }.get(expected.category, "internal_error")
        return GuardResult(status)

    common = {"expected_manifest_valid": True}
    status, installed = _read_installed_manifest(serial, package, runner)
    if status != "ok" or installed is None:
        return GuardResult(status, **common)

    complete = {**common, "installed_manifest_complete": True}
    expected_names = frozenset(expected.digests)
    if installed.names != expected_names:
        return GuardResult("beam_name_set_mismatch", **complete)

    matched = {**complete, "beam_name_set_match": True}
    for beam_name in sorted(expected_names):
        if not hmac.compare_digest(
            installed.entries[beam_name].digest,
            expected.digests[beam_name],
        ):
            return GuardResult("beam_digest_mismatch", **matched)

    installed_total = 0
    for beam_name in sorted(expected_names):
        read_result = runner.run(
            build_read_argv(
                serial,
                package,
                beam_name,
                installed.entries[beam_name].identity,
            ),
            stdout_limit=MAX_BEAM_BYTES,
            timeout_seconds=COMMAND_TIMEOUT_SECONDS,
        )
        if read_result.category == "output_limit":
            return GuardResult("installed_beam_limited", **matched)
        if read_result.category != "ok":
            return GuardResult("installed_beam_failed", **matched)
        if read_result.returncode != 0:
            status = {
                41: "installed_beam_missing",
                42: "installed_beam_invalid_entry",
                45: "installed_beam_changed",
                46: "installed_beam_failed",
            }.get(read_result.returncode, "installed_beam_failed")
            return GuardResult(status, **matched)
        if len(read_result.stdout) > MAX_BEAM_BYTES:
            return GuardResult("installed_beam_limited", **matched)
        if not read_result.stdout:
            return GuardResult("installed_beam_invalid", **matched)

        installed_total += len(read_result.stdout)
        if installed_total > MAX_AGGREGATE_BEAM_BYTES:
            return GuardResult("installed_beam_limited", **matched)
        if not hmac.compare_digest(
            hashlib.sha256(read_result.stdout).digest(), expected.digests[beam_name]
        ):
            return GuardResult("beam_digest_mismatch", **matched)

    closing_status, closing_manifest = _read_installed_manifest(serial, package, runner)
    if closing_status != "ok" or closing_manifest is None:
        return GuardResult(closing_status, **matched)
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
) -> tuple[str, InstalledManifest | None]:
    result = runner.run(
        build_manifest_argv(serial, package),
        stdout_limit=MAX_MANIFEST_BYTES,
        timeout_seconds=COMMAND_TIMEOUT_SECONDS,
    )
    if result.category == "output_limit":
        return ("installed_manifest_limited", None)
    if result.category != "ok":
        return ("installed_manifest_failed", None)
    if result.returncode != 0:
        status = {
            41: "installed_manifest_missing",
            42: "installed_manifest_invalid_entry",
            43: "installed_manifest_limited",
            44: "installed_manifest_missing",
            45: "installed_manifest_changed",
        }.get(result.returncode, "installed_manifest_failed")
        return (status, None)

    manifest = _parse_installed_manifest(result.stdout)
    if manifest.category != "ok":
        status = {
            "malformed": "installed_manifest_malformed",
            "duplicate": "installed_manifest_duplicate",
            "unsafe_name": "installed_manifest_unsafe_name",
            "limited": "installed_manifest_limited",
        }.get(manifest.category, "internal_error")
        return (status, None)
    return ("ok", manifest)


def _read_local_manifest(root: Path) -> LocalManifest:
    digests: dict[str, bytes] = {}
    root_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        root_flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        root_flags |= os.O_NOFOLLOW
    try:
        root_fd = os.open(root, root_flags)
    except OSError:
        return LocalManifest("read_failed", {})

    try:
        root_info = os.fstat(root_fd)
        if not stat.S_ISDIR(root_info.st_mode):
            return LocalManifest("read_failed", {})

        category, identities = _snapshot_local_beams(root_fd)
        if category != "ok":
            return LocalManifest(category, {})

        for name in sorted(identities):
            category, digest = _hash_local_beam(root_fd, name, identities[name])
            if category != "ok" or digest is None:
                return LocalManifest(category, {})
            digests[name] = digest

        closing_category, closing_identities = _snapshot_local_beams(root_fd)
        if closing_category != "ok":
            return LocalManifest(closing_category, {})
        if closing_identities != identities:
            return LocalManifest("read_failed", {})
    except OSError:
        return LocalManifest("read_failed", {})
    finally:
        os.close(root_fd)

    if not digests:
        return LocalManifest("missing", {})
    return LocalManifest("ok", digests)


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
    if len(lines) < 4 or lines[0] != _MANIFEST_HEADER or lines[-2] != _MANIFEST_END:
        return InstalledManifest("malformed", {})
    if lines[-1] != b"" or any(not line for line in lines[1:-2]):
        return InstalledManifest("malformed", {})

    entries: dict[str, InstalledEntry] = {}
    aggregate_size = 0
    for encoded_entry in lines[1:-2]:
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

    if not entries:
        return InstalledManifest("malformed", {})
    return InstalledManifest("ok", entries)


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


def _validate_expected_ebin_root(root: Path) -> Path:
    if (
        not isinstance(root, Path)
        or not root.is_absolute()
        or root.name != "ebin"
        or root.parent.name != "casein_mob"
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
    parser.add_argument("--expected-ebin-root", required=True)
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
            Path(args.expected_ebin_root),
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
