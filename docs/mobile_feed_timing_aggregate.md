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
