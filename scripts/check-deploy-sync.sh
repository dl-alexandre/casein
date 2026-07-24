#!/usr/bin/env bash
#
# Verify rel/overlays/deploy/ stays byte-identical to the canonical source in
# lib/casein/integrations/manager/deploy/. We can't use symlinks (mix release
# packages overlays via docker cp during build, which extracts symlinks as
# unresolved links rather than following them — see scripts/build-release.sh
# and the docker-cp tar implementation). So we ship two copies and enforce
# they match.
#
# Run from the repo root, or via `mix precommit`.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/lib/casein/integrations/manager/deploy"
DST="${REPO_ROOT}/rel/overlays/deploy"

failed=0
for f in devide.service devide.env.example docker-compose.postgres.yml README.md; do
  if ! diff -q "${SRC}/${f}" "${DST}/${f}" >/dev/null 2>&1; then
    echo "deploy-sync: ${f} differs between source and overlay" >&2
    echo "  source:  ${SRC}/${f}" >&2
    echo "  overlay: ${DST}/${f}" >&2
    echo "  fix:     cp ${SRC}/${f} ${DST}/${f}" >&2
    failed=1
  fi
done

if [ "$failed" -eq 0 ]; then
  exit 0
fi

echo >&2
echo "deploy-sync: rel/overlays/deploy/ is a build-time copy of the canonical" >&2
echo "deploy artifacts. Run the cp commands above to bring them back in sync." >&2
exit 1
