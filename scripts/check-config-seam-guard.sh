#!/usr/bin/env bash
#
# Config-seam compile-edge guard. Module-literal defaults in
# `Application.get_env(:casein, :key, SomeModule)` create a compile-time edge
# from the caller to SomeModule. That is how xref cycles got re-entangled
# (#347/#348): a cross-subtree default re-introduced a compile edge that sat
# inside a reported cycle.
#
# Invariant enforced: a module-literal get_env/3 default whose module lives in a
# *different* subtree from the caller must NOT appear as an edge inside a
# `mix xref` cycle. Same-subtree defaults (e.g. Casein.Push → LogProvider) and
# cross-subtree defaults that are *not* on a cycle are fine.
#
# Soft canaries (non-fatal, stderr): every cross-subtree module-literal default,
# so silent creep is visible without failing the gate on the 15+ legitimate
# seams already in the tree.
#
# Exit 0 = clean (no cross-subtree default lands inside a cycle).
# Exit 1 = violation (printed), or xref failed.
#
# Prerequisite: a compiled _build (run after `mix compile`). Uses $MIX if set
# (e.g. the mise-wrapped invocation from pre-push-check.sh), else `mix`.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

# $MIX may be a multi-word command (e.g. "mise exec … -- mix"); split on words.
read -ra MIX_CMD <<< "${MIX:-mix}"

cycles="$(mktemp)"
seams="$(mktemp)"
trap 'rm -f "$cycles" "$seams"' EXIT

if ! "${MIX_CMD[@]}" xref graph --format cycles >"$cycles" 2>/dev/null; then
  echo ">>> check-config-seam-guard: 'mix xref graph --format cycles' failed (compile the tree first)." >&2
  exit 1
fi

# Collect candidate call sites: Application.get_env(:casein, :key, ModuleLiteral)
# Also accepts short aliases and dotted module paths. Skips non-module defaults
# (atoms, numbers, strings, lists, maps, __MODULE__).
grep -RIn --include='*.ex' -E 'Application\.get_env\(:casein,' lib \
  | grep -E 'Application\.get_env\(:casein, :[A-Za-z0-9_]+, [A-Z][A-Za-z0-9_.]*' \
  | grep -v '__MODULE__' \
  >"$seams" || true

if [[ ! -s "$seams" ]]; then
  echo ">>> check-config-seam-guard: no module-literal get_env defaults found."
  exit 0
fi

# Analyze seams against cycles. Python keeps alias/subtree/cycle logic readable.
python3 - "$cycles" "$seams" <<'PY'
import re
import sys
from collections import defaultdict
from pathlib import Path

cycles_path, seams_path = sys.argv[1], sys.argv[2]
root = Path.cwd()

# --- parse xref cycles: list of sets of file paths (as printed by mix xref) ---
cycles = []
current = None
for line in Path(cycles_path).read_text(errors="replace").splitlines():
    if line.startswith("Cycle of length"):
        if current:
            cycles.append(current)
        current = set()
        continue
    m = re.match(r"^\s{4}(lib/\S+)", line)
    if m and current is not None:
        current.add(m.group(1))
if current:
    cycles.append(current)

# --- helpers ---

def module_to_candidates(mod: str):
    """Map Elixir module name to likely source paths under lib/."""
    if not mod or not mod[0].isupper():
        return []
    # Drop leading "Elixir." if present
    mod = mod.removeprefix("Elixir.")
    parts = mod.split(".")
    snake = [re.sub(r"(?<!^)(?=[A-Z])", "_", p).lower() for p in parts]
    # Conventional layouts: lib/foo/bar.ex, lib/foo/bar/baz.ex, ...
    candidates = []
    # full path under lib/
    candidates.append(Path("lib") / "/".join(snake[:-1]) / f"{snake[-1]}.ex" if len(snake) > 1
                      else Path("lib") / f"{snake[0]}.ex")
    # also try nesting last segment as dir index? skip
    return [str(c) for c in candidates]


def find_module_file(mod: str) -> str | None:
    """Locate defmodule Mod in the tree; fall back to path convention."""
    needle = f"defmodule {mod} "
    needle2 = f"defmodule {mod}\n"
    for path in Path("lib").rglob("*.ex"):
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        if f"defmodule {mod} " in text or f"defmodule {mod}\n" in text or f"defmodule {mod} do" in text:
            return str(path)
    for cand in module_to_candidates(mod):
        if Path(cand).is_file():
            return cand
    return None


def parse_aliases(file_path: str) -> dict[str, str]:
    """Best-effort alias map short_name -> full module for one source file."""
    aliases: dict[str, str] = {}
    try:
        text = Path(file_path).read_text(errors="replace")
    except OSError:
        return aliases

    # alias Foo.Bar
    # alias Foo.Bar, as: Baz
    # alias Foo.{Bar, Baz}
    for m in re.finditer(
        r"alias\s+([A-Z][A-Za-z0-9_.]*)(?:\s*,\s*as:\s*([A-Z][A-Za-z0-9_]*))?",
        text,
    ):
        full, as_name = m.group(1), m.group(2)
        short = as_name or full.rsplit(".", 1)[-1]
        aliases[short] = full

    for m in re.finditer(r"alias\s+([A-Z][A-Za-z0-9_.]*)\.\{([^}]+)\}", text):
        prefix, body = m.group(1), m.group(2)
        for part in body.split(","):
            part = part.strip()
            if not part:
                continue
            # support nested Foo.Bar inside braces rarely; keep simple
            name = part.split(".")[-1].strip()
            full = f"{prefix}.{part.strip()}"
            aliases[name] = full

    return aliases


def resolve_module(default_tok: str, caller_file: str) -> str | None:
    """Resolve a get_env default token to a fully-qualified module name."""
    if "." in default_tok:
        return default_tok  # already qualified-ish
    aliases = parse_aliases(caller_file)
    if default_tok in aliases:
        return aliases[default_tok]
    # Same-file nested module? Module.Child
    # Fall back: search defmodule ending with .DefaultTok or bare DefaultTok
    bare = find_module_file(default_tok)
    if bare:
        # recover module name from defmodule line
        text = Path(bare).read_text(errors="replace")
        m = re.search(rf"defmodule\s+([A-Z][A-Za-z0-9_.]*{re.escape(default_tok)})\b", text)
        if m:
            return m.group(1)
        return default_tok
    return None


def subtree_of(path: str) -> str:
    """
    Domain subtree under lib/.

    lib/casein/push.ex            -> casein/push
    lib/casein/push/log_provider  -> casein/push
    lib/casein/terminals/tmux.ex  -> casein/terminals
    lib/casein_web/live/...       -> casein_web
    lib/preview_ctl/...           -> preview_ctl
    lib/tmux_ctl/...              -> tmux_ctl
    """
    p = path.replace("\\", "/")
    if not p.startswith("lib/"):
        return p
    parts = p[len("lib/"):].split("/")
    if not parts:
        return p
    top = parts[0]
    # Strip .ex from single-file top modules
    top_name = top[:-3] if top.endswith(".ex") else top
    if top_name in {"casein", "casein_web"} and len(parts) >= 2:
        second = parts[1]
        second_name = second[:-3] if second.endswith(".ex") else second
        return f"{top_name}/{second_name}"
    return top_name


def in_shared_cycle(a: str, b: str) -> bool:
    for cyc in cycles:
        if a in cyc and b in cyc:
            return True
    return False


# --- parse seam lines: path:line:content ---
seam_re = re.compile(
    r"^(lib/\S+\.ex):(\d+):.*Application\.get_env\(:casein,\s*(:[A-Za-z0-9_]+),\s*([A-Z][A-Za-z0-9_.]*)"
)

cross_soft = []
violations = []
skipped = []

for raw in Path(seams_path).read_text(errors="replace").splitlines():
    m = seam_re.match(raw)
    if not m:
        continue
    caller_file, line_s, key, default_tok = m.group(1), m.group(2), m.group(3), m.group(4)
    if default_tok.startswith("__"):
        continue

    full_mod = resolve_module(default_tok, caller_file)
    if not full_mod:
        skipped.append((caller_file, line_s, key, default_tok, "unresolved_module"))
        continue

    target_file = find_module_file(full_mod)
    if not target_file:
        # Try path convention only
        for cand in module_to_candidates(full_mod):
            if Path(cand).is_file():
                target_file = cand
                break
    if not target_file:
        skipped.append((caller_file, line_s, key, full_mod, "unresolved_file"))
        continue

    st_caller = subtree_of(caller_file)
    st_target = subtree_of(target_file)
    if st_caller == st_target:
        continue  # same-subtree default — intentional seam, not a hazard

    entry = {
        "caller": caller_file,
        "line": line_s,
        "key": key,
        "module": full_mod,
        "target": target_file,
        "caller_subtree": st_caller,
        "target_subtree": st_target,
    }
    if in_shared_cycle(caller_file, target_file):
        violations.append(entry)
    else:
        cross_soft.append(entry)

# Soft canaries → stderr (non-fatal), matching check-scc-guard style.
for e in cross_soft:
    print(
        f"config-seam canary: {e['caller']}:{e['line']} "
        f"get_env({e['key']}, {e['module']}) cross-subtree "
        f"{e['caller_subtree']} -> {e['target_subtree']} (not in a cycle)",
        file=sys.stderr,
    )

for s in skipped:
    print(
        f"config-seam skip: {s[0]}:{s[1]} get_env({s[2]}, {s[3]}) ({s[4]})",
        file=sys.stderr,
    )

if violations:
    print("")
    for e in violations:
        print(
            f"CYCLE-BOUND config seam: {e['caller']}:{e['line']} "
            f"Application.get_env(:casein, {e['key']}, {e['module']})\n"
            f"    caller subtree: {e['caller_subtree']} ({e['caller']})\n"
            f"    default subtree: {e['target_subtree']} ({e['target']})\n"
            f"    Both files share a mix xref cycle — this re-entangles domains (#347/#348)."
        )
    print("")
    print(f">>> check-config-seam-guard: {len(violations)} cycle-bound cross-subtree config seam(s).")
    print(">>> Move the default behind a runtime-only resolve, or inject via config without a module literal.")
    sys.exit(1)

print(
    f">>> check-config-seam-guard: no cycle-bound cross-subtree config seams "
    f"({len(cross_soft)} cross-subtree canary(ies), soft)."
)
sys.exit(0)
PY
