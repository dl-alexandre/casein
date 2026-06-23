# Proposals

> Surface agent-produced change artifacts (unified `.diff`/`.patch` files) for **human review only** — discover, parse, and risk-classify them against the working tree, never apply them.

## Responsibility

The proposals subsystem finds artifacts that review/coding agents drop into
known workspace directories, parses their unified-diff headers into a
structured `Proposal`, and compares each against the current git working tree
to produce a `risk` verdict (`:clean` / `:overlap` / `:conflict` / `:invalid`).

It is **strictly read-only**. There is no callback, function, or code path that
applies a patch, writes a file, or grants a permission. Applying a proposal is
denied at the policy layer (`DevIDE.Policy.can_apply_proposal?/1` →
`deny(:apply_proposal, ctx, :not_implemented)`), and this subsystem provides no
machinery it could call even if it were allowed. This realizes the architecture
authority-map row "Apply proposal — **Denied** (`:not_implemented`)".

## Module map

| Module | File | Role |
|---|---|---|
| `DevIDE.Proposals` | `lib/dev_ide/proposals.ex` | Context facade. `discover/1` and `parse/2` delegate to a runtime-configurable adapter (`:proposals_adapter`, default `LocalAdapter`). |
| `DevIDE.Proposals.Adapter` | `lib/dev_ide/proposals/adapter.ex` | Behaviour: `discover/1` + `parse/2` callbacks returning `Proposal.t()`. |
| `DevIDE.Proposals.LocalAdapter` | `lib/dev_ide/proposals/local_adapter.ex` | Filesystem implementation: scans discovery dirs, size-caps, stats, and parses files. Read-only. |
| `DevIDE.Proposals.Proposal` | `lib/dev_ide/proposals/proposal.ex` | Struct for a single discovered artifact (path, size, mtime, parser, status, changes, diff). |
| `DevIDE.Proposals.UnifiedDiff` | `lib/dev_ide/proposals/unified_diff.ex` | Header-only unified-diff parser. `parse/2` extracts changed paths; `parse_with_hunks/2` also extracts hunk ranges. Rejects root-escaping paths. |
| `DevIDE.Proposals.ConflictAnalyzer` | `lib/dev_ide/proposals/conflict_analyzer.ex` | `analyze/2` compares a parsed proposal against the working-tree diff and returns an `Analysis`. |
| `DevIDE.Proposals.Analysis` | `lib/dev_ide/proposals/analysis.ex` | Struct holding the `risk` verdict, per-file overlap detail, and overlapping-file list. |
| `DevIDE.Proposals.Hunk` | `lib/dev_ide/proposals/hunk.ex` | Range-overlap helpers (`overlap?/2`, `overlaps/2`) used by the analyzer to detect colliding hunks. |

## Data flow / lifecycle

```text
caller (e.g. Export.WorkspaceStatus.recent_proposals)
  │
  ├─ Proposals.discover(root)            → impl().discover/1
  │     LocalAdapter.discover/1:
  │       for each @discovery_dirs entry  (.opencode/proposals, .opencode/sessions,
  │         PathSafety.resolve(root, rel)  .opencode/logs, .agent/proposals)
  │         File.ls + lstat each .diff/.patch
  │       → sort by mtime desc, take @max_results (20)
  │       → [%Proposal{status: :unsupported | :too_large}]  (no content read yet)
  │
  ├─ Proposals.parse(root, p.rel_path)   → impl().parse/2
  │     LocalAdapter.parse/2:
  │       PathSafety.resolve(root, rel_path)        — traversal/symlink guard
  │       supported?/1 (.diff/.patch)               — else :unsupported
  │       File.stat regular & size ≤ 512KB          — else :too_large / :invalid
  │       File.read
  │       UnifiedDiff.parse(content, root)           — header → [changes]
  │         /dev/null ⇒ :add/:delete; else :modify
  │         any root-escape ⇒ {:error, :invalid_path}
  │       diff rendered, truncated at 256KB
  │       → {:ok, %Proposal{status: :parsed | :invalid, changes, diff, truncated}}
  │
  └─ ConflictAnalyzer.analyze(root, %Proposal{status: :parsed, diff})
        UnifiedDiff.parse_with_hunks(diff, root)     — proposal hunks
        Git.diff_all(root)                           — workspace working-tree diff
        parse_with_hunks(workspace_diff, root)       — indexed by path
        build/2:
          per proposal file → classify_overlap/2 vs workspace index
            :add or :delete touching a workspace-touched path ⇒ :conflict
            :modify ⇒ Hunk.overlaps → :conflict if any, else :overlap
            no workspace change for path ⇒ :no_workspace_change
          risk = :conflict > :overlap > :clean (highest wins)
        → %Analysis{risk, reason, files, overlapping_files, files_count}
```

A `Proposal` thus passes through two stages: a cheap **discovery** stage
(metadata only, `status` is `:unsupported` or `:too_large`) and a **parse**
stage (content read, `status` becomes `:parsed` or `:invalid`). `ConflictAnalyzer`
only does real work on `status: :parsed`; anything else short-circuits to
`%Analysis{risk: :invalid}`.

## Public surface

Code outside the subsystem should go through the context facade and the analyzer:

- `DevIDE.Proposals.discover/1` — `(root) :: [Proposal.t()]`. Metadata-only listing, newest first, capped at 20.
- `DevIDE.Proposals.parse/2` — `(root, rel_path) :: {:ok, Proposal.t()}`. Always returns `{:ok, _}`; failure is encoded in the proposal's `status`/`error`, not the tuple.
- `DevIDE.Proposals.ConflictAnalyzer.analyze/2` — `(root, Proposal.t()) :: Analysis.t()`. Risk classification vs. the working tree.

Lower-level helpers, called by the adapter/analyzer (and usable directly):

- `DevIDE.Proposals.UnifiedDiff.parse/2` and `parse_with_hunks/2` — `(diff, root) :: {:ok, [change]} | {:error, :invalid_path | :no_headers}`.
- `DevIDE.Proposals.Hunk.overlap?/2`, `Hunk.overlaps/2` — range collision checks.

The only in-tree consumer today is the public
`DevIDE.Export.WorkspaceStatus.proposals/1`
(`lib/dev_ide/export/workspace_status.ex`, which delegates to the private
`recent_proposals/2`), running discover → parse →
analyze and projects a compact summary (`risk`, `files_count`,
`overlapping_files`) into the workspace status export.

The adapter is swappable at runtime via
`Application.get_env(:dev_ide, :proposals_adapter, DevIDE.Proposals.LocalAdapter)`.

## Invariants & gotchas

- **Read-only by construction.** No apply/write/permission-grant path exists. Applying is policy-denied as `:not_implemented`; do not add an apply path here without revisiting `DevIDE.Policy.can_apply_proposal?/1` and the architecture authority map.
- **Path safety is enforced twice.** Both discovery roots (`LocalAdapter`) and every diff-header target path (`UnifiedDiff`) run through `DevIDE.Files.PathSafety.resolve/2`; a header that resolves outside the workspace root makes the whole proposal `:invalid` (`"path traversal in diff header"`). This is trust-boundary 4 from the architecture doc.
- **`parse/2` never returns `:error`.** It always returns `{:ok, %Proposal{}}`; callers must inspect `status` (`:parsed | :too_large | :invalid | :unsupported`) and `error`, not pattern-match the tuple for failure.
- **Size caps.** Files over `@max_file_bytes` (512 KB) are flagged `:too_large` and never read; rendered diffs are truncated at `@max_diff_render` (256 KB) with a `truncated: true` flag. Discovery is capped at `@max_results` (20), sorted newest-first.
- **Discovery is extension-gated** to `.diff`/`.patch` (case-insensitive) under a fixed set of `@discovery_dirs` (`.opencode/proposals`, `.opencode/sessions`, `.opencode/logs`, `.agent/proposals`). Other agent artifact layouts are invisible until added here.
- **Header-only parsing.** `UnifiedDiff` extracts changed paths and hunk *ranges* only — no content/semantic validation, no three-way merge, no binary-patch handling. `/dev/null` is a create/delete marker, never a path; `/dev/null` ↔ `/dev/null` is `:invalid`.
- **Hunk zero-count ranges count as one line.** `Hunk.overlap?/2` treats a `count: 0` range as covering one line, so an insert-at-N and a modify-at-N collide rather than slipping past each other. Overlap is compared on `old_range`.
- **`:add`/`:delete` against any workspace-touched path is always `:conflict`** (not `:overlap`), regardless of hunk geometry — see `ConflictAnalyzer.classify_overlap/2`.
- **Analysis depends on `Git.diff_all/1`.** If the git diff can't be produced (or the proposal diff can't be re-parsed with hunks), the result is `%Analysis{risk: :invalid}` with a `reason`, not a crash.

## See also

- [`../architecture.md`](../architecture.md) — authority map ("Apply proposal — Denied"), trust boundaries (4: PathSafety), and key design invariant 1 (no arbitrary argv / no apply path).
- [`../product.md`](../product.md) — server/client boundary and review-only posture.
- [`../glossary.md`](../glossary.md) — operational terminology.
