#!/usr/bin/env python3

from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import os
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/lib/android_beam_provenance_guard.py"
SPEC = importlib.util.spec_from_file_location("android_beam_provenance_guard", SCRIPT)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)

SERIAL = "R52M1234.ADB-1:5555"
PACKAGE = guard.ANDROID_PACKAGE
SECRET = "password=privacy-regression-sentinel"


def installed_identity(
    name: str,
    *,
    generation: int = 1,
    size: int = 16,
) -> str:
    inode = sum(name.encode("ascii"))
    return f"1:{inode}:81a4:{size}:1700000000:{1700000000 + generation}"


def manifest(
    *names: str,
    identities: dict[str, str] | None = None,
    payloads: dict[str, bytes] | None = None,
    status: bytes = b"OK",
) -> bytes:
    identities = identities or {}
    payloads = payloads or {}
    return b"CASEIN_BEAMS_V5\n" + b"".join(
        name.encode("ascii")
        + b"\t"
        + identities.get(
            name,
            installed_identity(
                name,
                size=len(payloads.get(name, ("fixture:" + name).encode("ascii"))),
            ),
        ).encode("ascii")
        + b"\t"
        + hashlib.sha256(
            payloads.get(name, ("fixture:" + name).encode("ascii"))
        ).hexdigest().encode("ascii")
        + b"\n"
        for name in names
    ) + b"STATUS\t" + status + b"\nEND\n"


def read_frame(payload: bytes = b"", *, status: bytes = b"OK") -> bytes:
    if status == b"OK":
        return (
            b"CASEIN_BEAM_READ_V1\nDATA\n"
            + payload
            + b"\nSTATUS\tOK\nEND\n"
        )
    if payload:
        return (
            b"CASEIN_BEAM_READ_V1\nDATA\n"
            + payload
            + b"\nSTATUS\t"
            + status
            + b"\nEND\n"
        )
    return b"CASEIN_BEAM_READ_V1\nSTATUS\t" + status + b"\nEND\n"


def encoded_path(path: Path) -> bytes:
    return base64.urlsafe_b64encode(str(path).encode("ascii")).rstrip(b"=")


def runtime_frame(
    runtime: tuple[Path, ...],
    eex: Path,
    ssl: Path,
    *,
    crypto: bytes = b"REAL",
) -> bytes:
    return (
        b"CASEIN_RUNTIME_BEAM_DIRS_V4\n"
        + b"".join(b"RUNTIME\t" + encoded_path(path) + b"\n" for path in runtime)
        + b"EEX\t"
        + encoded_path(eex)
        + b"\nSSL\t"
        + encoded_path(ssl)
        + b"\nCRYPTO\t"
        + crypto
        + b"\nEND\n"
    )


class FakeRunner:
    def __init__(
        self,
        manifest_result: guard.CommandResult,
        beams: dict[str, bytes | guard.CommandResult] | None = None,
        runtime_result: guard.CommandResult | None = None,
    ) -> None:
        self.manifest_result = manifest_result
        self.beams = beams or {}
        self.calls: list[tuple[tuple[str, ...], dict[str, object]]] = []
        self.runtime_calls: list[tuple[tuple[str, ...], dict[str, object]]] = []
        self.runtime_result = runtime_result

    def run(self, argv: tuple[str, ...], **kwargs: object) -> guard.CommandResult:
        if argv == guard.build_runtime_resolution_argv():
            self.runtime_calls.append((argv, kwargs))
            return self.runtime_result or guard.CommandResult("failed", 1)
        self.calls.append((argv, kwargs))
        if argv[-1] == guard._MANIFEST_SCRIPT:
            return self.manifest_result
        value = self.beams.get(argv[-2], guard.CommandResult("ok", 41))
        if isinstance(value, guard.CommandResult):
            return value
        return guard.CommandResult("ok", 0, read_frame(value))


class RaisingRunner:
    def run(self, _argv: tuple[str, ...], **_kwargs: object) -> guard.CommandResult:
        raise RuntimeError(SECRET)


class BoundaryRunner:
    def __init__(self, runtime_result: guard.CommandResult) -> None:
        self.runtime_result = runtime_result
        self.subprocess_runner = guard.SubprocessCommandRunner()

    def run(self, argv: tuple[str, ...], **kwargs: object) -> guard.CommandResult:
        if argv == guard.build_runtime_resolution_argv():
            return self.runtime_result
        return self.subprocess_runner.run(argv, **kwargs)


class ChangingManifestRunner(FakeRunner):
    def __init__(self, initial: bytes, closing: bytes, beams: dict[str, bytes]) -> None:
        super().__init__(guard.CommandResult("ok", 0, initial), beams)
        self.closing = closing
        self.manifest_calls = 0

    def run(self, argv: tuple[str, ...], **kwargs: object) -> guard.CommandResult:
        if argv[-1] == guard._MANIFEST_SCRIPT:
            self.manifest_calls += 1
            if self.manifest_calls == 2:
                self.calls.append((argv, kwargs))
                return guard.CommandResult("ok", 0, self.closing)
        return super().run(argv, **kwargs)


class FakeProcess:
    pid = 700

    def __init__(self, stdout=None, returncode: int = 0) -> None:
        self.stdout = stdout
        self.returncode = returncode

    def poll(self) -> int:
        return self.returncode

    def wait(self, timeout=None) -> int:
        return self.returncode


class AndroidBeamProvenanceGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.project_root = Path(self.temp.name) / "casein_mob"
        self.build_root = self.project_root / "_build" / "dev" / "lib"
        self.root = self.build_root / "casein_mob" / "ebin"
        self.eex_root = Path(self.temp.name) / "toolchain" / "eex" / "ebin"
        self.ssl_root = Path(self.temp.name) / "toolchain" / "ssl-11.0" / "ebin"
        self.root.mkdir(parents=True)
        self.eex_root.mkdir(parents=True)
        self.ssl_root.mkdir(parents=True)
        self.payloads = {
            "Elixir.CaseinMob.App.beam": b"beam-app-v1",
            "Elixir.CaseinMob.SessionClient.beam": b"beam-session-v1",
            "Elixir.EEx.beam": b"e",
            "ssl.beam": b"s",
        }
        for name, payload in self.payloads.items():
            target = (
                self.eex_root
                if name == "Elixir.EEx.beam"
                else self.ssl_root
                if name == "ssl.beam"
                else self.root
            )
            (target / name).write_bytes(payload)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def runner(
        self,
        *names: str,
        beams: dict[str, bytes | guard.CommandResult] | None = None,
        identities: dict[str, str] | None = None,
        manifest_payloads: dict[str, bytes] | None = None,
    ) -> FakeRunner:
        return FakeRunner(
            guard.CommandResult(
                "ok",
                0,
                manifest(
                    *names,
                    identities=identities,
                    payloads=(
                        self.payloads
                        if manifest_payloads is None
                        else manifest_payloads
                    ),
                ),
            ),
            beams if beams is not None else dict(self.payloads),
            runtime_result=self.runtime_result(),
        )

    def runtime_result(
        self,
        *,
        runtime: tuple[Path, ...] | None = None,
        eex: Path | None = None,
        ssl: Path | None = None,
        crypto: bytes = b"REAL",
    ) -> guard.CommandResult:
        return guard.CommandResult(
            "ok",
            0,
            runtime_frame(
                runtime or (self.root,),
                eex or self.eex_root,
                ssl or self.ssl_root,
                crypto=crypto,
            ),
        )

    def fake_adb_environment(self, label: str) -> tuple[Path, dict[str, str]]:
        fake_root = Path(self.temp.name) / f"fake-android-{label}"
        fake_bin = Path(self.temp.name) / f"fake-android-tools-{label}"
        fake_root.mkdir()
        fake_bin.mkdir()

        programs = {
            "adb": f"#!{sys.executable}\n"
            + """import os
import subprocess
import sys

args = sys.argv[1:]
if len(args) < 9 or args[3:8] != ["exec-out", "run-as", "com.example.casein_mob", "sh", "-c"]:
    raise SystemExit(2)
mode = os.environ.get("CASEIN_FAKE_ADB_MODE", "execute")
if mode == "empty":
    raise SystemExit(0)
if mode == "truncated":
    sys.stdout.buffer.write(b"CASEIN_BEAMS_V5\\n")
    raise SystemExit(0)
program = args[8].replace(
    '[ "$path" -ef "/proc/$$/fd/3" ]',
    'casein_same_fd "$path"',
)
completed = subprocess.run(
    ["/bin/sh", "-c", program, *args[9:]],
    cwd=os.environ["CASEIN_FAKE_DEVICE_ROOT"],
    env=os.environ.copy(),
    stdin=subprocess.DEVNULL,
    stdout=(sys.stdout.buffer if mode == "stream" else subprocess.PIPE),
    stderr=subprocess.DEVNULL,
    check=False,
)
if completed.stdout is not None:
    sys.stdout.buffer.write(completed.stdout)
# Android 9 raw exec-out reports only the host-side stream result.
raise SystemExit(0)
""",
            "stat": f"#!{sys.executable}\n"
            + """import os
import sys

if os.environ.get("CASEIN_FAKE_STAT_MODE") == "fail":
    raise SystemExit(1)
target = sys.argv[-1]
info = os.stat(target)
sys.stdout.write(f"9:{info.st_ino}:81a4:{info.st_size}:0:0\\n")
""",
            "sha256sum": f"#!{sys.executable}\n"
            + """import hashlib
import os
import sys
import time

if os.environ.get("CASEIN_FAKE_SHA_MODE") == "fail":
    raise SystemExit(1)
time.sleep(float(os.environ.get("CASEIN_FAKE_SHA_DELAY", "0")))
sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + "  -\\n")
""",
            "casein_same_fd": f"#!{sys.executable}\n"
            + """import os
import sys

if os.environ.get("CASEIN_FAKE_FD_ALIAS_MODE") == "mismatch":
    raise SystemExit(1)
path = os.stat(sys.argv[1])
opened = os.fstat(3)
raise SystemExit(0 if (path.st_dev, path.st_ino) == (opened.st_dev, opened.st_ino) else 1)
""",
            "cat": f"#!{sys.executable}\n"
            + """import os
import sys

payload = sys.stdin.buffer.read()
if os.environ.get("CASEIN_FAKE_CAT_MODE") == "partial":
    sys.stdout.buffer.write(payload[: max(1, len(payload) // 2)])
    raise SystemExit(1)
sys.stdout.buffer.write(payload)
""",
        }
        for name, program in programs.items():
            executable = fake_bin / name
            executable.write_text(program, encoding="utf-8")
            executable.chmod(0o755)

        environment = {
            "PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", ""),
            "CASEIN_FAKE_DEVICE_ROOT": str(fake_root),
        }
        return fake_root, environment

    def verify(self, runner: object) -> guard.GuardResult:
        if isinstance(runner, FakeRunner) and runner.runtime_result is None:
            runner.runtime_result = self.runtime_result()
        return guard.verify_android_beam_provenance(
            SERIAL,
            PACKAGE,
            self.build_root,
            runner=runner,
        )

    def test_exact_manifest_and_digests_have_the_only_success_schema(self) -> None:
        names = tuple(reversed(tuple(self.payloads)))
        runner = self.runner(*names)

        result = self.verify(runner)

        self.assertEqual("exact", result.status)
        self.assertTrue(result.exact)
        self.assertEqual(
            {
                "schema_version": 1,
                "component": "casein_android_beam_provenance_guard",
                "status": "exact",
                "expected_manifest_valid": True,
                "installed_manifest_complete": True,
                "beam_name_set_match": True,
                "beam_digest_match": True,
                "timeout_reason": "none",
                "completed_record_count": 0,
                "valid_record_count": 0,
                "unique_name_count": 0,
                "duplicate_name_count": 0,
                "expected_name_match_count": 0,
                "unexpected_name_count": 0,
                "missing_name_count": 0,
                "manifest_capture_scope": "none",
                "exact": True,
            },
            result.public(),
        )
        read_names = [
            call[0][-2]
            for call in runner.calls
            if call[0][-1] != guard._MANIFEST_SCRIPT
        ]
        self.assertEqual(sorted(self.payloads), read_names)
        self.assertEqual(2, sum(call[0][-1] == guard._MANIFEST_SCRIPT for call in runner.calls))

    def test_every_adb_call_is_explicit_exec_out_run_as_for_fixed_package(self) -> None:
        runner = self.runner(*self.payloads)
        self.assertEqual("exact", self.verify(runner).status)

        self.assertEqual(1, len(runner.runtime_calls))
        runtime_argv, runtime_kwargs = runner.runtime_calls[0]
        self.assertEqual(guard.build_runtime_resolution_argv(), runtime_argv)
        self.assertEqual(self.project_root, runtime_kwargs["cwd"])
        self.assertEqual({"MIX_ENV": "dev"}, runtime_kwargs["env_overrides"])
        self.assertEqual(
            guard.MAX_RUNTIME_RESOLUTION_BYTES, runtime_kwargs["stdout_limit"]
        )

        for argv, kwargs in runner.calls:
            self.assertEqual(
                (
                    "adb",
                    "--exit-on-write-error",
                    "-s",
                    SERIAL,
                    "exec-out",
                    "run-as",
                    PACKAGE,
                    "sh",
                    "-c",
                ),
                argv[:9],
            )
            self.assertNotIn("shell", argv)
            if argv[-1] == guard._MANIFEST_SCRIPT:
                self.assertEqual(
                    guard._manifest_timeout_seconds(len(self.payloads)),
                    kwargs["timeout_seconds"],
                )
                self.assertEqual(
                    guard.MANIFEST_IDLE_TIMEOUT_SECONDS,
                    kwargs["idle_timeout_seconds"],
                )
            else:
                self.assertEqual(
                    guard.COMMAND_TIMEOUT_SECONDS, kwargs["timeout_seconds"]
                )
        self.assertEqual(guard.MAX_MANIFEST_BYTES, runner.calls[0][1]["stdout_limit"])
        for argv, kwargs in runner.calls[1:]:
            expected_limit = (
                guard.MAX_MANIFEST_BYTES
                if argv[-1] == guard._MANIFEST_SCRIPT
                else guard.MAX_BEAM_BYTES + guard.READ_FRAME_OVERHEAD_BYTES
            )
            self.assertEqual(expected_limit, kwargs["stdout_limit"])
        self.assertNotIn(SERIAL, guard._MANIFEST_SCRIPT)
        self.assertNotIn(PACKAGE, guard._MANIFEST_SCRIPT)
        self.assertNotIn(SERIAL, guard._READ_SCRIPT)
        self.assertNotIn(PACKAGE, guard._READ_SCRIPT)

    def test_runtime_resolution_keeps_hotpush_order_then_appends_eex_and_ssl(self) -> None:
        dependency = self.build_root / "runtime_dep" / "ebin"
        dependency.mkdir(parents=True)
        frame = runtime_frame(
            (dependency, self.root), self.eex_root, self.ssl_root
        )

        sources = guard._parse_runtime_sources(frame, self.build_root)

        self.assertEqual("ok", sources.category)
        self.assertEqual(
            (dependency, self.root, self.eex_root, self.ssl_root), sources.roots
        )

    def test_runtime_resolution_failure_malformed_frame_and_crypto_shim_fail_closed(self) -> None:
        cases = (
            (guard.CommandResult("failed", 1, SECRET.encode()), "expected_runtime_resolution_failed"),
            (guard.CommandResult("ok", 0, SECRET.encode()), "expected_runtime_resolution_malformed"),
            (self.runtime_result(crypto=b"SHIM_REQUIRED"), "expected_runtime_unsupported"),
        )
        for runtime_result, expected_status in cases:
            with self.subTest(status=expected_status):
                runner = FakeRunner(
                    guard.CommandResult("ok", 0, manifest(*self.payloads)),
                    runtime_result=runtime_result,
                )
                result = guard.verify_android_beam_provenance(
                    SERIAL, PACKAGE, self.build_root, runner=runner
                )
                self.assertEqual(expected_status, result.status)
                self.assertEqual([], runner.calls)
                self.assertNotIn(SECRET, json.dumps(result.public()))

    def test_runtime_resolution_rejects_missing_duplicate_and_non_ascii_roots(self) -> None:
        duplicate = runtime_frame(
            (self.root, self.root), self.eex_root, self.ssl_root
        )
        missing_runtime = (
            b"CASEIN_RUNTIME_BEAM_DIRS_V4\n"
            + b"EEX\t"
            + encoded_path(self.eex_root)
            + b"\nSSL\t"
            + encoded_path(self.ssl_root)
            + b"\nCRYPTO\tREAL\nEND\n"
        )
        non_ascii_path = base64.urlsafe_b64encode(
            "/tmp/non-ascii-\N{SNOWMAN}/ebin".encode("utf-8")
        ).rstrip(b"=")
        non_ascii = (
            b"CASEIN_RUNTIME_BEAM_DIRS_V4\nRUNTIME\t"
            + non_ascii_path
            + b"\nEEX\t"
            + encoded_path(self.eex_root)
            + b"\nSSL\t"
            + encoded_path(self.ssl_root)
            + b"\nCRYPTO\tREAL\nEND\n"
        )
        for payload in (duplicate, missing_runtime, non_ascii):
            with self.subTest(length=len(payload)):
                self.assertEqual(
                    "malformed",
                    guard._parse_runtime_sources(payload, self.build_root).category,
                )

    def test_flattened_basename_collision_is_terminal_before_adb(self) -> None:
        dependency = self.build_root / "runtime_dep" / "ebin"
        dependency.mkdir(parents=True)
        collision_name = sorted(self.payloads)[0]
        (dependency / collision_name).write_bytes(b"other-reviewed-content")
        runner = self.runner(*self.payloads)
        runner.runtime_result = self.runtime_result(runtime=(self.root, dependency))

        result = self.verify(runner)

        self.assertEqual("expected_manifest_collision", result.status)
        self.assertEqual([], runner.calls)

    def test_selected_source_symlink_and_missing_auxiliary_root_fail_before_adb(self) -> None:
        real_dependency = self.build_root / "real_dep" / "ebin"
        real_dependency.mkdir(parents=True)
        (real_dependency / "Elixir.RealDep.beam").write_bytes(b"dep")
        linked_dependency = self.build_root / "linked_dep" / "ebin"
        linked_dependency.parent.mkdir(parents=True)
        linked_dependency.symlink_to(real_dependency, target_is_directory=True)
        runner = self.runner(*self.payloads)
        runner.runtime_result = self.runtime_result(runtime=(self.root, linked_dependency))
        self.assertEqual("expected_manifest_symlink", self.verify(runner).status)
        self.assertEqual([], runner.calls)

        missing_eex = Path(self.temp.name) / "missing-toolchain" / "eex" / "ebin"
        runner = self.runner(*self.payloads)
        runner.runtime_result = self.runtime_result(eex=missing_eex)
        self.assertEqual(
            "expected_manifest_read_failed", self.verify(runner).status
        )
        self.assertEqual([], runner.calls)

    def test_bounds_cover_current_runtime_but_remain_finite(self) -> None:
        self.assertGreaterEqual(guard.MAX_BEAMS, 2000)
        self.assertLessEqual(guard.MAX_BEAMS, 4096)
        self.assertEqual(16 * 1024 * 1024, guard.MAX_BEAM_BYTES)
        self.assertEqual(128 * 1024 * 1024, guard.MAX_AGGREGATE_BEAM_BYTES)
        self.assertLessEqual(guard.MAX_SOURCE_DIRS, 512)
        self.assertAlmostEqual(198.36, guard._manifest_timeout_seconds(1403))
        self.assertEqual(
            guard.MANIFEST_TIMEOUT_MIN_SECONDS,
            guard._manifest_timeout_seconds(1),
        )
        self.assertEqual(
            guard.MANIFEST_TIMEOUT_MAX_SECONDS,
            guard._manifest_timeout_seconds(guard.MAX_BEAMS),
        )

    def test_manifest_timeout_policy_rejects_malformed_and_huge_counts(self) -> None:
        for count in (None, True, 0, -1, "4", guard.MAX_BEAMS + 1):
            with self.subTest(count=count):
                self.assertIsNone(guard._manifest_timeout_seconds(count))

        runner = self.runner(*self.payloads)
        status, installed, diagnostics = guard._read_installed_manifest(
            SERIAL,
            PACKAGE,
            runner,
            frozenset(f"Elixir.Module{index}.beam" for index in range(guard.MAX_BEAMS + 1)),
        )
        self.assertEqual("installed_manifest_failed", status)
        self.assertIsNone(installed)
        self.assertEqual(guard.ManifestDiagnostics(), diagnostics)
        self.assertEqual([], runner.calls)

    def test_fixed_device_shell_programs_pass_shell_syntax(self) -> None:
        for program in (guard._MANIFEST_SCRIPT, guard._READ_SCRIPT):
            with self.subTest(size=len(program)):
                result = subprocess.run(
                    ["sh", "-n", "-c", program],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
                self.assertEqual(0, result.returncode)

    def test_device_shell_fd_identity_contract_uses_parent_shell_proc_and_ef(self) -> None:
        for program in (guard._MANIFEST_SCRIPT, guard._READ_SCRIPT):
            with self.subTest(size=len(program)):
                self.assertNotIn("/proc/self/fd/3", program)
                self.assertNotIn("stat -L", program)
                self.assertNotIn("stat -Lc", program)
                self.assertEqual(2, program.count('[ "$path" -ef "/proc/$$/fd/3" ]'))
                self.assertGreaterEqual(
                    program.count("stat -c '%d:%i:%f:%s:%Y:%Z' \"$path\""),
                    3,
                )

        self.assertIn('[ "$before" = "$after_open" ] || finish CHANGED', guard._MANIFEST_SCRIPT)
        self.assertIn('[ "$after_path" = "$opened" ] || finish CHANGED', guard._MANIFEST_SCRIPT)
        self.assertIn('[ "$expected" = "$before" ] &&', guard._READ_SCRIPT)
        self.assertIn('[ "$before" = "$after_open" ] || finish CHANGED', guard._READ_SCRIPT)
        self.assertIn(
            '[ "$after_path" = "$opened" ] || finish_data CHANGED',
            guard._READ_SCRIPT,
        )

    def test_android9_shaped_fake_adb_exec_out_boundary_is_exact(self) -> None:
        fake_root, environment = self.fake_adb_environment("exact")
        installed_root = fake_root / guard.INSTALLED_BEAM_DIR
        installed_root.mkdir(parents=True)
        for name, payload in self.payloads.items():
            (installed_root / name).write_bytes(payload)

        runner = BoundaryRunner(self.runtime_result())
        with mock.patch.dict(os.environ, environment):
            result = self.verify(runner)

        self.assertEqual("exact", result.status)
        self.assertTrue(result.exact)

    def test_streaming_slow_manifest_completes_under_count_calibrated_cap(self) -> None:
        fake_root, environment = self.fake_adb_environment("streaming-slow")
        installed_root = fake_root / guard.INSTALLED_BEAM_DIR
        installed_root.mkdir(parents=True)
        for name, payload in self.payloads.items():
            (installed_root / name).write_bytes(payload)

        runner = guard.SubprocessCommandRunner()
        with mock.patch.dict(
            os.environ,
            {
                **environment,
                "CASEIN_FAKE_ADB_MODE": "stream",
                "CASEIN_FAKE_SHA_DELAY": "0.15",
            },
        ), mock.patch.object(
            guard, "MANIFEST_TIMEOUT_BASE_SECONDS", 1.0
        ), mock.patch.object(
            guard, "MANIFEST_TIMEOUT_PER_BEAM_SECONDS", 0.5
        ), mock.patch.object(
            guard, "MANIFEST_TIMEOUT_MIN_SECONDS", 1.0
        ), mock.patch.object(
            guard, "MANIFEST_TIMEOUT_MAX_SECONDS", 4.0
        ), mock.patch.object(
            guard, "MANIFEST_IDLE_TIMEOUT_SECONDS", 0.75
        ):
            status, installed, diagnostics = guard._read_installed_manifest(
                SERIAL, PACKAGE, runner, frozenset(self.payloads)
            )

        self.assertEqual("ok", status)
        self.assertIsNotNone(installed)
        self.assertEqual("none", diagnostics.timeout_reason)
        self.assertEqual(len(self.payloads), diagnostics.completed_record_count)
        self.assertEqual(len(self.payloads), len(installed.entries))

    def test_fake_adb_fd_alias_mismatch_fails_closed(self) -> None:
        fake_root, environment = self.fake_adb_environment("fd-alias-mismatch")
        installed_root = fake_root / guard.INSTALLED_BEAM_DIR
        installed_root.mkdir(parents=True)
        for name, payload in self.payloads.items():
            (installed_root / name).write_bytes(payload)

        runner = BoundaryRunner(self.runtime_result())
        with mock.patch.dict(
            os.environ,
            {**environment, "CASEIN_FAKE_FD_ALIAS_MODE": "mismatch"},
        ):
            result = self.verify(runner)

        self.assertEqual("installed_manifest_changed", result.status)
        self.assertFalse(result.exact)

    def test_fake_adb_host_zero_requires_complete_framed_remote_status(self) -> None:
        fake_root, environment = self.fake_adb_environment("failures")
        runner = BoundaryRunner(self.runtime_result())

        for mode in ("empty", "truncated"):
            with self.subTest(mode=mode), mock.patch.dict(
                os.environ,
                {**environment, "CASEIN_FAKE_ADB_MODE": mode},
            ):
                self.assertEqual(
                    "installed_manifest_malformed", self.verify(runner).status
                )

        with mock.patch.dict(os.environ, environment):
            self.assertEqual("installed_manifest_missing", self.verify(runner).status)

        installed_root = fake_root / guard.INSTALLED_BEAM_DIR
        installed_root.mkdir(parents=True)
        for name, payload in self.payloads.items():
            (installed_root / name).write_bytes(payload)

        cases = (
            ("CASEIN_FAKE_STAT_MODE", "fail", "installed_manifest_changed"),
            ("CASEIN_FAKE_SHA_MODE", "fail", "installed_manifest_failed"),
            ("CASEIN_FAKE_CAT_MODE", "partial", "installed_beam_failed"),
        )
        for variable, value, status in cases:
            with self.subTest(variable=variable), mock.patch.dict(
                os.environ,
                {**environment, variable: value},
            ):
                self.assertEqual(status, self.verify(runner).status)

    def test_read_frame_is_size_delimited_and_terminal(self) -> None:
        payload = b"beam\x00bytes\nSTATUS\tOK\nEND\ninside"
        self.assertEqual(
            guard.InstalledRead("ok", payload),
            guard._parse_installed_read(read_frame(payload), len(payload)),
        )

        malformed = (
            b"",
            b"CASEIN_BEAM_READ_V1\n",
            b"CASEIN_BEAM_READ_V1\nDATA\nabc",
            b"CASEIN_BEAM_READ_V1\nSTATUS\tUNKNOWN\nEND\n",
            read_frame(b"abc") + b"trailing",
            read_frame(b"abc") + b"STATUS\tOK\nEND\n",
        )
        for frame in malformed:
            with self.subTest(length=len(frame)):
                self.assertNotEqual(
                    "ok", guard._parse_installed_read(frame, 3).category
                )

        self.assertEqual(
            "size_mismatch",
            guard._parse_installed_read(read_frame(b"short"), 6).category,
        )
        self.assertEqual(
            "changed",
            guard._parse_installed_read(
                read_frame(payload, status=b"CHANGED"), len(payload)
            ).category,
        )
        self.assertEqual(
            "read_failed",
            guard._parse_installed_read(
                read_frame(b"partial", status=b"READ_FAILED"), len(payload)
            ).category,
        )

    def test_malformed_read_frames_stop_production_flow_without_retry(self) -> None:
        first_name = sorted(self.payloads)[0]
        payload = self.payloads[first_name]
        malformed = (
            b"CASEIN_BEAM_READ_V1\nDATA\n" + payload,
            b"CASEIN_BEAM_READ_V1\nDATA\n" + payload + b"\nEND\n",
            b"CASEIN_BEAM_READ_V1\nSTATUS\tUNKNOWN\nEND\n",
            read_frame(payload) + b"STATUS\tOK\nEND\n",
            read_frame(payload) + b"trailing-" + SECRET.encode(),
            read_frame(payload[:-1]),
        )
        for frame in malformed:
            with self.subTest(length=len(frame)):
                beams: dict[str, bytes | guard.CommandResult] = dict(self.payloads)
                beams[first_name] = guard.CommandResult("ok", 0, frame)
                runner = self.runner(*self.payloads, beams=beams)

                result = self.verify(runner)

                self.assertEqual("installed_beam_invalid", result.status)
                self.assertFalse(result.exact)
                self.assertEqual(2, len(runner.calls))
                self.assertNotIn(SECRET, json.dumps(result.public()))

    def test_invalid_inputs_never_invoke_adb(self) -> None:
        runner = self.runner(*self.payloads)
        cases = (
            ("serial;touch", PACKAGE, self.build_root),
            (SERIAL, "com.example.other", self.build_root),
            (SERIAL, PACKAGE, Path("_build/dev/lib")),
            (SERIAL, PACKAGE, self.build_root.parent),
            (SERIAL, PACKAGE, Path("/tmp/non-ascii-\N{SNOWMAN}/_build/dev/lib")),
        )
        for serial, package, root in cases:
            with self.subTest(root=root.name):
                result = guard.verify_android_beam_provenance(
                    serial, package, root, runner=runner
                )
                self.assertEqual("invalid_arguments", result.status)
        self.assertEqual([], runner.calls)

    def test_local_root_symlink_is_invalid_input(self) -> None:
        linked_parent = Path(self.temp.name) / "linked" / "_build" / "dev"
        linked_parent.mkdir(parents=True)
        linked = linked_parent / "lib"
        linked.symlink_to(self.build_root, target_is_directory=True)
        runner = self.runner(*self.payloads)
        self.assertEqual(
            "invalid_arguments",
            guard.verify_android_beam_provenance(
                SERIAL, PACKAGE, linked, runner=runner
            ).status,
        )
        self.assertEqual([], runner.calls)

    def test_missing_local_manifest_fails_before_adb(self) -> None:
        for path in self.root.glob("*.beam"):
            path.unlink()
        runner = self.runner()
        self.assertEqual("expected_manifest_missing", self.verify(runner).status)
        self.assertEqual([], runner.calls)

    def test_unsafe_local_name_fails_before_adb_without_reflection(self) -> None:
        (self.root / "bad name.beam").write_bytes(b"secret")
        runner = self.runner(*self.payloads)
        result = self.verify(runner)
        self.assertEqual("expected_manifest_unsafe_name", result.status)
        self.assertNotIn("bad name", json.dumps(result.public()))
        self.assertEqual([], runner.calls)

    def test_local_symlink_and_nonregular_entry_fail_before_adb(self) -> None:
        target = self.root / "target"
        target.write_bytes(b"target")
        link = self.root / "Elixir.Link.beam"
        link.symlink_to(target)
        runner = self.runner(*self.payloads)
        self.assertEqual("expected_manifest_symlink", self.verify(runner).status)
        self.assertEqual([], runner.calls)

        link.unlink()
        (self.root / "Elixir.Directory.beam").mkdir()
        runner = self.runner(*self.payloads)
        self.assertEqual("expected_manifest_invalid_entry", self.verify(runner).status)
        self.assertEqual([], runner.calls)

    def test_local_count_file_and_aggregate_caps_fail_before_adb(self) -> None:
        runner = self.runner(*self.payloads)
        with mock.patch.object(guard, "MAX_BEAMS", 1):
            self.assertEqual("expected_manifest_limited", self.verify(runner).status)
        self.assertEqual([], runner.calls)

    def test_local_regular_file_replacement_between_snapshot_and_open_fails(self) -> None:
        original_hash = guard._hash_local_beam
        replaced = False

        def replace_then_hash(root_fd, name, identity):
            nonlocal replaced
            if not replaced:
                replacement = self.root / "replacement.tmp"
                replacement.write_bytes(self.payloads[name])
                os.replace(replacement, self.root / name)
                replaced = True
            return original_hash(root_fd, name, identity)

        runner = self.runner(*self.payloads)
        with mock.patch.object(guard, "_hash_local_beam", side_effect=replace_then_hash):
            result = self.verify(runner)
        self.assertEqual("expected_manifest_read_failed", result.status)
        self.assertEqual([], runner.calls)

        runner = self.runner(*self.payloads)
        with mock.patch.object(guard, "MAX_BEAM_BYTES", 4):
            self.assertEqual("expected_manifest_limited", self.verify(runner).status)
        self.assertEqual([], runner.calls)

        runner = self.runner(*self.payloads)
        with mock.patch.object(guard, "MAX_AGGREGATE_BEAM_BYTES", 15):
            self.assertEqual("expected_manifest_limited", self.verify(runner).status)
        self.assertEqual([], runner.calls)

    def test_installed_manifest_transport_and_framed_device_failures_are_fixed(self) -> None:
        cases = (
            (guard.CommandResult("failed", 1, SECRET.encode()), "installed_manifest_failed"),
            (guard.CommandResult("timeout", None, SECRET.encode()), "installed_manifest_failed"),
            (guard.CommandResult("output_limit", None, SECRET.encode()), "installed_manifest_limited"),
            (guard.CommandResult("ok", 41, manifest(status=b"MISSING")), "installed_manifest_failed"),
            (guard.CommandResult("ok", 0, manifest(status=b"MISSING")), "installed_manifest_missing"),
            (guard.CommandResult("ok", 0, manifest(status=b"INVALID")), "installed_manifest_invalid_entry"),
            (guard.CommandResult("ok", 0, manifest(status=b"LIMITED")), "installed_manifest_limited"),
            (guard.CommandResult("ok", 0, manifest(status=b"CHANGED")), "installed_manifest_changed"),
            (guard.CommandResult("ok", 0, manifest(status=b"HASH_FAILED")), "installed_manifest_failed"),
        )
        for command, status in cases:
            with self.subTest(status=status, code=command.returncode):
                runner = FakeRunner(command)
                result = self.verify(runner)
                self.assertEqual(status, result.status)
                self.assertTrue(result.expected_manifest_valid)
                self.assertFalse(result.exact)
                self.assertNotIn(SECRET, json.dumps(result.public()))
                self.assertEqual(1, len(runner.calls))

    def test_manifest_failure_diagnostics_are_fixed_capped_and_nonreflecting(self) -> None:
        names = tuple(sorted(self.payloads)[:2])
        complete = manifest(*names, payloads=self.payloads)
        partial = b"\n".join(complete.split(b"\n")[:-3]) + b"\n"

        cases = (
            (
                guard.CommandResult("timeout", -15, partial, "idle"),
                "installed_manifest_failed",
                "idle",
            ),
            (
                guard.CommandResult("timeout", -15, partial, "total"),
                "installed_manifest_failed",
                "total",
            ),
            (
                guard.CommandResult("ok", 7, partial),
                "installed_manifest_failed",
                "none",
            ),
            (
                guard.CommandResult("ok", 0, partial),
                "installed_manifest_malformed",
                "none",
            ),
        )
        for command, status, reason in cases:
            with self.subTest(status=status, reason=reason):
                runner = FakeRunner(command, runtime_result=self.runtime_result())
                result = self.verify(runner)
                public = json.dumps(result.public(), sort_keys=True)
                self.assertEqual(status, result.status)
                self.assertEqual(reason, result.timeout_reason)
                self.assertEqual(len(names), result.completed_record_count)
                self.assertEqual(len(names), result.valid_record_count)
                self.assertEqual(len(names), result.unique_name_count)
                self.assertEqual(0, result.duplicate_name_count)
                self.assertEqual(len(names), result.expected_name_match_count)
                self.assertEqual(0, result.unexpected_name_count)
                self.assertEqual(len(self.payloads) - len(names), result.missing_name_count)
                self.assertEqual("incomplete_prefix", result.manifest_capture_scope)
                self.assertNotIn(SECRET, public)
                self.assertNotIn(SERIAL, public)
                self.assertNotIn(PACKAGE, public)

        oversized = (
            guard._MANIFEST_HEADER
            + b"\n"
            + (b"opaque\topaque\topaque\n" * (guard.MAX_BEAMS + 2))
        )
        self.assertEqual(
            guard.MAX_BEAMS,
            guard._completed_manifest_record_count(oversized),
        )
        capped = guard._manifest_diagnostics(
            guard._MANIFEST_HEADER
            + b"\n"
            + (
                b"Elixir.Repeated.beam\t1:2:81a4:4:5:6\t"
                + b"0" * 64
                + b"\n"
            )
            * (guard.MAX_BEAMS + 2),
            frozenset(self.payloads),
        )
        self.assertEqual(guard.MAX_BEAMS, capped.completed_record_count)
        self.assertEqual(guard.MAX_BEAMS, capped.valid_record_count)
        self.assertEqual(1, capped.unique_name_count)
        self.assertEqual(guard.MAX_BEAMS - 1, capped.duplicate_name_count)

    def test_manifest_diagnostic_sanitizes_untrusted_values(self) -> None:
        result = guard.GuardResult(
            "installed_manifest_failed",
            timeout_reason=SECRET,
            completed_record_count=guard.MAX_BEAMS + 1,
            valid_record_count=True,
            manifest_capture_scope=SECRET,
        )
        self.assertEqual("none", result.timeout_reason)
        self.assertEqual(0, result.completed_record_count)
        self.assertEqual(0, result.valid_record_count)
        self.assertEqual("none", result.manifest_capture_scope)
        self.assertNotIn(SECRET, json.dumps(result.public()))

        exact = guard.GuardResult(
            "exact",
            valid_record_count=1,
            unique_name_count=1,
            manifest_capture_scope="complete",
        )
        self.assertEqual(0, exact.valid_record_count)
        self.assertEqual(0, exact.unique_name_count)
        self.assertEqual("none", exact.manifest_capture_scope)

    def test_manifest_aggregate_diagnostics_distinguish_duplicates_from_unexpected_names(self) -> None:
        expected = tuple(self.payloads)
        duplicate_payload = manifest(*expected, expected[0], expected[1], payloads=self.payloads)
        duplicate_result = self.verify(FakeRunner(guard.CommandResult("ok", 0, duplicate_payload)))
        self.assertEqual("installed_manifest_duplicate", duplicate_result.status)
        self.assertEqual(len(expected) + 2, duplicate_result.valid_record_count)
        self.assertEqual(len(expected), duplicate_result.unique_name_count)
        self.assertEqual(2, duplicate_result.duplicate_name_count)
        self.assertEqual(len(expected), duplicate_result.expected_name_match_count)
        self.assertEqual(0, duplicate_result.unexpected_name_count)
        self.assertEqual(0, duplicate_result.missing_name_count)
        self.assertEqual("complete", duplicate_result.manifest_capture_scope)

        extras = ("Elixir.UnexpectedOne.beam", "Elixir.UnexpectedTwo.beam")
        overlay_payload = manifest(*expected, *extras, payloads=self.payloads)
        overlay_result = self.verify(FakeRunner(guard.CommandResult("ok", 0, overlay_payload)))
        self.assertEqual("beam_name_set_mismatch", overlay_result.status)
        self.assertEqual(len(expected) + 2, overlay_result.valid_record_count)
        self.assertEqual(len(expected) + 2, overlay_result.unique_name_count)
        self.assertEqual(0, overlay_result.duplicate_name_count)
        self.assertEqual(len(expected), overlay_result.expected_name_match_count)
        self.assertEqual(2, overlay_result.unexpected_name_count)
        self.assertEqual(0, overlay_result.missing_name_count)
        self.assertEqual("complete", overlay_result.manifest_capture_scope)

    def test_completed_frame_counter_is_broader_than_valid_record_diagnostics(self) -> None:
        payload = (
            guard._MANIFEST_HEADER
            + b"\nopaque\topaque\topaque\n"
            + b"STATUS\tOK\nEND\n"
        )
        diagnostics = guard._manifest_diagnostics(payload, frozenset(self.payloads))
        self.assertEqual(1, diagnostics.completed_record_count)
        self.assertEqual(0, diagnostics.valid_record_count)
        self.assertEqual(0, diagnostics.unique_name_count)
        self.assertEqual(len(self.payloads), diagnostics.missing_name_count)
        self.assertEqual("complete", diagnostics.manifest_capture_scope)

    def test_truncated_and_malformed_manifest_frames_are_rejected(self) -> None:
        digest = b"0" * 64
        malformed = (
            b"",
            b"CASEIN_BEAMS_V5\nElixir.One.beam\t1:2:81a4:4:5:6\t" + digest + b"\nSTATUS\tOK\nEND",
            b"WRONG\nElixir.One.beam\t1:2:81a4:4:5:6\t" + digest + b"\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\nEND\n",
            b"CASEIN_BEAMS_V5\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\n\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\nElixir.One.beam\t1:2:81a4:4:5:6\t" + digest + b"\nSTATUS\tOK\nEND\ntrailing\n",
            b"CASEIN_BEAMS_V5\nElixir.One.beam\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\nElixir.One.beam\tnot-an-identity\t" + digest + b"\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\nElixir.One.beam\t1:2:81a4:4:5:6\tnot-a-digest\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\nSTATUS\tMISSING\nSTATUS\tMISSING\nEND\n",
            b"CASEIN_BEAMS_V5\nSTATUS\tUNKNOWN\nEND\n",
            b"CASEIN_BEAMS_V5\nSTATUS\tMISSING\nEND\nSTATUS\tMISSING\nEND\n",
        )
        for payload in malformed:
            with self.subTest(length=len(payload)):
                runner = FakeRunner(guard.CommandResult("ok", 0, payload))
                result = self.verify(runner)
                self.assertEqual("installed_manifest_malformed", result.status)
                self.assertEqual(1, len(runner.calls))

    def test_duplicate_and_unsafe_manifest_names_are_distinct(self) -> None:
        duplicate = manifest(
            "Elixir.CaseinMob.App.beam", "Elixir.CaseinMob.App.beam"
        )
        runner = FakeRunner(guard.CommandResult("ok", 0, duplicate))
        self.assertEqual("installed_manifest_duplicate", self.verify(runner).status)

        unsafe_payloads = (
            b"CASEIN_BEAMS_V5\n../escape.beam\t1:2:81a4:4:5:6\t" + b"0" * 64 + b"\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\nbad name.beam\t1:2:81a4:4:5:6\t" + b"0" * 64 + b"\nSTATUS\tOK\nEND\n",
            b"CASEIN_BEAMS_V5\nElixir.Bad.\xff.beam\t1:2:81a4:4:5:6\t" + b"0" * 64 + b"\nSTATUS\tOK\nEND\n",
        )
        for payload in unsafe_payloads:
            with self.subTest(payload=payload[:20]):
                runner = FakeRunner(guard.CommandResult("ok", 0, payload))
                self.assertEqual(
                    "installed_manifest_unsafe_name", self.verify(runner).status
                )

    def test_manifest_name_count_and_payload_caps_are_rejected(self) -> None:
        names = tuple(f"Elixir.Module{index}.beam" for index in range(3))
        with mock.patch.object(guard, "MAX_BEAMS", 2):
            self.assertEqual(
                "limited", guard._parse_installed_manifest(manifest(*names)).category
            )

        runner = FakeRunner(guard.CommandResult("ok", 0, manifest(*self.payloads)))
        with mock.patch.object(guard, "MAX_MANIFEST_BYTES", 8):
            self.assertEqual("installed_manifest_malformed", self.verify(runner).status)

    def test_missing_or_extra_names_fail_before_any_beam_read(self) -> None:
        cases = (
            (tuple(self.payloads)[:1],),
            (tuple(self.payloads) + ("Elixir.Extra.beam",),),
        )
        for (names,) in cases:
            with self.subTest(count=len(names)):
                runner = self.runner(*names)
                result = self.verify(runner)
                self.assertEqual("beam_name_set_mismatch", result.status)
                self.assertTrue(result.installed_manifest_complete)
                self.assertFalse(result.beam_name_set_match)
                self.assertEqual(1, len(runner.calls))

    def test_digest_mismatch_stops_without_retry_or_hash_reflection(self) -> None:
        first_name = sorted(self.payloads)[0]
        changed = dict(self.payloads)
        changed[first_name] = b"x" * len(self.payloads[first_name])
        runner = self.runner(*reversed(tuple(self.payloads)), beams=changed)

        result = self.verify(runner)

        public = json.dumps(result.public(), sort_keys=True)
        self.assertEqual("beam_digest_mismatch", result.status)
        self.assertTrue(result.beam_name_set_match)
        self.assertFalse(result.beam_digest_match)
        self.assertEqual(2, len(runner.calls))
        self.assertNotIn(hashlib.sha256(changed[first_name]).hexdigest(), public)
        self.assertNotIn(SECRET, public)

    def test_installed_read_failures_are_fixed_and_not_retried(self) -> None:
        first_name = sorted(self.payloads)[0]
        cases = (
            (
                guard.CommandResult("ok", 0, read_frame(status=b"MISSING")),
                "installed_beam_missing",
            ),
            (
                guard.CommandResult("ok", 0, read_frame(status=b"INVALID")),
                "installed_beam_invalid_entry",
            ),
            (
                guard.CommandResult("ok", 0, read_frame(status=b"LIMITED")),
                "installed_beam_limited",
            ),
            (
                guard.CommandResult("ok", 0, read_frame(b"partial", status=b"READ_FAILED")),
                "installed_beam_failed",
            ),
            (
                guard.CommandResult("ok", 41, read_frame(status=b"MISSING")),
                "installed_beam_failed",
            ),
            (guard.CommandResult("failed", 1, SECRET.encode()), "installed_beam_failed"),
            (guard.CommandResult("timeout", None, SECRET.encode()), "installed_beam_failed"),
            (
                guard.CommandResult("output_limit", None, SECRET.encode()),
                "installed_beam_limited",
            ),
            (guard.CommandResult("ok", 0, b""), "installed_beam_invalid"),
        )
        for command, status in cases:
            with self.subTest(status=status):
                beams = dict(self.payloads)
                beams[first_name] = command
                runner = self.runner(*self.payloads, beams=beams)
                result = self.verify(runner)
                self.assertEqual(status, result.status)
                self.assertEqual(2, len(runner.calls))
                self.assertNotIn(SECRET, json.dumps(result.public()))

    def test_installed_path_identity_and_closing_snapshot_changes_fail(self) -> None:
        first_name = sorted(self.payloads)[0]
        beams = dict(self.payloads)
        beams[first_name] = guard.CommandResult(
            "ok",
            0,
            read_frame(self.payloads[first_name], status=b"CHANGED"),
        )
        runner = self.runner(*self.payloads, beams=beams)
        result = self.verify(runner)
        self.assertEqual("installed_beam_changed", result.status)
        self.assertEqual(2, len(runner.calls))

        extra = "Elixir.AddedAfterRead.beam"
        runner = ChangingManifestRunner(
            manifest(*self.payloads, payloads=self.payloads),
            manifest(*self.payloads, extra, payloads=self.payloads),
            dict(self.payloads),
        )
        result = self.verify(runner)
        self.assertEqual("installed_manifest_changed", result.status)
        self.assertEqual(2, runner.manifest_calls)
        self.assertFalse(result.exact)

        changed_identities = {
            first_name: installed_identity(first_name, generation=2),
        }
        runner = ChangingManifestRunner(
            manifest(*self.payloads, payloads=self.payloads),
            manifest(
                *self.payloads,
                identities=changed_identities,
                payloads=self.payloads,
            ),
            dict(self.payloads),
        )
        result = self.verify(runner)
        self.assertEqual("installed_manifest_changed", result.status)
        self.assertEqual(2, runner.manifest_calls)
        self.assertFalse(result.exact)

        changed_payloads = dict(self.payloads)
        changed_payloads[first_name] = b"changed-after-successful-read"
        runner = ChangingManifestRunner(
            manifest(*self.payloads, payloads=self.payloads),
            manifest(*self.payloads, payloads=changed_payloads),
            dict(self.payloads),
        )
        result = self.verify(runner)
        self.assertEqual("installed_manifest_changed", result.status)
        self.assertEqual(2, runner.manifest_calls)
        self.assertFalse(result.exact)

    def test_runner_cannot_bypass_the_per_file_cap(self) -> None:
        first_name = sorted(self.payloads)[0]
        beams = dict(self.payloads)
        beams[first_name] = b"x" * 9
        runner = self.runner(*self.payloads, beams=beams)
        with mock.patch.object(guard, "MAX_BEAM_BYTES", 8):
            result = self.verify(runner)
        self.assertEqual("expected_manifest_limited", result.status)
        self.assertEqual([], runner.calls)

        for path in self.root.glob("*.beam"):
            path.unlink()
        (self.root / "Elixir.A.beam").write_bytes(b"a")
        small = {
            "Elixir.A.beam": b"a",
            "Elixir.EEx.beam": b"e",
            "ssl.beam": b"s",
        }
        name = "Elixir.A.beam"
        installed = dict(small)
        installed[name] = b"x" * 9
        runner = self.runner(
            *small,
            beams=installed,
            identities={
                beam_name: installed_identity(beam_name, size=len(payload))
                for beam_name, payload in small.items()
            },
            manifest_payloads=small,
        )
        with mock.patch.object(guard, "MAX_BEAM_BYTES", 8):
            result = self.verify(runner)
        self.assertEqual("installed_beam_limited", result.status)
        self.assertEqual(2, len(runner.calls))

    def test_installed_aggregate_cap_is_enforced_before_digest_comparison(self) -> None:
        first_name = sorted(self.payloads)[0]
        beams = dict(self.payloads)
        beams[first_name] = b"12345678"
        runner = self.runner(*self.payloads, beams=beams)
        with mock.patch.object(guard, "MAX_AGGREGATE_BEAM_BYTES", 4):
            result = self.verify(runner)
        self.assertEqual("expected_manifest_limited", result.status)
        self.assertEqual([], runner.calls)

        # Let the reviewed two-byte set fit while the first installed file does not.
        for path in self.root.glob("*.beam"):
            path.unlink()
        small = {
            "Elixir.A.beam": b"a",
            "Elixir.EEx.beam": b"e",
            "ssl.beam": b"s",
        }
        (self.root / "Elixir.A.beam").write_bytes(b"a")
        installed = dict(small)
        installed["Elixir.A.beam"] = b"1234"
        identities = {
            name: installed_identity(name, size=len(payload))
            for name, payload in small.items()
        }
        runner = self.runner(
            *small,
            beams=installed,
            identities=identities,
            manifest_payloads=small,
        )
        with mock.patch.object(guard, "MAX_AGGREGATE_BEAM_BYTES", 3):
            result = self.verify(runner)
        self.assertEqual("installed_beam_limited", result.status)
        self.assertEqual(2, len(runner.calls))

    def test_internal_exception_is_enum_only_and_fail_closed(self) -> None:
        result = self.verify(RaisingRunner())
        self.assertEqual("internal_error", result.status)
        self.assertFalse(result.exact)
        self.assertNotIn(SECRET, json.dumps(result.public()))

    def test_cli_emits_exactly_one_fixed_json_line_without_reflection(self) -> None:
        secret_build_root = (
            Path(self.temp.name) / SECRET / "casein_mob" / "_build" / "dev" / "lib"
        )
        secret_ebin = secret_build_root / "casein_mob" / "ebin"
        secret_ebin.mkdir(parents=True)
        (secret_ebin / "Elixir.App.beam").write_bytes(b"beam")
        runner = FakeRunner(
            guard.CommandResult("failed", 1, SECRET.encode()),
            runtime_result=self.runtime_result(runtime=(secret_ebin,)),
        )
        output = io.StringIO()

        exit_code = guard.main(
            [
                "--serial",
                SERIAL,
                "--package",
                PACKAGE,
                "--expected-build-lib-root",
                str(secret_build_root),
            ],
            runner=runner,
            output=output,
        )

        raw = output.getvalue()
        decoded = json.loads(raw)
        self.assertEqual(3, exit_code)
        self.assertEqual(1, raw.count("\n"))
        self.assertTrue(raw.endswith("\n"))
        self.assertEqual(
            {
                "schema_version",
                "component",
                "status",
                "expected_manifest_valid",
                "installed_manifest_complete",
                "beam_name_set_match",
                "beam_digest_match",
                "timeout_reason",
                "completed_record_count",
                "valid_record_count",
                "unique_name_count",
                "duplicate_name_count",
                "expected_name_match_count",
                "unexpected_name_count",
                "missing_name_count",
                "manifest_capture_scope",
                "exact",
            },
            set(decoded),
        )
        self.assertNotIn(SERIAL, raw)
        self.assertNotIn(PACKAGE, raw)
        self.assertNotIn(str(secret_build_root), raw)
        self.assertNotIn(SECRET, raw)

    def test_invalid_cli_arguments_do_not_reflect_values(self) -> None:
        output = io.StringIO()
        exit_code = guard.main(["--serial", SECRET], output=output)
        self.assertEqual(64, exit_code)
        self.assertEqual("invalid_arguments", json.loads(output.getvalue())["status"])
        self.assertNotIn(SECRET, output.getvalue())

    def test_production_runner_never_uses_shell_and_discards_child_stderr(self) -> None:
        reader, writer = socket.socketpair()
        writer.close()
        stream = reader.makefile("rb", buffering=0)
        try:
            with mock.patch.object(
                subprocess, "Popen", return_value=FakeProcess(stdout=stream)
            ) as popen, mock.patch.object(os, "killpg"):
                result = guard.SubprocessCommandRunner().run(
                    ("adb", "version"),
                    stdout_limit=32,
                    timeout_seconds=1.0,
                )
        finally:
            reader.close()

        self.assertEqual("ok", result.category)
        kwargs = popen.call_args.kwargs
        self.assertIs(False, kwargs["shell"])
        self.assertEqual(subprocess.DEVNULL, kwargs["stderr"])
        self.assertEqual(subprocess.DEVNULL, kwargs["stdin"])
        self.assertTrue(kwargs["start_new_session"])

    def test_immediate_exit_oversized_stdout_is_drained_and_rejected(self) -> None:
        limit = 4096
        reader, writer = socket.socketpair()
        try:
            writer.sendall(b"x" * (limit + 4096))
            writer.close()
            stream = reader.makefile("rb", buffering=0)
            with mock.patch.object(
                subprocess, "Popen", return_value=FakeProcess(stdout=stream)
            ), mock.patch.object(os, "killpg"):
                result = guard.SubprocessCommandRunner().run(
                    ("adb", "version"),
                    stdout_limit=limit,
                    timeout_seconds=1.0,
                )
        finally:
            writer.close()
            reader.close()

        self.assertEqual("output_limit", result.category)
        self.assertEqual(limit + 1, len(result.stdout))

    def test_missing_stdout_still_reaps_only_the_child_group(self) -> None:
        process = FakeProcess(stdout=None)
        with mock.patch.object(
            subprocess, "Popen", return_value=process
        ), mock.patch.object(os, "killpg") as killpg:
            result = guard.SubprocessCommandRunner().run(
                ("adb", "version"),
                stdout_limit=32,
                timeout_seconds=1.0,
            )

        self.assertEqual("failed", result.category)
        self.assertEqual(0, result.returncode)
        self.assertEqual(
            [
                mock.call(process.pid, signal.SIGTERM),
                mock.call(process.pid, signal.SIGKILL),
            ],
            killpg.call_args_list,
        )

    def test_non_posix_group_host_fails_before_spawning(self) -> None:
        with mock.patch.object(guard, "_POSIX_GROUP_API", False), mock.patch.object(
            subprocess, "Popen"
        ) as popen:
            result = guard.SubprocessCommandRunner().run(
                ("adb", "version"),
                stdout_limit=32,
                timeout_seconds=1.0,
            )

        self.assertEqual("failed", result.category)
        popen.assert_not_called()

    def test_selector_failure_still_kills_and_reaps_the_owned_group(self) -> None:
        marker = Path(self.temp.name) / "selector-failure-child"
        program = textwrap.dedent(
            """
            import os
            import sys
            import time

            with open(sys.argv[1], "w", encoding="ascii") as stream:
                stream.write(str(os.getpid()))
            time.sleep(60)
            """
        )

        class FailingSelector:
            def register(self, _stream, _events):
                return None

            def select(self, _timeout):
                deadline = time.monotonic() + 1
                while not marker.exists():
                    if time.monotonic() >= deadline:
                        raise OSError
                    time.sleep(0.005)
                raise OSError

            def close(self):
                return None

        with mock.patch.object(selectors, "DefaultSelector", FailingSelector):
            result = guard.SubprocessCommandRunner().run(
                (sys.executable, "-c", program, str(marker)),
                stdout_limit=32,
                timeout_seconds=2.0,
            )

        self.assertEqual("failed", result.category)
        child_pid = int(marker.read_text(encoding="ascii"))
        self.assertTrue(self._wait_for_process_exit(child_pid))

    def test_streaming_progress_completes_within_total_and_idle_caps(self) -> None:
        program = (
            "import sys,time; "
            "[(sys.stdout.write('x'),sys.stdout.flush(),time.sleep(0.04)) "
            "for _ in range(5)]"
        )
        result = guard.SubprocessCommandRunner().run(
            (sys.executable, "-c", program),
            stdout_limit=16,
            timeout_seconds=1.0,
            idle_timeout_seconds=0.1,
        )
        self.assertEqual("ok", result.category)
        self.assertEqual(0, result.returncode)
        self.assertEqual(b"xxxxx", result.stdout)

    def test_stalled_mid_record_hits_idle_timeout_and_cleans_child(self) -> None:
        marker = Path(self.temp.name) / "idle-stall"
        program = textwrap.dedent(
            """
            import os
            import sys
            import time

            with open(sys.argv[1], "w", encoding="ascii") as stream:
                stream.write(str(os.getpid()))
            sys.stdout.write("partial")
            sys.stdout.flush()
            time.sleep(60)
            """
        )
        result = guard.SubprocessCommandRunner().run(
            (sys.executable, "-c", program, str(marker)),
            stdout_limit=32,
            timeout_seconds=1.0,
            idle_timeout_seconds=0.1,
        )
        self.assertEqual("timeout", result.category)
        self.assertEqual("idle", result.timeout_reason)
        self.assertEqual(b"partial", result.stdout)
        self.assertTrue(
            self._wait_for_process_exit(int(marker.read_text(encoding="ascii")))
        )

    def test_continuous_trickle_cannot_extend_total_timeout(self) -> None:
        program = textwrap.dedent(
            """
            import sys
            import time

            while True:
                sys.stdout.write("x")
                sys.stdout.flush()
                time.sleep(0.03)
            """
        )
        started = time.monotonic()
        result = guard.SubprocessCommandRunner().run(
            (sys.executable, "-c", program),
            stdout_limit=64,
            timeout_seconds=0.25,
            idle_timeout_seconds=0.1,
        )
        elapsed = time.monotonic() - started
        self.assertEqual("timeout", result.category)
        self.assertEqual("total", result.timeout_reason)
        self.assertLess(elapsed, 0.75)
        self.assertGreater(len(result.stdout), 1)

    def test_no_output_hits_idle_timeout(self) -> None:
        result = guard.SubprocessCommandRunner().run(
            (sys.executable, "-c", "import time; time.sleep(60)"),
            stdout_limit=8,
            timeout_seconds=1.0,
            idle_timeout_seconds=0.1,
        )
        self.assertEqual("timeout", result.category)
        self.assertEqual("idle", result.timeout_reason)
        self.assertEqual(b"", result.stdout)

    def test_runner_success_and_failure_return_without_signaling_caller(self) -> None:
        runner = guard.SubprocessCommandRunner()
        cases = ((0, "ok"), (7, "ok"))

        for returncode, category in cases:
            with self.subTest(returncode=returncode):
                result = runner.run(
                    (
                        sys.executable,
                        "-c",
                        "import sys; sys.stdout.write('STATUS\\n'); "
                        f"raise SystemExit({returncode})",
                    ),
                    stdout_limit=32,
                    timeout_seconds=1.0,
                )
                self.assertEqual(category, result.category)
                self.assertEqual(returncode, result.returncode)
                self.assertEqual(b"STATUS\n", result.stdout)

        # Reaching this assertion proves child cleanup did not signal the caller.
        self.assertTrue(True)

    def test_success_and_nonzero_exit_kill_silent_child_group_descendants(self) -> None:
        runner = guard.SubprocessCommandRunner()
        for returncode in (0, 7):
            marker = Path(self.temp.name) / f"silent-child-{returncode}"
            program = textwrap.dedent(
                """
                import subprocess
                import sys

                child = subprocess.Popen(
                    [sys.executable, "-c", "import time; time.sleep(60)"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                with open(sys.argv[1], "w", encoding="ascii") as stream:
                    stream.write(str(child.pid))
                sys.stdout.write("STATUS\\n")
                raise SystemExit(int(sys.argv[2]))
                """
            )

            with self.subTest(returncode=returncode):
                result = runner.run(
                    (sys.executable, "-c", program, str(marker), str(returncode)),
                    stdout_limit=32,
                    timeout_seconds=1.0,
                )
                self.assertEqual("ok", result.category)
                self.assertEqual(returncode, result.returncode)
                self.assertEqual(b"STATUS\n", result.stdout)
                child_pid = int(marker.read_text(encoding="ascii"))
                self.assertTrue(self._wait_for_process_exit(child_pid))

    def test_timeout_kills_child_group_without_orphan_or_reflection(self) -> None:
        marker = Path(self.temp.name) / "timeout-child"
        program = textwrap.dedent(
            """
            import os
            import signal
            import subprocess
            import sys
            import time

            ready = sys.argv[3]
            child = subprocess.Popen(
                [sys.executable, "-c", "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(sys.argv[1], 'w').write('R'); time.sleep(60)", ready],
                stdout=sys.stdout,
                stderr=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + 2
            while not os.path.exists(ready):
                if time.monotonic() >= deadline:
                    raise SystemExit(9)
                time.sleep(0.005)
            with open(sys.argv[1], "w", encoding="ascii") as stream:
                stream.write(str(child.pid))
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            sys.stdout.buffer.write(sys.argv[2].encode())
            sys.stdout.buffer.flush()
            time.sleep(60)
            """
        )

        ready = Path(self.temp.name) / "timeout-ready"

        with mock.patch.object(guard, "PROCESS_TERM_TIMEOUT_SECONDS", 0.05), mock.patch.object(
            guard, "PROCESS_KILL_TIMEOUT_SECONDS", 0.2
        ):
            result = guard.SubprocessCommandRunner().run(
                (
                    sys.executable,
                    "-c",
                    program,
                    str(marker),
                    SECRET,
                    str(ready),
                ),
                stdout_limit=256,
                timeout_seconds=0.5,
            )

        self.assertEqual("timeout", result.category)
        self.assertEqual("total", result.timeout_reason)
        self.assertIsNotNone(result.returncode)
        child_pid = int(marker.read_text(encoding="ascii"))
        self.assertTrue(self._wait_for_process_exit(child_pid))

    def test_exited_group_leader_cannot_leave_stdout_holder_orphaned(self) -> None:
        marker = Path(self.temp.name) / "stdout-holder"
        program = textwrap.dedent(
            """
            import subprocess
            import sys

            child = subprocess.Popen(
                [sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"],
                stdout=sys.stdout,
                stderr=subprocess.DEVNULL,
            )
            with open(sys.argv[1], "w", encoding="ascii") as stream:
                stream.write(str(child.pid))
            """
        )

        result = guard.SubprocessCommandRunner().run(
            (sys.executable, "-c", program, str(marker)),
            stdout_limit=32,
            timeout_seconds=1.0,
        )

        self.assertEqual("failed", result.category)
        self.assertEqual(0, result.returncode)
        child_pid = int(marker.read_text(encoding="ascii"))
        self.assertTrue(self._wait_for_process_exit(child_pid))

    @staticmethod
    def _wait_for_process_exit(pid: int) -> bool:
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.01)
        return False


if __name__ == "__main__":
    unittest.main()
