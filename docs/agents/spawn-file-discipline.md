# Spawn file-set discipline (#862)

**Audience:** managers spawning workers, supervisors clearing collisions.  
**Ground truth:** committed diff in each live worktree — **never** pane title,
window name, slug, or issue label.

Lane labels lie. A pane titled `v02-384-orch-slice` has committed
preview-contract files from a different, already-merged issue. Trusting the
label fences the wrong worker off the wrong files.

## Rule (before any spawned worker writes code)

1. **Declare** the intended file set (paths relative to the product root).
2. **Check** it against every **live** worktree's committed set:
   ```bash
   git -C <worktree> diff --name-only origin/master...HEAD
   ```
3. **On intersection:** the **newcomer yields** to the incumbent. Take only the
   non-overlapping **remainder**, or pick another lane.
4. **Do not** use pane title, window name, `worker-<slug>`, or issue labels as
   the file fence. Those are display-only chrome.

Uncommitted dirty paths are a secondary signal (`--include-dirty`). The
acceptance bar and collision proof are the **committed** triple-dot diff.

## One command

```bash
# Who holds what right now? (live pane cwd via casein_tmux)
bash scripts/fleet-lane-files.sh list
bash scripts/fleet-lane-files.sh list --session "$CASEIN_TMUX_SESSION"
bash scripts/fleet-lane-files.sh list --format json

# Newcomer declares a set before writing:
bash scripts/fleet-lane-files.sh check \
  --files lib/casein/paths.ex,test/casein/paths_test.exs
# exit 0 = CLEAR, exit 1 = BLOCKED (prints intersection + remainder)

# Omit your own tree when re-checking mid-flight:
bash scripts/fleet-lane-files.sh check --self "$PWD" --files-from declared.txt
```

Discovery uses **live tmux pane cwd** (`casein_tmux list-panes`), not a stale
directory walk of `/data/casein-agent-worktrees`. Panes move; cwd at list time
is the path. Foreign mega-checkouts (Mira / facility trees with thousands of
files vs `origin/master`) are skipped via `--max-files` (default 500).

## Yield protocol

| Result | Action |
|--------|--------|
| CLEAR | Proceed; bind issue; write only declared paths |
| BLOCKED | Incumbent keeps the intersection. Newcomer takes `remainder` only, or stands down |
| Empty remainder | Full yield — do not share the module; take a different issue |

Incumbent wins even if their window name looks unrelated. The committed set is
the lease.

## What this is not

- Not a durable lock service or MCP tool (script + docs only for #862)
- Not a substitute for `queue/claimed` issue protocol
- Not permission to demote CI gates or hand-patch around infra reds
- Not authority to edit `backends/**`, `impl/command.ex`, or other fenced paths
  without a cleared fileset against live diffs

## Evidence

Applied by hand it cleared two blocked workers in one pass: an incumbent's
#248 work was entirely under `scripts/`, so a newcomer's `lib/casein/paths.ex`
set had zero intersection and was cleared immediately. This script makes that
sweep one command.
