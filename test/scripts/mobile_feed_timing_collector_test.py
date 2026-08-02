#!/usr/bin/env python3

from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/lib/mobile_feed_timing_collector.py"
SPEC = importlib.util.spec_from_file_location("mobile_feed_timing_collector", SCRIPT)
assert SPEC and SPEC.loader
collector_module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = collector_module
SPEC.loader.exec_module(collector_module)


REQUIRED_STAGES = collector_module.REQUIRED_STAGES


def generation(index: int) -> str:
    return base64.urlsafe_b64encode(index.to_bytes(16, "big")).rstrip(b"=").decode()


def record(
    generation_value: str,
    stage: str,
    elapsed: int | float,
    *,
    duration: int | float = 1,
    cycle: str = "cold",
    outcome: str | None = None,
    reason_code: str | None = None,
) -> dict[str, object]:
    return {
        "connection_generation": generation_value,
        "cycle": cycle,
        "stage": stage,
        "duration_ms": duration,
        "elapsed_ms": elapsed,
        "outcome": (
            outcome
            if outcome is not None
            else (
                "started"
                if stage in {"app_start", "connect_requested", "tcp_connect_started"}
                else "succeeded"
            )
        ),
        "reason_code": (
            reason_code
            if reason_code is not None
            else ("dns_resolved" if stage == "dns_resolved" else "none")
        ),
    }


def complete_lines(index: int, cycle: str = "cold") -> list[bytes]:
    generation_value = generation(index)
    stages = list(REQUIRED_STAGES)
    if cycle == "origin_switch":
        stages.insert(0, "dns_resolved")
    return [
        (json.dumps(record(generation_value, stage, offset, cycle=cycle)) + "\n").encode()
        for offset, stage in enumerate(stages, 1)
    ]


def double_snapshot_lines(index: int, cycle: str = "cold") -> list[bytes]:
    stages = [
        *(["dns_resolved"] if cycle == "origin_switch" else []),
        *REQUIRED_STAGES[:5],
        "snapshot_received",
        "snapshot_accepted",
        "snapshot_received",
        "snapshot_accepted",
        "first_cards_render_ready",
    ]
    generation_value = generation(index)
    return [
        (json.dumps(record(generation_value, stage, offset, cycle=cycle)) + "\n").encode()
        for offset, stage in enumerate(stages, 1)
    ]


def encoded_record(*args, **kwargs) -> bytes:
    return (json.dumps(record(*args, **kwargs)) + "\n").encode()


def collect(lines: list[bytes], cycle: str = "cold"):
    collector = collector_module.Collector("ios", cycle)
    collector_module.collect_stream(io.BytesIO(b"".join(lines)), collector)
    return collector, collector.report()


EXPECTED_STAGE_ENVELOPES = {
    "app_start": {("started", "none")},
    "connect_requested": {("started", "none")},
    "tcp_connect_started": {("started", "none")},
    "dns_resolved": {
        ("succeeded", "dns_resolved"),
        ("skipped", "dns_ip_literal"),
        ("skipped", "no_configuration"),
        ("failed", "dns_invalid_url"),
        ("failed", "dns_resolution_failed"),
    },
    "no_configuration": {("skipped", "no_configuration")},
    "disconnected": {("failed", "transport_disconnected")},
    "snapshot_rejected": {
        ("failed", reason_code)
        for reason_code in {
            "invalid_payload",
            "transport_not_ready",
            "connection_generation_mismatch",
            "connection_cycle_mismatch",
            "invalid_snapshot_version",
            "invalid_origin",
            "unknown_origin",
            "origin_mismatch",
            "state_unavailable",
            "snapshot_version_regression",
        }
    },
    **{
        stage: {("succeeded", "none")}
        for stage in {
            "dependencies_ready",
            "profile_restored",
            "client_started",
            "database_ready",
            "root_started",
            "tcp_connected",
            "transport_connected",
            "mobile_join_replied",
            "snapshot_received",
            "snapshot_accepted",
            "first_cards_render_ready",
        }
    },
}


class MobileFeedTimingCollectorTest(unittest.TestCase):
    def test_stage_outcome_reason_envelope_matches_native_contract(self):
        self.assertEqual(set(collector_module.STAGES), set(EXPECTED_STAGE_ENVELOPES))
        self.assertEqual(
            EXPECTED_STAGE_ENVELOPES,
            {
                stage: set(envelopes)
                for stage, envelopes in collector_module.STAGE_ENVELOPES.items()
            },
        )

        for stage in collector_module.STAGES:
            for outcome in collector_module.OUTCOMES:
                for reason_code in collector_module.REASON_CODES:
                    marker = collector_module.NormalizedRecord(
                        generation_surrogate="surrogate",
                        cycle="cold",
                        stage=stage,
                        duration_ms=1,
                        elapsed_ms=1,
                        outcome=outcome,
                        reason_code=reason_code,
                    )
                    with self.subTest(
                        stage=stage, outcome=outcome, reason_code=reason_code
                    ):
                        self.assertEqual(
                            (outcome, reason_code) in EXPECTED_STAGE_ENVELOPES[stage],
                            collector_module._valid_stage_envelope(marker),
                        )

    def test_exact_twenty_complete_generations_produce_aggregate_only_output(self):
        lines = [line for index in range(1, 21) for line in complete_lines(index)]
        collector, report = collect(lines)

        self.assertEqual("complete", report["status"])
        self.assertEqual(20, report["complete_generations"])
        self.assertEqual(20, report["observed_generations"])
        self.assertEqual(160, report["input"]["records_accepted"])
        self.assertEqual(0, report["integrity"]["invalid_stage_envelopes"])
        self.assertEqual(20, report["stage_timings"]["tcp_connected"]["sample_count"])
        self.assertEqual(
            {"min": 8, "p50": 8, "p95": 8, "max": 8},
            report["first_cards_elapsed_ms"],
        )

        serialized = json.dumps(report, sort_keys=True)
        for index in range(1, 21):
            self.assertNotIn(generation(index), serialized)
        self.assertNotIn("generation_surrogate", serialized)
        self.assertNotIn("connection_generation", serialized)

        # A raw generation is never a state key; the per-run HMAC is ephemeral.
        self.assertTrue(set(collector._generations).isdisjoint({generation(1)}))
        other = collector_module.Collector("ios", "cold")
        first = collector_module.parse_record(complete_lines(1)[0], collector._hmac_key)
        second = collector_module.parse_record(complete_lines(1)[0], other._hmac_key)
        self.assertNotEqual(first.generation_surrogate, second.generation_surrogate)

    def test_partial_generations_are_explicitly_incomplete(self):
        lines = [line for index in range(1, 20) for line in complete_lines(index)]
        lines.append(complete_lines(20)[0])
        _collector, report = collect(lines)

        self.assertEqual("incomplete", report["status"])
        self.assertEqual(19, report["complete_generations"])
        self.assertEqual(1, report["integrity"]["partial_generations"])

        _collector, undersized = collect(complete_lines(21))
        self.assertIsNone(undersized["first_cards_elapsed_ms"]["p95"])

    def test_invalid_stage_envelope_hard_invalidates_without_state_mutation(self):
        collector = collector_module.Collector("ios", "cold")
        collector.add_line(encoded_record(generation(1), "connect_requested", 1))
        state = next(iter(collector._generations.values()))

        collector.add_line(
            encoded_record(
                generation(1),
                "tcp_connect_started",
                2,
                outcome="failed",
                reason_code="transport_disconnected",
            )
        )
        report = collector.report()

        self.assertTrue(state.invalid)
        self.assertEqual(["connect_requested"], [item.stage for item in state.records])
        self.assertEqual(1, state.last_elapsed_ms)
        self.assertEqual({"connect_requested"}, state.stages)
        self.assertEqual(1, collector.records_accepted)
        self.assertEqual({}, report["failed_outcomes_by_reason"])
        self.assertEqual(1, report["integrity"]["invalid_stage_envelopes"])
        self.assertEqual(1, report["integrity"]["invalid_generations"])
        self.assertEqual("invalid", report["status"])

    def test_invalid_final_marker_poisons_a_potentially_complete_generation(self):
        lines = complete_lines(1)
        invalid = json.loads(lines[-1])
        invalid["reason_code"] = "transport_disconnected"
        lines[-1] = (json.dumps(invalid) + "\n").encode()

        collector, report = collect(lines)
        state = next(iter(collector._generations.values()))

        self.assertEqual("invalid", report["status"])
        self.assertEqual(0, report["complete_generations"])
        self.assertEqual(1, report["integrity"]["invalid_stage_envelopes"])
        self.assertEqual(1, report["integrity"]["invalid_generations"])
        self.assertIsNone(state.terminal_stage)
        self.assertEqual("snapshot_accepted", state.records[-1].stage)

    def test_twenty_good_generations_plus_one_invalid_envelope_is_invalid(self):
        lines = [line for index in range(1, 21) for line in complete_lines(index)]
        invalid_generation = complete_lines(21)
        invalid = json.loads(invalid_generation[2])
        invalid["reason_code"] = "transport_disconnected"
        invalid_generation[2] = (json.dumps(invalid) + "\n").encode()
        lines.extend(invalid_generation)

        _collector, report = collect(lines)

        self.assertEqual("invalid", report["status"])
        self.assertEqual(20, report["complete_generations"])
        self.assertEqual(1, report["integrity"]["invalid_stage_envelopes"])
        self.assertEqual(1, report["integrity"]["invalid_generations"])
        self.assertEqual({}, report["failed_outcomes_by_reason"])

    def test_failed_partial_reconnects_do_not_pollute_twenty_successes(self):
        lines = [line for index in range(1, 21) for line in complete_lines(index, "reconnect")]
        for index in range(101, 106):
            lines.extend(
                [
                    encoded_record(
                        generation(index),
                        "connect_requested",
                        1,
                        cycle="reconnect",
                    ),
                    encoded_record(
                        generation(index),
                        "disconnected",
                        2,
                        cycle="reconnect",
                        outcome="failed",
                        reason_code="transport_disconnected",
                    ),
                ]
            )

        _collector, report = collect(lines, "reconnect")
        self.assertEqual("complete", report["status"])
        self.assertEqual(20, report["complete_generations"])
        self.assertEqual(5, report["integrity"]["partial_generations"])
        self.assertEqual(5, report["failed_outcomes_by_reason"]["transport_disconnected"])

    def test_old_disconnected_before_twenty_reconnects_is_invalid(self):
        lines = [
            encoded_record(
                generation(99),
                "disconnected",
                1,
                cycle="reconnect",
                outcome="failed",
                reason_code="transport_disconnected",
            ),
            *(line for index in range(1, 21) for line in complete_lines(index, "reconnect")),
        ]

        _collector, report = collect(lines, "reconnect")
        self.assertEqual("invalid", report["status"])
        self.assertEqual(20, report["complete_generations"])
        self.assertEqual(1, report["integrity"]["invalid_start_stages"])
        self.assertEqual(1, report["integrity"]["invalid_generations"])

    def test_disconnected_after_each_completed_generation_is_invalid(self):
        lines = []
        for index in range(1, 21):
            lines.extend(complete_lines(index, "reconnect"))
            lines.append(
                encoded_record(
                    generation(index),
                    "disconnected",
                    9,
                    cycle="reconnect",
                    outcome="failed",
                    reason_code="transport_disconnected",
                )
            )

        _collector, report = collect(lines, "reconnect")
        self.assertEqual("invalid", report["status"])
        self.assertEqual(0, report["complete_generations"])
        self.assertEqual(20, report["integrity"]["post_terminal_markers"])
        self.assertEqual(20, report["integrity"]["invalid_generations"])

    def test_twenty_origin_switches_start_with_dns_then_connect(self):
        lines = [
            line
            for index in range(1, 21)
            for line in complete_lines(index, "origin_switch")
        ]
        _collector, report = collect(lines, "origin_switch")

        self.assertEqual("complete", report["status"])
        self.assertEqual(20, report["complete_generations"])
        self.assertEqual(20, report["stage_timings"]["dns_resolved"]["sample_count"])
        self.assertEqual(180, report["input"]["records_accepted"])

    def test_cycle_specific_start_boundaries_fail_closed(self):
        cases = [
            (
                "reconnect",
                [
                    encoded_record(
                        generation(1),
                        "disconnected",
                        1,
                        cycle="reconnect",
                        outcome="failed",
                        reason_code="transport_disconnected",
                    )
                ],
            ),
            (
                "origin_switch",
                [
                    encoded_record(
                        generation(2), "connect_requested", 1, cycle="origin_switch"
                    )
                ],
            ),
            (
                "origin_switch",
                [
                    encoded_record(
                        generation(3), "dns_resolved", 1, cycle="origin_switch"
                    ),
                    encoded_record(
                        generation(3), "tcp_connect_started", 2, cycle="origin_switch"
                    ),
                ],
            ),
            (
                "cold",
                [encoded_record(generation(4), "dns_resolved", 1, cycle="cold")],
            ),
        ]

        for cycle, lines in cases:
            with self.subTest(cycle=cycle, stages=[json.loads(line)["stage"] for line in lines]):
                _collector, report = collect(lines, cycle)
                self.assertEqual("invalid", report["status"])
                self.assertEqual(1, report["integrity"]["invalid_start_stages"])

    def test_hydrating_then_authoritative_pairs_use_final_pair_summaries(self):
        lines = [line for index in range(1, 21) for line in double_snapshot_lines(index)]
        _collector, report = collect(lines)

        self.assertEqual("complete", report["status"])
        self.assertEqual(20, report["complete_generations"])
        self.assertEqual(200, report["input"]["records_accepted"])
        self.assertEqual(20, report["stage_timings"]["snapshot_received"]["sample_count"])
        self.assertEqual(20, report["stage_timings"]["snapshot_accepted"]["sample_count"])
        self.assertEqual(
            {"min": 8, "p50": 8, "p95": 8, "max": 8},
            report["stage_timings"]["snapshot_received"]["elapsed_ms"],
        )
        self.assertEqual(
            {"min": 9, "p50": 9, "p95": 9, "max": 9},
            report["stage_timings"]["snapshot_accepted"]["elapsed_ms"],
        )
        self.assertEqual(
            {"min": 1, "p50": 1, "p95": 1, "max": 1},
            report["stage_timings"]["first_cards_render_ready"]["duration_ms"],
        )

    def test_snapshot_pair_state_machine_rejects_invalid_sequences(self):
        prefix = complete_lines(1)[:5]
        cases = {
            "lone": [*prefix, complete_lines(1)[5]],
            "misordered": [
                *prefix,
                encoded_record(generation(1), "snapshot_accepted", 6),
            ],
            "rejected": [
                *prefix,
                encoded_record(generation(1), "snapshot_received", 6),
                encoded_record(
                    generation(1),
                    "snapshot_rejected",
                    7,
                    outcome="failed",
                    reason_code="invalid_payload",
                ),
            ],
            "postpaint": [
                *complete_lines(1),
                encoded_record(generation(1), "snapshot_received", 9),
                encoded_record(generation(1), "snapshot_accepted", 10),
            ],
        }

        timing_mismatch = double_snapshot_lines(2)
        mismatched = json.loads(timing_mismatch[-2])
        mismatched["duration_ms"] = 0.5
        timing_mismatch[-2] = (json.dumps(mismatched) + "\n").encode()
        cases["timing_mismatch"] = timing_mismatch

        for name, lines in cases.items():
            with self.subTest(name=name):
                _collector, report = collect(lines)
                self.assertEqual("invalid", report["status"])
                self.assertEqual(1, report["integrity"]["invalid_generations"])

        _collector, rejected = collect(cases["rejected"])
        self.assertEqual(1, rejected["integrity"]["snapshot_rejections"])
        self.assertEqual(
            1, rejected["failed_outcomes_by_reason"]["invalid_payload"]
        )
        _collector, postpaint = collect(cases["postpaint"])
        self.assertEqual(1, postpaint["integrity"]["post_terminal_markers"])
        _collector, mismatch = collect(cases["timing_mismatch"])
        self.assertEqual(1, mismatch["integrity"]["duration_interval_mismatches"])

    def test_explicit_snapshot_pair_errors_count_once_and_clear_pending_state(self):
        prefix = complete_lines(1)[:5]
        cases = {
            "received_twice": [
                *prefix,
                encoded_record(generation(1), "snapshot_received", 6),
                encoded_record(generation(1), "snapshot_received", 7),
            ],
            "invalid_accept": [
                *prefix,
                encoded_record(generation(1), "snapshot_received", 6),
                encoded_record(
                    generation(1),
                    "snapshot_accepted",
                    7,
                    outcome="failed",
                    reason_code="invalid_payload",
                ),
            ],
        }

        for name, lines in cases.items():
            with self.subTest(name=name):
                collector, report = collect(lines)
                state = next(iter(collector._generations.values()))

                self.assertEqual("invalid", report["status"])
                self.assertEqual(1, report["integrity"]["snapshot_sequence_errors"])
                self.assertIsNone(state.pending_snapshot_received)

                if name == "invalid_accept":
                    self.assertEqual(
                        1, report["integrity"]["invalid_stage_envelopes"]
                    )
                    self.assertEqual({}, report["failed_outcomes_by_reason"])
                else:
                    self.assertEqual(
                        0, report["integrity"]["invalid_stage_envelopes"]
                    )

    def test_twenty_one_complete_generations_are_rejected_as_excess(self):
        lines = [line for index in range(1, 22) for line in complete_lines(index)]
        _collector, report = collect(lines)
        self.assertEqual("invalid", report["status"])
        self.assertEqual(1, report["integrity"]["excess_complete_generations"])

    def test_duplicate_order_gap_and_elapsed_integrity_fail_closed(self):
        duplicate = complete_lines(1)
        duplicate.insert(1, duplicate[0])
        _collector, duplicate_report = collect(duplicate)
        self.assertEqual("invalid", duplicate_report["status"])
        self.assertEqual(1, duplicate_report["integrity"]["duplicate_stages"])

        out_of_order_records = complete_lines(2)
        earlier = json.loads(out_of_order_records[2])
        later = json.loads(out_of_order_records[3])
        earlier["stage"], later["stage"] = later["stage"], earlier["stage"]
        out_of_order_records[2] = (json.dumps(earlier) + "\n").encode()
        out_of_order_records[3] = (json.dumps(later) + "\n").encode()
        _collector, order_report = collect(out_of_order_records)
        self.assertEqual("invalid", order_report["status"])
        self.assertGreater(order_report["integrity"]["out_of_order_stages"], 0)

        gap = complete_lines(3)
        del gap[3]
        _collector, gap_report = collect(gap)
        self.assertEqual("invalid", gap_report["status"])
        self.assertGreater(gap_report["integrity"]["duration_interval_mismatches"], 0)

        regression = complete_lines(4)
        value = json.loads(regression[3])
        value["elapsed_ms"] = 2
        regression[3] = (json.dumps(value) + "\n").encode()
        _collector, regression_report = collect(regression)
        self.assertEqual("invalid", regression_report["status"])
        self.assertGreater(regression_report["integrity"]["elapsed_regressions"], 0)

    def test_real_cold_boot_prefix_matches_the_strict_stage_order(self):
        generation_value = generation(1)
        stages = [
            "app_start",
            "dns_resolved",
            "dependencies_ready",
            "profile_restored",
            *REQUIRED_STAGES,
        ]
        lines = [
            (
                json.dumps(
                    record(
                        generation_value,
                        stage,
                        offset,
                        outcome=(
                            "started"
                            if stage
                            in {"app_start", "connect_requested", "tcp_connect_started"}
                            else "succeeded"
                        ),
                    )
                )
                + "\n"
            ).encode()
            for offset, stage in enumerate(stages, 1)
        ]

        _collector, report = collect(lines)
        self.assertEqual("incomplete", report["status"])
        self.assertEqual(1, report["complete_generations"])
        self.assertEqual(0, report["integrity"]["out_of_order_stages"])

    def test_cohort_mixing_and_boot_stage_on_reconnect_are_rejected(self):
        mixed = [
            (
                json.dumps(
                    record(generation(1), "connect_requested", 1, cycle="reconnect")
                )
                + "\n"
            ).encode()
        ]
        _collector, mixed_report = collect(mixed, "cold")
        self.assertEqual("invalid", mixed_report["status"])
        self.assertEqual(1, mixed_report["rejections"]["cohort_mismatch"])

        boot = [
            (
                json.dumps(record(generation(2), "app_start", 1, cycle="reconnect"))
                + "\n"
            ).encode()
        ]
        _collector, boot_report = collect(boot, "reconnect")
        self.assertEqual(1, boot_report["rejections"]["stage_cycle_mismatch"])

    def test_malformed_unknown_secret_and_snapshot_fields_are_rejected(self):
        base = record(generation(1), "connect_requested", 1)
        cases: list[tuple[dict[str, object], str]] = []

        missing = dict(base)
        missing.pop("outcome")
        cases.append((missing, "missing_fields"))

        unknown = dict(base, raw_log="not retained")
        cases.append((unknown, "unknown_fields"))

        secret = dict(base, outcome="Bearer do-not-retain")
        cases.append((secret, "secret_value"))

        malformed_version = dict(base, snapshot_version="12")
        cases.append((malformed_version, "invalid_snapshot_version"))

        boolean_version = dict(base, snapshot_version=True)
        cases.append((boolean_version, "invalid_snapshot_version"))

        integer_version = dict(base, snapshot_version=12)
        cases.append((integer_version, "unexpected_snapshot_version"))

        for payload, rejection in cases:
            with self.subTest(rejection=rejection):
                _collector, report = collect([(json.dumps(payload) + "\n").encode()])
                self.assertEqual("invalid", report["status"])
                self.assertEqual(1, report["rejections"][rejection])
                self.assertNotIn("do-not-retain", json.dumps(report))

    def test_duplicate_keys_excess_fields_and_malformed_json_are_rejected(self):
        duplicate = (
            '{"connection_generation":"'
            + generation(1)
            + '","connection_generation":"'
            + generation(2)
            + '","cycle":"cold","stage":"connect_requested",'
            '"duration_ms":1,"elapsed_ms":1,"outcome":"started","reason_code":"none"}\n'
        ).encode()
        _collector, duplicate_report = collect([duplicate])
        self.assertEqual(1, duplicate_report["rejections"]["duplicate_json_key"])

        excessive = {f"field_{index}": index for index in range(17)}
        _collector, excessive_report = collect([(json.dumps(excessive) + "\n").encode()])
        self.assertEqual(1, excessive_report["rejections"]["excessive_fields"])

        _collector, malformed_report = collect([b'{"unterminated":\n'])
        self.assertEqual(1, malformed_report["rejections"]["invalid_json"])

        invalid_unicode = record(generation(3), "connect_requested", 1)
        invalid_unicode["cycle"] = "\ud800"
        encoded = (json.dumps(invalid_unicode) + "\n").encode("utf-8")
        _collector, unicode_report = collect([encoded])
        self.assertEqual(1, unicode_report["rejections"]["invalid_category"])

    def test_numeric_and_generation_bounds_are_rejected(self):
        payloads = []
        for duration, elapsed in [
            (-1, 1),
            (2, 1),
            (0.0001, 1),
            (2147483648, 2147483648),
            (True, 1),
        ]:
            payload = record(generation(1), "connect_requested", elapsed, duration=duration)
            payloads.append((json.dumps(payload) + "\n").encode())

        invalid_generation = record("A" * 21, "connect_requested", 1)
        payloads.append((json.dumps(invalid_generation) + "\n").encode())

        prefix = (
            '{"connection_generation":"'
            + generation(2)
            + '","cycle":"cold","stage":"connect_requested",'
            '"duration_ms":'
        )
        suffix = ',"elapsed_ms":1,"outcome":"started","reason_code":"none"}\n'
        payloads.append((prefix + "1e999999999999999999999999999" + suffix).encode())
        payloads.append((prefix + "1e-99999999999999999999999999" + suffix).encode())

        _collector, report = collect(payloads)
        self.assertEqual("invalid", report["status"])
        self.assertEqual(7, report["rejections"]["invalid_timing"])
        self.assertEqual(1, report["rejections"]["invalid_connection_generation"])

    def test_oversized_line_is_drained_without_parsing_following_content_as_records(self):
        oversized = b"{" + (b"x" * (collector_module.MAX_LINE_BYTES + 100)) + b"}\n"
        valid = complete_lines(1)[0]
        collector, report = collect([oversized, valid])
        self.assertEqual(2, collector.lines_seen)
        self.assertEqual(1, report["rejections"]["line_too_large"])
        self.assertEqual(1, report["input"]["records_accepted"])
        self.assertEqual("invalid", report["status"])

    def test_input_line_limit_marks_truncation_without_unbounded_read(self):
        original = collector_module.MAX_LINES
        collector_module.MAX_LINES = 2
        try:
            collector, report = collect([complete_lines(1)[0]] * 3)
        finally:
            collector_module.MAX_LINES = original
        self.assertTrue(collector.input_truncated)
        self.assertTrue(report["input"]["input_truncated"])
        self.assertEqual(1, report["rejections"]["input_limit_exceeded"])

    def test_generation_and_per_generation_record_bounds_fail_closed(self):
        original_generations = collector_module.MAX_GENERATIONS
        collector_module.MAX_GENERATIONS = 1
        try:
            _collector, generation_report = collect(
                [complete_lines(1)[0], complete_lines(2)[0]]
            )
        finally:
            collector_module.MAX_GENERATIONS = original_generations
        self.assertEqual(1, generation_report["rejections"]["too_many_generations"])

        original_records = collector_module.MAX_RECORDS_PER_GENERATION
        collector_module.MAX_RECORDS_PER_GENERATION = 1
        try:
            _collector, record_report = collect(complete_lines(1)[:2])
        finally:
            collector_module.MAX_RECORDS_PER_GENERATION = original_records
        self.assertEqual(1, record_report["rejections"]["too_many_records"])

    def test_cli_writes_only_a_mode_0600_aggregate(self):
        data = b"".join(
            line for index in range(1, 21) for line in complete_lines(index)
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "aggregate.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--platform",
                    "ios",
                    "--cycle",
                    "cold",
                    "--output",
                    str(output),
                ],
                input=data,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr.decode())
            self.assertEqual(b"", result.stdout)
            self.assertEqual(b"", result.stderr)
            self.assertEqual(0o600, stat.S_IMODE(output.stat().st_mode))
            report = json.loads(output.read_text())
            self.assertEqual("complete", report["status"])
            self.assertNotIn(generation(1), output.read_text())

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_output_symlink_is_rejected_without_touching_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            target.write_text("preserve")
            link = Path(directory) / "aggregate.json"
            link.symlink_to(target)

            with self.assertRaises(OSError):
                collector_module.secure_write_json(link, {"status": "incomplete"})
            self.assertEqual("preserve", target.read_text())


if __name__ == "__main__":
    unittest.main()
