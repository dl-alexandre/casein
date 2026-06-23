#!/usr/bin/env bash
#
# Doc-citation guard. Keeps the code-derived docs (docs/subsystems/*, docs/reference/*)
# from rotting: every `CamelCase.Dotted` module/type name cited in backticks must
# resolve to a real `defmodule` in the tree (lib/, dev_ide_core/, test/support/),
# or be a registered process name / external module listed in the allowlist.
#
# Exit 0 = all citations resolve. Exit 1 = unresolved citations (printed).
#
# Why: a rename or removal that orphans a doc reference is invisible until someone
# follows a dead link. This catches it at pre-push (the real gate; CI is billing-blocked).
#
# Runs read-only; safe in a dirty worktree. Verifies against the WORKING TREE — run it
# on a clean checkout (or after the relevant code change is in the tree) for a true result.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

DOC_GLOBS=(docs/subsystems docs/reference)
ALLOWLIST="docs/.citation-allowlist"

# External / stdlib namespaces that legitimately have no defmodule in this tree.
SKIP_RE='^(GenServer|Task|System|File|Port|Req|String|DynamicSupervisor|Mix|Ghostty|WorkspaceLeader|Phoenix|Ecto|Plug|Logger|Enum|Map|Keyword|Registry|Supervisor|Application|Process|Node|Jason|Bandit|Swoosh|Bypass|ExUnit|Elixir|IO|Kernel|Stream|DateTime|NaiveDateTime|URI|Base|Float|Integer)\.'

real="$(mktemp)"; cited="$(mktemp)"
trap 'rm -f "$real" "$cited"' EXIT

grep -rhoE '^[[:space:]]*defmodule[[:space:]]+[A-Za-z0-9_.]+' lib dev_ide_core test/support --include='*.ex' 2>/dev/null \
  | sed -E 's/.*defmodule[[:space:]]+//' | sort -u > "$real"

# Cited fully-capitalised dotted tokens inside backticks (each segment starts uppercase) -> excludes `.func` tails.
for d in "${DOC_GLOBS[@]}"; do
  [ -d "$d" ] && grep -rhoE '`([A-Z][A-Za-z0-9_]*)(\.[A-Z][A-Za-z0-9_]*)+`' "$d" 2>/dev/null
done | tr -d '`' | sort -u > "$cited"

resolves() {
  local m="$1"
  echo "$m" | grep -qE "$SKIP_RE" && return 0
  grep -qE "(^|\.)${m//./\\.}$" "$real" && return 0           # exact or suffix match against a real defmodule
  [ -f "$ALLOWLIST" ] && grep -qxF "$m" "$ALLOWLIST" && return 0
  return 1
}

miss=0
while read -r m; do
  [ -z "$m" ] && continue
  resolves "$m" || { echo "  UNRESOLVED doc citation: $m"; miss=$((miss+1)); }
done < "$cited"

if [ "$miss" -gt 0 ]; then
  echo ">>> check-doc-citations: $miss unresolved citation(s) in docs/subsystems|reference." >&2
  echo ">>> Fix the doc, or (if it is a process name / external module) add it to ${ALLOWLIST}." >&2
  exit 1
fi
echo ">>> check-doc-citations: all $(wc -l < "$cited") cited modules resolve."
exit 0
