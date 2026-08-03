# Android app-BEAM provenance guard

`scripts/lib/android_beam_provenance_guard.py` is the read-only preflight that
proves an Android app's installed Casein BEAM set is exactly the reviewed local
`casein_mob` build before a physical timing cohort consumes a fresh server
fence.

A caller supplies one explicit Android serial, the fixed Casein package, and an
absolute path to the reviewed `casein_mob/ebin` directory:

```bash
python3 -B scripts/lib/android_beam_provenance_guard.py \
  --serial "$ANDROID_SERIAL" \
  --package com.example.casein_mob \
  --expected-ebin-root /absolute/path/to/casein_mob/ebin
```

Proceed only when the command exits `0` and emits `status: "exact"` with all
five booleans true. Every other status is terminal for that attempted
preflight. The guard does not retry and does not create or consume a cohort
fence.

## Exactness contract

The guard:

1. Requires the local root to be an absolute, real directory whose final
   components are exactly `casein_mob/ebin`.
2. Builds a non-empty set of at most 64 strict ASCII `.beam` basenames. Every
   selected local entry must be a regular non-symlink file.
3. Snapshots each local file's device/inode/mode/size/change identity, hashes it
   through a no-follow descriptor under a 16 MiB per-file and 64 MiB aggregate
   cap, and requires descriptor identity before/after the read plus a closing
   directory snapshot to equal the opening snapshot.
4. Runs only argv-based ADB commands scoped as
   `adb --exit-on-write-error -s SERIAL exec-out run-as
   com.example.casein_mob ...`. There is no device discovery, package
   discovery, alternate transport, root path, or fallback.
5. Reads a fixed framed manifest of names, bounded file-identity tokens, and
   SHA-256 content digests from `files/otp/casein_mob`, rejecting truncation,
   malformed frames, duplicates, unsafe names, non-regular entries, symlinks,
   pathname/descriptor identity changes, and count/output overages.
6. Requires exact installed/local basename-set equality before reading any
   installed BEAM bytes, and requires each opening-manifest digest to equal its
   reviewed local digest.
7. Opens each installed entry on a private shell descriptor, requires its
   identity to equal the opening-manifest identity, and sandwiches the bounded
   read between pathname/descriptor identity checks. A symlink or regular-file
   swap makes that one read fail; no file is retried.
8. Requires each SHA-256 digest to equal the reviewed digest for that exact
   basename, then obtains a closing strict manifest and requires its complete
   name-to-identity-and-digest map to equal the opening installed manifest
   before reporting exactness. Replacement or in-place content change after an
   earlier successful read therefore fails even when the basename set and
   coarse filesystem timestamps are unchanged.

Manifest order is irrelevant. Installed files are read in sorted basename order
only after set equality, so a reordered manifest cannot associate bytes with
the wrong reviewed module. Opening and closing snapshots are two phases of one
verification, not a retry; any observed change is terminal for the attempt.

## Privacy and failure contract

The process emits exactly one compact JSON line. Its keys are fixed:

- `schema_version`
- `component`
- `status`
- `expected_manifest_valid`
- `installed_manifest_complete`
- `beam_name_set_match`
- `beam_digest_match`
- `exact`

`status` is a fixed enum. Output never includes the device serial, package,
local or installed paths, BEAM filenames, child output, file bytes, digests, or
exception text. Child stderr is discarded and child stdout is held only in
bounded memory. Subprocess timeout, output truncation, local or device races,
missing/extra entries, malformed data, and internal exceptions all fail closed
with nonzero exit status.

The guard is read-only: it does not install, uninstall, clear, launch, stop,
pair, write, rename, or delete app/device data. A non-exact result must never be
reinterpreted as provenance or retried against the same physical cohort fence.
