#!/usr/bin/env python3
"""Aggregate Casein's fixed native feed-timing JSONL without retaining identity.

Input is accepted only from stdin.  Each connection generation is replaced by
an HMAC surrogate before it is placed in collector state; neither raw records
nor generation surrogates are written to the aggregate output.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import stat
import sys
from collections import Counter
from dataclasses import dataclass, field
from decimal import Decimal, DecimalException
from pathlib import Path
from typing import BinaryIO, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
TARGET_COMPLETE_GENERATIONS = 20
MAX_LINE_BYTES = 1_024
MAX_INPUT_BYTES = 10 * 1_024 * 1_024
MAX_LINES = 10_000
MAX_JSON_FIELDS = 16
MAX_GENERATIONS = 256
MAX_RECORDS_PER_GENERATION = 64
MAX_TIMING_MS = Decimal("2147483647")
TIMING_TOLERANCE_MS = Decimal("0.002")

INPUT_FIELDS = frozenset(
    {
        "connection_generation",
        "cycle",
        "stage",
        "duration_ms",
        "elapsed_ms",
        "outcome",
        "reason_code",
    }
)
PLATFORMS = ("ios", "android")
CYCLES = ("cold", "reconnect", "origin_switch")
OUTCOMES = ("started", "succeeded", "failed", "skipped")
REASON_CODES = (
    "none",
    "no_configuration",
    "transport_disconnected",
    "dns_resolved",
    "dns_ip_literal",
    "dns_invalid_url",
    "dns_resolution_failed",
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
)
STAGES = (
    "app_start",
    "dns_resolved",
    "dependencies_ready",
    "profile_restored",
    "client_started",
    "database_ready",
    "root_started",
    "connect_requested",
    "tcp_connect_started",
    "tcp_connected",
    "transport_connected",
    "mobile_join_replied",
    "snapshot_received",
    "snapshot_accepted",
    "snapshot_rejected",
    "first_cards_render_ready",
    "no_configuration",
    "disconnected",
)
REQUIRED_STAGES = (
    "connect_requested",
    "tcp_connect_started",
    "tcp_connected",
    "transport_connected",
    "mobile_join_replied",
    "snapshot_received",
    "snapshot_accepted",
    "first_cards_render_ready",
)
STAGE_RANK = {stage: index for index, stage in enumerate(STAGES)}
BOOT_STAGES = frozenset(STAGES[:7])
CYCLE_START_STAGES = {
    "cold": frozenset({"app_start", "connect_requested"}),
    "reconnect": frozenset({"connect_requested"}),
    "origin_switch": frozenset({"dns_resolved"}),
}
REPEATABLE_SNAPSHOT_STAGES = frozenset({"snapshot_received", "snapshot_accepted"})
SNAPSHOT_VALIDATION_REASON_CODES = frozenset(
    {
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
)
STAGE_ENVELOPES = {
    "app_start": frozenset({("started", "none")}),
    "connect_requested": frozenset({("started", "none")}),
    "tcp_connect_started": frozenset({("started", "none")}),
    "dns_resolved": frozenset(
        {
            ("succeeded", "dns_resolved"),
            ("skipped", "dns_ip_literal"),
            ("skipped", "no_configuration"),
            ("failed", "dns_invalid_url"),
            ("failed", "dns_resolution_failed"),
        }
    ),
    "no_configuration": frozenset({("skipped", "no_configuration")}),
    "disconnected": frozenset({("failed", "transport_disconnected")}),
    "snapshot_rejected": frozenset(
        ("failed", reason_code) for reason_code in SNAPSHOT_VALIDATION_REASON_CODES
    ),
    **{
        stage: frozenset({("succeeded", "none")})
        for stage in STAGES
        if stage
        not in {
            "app_start",
            "connect_requested",
            "tcp_connect_started",
            "dns_resolved",
            "no_configuration",
            "disconnected",
            "snapshot_rejected",
        }
    },
}

REJECTION_CODES = frozenset(
    {
        "blank_line",
        "cohort_mismatch",
        "duplicate_json_key",
        "excessive_fields",
        "input_limit_exceeded",
        "invalid_category",
        "invalid_connection_generation",
        "invalid_json",
        "invalid_snapshot_version",
        "invalid_timing",
        "line_too_large",
        "missing_fields",
        "secret_value",
        "stage_cycle_mismatch",
        "too_many_generations",
        "too_many_records",
        "unknown_fields",
        "unexpected_snapshot_version",
    }
)

_GENERATION_RE = re.compile(r"^[A-Za-z0-9_-]{22}$")
_SECRET_RE = re.compile(
    r"(?i)(?:bearer\s+|(?:api[_-]?key|access[_-]?token|password|passwd|secret|"
    r"credential)\s*[:=]|-----BEGIN\s+[^-]*PRIVATE\s+KEY-----)"
)
_JWT_RE = re.compile(r"^[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}$")


class RejectedRecord(Exception):
    """A bounded rejection whose code is safe to aggregate."""

    def __init__(self, code: str):
        if code not in REJECTION_CODES:
            code = "invalid_json"
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class NormalizedRecord:
    """The seven-field record after raw generation replacement."""

    generation_surrogate: str
    cycle: str
    stage: str
    duration_ms: Decimal
    elapsed_ms: Decimal
    outcome: str
    reason_code: str


@dataclass(slots=True)
class GenerationState:
    cycle: str
    records: list[NormalizedRecord] = field(default_factory=list)
    stages: set[str] = field(default_factory=set)
    last_rank: int = -1
    last_elapsed_ms: Decimal | None = None
    invalid: bool = False
    required_successes: set[str] = field(default_factory=set)
    markers_seen: int = 0
    pending_snapshot_received: NormalizedRecord | None = None
    final_snapshot_pair: tuple[NormalizedRecord, NormalizedRecord] | None = None
    terminal_stage: str | None = None

    def add(self, record: NormalizedRecord, integrity: Counter[str]) -> bool:
        self.markers_seen += 1
        if self.markers_seen > MAX_RECORDS_PER_GENERATION:
            self.invalid = True
            raise RejectedRecord("too_many_records")

        if self.invalid:
            return False

        if self.terminal_stage == "first_cards_render_ready":
            integrity["post_terminal_markers"] += 1
            self.invalid = True
            return False

        if self.markers_seen == 1 and record.stage not in CYCLE_START_STAGES[self.cycle]:
            integrity["invalid_start_stages"] += 1
            self.invalid = True
            return False

        if (
            self.cycle == "origin_switch"
            and len(self.records) == 1
            and self.records[0].stage == "dns_resolved"
            and record.stage != "connect_requested"
        ):
            integrity["invalid_start_stages"] += 1
            self.invalid = True
            return False

        if not _valid_stage_envelope(record):
            integrity["invalid_stage_envelopes"] += 1
            if (
                self.pending_snapshot_received is not None
                and record.stage in REPEATABLE_SNAPSHOT_STAGES
            ):
                integrity["snapshot_sequence_errors"] += 1
                self.pending_snapshot_received = None
            self.invalid = True
            return False

        if self.pending_snapshot_received is None and record.stage in self.stages:
            integrity["duplicate_stages"] += 1
            self.invalid = True
            return False

        if not self._valid_timing(record, integrity):
            return False

        if record.stage == "snapshot_rejected":
            self._append(record)
            self.pending_snapshot_received = None
            integrity["snapshot_rejections"] += 1
            integrity["snapshot_sequence_errors"] += 1
            self.invalid = True
            return True

        if record.stage == "snapshot_received":
            return self._add_snapshot_received(record, integrity)

        if record.stage == "snapshot_accepted":
            return self._add_snapshot_accepted(record, integrity)

        if self.pending_snapshot_received is not None:
            integrity["snapshot_sequence_errors"] += 1
            self.pending_snapshot_received = None
            self.invalid = True
            return False

        if record.stage == "first_cards_render_ready" and (
            self.final_snapshot_pair is None
            or not self.records
            or self.records[-1].stage != "snapshot_accepted"
        ):
            integrity["snapshot_sequence_errors"] += 1
            self.invalid = True
            return False

        rank = STAGE_RANK[record.stage]
        if rank < self.last_rank:
            integrity["out_of_order_stages"] += 1
            self.invalid = True
            return False

        self._append(record)
        if record.stage == "first_cards_render_ready":
            self.terminal_stage = record.stage
        return True

    def _add_snapshot_received(
        self, record: NormalizedRecord, integrity: Counter[str]
    ) -> bool:
        preceding_stage = self.records[-1].stage if self.records else None
        starts_first_pair = (
            self.final_snapshot_pair is None
            and self.pending_snapshot_received is None
            and preceding_stage == "mobile_join_replied"
            and "mobile_join_replied" in self.required_successes
        )
        starts_next_pair = (
            self.final_snapshot_pair is not None
            and self.pending_snapshot_received is None
            and preceding_stage == "snapshot_accepted"
        )

        if record.outcome != "succeeded" or not (starts_first_pair or starts_next_pair):
            integrity["snapshot_sequence_errors"] += 1
            self.pending_snapshot_received = None
            self.invalid = True
            return False

        self._append(record)
        self.pending_snapshot_received = record
        return True

    def _add_snapshot_accepted(
        self, record: NormalizedRecord, integrity: Counter[str]
    ) -> bool:
        received = self.pending_snapshot_received
        if (
            record.outcome != "succeeded"
            or received is None
            or not self.records
            or self.records[-1] is not received
        ):
            integrity["snapshot_sequence_errors"] += 1
            self.pending_snapshot_received = None
            self.invalid = True
            return False

        self._append(record)
        self.final_snapshot_pair = (received, record)
        self.pending_snapshot_received = None
        return True

    def _valid_timing(
        self, record: NormalizedRecord, integrity: Counter[str]
    ) -> bool:
        if self.last_elapsed_ms is None:
            return True
        if record.elapsed_ms < self.last_elapsed_ms:
            integrity["elapsed_regressions"] += 1
            self.invalid = True
            return False

        observed_interval = record.elapsed_ms - self.last_elapsed_ms
        if abs(observed_interval - record.duration_ms) > TIMING_TOLERANCE_MS:
            integrity["duration_interval_mismatches"] += 1
            self.invalid = True
            return False
        return True

    def _append(self, record: NormalizedRecord) -> None:
        self.records.append(record)
        if record.stage not in REPEATABLE_SNAPSHOT_STAGES:
            self.stages.add(record.stage)
        self.last_rank = STAGE_RANK[record.stage]
        self.last_elapsed_ms = record.elapsed_ms
        if _successful_required_stage(record):
            self.required_successes.add(record.stage)

    def invalid_for_report(self) -> bool:
        return self.invalid or self.pending_snapshot_received is not None

    def complete(self) -> bool:
        return (
            not self.invalid_for_report()
            and self.terminal_stage == "first_cards_render_ready"
            and self.final_snapshot_pair is not None
            and set(REQUIRED_STAGES).issubset(self.required_successes)
        )


class Collector:
    def __init__(self, platform: str, cycle: str) -> None:
        if platform not in PLATFORMS or cycle not in CYCLES:
            raise ValueError("invalid fixed cohort")

        self.platform = platform
        self.cycle = cycle
        self._hmac_key = secrets.token_bytes(32)
        self._generations: dict[str, GenerationState] = {}
        self.rejections: Counter[str] = Counter()
        self.integrity: Counter[str] = Counter()
        self.failure_reasons: Counter[str] = Counter()
        self.lines_seen = 0
        self.records_accepted = 0
        self.input_bytes = 0
        self.input_truncated = False

    def reject(self, code: str) -> None:
        if code not in REJECTION_CODES:
            code = "invalid_json"
        self.rejections[code] += 1

    def add_line(self, raw_line: bytes) -> None:
        self.lines_seen += 1
        self.input_bytes += len(raw_line)

        try:
            record = parse_record(raw_line, self._hmac_key)
            if record.cycle != self.cycle:
                raise RejectedRecord("cohort_mismatch")
            if record.cycle == "reconnect" and record.stage in BOOT_STAGES:
                raise RejectedRecord("stage_cycle_mismatch")
            if (
                record.cycle == "origin_switch"
                and record.stage in BOOT_STAGES
                and record.stage != "dns_resolved"
            ):
                raise RejectedRecord("stage_cycle_mismatch")

            state = self._generations.get(record.generation_surrogate)
            if state is None:
                if len(self._generations) >= MAX_GENERATIONS:
                    raise RejectedRecord("too_many_generations")
                state = GenerationState(cycle=record.cycle)
                self._generations[record.generation_surrogate] = state
            elif state.cycle != record.cycle:
                raise RejectedRecord("cohort_mismatch")

            if state.add(record, self.integrity):
                self.records_accepted += 1
                if record.outcome == "failed":
                    self.failure_reasons[record.reason_code] += 1
        except RejectedRecord as rejection:
            self.reject(rejection.code)

    def report(self) -> dict[str, object]:
        complete = [state for state in self._generations.values() if state.complete()]
        invalid_generations = sum(
            state.invalid_for_report() for state in self._generations.values()
        )
        partial_generations = len(self._generations) - len(complete) - invalid_generations
        excess = max(0, len(complete) - TARGET_COMPLETE_GENERATIONS)
        lone_snapshot_pairs = sum(
            state.pending_snapshot_received is not None
            for state in self._generations.values()
        )

        integrity = {
            "duplicate_stages": self.integrity["duplicate_stages"],
            "out_of_order_stages": self.integrity["out_of_order_stages"],
            "elapsed_regressions": self.integrity["elapsed_regressions"],
            "duration_interval_mismatches": self.integrity[
                "duration_interval_mismatches"
            ],
            "snapshot_rejections": self.integrity["snapshot_rejections"],
            "snapshot_sequence_errors": self.integrity["snapshot_sequence_errors"]
            + lone_snapshot_pairs,
            "invalid_start_stages": self.integrity["invalid_start_stages"],
            "post_terminal_markers": self.integrity["post_terminal_markers"],
            "invalid_stage_envelopes": self.integrity["invalid_stage_envelopes"],
            "invalid_generations": invalid_generations,
            "partial_generations": partial_generations,
            "excess_complete_generations": excess,
        }

        has_invalidity = bool(self.rejections) or invalid_generations > 0 or excess > 0
        if has_invalidity:
            status = "invalid"
        elif len(complete) == TARGET_COMPLETE_GENERATIONS:
            status = "complete"
        else:
            status = "incomplete"

        return {
            "schema_version": SCHEMA_VERSION,
            "collector": "casein_mobile_feed_timing",
            "platform": self.platform,
            "cycle": self.cycle,
            "status": status,
            "target_complete_generations": TARGET_COMPLETE_GENERATIONS,
            "complete_generations": len(complete),
            "observed_generations": len(self._generations),
            "input": {
                "lines_seen": self.lines_seen,
                "records_accepted": self.records_accepted,
                "records_rejected": sum(self.rejections.values()),
                "input_truncated": self.input_truncated,
            },
            "rejections": _fixed_counts(self.rejections, REJECTION_CODES),
            "integrity": integrity,
            "failed_outcomes_by_reason": _fixed_counts(
                self.failure_reasons, REASON_CODES
            ),
            "stage_timings": _stage_summaries(complete),
            "first_cards_elapsed_ms": _summary(
                record.elapsed_ms
                for state in complete
                for record in state.records
                if record.stage == "first_cards_render_ready"
            ),
        }


def parse_record(raw_line: bytes, hmac_key: bytes) -> NormalizedRecord:
    if not raw_line.strip():
        raise RejectedRecord("blank_line")
    if len(raw_line) > MAX_LINE_BYTES:
        raise RejectedRecord("line_too_large")

    try:
        text = raw_line.decode("utf-8", "strict")
        parsed = json.loads(
            text,
            parse_float=Decimal,
            parse_int=int,
            parse_constant=lambda _value: _reject("invalid_timing"),
            object_pairs_hook=_bounded_object,
        )
    except RejectedRecord:
        raise
    except DecimalException:
        raise RejectedRecord("invalid_timing") from None
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError):
        raise RejectedRecord("invalid_json") from None

    if not isinstance(parsed, dict):
        raise RejectedRecord("invalid_json")

    keys = set(parsed)
    if "snapshot_version" in keys:
        version = parsed["snapshot_version"]
        if isinstance(version, bool) or not isinstance(version, int) or version < 0:
            raise RejectedRecord("invalid_snapshot_version")
        raise RejectedRecord("unexpected_snapshot_version")
    if not INPUT_FIELDS.issubset(keys):
        raise RejectedRecord("missing_fields")
    if keys != INPUT_FIELDS:
        raise RejectedRecord("unknown_fields")

    raw_generation = parsed.pop("connection_generation")
    generation_surrogate = _generation_surrogate(raw_generation, hmac_key)
    del raw_generation

    for value in parsed.values():
        if isinstance(value, str) and _looks_secret(value):
            raise RejectedRecord("secret_value")

    cycle = _category(parsed["cycle"], CYCLES)
    stage = _category(parsed["stage"], STAGES)
    outcome = _category(parsed["outcome"], OUTCOMES)
    reason_code = _category(parsed["reason_code"], REASON_CODES)
    duration_ms = _timing(parsed["duration_ms"])
    elapsed_ms = _timing(parsed["elapsed_ms"])
    if duration_ms > elapsed_ms:
        raise RejectedRecord("invalid_timing")

    return NormalizedRecord(
        generation_surrogate=generation_surrogate,
        cycle=cycle,
        stage=stage,
        duration_ms=duration_ms,
        elapsed_ms=elapsed_ms,
        outcome=outcome,
        reason_code=reason_code,
    )


def collect_stream(stream: BinaryIO, collector: Collector) -> None:
    total_bytes = 0
    nonempty_reads = 0

    while True:
        chunk = stream.readline(MAX_LINE_BYTES + 1)
        if not chunk:
            return

        total_bytes += len(chunk)
        if total_bytes > MAX_INPUT_BYTES:
            collector.input_truncated = True
            collector.reject("input_limit_exceeded")
            return

        nonempty_reads += 1
        if nonempty_reads > MAX_LINES:
            collector.input_truncated = True
            collector.reject("input_limit_exceeded")
            return

        if len(chunk) > MAX_LINE_BYTES:
            collector.lines_seen += 1
            collector.input_bytes += len(chunk)
            collector.reject("line_too_large")
            while chunk and not chunk.endswith(b"\n"):
                chunk = stream.readline(MAX_LINE_BYTES + 1)
                total_bytes += len(chunk)
                if total_bytes > MAX_INPUT_BYTES:
                    collector.input_truncated = True
                    collector.reject("input_limit_exceeded")
                    return
            continue

        collector.add_line(chunk)


def secure_write_json(path: Path, payload: Mapping[str, object]) -> None:
    parent = path.parent
    if not parent.is_dir():
        raise OSError("output directory unavailable")

    try:
        target = path.lstat()
    except FileNotFoundError:
        target = None
    if target is not None and (not stat.S_ISREG(target.st_mode) or target.st_nlink != 1):
        raise OSError("output target is not a regular file")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    temporary = parent / f".{path.name}.tmp-{os.getpid()}-{secrets.token_hex(8)}"
    descriptor = os.open(temporary, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=False) as output:
            json.dump(payload, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
        os.chmod(path, 0o600, follow_symlinks=False)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _bounded_object(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
    if len(pairs) > MAX_JSON_FIELDS:
        raise RejectedRecord("excessive_fields")
    keys = [key for key, _value in pairs]
    if len(set(keys)) != len(keys):
        raise RejectedRecord("duplicate_json_key")
    return dict(pairs)


def _reject(code: str):
    raise RejectedRecord(code)


def _generation_surrogate(value: object, hmac_key: bytes) -> str:
    if not isinstance(value, str) or not _GENERATION_RE.fullmatch(value):
        raise RejectedRecord("invalid_connection_generation")
    try:
        decoded = base64.urlsafe_b64decode(value + "==")
    except (ValueError, base64.binascii.Error):
        raise RejectedRecord("invalid_connection_generation") from None
    if len(decoded) != 16 or base64.urlsafe_b64encode(decoded).rstrip(b"=").decode() != value:
        raise RejectedRecord("invalid_connection_generation")
    return hmac.new(hmac_key, value.encode("ascii"), hashlib.sha256).hexdigest()[:32]


def _looks_secret(value: str) -> bool:
    return bool(_SECRET_RE.search(value) or _JWT_RE.fullmatch(value))


def _category(value: object, allowed: Sequence[str]) -> str:
    if not isinstance(value, str):
        raise RejectedRecord("invalid_category")
    try:
        encoded = value.encode("utf-8", "strict")
    except UnicodeEncodeError:
        raise RejectedRecord("invalid_category") from None
    if len(encoded) > 64 or value not in allowed:
        raise RejectedRecord("invalid_category")
    return value


def _timing(value: object) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, Decimal)):
        raise RejectedRecord("invalid_timing")
    try:
        decimal = Decimal(value)
        valid_range = decimal.is_finite() and 0 <= decimal <= MAX_TIMING_MS
        precision = decimal.as_tuple().exponent
    except (DecimalException, OverflowError, ValueError):
        raise RejectedRecord("invalid_timing") from None
    if not valid_range:
        raise RejectedRecord("invalid_timing")
    if precision < -3:
        raise RejectedRecord("invalid_timing")
    return decimal


def _successful_required_stage(record: NormalizedRecord) -> bool:
    if record.stage not in REQUIRED_STAGES:
        return False
    if record.stage in {"connect_requested", "tcp_connect_started"}:
        return record.outcome == "started"
    return record.outcome == "succeeded"


def _valid_stage_envelope(record: NormalizedRecord) -> bool:
    return (record.outcome, record.reason_code) in STAGE_ENVELOPES[record.stage]


def _fixed_counts(counts: Counter[str], allowed: Iterable[str]) -> dict[str, int]:
    return {key: counts[key] for key in sorted(allowed) if counts[key] > 0}


def _stage_summaries(states: Sequence[GenerationState]) -> dict[str, object]:
    by_stage: dict[str, list[NormalizedRecord]] = {stage: [] for stage in STAGES}
    for state in states:
        for record in state.records:
            if record.stage not in REPEATABLE_SNAPSHOT_STAGES:
                by_stage[record.stage].append(record)
        if state.final_snapshot_pair is not None:
            received, accepted = state.final_snapshot_pair
            by_stage[received.stage].append(received)
            by_stage[accepted.stage].append(accepted)

    return {
        stage: {
            "sample_count": len(records),
            "duration_ms": _summary(record.duration_ms for record in records),
            "elapsed_ms": _summary(record.elapsed_ms for record in records),
        }
        for stage, records in by_stage.items()
        if records
    }


def _summary(values: Iterable[Decimal]) -> dict[str, object] | None:
    ordered = sorted(values)
    if not ordered:
        return None
    return {
        "min": _json_number(ordered[0]),
        "p50": _json_number(_nearest_rank(ordered, Decimal("0.50"))),
        "p95": (
            _json_number(_nearest_rank(ordered, Decimal("0.95")))
            if len(ordered) >= 10
            else None
        ),
        "max": _json_number(ordered[-1]),
    }


def _nearest_rank(values: Sequence[Decimal], percentile: Decimal) -> Decimal:
    rank = max(1, math.ceil(len(values) * float(percentile)))
    return values[rank - 1]


def _json_number(value: Decimal) -> int | float:
    if value == value.to_integral_value():
        return int(value)
    return float(value)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Aggregate a single fixed Casein mobile timing cohort from stdin"
    )
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    parser.add_argument("--cycle", required=True, choices=CYCLES)
    parser.add_argument("--output", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    collector = Collector(args.platform, args.cycle)
    collect_stream(sys.stdin.buffer, collector)
    report = collector.report()
    try:
        secure_write_json(args.output, report)
    except OSError:
        print("mobile feed timing aggregate could not be written", file=sys.stderr)
        return 4

    return {"complete": 0, "incomplete": 2, "invalid": 3}[str(report["status"])]


if __name__ == "__main__":
    raise SystemExit(main())
