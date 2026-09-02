#!/usr/bin/env bash
#
# hex-audit.sh — `mix hex.audit` with a narrow, documented allowlist.
#
# The audit's job is to catch a dependency being retired upstream. That is
# worth failing a gate over *when there is somewhere to go*. It is not worth
# blocking every deploy when the replacement release is itself broken.
#
# So: run the real audit, and tolerate ONLY the exact package-version pairs
# listed below. Any other retired package still fails, and a listed package at
# a different version fails too — an allowlist entry pins the version it was
# reasoned about, so a later bump cannot inherit the exemption silently.
#
# Each entry must carry the reason and the condition for removing it.
#
# Exit codes:
#   0  no retirements, or only allowlisted ones (loud warning)
#   1  a retirement outside the allowlist, or the audit itself failed to run
set -euo pipefail

# "<package> <version>" — keep the justification with the entry.
#
# erlexec 2.3.4: on 2026-09-02 upstream retired every 2.3.x release and
# published 2.4.0, whose hex tarball omits the include/ directory entirely.
# src/exec.erl does -include("exec.hrl"), so 2.4.0 does not compile for anyone
# ("undefined macro 'FMT/2'"). There is no non-retired version that builds.
# REMOVE once a working erlexec (2.4.1+) is on hex and mix.exs is bumped to it.
ALLOWLIST=(
  "erlexec 2.3.4"
)

allowed() {
  local entry
  for entry in "${ALLOWLIST[@]}"; do
    [[ "$1" == "$entry" ]] && return 0
  done
  return 1
}

output=""
status=0
output="$(mix hex.audit 2>&1)" || status=$?

printf '%s\n' "$output"

if [[ "$status" -eq 0 ]]; then
  exit 0
fi

# Retired lines look like:  "  erlexec 2.3.4 - (deprecated) Deprecated"
# Anything the audit reports that we cannot parse as a retirement is a real
# failure (the task itself broke), never a silent pass.
mapfile -t retired < <(
  printf '%s\n' "$output" |
    sed -n 's/^[[:space:]]\{1,\}\([A-Za-z0-9_]\{1,\}\)[[:space:]]\{1,\}\([0-9][^[:space:]]*\)[[:space:]]*-.*$/\1 \2/p'
)

if [[ "${#retired[@]}" -eq 0 ]]; then
  echo "error: mix hex.audit failed and reported no parseable retirement" >&2
  echo "       treating as a real failure rather than assuming it is benign" >&2
  exit 1
fi

blocked=()
excused=()
for pkg in "${retired[@]}"; do
  if allowed "$pkg"; then
    excused+=("$pkg")
  else
    blocked+=("$pkg")
  fi
done

if [[ "${#blocked[@]}" -gt 0 ]]; then
  echo "error: retired dependencies outside the hex-audit allowlist:" >&2
  printf '       %s\n' "${blocked[@]}" >&2
  echo "       upgrade them, or add an entry (with a reason) to scripts/hex-audit.sh" >&2
  exit 1
fi

echo "warn: tolerating allowlisted retired dependencies — see scripts/hex-audit.sh" >&2
printf '      %s\n' "${excused[@]}" >&2
exit 0
