# Bounded physical iOS scanner-boundary probe

`scripts/lib/ios_scanner_boundary_probe_runner.py` is the only supported
physical execution path for the development-only scanner boundary diagnostic.
It does not scan, pair, exchange a handle, change a profile, or make a network
request. The native app injects the checked-in public compact-pairing fixture
into a parser-only receiver and emits one fixed diagnostic classification.

## Preconditions

- The exact reviewed scanner-probe commit is in `origin/master` and active via
  the normal deploy poller at that revision or a proven descendant.
- The signed app was built from a clean detached worktree at that exact
  revision and installed in place without uninstalling or clearing app data.
- The installed bundle is
  `com.alexandrefamilyfarm.casein-mob`, is container-accessible, and carries the
  development `get-task-allow=true` entitlement. A distribution-signed app
  intentionally rejects the diagnostic URL.
- The caller has one explicit physical device identifier. There is no device
  enumeration or first-device fallback.
- The caller records a durable external attempted fence **before** invoking the
  runner. That fence is consumed for every outcome, including timeout,
  interruption, malformed output, or cleanup ambiguity. Never retry the same
  attempted fence.

The sole invocation is:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 \
  scripts/lib/ios_scanner_boundary_probe_runner.py \
  --device "$EXACT_PRIVATE_IOS_DEVICE_ID"
```

The device argument stays in process memory and fixed child argv only. It is
never included in runner output. Do not use `tee`, interactive
`idevicesyslog`, a device-log archive, or a shell pipeline around this command.

## Fixed lifecycle

1. Validate the explicit device identifier without reflecting it.
2. Invoke exactly one bounded CoreDevice command with the fixed public literal
   `casein://diagnostic/scanner-boundary`: start the exact app suspended,
   terminate only a prior instance of that app, and return strict JSON. The
   bounded JSON reader accepts at most 16 KiB and suppresses child stderr.
3. Strictly parse one positive integer PID from the exact successful launch
   envelope. There is no process-name lookup.
4. Spawn one owned `idevicesyslog` process filtered to that exact PID and the
   literal `ios_scanner_boundary_probe ` marker. Require its exact connection
   frame before continuing.
5. Resume the same PID through a second bounded CoreDevice JSON command. A
   different returned PID fails closed.
6. Within 15 seconds, accept one line of at most 1,024 bytes containing exactly
   one marker, a bounded UTF-8 transport prefix, and this exact suffix:

   ```text
   scan_type=qr byte_count=146 compact_prefix=true base64url_segment=true rejection_stage=none rejection_reason=none
   ```

7. Hold the filtered source for a 250 ms duplicate guard. A second line, EOF,
   malformed line, timeout, or oversized line fails closed.
8. If any boundary after strict PID parsing fails before resume is confirmed,
   issue one bounded termination for that exact launched PID. A malformed or
   ambiguous termination reply fails as `cleanup`; there is no bundle lookup,
   process-name lookup, fallback, retry, or relaunch.
9. Terminate only the owned host source process group and require proven
   closure. Process-directed interrupts are blocked while all acquired
   capabilities are released, then restored. An exception at any one cleanup
   boundary cannot skip the remaining cleanup boundaries. The runner never
   kills an unrelated process, relaunches the app, or retries the URL.

All child stdout is consumed through bounded in-memory readers. Child stderr
is `/dev/null`. No raw line, launch reply, PID, device identifier, URL, fixture,
or exception text is emitted or retained.

## Output contract

The runner writes exactly one compact JSON object to standard error and nothing
to standard output:

```json
{"phase":"complete","runner":"casein_ios_scanner_boundary_probe_runner","status":"accepted"}
```

or:

```json
{"phase":"diagnostic","runner":"casein_ios_scanner_boundary_probe_runner","status":"failed"}
```

Failure `phase` is one fixed value:

- `arguments`
- `launch_suspended`
- `pid_parse`
- `source_spawn`
- `source_connected`
- `resume`
- `diagnostic`
- `cleanup`
- `interrupted`

Exit status is `0` for accepted, `3` for a physical/protocol failure, `64` for
invalid arguments, and `130` for interruption. Any nonzero result consumes the
external attempted fence. Do not interpret a phase as permission to retry.

The fake-process contract suite invokes no device, Xcode command, native log
source, network endpoint, or app process:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 \
  test/scripts/ios_scanner_boundary_probe_runner_test.py

mise exec -- mix test \
  test/scripts/ios_scanner_boundary_probe_runner_test.exs
```
