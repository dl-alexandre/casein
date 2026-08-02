# Privacy-safe mobile feed timing collector

`scripts/lib/mobile_feed_timing_collector.py` consumes one native platform and
cycle cohort as bounded JSONL from standard input. It accepts only the fixed
seven-field native timing contract and writes only aggregate timing and
integrity counts. It never reads a device, a terminal pane, a file of raw logs,
or a credential-bearing application log.

```bash
python3 scripts/lib/mobile_feed_timing_collector.py \
  --platform ios \
  --cycle cold \
  --output /tmp/casein-ios-cold-aggregate.json \
  < /dev/stdin
```

The caller is responsible for reconstructing only the public, fixed-field
native marker as JSONL and piping it directly to stdin. Do not create an
intermediate raw capture file. The collector:

- requires exactly the seven fields in
  `scripts/schemas/mobile_feed_timing_record.schema.json`;
- HMAC-replaces `connection_generation` with a random per-process surrogate as
  soon as the record is parsed;
- keeps that surrogate only in memory for grouping and never writes it;
- rejects unknown fields, duplicate JSON keys, secret-looking values, malformed
  categories, non-finite or over-precise timings, and input outside fixed size
  bounds;
- validates the fixed native stage/outcome/reason envelope before a marker can
  advance generation timing or stage state. A mismatch increments
  `invalid_stage_envelopes`, hard-invalidates that generation, and is never
  counted as an accepted failure outcome;
- rejects `snapshot_version` as an eighth field. Snapshot-version validity is
  enforced in the native receive contract, while this collector deliberately
  remains the seven-field public timing surface. A malformed or non-integer
  version therefore cannot enter a cohort;
- accepts a cohort only at exactly 20 complete connection generations;
- reports partial generations and invalid integrity separately; and
- atomically writes the aggregate as a regular file with mode `0600`.

`duration_ms` is the interval from the preceding accepted stage in the same
connection generation. `elapsed_ms` is cumulative from that generation's
start. Both are retained only in aggregate nearest-rank summaries, with p95
unset for groups smaller than ten samples. A complete generation contains, in
order, connect request, TCP start and completion, WebSocket transport
connection, mobile join, one or more complete consecutive snapshot receive and
accept pairs, and first-card render readiness. A natural hydrating snapshot
followed by an authoritative snapshot is therefore forwarded as
`snapshot_received`, `snapshot_accepted`, `snapshot_received`,
`snapshot_accepted`. Snapshot timing summaries use only the final accepted pair
from each generation, while duration/elapsed continuity is validated across
every pair. A lone, misordered, or rejected snapshot pair invalidates the
cohort. Failed reconnect attempts ending in
`connect_requested` -> `disconnected` may be counted as partial generations
without being mislabeled as successful latency samples.

The stage envelope is exact: app/connect/TCP-start markers are `started/none`;
ordinary successful lifecycle markers are `succeeded/none`; DNS uses only its
five allowlisted outcome/reason combinations; no-configuration is
`skipped/no_configuration`; disconnect is
`failed/transport_disconnected`; and snapshot rejection is `failed` with one
of the ten snapshot-validation reason codes declared in the record schema.

Generation boundaries are cycle-specific and fail closed:

- reconnect starts at `connect_requested`;
- origin switch starts at `dns_resolved`, immediately followed by the natural
  `connect_requested`; and
- cold start uses either the natural `app_start` boundary (including its
  allowlisted boot stages) or a deliberately narrowed `connect_requested`
  boundary.

For a reconnect cohort, establish the boundary before opening the collector's
stdin: wait for the first public `cycle=reconnect`,
`stage=connect_requested` marker, then forward that marker and the following
cohort markers. The `disconnected` marker that closes the old generation belongs
before this boundary and must not be forwarded. An origin-switch collection
begins at its `dns_resolved` marker. After any boundary, forward every natural
fixed-field marker through first paint; the collector rejects rather than
filters a wrong first marker, unexpected cycle, or invalid stage sequence.

The strict performance cohort terminates each generation at its first
`first_cards_render_ready` marker. Stop forwarding that generation immediately:
a later disconnect or snapshot refresh is a hard terminal-boundary violation.
Complete receive/accept refresh pairs that occur before first paint are retained
for continuity validation and final-pair selection; refreshes after first paint
belong to a different observation and are never silently coalesced here.

Exit code `0` means the cohort is complete. Exit code `2` means fewer than 20
clean complete generations were observed. Exit code `3` means the stream or
cohort failed validation. Exit code `4` means the aggregate could not be safely
written. Error output is fixed text and never includes input data.
