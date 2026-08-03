#!/usr/bin/env python3

from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
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
completed = subprocess.run(
    ["/bin/sh", "-c", args[8], *args[9:]],
    cwd=os.environ["CASEIN_FAKE_DEVICE_ROOT"],
    env=os.environ.copy(),
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
)
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
info = os.fstat(3) if target == "/proc/self/fd/3" else os.stat(target)
sys.stdout.write(f"9:{info.st_ino}:81a4:{info.st_size}:0:0\\n")
""",
            "sha256sum": f"#!{sys.executable}\n"
            + """import hashlib
import os
import sys

if os.environ.get("CASEIN_FAKE_SHA_MODE") == "fail":
    raise SystemExit(1)
sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + "  -\\n")
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
            self.assertEqual(guard.COMMAND_TIMEOUT_SECONDS, kwargs["timeout_seconds"])
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
            ) as popen:
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
            ):
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


if __name__ == "__main__":
    unittest.main()
