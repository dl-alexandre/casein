#!/usr/bin/env bash
#
# Claim the next queued GitHub issue for a workspace and print it as a runner
# brief. The cold-queue half of the async fleet: issues schedule work, this is
# how a runner takes one off the queue without a human in the loop.
#
# See the claim protocol in AGENTS.md — this script is that protocol, executed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: claim-next-issue.sh [options]

Claim the next `queue/ready` issue for a workspace: swap its label to
`queue/claimed`, leave a claim comment, and print a structured brief.

Options:
  --workspace <name>   workspace label suffix (default: resolved from CASEIN_WORKSPACE_NAME)
  --issue <N>          claim this specific issue instead of the next one
  --list               list claimable issues and exit, claiming nothing
  --dry-run            print the brief for the issue that would be claimed, claiming nothing
  --format brief|json  output shape (default: brief)
  --owner <id>         claimant identity (default: CASEIN_CLAIM_OWNER, else <host>:<pane>)
  --repo <owner/repo>  target repository (default: resolved by gh from the cwd)
  -h, --help           this text

Exit codes:
  0  claimed (or already held by this owner — the call is idempotent)
  1  usage or environment error
  2  a GitHub call failed
  3  candidates existed but every claim was lost to another runner
  4  nothing claimable for this workspace
  5  the requested issue is claimed by someone else

Idempotency: a runner that already holds an open claim in this workspace gets
that issue back rather than consuming a second one. Claiming is a
compare-and-swap on the `queue/ready` label — GitHub returns 404 to whoever
loses — so two runners racing the same issue cannot both win.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

WORKSPACE=""
ISSUE=""
FORMAT="brief"
OWNER="${CASEIN_CLAIM_OWNER:-}"
REPO=""
LIST_ONLY=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --issue)
      ISSUE="${2:-}"
      shift 2
      ;;
    --format)
      FORMAT="${2:-}"
      shift 2
      ;;
    --owner)
      OWNER="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option '$1' (see --help)" ;;
  esac
done

case "$FORMAT" in
  brief | json) ;;
  *) die "unknown --format '${FORMAT}' (expected brief or json)" ;;
esac

if [[ -n "$ISSUE" && ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  die "--issue expects a number, got '${ISSUE}'"
fi

command -v gh >/dev/null 2>&1 || die "gh is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"

# The claimant identity has to survive across calls, or the idempotency check
# cannot recognise this runner's own claim. A tmux pane id is the most stable
# handle a Casein worker has: it outlives the shell but dies with the pane, so a
# claim is released for reclaim exactly when the runner is really gone.
if [[ -z "$OWNER" ]]; then
  OWNER="$(hostname -s 2>/dev/null || hostname)"
  OWNER="${OWNER}:${TMUX_PANE:-${CASEIN_CALLER_PANE:-no-pane}}"
fi

gh_json() {
  gh "$@" 2>/dev/null || {
    echo "error: gh $1 failed — check auth (gh auth status) and network" >&2
    exit 2
  }
}

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [[ -n "$REPO" ]] || die "could not resolve the repository — pass --repo <owner/repo>"
fi

# Resolve `workspace/<name>` by asking the repo which such labels exist, rather
# than guessing: CASEIN_WORKSPACE_NAME is `<owner>-<workspace>` (dalexandre-devide)
# while the label is the bare workspace, and a guess that is wrong by one prefix
# silently returns an empty queue — indistinguishable from "no work", which is
# the worst possible failure for an unattended runner.
#
# The repo name is the last candidate because the workspace name can outlive a
# rename: this checkout is still called `dalexandre-devide` after the project
# became `casein`, so the derived `workspace/devide` stopped existing while
# `workspace/casein` did. Falling back to the repo name keeps a renamed project
# resolvable without pinning CASEIN_QUEUE_WORKSPACE on every runner.
claim_resolve_workspace_label() {
  local explicit="$1"
  local labels candidates candidate

  labels="$(gh_json label list --repo "$REPO" --limit 200 --json name -q '.[].name')"

  if [[ -n "$explicit" ]]; then
    explicit="${explicit#workspace/}"
    if printf '%s\n' "$labels" | grep -qx "workspace/${explicit}"; then
      printf 'workspace/%s\n' "$explicit"
      return 0
    fi
    die "no label 'workspace/${explicit}' in ${REPO} — create it, or pass an existing one"
  fi

  candidates=(
    "${CASEIN_QUEUE_WORKSPACE:-}"
    "${CASEIN_WORKSPACE_NAME:-}"
    "${CASEIN_WORKSPACE_NAME##*-}"
    "${REPO##*/}"
  )
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if printf '%s\n' "$labels" | grep -qx "workspace/${candidate}"; then
      printf 'workspace/%s\n' "$candidate"
      return 0
    fi
  done

  echo "error: could not resolve a workspace label from the environment." >&2
  echo "hint: pass --workspace <name>. Labels in ${REPO}:" >&2
  printf '%s\n' "$labels" | grep '^workspace/' | sed 's/^/  /' >&2
  exit 1
}

WORKSPACE_LABEL="$(claim_resolve_workspace_label "$WORKSPACE")"

# The marker is what makes a claim recognisable to a later call. It is an HTML
# comment so it is invisible in the issue UI but exact to match — matching on the
# prose line instead would confuse CLAIMED with RECLAIMED, and with a human's
# hand-written claim.
claim_marker() {
  printf '<!-- casein-claim: owner=%s -->' "$1"
}

claim_comment_body() {
  local number="$1"
  cat <<EOF
CLAIMED by \`${OWNER}\` at $(date -u +%FT%TZ) via \`scripts/claim-next-issue.sh\`.

Working in a fresh worktree off \`origin/master\`. Will comment the PR URL here
and close with \`queue/done\`, or hand it back as \`queue/blocked\` with what it
needs.

$(claim_marker "$OWNER")
EOF
}

issue_json() {
  gh_json issue view "$1" --repo "$REPO" \
    --json number,title,url,body,labels,createdAt,comments
}

# Render an issue as a brief or as JSON. Kept in one place so both output shapes
# describe the same issue the same way.
render_issue() {
  local state="$1"
  python3 "${ROOT}/scripts/lib/issue-brief.py" \
    --format "$FORMAT" \
    --owner "$OWNER" \
    --state "$state" \
    --workspace-label "$WORKSPACE_LABEL"
}

# Compare-and-swap: GitHub's "remove a label from an issue" is 404 when the label
# is not applied, so exactly one racing runner sees a 2xx here. This is the whole
# concurrency story — everything after it is bookkeeping by the winner.
claim_take_ready_label() {
  local number="$1"
  gh api -X DELETE "repos/${REPO}/issues/${number}/labels/queue%2Fready" --silent >/dev/null 2>&1
}

claim_add_label() {
  local number="$1" label="$2"
  gh api -X POST "repos/${REPO}/issues/${number}/labels" -f "labels[]=${label}" --silent >/dev/null 2>&1
}

claim_remove_label() {
  local number="$1" label="$2"
  gh api -X DELETE "repos/${REPO}/issues/${number}/labels/${label//\//%2F}" --silent >/dev/null 2>&1 || true
}

# Winning the CAS but failing to record the claim would leave the issue with no
# `queue/*` label at all — invisible to every runner including this one. Put it
# back rather than leaving a hole in the queue.
claim_release() {
  local number="$1"
  claim_remove_label "$number" "queue/claimed"
  claim_add_label "$number" "queue/ready" || true
}

claim_finish() {
  local number="$1"

  if ! claim_add_label "$number" "queue/claimed"; then
    claim_release "$number"
    die "claimed #${number} but could not apply queue/claimed — released it again"
  fi

  if ! gh issue comment "$number" --repo "$REPO" --body "$(claim_comment_body "$number")" >/dev/null 2>&1; then
    claim_release "$number"
    die "claimed #${number} but could not leave the claim comment — released it again"
  fi
}

# An open issue already claimed by this owner. Returning it makes the call
# idempotent: a runner that asks twice continues its work instead of taking a
# second issue off the queue and half-doing both.
claim_find_held() {
  gh_json issue list --repo "$REPO" \
    --label "queue/claimed" --label "$WORKSPACE_LABEL" \
    --state open --limit 50 --json number,comments |
    MARKER="$(claim_marker "$OWNER")" python3 -c '
import json, os, sys

marker = os.environ["MARKER"]
for issue in json.load(sys.stdin):
    if any(marker in (c.get("body") or "") for c in issue.get("comments") or []):
        print(issue["number"])
        break
'
}

claim_candidates() {
  gh_json issue list --repo "$REPO" \
    --label "queue/ready" --label "$WORKSPACE_LABEL" \
    --state open --limit 100 --json number,title,labels,createdAt |
    python3 -c '
import json, sys

# Priority first, then oldest — a p0 filed this morning outranks a p2 from last
# week, and equal priorities are FIFO so nothing starves at the back of the queue.
def rank(issue):
    names = [label["name"] for label in issue.get("labels") or []]
    priority = next((n.split("/", 1)[1] for n in names if n.startswith("priority/")), "p9")
    return (priority, issue.get("createdAt") or "", issue["number"])

for issue in sorted(json.load(sys.stdin), key=rank):
    print("%s\t%s\t%s" % (issue["number"], rank(issue)[0], issue["title"]))
'
}

if ((LIST_ONLY == 1)); then
  listing="$(claim_candidates)"
  if [[ -z "$listing" ]]; then
    echo "no ${WORKSPACE_LABEL} issues are queue/ready in ${REPO}" >&2
    exit 4
  fi
  printf '%s\n' "$listing"
  exit 0
fi

# --issue: claim exactly this one, or hand back the brief if it is already mine.
if [[ -n "$ISSUE" ]]; then
  payload="$(issue_json "$ISSUE")"
  labels="$(printf '%s' "$payload" | python3 -c 'import json,sys; print("\n".join(l["name"] for l in json.load(sys.stdin)["labels"]))')"

  if printf '%s\n' "$labels" | grep -qx "queue/claimed"; then
    if printf '%s' "$payload" | grep -qF "$(claim_marker "$OWNER")"; then
      printf '%s' "$payload" | render_issue "already-mine"
      exit 0
    fi
    echo "error: #${ISSUE} is queue/claimed by another runner — see its claim comment" >&2
    exit 5
  fi

  if ((DRY_RUN == 1)); then
    printf '%s' "$payload" | render_issue "dry-run"
    exit 0
  fi

  if ! claim_take_ready_label "$ISSUE"; then
    echo "error: #${ISSUE} is not queue/ready (another runner took it, or it was never queued)" >&2
    exit 3
  fi

  claim_finish "$ISSUE"
  issue_json "$ISSUE" | render_issue "claimed"
  exit 0
fi

# Already holding one? Continue it rather than taking another.
HELD="$(claim_find_held)"
if [[ -n "$HELD" ]]; then
  issue_json "$HELD" | render_issue "already-mine"
  exit 0
fi

CANDIDATES="$(claim_candidates)"
if [[ -z "$CANDIDATES" ]]; then
  echo "no ${WORKSPACE_LABEL} issues are queue/ready in ${REPO}" >&2
  exit 4
fi

if ((DRY_RUN == 1)); then
  first="$(printf '%s\n' "$CANDIDATES" | head -1 | cut -f1)"
  issue_json "$first" | render_issue "dry-run"
  exit 0
fi

# Walk the ranked candidates, taking the first one whose CAS we win. Losing a
# race is normal with several runners on one queue — it is not an error until
# every candidate is gone.
while IFS=$'\t' read -r number _priority _title; do
  [[ -n "$number" ]] || continue

  if ! claim_take_ready_label "$number"; then
    echo "note: #${number} was taken by another runner — trying the next one" >&2
    continue
  fi

  claim_finish "$number"
  issue_json "$number" | render_issue "claimed"
  exit 0
done <<<"$CANDIDATES"

echo "error: every queue/ready ${WORKSPACE_LABEL} issue was claimed by another runner first" >&2
exit 3
