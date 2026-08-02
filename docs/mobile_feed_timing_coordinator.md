# Privacy-safe physical mobile feed timing coordinator

`scripts/lib/mobile_feed_timing_coordinator.py` is the only supported entry
point for pairing one native 20-generation timing cohort with the matching
server aggregate. It composes the app-scoped source supervisor, strict stream
adapter, aggregate collector, and release-only server fence without creating a
raw capture or intermediate JSONL file.

The coordinator supports only `cold` and `reconnect` cohorts. Origin-switch
automation remains unavailable until an equally narrow, signed, app-scoped
lifecycle driver exists; there is no generic device-control fallback.

## Required inputs

Every run requires an explicit platform, cycle, physical-device identifier,
and existing absolute output root. There is no default device, connected-device
enumeration, first-device selection, PID search, or alternate host.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/lib/mobile_feed_timing_coordinator.py \
  --platform android \
  --cycle reconnect \
  --device "$EXACT_ANDROID_SERIAL" \
  --output-root "$EXISTING_PRIVATE_AGGREGATE_ROOT"
```

iOS reconnect additionally requires the already-running production app's exact
numeric PID. The coordinator never discovers a PID by process name:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/lib/mobile_feed_timing_coordinator.py \
  --platform ios \
  --cycle reconnect \
  --device "$EXACT_IOS_UDID" \
  --ios-pid "$EXACT_RUNNING_PID" \
  --output-root "$EXISTING_PRIVATE_AGGREGATE_ROOT"
```

iOS cold runs omit `--ios-pid`; each of the twenty generations uses the source
supervisor's reviewed start-stopped → PID-scoped attachment → resume lifecycle.

## Fixed execution order

1. Preflight the aggregate root without creating output.
2. Start the fixed SSH command for
   `/opt/casein/release/bin/mobile_feed_timing_soak <platform> <cycle>`.
3. Wait for the literal `CASEIN_MOBILE_FEED_SOAK_READY` control line. The
   release helper emits it as the first stdout frame only after opening the
   recorder fence. Any partial, malformed, extra, stderr, timeout, or early-exit
   frame fails before device work.
4. Start the app-scoped source. Markers flow through an anonymous bounded pipe
   into `StreamAdapter`, then directly through an in-memory sink into
   `Collector`. The sink keeps no records or log lines.
5. Retain only the raw generation from each accepted terminal
   `first_cards_render_ready` marker. The adapter and collector retain only
   their independent HMAC surrogates.
6. Require exact adapter completion, exact collector completion, twenty unique
   terminal generations, and successful scoped-source cleanup.
7. Encode the generation vault exactly once as twenty canonical 22-byte IDs,
   each followed by LF: 20 lines and 460 bytes. Write it once to bridge stdin,
   close stdin, and never retry an uncertain finish.
8. Require the aggregate as the second and final stdout frame, then strictly
   validate it. Missing, malformed, extra, or stderr frames fail closed. A valid
   `cohort_match=false` aggregate remains useful evidence and is published, but
   the coordinator exits nonzero. Validation mirrors the release bridge's
   occupancy, percentile, ordering, numeric-bound, cross-map-count, observation,
   and 65,536-byte aggregate invariants.
9. Atomically rename one new mode-`0700` directory containing only
   `native.json` and `server.json`, each mode `0600`.

## Platform lifecycle boundaries

- Android cold uses the explicit serial for alternating package-only
  `am force-stop com.example.casein_mob` and exact launcher-activity starts. It
  waits for one accepted terminal generation before beginning the next cycle.
- Android reconnect invokes only the installed signed instrumentation method
  `CaseinFeedLifecycleSoakTest#twentyExplicitCurrentOriginReconnects` on the
  explicit serial.
- iOS cold uses twenty independent reviewed start-stopped source-supervisor
  plans. No UI runner is involved.
- iOS reconnect attaches the continuous PID-scoped source, then invokes only
  `native/casein_mob/ios/run_feed_lifecycle_soak.sh <UDID>`. That reviewed
  runner owns the exact test plan/method, 20 no-relaunch repetitions, signing
  requirements, disabled diagnostics/capture/coverage, suppressed child
  output, and trap-cleaned ephemeral artifacts.

All coordinator children use argv execution with `shell=False`, new process
groups, a reduced environment, `/dev/null` for non-protocol output, disabled
Python bytecode, and disabled core dumps. Only the fixed SSH bridge inherits
`SSH_AUTH_SOCK`; native source, ADB, and signed iOS lifecycle children do not.
Cleanup is bounded TERM followed by KILL and visits every coordinator-owned
group even if an earlier child resists cleanup or raises. A numeric PGID is
signalable only while its tracked leader identity remains live. If the leader
has already exited, an absent group is `not_needed`; an existing group is
ambiguous and fails cleanup without any signal. Leader identity is revalidated
before escalation, so exit after TERM also prevents KILL. A deferred interrupt
or any failed group cleanup prevents bridge submission and publication.
Successful native cleanup is authoritative and precedes the one-shot bridge
send.

## Failure and privacy semantics

Before the one-shot send, every failure closes bridge stdin so the release
helper retires its fence, terminates scoped native/lifecycle processes, clears
the in-memory generation vault, and publishes nothing. After a send begins,
write, EOF, remote-finish, target, or reply uncertainty is terminal; the
coordinator does not reuse the fence or generation set.

The coordinator never uses `tee`, a shell pipeline, a raw log capture, a pane,
the operator terminal, a credential-bearing log, a general device-log export,
or an output/status object containing a generation or device identity. On
success, standard error is the fixed two-field coordinator/status object. On
failure, it adds only the bounded allowlisted `phase`, `source`, `adapter`,
`record_count`, and `generation_count` diagnostics. The published aggregates
are checked again for secrets and generation values before their atomic reveal.

The output root is opened with `O_NOFOLLOW` during preflight and that same
directory descriptor remains pinned for the entire run. It is the sole base for
staging, file creation, rename, and root sync, so replacing the pathname cannot
redirect publication. Both files and the staging directory are synced and
permissioned before rename. The rename is the publication commit point: if the
post-rename root sync fails or is interrupted, the already-visible complete
artifact is truthfully reported as published. No result claims
`published=false` while that artifact remains visible.

Keyboard interrupt and SIGTERM share the same exhaustive bounded cleanup path.
Before the one-shot send, cleanup visits all owned process groups before the
interrupt is returned, bridge stdin is closed, and the fence is aborted. During
an uncertain finish, no second payload is ever sent; the owned bridge process
is only retired, native groups are terminated, anonymous pipes are closed, and
the in-memory generation vault is cleared.

The fake-process contract suite invokes no SSH endpoint, device, Xcode build,
ADB command, terminal, or log source:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 \
  test/scripts/mobile_feed_timing_coordinator_test.py

mise exec -- mix test \
  test/scripts/mobile_feed_timing_coordinator_test.exs
```
