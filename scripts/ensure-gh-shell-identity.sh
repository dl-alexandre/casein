#!/usr/bin/env bash
#
# Replace the path-keyed GH_CONFIG_DIR hook in ~/.bashrc with a
# principal-keyed one.
#
# The original hook ran on every prompt and picked a GitHub identity from $PWD:
#
#   /data/workspaces/dalexandre*) export GH_CONFIG_DIR=~/.config/gh-dalexandre
#   *)                            unset GH_CONFIG_DIR
#
# Two problems. It ties a GitHub account to a *directory* rather than a person,
# so anyone working under that path acts as dl-alexandre. And because it runs
# on every prompt, its `unset` branch clobbers the GH_CONFIG_DIR that
# launch-casein-agent.sh exports — an agent pane outside that path loses its
# identity at the first prompt and silently falls back to the host-global
# config.
#
# The replacement keys on CASEIN_ACTOR (the principal Casein stamps into the
# pane) and never unsets an identity that something else deliberately set.
#
# Usage:
#   scripts/ensure-gh-shell-identity.sh            # show current state
#   scripts/ensure-gh-shell-identity.sh --apply    # rewrite the hook
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"

BASHRC="${CASEIN_BASHRC:-${HOME}/.bashrc}"
BEGIN="# >>> casein gh identity >>>"
END="# <<< casein gh identity <<<"
APPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ -f "$BASHRC" ]] || { echo "error: no ${BASHRC}" >&2; exit 1; }

if grep -qF "$BEGIN" "$BASHRC"; then
  echo "already installed in ${BASHRC}"
  exit 0
fi

legacy_present=0
if grep -q "__gh_profile_for_dir" "$BASHRC"; then
  legacy_present=1
  echo "found the legacy path-keyed hook (__gh_profile_for_dir) in ${BASHRC}"
else
  echo "no legacy hook found in ${BASHRC}"
fi

read -r -d '' BLOCK <<EOF || true
${BEGIN}
# Managed by scripts/ensure-gh-shell-identity.sh. GitHub identity follows the
# principal Casein resolved for this pane (CASEIN_ACTOR), not the directory the
# shell happens to be sitting in. Deliberately not a PROMPT_COMMAND hook: the
# old one re-evaluated on every prompt and unset the identity that
# launch-casein-agent.sh had just exported.
if [ -n "\${CASEIN_ACTOR:-}" ] && [ -z "\${GH_CONFIG_DIR:-}" ]; then
  __casein_gh_profile="\${CASEIN_AGENT_AUTH_ROOT:-\${HOME}/.casein/agent-auth}/profiles/\${CASEIN_ACTOR}/gh"
  if [ -f "\${__casein_gh_profile}/hosts.yml" ]; then
    export GH_CONFIG_DIR="\${__casein_gh_profile}"
  fi
  unset __casein_gh_profile
fi
${END}
EOF

if [[ "$APPLY" -ne 1 ]]; then
  echo
  echo "would append to ${BASHRC}:"
  echo
  printf '%s\n' "$BLOCK"
  if [[ "$legacy_present" -eq 1 ]]; then
    echo
    echo "and would comment out the legacy __gh_profile_for_dir hook."
  fi
  echo
  echo "plan only — re-run with --apply"
  exit 0
fi

cp -a "$BASHRC" "${BASHRC}.casein-backup"

if [[ "$legacy_present" -eq 1 ]]; then
  # Commented rather than deleted: the operator may have edited it, and a
  # commented block is reviewable in a diff.
  python3 - "$BASHRC" <<'PY'
import re, sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)

# Shell blocks do not nest with braces alone: the legacy hook is a function
# (`{` / `}`) *and* an `if ... fi` guard around PROMPT_COMMAND. Commenting on
# brace depth only would leave that `fi` orphaned and break every new shell.
OPENERS = (r"\bif\b", r"\bcase\b", r"\bwhile\b", r"\buntil\b", r"\bfor\b")
CLOSERS = {"fi": r"\bif\b", "esac": r"\bcase\b", "done": r"\b(while|until|for)\b"}

out, depth, active, touched = [], 0, False, False

for line in lines:
    stripped = line.strip()

    if not active and "__gh_profile_for_dir" in line:
        active, depth = True, 0

    if active:
        touched = True
        depth += line.count("{") - line.count("}")
        for pattern in OPENERS:
            # `elif`/`;;` do not open a new block; a leading keyword does.
            if re.match(r"^\s*(%s)\b" % pattern.strip("\\b"), line):
                depth += 1
        for closer in CLOSERS:
            if re.match(r"^\s*%s\b" % closer, stripped):
                depth -= 1

        out.append(("# [casein] retired path-keyed gh hook: " + line) if stripped else line)

        if depth <= 0:
            active = False
    else:
        out.append(line)

if touched:
    open(path, "w", encoding="utf-8").writelines(out)
PY
  echo "commented out the legacy hook"
fi

printf '\n%s\n' "$BLOCK" >>"$BASHRC"
echo "installed principal-keyed gh identity block in ${BASHRC}"
echo "backup: ${BASHRC}.casein-backup"
echo
echo "open a new shell, then check: echo \$CASEIN_ACTOR; gh auth status"
