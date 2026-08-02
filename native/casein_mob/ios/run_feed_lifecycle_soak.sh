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

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)" || failure
project="${script_dir}/Provision.xcodeproj"
artifact_root="$(mktemp -d /tmp/casein-ios-feed-lifecycle.XXXXXX)" || failure
artifact_prefix='/tmp/casein-ios-feed-lifecycle.'

# Invoked by finalize, which is registered as an EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  case "${artifact_root}" in
    "${artifact_prefix}"*) artifact_suffix=${artifact_root#"${artifact_prefix}"} ;;
    *) return 74 ;;
  esac

  case "${artifact_suffix}" in
    '' | *[!A-Za-z0-9]*) return 74 ;;
  esac

  [ "${#artifact_suffix}" -eq 6 ] || return 74

  if [ ! -e "${artifact_root}" ] && [ ! -L "${artifact_root}" ]; then
    return 0
  fi

  [ -d "${artifact_root}" ] || return 74
  [ ! -L "${artifact_root}" ] || return 74

  chmod -R u+rwX "${artifact_root}" >/dev/null 2>&1 || true
  rm -rf -- "${artifact_root}" >/dev/null 2>&1 || return 74
  [ ! -e "${artifact_root}" ] && [ ! -L "${artifact_root}" ]
}

# Invoked through the EXIT trap below.
# shellcheck disable=SC2329
finalize() {
  build_status=$?
  cleanup_status=0

  trap - EXIT HUP INT TERM
  cleanup || cleanup_status=$?

  if [ "${build_status}" -eq 0 ] && [ "${cleanup_status}" -eq 0 ]; then
    printf '%s\n' 'CASEIN_IOS_FEED_LIFECYCLE_SOAK_OK'
    exit 0
  fi

  printf '%s\n' 'CASEIN_IOS_FEED_LIFECYCLE_SOAK_FAILED' >&2
  exit 74
}

trap finalize EXIT
trap 'exit 74' HUP INT TERM

# Core-size limits are supported by the target macOS and POSIX shells.
# shellcheck disable=SC3045
ulimit -c 0 || exit 74

[ "${HOME+x}" = x ] || exit 74
[ "${PATH+x}" = x ] || exit 74

build_tmpdir=${TMPDIR:-/tmp}

set -- env -i \
  "HOME=${HOME}" \
  "PATH=${PATH}" \
  "TMPDIR=${build_tmpdir}" \
  'LC_ALL=C' \
  'LANG=C'

if [ "${DEVELOPER_DIR+x}" = x ]; then
  set -- "$@" "DEVELOPER_DIR=${DEVELOPER_DIR}"
fi

set -- "$@" xcodebuild test \
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
  CODE_SIGNING_REQUIRED=YES

if "$@" >/dev/null 2>&1; then
  exit 0
fi

exit 74
