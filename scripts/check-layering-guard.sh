#!/usr/bin/env bash
#
# Preview directional-layering guard. Unlike the SCC and config-seam guards,
# this checks edge direction: preview-domain modules must not reference core
# terminal, workspace, or runtime modules directly. They must go through the
# Casein.Previews.Deps.* seam.
#
# This first ships as a soft canary because the current tree has known direct
# edges whose removal would widen the seam. Violations are printed but do not
# fail the gate. Once the count reaches zero, make violations fatal before
# changing the pre-push wiring.
#
# Exit 0 = xref succeeded (including when soft-canary violations were found).
# Exit 1 = xref failed or its output could not be analyzed.
#
# Prerequisite: a compiled _build (run after `mix compile`). Uses $MIX if set
# (e.g. the mise-wrapped invocation from pre-push-check.sh), else `mix`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

# $MIX may be a multi-word command (e.g. "mise exec … -- mix"); split on words.
read -ra MIX_CMD <<< "${MIX:-mix}"

graph="$(mktemp)"
trap 'rm -f "$graph"' EXIT

# Directional rules: name|source path prefix|forbidden target path prefixes|seam.
# Keep this table narrow: FilePanes and broader ports/adapters rules are out of
# scope until the preview rule has earned its keep.
RULES=(
  'preview|lib/casein/previews/|lib/casein/terminals,lib/casein/workspaces,lib/casein/runtimes|Casein.Previews.Deps.*'
)

if ! "${MIX_CMD[@]}" xref graph --format json --output "$graph" >/dev/null 2>&1; then
  echo ">>> check-layering-guard: 'mix xref graph --format json' failed (compile the tree first)." >&2
  exit 1
fi

if ! python3 - "$graph" "${RULES[@]}" <<'PY'
import json
import sys
from pathlib import Path


def matches_namespace(path, prefix):
    return path == f"{prefix}.ex" or path.startswith(f"{prefix}/")


try:
    graph = json.loads(Path(sys.argv[1]).read_text(errors="replace"))
except (OSError, json.JSONDecodeError) as error:
    print(f">>> check-layering-guard: could not read mix xref JSON: {error}", file=sys.stderr)
    sys.exit(1)

violations = []

for raw_rule in sys.argv[2:]:
    name, source_prefix, target_csv, seam = raw_rule.split("|", 3)
    target_prefixes = target_csv.split(",")

    for source, sinks in graph.items():
        if not source.startswith(source_prefix):
            continue

        # The seam is preview-owned composition code. Referencing core is its
        # job, so exclude the whole Deps namespace by construction rather than
        # maintaining an exception for each adapter edge.
        if source == "lib/casein/previews/deps.ex" or source.startswith(
            "lib/casein/previews/deps/"
        ):
            continue

        for target, label in sinks.items():
            if any(matches_namespace(target, prefix) for prefix in target_prefixes):
                violations.append((name, source, target, label, seam))

violations.sort()

for name, source, target, label, seam in violations:
    print(
        f"layering canary: [{name}] {source} -> {target} ({label}); route via {seam}",
        file=sys.stderr,
    )

if violations:
    print(
        f">>> check-layering-guard: {len(violations)} direct preview/core "
        "layering violation(s) (soft canary)."
    )
    print(">>> Route these references through Casein.Previews.Deps.* before making this guard fatal.")
else:
    print(">>> check-layering-guard: no direct preview/core layering violations.")

sys.exit(0)
PY
then
  exit 1
fi

exit 0
