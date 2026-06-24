# Working safely with concurrent agents in the shared checkout

> Multiple agents run against the **same** primary checkout
> (`/data/workspaces/dalexandre/dev_ide`) at once, plus a dozen-plus
> `git worktree`s. Uncommitted work in the shared root is not yours alone —
> another agent can wipe or race it. This doc is the convention that avoids
> the corruption modes we have actually hit.
>
> **Canonical workflow**: [`development-workflow.md`](development-workflow.md) —
> `launch-devide-agent.sh` now enforces worktree creation at agent start.

## The hazard, concretely

The primary checkout is a shared mutable workspace. At any moment several agents
may be editing files, staging changes, or running `git reset`/`checkout` loops in
it. Two failure modes have bitten real work:

1. **Reset/stash wipes.** An agent running a `git reset --hard` / `git checkout`
   loop (or a stash/harvest cycle) discards *another* agent's uncommitted edits in
   the same tree. Untracked files survive a reset but **not** `git clean`.
2. **Read races.** A verification or "does this file exist?" check reads the
   working tree *while* another agent is mid-refactor. On 2026-06-20 a doc-accuracy
   pass concluded five real modules
   (`DevIDE.PreviewControl.{Adapter,MemoryAdapter,PlaywrightAdapter,PlaywrightBridge}`,
   `DevIDE.Terminals.TmuxAdapter`) were "hallucinations" because a concurrent agent
   had just **staged their deletion** — they were present in `HEAD` the whole time.
   The pass nearly "corrected" accurate docs to match a transient state.

## Conventions

### 1. Do your work in a dedicated worktree, not the shared root

Create an isolated worktree at a known-good commit. It shares `.git` (cheap) but
has its own working tree and index, so nothing you do can race another agent:

```sh
git worktree add -b <branch> /tmp/<task>-wt HEAD
cd /tmp/<task>-wt
# … edit, build, test, commit here …
git worktree remove /tmp/<task>-wt   # when done (branch persists in .git)
```

Reserve direct edits to the primary checkout for quick, committed-immediately
changes — never leave a large uncommitted change sitting in the shared root.

### 2. Verify code/doc claims against `HEAD`, not the working tree

If you must check whether a symbol or file exists in the shared root, ask the
committed tree, which no concurrent edit can mutate under you:

```sh
git cat-file -e HEAD:lib/dev_ide/foo.ex      # exists in HEAD?
git show HEAD:lib/dev_ide/foo.ex | grep …    # read the committed content
```

If the working tree and `HEAD` disagree, a concurrent agent is mid-refactor —
**stop and reconcile**; do not act on the transient state.

### 3. Commit only your own pathspecs

The shared index may hold another agent's staged changes. Never `git commit -a`
or commit a bare index. Stage and commit explicit paths so you cannot capture
someone else's work:

```sh
git add docs/ lib/dev_ide/my_file.ex
git commit -- docs/ lib/dev_ide/my_file.ex
```

### 4. Snapshot before anything destructive

Before any operation that could lose work (yours or a neighbour's), take a
non-invasive rescue copy that survives a reset/clean:

```sh
mkdir -p /tmp/rescue && cp -r docs /tmp/rescue/         # untracked deliverables
git diff -- <your-files> > /tmp/rescue/changes.patch    # tracked edits
```

### 5. Never run broad `pkill`/`git clean -fdx` in the shared root

Kill by PID, not by pattern. A broad `git clean` deletes every agent's untracked
deliverables; a broad `pkill` has caused a forced manager restart before.

## See also

- [`README.md`](README.md) — documentation index.
- [`coverage_map.md`](coverage_map.md) — its "Verification" note records the
  2026-06-20 concurrent-refactor collision described above.
