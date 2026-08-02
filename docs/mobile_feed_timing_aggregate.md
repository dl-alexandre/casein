# Mobile feed timing server aggregate

`Casein.Mobile.FeedTimingRecorder` exposes an internal, release-RPC-safe
aggregate for bounded native-feed timing so soak evidence does not need to
export the recorder's retained rows. It is deliberately not an HTTP surface.

Callers must supply all three cohort dimensions explicitly:

- a nonempty, exact-unique allowlist of at most 100 canonical connection
  generations;
- one fixed native platform atom (`:ios` or `:android`);
- one fixed cycle atom (`:cold`, `:reconnect`, or `:origin_switch`).

Use `aggregate/3` to inspect without changing retention, or
`aggregate_and_consume/3` to aggregate and delete only the matched retained
rows in one recorder call. Invalid requests return the same non-reflective
`{:error, :invalid_request}` result and delete nothing. A consuming call takes
a sequence boundary before reading ETS and deletes only the exact matched
sequence keys it aggregated. Records outside the allowlist/scope, plus records
arriving after that boundary, remain retained.

The JSON-safe result contains only:

- schema version, component, platform, and cycle;
- expected and observed unique-generation counts and an exact set-match flag;
- all fixed server stages with sample counts and `duration_ms` / `elapsed_ms`
  min, nearest-rank p50, nearest-rank p95, and max values;
- all fixed outcome and reason counts;
- bounded card-count and canonical-snapshot-byte summaries when sampled.

P95 remains `null` until a field has at least 10 samples. Hydration stages are
optional and are summarized independently; no stage-completeness requirement
is inferred. Equal generation counts do not imply a cohort match: missing and
unexpected generations can cancel numerically, so the recorder compares the
sets exactly within the requested platform/cycle.

The aggregate never returns or logs connection-generation values, individual
records, timestamps, HMACs, workspace/session/pane identities, or content. It
also never compares native and server monotonic timestamps. Cross-component
analysis must compare stage durations or independently elapsed intervals, not
subtract clocks from different processes or devices.

## Fenced physical-soak collection

Physical 20-cycle runs use the internal `begin_cohort/2` and
`finish_cohort/4` recorder contract. Begin returns an opaque, recorder-epoch
fence bound to one fixed platform/cycle and a lower sequence. Finish captures
an upper sequence and considers only records in the open/closed interval
`lower < sequence <= upper`. It requires exactly 20 unique canonical raw
generation IDs, emits only their aggregate, and consumes only matched rows in
that interval. Pre-fence rows, post-upper rows, other generations, and other
platform/cycle scopes remain retained. This path never calls `clear/0`.

Only one live fence is allowed per platform/cycle. The recorder also keeps a
small fixed total fence cap and lazily expires abandoned fences after one hour,
so interrupted helpers cannot create an unbounded registry or contaminate a
later same-scope cohort. A finish attempt consumes its fence even when the
scope, ID count, or request is invalid. Foreign, expired, replayed, altered,
and malformed fences all return the same non-reflective error.

The packaged `bin/mobile_feed_timing_soak` helper is a local release-only
bridge; it is not routed through HTTP. Its only arguments are the fixed public
platform and cycle names. It opens the server fence before reading exactly 20
canonical LF-terminated IDs from stdin. Immediately after begin succeeds it
writes the constant `CASEIN_MOBILE_FEED_SOAK_READY` line exactly once on a
control-only descriptor that the overlay duplicates from outer stderr. A
coordinator must observe that line before starting device work. The child
runtime's ordinary stderr is discarded, and aggregate stdout remains silent
and buffered until finish. Missing readiness fails closed and retires the
fence without reading stdin. The bridge pins one strictly validated
`/run/casein/current.sock` target around the consuming RPC, and starts a hidden
non-listening distribution client. It never fails over or retries an uncertain
finish. Success writes one aggregate JSON object. Every failure writes one
fixed error code with no supplied value.

Distribution credentials stay in the existing fixed
`/etc/casein/casein.env` file. The helper requires that file to be owned by its
effective release user, non-symlinked, single-linked, private, and below a
bounded size; `/etc/casein` must be non-symlinked and non-writable to that
user. The cookie is parsed in memory without sourcing the file and is never
placed in argv, inherited environment, a new file, stdout, stderr, or a crash
dump. Moving the cookie into a dedicated systemd credential would further
reduce file scope, but is a separate host-hardening change rather than a
requirement of this bridge.
