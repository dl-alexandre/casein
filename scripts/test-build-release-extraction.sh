#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

make_fake_docker() {
  local fake_bin="$1"

  cat >"${fake_bin}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG}"

case "${1:-}" in
  image)
    exit 1
    ;;
  build)
    exit 0
    ;;
  create)
    printf 'fake-container-id\n'
    ;;
  cp)
    if [ "${FAKE_DOCKER_CP_FAIL:-0}" = "1" ]; then
      exit 42
    fi
    output="${3:?missing output directory}"
    mkdir -p \
      "${output}/bin" \
      "${output}/releases" \
      "${output}/lib/casein-0.1.0/priv/static/assets/css" \
      "${output}/lib/casein-0.1.0/priv/static/assets/js"
    chmod +x "${output}/bin"
    for executable in casein casein-runtime migrate clean_casein_socket; do
      printf '#!/usr/bin/env sh\n' >"${output}/bin/${executable}"
      chmod +x "${output}/bin/${executable}"
    done
    printf '{}\n' >"${output}/releases/casein.relmeta.json"
    printf '{}\n' >"${output}/lib/casein-0.1.0/priv/static/cache_manifest.json"
    : >"${output}/lib/casein-0.1.0/priv/static/assets/css/app.css"
    : >"${output}/lib/casein-0.1.0/priv/static/assets/js/app.js"
    ;;
  rm)
    if [ "${FAKE_DOCKER_RM_HANG:-0}" = "1" ]; then
      sleep 30
    fi
    ;;
  rmi)
    ;;
  *)
    echo "unexpected fake docker command: $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "${fake_bin}"

  for unsupported in timeout gtimeout; do
    cat >"$(dirname "${fake_bin}")/${unsupported}" <<'EOF'
#!/usr/bin/env sh
echo "external timeout utility must not be used" >&2
exit 97
EOF
    chmod +x "$(dirname "${fake_bin}")/${unsupported}"
  done
}

run_case() {
  local name="$1"
  shift
  local case_root="${TMP_ROOT}/${name}"
  mkdir -p "${case_root}/bin"
  make_fake_docker "${case_root}/bin/docker"

  env \
    PATH="${case_root}/bin:${PATH}" \
    CASEIN_DOCKER_BIN="${case_root}/bin/docker" \
    CASEIN_DOCKER_CLEANUP_TIMEOUT_SECONDS=1 \
    CASEIN_BUILDER_CACHE_TAG="casein:test-cache" \
    FAKE_DOCKER_LOG="${case_root}/docker.log" \
    OUTPUT_DIR="${case_root}/release-out" \
    "$@" \
    bash "${ROOT}/scripts/build-release.sh"
}

echo "== successful copy remains valid when exact-container cleanup hangs =="
run_case cleanup-hang FAKE_DOCKER_RM_HANG=1
grep -q '^create --name casein-release-extract-' "${TMP_ROOT}/cleanup-hang/docker.log"
grep -q '^cp casein-release-extract-' "${TMP_ROOT}/cleanup-hang/docker.log"
grep -q '^rm -f casein-release-extract-' "${TMP_ROOT}/cleanup-hang/docker.log"
test -x "${TMP_ROOT}/cleanup-hang/release-out/bin/casein"

echo "== copy failure is fatal and still attempts exact-container cleanup =="
if run_case copy-failure FAKE_DOCKER_CP_FAIL=1; then
  echo "expected docker cp failure to fail the release build" >&2
  exit 1
fi
grep -q '^rm -f casein-release-extract-' "${TMP_ROOT}/copy-failure/docker.log"

echo "release extraction cleanup tests passed"
