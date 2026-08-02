# Android native-runtime provenance guard

`scripts/lib/android_native_provenance_guard.py` is the fail-closed preflight for
an Android physical timing cohort. It proves that the installed ARMv7 native
runtime is the native runtime from the reviewed APK before a cohort consumes a
fresh server fence.

The preflight is deliberately read-only. It does not install, uninstall, clear,
launch, stop, pair, or otherwise mutate the device or app. A caller supplies one
explicit Android serial, the fixed Casein package, and an absolute path to the
reviewed APK:

```bash
python3 -B scripts/lib/android_native_provenance_guard.py \
  --serial "$ANDROID_SERIAL" \
  --package com.example.casein_mob \
  --expected-apk /absolute/path/to/reviewed.apk
```

Proceed only when the process exits `0` and reports `status: "exact"` with
`exact: true`. All other statuses are terminal for that attempted preflight; a
cohort must not open or consume a server fence.

## Exactness contract

The guard:

1. Opens `lib/armeabi-v7a/libcasein_mob.so` from the reviewed APK under strict
   archive and uncompressed-size bounds.
2. Requires both native timing schema strings, `tcp_connect_started` and
   `tcp_connected`, in that reviewed library.
3. Runs only fixed, argv-only ADB operations for the explicit serial and fixed
   package: `pm path` followed by one read-only `adb pull` of the unique
   `base.apk` into a bounded temporary directory.
4. Applies the same archive and schema checks to the installed APK.
5. Requires the installed native-library SHA-256 digest to equal the reviewed
   native-library digest.
6. Removes the temporary APK before returning. Cleanup failure is itself a
   fail-closed result.

No digest, device identifier, package path, local path, child stdout/stderr, or
exception text is emitted. Output is one fixed-schema JSON object containing
only a fixed status category and booleans. Device-query output is held only in
bounded memory, pull output is discarded, and the downloaded APK is limited to
512 MiB.

## Failure categories

Categories distinguish invalid reviewed input, missing or ambiguous installed
base APKs, bounded-command failures, archive/native-member failures, stale stage
schema, digest mismatch, extension failure, and cleanup failure. Categories do
not include reflected identifiers or failure details.

The guard does not retry. A caller decides whether a later run represents a new
physical attempt; it must never reinterpret a non-exact result as provenance.

## BEAM-manifest extension seam

`RuntimeProvenanceExtension` is a typed, dependency-injected seam for a future
bounded comparison of packaged BEAM module manifests. It is intentionally not
wired to the CLI today: doing so would overlap the existing native build and
runtime-manifest work and would broaden this guard beyond the native library
required by the physical cohort. If an extension is supplied by an in-process
caller, an applied failing verdict changes the result to `extension_failed`; no
extension-provided details are exposed.
