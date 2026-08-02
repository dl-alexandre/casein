#!/usr/bin/env python3

from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts/lib"
COLLECTOR_SCRIPT = LIB / "mobile_feed_timing_collector.py"
STREAM_SCRIPT = LIB / "mobile_feed_timing_stream.py"
RECORD_SCHEMA = ROOT / "scripts/schemas/mobile_feed_timing_record.schema.json"

COLLECTOR_SPEC = importlib.util.spec_from_file_location(
    "mobile_feed_timing_collector", COLLECTOR_SCRIPT
)
assert COLLECTOR_SPEC and COLLECTOR_SPEC.loader
collector_module = importlib.util.module_from_spec(COLLECTOR_SPEC)
sys.modules[COLLECTOR_SPEC.name] = collector_module
COLLECTOR_SPEC.loader.exec_module(collector_module)

STREAM_SPEC = importlib.util.spec_from_file_location(
    "mobile_feed_timing_stream", STREAM_SCRIPT
)
assert STREAM_SPEC and STREAM_SPEC.loader
stream_module = importlib.util.module_from_spec(STREAM_SPEC)
sys.modules[STREAM_SPEC.name] = stream_module
STREAM_SPEC.loader.exec_module(stream_module)


def generation(index: int) -> str:
    return base64.urlsafe_b64encode(index.to_bytes(16, "big")).rstrip(b"=").decode()


def native_line(
    generation_value: str,
    stage: str,
    elapsed: int | float | str,
    *,
    duration: int | float | str = 1,
    cycle: str = "cold",
    outcome: str | None = None,
    reason_code: str | None = None,
    prefix: bytes = b"",
    newline: bool = True,
) -> bytes:
    if outcome is None:
        outcome = (
            "started"
            if stage in {"app_start", "connect_requested", "tcp_connect_started"}
            else "succeeded"
        )
    if reason_code is None:
        reason_code = "dns_resolved" if stage == "dns_resolved" else "none"
    line = (
        prefix
        + b"mobile_feed_stage "
        + f"connection_generation={generation_value} ".encode()
        + f"cycle={cycle} ".encode()
        + f"stage={stage} ".encode()
        + f"duration_ms={duration} ".encode()
        + f"elapsed_ms={elapsed} ".encode()
        + f"outcome={outcome} ".encode()
        + f"reason_code={reason_code}".encode()
    )
    return line + (b"\n" if newline else b"")


def complete_lines(
    index: int,
    *,
    cycle: str = "cold",
    prefix: bytes = b"",
) -> list[bytes]:
    stages = list(collector_module.REQUIRED_STAGES)
    if cycle == "origin_switch":
        stages.insert(0, "dns_resolved")
    return [
        native_line(
            generation(index),
            stage,
            offset,
            cycle=cycle,
            prefix=prefix,
        )
        for offset, stage in enumerate(stages, 1)
    ]


def run_adapter(
    lines: list[bytes] | bytes | io.BufferedReader,
    *,
    source: str = "android",
    cycle: str = "cold",
) -> tuple[stream_module.StreamAdapter, int, str, str]:
    if isinstance(lines, list):
        input_stream = io.BytesIO(b"".join(lines))
    elif isinstance(lines, bytes):
        input_stream = io.BytesIO(lines)
    else:
        input_stream = lines
    stdout = io.StringIO()
    stderr = io.StringIO()
    adapter = stream_module.StreamAdapter(source, cycle)
    status = adapter.run(input_stream, stdout, stderr)
    return adapter, status, stdout.getvalue(), stderr.getvalue()


def parsed_lines(output: str) -> list[dict[str, object]]:
    return [json.loads(line) for line in output.splitlines()]


class FragmentedRaw(io.RawIOBase):
    def __init__(self, payload: bytes, fragment_size: int = 3):
        self._payload = payload
        self._offset = 0
        self._fragment_size = fragment_size

    def readable(self) -> bool:
        return True

    def readinto(self, buffer) -> int:
        if self._offset >= len(self._payload):
            return 0
        count = min(
            len(buffer),
            self._fragment_size,
            len(self._payload) - self._offset,
        )
        buffer[:count] = self._payload[self._offset : self._offset + count]
        self._offset += count
        return count


class MobileFeedTimingStreamTest(unittest.TestCase):
    def assert_fixed_status(self, stderr: str) -> dict[str, object]:
        status_lines = stderr.splitlines()
        self.assertEqual(1, len(status_lines))
        payload = json.loads(status_lines[0])
        self.assertEqual(stream_module.ADAPTER_NAME, payload["adapter"])
        self.assertEqual(
            {
                "adapter",
                "status",
                "source",
                "cycle",
                "target_generations",
                "terminal_generations",
                "generations_started",
                "lines_seen",
                "records_parsed",
                "records_forwarded",
                "input_truncated",
                "rejections",
                "discards",
            },
            set(payload),
        )
        self.assertEqual(set(stream_module.REJECTION_CODES), set(payload["rejections"]))
        self.assertEqual(set(stream_module.DISCARD_CODES), set(payload["discards"]))
        return payload

    def test_ios_prefix_and_android_raw_mode_emit_only_exact_collector_records(self):
        ios_prefix = "2026-08-02 10:20:30.123456-0700 CaseinMob[42:7] … ".encode()
        ios_generation = generation(1)
        ios_adapter, ios_status, ios_output, ios_error = run_adapter(
            complete_lines(1, prefix=ios_prefix), source="ios"
        )
        android_generation = generation(2)
        _android_adapter, android_status, android_output, android_error = run_adapter(
            complete_lines(2), source="android"
        )

        self.assertEqual(2, ios_status)
        self.assertEqual(2, android_status)
        for output, expected_generation in (
            (ios_output, ios_generation),
            (android_output, android_generation),
        ):
            records = parsed_lines(output)
            self.assertEqual(8, len(records))
            for record in records:
                self.assertEqual(
                    [
                        "connection_generation",
                        "cycle",
                        "stage",
                        "duration_ms",
                        "elapsed_ms",
                        "outcome",
                        "reason_code",
                    ],
                    list(record),
                )
                self.assertEqual(expected_generation, record["connection_generation"])
                self.assertEqual(7, len(record))

        ios_report = self.assert_fixed_status(ios_error)
        android_report = self.assert_fixed_status(android_error)
        self.assertEqual(8, ios_report["records_forwarded"])
        self.assertEqual(8, android_report["records_forwarded"])
        self.assertNotIn(ios_generation, ios_error)
        self.assertNotIn(ios_prefix.decode(), ios_error)
        self.assertNotIn(android_generation, android_error)
        self.assertNotIn(ios_generation, repr(ios_adapter.__dict__))

        _adapter, rejected, output, error = run_adapter(
            [native_line(generation(3), "connect_requested", 1, prefix=b"logcat: ")],
            source="android",
        )
        self.assertEqual(3, rejected)
        self.assertEqual("", output)
        self.assertEqual(1, self.assert_fixed_status(error)["rejections"]["invalid_prefix"])

    def test_canonical_output_matches_the_committed_seven_field_schema(self):
        schema = json.loads(RECORD_SCHEMA.read_text(encoding="utf-8"))
        required = [
            "connection_generation",
            "cycle",
            "stage",
            "duration_ms",
            "elapsed_ms",
            "outcome",
            "reason_code",
        ]
        self.assertEqual(required, schema["required"])
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(
            set(collector_module.CYCLES),
            set(schema["properties"]["cycle"]["enum"]),
        )
        self.assertEqual(
            set(collector_module.STAGES),
            set(schema["properties"]["stage"]["enum"]),
        )
        self.assertEqual(
            set(collector_module.OUTCOMES),
            set(schema["properties"]["outcome"]["enum"]),
        )
        self.assertEqual(
            set(collector_module.REASON_CODES),
            set(schema["properties"]["reason_code"]["enum"]),
        )

        _adapter, _status, output, _error = run_adapter(complete_lines(1))
        for record in parsed_lines(output):
            self.assertEqual(required, list(record))
            self.assertEqual(set(required), set(record))

    def test_stale_replay_and_other_cycles_are_discarded_until_fresh_start(self):
        prefix = b"2026-08-02T10:20:30Z CaseinMob: "
        stale_generation = generation(90)
        other_generation = generation(91)
        fresh_generation = generation(92)
        stale_lines = [
            native_line(
                stale_generation,
                "first_cards_render_ready",
                100,
                prefix=prefix,
            ),
            native_line(
                stale_generation,
                "disconnected",
                101,
                outcome="failed",
                reason_code="transport_disconnected",
                prefix=prefix,
            ),
            native_line(
                other_generation,
                "connect_requested",
                1,
                cycle="reconnect",
                prefix=prefix,
            ),
        ]
        _adapter, status, output, error = run_adapter(
            stale_lines + complete_lines(92, prefix=prefix), source="ios"
        )

        self.assertEqual(2, status)
        records = parsed_lines(output)
        self.assertEqual(8, len(records))
        self.assertTrue(
            all(record["connection_generation"] == fresh_generation for record in records)
        )
        self.assertNotIn(stale_generation, output)
        self.assertNotIn(other_generation, output)
        report = self.assert_fixed_status(error)
        self.assertEqual(2, report["discards"]["stale_pre_start"])
        self.assertEqual(1, report["discards"]["other_cycle"])
        self.assertNotIn(stale_generation, error)
        self.assertNotIn(other_generation, error)

    def test_cold_app_start_is_valid_and_closed_generations_never_forward_again(self):
        generation_value = generation(93)
        lines = [
            native_line(generation_value, "app_start", 1),
            *[
                native_line(
                    generation_value,
                    stage,
                    offset,
                    duration=1,
                )
                for offset, stage in enumerate(
                    collector_module.REQUIRED_STAGES,
                    2,
                )
            ],
            native_line(
                generation_value,
                "disconnected",
                10,
                outcome="failed",
                reason_code="transport_disconnected",
            ),
        ]
        _adapter, status, output, error = run_adapter(lines)

        self.assertEqual(2, status)
        records = parsed_lines(output)
        self.assertEqual(9, len(records))
        self.assertEqual("app_start", records[0]["stage"])
        self.assertEqual("first_cards_render_ready", records[-1]["stage"])
        self.assertFalse(any(record["stage"] == "disconnected" for record in records))
        report = self.assert_fixed_status(error)
        self.assertEqual(1, report["terminal_generations"])
        self.assertEqual(1, report["discards"]["closed_generation"])

    def test_marker_count_suffix_injection_and_secret_text_fail_closed_without_echo(self):
        secret = "password=do-not-retain"
        valid = native_line(generation(1), "connect_requested", 1)
        cases = {
            "no_marker": f"unrelated log {secret}\n".encode(),
            "multiple_markers": b"mobile_feed_stage prefix " + valid,
            "invalid_marker": valid[:-1] + f" {secret}\n".encode(),
        }
        for rejection_code, line in cases.items():
            with self.subTest(rejection_code=rejection_code):
                _adapter, status, output, error = run_adapter(line)
                self.assertEqual(3, status)
                self.assertEqual("", output)
                report = self.assert_fixed_status(error)
                self.assertEqual(1, report["rejections"][rejection_code])
                self.assertNotIn(secret, error)
                self.assertNotIn(generation(1), error)

    def test_malformed_generation_category_field_order_envelope_and_sequence_reject(self):
        valid = native_line(generation(1), "connect_requested", 1)
        malformed_cases = {
            "invalid_generation": valid.replace(generation(1).encode(), b"not_canonical"),
            "invalid_category": valid.replace(b"cycle=cold", b"cycle=secret_cycle"),
            "invalid_marker": valid.replace(
                b"cycle=cold stage=connect_requested",
                b"stage=connect_requested cycle=cold",
            ),
            "invalid_envelope": valid.replace(b"outcome=started", b"outcome=succeeded"),
        }
        for rejection_code, line in malformed_cases.items():
            with self.subTest(rejection_code=rejection_code):
                _adapter, status, output, error = run_adapter(line)
                self.assertEqual(3, status)
                self.assertEqual("", output)
                report = self.assert_fixed_status(error)
                self.assertEqual(1, report["rejections"][rejection_code])
                self.assertNotIn("secret_cycle", error)

        ordered_then_regressed = [
            native_line(generation(2), "connect_requested", 1),
            native_line(generation(2), "tcp_connected", 2),
            native_line(generation(2), "tcp_connect_started", 3),
        ]
        _adapter, status, output, error = run_adapter(ordered_then_regressed)
        self.assertEqual(3, status)
        self.assertEqual(2, len(parsed_lines(output)))
        self.assertEqual(1, self.assert_fixed_status(error)["rejections"]["invalid_sequence"])

    def test_timing_tokens_and_sequence_continuity_are_strict(self):
        malformed_tokens = ("-1", "NaN", "1e1", "1.0000", "2147483648")
        for token in malformed_tokens:
            with self.subTest(token=token):
                line = native_line(
                    generation(1),
                    "connect_requested",
                    token,
                    duration="0",
                )
                _adapter, status, output, error = run_adapter(line)
                self.assertEqual(3, status)
                self.assertEqual("", output)
                self.assertEqual(
                    1,
                    self.assert_fixed_status(error)["rejections"]["invalid_timing"],
                )
                self.assertNotIn(token, error)

        timing_sequences = (
            [
                native_line(generation(2), "connect_requested", 1),
                native_line(generation(2), "tcp_connect_started", 3, duration=1),
            ],
            [
                native_line(generation(3), "connect_requested", 2, duration=1),
                native_line(generation(3), "tcp_connect_started", 1, duration=0),
            ],
            [native_line(generation(4), "connect_requested", 1, duration=2)],
        )
        for lines in timing_sequences:
            _adapter, status, _output, error = run_adapter(lines)
            self.assertEqual(3, status)
            report = self.assert_fixed_status(error)
            self.assertEqual(
                1,
                report["rejections"][
                    "invalid_timing" if len(lines) == 1 else "invalid_sequence"
                ],
            )

    def test_lone_snapshot_received_at_end_of_stream_is_invalid(self):
        lines = complete_lines(1)[:-2]
        _adapter, status, output, error = run_adapter(lines)

        self.assertEqual(3, status)
        self.assertEqual(
            "snapshot_received",
            parsed_lines(output)[-1]["stage"],
        )
        report = self.assert_fixed_status(error)
        self.assertEqual(1, report["rejections"]["invalid_sequence"])
        self.assertEqual(0, report["terminal_generations"])

    def test_origin_switch_requires_dns_then_connect_and_reconnect_requires_connect(self):
        _adapter, status, output, error = run_adapter(
            complete_lines(1, cycle="origin_switch"), cycle="origin_switch"
        )
        self.assertEqual(2, status)
        self.assertEqual(9, len(parsed_lines(output)))
        self.assertEqual(1, self.assert_fixed_status(error)["terminal_generations"])

        wrong_second = [
            native_line(
                generation(2),
                "dns_resolved",
                1,
                cycle="origin_switch",
            ),
            native_line(
                generation(2),
                "tcp_connect_started",
                2,
                cycle="origin_switch",
            ),
        ]
        _adapter, rejected, _output, rejected_error = run_adapter(
            wrong_second, cycle="origin_switch"
        )
        self.assertEqual(3, rejected)
        self.assertEqual(
            1,
            self.assert_fixed_status(rejected_error)["rejections"]["invalid_sequence"],
        )

        reconnect_stale = [
            native_line(
                generation(3),
                "disconnected",
                1,
                cycle="reconnect",
                outcome="failed",
                reason_code="transport_disconnected",
            ),
            *complete_lines(4, cycle="reconnect"),
        ]
        _adapter, reconnect_status, reconnect_output, reconnect_error = run_adapter(
            reconnect_stale, cycle="reconnect"
        )
        self.assertEqual(2, reconnect_status)
        self.assertEqual(8, len(parsed_lines(reconnect_output)))
        self.assertEqual(
            1,
            self.assert_fixed_status(reconnect_error)["discards"]["stale_pre_start"],
        )

    def test_target_stops_at_exactly_twenty_terminals(self):
        all_lines = [
            line for index in range(1, 22) for line in complete_lines(index)
        ]
        _adapter, status, output, error = run_adapter(all_lines)
        self.assertEqual(0, status)
        records = parsed_lines(output)
        self.assertEqual(20 * 8, len(records))
        self.assertNotIn(generation(21), output)
        report = self.assert_fixed_status(error)
        self.assertEqual("complete", report["status"])
        self.assertEqual(20, report["terminal_generations"])
        self.assertEqual(20 * 8, report["lines_seen"])
        self.assertEqual(20 * 8, report["records_forwarded"])

    def test_twenty_missing_required_stage_generations_cannot_claim_completion(self):
        incomplete_stages = [
            "connect_requested",
            "transport_connected",
            "mobile_join_replied",
            "snapshot_received",
            "snapshot_accepted",
            "first_cards_render_ready",
        ]
        lines = [
            native_line(generation(index), stage, elapsed)
            for index in range(1, 21)
            for elapsed, stage in enumerate(incomplete_stages, 1)
        ]
        _adapter, status, output, error = run_adapter(lines)

        self.assertEqual(3, status)
        report = self.assert_fixed_status(error)
        self.assertEqual("invalid", report["status"])
        self.assertEqual(0, report["terminal_generations"])
        self.assertEqual(1, report["rejections"]["invalid_sequence"])
        self.assertEqual(5, report["records_forwarded"])

        collector = collector_module.Collector("android", "cold")
        collector_module.collect_stream(io.BytesIO(output.encode()), collector)
        aggregate = collector.report()
        self.assertEqual("incomplete", aggregate["status"])
        self.assertEqual(0, aggregate["complete_generations"])

    def test_twenty_same_generation_cycle_flip_contaminations_fail_closed(self):
        lines: list[bytes] = []
        for index in range(1, 21):
            complete = complete_lines(index)
            lines.append(complete[0])
            lines.append(
                native_line(
                    generation(index),
                    "disconnected",
                    2,
                    cycle="reconnect",
                    outcome="failed",
                    reason_code="transport_disconnected",
                )
            )
            lines.extend(complete[1:])

        _adapter, status, output, error = run_adapter(lines)

        self.assertEqual(3, status)
        report = self.assert_fixed_status(error)
        self.assertEqual("invalid", report["status"])
        self.assertEqual(0, report["terminal_generations"])
        self.assertEqual(1, report["rejections"]["invalid_sequence"])
        self.assertEqual(0, report["discards"]["other_cycle"])
        self.assertEqual(1, report["records_forwarded"])

        collector = collector_module.Collector("android", "cold")
        collector_module.collect_stream(io.BytesIO(output.encode()), collector)
        aggregate = collector.report()
        self.assertEqual("incomplete", aggregate["status"])
        self.assertEqual(0, aggregate["complete_generations"])

    def test_fragmented_pipe_is_reassembled_but_oversized_and_unterminated_lines_reject(self):
        payload = b"".join(complete_lines(1))
        fragmented = io.BufferedReader(FragmentedRaw(payload), buffer_size=4)
        _adapter, status, output, error = run_adapter(fragmented)
        self.assertEqual(2, status)
        self.assertEqual(8, len(parsed_lines(output)))
        self.assertEqual("incomplete", self.assert_fixed_status(error)["status"])

        oversized = b"x" * (stream_module.MAX_LINE_BYTES + 1) + b"\n"
        _adapter, status, output, error = run_adapter(oversized)
        self.assertEqual(3, status)
        self.assertEqual("", output)
        report = self.assert_fixed_status(error)
        self.assertEqual(1, report["rejections"]["line_too_large"])
        self.assertTrue(report["input_truncated"])

        unterminated = native_line(
            generation(2), "connect_requested", 1, newline=False
        )
        _adapter, status, output, error = run_adapter(unterminated)
        self.assertEqual(3, status)
        self.assertEqual("", output)
        self.assertEqual(
            1, self.assert_fixed_status(error)["rejections"]["missing_newline"]
        )

    def test_line_byte_generation_and_record_bounds_fail_closed(self):
        self.assertEqual(collector_module.MAX_LINE_BYTES, stream_module.MAX_LINE_BYTES)
        self.assertEqual(collector_module.MAX_INPUT_BYTES, stream_module.MAX_INPUT_BYTES)
        self.assertEqual(collector_module.MAX_LINES, stream_module.MAX_LINES)
        self.assertEqual(collector_module.MAX_GENERATIONS, stream_module.MAX_GENERATIONS)

        original_input_bytes = stream_module.MAX_INPUT_BYTES
        try:
            stream_module.MAX_INPUT_BYTES = 10
            _adapter, status, _output, error = run_adapter(
                native_line(generation(1), "connect_requested", 1)
            )
        finally:
            stream_module.MAX_INPUT_BYTES = original_input_bytes
        self.assertEqual(3, status)
        self.assertEqual(
            1, self.assert_fixed_status(error)["rejections"]["input_limit_exceeded"]
        )

        original_lines = stream_module.MAX_LINES
        try:
            stream_module.MAX_LINES = 1
            _adapter, status, _output, error = run_adapter(
                [
                    native_line(generation(2), "connect_requested", 1),
                    native_line(generation(2), "tcp_connect_started", 2),
                ]
            )
        finally:
            stream_module.MAX_LINES = original_lines
        self.assertEqual(3, status)
        self.assertEqual(
            1, self.assert_fixed_status(error)["rejections"]["line_limit_exceeded"]
        )

        original_records = stream_module.MAX_RECORDS
        try:
            stream_module.MAX_RECORDS = 1
            _adapter, status, _output, error = run_adapter(
                [
                    native_line(generation(3), "connect_requested", 1),
                    native_line(generation(3), "tcp_connect_started", 2),
                ]
            )
        finally:
            stream_module.MAX_RECORDS = original_records
        self.assertEqual(3, status)
        self.assertEqual(
            1, self.assert_fixed_status(error)["rejections"]["record_limit_exceeded"]
        )

        partials: list[bytes] = []
        for index in range(1, collector_module.MAX_GENERATIONS + 2):
            partials.extend(
                [
                    native_line(generation(index), "connect_requested", 1),
                    native_line(
                        generation(index),
                        "disconnected",
                        2,
                        outcome="failed",
                        reason_code="transport_disconnected",
                    ),
                ]
            )
        _adapter, status, _output, error = run_adapter(partials)
        self.assertEqual(3, status)
        self.assertEqual(
            1, self.assert_fixed_status(error)["rejections"]["too_many_generations"]
        )

        too_many_for_one: list[bytes] = [
            native_line(generation(500), "connect_requested", 1),
            native_line(generation(500), "tcp_connect_started", 2),
            native_line(generation(500), "tcp_connected", 3),
            native_line(generation(500), "transport_connected", 4),
            native_line(generation(500), "mobile_join_replied", 5),
        ]
        elapsed = 6
        for _index in range(30):
            too_many_for_one.append(
                native_line(generation(500), "snapshot_received", elapsed)
            )
            elapsed += 1
            too_many_for_one.append(
                native_line(generation(500), "snapshot_accepted", elapsed)
            )
            elapsed += 1
        _adapter, status, _output, error = run_adapter(too_many_for_one)
        self.assertEqual(3, status)
        self.assertEqual(
            1, self.assert_fixed_status(error)["rejections"]["record_limit_exceeded"]
        )

    def test_adapter_output_completes_the_merged_collector_cohort(self):
        input_lines = [
            line for index in range(1, 21) for line in complete_lines(index)
        ]
        _adapter, status, output, error = run_adapter(input_lines)
        self.assertEqual(0, status)
        adapter_report = self.assert_fixed_status(error)
        self.assertEqual(20, adapter_report["terminal_generations"])

        collector = collector_module.Collector("android", "cold")
        collector_module.collect_stream(io.BytesIO(output.encode()), collector)
        report = collector.report()
        self.assertEqual("complete", report["status"])
        self.assertEqual(20, report["complete_generations"])
        self.assertEqual(20, report["observed_generations"])
        self.assertEqual(160, report["input"]["records_accepted"])
        serialized = json.dumps(report, sort_keys=True)
        for index in range(1, 21):
            self.assertNotIn(generation(index), serialized)

    def test_real_closed_downstream_pipe_has_one_fixed_status_and_exit_three(self):
        read_descriptor, write_descriptor = os.pipe()
        os.close(read_descriptor)
        process = subprocess.Popen(
            [
                sys.executable,
                str(STREAM_SCRIPT),
                "--source",
                "android",
                "--cycle",
                "cold",
            ],
            stdin=subprocess.PIPE,
            stdout=write_descriptor,
            stderr=subprocess.PIPE,
            close_fds=True,
        )
        os.close(write_descriptor)
        _stdout, stderr = process.communicate(
            input=native_line(generation(700), "connect_requested", 1),
            timeout=5,
        )

        self.assertEqual(3, process.returncode)
        lines = stderr.decode().splitlines()
        self.assertEqual(1, len(lines))
        report = json.loads(lines[0])
        self.assertEqual("invalid", report["status"])
        self.assertEqual(1, report["rejections"]["output_unavailable"])
        self.assertNotIn(generation(700), stderr.decode())
        self.assertNotIn("BrokenPipeError", stderr.decode())

    def test_normal_cli_import_never_creates_python_bytecode(self):
        with tempfile.TemporaryDirectory(prefix="casein-mobile-timing-stream-") as temp:
            isolated = Path(temp)
            copied_stream = isolated / STREAM_SCRIPT.name
            copied_collector = isolated / COLLECTOR_SCRIPT.name
            shutil.copyfile(STREAM_SCRIPT, copied_stream)
            shutil.copyfile(COLLECTOR_SCRIPT, copied_collector)
            environment = os.environ.copy()
            environment.pop("PYTHONDONTWRITEBYTECODE", None)

            result = subprocess.run(
                [
                    sys.executable,
                    str(copied_stream),
                    "--source",
                    "android",
                    "--cycle",
                    "cold",
                ],
                input=b"",
                capture_output=True,
                check=False,
                env=environment,
            )

            self.assertEqual(2, result.returncode)
            self.assertEqual(b"", result.stdout)
            self.assertEqual("incomplete", json.loads(result.stderr)["status"])
            self.assertEqual([], list(isolated.rglob("__pycache__")))
            self.assertEqual([], list(isolated.rglob("*.pyc")))

    def test_cli_rejects_non_twenty_target_without_reflecting_arguments(self):
        secret_argument = "password=never-echo"
        result = subprocess.run(
            [
                sys.executable,
                str(STREAM_SCRIPT),
                "--source",
                "ios",
                "--cycle",
                "cold",
                "--target",
                "19",
                secret_argument,
            ],
            input=b"",
            capture_output=True,
            check=False,
        )
        self.assertEqual(64, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertEqual(
            {"adapter": stream_module.ADAPTER_NAME, "status": "invalid_arguments"},
            json.loads(result.stderr),
        )
        self.assertNotIn(secret_argument.encode(), result.stderr)


if __name__ == "__main__":
    unittest.main()
