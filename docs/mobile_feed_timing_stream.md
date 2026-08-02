# Privacy-safe native mobile feed timing stream

`scripts/lib/mobile_feed_timing_stream.py` is the only supported bridge from a
live native log stream to Casein's aggregate mobile feed timing collector. It
accepts raw text only on standard input, recognizes the public
`mobile_feed_stage ` marker, and writes only canonical seven-field JSONL on
standard output. It never writes or echoes an input line, native log prefix,
generation surrogate, application text, or credential.
Normal invocation also disables Python bytecode before importing the shared
collector contract, so the live bridge does not leave `__pycache__` or `.pyc`
artifacts in the checkout.

Use one process for exactly one platform and cycle. The target defaults to and
may only be 20 clean terminal generations:

```bash
set -o pipefail
native_log_producer_with_marker_only_filter |
  python3 scripts/lib/mobile_feed_timing_stream.py \
    --source ios \
    --cycle cold |
  python3 scripts/lib/mobile_feed_timing_collector.py \
    --platform ios \
    --cycle cold \
    --output /tmp/casein-ios-cold-aggregate.json
```

The producer in this example is a placeholder. The only supported native
producer is the bounded, app-scoped source supervisor documented in
[`mobile_feed_timing_source_supervisor.md`](mobile_feed_timing_source_supervisor.md).
It is a building block for the in-memory cohort coordinator, not a standalone
physical-cohort runner. Do not use a raw capture file, shell variable,
clipboard, `tee`, or a general application-log export. The adapter itself has
no input-file option. Its output must flow directly to the aggregate collector.

Input framing is intentionally narrow:

- Android requires the exact `adb logcat -v raw` message beginning with the
  marker at byte zero. A logcat tag, timestamp, priority, or other prefix is
  rejected.
- iOS permits one bounded, valid UTF-8 unified-log prefix before the marker.
  The prefix is inspected only for framing and is never retained or emitted.
- Every newline-terminated input line must contain exactly one literal marker.
  Missing markers, duplicate markers, trailing fields, suffix text, malformed
  UTF-8, oversized lines, and unterminated final lines fail closed.
- Marker fields must appear in this exact order:
  `connection_generation cycle stage duration_ms elapsed_ms outcome reason_code`.
  Categories, stage envelopes, canonical generation encoding, and timing bounds
  are imported directly from the aggregate collector contract.

The adapter waits for a natural boundary instead of forwarding stale log-buffer
history:

- cold: `app_start` or `connect_requested`;
- reconnect: `connect_requested`; and
- origin switch: `dns_resolved`, immediately followed by
  `connect_requested`.

Valid markers from another cycle and configured-cycle markers before the fresh
boundary are counted as fixed discard categories. After a generation starts,
the full ordered marker sequence is validated. Its raw generation is HMACed
before any sequence state is retained. Only that active generation is
forwarded, through its first `first_cards_render_ready`; later markers for the
closed generation are not forwarded. A malformed sequence terminates the
adapter as invalid rather than attempting recovery or silently forming a
cohort.

Standard error contains one fixed-schema final status object with aggregate
counts only. It never contains input values or identifiers. Exit code `0`
means exactly 20 terminal generations were forwarded, `2` means the clean
stream ended before the target, `3` means input failed validation, and `64`
means the fixed CLI arguments were invalid. Preserve both pipeline exit status
and the collector's aggregate status; do not treat an incomplete adapter run as
a performance cohort.
