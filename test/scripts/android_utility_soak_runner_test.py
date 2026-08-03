#!/usr/bin/env python3
from __future__ import annotations

from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
RUNNER_PATH = ROOT / "native/casein_mob/android/run_utility_soak.py"
UTILITY_TEST_PATH = (
    ROOT
    / "native/casein_mob/android/app/src/androidTest/java/com/example/casein_mob"
    / "CaseinUtilitySoakTest.kt"
)
SPEC = importlib.util.spec_from_file_location("android_utility_soak_runner", RUNNER_PATH)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)
SOURCE_SHA256 = hashlib.sha256(UTILITY_TEST_PATH.read_bytes()).hexdigest()


class FakeClock:
    def __init__(self) -> None:
        self.value = 100.0

    def monotonic(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds

    def sleep(self, seconds: float) -> None:
        self.advance(seconds)


def reviewed_manifest(
    *,
    package: str = RUNNER.DRIVER_PACKAGE,
    runner: str = RUNNER.EXPECTED_RUNNER_CLASS,
    target: str = RUNNER.BASE_PACKAGE,
    source_sha256: str = SOURCE_SHA256,
) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="{RUNNER.ANDROID_XML_NS}" package="{package}">
  <application>
    <meta-data android:name="{RUNNER.UTILITY_SOURCE_DIGEST_METADATA}"
      android:value="{source_sha256}" />
  </application>
  <instrumentation android:name="{runner}" android:targetPackage="{target}" />
</manifest>
"""


class FakeExecutor:
    def __init__(self, serial: str, mode: str, clock: FakeClock) -> None:
        self.serial = serial
        self.mode = mode
        self.clock = clock
        self.wifi = "0" if mode == "wifi_disabled" else "1"
        self.driver_present = mode.startswith("driver_preexisting")
        self.package_queries = 0
        self.instrumentation_active = False
        self.target_process_active = False
        self.installed_path = (
            "/data/app/com.example.casein_mob.test-synthetic1/base.apk"
        )
        self.installed_digest: str | None = None
        self.installed_digest_queries = 0
        self.calls: list[tuple[tuple[str, ...], float]] = []

    @property
    def commands(self) -> list[tuple[str, ...]]:
        return [command for command, _deadline in self.calls]

    def result(
        self,
        returncode: int = 0,
        stdout: str = "",
        stdout_truncated: bool = False,
    ):
        return RUNNER.CommandResult(returncode, stdout, stdout_truncated)

    def run(self, argv, deadline):
        command = tuple(argv)
        self.calls.append((command, deadline))
        self.clock.advance(0.01)

        if command == ("adb", "devices", "-l"):
            rows = [
                "List of devices attached",
                f"{self.serial} device product:gta2xl model:SM_T390 transport_id:1",
                "synthetic-other unauthorized transport_id:2",
            ]
            if self.mode == "ambiguous":
                rows.append(
                    "synthetic-second device product:gta2xl model:SM_T390 transport_id:3"
                )
            return self.result(stdout="\n".join(rows) + "\n")

        if command and command[0] == "/synthetic/apksigner":
            signature_output = (
                "MALFORMED\n"
                if self.mode == "signer_malformed"
                else "Verifies\n"
                "Verified using v1 scheme (JAR signing): false\n"
                "Verified using v2 scheme (APK Signature Scheme v2): true\n"
                "Number of signers: 1\n"
            )
            return self.result(
                returncode=1 if self.mode == "unsigned" else 0,
                stdout=signature_output,
                stdout_truncated=self.mode == "signer_truncated",
            )

        if command[:3] == (
            "/synthetic/apkanalyzer",
            "manifest",
            "application-id",
        ):
            package = (
                "wrong.synthetic.package"
                if self.mode == "wrong_app_id"
                else RUNNER.DRIVER_PACKAGE
            )
            return self.result(
                stdout=package + "\n",
                stdout_truncated=self.mode == "app_id_truncated",
            )

        if command[:3] == (
            "/synthetic/apkanalyzer",
            "manifest",
            "print",
        ):
            overrides = {
                "wrong_target": {"target": "wrong.synthetic.target"},
                "wrong_runner": {"runner": "wrong.synthetic.Runner"},
                "wrong_source_digest": {"source_sha256": "0" * 64},
            }
            manifest = (
                "<manifest"
                if self.mode == "manifest_malformed"
                else reviewed_manifest(**overrides.get(self.mode, {}))
            )
            return self.result(
                stdout=manifest,
                stdout_truncated=self.mode == "manifest_truncated",
            )

        if command[-4:] == ("settings", "get", "global", "wifi_on"):
            if self.mode == "wifi_unreadable":
                return self.result(returncode=1)
            return self.result(stdout=self.wifi + "\n")

        if command[-2:] == ("date", "+%s"):
            if self.mode == "clock_failure":
                return self.result(returncode=1)
            if self.mode == "clock_timeout":
                raise RUNNER.CommandDeadlineExceeded("SYNTHETIC_PRIVATE_CLOCK_OUTPUT")
            return self.result(stdout="1700000000\n")

        if "install" in command:
            if self.mode == "driver_race":
                self.driver_present = True
                return self.result(
                    returncode=1,
                    stdout="Failure [INSTALL_FAILED_ALREADY_EXISTS]\n",
                )
            if self.mode == "install_failure":
                self.driver_present = True
                return self.result(returncode=1, stdout="Failure\n")
            if self.mode == "install_timeout":
                self.driver_present = True
                raise RUNNER.CommandDeadlineExceeded("SYNTHETIC_PRIVATE_INSTALL")
            installed_apk = Path(command[-1])
            if self.mode == "install_content_swap":
                installed_apk.write_bytes(b"synthetic swapped apk")
            self.installed_digest = hashlib.sha256(
                installed_apk.read_bytes()
            ).hexdigest()
            self.driver_present = True
            return self.result(stdout="Success\n")

        if command[-4:] == (
            "pm",
            "list",
            "packages",
            RUNNER.DRIVER_PACKAGE,
        ):
            self.package_queries += 1
            if self.mode == "driver_state_unknown":
                return self.result(returncode=1)
            if self.mode == "install_postcheck_unknown" and self.package_queries > 1:
                return self.result(returncode=1)
            if self.mode == "driver_preexisting_multiple":
                return self.result(
                    stdout=(
                        f"package:{RUNNER.DRIVER_PACKAGE}\n"
                        f"package:{RUNNER.DRIVER_PACKAGE}\n"
                    )
                )
            malformed_outputs = {
                "driver_output_malformed": "not-a-package-row\n",
                "driver_output_warning": "Warning: package manager degraded\n",
                "driver_output_error": "Error: package lookup failed\n",
                "driver_output_partial": (
                    f"package:{RUNNER.DRIVER_PACKAGE}\n"
                    "Warning: trailing untrusted row\n"
                ),
            }
            if self.mode in malformed_outputs:
                return self.result(stdout=malformed_outputs[self.mode])
            return self.result(
                stdout=f"package:{RUNNER.DRIVER_PACKAGE}\n"
                if self.driver_present
                else ""
            )

        if command[-3:] == ("pm", "path", RUNNER.DRIVER_PACKAGE):
            outputs = {
                "installed_path_malformed": "package:/data/local/tmp/driver.apk\n",
                "installed_path_multiple": (
                    f"package:{self.installed_path}\n"
                    f"package:{self.installed_path}\n"
                ),
                "installed_path_split": (
                    f"package:{self.installed_path}\n"
                    "package:/data/app/com.example.casein_mob.test-"
                    "synthetic1/split_config.en.apk\n"
                ),
            }
            return self.result(
                returncode=1 if self.mode == "installed_path_unknown" else 0,
                stdout=outputs.get(
                    self.mode, f"package:{self.installed_path}\n"
                ),
                stdout_truncated=self.mode == "installed_path_truncated",
            )

        if command[-3:] == (
            RUNNER.DEVICE_SHA256SUM,
            "-b",
            self.installed_path,
        ):
            self.installed_digest_queries += 1
            digest = self.installed_digest or "0" * 64
            if (
                self.mode == "cleanup_identity_swap"
                and self.installed_digest_queries > 1
            ):
                digest = "0" * 64
            output = f"{digest}\n"
            if self.mode == "installed_digest_malformed":
                output = f"SHA256 ({self.installed_path}) = {digest}\n"
            return self.result(
                returncode=1 if self.mode == "installed_digest_unknown" else 0,
                stdout=output,
                stdout_truncated=self.mode == "installed_digest_truncated",
            )

        if "instrument" in command:
            self.instrumentation_active = True
            self.target_process_active = True
            if self.mode == "timeout":
                self.wifi = "0"
                raise RUNNER.CommandDeadlineExceeded(
                    "SYNTHETIC_PRIVATE_OUTPUT " + self.serial
                )
            if self.mode == "instrument_error":
                self.wifi = "0"
                raise RuntimeError("SYNTHETIC_PRIVATE_ERROR " + self.serial)
            if self.mode != "active_instrumentation":
                self.instrumentation_active = False
            if self.mode != "active_target_process":
                self.target_process_active = False
            self.wifi = "0"
            if self.mode == "cleanup_path_swap":
                self.installed_path = (
                    "/data/app/com.example.casein_mob.test-synthetic2/base.apk"
                )
            return self.result(
                stdout="OK (1 test)\nINSTRUMENTATION_CODE: -1\n",
                stdout_truncated=self.mode == "instrument_stdout_truncated",
            )

        if "logcat" in command:
            if self.mode == "metric_timeout":
                raise RUNNER.CommandDeadlineExceeded("SYNTHETIC_PRIVATE_METRIC_OUTPUT")
            if self.mode == "metrics_empty":
                return self.result(stdout="")
            lines = [
                "1700000001.000 I CaseinUtilitySoak: casein_soak cold_launch_ms=800",
            ]
            if self.mode != "metrics_incomplete":
                lines.append(
                    "1700000002.000 I CaseinUtilitySoak: casein_soak warm_resume_ms=400"
                )
                lines.append(
                    "1700000003.000 I CaseinUtilitySoak: "
                    "casein_soak offline_recovery_ms=1500"
                )
            return self.result(stdout="\n".join(lines) + "\n")

        if command[-3:] == ("svc", "wifi", "enable"):
            self.wifi = "1"
            return self.result()
        if command[-3:] == ("svc", "wifi", "disable"):
            self.wifi = "0"
            return self.result()

        if command[-3:] == ("am", "force-stop", RUNNER.DRIVER_PACKAGE):
            if self.mode != "active_instrumentation":
                self.instrumentation_active = False
            return self.result()

        if command[-3:] == ("am", "force-stop", RUNNER.BASE_PACKAGE):
            if self.mode != "active_target_process":
                self.target_process_active = False
            return self.result()

        if (
            command[-4:-1] == ("dumpsys", "activity", "processes")
            and command[-1] in {RUNNER.BASE_PACKAGE, RUNNER.DRIVER_PACKAGE}
        ):
            output = "ACTIVITY MANAGER RUNNING PROCESSES\n"
            if self.instrumentation_active:
                output += f"  ActiveInstrumentation{{ {RUNNER.INSTRUMENTATION_RUNNER} }}\n"
            return self.result(
                stdout=output,
                stdout_truncated=self.mode == "quiescence_truncated",
            )

        if command[-5:] == ("ps", "-A", "-w", "-o", "NAME"):
            output = "NAME\nsystem_server\n"
            if self.target_process_active:
                output += RUNNER.BASE_PACKAGE + "\n"
            return self.result(stdout=output)

        if command[-2:] == ("uninstall", RUNNER.DRIVER_PACKAGE):
            if self.mode != "uninstall_failure":
                self.driver_present = False
                return self.result(stdout="Success\n")
            return self.result(returncode=1, stdout="Failure\n")

        raise AssertionError("unexpected fixed command shape")


class AndroidUtilitySoakRunnerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.driver_apk = Path(self.temporary.name) / "reviewed-driver.apk"
        self.driver_apk.write_bytes(b"synthetic apk fixture")
        self.driver_apk_sha256 = hashlib.sha256(
            self.driver_apk.read_bytes()
        ).hexdigest()

    def run_fake(
        self,
        mode: str = "pass",
        *,
        utility_source=UTILITY_TEST_PATH,
        expected_digest: str | None = None,
    ):
        serial = "synthetic-private-serial"
        clock = FakeClock()
        executor = FakeExecutor(serial, mode, clock)
        reviewed_digest = expected_digest
        if reviewed_digest is None:
            reviewed_digest = (
                "f" * 64 if mode == "wrong_digest" else self.driver_apk_sha256
            )
        result = RUNNER.run_utility_soak(
            serial,
            str(self.driver_apk),
            reviewed_digest,
            executor=executor,
            monotonic=clock.monotonic,
            sleep=clock.sleep,
            analyzer_locator=lambda: "/synthetic/apkanalyzer",
            signer_locator=lambda: "/synthetic/apksigner",
            utility_source=utility_source,
        )
        return serial, clock, executor, result

    def test_wait_budget_is_derived_from_source_and_changes_with_call_graph(self):
        source = UTILITY_TEST_PATH.read_text(encoding="utf-8")
        budget = RUNNER.derive_wait_budget(source)

        self.assertEqual(24, budget.ui_count)
        self.assertEqual(4, budget.filter_count)
        self.assertEqual(3, budget.offline_count)
        self.assertEqual(2, budget.recovery_count)
        self.assertEqual(1, budget.keyboard_count)
        self.assertEqual(7, budget.idle_count)
        self.assertEqual(783_000, budget.total_ms)

        with_extra_idle = source.replace(
            "device.wakeUp()", "device.wakeUp()\n        device.waitForIdle()", 1
        )
        with_extra_ui_wait = source.replace(
            "val coldMs = coldLaunch()",
            "val coldMs = coldLaunch()\n            waitForText(DASHBOARD_TITLE)",
            1,
        )
        self.assertEqual(
            budget.total_ms + budget.idle_ms,
            RUNNER.derive_wait_budget(with_extra_idle).total_ms,
        )
        self.assertEqual(
            budget.total_ms + budget.ui_ms,
            RUNNER.derive_wait_budget(with_extra_ui_wait).total_ms,
        )

        mutations = (
            ("FILTER_TIMEOUT_MS", budget.filter_ms),
            ("OFFLINE_TIMEOUT_MS", budget.offline_ms),
            ("RECOVERY_TIMEOUT_MS", budget.recovery_ms),
        )
        for timeout_name, expected_delta in mutations:
            with self.subTest(timeout_name=timeout_name):
                mutated = source.replace(
                    "val coldMs = coldLaunch()",
                    "val coldMs = coldLaunch()\n"
                    f"            waitForText(DASHBOARD_TITLE, {timeout_name})",
                    1,
                )
                self.assertEqual(
                    budget.total_ms + expected_delta,
                    RUNNER.derive_wait_budget(mutated).total_ms,
                )

        with_extra_keyboard = source.replace(
            "val coldMs = coldLaunch()",
            "val coldMs = coldLaunch()\n            waitForKeyboard()",
            1,
        )
        self.assertEqual(
            budget.total_ms + budget.keyboard_ms,
            RUNNER.derive_wait_budget(with_extra_keyboard).total_ms,
        )

    def test_wait_budget_multiplies_nested_helpers_and_rejects_cycles(self):
        source = UTILITY_TEST_PATH.read_text(encoding="utf-8")
        budget = RUNNER.derive_wait_budget(source)
        nested_helpers = """
    private fun syntheticWaitLeaf() {
        waitForText(DASHBOARD_TITLE)
    }

    private fun syntheticWaitBranch() {
        syntheticWaitLeaf()
        syntheticWaitLeaf()
    }

"""
        nested = source.replace(
            "    private fun waitForKeyboard(",
            nested_helpers + "    private fun waitForKeyboard(",
            1,
        ).replace(
            "val coldMs = coldLaunch()",
            "val coldMs = coldLaunch()\n"
            "            syntheticWaitBranch()\n"
            "            syntheticWaitBranch()",
            1,
        )
        nested_budget = RUNNER.derive_wait_budget(nested)
        self.assertEqual(budget.ui_count + 4, nested_budget.ui_count)
        self.assertEqual(budget.total_ms + 4 * budget.ui_ms, nested_budget.total_ms)

        cyclic_helpers = """
    private fun syntheticCycleA() { syntheticCycleB() }
    private fun syntheticCycleB() { syntheticCycleA() }

"""
        cyclic = source.replace(
            "    private fun waitForKeyboard(",
            cyclic_helpers + "    private fun waitForKeyboard(",
            1,
        ).replace(
            "val coldMs = coldLaunch()",
            "val coldMs = coldLaunch()\n            syntheticCycleA()",
            1,
        )
        with self.assertRaises(ValueError):
            RUNNER.derive_wait_budget(cyclic)

        unfamiliar = source.replace(
            "val coldMs = coldLaunch()",
            "val coldMs = coldLaunch()\n            syntheticUnknownWait()",
            1,
        ).replace(
            "    private fun waitForKeyboard(",
            "    private fun syntheticUnknownWait() {\n"
            "        device.wait(Until.hasObject(By.text(DASHBOARD_TITLE)), 1000)\n"
            "    }\n\n"
            "    private fun waitForKeyboard(",
            1,
        )
        with self.assertRaises(ValueError):
            RUNNER.derive_wait_budget(unfamiliar)

    def test_pass_pins_artifact_watchdog_and_cleanup_order(self):
        serial, _clock, executor, result = self.run_fake()

        self.assertEqual("pass", result["status"])
        self.assertEqual(783_000, result["explicit_wait_budget_ms"])
        self.assertEqual(267_000, result["safety_margin_ms"])
        self.assertEqual(
            RUNNER.DEVICE_WATCHDOG_TIMEOUT_MS,
            result["device_watchdog_timeout_ms"],
        )
        self.assertTrue(result["reviewed_apk_verified"])
        self.assertEqual("external", result["cross_invocation_one_attempt"])
        self.assertTrue(result["device_quiescent"])
        self.assertTrue(result["driver_installed"])
        self.assertTrue(result["driver_cleaned"])
        self.assertTrue(result["wifi_restore_attempted"])
        self.assertTrue(result["wifi_restored"])
        self.assertEqual(800, result["cold_launch_ms"])
        self.assertEqual(400, result["warm_resume_ms"])
        self.assertEqual(1500, result["offline_recovery_ms"])
        self.assertEqual(set(RUNNER.RESULT_KEYS), set(result))

        commands = executor.commands
        for command in commands:
            if command[:2] == ("adb", "devices"):
                continue
            if command and command[0] == "adb":
                self.assertEqual(("-s", serial), command[2:4])

        package_checks = [
            index
            for index, command in enumerate(commands)
            if command[-4:]
            == ("pm", "list", "packages", RUNNER.DRIVER_PACKAGE)
        ]
        install_index, install_command = next(
            (index, command)
            for index, command in enumerate(commands)
            if "install" in command
        )
        instrument_index, instrument_command = next(
            (index, command)
            for index, command in enumerate(commands)
            if "instrument" in command
        )
        installed_path_index = commands.index(
            (*RUNNER._adb(serial, "shell", "pm", "path", RUNNER.DRIVER_PACKAGE),)
        )
        installed_digest_index = commands.index(
            (*RUNNER._adb(
                serial,
                "shell",
                RUNNER.DEVICE_SHA256SUM,
                "-b",
                executor.installed_path,
            ),)
        )
        driver_stop = commands.index(
            (*RUNNER._adb(serial, "shell", "am", "force-stop", RUNNER.DRIVER_PACKAGE),)
        )
        base_stop = commands.index(
            (*RUNNER._adb(serial, "shell", "am", "force-stop", RUNNER.BASE_PACKAGE),)
        )
        quiescence = commands.index(
            (*RUNNER._adb(
                serial,
                "shell",
                "dumpsys",
                "activity",
                "processes",
                RUNNER.BASE_PACKAGE,
            ),)
        )
        process_check = commands.index(
            (*RUNNER._adb(serial, "shell", "ps", "-A", "-w", "-o", "NAME"),)
        )
        uninstall = commands.index(
            (*RUNNER._adb(serial, "uninstall", RUNNER.DRIVER_PACKAGE),)
        )
        wifi_restore = commands.index(
            (*RUNNER._adb(serial, "shell", "svc", "wifi", "enable"),)
        )

        self.assertLess(package_checks[0], install_index)
        self.assertLess(install_index, installed_path_index)
        self.assertLess(installed_path_index, installed_digest_index)
        self.assertLess(installed_digest_index, instrument_index)
        self.assertLess(install_index, instrument_index)
        self.assertLess(instrument_index, driver_stop)
        self.assertLess(driver_stop, base_stop)
        self.assertLess(base_stop, quiescence)
        self.assertLess(quiescence, process_check)
        self.assertLess(process_check, uninstall)
        self.assertLess(uninstall, package_checks[-1])
        self.assertLess(package_checks[-1], wifi_restore)
        self.assertNotIn("-r", install_command)
        staged_apk = Path(install_command[-1])
        self.assertNotEqual(self.driver_apk, staged_apk)
        self.assertFalse(staged_apk.exists())
        self.assertEqual(1, sum("instrument" in command for command in commands))
        self.assertIn(
            ("-e", "timeout_msec", str(RUNNER.DEVICE_WATCHDOG_TIMEOUT_MS)),
            tuple(
                instrument_command[index : index + 3]
                for index in range(len(instrument_command) - 2)
            ),
        )
        self.assertIn(
            (
                "-e",
                "casein_watchdog_ms",
                str(RUNNER.DEVICE_WATCHDOG_TIMEOUT_MS),
            ),
            tuple(
                instrument_command[index : index + 3]
                for index in range(len(instrument_command) - 2)
            ),
        )
        self.assertFalse(
            any(
                command[-2:] == ("uninstall", RUNNER.BASE_PACKAGE)
                or "clear" in command
                for command in commands
            )
        )

    def test_exact_reviewed_artifact_contract_rejects_adversarial_variants(self):
        modes = (
            "wrong_digest",
            "wrong_app_id",
            "app_id_truncated",
            "wrong_target",
            "wrong_runner",
            "wrong_source_digest",
            "unsigned",
            "signer_truncated",
            "signer_malformed",
            "manifest_truncated",
            "manifest_malformed",
        )
        for mode in modes:
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertEqual("driver_apk_invalid", result["status"])
                self.assertFalse(result["reviewed_apk_verified"])
                self.assertFalse(result["driver_install_attempted"])
                self.assertFalse(any("install" in command for command in executor.commands))
                if mode == "wrong_digest":
                    self.assertFalse(
                        any(
                            command
                            and command[0]
                            in {"/synthetic/apksigner", "/synthetic/apkanalyzer"}
                            for command in executor.commands
                        )
                    )

    def test_cli_requires_reviewed_apk_digest_argument(self):
        output = io.StringIO()
        with redirect_stdout(output):
            status = RUNNER.main(
                ["run_utility_soak.py", "synthetic", str(self.driver_apk)]
            )
        self.assertEqual(74, status)
        result = json.loads(output.getvalue())
        self.assertEqual("invalid_target", result["status"])
        self.assertFalse(result["reviewed_apk_verified"])

        for malformed in ("", "0" * 63, "g" * 64, "0" * 65):
            with self.subTest(malformed=malformed):
                _serial, _clock, executor, result = self.run_fake(
                    expected_digest=malformed
                )
                self.assertEqual("driver_apk_invalid", result["status"])
                self.assertFalse(
                    any("install" in command for command in executor.commands)
                )

    def test_private_staging_cleanup_failure_returns_fixed_schema(self):
        private_marker = "SYNTHETIC_PRIVATE_STAGING_PATH"
        real_temporary = tempfile.TemporaryDirectory(
            prefix="casein-cleanup-regression-"
        )
        self.addCleanup(real_temporary.cleanup)

        class CleanupFailure:
            name = real_temporary.name

            @staticmethod
            def cleanup():
                raise OSError(private_marker + real_temporary.name)

        with mock.patch.object(
            RUNNER.tempfile,
            "TemporaryDirectory",
            return_value=CleanupFailure(),
        ):
            _serial, _clock, _executor, result = self.run_fake()

        encoded = json.dumps(result, sort_keys=True)
        self.assertEqual("cleanup_failed", result["status"])
        self.assertEqual("artifact_staging_cleanup", result["failure_stage"])
        self.assertTrue(result["driver_cleaned"])
        self.assertTrue(result["wifi_restored"])
        self.assertEqual(set(RUNNER.RESULT_KEYS), set(result))
        self.assertNotIn(private_marker, encoded)
        self.assertNotIn(real_temporary.name, encoded)

        second_temporary = tempfile.TemporaryDirectory(
            prefix="casein-cleanup-preserve-regression-"
        )
        self.addCleanup(second_temporary.cleanup)
        CleanupFailure.name = second_temporary.name
        with mock.patch.object(
            RUNNER.tempfile,
            "TemporaryDirectory",
            return_value=CleanupFailure(),
        ):
            _serial, _clock, _executor, device_failure = self.run_fake(
                "uninstall_failure"
            )
        self.assertEqual("cleanup_failed", device_failure["status"])
        self.assertEqual("driver_cleanup", device_failure["failure_stage"])
        self.assertFalse(device_failure["driver_cleaned"])
        self.assertEqual(set(RUNNER.RESULT_KEYS), set(device_failure))

    def test_main_converts_unexpected_escape_to_private_fixed_schema(self):
        private_marker = "SYNTHETIC_PRIVATE_MAIN_ESCAPE"
        output = io.StringIO()
        with mock.patch.object(
            RUNNER,
            "run_utility_soak",
            side_effect=OSError(private_marker),
        ), redirect_stdout(output):
            status = RUNNER.main(
                [
                    "run_utility_soak.py",
                    "synthetic",
                    str(self.driver_apk),
                    self.driver_apk_sha256,
                ]
            )

        self.assertEqual(74, status)
        result = json.loads(output.getvalue())
        self.assertEqual("runner_error", result["status"])
        self.assertEqual("runner", result["failure_stage"])
        self.assertEqual(set(RUNNER.RESULT_KEYS), set(result))
        self.assertNotIn(private_marker, output.getvalue())

    def test_package_presence_is_exact_tristate(self):
        class OneResult:
            def __init__(self, result):
                self.result = result

            def run(self, _argv, _deadline):
                return self.result

        cases = (
            (RUNNER.CommandResult(0, ""), False),
            (
                RUNNER.CommandResult(0, f"package:{RUNNER.DRIVER_PACKAGE}\n"),
                True,
            ),
            (RUNNER.CommandResult(1, ""), None),
            (RUNNER.CommandResult(0, "package:wrong.synthetic\n"), None),
            (
                RUNNER.CommandResult(
                    0, f"package:{RUNNER.DRIVER_PACKAGE}\n", True
                ),
                None,
            ),
        )
        for command_result, expected in cases:
            with self.subTest(command_result=command_result, expected=expected):
                actual = RUNNER._driver_present(
                    OneResult(command_result), "synthetic", 10.0, lambda: 0.0
                )
                self.assertIs(expected, actual)

    def test_android_9_quiescence_headers_are_conservative_and_provable(self):
        inactive_dumpsys = (
            "ACTIVITY MANAGER RUNNING PROCESSES "
            "(dumpsys activity processes)\n"
            "  (nothing)\n"
        )
        self.assertIs(
            True,
            RUNNER._parse_instrumentation_quiescence(inactive_dumpsys),
        )
        self.assertIs(
            True,
            RUNNER._parse_instrumentation_quiescence(
                "ACTIVITY MANAGER RUNNING PROCESSES\r\n"
            ),
        )
        self.assertIs(
            False,
            RUNNER._parse_instrumentation_quiescence(
                inactive_dumpsys
                + f"  ActiveInstrumentation{{ {RUNNER.INSTRUMENTATION_RUNNER} }}\n"
            ),
        )
        self.assertIsNone(
            RUNNER._parse_instrumentation_quiescence("Activity manager help\n")
        )

        self.assertIs(
            True,
            RUNNER._parse_target_process_quiescence("NAME\n"),
        )
        self.assertIs(
            True,
            RUNNER._parse_target_process_quiescence(
                "NAME\ninit\nsystem_server\n"
            ),
        )
        for process_name in (
            RUNNER.BASE_PACKAGE,
            RUNNER.BASE_PACKAGE + ":remote",
            RUNNER.DRIVER_PACKAGE,
            RUNNER.DRIVER_PACKAGE + ":runner",
        ):
            with self.subTest(process_name=process_name):
                self.assertIs(
                    False,
                    RUNNER._parse_target_process_quiescence(
                        f"NAME\n{process_name}\n"
                    ),
                )
        self.assertIsNone(
            RUNNER._parse_target_process_quiescence("USER PID NAME\n")
        )
        self.assertIsNone(
            RUNNER._parse_target_process_quiescence("NAME\nbad process\n")
        )

    def test_manifest_source_digest_requires_exact_sha256_shape(self):
        manifest = reviewed_manifest()
        self.assertTrue(
            RUNNER._manifest_matches_reviewed_contract(
                manifest, SOURCE_SHA256
            )
        )
        for malformed in ("", "0" * 63, "g" * 64, "0" * 65):
            with self.subTest(malformed=malformed):
                self.assertFalse(
                    RUNNER._manifest_matches_reviewed_contract(
                        manifest, malformed
                    )
                )

    def test_host_and_device_watchdog_bounds_must_match(self):
        mutated_source = Path(self.temporary.name) / "mutated-soak.kt"
        mutated_source.write_text(
            UTILITY_TEST_PATH.read_text(encoding="utf-8").replace(
                "DEVICE_WATCHDOG_TIMEOUT_MS = 900_000L",
                "DEVICE_WATCHDOG_TIMEOUT_MS = 899_999L",
                1,
            ),
            encoding="utf-8",
        )
        _serial, _clock, executor, result = self.run_fake(
            utility_source=mutated_source
        )
        self.assertEqual("source_contract_invalid", result["status"])
        self.assertEqual("wait_budget", result["failure_stage"])
        self.assertFalse(any("install" in command for command in executor.commands))

    def test_initially_disabled_wifi_is_explicit_nonpass_preflight(self):
        _serial, _clock, executor, result = self.run_fake("wifi_disabled")

        self.assertEqual("wifi_initially_disabled", result["status"])
        self.assertEqual("preflight", result["failure_stage"])
        self.assertFalse(result["wifi_initially_enabled"])
        self.assertFalse(result["wifi_restore_attempted"])
        self.assertTrue(result["wifi_restored"])
        self.assertFalse(result["driver_install_attempted"])
        self.assertFalse(
            any(
                "install" in command
                or "instrument" in command
                or "force-stop" in command
                or ("svc" in command and "wifi" in command)
                for command in executor.commands
            )
        )

    def test_install_ambiguity_never_authorizes_cleanup(self):
        expected = {
            "install_failure": "driver_install_ambiguous",
            "install_timeout": "driver_install_ambiguous",
            "install_postcheck_unknown": "driver_install_ambiguous",
            "installed_path_unknown": "driver_install_ambiguous",
            "installed_path_truncated": "driver_install_ambiguous",
            "installed_path_malformed": "driver_install_ambiguous",
            "installed_path_multiple": "driver_install_ambiguous",
            "installed_path_split": "driver_install_ambiguous",
            "installed_digest_unknown": "driver_install_ambiguous",
            "installed_digest_truncated": "driver_install_ambiguous",
            "installed_digest_malformed": "driver_install_ambiguous",
            "driver_race": "driver_ownership_conflict",
        }
        for mode, status in expected.items():
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertEqual(status, result["status"])
                self.assertTrue(result["driver_install_attempted"])
                self.assertFalse(result["driver_installed"])
                self.assertFalse(result["driver_cleanup_attempted"])
                self.assertTrue(executor.driver_present)
                self.assertFalse(
                    any(
                        "uninstall" in command or "force-stop" in command
                        for command in executor.commands
                    )
                )

    def test_install_time_content_swap_cannot_earn_ownership_or_execute(self):
        serial, _clock, executor, result = self.run_fake(
            "install_content_swap"
        )

        self.assertEqual("driver_install_ambiguous", result["status"])
        self.assertEqual("driver_install", result["failure_stage"])
        self.assertTrue(result["reviewed_apk_verified"])
        self.assertTrue(result["driver_install_attempted"])
        self.assertFalse(result["driver_installed"])
        self.assertFalse(result["driver_cleanup_attempted"])
        self.assertTrue(executor.driver_present)
        self.assertNotEqual(self.driver_apk_sha256, executor.installed_digest)
        self.assertIn(
            (*RUNNER._adb(
                serial,
                "shell",
                RUNNER.DEVICE_SHA256SUM,
                "-b",
                executor.installed_path,
            ),),
            executor.commands,
        )
        self.assertFalse(
            any(
                "instrument" in command
                or "uninstall" in command
                or "force-stop" in command
                for command in executor.commands
            )
        )

    def test_instrumentation_truncated_stdout_can_never_pass(self):
        serial, _clock, executor, result = self.run_fake(
            "instrument_stdout_truncated"
        )

        self.assertEqual("test_failed", result["status"])
        self.assertEqual(
            "instrumentation_output_truncated", result["failure_stage"]
        )
        self.assertTrue(result["test_completed"])
        self.assertTrue(result["driver_cleaned"])
        self.assertTrue(result["wifi_restored"])
        self.assertEqual(set(RUNNER.RESULT_KEYS), set(result))
        encoded = json.dumps(result, sort_keys=True)
        self.assertNotIn(serial, encoded)
        self.assertNotIn("OK (1 test)", encoded)

    def test_cleanup_identity_swap_fails_closed_before_any_mutation(self):
        for mode in ("cleanup_identity_swap", "cleanup_path_swap"):
            with self.subTest(mode=mode):
                serial, _clock, executor, result = self.run_fake(mode)

                self.assertEqual("cleanup_failed", result["status"])
                self.assertEqual(
                    "wifi_restore_and_driver_cleanup",
                    result["failure_stage"],
                )
                self.assertTrue(result["driver_cleanup_attempted"])
                self.assertFalse(result["driver_cleaned"])
                self.assertFalse(result["device_quiescent"])
                self.assertFalse(result["wifi_restored"])
                self.assertTrue(executor.driver_present)
                self.assertEqual(2, executor.installed_digest_queries)
                self.assertFalse(
                    any(
                        command[-3:]
                        in {
                            ("am", "force-stop", RUNNER.DRIVER_PACKAGE),
                            ("am", "force-stop", RUNNER.BASE_PACKAGE),
                        }
                        or command[-2:]
                        == ("uninstall", RUNNER.DRIVER_PACKAGE)
                        for command in executor.commands
                    )
                )
                self.assertIn(
                    (*RUNNER._adb(
                        serial,
                        "shell",
                        RUNNER.DEVICE_SHA256SUM,
                        "-b",
                        executor.installed_path,
                    ),),
                    executor.commands,
                )
                self.assertEqual(set(RUNNER.RESULT_KEYS), set(result))

    def test_preexisting_or_unknown_driver_fails_closed_without_mutation(self):
        expected = {
            "driver_preexisting": "driver_preexisting",
            "driver_preexisting_multiple": "driver_state_unknown",
            "driver_state_unknown": "driver_state_unknown",
            "driver_output_malformed": "driver_state_unknown",
            "driver_output_warning": "driver_state_unknown",
            "driver_output_error": "driver_state_unknown",
            "driver_output_partial": "driver_state_unknown",
        }
        for mode, status in expected.items():
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertEqual(status, result["status"])
                self.assertEqual("driver_preflight", result["failure_stage"])
                self.assertFalse(result["driver_install_attempted"])
                self.assertFalse(result["driver_cleanup_attempted"])
                self.assertFalse(
                    any(
                        "install" in command
                        or "uninstall" in command
                        or "force-stop" in command
                        for command in executor.commands
                    )
                )

    def test_timeout_is_private_bounded_and_cleans_exact_targets(self):
        serial, clock, executor, result = self.run_fake("timeout")

        self.assertEqual("timeout", result["status"])
        self.assertTrue(result["timed_out"])
        self.assertTrue(result["device_quiescent"])
        self.assertTrue(result["driver_cleaned"])
        self.assertTrue(result["wifi_restored"])
        self.assertLessEqual(result["duration_ms"], RUNNER.WHOLE_RUN_TIMEOUT_MS)
        encoded = json.dumps(result, sort_keys=True)
        self.assertNotIn(serial, encoded)
        self.assertNotIn("SYNTHETIC_PRIVATE", encoded)
        self.assertNotIn(str(self.driver_apk), encoded)

        run_start = 100.0
        telemetry_start = (
            run_start
            + RUNNER.WHOLE_RUN_TIMEOUT_MS / 1_000
            - RUNNER.CLEANUP_RESERVE_MS / 1_000
            - RUNNER.TELEMETRY_RESERVE_MS / 1_000
        )
        hard_deadline = run_start + RUNNER.WHOLE_RUN_TIMEOUT_MS / 1_000
        instrument_deadline = next(
            deadline
            for command, deadline in executor.calls
            if "instrument" in command
        )
        self.assertEqual(telemetry_start, instrument_deadline)
        self.assertTrue(
            all(deadline <= hard_deadline for _command, deadline in executor.calls)
        )
        self.assertLessEqual(clock.monotonic(), hard_deadline)

    def test_cleanup_requires_positive_quiescence_before_uninstall_or_wifi(self):
        for mode in (
            "active_instrumentation",
            "active_target_process",
            "quiescence_truncated",
        ):
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertEqual("cleanup_failed", result["status"])
                self.assertFalse(result["device_quiescent"])
                self.assertFalse(result["driver_cleaned"])
                self.assertFalse(result["wifi_restored"])
                self.assertFalse(
                    any(
                        "uninstall" in command
                        or command[-3:] == ("svc", "wifi", "enable")
                        for command in executor.commands
                    )
                )
                self.assertTrue(
                    any(
                        command[-3:]
                        == ("am", "force-stop", RUNNER.DRIVER_PACKAGE)
                        for command in executor.commands
                    )
                )
                self.assertTrue(
                    any(
                        command[-3:]
                        == ("am", "force-stop", RUNNER.BASE_PACKAGE)
                        for command in executor.commands
                    )
                )

    def test_uninstall_failure_is_cleanup_failure_after_quiescence(self):
        _serial, _clock, executor, result = self.run_fake("uninstall_failure")

        self.assertEqual("cleanup_failed", result["status"])
        self.assertEqual("driver_cleanup", result["failure_stage"])
        self.assertTrue(result["device_quiescent"])
        self.assertFalse(result["driver_cleaned"])
        self.assertTrue(result["wifi_restored"])
        self.assertTrue(executor.driver_present)

    def test_instrument_error_still_cleans_owned_driver(self):
        _serial, _clock, executor, result = self.run_fake("instrument_error")

        self.assertEqual("runner_error", result["status"])
        self.assertTrue(result["driver_cleanup_attempted"])
        self.assertTrue(result["driver_cleaned"])
        self.assertTrue(result["device_quiescent"])
        self.assertFalse(executor.driver_present)

    def test_empty_and_incomplete_metric_sets_fail(self):
        for mode in ("metrics_empty", "metrics_incomplete", "metric_timeout"):
            with self.subTest(mode=mode):
                _serial, _clock, _executor, result = self.run_fake(mode)
                self.assertEqual("telemetry_incomplete", result["status"])
                self.assertEqual("metric_set", result["failure_stage"])
                self.assertTrue(result["driver_cleaned"])

    def test_preinstall_failures_never_mutate(self):
        for mode in ("wifi_unreadable", "clock_failure", "clock_timeout"):
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertFalse(result["driver_install_attempted"])
                self.assertFalse(result["driver_cleanup_attempted"])
                self.assertFalse(
                    any(
                        "install" in command
                        or "uninstall" in command
                        or "force-stop" in command
                        for command in executor.commands
                    )
                )

    def test_ambiguous_target_never_installs_or_exposes_identity(self):
        serial, _clock, executor, result = self.run_fake("ambiguous")

        self.assertEqual("target_ambiguous", result["status"])
        self.assertFalse(result["driver_install_attempted"])
        self.assertFalse(any("install" in command for command in executor.commands))
        self.assertNotIn(serial, json.dumps(result, sort_keys=True))

    def test_successful_child_reports_bounded_output_truncation(self):
        executor = RUNNER.SubprocessExecutor(max_capture_bytes=128)
        result = executor.run(
            [sys.executable, "-c", "print('x' * 4096)"],
            time.monotonic() + 5,
        )
        self.assertEqual(0, result.returncode)
        self.assertTrue(result.stdout_truncated)
        self.assertLessEqual(len(result.stdout.encode()), 128)

    def test_real_child_timeout_bounds_capture_and_kills_descendant_group(self):
        pid_file = Path(self.temporary.name) / "descendant.pid"
        private_marker = "SYNTHETIC_PRIVATE_COHORT_MARKER"
        child = """
import os
from pathlib import Path
import signal
import subprocess
import sys

signal.signal(signal.SIGTERM, signal.SIG_IGN)
descendant = subprocess.Popen([
    sys.executable,
    "-c",
    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
])
Path(sys.argv[1]).write_text(str(descendant.pid), encoding="utf-8")
payload = (sys.argv[2] * 1024).encode()
while True:
    os.write(1, payload)
"""
        executor = RUNNER.SubprocessExecutor(
            max_capture_bytes=4096,
            term_grace_seconds=0.15,
            kill_grace_seconds=0.15,
        )

        with self.assertRaises(RUNNER.CommandDeadlineExceeded) as raised:
            executor.run(
                [sys.executable, "-c", child, str(pid_file), private_marker],
                time.monotonic() + 0.8,
            )

        self.assertTrue(pid_file.is_file())
        descendant_pid = int(pid_file.read_text(encoding="utf-8"))
        self.assertLessEqual(len(raised.exception.output.encode()), 4096)
        self.assertIn(private_marker, raised.exception.output)
        self.assertNotIn(private_marker, str(raised.exception))
        self.assertNotIn(str(pid_file), str(raised.exception))

        disappearance_deadline = time.monotonic() + 2
        while time.monotonic() < disappearance_deadline and self.process_exists(
            descendant_pid
        ):
            time.sleep(0.02)
        self.assertFalse(self.process_exists(descendant_pid))

    def test_timeout_kills_closed_stdio_descendant_after_leader_exits_on_term(self):
        pid_file = Path(self.temporary.name) / "closed-stdio-descendant.pid"
        child = """
from pathlib import Path
import subprocess
import sys
import time

descendant = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
    ],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    close_fds=True,
)
Path(sys.argv[1]).write_text(str(descendant.pid), encoding="utf-8")
while True:
    time.sleep(1)
"""
        executor = RUNNER.SubprocessExecutor(
            max_capture_bytes=128,
            term_grace_seconds=0.15,
            kill_grace_seconds=0.15,
        )

        with self.assertRaises(RUNNER.CommandDeadlineExceeded):
            executor.run(
                [sys.executable, "-c", child, str(pid_file)],
                time.monotonic() + 0.8,
            )

        self.assertTrue(pid_file.is_file())
        descendant_pid = int(pid_file.read_text(encoding="utf-8"))
        disappearance_deadline = time.monotonic() + 2
        while time.monotonic() < disappearance_deadline and self.process_exists(
            descendant_pid
        ):
            time.sleep(0.02)
        self.assertFalse(self.process_exists(descendant_pid))

    def test_subprocess_executor_requires_posix_process_groups(self):
        with self.assertRaisesRegex(RuntimeError, "POSIX process groups required"):
            RUNNER.SubprocessExecutor(platform_name="nt")

    @staticmethod
    def process_exists(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False


if __name__ == "__main__":
    unittest.main()
