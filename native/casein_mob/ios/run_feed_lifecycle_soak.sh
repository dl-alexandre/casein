#!/bin/sh

# Privacy-safe physical runner for the already-running production Casein app.
# The dedicated scheme and test plan contain one test method only. XCTest must
# attach to that running app; this script never launches or terminates it.

set -eu

failure() {
  printf '%s\n' 'CASEIN_IOS_FEED_LIFECYCLE_SOAK_FAILED' >&2
  exit 74
}

[ "$#" -eq 1 ] || failure

device_id="$1"

case "${device_id}" in
  *[!A-Za-z0-9-]* | '') failure ;;
esac

[ "${#device_id}" -ge 8 ] || failure
[ "${#device_id}" -le 64 ] || failure

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)" || failure
project="${script_dir}/Provision.xcodeproj"
artifact_root="$(mktemp -d /tmp/casein-ios-feed-lifecycle.XXXXXX)" || failure

cleanup() {
  case "${artifact_root}" in
    /tmp/casein-ios-feed-lifecycle.*)
      chmod -R u+rwX "${artifact_root}" 2>/dev/null || true
      rm -rf -- "${artifact_root}"
      ;;
    *)
      return 74
      ;;
  esac
}

trap cleanup EXIT
trap 'exit 74' HUP INT TERM

if xcodebuild test \
  -project "${project}" \
  -scheme CaseinMobFeedLifecycleUITests \
  -testPlan CaseinMobFeedLifecycleSoak \
  -destination "platform=iOS,id=${device_id}" \
  -derivedDataPath "${artifact_root}/DerivedData" \
  -resultBundlePath "${artifact_root}/Result.xcresult" \
  -only-testing:CaseinMobFeedLifecycleUITests/CaseinMobFeedLifecycleUITests/testCanonicalDevboxReconnectWithoutRelaunch \
  -test-iterations 20 \
  -test-repetition-relaunch-enabled NO \
  -collect-test-diagnostics never \
  -enablePerformanceTestsDiagnostics NO \
  -enableCodeCoverage NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  >/dev/null 2>&1; then
  printf '%s\n' 'CASEIN_IOS_FEED_LIFECYCLE_SOAK_OK'
  exit 0
fi

failure
