#!/usr/bin/env bash
#
# Ghostty vendor pin guard. Locks the locally patched web-terminal artifact to
# the provenance and SHA-256 recorded in assets/vendor/ghostty/VERSION so a
# dependency refresh or direct vendor edit cannot land as invisible drift.
#
# Invariant enforced: VERSION must name assets/vendor/ghostty.js and its
# artifact_sha256 must equal the SHA-256 of that file's current bytes. Updating
# the vendor intentionally therefore requires reviewing and updating the pin in
# the same change.
#
# Exit 0 = clean. Exit 1 = missing/malformed pin data, missing artifact, digest
# mismatch, or digest calculation failed.
#
# Prerequisite: a compiled _build (run after `mix compile`). Uses $MIX if set
# (e.g. the mise-wrapped invocation from pre-push-check.sh), else `mix`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

# $MIX may be a multi-word command (e.g. "mise exec … -- mix"); split on words.
read -ra MIX_CMD <<< "${MIX:-mix}"

PIN_FILE="assets/vendor/ghostty/VERSION"
EXPECTED_ARTIFACT="assets/vendor/ghostty.js"

pin_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "${PIN_FILE}"
}

if [[ ! -f "${PIN_FILE}" ]]; then
  echo ">>> check-vendor-pin-guard: missing pin record: ${PIN_FILE}" >&2
  exit 1
fi

artifact="$(pin_value artifact)"
expected_sha="$(pin_value artifact_sha256)"

if [[ "${artifact}" != "${EXPECTED_ARTIFACT}" ]]; then
  echo ">>> check-vendor-pin-guard: VERSION must pin ${EXPECTED_ARTIFACT}; found '${artifact:-<missing>}'" >&2
  exit 1
fi

if ! [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]]; then
  echo ">>> check-vendor-pin-guard: VERSION has a missing or malformed artifact_sha256" >&2
  exit 1
fi

if [[ ! -f "${artifact}" ]]; then
  echo ">>> check-vendor-pin-guard: pinned artifact is missing: ${artifact}" >&2
  exit 1
fi

if ! actual_sha="$(
  GHOSTTY_VENDOR_ARTIFACT="${artifact}" "${MIX_CMD[@]}" eval --no-compile '
    System.fetch_env!("GHOSTTY_VENDOR_ARTIFACT")
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> IO.write()
  ' 2>/dev/null
)"; then
  echo ">>> check-vendor-pin-guard: failed to calculate SHA-256 for ${artifact}" >&2
  exit 1
fi

if [[ "${actual_sha}" != "${expected_sha}" ]]; then
  echo ">>> check-vendor-pin-guard: Ghostty vendor drift detected in ${artifact}" >&2
  echo ">>> expected SHA-256: ${expected_sha}" >&2
  echo ">>> actual SHA-256:   ${actual_sha}" >&2
  echo ">>> Review the vendor change, then update ${PIN_FILE} intentionally." >&2
  exit 1
fi

echo ">>> check-vendor-pin-guard: Ghostty vendor matches pinned SHA-256 (${expected_sha})."
exit 0
