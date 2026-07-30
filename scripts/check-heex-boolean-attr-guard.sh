#!/usr/bin/env bash
#
# HEEx boolean data-/aria- attribute guard (#163).
#
# Invariant: a `data-*` or `aria-*` attribute whose *entire* interpolated
# expression is a boolean predicate (`foo?(...)` or `@flag?`) must be wrapped
# in `to_string(...)`. HEEx / Phoenix.HTML encodes bare `true` as a *valueless*
# attribute and *omits* `false`, so JS `dataset.x === "true"` is always false
# (see `preview_pane_overlay.js` + `data-snapshot-mode` before the fix).
#
# Scope is deliberately narrow — only pure predicate expressions. Expressions
# that merely *mention* a `?` name inside `if/cond/||/and` (e.g.
# `if(@open?, do: "Close", else: "Open")` for aria-label, or `@active? || nil`
# for optional attrs) are not flagged: those are not the #163 shape, and
# broadening the rule drowns it in noise (~150 fine string/int data-* attrs).
#
# Exit 0 = clean. Exit 1 = one or more unwrapped predicate attrs (printed).
#
# Scans `lib/**/*.ex` and `lib/**/*.heex` (HEEx lives in ~H sigils and templates).
# No compile step required.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

python3 - <<'PY'
import re
import sys
from pathlib import Path

# Match data-* / aria-* = { body }, body without nested `}` (covers single-line
# and the common multi-line `{\n  to_string(...)\n}` form used in this tree).
ATTR_RE = re.compile(
    r"(?P<attr>(?:data|aria)-[A-Za-z0-9_-]+)=\{(?P<body>[^}]*)\}",
    re.MULTILINE,
)

# Whole expression is a predicate assign: @flag? or @map.flag?
ASSIGN_PRED = re.compile(
    r"^@[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\?\s*$"
)

# Whole expression is a predicate call: foo?(...), Mod.foo?(...), a.b?(...)
# Allow nested parens inside args via a balanced-paren check below.
CALL_PRED_HEAD = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\?\s*\("
)


def is_pure_predicate(body: str) -> bool:
    expr = " ".join(body.strip().split())
    if not expr:
        return False
    # Correct encoding — leave alone even if the inner call ends in ?.
    if expr.startswith("to_string("):
        return False
    if ASSIGN_PRED.match(expr):
        return True
    if not CALL_PRED_HEAD.match(expr):
        return False
    # Require the call to be the whole expression (balanced parens to the end).
    depth = 0
    started = False
    for i, ch in enumerate(expr):
        if ch == "(":
            depth += 1
            started = True
        elif ch == ")":
            depth -= 1
            if depth < 0:
                return False
            if depth == 0 and started:
                return i == len(expr) - 1
    return False


violations = []
for path in sorted(list(Path("lib").rglob("*.ex")) + list(Path("lib").rglob("*.heex"))):
    try:
        text = path.read_text(errors="replace")
    except OSError as exc:
        print(f">>> check-heex-boolean-attr-guard: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(1)

    for m in ATTR_RE.finditer(text):
        body = m.group("body")
        if not is_pure_predicate(body):
            continue
        line = text.count("\n", 0, m.start()) + 1
        snippet = " ".join(body.strip().split())
        violations.append((str(path), line, m.group("attr"), snippet))

if violations:
    print("")
    for path, line, attr, snippet in violations:
        print(f"{path}:{line}: {attr}={{{snippet}}}")
        print("    unwrapped boolean predicate — HEEx encodes true as valueless and omits false.")
        print(f"    wrap: {attr}={{to_string({snippet})}}")
    print("")
    print(
        f">>> check-heex-boolean-attr-guard: {len(violations)} unwrapped boolean "
        "data-/aria- predicate attribute(s)."
    )
    print(">>> Wrap the expression in to_string/1 so JS dataset reads === \"true\" work (#163).")
    sys.exit(1)

print(">>> check-heex-boolean-attr-guard: no unwrapped boolean data-/aria- predicate attrs.")
sys.exit(0)
PY
