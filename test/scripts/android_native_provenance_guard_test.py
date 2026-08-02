#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from collections import deque
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/lib/android_native_provenance_guard.py"
SPEC = importlib.util.spec_from_file_location("android_native_provenance_guard", SCRIPT)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)

SERIAL = "R52M1234.ADB-1:5555"
PACKAGE = guard.ANDROID_PACKAGE
REMOTE_BASE = "/data/app/~~AbC_12==/com.example.casein_mob-XyZ_34==/base.apk"
SECRET = "password=privacy-regression-sentinel"


def library_payload(suffix: bytes = b"") -> bytes:
    return b"native\x00tcp_connect_started\x00tcp_connected\x00" + suffix


def apk_bytes(payload: bytes | None, *, duplicate: bool = False) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        if payload is not None:
            archive.writestr(guard.NATIVE_MEMBER, payload)
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(guard.NATIVE_MEMBER, payload)
        archive.writestr("AndroidManifest.xml", b"bounded")
    return output.getvalue()


class FakeRunner:
    def __init__(
        self,
        query: guard.CommandResult,
        *,
        installed: bytes | None = None,
        pull: guard.CommandResult | None = None,
    ):
        self.results = deque([query, pull or guard.CommandResult("ok", 0)])
        self.installed = installed
        self.calls: list[tuple[tuple[str, ...], dict[str, object]]] = []

    def run(self, argv: tuple[str, ...], **kwargs) -> guard.CommandResult:
        self.calls.append((argv, kwargs))
        result = self.results.popleft()
        artifact_path = kwargs.get("artifact_path")
        if artifact_path is not None and self.installed is not None:
            Path(artifact_path).write_bytes(self.installed)
        return result


class FixedExtension:
    def __init__(self, verdict: guard.ExtensionVerdict | Exception):
        self.verdict = verdict
        self.calls = 0

    def verify(self, _expected: Path, _installed: Path) -> guard.ExtensionVerdict:
        self.calls += 1
        if isinstance(self.verdict, Exception):
            raise self.verdict
        return self.verdict


class FakeProcess:
    pid = 700

    def __init__(self, stdout=None):
        self.stdout = stdout

    def poll(self):
        return 0

    def wait(self, timeout=None):
        return 0


class AndroidNativeProvenanceGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.expected = self.root / "reviewed.apk"
        self.expected.write_bytes(apk_bytes(library_payload()))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def query(self, payload: bytes | None = None) -> guard.CommandResult:
        payload = payload or f"package:{REMOTE_BASE}\n".encode("ascii")
        return guard.CommandResult("ok", 0, payload)

    def temp_factory(self) -> Path:
        return Path(tempfile.mkdtemp(dir=self.root, prefix="guard-"))

    def verify(self, runner: FakeRunner, **kwargs) -> guard.GuardResult:
        return guard.verify_android_native_provenance(
            SERIAL,
            PACKAGE,
            self.expected,
            runner=runner,
            temp_factory=self.temp_factory,
            **kwargs,
        )

    def test_exact_runtime_requires_schema_and_digest(self) -> None:
        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())

        result = self.verify(runner)

        self.assertEqual("exact", result.status)
        self.assertTrue(result.exact)
        self.assertTrue(result.expected_schema_complete)
        self.assertTrue(result.installed_schema_complete)
        self.assertTrue(result.native_digest_match)
        self.assertEqual(
            (
                "adb",
                "--exit-on-write-error",
                "-s",
                SERIAL,
                "shell",
                "pm",
                "path",
                PACKAGE,
            ),
            runner.calls[0][0],
        )
        self.assertEqual("pull", runner.calls[1][0][4])
        self.assertEqual(REMOTE_BASE, runner.calls[1][0][5])
        self.assertEqual(0, runner.calls[1][1]["stdout_limit"])
        self.assertEqual(guard.MAX_APK_BYTES, runner.calls[1][1]["artifact_limit"])

    def test_reviewed_apk_with_stale_stage_schema_fails_before_adb(self) -> None:
        self.expected.write_bytes(apk_bytes(b"native\x00tcp_connect_started\x00"))
        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())

        result = self.verify(runner)

        self.assertEqual("expected_schema_stale", result.status)
        self.assertEqual([], runner.calls)

    def test_installed_schema_stale_is_distinct_from_digest_mismatch(self) -> None:
        runner = FakeRunner(
            self.query(),
            installed=apk_bytes(b"native\x00tcp_connect_started\x00different"),
        )

        result = self.verify(runner)

        self.assertEqual("installed_schema_stale", result.status)
        self.assertFalse(result.native_digest_match)

    def test_digest_mismatch_fails_closed_without_emitting_hashes(self) -> None:
        installed_payload = library_payload(b"different")
        runner = FakeRunner(self.query(), installed=apk_bytes(installed_payload))

        result = self.verify(runner)

        public = json.dumps(result.public(), sort_keys=True)
        self.assertEqual("digest_mismatch", result.status)
        self.assertNotIn(hashlib.sha256(installed_payload).hexdigest(), public)
        self.assertFalse(result.exact)

    def test_missing_and_duplicate_reviewed_members_are_rejected(self) -> None:
        for archive, status in (
            (apk_bytes(None), "expected_native_lib_missing"),
            (apk_bytes(library_payload(), duplicate=True), "expected_apk_invalid"),
        ):
            with self.subTest(status=status):
                self.expected.write_bytes(archive)
                runner = FakeRunner(self.query(), installed=archive)
                self.assertEqual(status, self.verify(runner).status)
                self.assertEqual([], runner.calls)

    def test_missing_and_multiple_base_paths_fail_before_pull(self) -> None:
        cases = (
            (
                b"package:/data/app/example/split_config.armeabi_v7a.apk\n",
                "installed_base_missing",
            ),
            (
                f"package:{REMOTE_BASE}\npackage:/data/app/other/base.apk\n".encode(),
                "installed_base_ambiguous",
            ),
        )
        for payload, status in cases:
            with self.subTest(status=status):
                runner = FakeRunner(self.query(payload), installed=self.expected.read_bytes())
                self.assertEqual(status, self.verify(runner).status)
                self.assertEqual(1, len(runner.calls))

    def test_one_base_plus_split_apks_is_unambiguous(self) -> None:
        payload = (
            f"package:{REMOTE_BASE}\n"
            "package:/data/app/ignored/split_config.armeabi_v7a.apk\n"
        ).encode()
        runner = FakeRunner(self.query(payload), installed=self.expected.read_bytes())

        self.assertEqual("exact", self.verify(runner).status)

    def test_invalid_base_path_and_non_ascii_output_are_rejected(self) -> None:
        for payload in (
            b"package:/data/app/../../private/base.apk\n",
            b"package:/data/app/ok/base.apk\xff\n",
            f"{SECRET}\n".encode(),
        ):
            with self.subTest(payload=payload[:1]):
                runner = FakeRunner(self.query(payload), installed=self.expected.read_bytes())
                self.assertEqual("installed_base_invalid", self.verify(runner).status)
                self.assertEqual(1, len(runner.calls))

    def test_query_failure_and_limit_have_fixed_categories(self) -> None:
        cases = (
            (guard.CommandResult("failed", 1, SECRET.encode()), "device_query_failed"),
            (guard.CommandResult("output_limit", None, SECRET.encode()), "device_query_limited"),
        )
        for query, status in cases:
            with self.subTest(status=status):
                runner = FakeRunner(query, installed=self.expected.read_bytes())
                result = self.verify(runner)
                self.assertEqual(status, result.status)
                self.assertNotIn(SECRET, json.dumps(result.public()))

    def test_pull_failure_limit_and_invalid_zip_are_distinct(self) -> None:
        cases = (
            (guard.CommandResult("failed", 1), None, "installed_apk_unavailable"),
            (guard.CommandResult("artifact_limit", None), b"large", "installed_apk_limited"),
            (guard.CommandResult("ok", 0), b"not-a-zip", "installed_apk_invalid"),
        )
        for pull, installed, status in cases:
            with self.subTest(status=status):
                runner = FakeRunner(self.query(), installed=installed, pull=pull)
                self.assertEqual(status, self.verify(runner).status)

    def test_native_member_size_limit_is_fail_closed(self) -> None:
        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())
        with mock.patch.object(guard, "MAX_NATIVE_LIB_BYTES", 8):
            result = self.verify(runner)
        self.assertEqual("expected_apk_invalid", result.status)
        self.assertEqual([], runner.calls)

    def test_missing_installed_member_fails_closed(self) -> None:
        runner = FakeRunner(self.query(), installed=apk_bytes(None))
        self.assertEqual("installed_native_lib_missing", self.verify(runner).status)

    def test_cleanup_is_bounded_and_cleanup_failure_overrides_success(self) -> None:
        cleaned: list[Path] = []

        def cleanup(path: Path) -> bool:
            cleaned.append(path)
            shutil.rmtree(path)
            return True

        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())
        self.assertEqual("exact", self.verify(runner, cleanup=cleanup).status)
        self.assertEqual(1, len(cleaned))
        self.assertFalse(cleaned[0].exists())

        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())
        result = self.verify(runner, cleanup=lambda _path: False)
        self.assertEqual("cleanup_failed", result.status)

    def test_invalid_serial_package_and_relative_expected_path_never_run_adb(self) -> None:
        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())
        cases = (
            ("serial;touch", PACKAGE, self.expected),
            (SERIAL, "com.example.other", self.expected),
            (SERIAL, PACKAGE, Path("relative.apk")),
        )
        for serial, package, expected in cases:
            with self.subTest(package=package):
                result = guard.verify_android_native_provenance(
                    serial,
                    package,
                    expected,
                    runner=runner,
                )
                self.assertEqual("invalid_arguments", result.status)
        self.assertEqual([], runner.calls)

    def test_extension_seam_is_typed_optional_and_fail_closed(self) -> None:
        passing = FixedExtension(guard.ExtensionVerdict(True, True))
        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())
        result = self.verify(runner, extension=passing)
        self.assertEqual("exact", result.status)
        self.assertTrue(result.extension_applied)
        self.assertTrue(result.extension_passed)

        failing = FixedExtension(RuntimeError(SECRET))
        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())
        result = self.verify(runner, extension=failing)
        self.assertEqual("extension_failed", result.status)
        self.assertNotIn(SECRET, json.dumps(result.public()))

        malformed = FixedExtension({"applied": True})
        runner = FakeRunner(self.query(), installed=self.expected.read_bytes())
        self.assertEqual(
            "extension_failed", self.verify(runner, extension=malformed).status
        )

    def test_cli_output_is_fixed_schema_and_privacy_safe(self) -> None:
        runner = FakeRunner(
            guard.CommandResult("failed", 1, f"{SERIAL} {REMOTE_BASE} {SECRET}".encode()),
            installed=self.expected.read_bytes(),
        )
        output = io.StringIO()

        exit_code = guard.main(
            [
                "--serial",
                SERIAL,
                "--package",
                PACKAGE,
                "--expected-apk",
                str(self.expected),
            ],
            runner=runner,
            output=output,
        )

        payload = output.getvalue()
        decoded = json.loads(payload)
        self.assertEqual(3, exit_code)
        self.assertEqual("device_query_failed", decoded["status"])
        self.assertEqual(
            {
                "schema_version",
                "component",
                "status",
                "expected_native_lib_present",
                "expected_schema_complete",
                "base_apk_unique",
                "installed_apk_readable",
                "installed_native_lib_present",
                "installed_schema_complete",
                "native_digest_match",
                "extension_applied",
                "extension_passed",
                "exact",
            },
            set(decoded),
        )
        self.assertNotIn(SERIAL, payload)
        self.assertNotIn(REMOTE_BASE, payload)
        self.assertNotIn(str(self.expected), payload)
        self.assertNotIn(SECRET, payload)

    def test_invalid_cli_arguments_do_not_reflect_values(self) -> None:
        output = io.StringIO()
        exit_code = guard.main(["--serial", SECRET], output=output)
        self.assertEqual(64, exit_code)
        self.assertEqual("invalid_arguments", json.loads(output.getvalue())["status"])
        self.assertNotIn(SECRET, output.getvalue())

    def test_production_runner_uses_no_shell_and_discards_child_stderr(self) -> None:
        with mock.patch.object(subprocess, "Popen", return_value=FakeProcess()) as popen:
            result = guard.SubprocessCommandRunner().run(
                ("adb", "version"),
                stdout_limit=0,
                timeout_seconds=1.0,
            )
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
            process = FakeProcess(stdout=stream)

            with mock.patch.object(subprocess, "Popen", return_value=process):
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
