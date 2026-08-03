#!/usr/bin/env python3

from __future__ import annotations

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
) -> bytes:
    identities = identities or {}
    payloads = payloads or {}
    return b"CASEIN_BEAMS_V3\n" + b"".join(
        name.encode("ascii")
        + b"\t"
        + identities.get(name, installed_identity(name)).encode("ascii")
        + b"\t"
        + hashlib.sha256(
            payloads.get(name, ("fixture:" + name).encode("ascii"))
        ).hexdigest().encode("ascii")
        + b"\n"
        for name in names
    ) + b"END\n"


class FakeRunner:
    def __init__(
        self,
        manifest_result: guard.CommandResult,
        beams: dict[str, bytes | guard.CommandResult] | None = None,
    ) -> None:
        self.manifest_result = manifest_result
        self.beams = beams or {}
        self.calls: list[tuple[tuple[str, ...], dict[str, object]]] = []

    def run(self, argv: tuple[str, ...], **kwargs: object) -> guard.CommandResult:
        self.calls.append((argv, kwargs))
        if argv[-1] == guard._MANIFEST_SCRIPT:
            return self.manifest_result
        value = self.beams.get(argv[-2], guard.CommandResult("ok", 41))
        if isinstance(value, guard.CommandResult):
            return value
        return guard.CommandResult("ok", 0, value)


class RaisingRunner:
    def run(self, _argv: tuple[str, ...], **_kwargs: object) -> guard.CommandResult:
        raise RuntimeError(SECRET)


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
        self.root = Path(self.temp.name) / "casein_mob" / "ebin"
        self.root.mkdir(parents=True)
        self.payloads = {
            "Elixir.CaseinMob.App.beam": b"beam-app-v1",
            "Elixir.CaseinMob.SessionClient.beam": b"beam-session-v1",
        }
        for name, payload in self.payloads.items():
            (self.root / name).write_bytes(payload)

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
        )

    def verify(self, runner: object) -> guard.GuardResult:
        return guard.verify_android_beam_provenance(
            SERIAL,
            PACKAGE,
            self.root,
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
                else guard.MAX_BEAM_BYTES
            )
            self.assertEqual(expected_limit, kwargs["stdout_limit"])
        self.assertNotIn(SERIAL, guard._MANIFEST_SCRIPT)
        self.assertNotIn(PACKAGE, guard._MANIFEST_SCRIPT)
        self.assertNotIn(SERIAL, guard._READ_SCRIPT)
        self.assertNotIn(PACKAGE, guard._READ_SCRIPT)

    def test_invalid_inputs_never_invoke_adb(self) -> None:
        runner = self.runner(*self.payloads)
        cases = (
            ("serial;touch", PACKAGE, self.root),
            (SERIAL, "com.example.other", self.root),
            (SERIAL, PACKAGE, Path("casein_mob/ebin")),
            (SERIAL, PACKAGE, self.root.parent),
        )
        for serial, package, root in cases:
            with self.subTest(root=root.name):
                result = guard.verify_android_beam_provenance(
                    serial, package, root, runner=runner
                )
                self.assertEqual("invalid_arguments", result.status)
        self.assertEqual([], runner.calls)

    def test_local_root_symlink_is_invalid_input(self) -> None:
        linked_parent = Path(self.temp.name) / "linked" / "casein_mob"
        linked_parent.mkdir(parents=True)
        linked = linked_parent / "ebin"
        linked.symlink_to(self.root, target_is_directory=True)
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

    def test_installed_manifest_subprocess_and_device_entry_failures_are_fixed(self) -> None:
        cases = (
            (guard.CommandResult("failed", 1, SECRET.encode()), "installed_manifest_failed"),
            (guard.CommandResult("timeout", None, SECRET.encode()), "installed_manifest_failed"),
            (guard.CommandResult("output_limit", None, SECRET.encode()), "installed_manifest_limited"),
            (guard.CommandResult("ok", 41, SECRET.encode()), "installed_manifest_missing"),
            (guard.CommandResult("ok", 42, SECRET.encode()), "installed_manifest_invalid_entry"),
            (guard.CommandResult("ok", 43, SECRET.encode()), "installed_manifest_limited"),
            (guard.CommandResult("ok", 44, SECRET.encode()), "installed_manifest_missing"),
            (guard.CommandResult("ok", 45, SECRET.encode()), "installed_manifest_changed"),
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
            b"CASEIN_BEAMS_V3\nElixir.One.beam\t1:2:81a4:4:5:6\t" + digest + b"\nEND",
            b"WRONG\nElixir.One.beam\t1:2:81a4:4:5:6\t" + digest + b"\nEND\n",
            b"CASEIN_BEAMS_V3\nEND\n",
            b"CASEIN_BEAMS_V3\n\nEND\n",
            b"CASEIN_BEAMS_V3\nElixir.One.beam\t1:2:81a4:4:5:6\t" + digest + b"\nEND\ntrailing\n",
            b"CASEIN_BEAMS_V3\nElixir.One.beam\nEND\n",
            b"CASEIN_BEAMS_V3\nElixir.One.beam\tnot-an-identity\t" + digest + b"\nEND\n",
            b"CASEIN_BEAMS_V3\nElixir.One.beam\t1:2:81a4:4:5:6\tnot-a-digest\nEND\n",
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
            b"CASEIN_BEAMS_V3\n../escape.beam\t1:2:81a4:4:5:6\t" + b"0" * 64 + b"\nEND\n",
            b"CASEIN_BEAMS_V3\nbad name.beam\t1:2:81a4:4:5:6\t" + b"0" * 64 + b"\nEND\n",
            b"CASEIN_BEAMS_V3\nElixir.Bad.\xff.beam\t1:2:81a4:4:5:6\t" + b"0" * 64 + b"\nEND\n",
        )
        for payload in unsafe_payloads:
            with self.subTest(payload=payload[:20]):
                runner = FakeRunner(guard.CommandResult("ok", 0, payload))
                self.assertEqual(
                    "installed_manifest_unsafe_name", self.verify(runner).status
                )

    def test_manifest_name_count_and_payload_caps_are_rejected(self) -> None:
        names = tuple(f"Elixir.Module{index}.beam" for index in range(3))
        runner = FakeRunner(guard.CommandResult("ok", 0, manifest(*names)))
        with mock.patch.object(guard, "MAX_BEAMS", 2):
            self.assertEqual("installed_manifest_limited", self.verify(runner).status)

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
        changed[first_name] = b"changed-" + SECRET.encode()
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
            (guard.CommandResult("ok", 41, SECRET.encode()), "installed_beam_missing"),
            (
                guard.CommandResult("ok", 42, SECRET.encode()),
                "installed_beam_invalid_entry",
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
        beams[first_name] = guard.CommandResult("ok", 45, self.payloads[first_name])
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
        name = "Elixir.A.beam"
        runner = self.runner(
            name,
            beams={name: b"x" * 9},
            identities={name: installed_identity(name, size=1)},
            manifest_payloads={name: b"a"},
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
            "Elixir.B.beam": b"b",
        }
        for name, payload in small.items():
            (self.root / name).write_bytes(payload)
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
        secret_parent = Path(self.temp.name) / SECRET / "casein_mob" / "ebin"
        secret_parent.mkdir(parents=True)
        (secret_parent / "Elixir.App.beam").write_bytes(b"beam")
        runner = FakeRunner(guard.CommandResult("failed", 1, SECRET.encode()))
        output = io.StringIO()

        exit_code = guard.main(
            [
                "--serial",
                SERIAL,
                "--package",
                PACKAGE,
                "--expected-ebin-root",
                str(secret_parent),
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
        self.assertNotIn(str(secret_parent), raw)
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
