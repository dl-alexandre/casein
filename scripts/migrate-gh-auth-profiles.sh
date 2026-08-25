#!/usr/bin/env bash
#
# Split a multi-account GitHub CLI config into per-principal Casein auth
# profiles.
#
# The host-global ~/.config/gh can hold several accounts at once, but `gh`
# acts as exactly one of them — whichever `user:` was set last. Every Casein
# agent that ran `gh` without GH_CONFIG_DIR therefore pushed, opened PRs, and
# commented on issues as that one account, regardless of whose workspace it
# was in. This script gives each account its own config dir under the same
# auth-profile tree Claude and Codex already use:
#
#   ~/.casein/agent-auth/profiles/<principal>/gh/hosts.yml
#
# Run --plan first (the default). It prints the mapping it would apply and
# changes nothing. Nothing is destructive until --apply, and the global config
# is only retired by an explicit --retire-global.
#
# Usage:
#   scripts/migrate-gh-auth-profiles.sh                       # plan
#   scripts/migrate-gh-auth-profiles.sh --map dl-alexandre=dalexandre ... --apply
#   scripts/migrate-gh-auth-profiles.sh --retire-global --apply
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"

GH_GLOBAL="${GH_GLOBAL_CONFIG_DIR:-${HOME}/.config/gh}"
APPLY=0
RETIRE_GLOBAL=0
declare -A MAPPING=()
declare -a EXTRA_SOURCES=()

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --plan) APPLY=0; shift ;;
    --retire-global) RETIRE_GLOBAL=1; shift ;;
    --map)
      [[ -n "${2:-}" ]] || { echo "error: --map needs <gh-login>=<principal>" >&2; exit 64; }
      MAPPING["${2%%=*}"]="${2#*=}"
      shift 2
      ;;
    --source)
      [[ -d "${2:-}" ]] || { echo "error: --source needs an existing gh config dir" >&2; exit 64; }
      EXTRA_SOURCES+=("$2")
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ ! -f "${GH_GLOBAL}/hosts.yml" ]]; then
  echo "error: no hosts.yml under ${GH_GLOBAL}" >&2
  exit 1
fi

# Accounts present in a gh config dir, one login per line.
gh_logins() {
  GH_HOSTS="$1/hosts.yml" python3 - <<'PY'
import os, re, sys

text = open(os.environ["GH_HOSTS"], encoding="utf-8").read()
in_users = False
users_indent = None
for line in text.splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip())
    if re.match(r"^\s*users:\s*$", line):
        in_users, users_indent = True, indent
        continue
    if in_users:
        if indent <= users_indent:
            in_users = False
            continue
        m = re.match(r"^\s*([A-Za-z0-9][A-Za-z0-9-]*):\s*$", line)
        if m and indent == users_indent + 4:
            print(m.group(1))
PY
}

# Existing Casein principals (profile dirs), one per line.
principals() {
  local root
  root="$(agent_auth_profile_root)/profiles"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

# Suggest a principal for a GitHub login. Deliberately conservative: it only
# offers a match it can justify, and prints "?" otherwise, because guessing
# wrong here hands one person's GitHub account to another.
suggest_principal() {
  local login="$1" normalized candidate
  normalized="$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"

  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    local cnorm
    cnorm="$(printf '%s' "$candidate" | tr -cd '[:alnum:]')"
    if [[ "$normalized" == "$cnorm" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(principals)

  printf '?\n'
}

# Write a single-account hosts.yml for one login, preserving that account's
# entry verbatim (token included) and pinning `user:` to it.
extract_account() {
  local src="$1" login="$2" dest="$3"
  GH_HOSTS="${src}/hosts.yml" GH_LOGIN="$login" GH_DEST="$dest" python3 - <<'PY'
import os, re

hosts = open(os.environ["GH_HOSTS"], encoding="utf-8").read().splitlines()
login = os.environ["GH_LOGIN"]
dest = os.environ["GH_DEST"]

# Collect the account's own block plus host-level scalars worth carrying.
block, in_users, users_indent, capture, capture_indent = [], False, None, False, None
git_protocol = "https"

for line in hosts:
    if not line.strip():
        continue
    indent = len(line) - len(line.lstrip())
    if re.match(r"^\s*users:\s*$", line):
        in_users, users_indent = True, indent
        continue
    if in_users:
        if indent <= users_indent:
            in_users, capture = False, False
        else:
            m = re.match(r"^\s*([A-Za-z0-9][A-Za-z0-9-]*):\s*$", line)
            if m and indent == users_indent + 4:
                capture = m.group(1) == login
                capture_indent = indent
                continue
            if capture and indent > capture_indent:
                block.append(line.strip())
                continue
    m = re.match(r"^\s*git_protocol:\s*(\S+)\s*$", line)
    if m and not in_users:
        git_protocol = m.group(1)

if not block:
    raise SystemExit(f"no entry for {login}")

oauth = next((l for l in block if l.startswith("oauth_token:")), None)

out = ["github.com:", "    users:", f"        {login}:"]
out += [f"            {l}" for l in block]
out.append(f"    git_protocol: {git_protocol}")
out.append(f"    user: {login}")
if oauth:
    out.append(f"    {oauth}")

os.makedirs(dest, mode=0o700, exist_ok=True)
path = os.path.join(dest, "hosts.yml")
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
os.chmod(path, 0o600)
print(path)
PY
}

SOURCES=("$GH_GLOBAL" "${EXTRA_SOURCES[@]}")

echo "auth root:  $(agent_auth_profile_root)"
echo "gh global:  ${GH_GLOBAL}"
echo

declare -A PLAN=()
declare -A PLAN_SOURCE=()
UNMAPPED=0

for src in "${SOURCES[@]}"; do
  [[ -f "${src}/hosts.yml" ]] || continue
  while read -r login; do
    [[ -n "$login" ]] || continue
    principal="${MAPPING[$login]:-$(suggest_principal "$login")}"
    PLAN["$login"]="$principal"
    PLAN_SOURCE["$login"]="$src"
    [[ "$principal" == "?" ]] && UNMAPPED=1
  done < <(gh_logins "$src")
done

printf '%-24s %-24s %s\n' "github login" "-> principal" "source"
for login in "${!PLAN[@]}"; do
  printf '%-24s %-24s %s\n' "$login" "${PLAN[$login]}" "${PLAN_SOURCE[$login]}"
done | sort
echo

if [[ "$UNMAPPED" -eq 1 ]]; then
  echo "error: some accounts have no principal. Map each one explicitly:" >&2
  echo "  $0 --map <github-login>=<principal> ... --apply" >&2
  echo "known principals: $(principals | tr '\n' ' ')" >&2
  exit 64
fi

if [[ "$APPLY" -ne 1 ]]; then
  echo "plan only — re-run with --apply to write these profiles"
  exit 0
fi

for login in "${!PLAN[@]}"; do
  principal="${PLAN[$login]}"
  src="${PLAN_SOURCE[$login]}"
  dest="$(agent_auth_profile_named_dir "$principal" gh)"

  if [[ -f "${dest}/hosts.yml" ]]; then
    echo "skip ${login}: ${dest}/hosts.yml already exists (remove it to re-migrate)"
    continue
  fi

  agent_auth_profile_ensure_named "$principal" gh >/dev/null
  extract_account "$src" "$login" "$dest" >/dev/null
  echo "wrote ${dest}/hosts.yml  (${login})"
done

echo
echo "verify each profile before retiring the global config:"
for login in "${!PLAN[@]}"; do
  printf '  GH_CONFIG_DIR=%s GH_TOKEN= GITHUB_TOKEN= gh auth status\n' \
    "$(agent_auth_profile_named_dir "${PLAN[$login]}" gh)"
done

if [[ "$RETIRE_GLOBAL" -eq 1 ]]; then
  # Moved aside rather than deleted: if a profile turns out to be wrong, the
  # only copy of that account's token would otherwise be gone.
  backup="${GH_GLOBAL}.retired-by-casein"
  if [[ -e "$backup" ]]; then
    echo "error: ${backup} already exists; move it away first" >&2
    exit 1
  fi
  mv "$GH_GLOBAL" "$backup"
  echo
  echo "retired ${GH_GLOBAL} -> ${backup}"
  echo "bare \`gh\` with no GH_CONFIG_DIR now fails instead of acting as an arbitrary account."
fi
