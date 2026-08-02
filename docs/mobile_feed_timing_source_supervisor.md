# Privacy-safe native timing source supervisor

`scripts/lib/mobile_feed_timing_source_supervisor.py` is the only supported
native-log producer for the strict mobile feed timing stream. It owns one
app-scoped source process, removes only the fixed iOS connection framing in
memory, and writes only newline-terminated `mobile_feed_stage ` markers to
standard output. It never writes a raw capture, uses `tee`, invokes a local
shell, interpolates input into the fixed Android remote command, or reflects
child output, child errors, device identifiers, process identifiers, commands,
credentials, or log text.

This script is a narrow building block, not the final physical-cohort entry
point. The in-memory cohort coordinator must own the source, stream adapter,
collector, and server aggregate helper and inject their authoritative downstream
status. A standalone producer cannot prove why its pipe closed, so it rejects an
otherwise unverifiable `EPIPE`. Only an injected exact downstream exit status of
zero may normalize `EPIPE` or wake a quiet source after generation 20. `TERM`
alone is never evidence of success.

## Fixed source contracts

Android uses one `adb exec-out` remote-command argument. That constant command
runs a bounded logcat capability probe as the Casein application UID, emits one
literal identity-free readiness frame, then replaces the remote shell with the
reviewed long-lived logcat source. The supervisor must consume that exact frame
within the readiness timeout before signaling its caller. It then selects only
the main buffer, uses raw formatting, starts at the current tail, applies the
exact anchored timing-marker regex, and silences every tag except `Elixir`.
There is no PID/UID fallback, general logcat export, or alternate regex. Failure
of the exact readiness frame, `run-as`, logcat, the application package, adb
transport, or `--exit-on-write-error` is a hard capability failure. Because the
filter is application-UID scoped, Android pane or app-process replacement does
not broaden the source. The readiness frame is discarded in memory and is
never forwarded or reported.

iOS uses idevicesyslog 1.4 with one validated device UDID, one validated numeric
PID, the literal `mobile_feed_stage ` match, color disabled, and exit-on-process
disconnect. It accepts the exact bounded `[connected:<UDID>]` readiness frame,
then discards only the matching `[disconnected:<UDID>]` frame. Both comparisons
happen in memory and neither identifier is reported. Any other pre-readiness or
non-marker stdout is a hard capability failure.

For a cold iOS generation the lifecycle is fixed:

1. `devicectl` launches the tracked production bundle
   `com.alexandrefamilyfarm.casein-mob` start-stopped, terminated-existing,
   active, quiet, with a 30-second timeout and JSON written to its stdout pipe.
2. The bounded JSON reply must have exactly `info` and `result`,
   `info.outcome == "success"`, and a valid integer
   `result.processIdentifier`.
3. The PID-scoped idevicesyslog source starts and must emit its exact connected
   frame within the readiness timeout.
4. `devicectl process resume` must return the same fixed success envelope. Its
   documented result map may omit `processIdentifier`; if present, it must equal
   the launched PID.
5. Immediately after forwarding that generation's exact cold
   `first_cards_render_ready` marker, the supervisor terminates the PID-scoped
   source group and returns the distinct successful per-generation status
   `ios_cold_generation_complete`. The coordinator can then launch and attach
   the next PID without retaining or replaying an old stream.

Reconnect observation attaches once to the coordinator-supplied stable PID and
does not use launch/resume. When the coordinator does not yet have that PID, the
narrow suspended-continuous mode performs the same fixed launch, attachment,
readiness, and resume sequence but intentionally does not stop on the initial
cold first-card marker. The reconnect adapter discards that other-cycle startup,
then signed app-scoped UI automation drives the reconnect cohort on the same PID.
This mode is a coordinator-only typed API and is deliberately absent from the
standalone CLI, because only the coordinator can supply the required downstream
completion probe. Only verified downstream completion stops that continuous
source; there is no process-list or name-search fallback. Twenty cold
per-generation streams may be concatenated only in memory into one strict
stream-adapter process; they must not be written to an intermediate file.

## Process and privacy bounds

- Every child is argv-only with `shell=False`, its own process group, stdin from
  `/dev/null`, stdout through one bounded pipe, and stderr sent to `/dev/null`.
- Child environment is reduced to the tool-resolution/device-support keys plus
  a fixed C locale; application/API tokens are not propagated.
- Marker lines, cumulative bytes, line count, iOS prefix length, lifecycle JSON,
  readiness time, and lifecycle command time are hard bounded.
- Timeout, framing drift, invalid or duplicate-key JSON, wrong/missing PID,
  nonzero tool exit, unsupported tool capability, and cleanup failure all fail
  closed. There is no broad source fallback.
- Cleanup targets only the source child's new process group, first with `TERM`
  and then bounded `KILL` escalation.
- Standard error is exactly one fixed-schema, identity-free aggregate status.
  It contains only fixed categories and bounded counters. The full supervisor
  status includes one `source_phase` enum; malformed, missing, duplicate,
  non-string, unknown, or extra phase data is rejected by the coordinator.
- Normal execution disables Python bytecode creation. No raw source or lifecycle
  reply is written to disk.

## Source phase boundaries

`source_phase` is a causal boundary, not a timer and not a free-form error. A
failed run retains the first boundary that failed. Later best-effort teardown
does not overwrite it; `cleanup` is reported only when cleanup itself turns an
otherwise successful source path into failure. A successful full supervisor
status always reports `complete`.

| `source_phase` | Exact boundary |
|---|---|
| `not_started` | The coordinator has not received a full supervisor status for the current source generation. A full supervisor run advances before doing work. |
| `plan_validation` | Reconstruct and compare the allowlisted typed source plan before any child starts. |
| `launch_suspended` | Run the fixed iOS start-stopped launch and receive its bounded JSON envelope. |
| `pid_parse` | Validate the exact launch envelope and extract its strict integer PID. |
| `source_spawn` | Spawn the sole allowlisted app-scoped source child. |
| `source_connected` | Require the source stdout pipe and consume the exact Android readiness or iOS PID-attachment frame. |
| `resume` | Validate the fixed same-PID iOS resume reply. Source readiness cannot be released before this succeeds. |
| `stream` | Release source readiness, then read, validate, and forward only bounded timing markers. |
| `early_exit` | The source reached EOF before an authoritative terminal/downstream completion. Zero exit is incomplete; nonzero exit is a capability failure. |
| `cleanup` | Intentional source cleanup was the operation that failed after an otherwise successful terminal/downstream boundary. |
| `complete` | The source boundary, authoritative completion condition, and required cleanup all succeeded. |

The enum carries no duration, device, process, generation, command, output,
exception, or credential field. `source_phase` supplements the existing fixed
status category; it does not weaken any status or cleanup requirement.

The dependency-injected contract suite never invokes adb, devicectl,
idevicesyslog, a device, SSH, a terminal, or an operator pane. Run it through
the repository wrapper:

```bash
mise exec -- mix test test/scripts/mobile_feed_timing_source_supervisor_test.exs
```

The downstream marker and cohort validation contracts remain in
[`mobile_feed_timing_stream.md`](mobile_feed_timing_stream.md) and
[`mobile_feed_timing_collector.md`](mobile_feed_timing_collector.md).
