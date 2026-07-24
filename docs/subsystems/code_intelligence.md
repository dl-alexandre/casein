# Code Intelligence

> Read-only-by-default surfaces for navigating a workspace tree: safe file I/O, cross-file search, git context, and lightweight Elixir/Phoenix introspection — all rooted in one workspace path and never reaching outside it.

## Responsibility

These four contexts give the cockpit its "what's in this workspace" surfaces:

- **Files** (`lib/casein/files/`) — list/read/write/create/rename/delete a workspace tree, version-checked and atomic, with a single path-safety gate.
- **Search** (`lib/casein/search/`) — cross-file text search via ripgrep, argv-only, results filtered back through path safety.
- **Git** (`lib/casein/git/`) — branch/status/diff for the working tree, plus worktree/checkout inspection (delegated to `GitCtl`).
- **Elixir** (`lib/casein/elixir/`) — regex-level symbol extraction and project/tooling detection. No `mix`, no AST, no processes.

Every read in this subsystem canonicalises its target through `Casein.Files.PathSafety` so a traversal (`../`) or escaping symlink cannot surface content from outside the workspace root. The root itself is supplied pre-validated by the caller (typically `Casein.Workspaces.safe_host_path/1`).

## Module map

| module | file | role |
|--------|------|------|
| `Casein.Files.PathSafety` | `lib/casein/files/path_safety.ex` | Allowlist + ignore-set + symlink-escape gate. The shared safety primitive every other module here depends on. |
| `Casein.Files.Entry` | `lib/casein/files/entry.ex` | Struct for one tree entry (`name`, `rel_path`, `kind`, `size`, `mtime`); built from `File.Stat`. |
| `Casein.Files.Version` | `lib/casein/files/version.ex` | Opaque optimistic-concurrency token `<size>:<mtime_hex>:<sha256_16>` for write conflict detection. |
| `Casein.Files.Janitor` | `lib/casein/files/janitor.ex` | Boot-time sweep of stale `.devide.tmp.*` sidecars from aborted atomic writes. |
| `Casein.Search.Adapter` | `lib/casein/search/adapter.ex` | Behaviour: `search/3`, `available?/0`. |
| `Casein.Search.RipgrepAdapter` | `lib/casein/search/ripgrep_adapter.ex` | Default adapter; runs `rg --json` argv-only, parses match events, path-safe filters. |
| `Casein.Search.MemoryAdapter` | `lib/casein/search/memory_adapter.ex` | Test-only adapter reading canned results from app env. |
| `Casein.Search.Result` | `lib/casein/search/result.ex` | Struct for one match (`path`, `line`, `column`, `preview`). |
| `Casein.Git.Adapter` | `lib/casein/git/adapter.ex` | Behaviour: `branch/1`, `status_short/1`, `diff/2`, `diff_all/1`. |
| `Casein.Git.LocalAdapter` | `lib/casein/git/local_adapter.ex` | Default adapter; `git -C <root>` argv-only, diff output capped at 256 KB. |
| `Casein.Git.Inspector` | `lib/casein/git/inspector.ex` | Worktree/checkout context facade over `GitCtl.Inspector`; mirrors its struct (compile-time field check) and injects agent inference. |
| `Casein.Git.InspectorCache` | `lib/casein/git/inspector_cache.ex` | Supervised owner of the `GitCtl.Cache` ETS table so it outlives transient callers. |
| `Casein.Elixir.Symbols` | `lib/casein/elixir/symbols.ex` | Line-level regex symbol scanner for `.ex`/`.exs`. |
| `Casein.Elixir.Symbol` | `lib/casein/elixir/symbol.ex` | Struct for one extracted symbol (`kind`, `name`, `line`, `arity`, `visibility`). |
| `Casein.Elixir.Project` | `lib/casein/elixir/project.ex` | Detect mix/umbrella/phoenix/live_view/ecto/formatter from `mix.exs`/`mix.lock`. |
| `Casein.Elixir.Tooling` | `lib/casein/elixir/tooling.ex` | Detect formatter / Lexical / ElixirLS presence from workspace-local artifacts. |

These contexts have public facades one directory up — `Casein.Files`, `Casein.Search`, `Casein.Git`, `Casein.Elixir` — and a location-aware wrapper `Casein.Workspaces.FileAccess` that dispatches local vs. remote (`{:local, root}` / `{:remote, host, root}`). Those facades are outside this subsystem's directories but are the actual call entry points (see Public surface).

## Data flow / lifecycle

**File read/write (optimistic concurrency).**
`Files.read_text/2` resolves the path, rejects binary (`PathSafety.likely_binary?/1`, NUL sniff in first 8 KB) and oversized (>2 MB) content, and returns content plus a `Version.compute/2` token. The editor sends that token back on save; `Files.write_text/4` recomputes the current on-disk version, returns `{:error, :conflict}` on mismatch, otherwise writes atomically: a sibling `.devide.tmp.<rand>` file is written, chmod'd to the original mode, and `File.rename/2`'d over the target. A crash between write and rename leaves a `.devide.tmp.*` sidecar; `Janitor.run_on_boot/0` (kicked off via `Task.start` in `Casein.Application.start/2`) sweeps those older than 1 hour from each configured workspace root.

**Tree listing.** `Files.list/2` and `Palette.FileIndex.list/1` both walk the tree filtering through `PathSafety.ignored_dir?/1` (`.git`, `_build`, `deps`, `node_modules`, …) and `ignored_path?/1` (cache globs). `FileIndex` additionally caps at 5,000 files and only surfaces dotfile dirs `.formatter`/`.github`. Neither follows symlinks.

**Search.** `Casein.Search.search/3` validates query length (2–200 chars) and root existence, then dispatches to the configured adapter. `RipgrepAdapter` builds an argv (`--json --hidden` with `!`-globs), runs it under a `Task.async` + `Task.yield`/`Task.shutdown(:brutal_kill)` timeout (default 10 s), caps raw output at 1 MB, parses `match` events, and re-validates every hit's path with `PathSafety.resolve/2` before returning up to `result_cap` (200) `Result` structs with workspace-relative paths.

**Git.** `Casein.Git.*` shell out via `LocalAdapter` (`git -C <root>`, argv-only, `stderr_to_stdout: true`). Independently, `Git.Inspector.inspect_cwd/1` delegates to `GitCtl.Inspector` (in the `dev_ide_core` sibling) for worktree detection, caching results per-cwd in an ETS table owned by the supervised `InspectorCache`. `SessionDirectory` calls `Inspector` to label sessions with branch/worktree/agent context.

**Elixir.** Pure, synchronous, content-in/struct-out. `Symbols.extract/2` scans source line-by-line; `Project.detect/1` and `Tooling.detect/1` read a handful of root files through `PathSafety`. No process is started anywhere in `lib/casein/elixir/`.

## Public surface

Callers reach these through the facade modules (and `Workspaces.FileAccess` for local/remote dispatch):

- **Files** — `Files.list/2`, `read_text/2`, `write_text/4`, `create_file/2`, `create_dir/2`, `rename/3`, `delete/3`. Underlying gate: `PathSafety.resolve/2`, `ignored_dir?/1`, `ignored_path?/1`, `likely_binary?/1`; `Version.compute/2`, `compute_path/1`.
- **Search** — `Search.search/3`, `available?/0`, `min_query/0`, `max_query/0`, `result_cap/0` (the last three drive UI validation in `side_panels.ex`).
- **Git** — `Git.branch/1`, `status_short/1`, `diff/2`, `diff_all/1`; `Git.Inspector.inspect_cwd/1`, `infer_agent/1`.
- **Elixir** — `Elixir.symbols/2` (→ `Symbols.extract/2`), `Elixir.project/1` (→ `Project.detect/1`), `Elixir.tooling/1` (→ `Tooling.detect/1`).
- **Palette** — `Palette.FileIndex.list/1`, `cap/0`.

**Supervised process:** `Casein.Git.InspectorCache` (owns the `GitCtl.Cache` ETS table; does nothing after `init/1`).

## Invariants & gotchas

- **PathSafety is the single chokepoint.** Every path that reaches the filesystem in this subsystem goes through `resolve/2`. It rejects `:too_deep` (>32 segments), `:outside_root`, and `:symlink_escape` (any ancestor symlink whose `read_link` target leaves the root). The caller must still hand in a root already validated against `:workspaces_roots`.
- **Argv-only, never shell.** Both `RipgrepAdapter` and `LocalAdapter` pass user input (search query, path) as discrete `System.cmd/3` argv elements — never interpolated into a shell string. The search query is the element after `-e`; the diff path is the element after `--`.
- **Search is read-only by contract.** `Casein.Search`'s moduledoc pins the "M18 contract: search-only" — no replace/write path lives here.
- **Write conflicts are detected, not prevented.** `write_text/4` is last-writer-wins-with-a-veto: a stale `expected_version` yields `{:error, :conflict}` rather than clobbering. Version folds in content sha256 *and* stat to survive low-resolution mtimes.
- **Atomic writes leave sidecars on crash.** The `.devide.tmp.*` convention is shared between `Files.atomic_write/3` (writer) and `Janitor` (sweeper); changing the prefix in one without the other strands temp files.
- **Inspector struct must mirror `GitCtl.Inspector`.** `Git.Inspector` has an `@after_compile` hook that raises a `CompileError` if its fields drift from `GitCtl.Inspector`'s, because `struct/2` would otherwise silently drop unknown keys. Edit both structs together.
- **InspectorCache must stay supervised.** The ETS table is `:public` and accessed directly from transient `SessionDirectory` callers; the GenServer exists only to keep the table alive longer than they live.
- **Symbol extraction is regex, not AST.** `Symbols` is a line scanner — it matches the literal shapes (`defmodule`, `def`/`defp`/`defmacro`/`defguard`/`defdelegate`, ExUnit `test`/`describe`) and computes arity by counting top-level commas. It can miss multi-line heads or metaprogrammed defs. `.heex` returns `[]` by design.
- **Adapters are swappable via app env.** `:search_adapter` and `:git_adapter` select the implementation; tests point them at `MemoryAdapter` / fixtures. `GitCtl` config (`:git_ctl :cache_ttl_ms`, `:agent_inference`) tunes inspection.

## See also

- [`../architecture.md`](../architecture.md) — system purpose and first principles (server-side authority; UI reflects runtime truth).
- [`../glossary.md`](../glossary.md) — workspace/root term constraints.
- [`../terminal.md`](../terminal.md) — `SessionDirectory`, the main consumer of `Git.Inspector` for session labelling.
