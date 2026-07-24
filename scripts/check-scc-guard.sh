#!/usr/bin/env bash
#
# Preview-extraction SCC guard. Locks in the domain extraction (PRs #301–#303):
# the preview domain was pulled OUT of the primary 133-node runtime cycle (now
# 73), so preview and core modules must never again share a strongly-connected
# component.
#
# Invariant enforced: no `mix xref` cycle may contain BOTH a preview-domain file
# and a non-preview file. A mixed cycle means a preview module reacquired a
# compile/runtime edge into core (or vice-versa) that re-entangles the two — the
# exact regression this guard exists to catch. Typically that is a preview
# module referencing DevIDE.Terminals/Workspaces/Runtimes directly instead of
# through its injected Previews.Deps.* seam.
#
# KNOWN INTERNAL CYCLES (tracked debt, NOT flagged): the preview domain still
# forms its own ~41-node all-preview cycle via intra-domain back-edges
# (previews/commands -> PreviewTools, previews/{pane,control} -> PreviewPanes).
# That is confined to one domain, invisible to core, and is a deliberate
# follow-up — an all-preview cycle is fine; a mixed one is not.
#
# Also reported (soft canaries, non-fatal): the core runtime cycle size and the
# web-tree cycle size, so a silent creep is visible.
#
# Exit 0 = clean. Exit 1 = a mixed preview/core cycle (printed), or xref failed.
#
# Prerequisite: a compiled _build (run after `mix compile`). Uses $MIX if set
# (e.g. the mise-wrapped invocation from pre-push-check.sh), else `mix`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

# $MIX may be a multi-word command (e.g. "mise exec … -- mix"); split on words.
read -ra MIX_CMD <<< "${MIX:-mix}"

# Preview-DOMAIN files. The injected impls (lib/casein/{terminals,workspaces,
# runtimes}/preview_deps.ex, lib/casein/panes/preview_deps.ex) are CORE-side
# adapters and are deliberately NOT matched — they may live in the core cycle.
PREVIEW_RE='lib/casein/previews/|lib/casein/previews[.]ex|lib/casein/preview_panes([.]ex|/)|lib/casein/preview_control([.]ex|/)|lib/casein/agents/preview_tools([.]ex|/)|lib/casein/panes/preview[.]ex'

cycles="$(mktemp)"
trap 'rm -f "$cycles"' EXIT

if ! "${MIX_CMD[@]}" xref graph --format cycles >"$cycles" 2>/dev/null; then
  echo ">>> check-scc-guard: 'mix xref graph --format cycles' failed (compile the tree first)." >&2
  exit 1
fi

# Parse cycle blocks; flag any cycle mixing preview and non-preview members.
awk -v preview_re="$PREVIEW_RE" '
  function flush() {
    if (len == "") return
    if (has_preview && has_core) {
      violations++
      printf "\nMIXED cycle of length %s re-entangles preview and core:\n", len
      for (i = 1; i <= n; i++) {
        tag = (mem[i] ~ preview_re) ? "preview" : "core   "
        printf "    [%s] %s\n", tag, mem[i]
      }
    }
    if (len + 0 >= 30 && !has_preview) {
      # core/web canary: largest non-preview cycles
      printf "core-cycle size %s\n", len > "/dev/stderr"
    }
  }
  /^Cycle of length/ {
    flush()
    len = $4; sub(/[^0-9].*/, "", len)
    has_preview = 0; has_core = 0; n = 0
    next
  }
  /^    lib\// {
    p = $1
    mem[++n] = p
    if (p ~ preview_re) has_preview = 1; else has_core = 1
    next
  }
  END { flush() }
' "$cycles"

mixed="$(awk -v preview_re="$PREVIEW_RE" '
  function eval() {
    if (len != "" && has_preview && has_core) c++
  }
  /^Cycle of length/ { eval(); len=$4; sub(/[^0-9].*/,"",len); has_preview=0; has_core=0; next }
  /^    lib\// { if ($1 ~ preview_re) has_preview=1; else has_core=1; next }
  END { eval(); print c+0 }
' "$cycles")"

if [[ "$mixed" -gt 0 ]]; then
  echo ""
  echo ">>> check-scc-guard: ${mixed} mixed preview/core cycle(s) — preview has re-entangled with core."
  echo ">>> Route the offending reference through the Previews.Deps.* seam (see PR #303)."
  exit 1
fi

echo ">>> check-scc-guard: preview and core remain in separate SCCs (no mixed cycle)."
exit 0
