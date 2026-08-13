#!/usr/bin/env bash
#
# npm install-path audit guard (#929).
#
# Install calls keep --no-audit for speed/determinism. The scan is
# scripts/npm-audit.sh (or an inline `npm audit --... --audit-level=high`).
# A new `npm ci` / `npm install` against assets/ or priv/scripts/ that does
# not also run that scan is a gate failure — briefs die with the pane;
# this script is the durable constraint.
#
# Exit 0 = every product-tree install site scans. Exit 1 = a site skipped it.

set -euo pipefail

ROOT="${NPM_AUDIT_GUARD_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${ROOT}" || exit 1

violations=0

fail() {
  printf '>>> check-npm-audit-guard: %s\n' "$*" >&2
  violations=$((violations + 1))
}

if [[ ! -f "${ROOT}/scripts/npm-audit.sh" ]]; then
  fail "missing scripts/npm-audit.sh"
  exit 1
fi

if ! grep -q -- '--audit-level=high' "${ROOT}/scripts/npm-audit.sh"; then
  fail "scripts/npm-audit.sh must pin --audit-level=high"
fi

if grep -qE -- '--audit-level=(low|moderate|info)' "${ROOT}/scripts/npm-audit.sh"; then
  fail "scripts/npm-audit.sh must not lower the audit level below high"
fi

scans() {
  local file="$1"
  grep -qE 'npm-audit\.sh|[[:space:]]npm[[:space:]]+audit[[:space:]]|npm[[:space:]]+--prefix[[:space:]][^[:space:]]+[[:space:]]+audit|audit --package-lock-only --audit-level=high' "${file}"
}

is_comment_or_doc() {
  local line="$1"
  [[ "${line}" =~ ^[[:space:]]*# ]] || [[ "${line}" =~ ^[[:space:]]*// ]]
}

# Product-tree install: npm ci / npm install, not `npm install -g`.
is_product_install() {
  local line="$1"
  # log/echo/printf mention install; they do not run it.
  if [[ "${line}" =~ (log|echo|printf|note)\  ]]; then
    return 1
  fi
  if [[ "${line}" =~ npm[[:space:]]+install[[:space:]]+-g ]] ||
    [[ "${line}" =~ npm[[:space:]]+install[[:space:]]+\"\$\{missing ]]; then
    return 1
  fi
  [[ "${line}" =~ npm[[:space:]]+(ci|install) ]] ||
    [[ "${line}" =~ npm[[:space:]]+--prefix[[:space:]][^[:space:]]+[[:space:]]+ci ]] ||
    [[ "${line}" =~ \$NpmPath[[:space:]]+ci ]]
}

scan_roots=(mix.exs Dockerfile)
[[ -d scripts ]] && scan_roots+=(scripts)
[[ -d .github/workflows ]] && scan_roots+=(.github/workflows)

declare -A seen=()

while IFS= read -r hit; do
  [ -z "${hit}" ] && continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest#*:}"

  case "${file}" in
    scripts/npm-audit.sh | scripts/check-npm-audit-guard.sh) continue ;;
  esac

  is_comment_or_doc "${line}" && continue
  is_product_install "${line}" || continue

  [[ -n "${seen[$file]+x}" ]] && continue
  seen["${file}"]=1

  if ! scans "${file}"; then
    fail "${file} installs npm deps but never runs npm-audit.sh or npm audit"
  fi
done < <(
  grep -RIn --include='*.exs' --include='*.sh' --include='*.ps1' \
    --include='*.yml' --include='Dockerfile' \
    -E 'npm[[:space:]]+(ci|install)|npm[[:space:]]+--prefix' \
    "${scan_roots[@]}" 2>/dev/null || true
)

if [[ "${violations}" -gt 0 ]]; then
  printf '\n>>> check-npm-audit-guard: %s violation(s). See issue #929.\n' "${violations}" >&2
  exit 1
fi

echo ">>> check-npm-audit-guard: ${#seen[@]} install site(s) run npm audit."
exit 0
