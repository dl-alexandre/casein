#!/usr/bin/env python3
"""Forward strict native feed-stage log markers without retaining raw logs.

The adapter accepts only stdin, keeps only HMAC generation identities and
bounded normalized sequence state, and emits the collector's canonical
seven-field JSONL contract on stdout. Raw input lines and log prefixes are
never accumulated, echoed, or written to a file.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import re
import secrets
import sys
from collections import Counter
from decimal import Decimal, DecimalException
from typing import BinaryIO, Sequence, TextIO


# A normal dogfood invocation must not materialize collector bytecode beside
# the source. Set the interpreter switch before importing the shared contract.
sys.dont_write_bytecode = True
contract = importlib.import_module("mobile_feed_timing_collector")


ADAPTER_NAME = "casein_mobile_feed_timing_stream"
TARGET_GENERATIONS = contract.TARGET_COMPLETE_GENERATIONS
MAX_LINE_BYTES = contract.MAX_LINE_BYTES
MAX_INPUT_BYTES = contract.MAX_INPUT_BYTES
MAX_LINES = contract.MAX_LINES
MAX_GENERATIONS = contract.MAX_GENERATIONS
MAX_RECORDS = contract.MAX_LINES
MAX_IOS_PREFIX_BYTES = 768

MARKER = b"mobile_feed_stage "

REJECTION_CODES = (
    "input_limit_exceeded",
    "invalid_category",
    "invalid_encoding",
    "invalid_envelope",
    "invalid_generation",
    "invalid_marker",
    "invalid_prefix",
    "invalid_sequence",
    "invalid_timing",
    "line_limit_exceeded",
    "line_too_large",
    "missing_newline",
    "multiple_markers",
    "no_marker",
    "output_unavailable",
    "record_limit_exceeded",
    "too_many_generations",
)

DISCARD_CODES = (
    "closed_generation",
    "other_cycle",
    "stale_generation",
    "stale_pre_start",
)

_CATEGORY_TOKEN = rb"[A-Za-z0-9_-]{1,64}"
_GENERATION_TOKEN = rb"[^ ]{1,64}"
_TIMING_TOKEN = rb"[^ ]{1,64}"
_NATIVE_MARKER_RE = re.compile(
    rb"mobile_feed_stage "
    rb"connection_generation=(?P<generation>" + _GENERATION_TOKEN + rb") "
    rb"cycle=(?P<cycle>" + _CATEGORY_TOKEN + rb") "
    rb"stage=(?P<stage>" + _CATEGORY_TOKEN + rb") "
    rb"duration_ms=(?P<duration_ms>" + _TIMING_TOKEN + rb") "
    rb"elapsed_ms=(?P<elapsed_ms>" + _TIMING_TOKEN + rb") "
    rb"outcome=(?P<outcome>" + _CATEGORY_TOKEN + rb") "
    rb"reason_code=(?P<reason_code>" + _CATEGORY_TOKEN + rb")"
)
_DECIMAL_TOKEN_RE = re.compile(rb"(?:0|[1-9][0-9]*)(?:\.[0-9]{1,3})?")


class RejectedInput(Exception):
    """A fixed, non-reflective stream rejection."""

    def __init__(self, code: str):
        self.code = code if code in REJECTION_CODES else "invalid_marker"
        super().__init__(self.code)


class InvalidArguments(Exception):
    """Raised without argparse's input-reflecting error text."""


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        raise InvalidArguments


class StreamAdapter:
    """One fixed source/cycle stream with bounded HMAC-only sequence state."""

    def __init__(self, source: str, cycle: str, target: int = TARGET_GENERATIONS):
        if source not in contract.PLATFORMS:
            raise ValueError("invalid source")
        if cycle not in contract.CYCLES:
            raise ValueError("invalid cycle")
        if target != TARGET_GENERATIONS:
            raise ValueError("invalid target")

        self.source = source
        self.cycle = cycle
        self.target = target
        self._hmac_key = secrets.token_bytes(32)
        self._active_generation: str | None = None
        self._active_state: contract.GenerationState | None = None
        self._seen_generations: set[str] = set()
        self._closed_generations: set[str] = set()
        self._terminal_generations: set[str] = set()
        self._sequence_integrity: Counter[str] = Counter()
        self.rejections: Counter[str] = Counter()
        self.discards: Counter[str] = Counter()
        self.lines_seen = 0
        self.input_bytes = 0
        self.records_parsed = 0
        self.records_forwarded = 0
        self.input_truncated = False

    def run(self, stream: BinaryIO, output: TextIO, status_output: TextIO) -> int:
        while len(self._terminal_generations) < self.target:
            try:
                raw_line = stream.readline(MAX_LINE_BYTES + 1)
            except (OSError, ValueError):
                self._reject("input_limit_exceeded", truncated=True)
                break

            if not raw_line:
                if (
                    self._active_state is not None
                    and self._active_state.pending_snapshot_received is not None
                ):
                    self._reject("invalid_sequence")
                break

            self.lines_seen += 1
            self.input_bytes += len(raw_line)

            try:
                self._check_stream_bounds(raw_line)
                raw_generation, record = parse_native_line(
                    raw_line, self.source, self._hmac_key
                )
                self.records_parsed += 1
                if self.records_parsed > MAX_RECORDS:
                    raise RejectedInput("record_limit_exceeded")

                should_forward = self._accept(record)
                if should_forward:
                    self._write_record(output, raw_generation, record)
                    self.records_forwarded += 1
                del raw_generation
                del raw_line
            except RejectedInput as rejection:
                self._reject(rejection.code)
                break

        status = self._status()
        self._write_status(status_output, status)
        return {"complete": 0, "incomplete": 2, "invalid": 3}[status]

    def _check_stream_bounds(self, raw_line: bytes) -> None:
        if self.input_bytes > MAX_INPUT_BYTES:
            raise RejectedInput("input_limit_exceeded")
        if self.lines_seen > MAX_LINES:
            raise RejectedInput("line_limit_exceeded")
        if len(raw_line) > MAX_LINE_BYTES:
            raise RejectedInput("line_too_large")
        if not raw_line.endswith(b"\n"):
            raise RejectedInput("missing_newline")

    def _accept(self, record: contract.NormalizedRecord) -> bool:
        if record.cycle != self.cycle:
            if record.generation_surrogate == self._active_generation:
                raise RejectedInput("invalid_sequence")
            self.discards["other_cycle"] += 1
            return False

        if record.generation_surrogate in self._closed_generations:
            self.discards["closed_generation"] += 1
            return False

        if self._active_generation is None:
            if not self._fresh_start(record.stage):
                self.discards["stale_pre_start"] += 1
                return False
            self._start_generation(record.generation_surrogate)
        elif record.generation_surrogate != self._active_generation:
            if self._fresh_start(record.stage):
                raise RejectedInput("invalid_sequence")
            self.discards["stale_generation"] += 1
            return False

        state = self._active_state
        if state is None:
            raise RejectedInput("invalid_sequence")

        try:
            accepted = state.add(record, self._sequence_integrity)
        except contract.RejectedRecord as rejection:
            if rejection.code == "too_many_records":
                raise RejectedInput("record_limit_exceeded") from None
            raise RejectedInput("invalid_sequence") from None

        # A successfully appended snapshot_received is intentionally pending
        # until its immediately following snapshot_accepted partner arrives.
        # Only the state's permanent invalid bit is a sequence failure here.
        if not accepted or state.invalid:
            if record.stage != "snapshot_rejected":
                raise RejectedInput("invalid_sequence")

        if record.stage == "first_cards_render_ready":
            if not state.complete():
                raise RejectedInput("invalid_sequence")
            self._terminal_generations.add(record.generation_surrogate)
            self._close_active_generation()
        elif record.stage in {"disconnected", "no_configuration", "snapshot_rejected"}:
            self._close_active_generation()

        return True

    def _fresh_start(self, stage: str) -> bool:
        if self.cycle == "cold":
            return stage in {"app_start", "connect_requested"}
        if self.cycle == "reconnect":
            return stage == "connect_requested"
        return stage == "dns_resolved"

    def _start_generation(self, generation_surrogate: str) -> None:
        if generation_surrogate not in self._seen_generations:
            if len(self._seen_generations) >= MAX_GENERATIONS:
                raise RejectedInput("too_many_generations")
            self._seen_generations.add(generation_surrogate)

        self._active_generation = generation_surrogate
        self._active_state = contract.GenerationState(cycle=self.cycle)

    def _close_active_generation(self) -> None:
        if self._active_generation is not None:
            self._closed_generations.add(self._active_generation)
        self._active_generation = None
        self._active_state = None

    def _write_record(
        self,
        output: TextIO,
        raw_generation: str,
        record: contract.NormalizedRecord,
    ) -> None:
        payload = {
            "connection_generation": raw_generation,
            "cycle": record.cycle,
            "stage": record.stage,
            "duration_ms": contract._json_number(record.duration_ms),
            "elapsed_ms": contract._json_number(record.elapsed_ms),
            "outcome": record.outcome,
            "reason_code": record.reason_code,
        }
        try:
            output.write(json.dumps(payload, separators=(",", ":")) + "\n")
            output.flush()
        except (BrokenPipeError, OSError, ValueError):
            _suppress_failed_output(output)
            raise RejectedInput("output_unavailable") from None

    def _reject(self, code: str, *, truncated: bool = False) -> None:
        safe_code = code if code in REJECTION_CODES else "invalid_marker"
        self.rejections[safe_code] += 1
        self.input_truncated = self.input_truncated or truncated or safe_code in {
            "input_limit_exceeded",
            "line_limit_exceeded",
            "line_too_large",
            "record_limit_exceeded",
        }

    def _status(self) -> str:
        if self.rejections:
            return "invalid"
        if len(self._terminal_generations) == self.target:
            return "complete"
        return "incomplete"

    def _write_status(self, output: TextIO, status: str) -> None:
        payload = {
            "adapter": ADAPTER_NAME,
            "status": status,
            "source": self.source,
            "cycle": self.cycle,
            "target_generations": self.target,
            "terminal_generations": len(self._terminal_generations),
            "generations_started": len(self._seen_generations),
            "lines_seen": self.lines_seen,
            "records_parsed": self.records_parsed,
            "records_forwarded": self.records_forwarded,
            "input_truncated": self.input_truncated,
            "rejections": {code: self.rejections[code] for code in REJECTION_CODES},
            "discards": {code: self.discards[code] for code in DISCARD_CODES},
        }
        try:
            output.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
            output.flush()
        except (BrokenPipeError, OSError, ValueError):
            return


def parse_native_line(
    raw_line: bytes, source: str, hmac_key: bytes
) -> tuple[str, contract.NormalizedRecord]:
    line = raw_line[:-1]
    marker_count = line.count(MARKER)
    if marker_count == 0:
        raise RejectedInput("no_marker")
    if marker_count != 1:
        raise RejectedInput("multiple_markers")

    prefix, marker = line.split(MARKER, 1)
    if source == "android" and prefix:
        raise RejectedInput("invalid_prefix")
    if source == "ios":
        _validate_ios_prefix(prefix)

    marker = MARKER + marker
    match = _NATIVE_MARKER_RE.fullmatch(marker)
    if match is None:
        raise RejectedInput("invalid_marker")

    groups = match.groupdict()
    try:
        raw_generation = groups["generation"].decode("ascii", "strict")
        generation_surrogate = contract._generation_surrogate(raw_generation, hmac_key)
    except (UnicodeDecodeError, contract.RejectedRecord):
        raise RejectedInput("invalid_generation") from None

    cycle = _category(groups["cycle"], contract.CYCLES)
    stage = _category(groups["stage"], contract.STAGES)
    outcome = _category(groups["outcome"], contract.OUTCOMES)
    reason_code = _category(groups["reason_code"], contract.REASON_CODES)
    duration_ms = _timing(groups["duration_ms"])
    elapsed_ms = _timing(groups["elapsed_ms"])
    if duration_ms > elapsed_ms:
        raise RejectedInput("invalid_timing")

    record = contract.NormalizedRecord(
        generation_surrogate=generation_surrogate,
        cycle=cycle,
        stage=stage,
        duration_ms=duration_ms,
        elapsed_ms=elapsed_ms,
        outcome=outcome,
        reason_code=reason_code,
    )

    if not contract._valid_stage_envelope(record):
        raise RejectedInput("invalid_envelope")
    if cycle == "reconnect" and stage in contract.BOOT_STAGES:
        raise RejectedInput("invalid_sequence")
    if cycle == "origin_switch" and stage in contract.BOOT_STAGES and stage != "dns_resolved":
        raise RejectedInput("invalid_sequence")

    return raw_generation, record


def _validate_ios_prefix(prefix: bytes) -> None:
    if len(prefix) > MAX_IOS_PREFIX_BYTES:
        raise RejectedInput("invalid_prefix")
    if any(byte < 0x20 and byte != 0x09 for byte in prefix):
        raise RejectedInput("invalid_prefix")
    try:
        prefix.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise RejectedInput("invalid_encoding") from None


def _category(raw_value: bytes, allowed: Sequence[str]) -> str:
    try:
        value = raw_value.decode("ascii", "strict")
    except UnicodeDecodeError:
        raise RejectedInput("invalid_category") from None
    if value not in allowed:
        raise RejectedInput("invalid_category")
    return value


def _timing(raw_value: bytes) -> Decimal:
    if _DECIMAL_TOKEN_RE.fullmatch(raw_value) is None:
        raise RejectedInput("invalid_timing")
    try:
        value = Decimal(raw_value.decode("ascii", "strict"))
        return contract._timing(value)
    except (UnicodeDecodeError, DecimalException, contract.RejectedRecord):
        raise RejectedInput("invalid_timing") from None


def _suppress_failed_output(output: TextIO) -> None:
    """Redirect a poisoned process stdout descriptor before interpreter exit."""

    descriptor = -1
    try:
        output_descriptor = output.fileno()
        flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(os.devnull, flags)
        if descriptor == output_descriptor:
            descriptor = -1
        else:
            os.dup2(descriptor, output_descriptor)
    except (AttributeError, OSError, ValueError):
        return
    finally:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(add_help=False)
    parser.add_argument("--source", required=True, choices=contract.PLATFORMS)
    parser.add_argument("--cycle", required=True, choices=contract.CYCLES)
    parser.add_argument(
        "--target",
        type=int,
        choices=(TARGET_GENERATIONS,),
        default=TARGET_GENERATIONS,
    )
    return parser


def _fixed_cli_status(output: TextIO, status: str) -> None:
    payload = {"adapter": ADAPTER_NAME, "status": status}
    try:
        output.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
        output.flush()
    except (BrokenPipeError, OSError, ValueError):
        return


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
    except InvalidArguments:
        _fixed_cli_status(sys.stderr, "invalid_arguments")
        return 64

    adapter = StreamAdapter(args.source, args.cycle, args.target)
    return adapter.run(sys.stdin.buffer, sys.stdout, sys.stderr)


if __name__ == "__main__":
    try:
        exit_code = main()
    except KeyboardInterrupt:
        _fixed_cli_status(sys.stderr, "interrupted")
        exit_code = 130
    except Exception:
        _fixed_cli_status(sys.stderr, "internal_error")
        exit_code = 70
    raise SystemExit(exit_code)
