#!/usr/bin/env bash
#
# fleet-lane-files.sh — spawn file-set discipline (#862).
#
# Lane LABELS LIE. Pane titles, window names, and slugs are display only.
# Ground truth for "what is this live worker actually editing?" is:
#
#   git -C <worktree> diff --name-only origin/master...HEAD
#
# An MGR (or newcomer) runs this before a worker writes code: declare the
# intended file set, intersect it with every live worktree's committed diff,
# and on hit yield to the incumbent (take the non-overlapping remainder).
#
# Discovery is live pane cwd via labeled tmux (casein_tmux), not a stale
# worktree directory walk — panes move; the cwd at list time is the path.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/tmux-label.sh
source "${ROOT}/scripts/lib/tmux-label.sh"

BASE_REF="${CASEIN_LANE_BASE_REF:-origin/master}"
FORMAT="text"
MODE="list"
INCLUDE_DIRTY=0
INCLUDE_EMPTY=0
SELF_PATH=""
MAX_FILES="${CASEIN_LANE_MAX_FILES:-500}"
SESSION_FILTER="${CASEIN_LANE_SESSION:-}"
SESSION_PREFIX="${CASEIN_LANE_SESSION_PREFIX:-casein_}"
DECLARED_FILES=()
FILES_FROM=""
CHECK_PATHS=()

usage() {
  cat <<'EOF'
Usage: fleet-lane-files.sh [list|check] [options]

List live fleet lanes with their REAL committed file sets, or check a
declared file set for intersection with incumbents.

Ground truth (never pane title / window name / slug):
  git diff --name-only origin/master...HEAD   in each live pane's cwd

Commands:
  list                 print every live lane with a non-empty committed set
  check                require --files / --files-from / paths; exit 1 on hit

Options:
  --files f1,f2,...    comma-separated declared paths (check)
  --files-from <path>  one path per line; - = stdin (check)
  --path <file>        repeatable declared path (check)
  --session <name>     only panes in this tmux session
  --session-prefix <p> session name prefix (default: casein_)
  --base-ref <ref>     merge-base tip (default: origin/master)
  --include-dirty      also union unstaged/untracked paths (secondary signal)
  --include-empty      list lanes with zero committed files too
  --self <worktree>    omit this worktree from incumbents (your own tree)
  --format text|json   output shape (default: text)
  --max-files <n>      skip worktrees whose committed set exceeds n (default 500)
                       — filters foreign mega-checkouts (Mira/facility trees)
  -h, --help           this text

Exit codes:
  0  list ok, or check CLEAR (no intersection)
  1  check BLOCKED (intersection with one or more incumbents)
  2  usage / environment error

Examples:
  # MGR sweep — who holds what right now?
  bash scripts/fleet-lane-files.sh list

  # Newcomer declares a set before writing:
  bash scripts/fleet-lane-files.sh check \
    --files lib/casein/paths.ex,test/casein/paths_test.exs

  # Remainder after a yield:
  bash scripts/fleet-lane-files.sh check --files-from declared.txt --self "$PWD"
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

abs_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
    return
  fi
  if [[ -e "$p" ]]; then
    local dir base
    dir="$(cd "$(dirname "$p")" && pwd -P)"
    base="$(basename "$p")"
    printf '%s/%s\n' "$dir" "$base"
    return
  fi
  # non-existent path: resolve parent if possible
  local dir base
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || {
    printf '%s\n' "$p"
    return
  }
  base="$(basename "$p")"
  printf '%s/%s\n' "$dir" "$base"
}

git_common_dir() {
  local wt="$1"
  local gd
  gd="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  # normalize
  if [[ -d "$gd" ]]; then
    (cd "$gd" && pwd -P)
  else
    printf '%s\n' "$gd"
  fi
}

committed_files() {
  local wt="$1"
  git -C "$wt" diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || true
}

dirty_files() {
  local wt="$1"
  # porcelain: XY path (and rename " -> ")
  git -C "$wt" status --porcelain=v1 -uall 2>/dev/null \
    | awk '{
        if ($1 ~ /^R/ || $1 ~ /^C/) {
          # rename/copy: "R  old -> new"
          for (i=1;i<=NF;i++) if ($i=="->") { print $(i+1); break }
        } else {
          # first field is status; path is rest (may have spaces rarely)
          sub(/^../, ""); sub(/^ /, ""); print
        }
      }' || true
}

# Collect live panes: pane_id, window_name, cwd.
# tmux list-panes without -a/-s is window-scoped only — a bare -t <session>
# returns the session's *current* window. Always use -s (session) or -a (all).
collect_panes() {
  local args=()
  if [[ -n "$SESSION_FILTER" ]]; then
    args=(-s -t "$SESSION_FILTER")
  else
    args=(-a)
  fi

  casein_tmux list-panes "${args[@]}" -F \
    '#{session_name}'$'\t''#{pane_id}'$'\t''#{window_name}'$'\t''#{pane_current_path}' 2>/dev/null \
    | while IFS=$'\t' read -r session pane win path; do
        [[ -n "$session" && -n "$path" ]] || continue
        if [[ -z "$SESSION_FILTER" && -n "$SESSION_PREFIX" ]]; then
          case "$session" in
            "${SESSION_PREFIX}"*) ;;
            *) continue ;;
          esac
        fi
        printf '%s\t%s\t%s\t%s\n' "$session" "$pane" "$win" "$path"
      done
}

# Build lanes keyed by absolute worktree path.
# Writes lines to FD 3 as: path<TAB>session<TAB>pane<TAB>win  (may repeat path)
enumerate_lane_rows() {
  local session pane win path abs
  while IFS=$'\t' read -r session pane win path; do
    [[ -d "$path" ]] || continue
    git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    abs="$(abs_path "$path")" || continue
    printf '%s\t%s\t%s\t%s\n' "$abs" "$session" "$pane" "$win"
  done < <(collect_panes)
}

same_product_repo() {
  local wt="$1"
  local anchor_gd wt_gd
  anchor_gd="${ANCHOR_GIT_COMMON:-}"
  [[ -n "$anchor_gd" ]] || return 0
  wt_gd="$(git_common_dir "$wt")" || return 1
  [[ "$wt_gd" == "$anchor_gd" ]]
}

resolve_anchor_git() {
  # Prefer an explicit product checkout (tests set CASEIN_CHECKOUT to a
  # hermetic repo). Fall back to $PWD, then the script's tree.
  local cand
  for cand in "${CASEIN_CHECKOUT:-}" "$PWD" "$ROOT"; do
    [[ -n "$cand" && -d "$cand" ]] || continue
    if git -C "$cand" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || git -C "$cand" rev-parse --git-dir >/dev/null 2>&1; then
      ANCHOR_GIT_COMMON="$(git_common_dir "$cand")" || continue
      ANCHOR_TOPLEVEL="$(git -C "$cand" rev-parse --show-toplevel 2>/dev/null || true)"
      return 0
    fi
  done
  ANCHOR_GIT_COMMON=""
  ANCHOR_TOPLEVEL=""
}

# Ensure base ref is usable in a worktree (best-effort; empty set if missing).
ensure_base_ref() {
  local wt="$1"
  git -C "$wt" rev-parse --verify "${BASE_REF}^{commit}" >/dev/null 2>&1
}

parse_args() {
  local cmd_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      list)
        MODE="list"
        cmd_set=1
        shift
        ;;
      check)
        MODE="check"
        cmd_set=1
        shift
        ;;
      --files)
        [[ $# -ge 2 ]] || die "--files needs a value"
        IFS=',' read -r -a _parts <<<"$2"
        DECLARED_FILES+=("${_parts[@]}")
        shift 2
        ;;
      --files-from)
        [[ $# -ge 2 ]] || die "--files-from needs a value"
        FILES_FROM="$2"
        shift 2
        ;;
      --path)
        [[ $# -ge 2 ]] || die "--path needs a value"
        DECLARED_FILES+=("$2")
        shift 2
        ;;
      --session)
        SESSION_FILTER="${2:-}"
        [[ -n "$SESSION_FILTER" ]] || die "--session needs a value"
        shift 2
        ;;
      --session-prefix)
        SESSION_PREFIX="${2:-}"
        shift 2
        ;;
      --base-ref)
        BASE_REF="${2:-}"
        [[ -n "$BASE_REF" ]] || die "--base-ref needs a value"
        shift 2
        ;;
      --include-dirty)
        INCLUDE_DIRTY=1
        shift
        ;;
      --include-empty)
        INCLUDE_EMPTY=1
        shift
        ;;
      --self)
        SELF_PATH="$(abs_path "${2:-}")"
        shift 2
        ;;
      --format)
        FORMAT="${2:-}"
        [[ "$FORMAT" == "text" || "$FORMAT" == "json" ]] || die "--format text|json"
        shift 2
        ;;
      --max-files)
        MAX_FILES="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        DECLARED_FILES+=("$@")
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        # bare paths after check
        DECLARED_FILES+=("$1")
        shift
        ;;
    esac
  done

  if [[ "$cmd_set" -eq 0 && ${#DECLARED_FILES[@]} -gt 0 ]]; then
    MODE="check"
  fi
}

load_declared() {
  local line
  if [[ -n "$FILES_FROM" ]]; then
    if [[ "$FILES_FROM" == "-" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        DECLARED_FILES+=("$line")
      done
    else
      [[ -f "$FILES_FROM" ]] || die "files-from not found: $FILES_FROM"
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        DECLARED_FILES+=("$line")
      done <"$FILES_FROM"
    fi
  fi

  # normalize: strip leading ./ 
  local -a norm=()
  local f
  for f in "${DECLARED_FILES[@]+"${DECLARED_FILES[@]}"}"; do
    f="${f#./}"
    f="${f//$'\r'/}"
    [[ -n "$f" ]] || continue
    norm+=("$f")
  done
  DECLARED_FILES=("${norm[@]+"${norm[@]}"}")
}

# Populate global arrays LANE_PATHS, and associative-ish files via temp dir
LANE_TMP=""
cleanup() {
  [[ -n "${LANE_TMP:-}" && -d "${LANE_TMP:-}" ]] && rm -rf "$LANE_TMP"
}
trap cleanup EXIT

build_lanes() {
  LANE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-lane-files.XXXXXX")"
  mkdir -p "$LANE_TMP/meta" "$LANE_TMP/files"

  local path session pane win key metafile filesfile branch n count
  local -A seen_meta=()

  while IFS=$'\t' read -r path session pane win; do
    [[ -n "$path" ]] || continue
    if [[ -n "$SELF_PATH" && "$path" == "$SELF_PATH" ]]; then
      continue
    fi
    same_product_repo "$path" || continue

    key="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
    metafile="$LANE_TMP/meta/$key"
    filesfile="$LANE_TMP/files/$key"

    if [[ ! -f "$metafile" ]]; then
      branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
      {
        printf 'path=%s\n' "$path"
        printf 'branch=%s\n' "$branch"
      } >"$metafile"
      : >"$filesfile"

      if ensure_base_ref "$path"; then
        committed_files "$path" >>"$filesfile" || true
      fi
      if [[ "$INCLUDE_DIRTY" -eq 1 ]]; then
        dirty_files "$path" >>"$filesfile" || true
      fi
      # unique sort
      if [[ -s "$filesfile" ]]; then
        sort -u -o "$filesfile" "$filesfile"
      fi
      count="$(wc -l <"$filesfile" | tr -d ' ')"
      if [[ "$count" -gt "$MAX_FILES" ]]; then
        # foreign mega-tree or runaway branch — not a casein lane signal
        rm -f "$metafile" "$filesfile"
        continue
      fi
      printf 'file_count=%s\n' "$count" >>"$metafile"
    fi

    # append occupant
    printf '%s\t%s\t%s\n' "$session" "$pane" "$win" >>"$LANE_TMP/meta/${key}.panes"
  done < <(enumerate_lane_rows)
}

print_list_text() {
  local key metafile filesfile path branch count
  local any=0
  for metafile in "$LANE_TMP"/meta/*; do
    [[ -f "$metafile" ]] || continue
    [[ "$metafile" == *.panes ]] && continue
    key="$(basename "$metafile")"
    filesfile="$LANE_TMP/files/$key"
    # shellcheck disable=SC1090
    path=""; branch=""; count=0
    path="$(grep -E '^path=' "$metafile" | head -1 | cut -d= -f2-)"
    branch="$(grep -E '^branch=' "$metafile" | head -1 | cut -d= -f2-)"
    count="$(grep -E '^file_count=' "$metafile" | head -1 | cut -d= -f2-)"
    count="${count:-0}"

    if [[ "$count" -eq 0 && "$INCLUDE_EMPTY" -eq 0 ]]; then
      continue
    fi
    any=1
    echo "=== lane ==="
    echo "worktree: $path"
    echo "branch:   $branch"
    echo "files:    $count   (git diff --name-only ${BASE_REF}...HEAD)"
    echo "occupants (label display only — not ground truth):"
    if [[ -f "$LANE_TMP/meta/${key}.panes" ]]; then
      while IFS=$'\t' read -r session pane win; do
        printf '  %-8s  %-36s  session=%s\n' "$pane" "$win" "$session"
      done <"$LANE_TMP/meta/${key}.panes"
    fi
    if [[ "$count" -gt 0 ]]; then
      echo "committed_set:"
      sed 's/^/  /' "$filesfile"
    else
      echo "committed_set: (empty)"
    fi
    echo
  done
  if [[ "$any" -eq 0 ]]; then
    echo "no live lanes with a non-empty committed file set (base=${BASE_REF})."
  fi
}

print_list_json() {
  python3 - "$LANE_TMP" "$BASE_REF" "$INCLUDE_EMPTY" <<'PY'
import json, os, sys
tmp, base_ref, include_empty = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
lanes = []
meta_dir = os.path.join(tmp, "meta")
files_dir = os.path.join(tmp, "files")
for name in sorted(os.listdir(meta_dir)):
    if name.endswith(".panes"):
        continue
    meta_path = os.path.join(meta_dir, name)
    if not os.path.isfile(meta_path):
        continue
    meta = {}
    with open(meta_path) as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                meta[k] = v
    count = int(meta.get("file_count") or 0)
    if count == 0 and not include_empty:
        continue
    files = []
    fp = os.path.join(files_dir, name)
    if os.path.isfile(fp):
        with open(fp) as f:
            files = [ln.rstrip("\n") for ln in f if ln.strip()]
    occupants = []
    panes_path = os.path.join(meta_dir, name + ".panes")
    if os.path.isfile(panes_path):
        with open(panes_path) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    occupants.append({"session": parts[0], "pane": parts[1], "window": parts[2]})
    lanes.append({
        "worktree": meta.get("path"),
        "branch": meta.get("branch"),
        "base_ref": base_ref,
        "file_count": count,
        "committed_set": files,
        "occupants": occupants,
        "note": "occupants.window is display-only; committed_set is ground truth",
    })
print(json.dumps({"base_ref": base_ref, "lanes": lanes}, indent=2))
PY
}

run_check() {
  load_declared
  if [[ ${#DECLARED_FILES[@]} -eq 0 ]]; then
    die "check requires --files, --files-from, --path, or bare paths"
  fi

  # unique declared
  local -A want=()
  local f
  for f in "${DECLARED_FILES[@]}"; do
    want["$f"]=1
  done

  local blocked=0
  local key metafile filesfile path branch
  local -a hits=()
  local -a clear_files=()
  local -A hit_files=()

  if [[ "$FORMAT" == "json" ]]; then
    # collect for json at end
    :
  fi

  local intersections_json="["
  local first_i=1

  for metafile in "$LANE_TMP"/meta/*; do
    [[ -f "$metafile" ]] || continue
    [[ "$metafile" == *.panes ]] && continue
    key="$(basename "$metafile")"
    filesfile="$LANE_TMP/files/$key"
    [[ -s "$filesfile" ]] || continue

    path="$(grep -E '^path=' "$metafile" | head -1 | cut -d= -f2-)"
    branch="$(grep -E '^branch=' "$metafile" | head -1 | cut -d= -f2-)"

    hits=()
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [[ -n "${want[$f]+x}" ]]; then
        hits+=("$f")
        hit_files["$f"]=1
      fi
    done <"$filesfile"

    if [[ ${#hits[@]} -gt 0 ]]; then
      blocked=1
      if [[ "$FORMAT" == "text" ]]; then
        echo "BLOCKED by incumbent"
        echo "  worktree: $path"
        echo "  branch:   $branch"
        echo "  occupants (display only):"
        if [[ -f "$LANE_TMP/meta/${key}.panes" ]]; then
          while IFS=$'\t' read -r session pane win; do
            printf '    %s  %s  session=%s\n' "$pane" "$win" "$session"
          done <"$LANE_TMP/meta/${key}.panes"
        fi
        echo "  intersection:"
        printf '    %s\n' "${hits[@]}"
        echo
      else
        # json fragment built in python below via temp
        local hitfile="$LANE_TMP/hit_$key"
        printf '%s\n' "${hits[@]}" >"$hitfile"
        printf '%s\t%s\t%s\n' "$path" "$branch" "$key" >>"$LANE_TMP/blocked_keys"
      fi
    fi
  done

  for f in "${!want[@]}"; do
    if [[ -z "${hit_files[$f]+x}" ]]; then
      clear_files+=("$f")
    fi
  done

  if [[ "$FORMAT" == "json" ]]; then
    python3 - "$LANE_TMP" "$BASE_REF" "$blocked" "${DECLARED_FILES[@]}" <<'PY'
import json, os, sys
tmp, base_ref, blocked = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
declared = sys.argv[4:]
incumbents = []
blocked_keys = os.path.join(tmp, "blocked_keys")
if os.path.isfile(blocked_keys):
    with open(blocked_keys) as f:
        for line in f:
            path, branch, key = line.rstrip("\n").split("\t")
            hits = []
            hf = os.path.join(tmp, "hit_" + key)
            if os.path.isfile(hf):
                with open(hf) as h:
                    hits = [ln.rstrip("\n") for ln in h if ln.strip()]
            occupants = []
            panes = os.path.join(tmp, "meta", key + ".panes")
            if os.path.isfile(panes):
                with open(panes) as p:
                    for pl in p:
                        parts = pl.rstrip("\n").split("\t")
                        if len(parts) >= 3:
                            occupants.append({"session": parts[0], "pane": parts[1], "window": parts[2]})
            incumbents.append({
                "worktree": path,
                "branch": branch,
                "intersection": hits,
                "occupants": occupants,
            })
hit_set = set()
for inc in incumbents:
    hit_set.update(inc["intersection"])
remainder = [f for f in declared if f not in hit_set]
print(json.dumps({
    "base_ref": base_ref,
    "status": "blocked" if blocked else "clear",
    "declared": declared,
    "intersection": sorted(hit_set),
    "remainder": remainder,
    "incumbents": incumbents,
    "rule": "newcomer yields intersection to incumbent; take remainder only",
}, indent=2))
PY
  else
    if [[ "$blocked" -eq 1 ]]; then
      echo "status: BLOCKED"
      echo "rule:   newcomer yields intersection to incumbent; take remainder only"
      echo "remainder (non-overlapping — safe to claim):"
      if [[ ${#clear_files[@]} -eq 0 ]]; then
        echo "  (empty — full yield, pick a different lane)"
      else
        printf '  %s\n' "${clear_files[@]}"
      fi
      echo "blocked_paths:"
      printf '  %s\n' "${!hit_files[@]}"
    else
      echo "status: CLEAR"
      echo "declared file set has zero intersection with live committed diffs (base=${BASE_REF})."
      echo "files:"
      printf '  %s\n' "${DECLARED_FILES[@]}"
    fi
  fi

  if [[ "$blocked" -eq 1 ]]; then
    exit 1
  fi
  exit 0
}

main() {
  parse_args "$@"
  resolve_anchor_git
  build_lanes

  case "$MODE" in
    list)
      if [[ "$FORMAT" == "json" ]]; then
        print_list_json
      else
        print_list_text
      fi
      ;;
    check)
      run_check
      ;;
    *)
      die "unknown mode: $MODE"
      ;;
  esac
}

main "$@"
