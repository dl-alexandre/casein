# Android runtime-BEAM provenance guard

`scripts/lib/android_beam_provenance_guard.py` is the read-only preflight that
proves an Android app's installed flat Casein BEAM set is exactly the reviewed
local runtime selected by the same contract as `mix mob.deploy`. Run it before a
physical timing cohort consumes a fresh server fence.

A caller supplies one explicit Android serial, the fixed Casein package, and the
absolute reviewed `_build/dev/lib` root:

```bash
python3 -B scripts/lib/android_beam_provenance_guard.py \
  --serial "$ANDROID_SERIAL" \
  --package com.example.casein_mob \
  --expected-build-lib-root \
    /absolute/path/to/casein_mob/_build/dev/lib
```

Proceed only when the command exits `0` and emits `status: "exact"` with all
five booleans true. Every other status is terminal for that attempted preflight.
The guard does not retry and does not create or consume a cohort fence.

## Exact deploy-selection contract

The guard resolves expected source roots with one fixed, bounded, argv-only
local command from the reviewed project root:

```text
mise exec -- mix run --no-start --no-compile --no-deps-check -e FIXED_PROGRAM
```

The fixed program calls `MobDev.HotPush.runtime_beam_dirs/0`, then appends the
host EEx and SSL `ebin` roots exactly as `MobDev.Deployer.collect_beam_dirs/0`
does. It also repeats the deployer's cached-runtime crypto test. A runtime that
would require the generated crypto shim is deliberately unsupported because
generating that shim would mutate local state; the guard fails closed before
ADB instead. The current reviewed Android runtime has real crypto, so the
documented invocation is complete and honest.

`runtime_beam_dirs/0` inherits `File.ls/1` order, which is not guaranteed. Mob's
flat staging copies roots sequentially, so a duplicate BEAM basename would make
the last source win nondeterministically. The guard never tries to emulate that
unsafe ambiguity: it preserves the returned runtime-root order, appends EEx then
SSL, and rejects any basename collision before ADB. With unique basenames, root
order cannot change the expected flat map.

The resolver frame is private and bounded. It must contain a non-empty runtime
closure, exactly one EEx root, exactly one SSL root, exactly one `REAL` crypto
classification, no duplicate roots, and only absolute strict-ASCII paths of the
expected shape. Missing, malformed, duplicated, non-ASCII, symlinked, or
non-directory selected roots fail closed. No resolver path or output is emitted.

## Exactness contract

The guard:

1. Requires the reviewed root to be an absolute real directory ending exactly
   in `_build/dev/lib`.
2. Resolves at most 512 selected source roots and flattens a non-empty set of at
   most 4,096 strict-ASCII `.beam` basenames. Every selected BEAM and source root
   must be regular/non-symlink as appropriate, and every basename must be unique
   across all selected roots.
3. Opens all selected source roots first, snapshots every selected file's
   device/inode/mode/size/change identity, hashes through no-follow descriptors,
   and requires descriptor identity before/after every read plus complete closing
   root/file snapshots. Limits are 16 MiB per BEAM and 128 MiB aggregate. These
   finite bounds cover the reviewed 61-root, 1,399-BEAM, 27,447,200-byte runtime
   while leaving room for ordinary dependency growth.
4. Runs device commands only as argv scoped to
   `adb --exit-on-write-error -s SERIAL exec-out run-as
   com.example.casein_mob ...`. There is no discovery, alternate device,
   package fallback, root path, or device mutation. Android raw `exec-out` does
   not carry a trustworthy remote shell exit status, so device classifications
   never depend on the host process return code. Each fixed remote program
   emits its semantic result in a bounded terminal status record instead; a
   nonzero host return code remains a transport failure.
5. Reads a fixed framed opening manifest of names, bounded file-identity tokens,
   and SHA-256 digests from `files/otp/casein_mob`. The frame starts with
   `CASEIN_BEAMS_V5`, ends with exactly one terminal
   `STATUS<TAB>{OK|MISSING|INVALID|LIMITED|CHANGED|HASH_FAILED}` record and one
   `END` record, and permits no bytes after `END`. Missing, duplicated, unknown,
   truncated, or misplaced status records fail as malformed. The guard also
   rejects malformed entries, duplicates, unsafe names, non-regular entries,
   symlinks, path/descriptor identity changes, and count/output overages.
6. Requires exact installed/local basename-set equality before reading installed
   BEAM bytes, and requires each opening-manifest digest to equal the reviewed
   local digest.
7. Opens each installed entry on a private shell descriptor, requires its
   identity to equal the opening-manifest identity, and sandwiches the bounded
   read between pathname/descriptor identity checks. Its private read frame is
   `CASEIN_BEAM_READ_V1`, `DATA`, the byte-exact BEAM payload, then exactly one
   terminal status and `END`. On success, the manifest-declared identity size
   is the payload boundary, so arbitrary BEAM bytes cannot forge or hide the
   success trailer. A non-success trailer may follow no bytes or a bounded
   partial/full read as appropriate. Missing, truncated, duplicated, unknown,
   trailing, or wrong-length frames fail closed. A symlink or regular-file swap
   makes that one read fail; no file is retried.
8. Requires every locally computed installed digest to equal the reviewed digest,
   then obtains a closing strict manifest and requires its complete
   name-to-identity-and-digest map to equal the opening installed manifest.

Installed manifest order is irrelevant. Files are read in sorted basename order
only after set equality, so reordering cannot associate bytes with the wrong
reviewed module. Opening and closing snapshots are phases of one verification,
not retries; any observed change is terminal.

## Privacy and failure contract

The process emits exactly one compact JSON line with fixed keys:

- `schema_version`
- `component`
- `status`
- `expected_manifest_valid`
- `installed_manifest_complete`
- `beam_name_set_match`
- `beam_digest_match`
- `exact`

`status` is a fixed enum. Remote frame tokens map only to those fixed public
classifications; frame contents are never reflected. Output never includes the
device serial, package, local or installed paths, source roots, BEAM filenames,
child output, file bytes, digests, or exception text. Child stderr is discarded
and child stdout is held only in bounded memory. Resolver failure, crypto-shim
mode, subprocess timeout, output truncation, local or device races, collisions,
missing/extra entries, malformed data, and internal exceptions all fail closed
with nonzero exit status.

The guard is read-only: it does not compile, generate a crypto shim, install,
uninstall, clear, launch, stop, pair, write, rename, or delete app/device data.
A non-exact result must never be reinterpreted as provenance or retried against
the same physical cohort fence.
