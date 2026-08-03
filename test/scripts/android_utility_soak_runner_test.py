#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


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


class FakeClock:
    def __init__(self) -> None:
        self.value = 100.0

    def monotonic(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds

    def sleep(self, seconds: float) -> None:
        self.advance(seconds)


class FakeExecutor:
    def __init__(self, serial: str, mode: str, clock: FakeClock) -> None:
        self.serial = serial
        self.mode = mode
        self.clock = clock
        self.wifi = "0" if mode == "wifi_disabled" else "1"
        self.driver_present = mode == "driver_preexisting"
        self.calls: list[tuple[tuple[str, ...], float]] = []

    @property
    def commands(self) -> list[tuple[str, ...]]:
        return [command for command, _deadline in self.calls]

    def result(self, returncode: int = 0, stdout: str = ""):
        return RUNNER.CommandResult(returncode, stdout)

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

        if command and command[0] == "/synthetic/apkanalyzer":
            package = (
                "wrong.synthetic.package"
                if self.mode == "invalid_apk"
                else RUNNER.DRIVER_PACKAGE
            )
            return self.result(stdout=package + "\n")

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
                # Model a partial package-manager install. An attempted install
                # is owned by this run even when adb reports failure.
                self.driver_present = True
                return self.result(returncode=1, stdout="Failure\n")
            self.driver_present = True
            return self.result(stdout="Success\n")

        if command[-3:] == ("pm", "path", RUNNER.DRIVER_PACKAGE):
            if self.mode == "driver_state_unknown":
                return self.result(returncode=1)
            if self.mode == "driver_preexisting_multiple":
                return self.result(
                    stdout=(
                        "package:/synthetic/test-driver-base.apk\n"
                        "package:/synthetic/test-driver-split.apk\n"
                    )
                )
            malformed_outputs = {
                "driver_output_malformed": "not-a-package-row\n",
                "driver_output_warning": "Warning: package manager degraded\n",
                "driver_output_error": "Error: package lookup failed\n",
                "driver_output_partial": (
                    "package:/synthetic/test-driver.apk\n"
                    "Warning: trailing untrusted row\n"
                ),
            }
            if self.mode in malformed_outputs:
                return self.result(stdout=malformed_outputs[self.mode])
            return self.result(
                stdout="package:/synthetic/test-driver.apk\n"
                if self.driver_present
                else ""
            )

        if "instrument" in command:
            if self.mode == "timeout":
                self.wifi = "0"
                raise RUNNER.CommandDeadlineExceeded(
                    "SYNTHETIC_PRIVATE_OUTPUT " + self.serial
                )
            if self.mode == "instrument_error":
                self.wifi = "0"
                raise RuntimeError("SYNTHETIC_PRIVATE_ERROR " + self.serial)
            return self.result(stdout="OK (1 test)\nINSTRUMENTATION_CODE: -1\n")

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
                if self.mode != "wifi_disabled":
                    lines.append(
                        "1700000003.000 I CaseinUtilitySoak: casein_soak offline_recovery_ms=1500"
                    )
            return self.result(stdout="\n".join(lines) + "\n")

        if command[-3:] == ("svc", "wifi", "enable"):
            self.wifi = "1"
            return self.result()
        if command[-3:] == ("svc", "wifi", "disable"):
            self.wifi = "0"
            return self.result()

        if command[-3:] == ("am", "force-stop", RUNNER.DRIVER_PACKAGE):
            return self.result()

        if command[-2:] == ("uninstall", RUNNER.DRIVER_PACKAGE):
            if self.mode != "cleanup_failure":
                self.driver_present = False
            return self.result()

        raise AssertionError("unexpected fixed command shape")


class AndroidUtilitySoakRunnerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.driver_apk = Path(self.temporary.name) / "reviewed-driver.apk"
        self.driver_apk.write_bytes(b"synthetic apk fixture")

    def run_fake(self, mode: str = "pass"):
        serial = "synthetic-private-serial"
        clock = FakeClock()
        executor = FakeExecutor(serial, mode, clock)
        result = RUNNER.run_utility_soak(
            serial,
            str(self.driver_apk),
            executor=executor,
            monotonic=clock.monotonic,
            sleep=clock.sleep,
            analyzer_locator=lambda: "/synthetic/apkanalyzer",
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

    def test_pass_requires_complete_metrics_and_cleans_driver(self):
        _serial, _clock, executor, result = self.run_fake()

        self.assertEqual("pass", result["status"])
        self.assertEqual(783_000, result["explicit_wait_budget_ms"])
        self.assertEqual(267_000, result["safety_margin_ms"])
        self.assertEqual(800, result["cold_launch_ms"])
        self.assertEqual(400, result["warm_resume_ms"])
        self.assertEqual(1500, result["offline_recovery_ms"])
        self.assertTrue(result["wifi_restore_attempted"])
        self.assertTrue(result["wifi_restored"])
        self.assertTrue(result["driver_install_attempted"])
        self.assertTrue(result["driver_installed"])
        self.assertTrue(result["driver_cleanup_attempted"])
        self.assertTrue(result["driver_cleaned"])
        self.assertFalse(executor.driver_present)
        self.assertEqual(set(RUNNER.RESULT_KEYS), set(result))

        mutation_commands = [
            command
            for command in executor.commands
            if "install" in command or "uninstall" in command
        ]
        self.assertEqual(2, len(mutation_commands))
        self.assertFalse(
            any("com.example.casein_mob" in command for command in mutation_commands)
        )
        initial_absence_check = next(
            index
            for index, command in enumerate(executor.commands)
            if command[-3:] == ("pm", "path", RUNNER.DRIVER_PACKAGE)
        )
        install = next(
            (index, command)
            for index, command in enumerate(executor.commands)
            if "install" in command
        )
        cleanup_stop = next(
            index
            for index, command in enumerate(executor.commands)
            if command[-3:] == ("am", "force-stop", RUNNER.DRIVER_PACKAGE)
        )
        cleanup_remove = next(
            index
            for index, command in enumerate(executor.commands)
            if command[-2:] == ("uninstall", RUNNER.DRIVER_PACKAGE)
        )
        wifi_restore = max(
            index
            for index, command in enumerate(executor.commands)
            if command[-3:] == ("svc", "wifi", "enable")
        )
        final_absence_check = max(
            index
            for index, command in enumerate(executor.commands)
            if command[-3:] == ("pm", "path", RUNNER.DRIVER_PACKAGE)
        )
        self.assertLess(cleanup_stop, cleanup_remove)
        install_index, install_command = install
        self.assertNotIn("-r", install_command)
        self.assertLess(initial_absence_check, install_index)
        self.assertLess(install_index, cleanup_stop)
        self.assertLess(cleanup_remove, final_absence_check)
        self.assertLess(final_absence_check, wifi_restore)
        self.assertEqual(wifi_restore, len(executor.commands) - 2)
        self.assertEqual(
            ("settings", "get", "global", "wifi_on"),
            executor.commands[-1][-4:],
        )

    def test_empty_and_incomplete_metric_sets_fail(self):
        for mode in ("metrics_empty", "metrics_incomplete", "metric_timeout"):
            with self.subTest(mode=mode):
                _serial, _clock, _executor, result = self.run_fake(mode)
                self.assertEqual("telemetry_incomplete", result["status"])
                self.assertEqual("metric_set", result["failure_stage"])
                self.assertTrue(result["driver_cleaned"])

    def test_initially_disabled_wifi_requires_cold_and_warm_metrics_only(self):
        _serial, _clock, executor, result = self.run_fake("wifi_disabled")

        self.assertEqual("pass", result["status"])
        self.assertFalse(result["wifi_initially_enabled"])
        self.assertIsNone(result["offline_recovery_ms"])
        self.assertTrue(result["wifi_restored"])
        self.assertEqual("0", executor.wifi)
        self.assertTrue(
            any(command[-3:] == ("svc", "wifi", "disable") for command in executor.commands)
        )

    def test_timeout_is_private_restores_wifi_and_cleans_driver(self):
        serial, clock, executor, result = self.run_fake("timeout")

        self.assertEqual("timeout", result["status"])
        self.assertTrue(result["timed_out"])
        self.assertTrue(result["wifi_restored"])
        self.assertTrue(result["driver_cleaned"])
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
        self.assertTrue(all(deadline <= hard_deadline for _command, deadline in executor.calls))
        self.assertLessEqual(clock.monotonic(), hard_deadline)

    def test_post_authorization_failures_always_run_driver_cleanup(self):
        modes = ("install_failure", "instrument_error")
        for mode in modes:
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertTrue(result["driver_cleanup_attempted"])
                self.assertTrue(result["driver_cleaned"])
                self.assertTrue(
                    any(
                        command[-2:] == ("uninstall", RUNNER.DRIVER_PACKAGE)
                        for command in executor.commands
                    )
                )

    def test_preinstall_failures_do_not_claim_or_remove_driver(self):
        modes = (
            "wifi_unreadable",
            "clock_failure",
            "clock_timeout",
            "invalid_apk",
        )
        for mode in modes:
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertFalse(result["driver_install_attempted"])
                self.assertFalse(result["driver_installed"])
                self.assertFalse(result["driver_cleanup_attempted"])
                self.assertFalse(result["driver_cleaned"])
                self.assertFalse(
                    any(
                        "install" in command
                        or "uninstall" in command
                        or command[-3:] == (
                            "am",
                            "force-stop",
                            RUNNER.DRIVER_PACKAGE,
                        )
                        for command in executor.commands
                    )
                )

    def test_preexisting_or_unknown_driver_fails_closed_without_mutation(self):
        expected = {
            "driver_preexisting": "driver_preexisting",
            "driver_preexisting_multiple": "driver_preexisting",
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
                        or command[-3:] == (
                            "am",
                            "force-stop",
                            RUNNER.DRIVER_PACKAGE,
                        )
                        for command in executor.commands
                    )
                )
                self.assertTrue(
                    any(
                        command[-3:] == ("pm", "path", RUNNER.DRIVER_PACKAGE)
                        for command in executor.commands
                    )
                )

    def test_install_race_never_replaces_or_removes_unowned_driver(self):
        _serial, _clock, executor, result = self.run_fake("driver_race")

        self.assertEqual("driver_ownership_conflict", result["status"])
        self.assertTrue(result["driver_install_attempted"])
        self.assertFalse(result["driver_installed"])
        self.assertFalse(result["driver_cleanup_attempted"])
        install_command = next(
            command for command in executor.commands if "install" in command
        )
        self.assertNotIn("-r", install_command)
        self.assertTrue(executor.driver_present)
        self.assertFalse(
            any(
                "uninstall" in command
                or command[-3:] == ("am", "force-stop", RUNNER.DRIVER_PACKAGE)
                for command in executor.commands
            )
        )

    def test_post_baseline_clock_and_deadline_failures_restore_wifi_in_finally(self):
        for mode in ("clock_failure", "clock_timeout"):
            with self.subTest(mode=mode):
                _serial, _clock, executor, result = self.run_fake(mode)
                self.assertTrue(result["wifi_restore_attempted"])
                self.assertTrue(result["wifi_restored"])
                self.assertTrue(
                    any(command[-3:] == ("svc", "wifi", "enable") for command in executor.commands)
                )

    def test_ambiguous_target_never_installs_or_uninstalls(self):
        serial, _clock, executor, result = self.run_fake("ambiguous")

        self.assertEqual("target_ambiguous", result["status"])
        self.assertFalse(result["driver_install_attempted"])
        self.assertFalse(result["driver_cleanup_attempted"])
        self.assertFalse(any("install" in command for command in executor.commands))
        self.assertNotIn(serial, json.dumps(result, sort_keys=True))

    def test_cleanup_failure_overrides_primary_status(self):
        _serial, _clock, _executor, result = self.run_fake("cleanup_failure")

        self.assertEqual("cleanup_failed", result["status"])
        self.assertEqual("driver_cleanup", result["failure_stage"])
        self.assertFalse(result["driver_cleaned"])

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
