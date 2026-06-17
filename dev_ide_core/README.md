# DevIdeCore

Generic BEAM primitives extracted from [DevIDE](../) — the dependency-free
floor that the full IDE product builds on. No Phoenix, no Ecto, no LiveView.

This package houses three already-boundary-isolated leaf libraries:

| Library   | Purpose                              | External requirement |
| --------- | ------------------------------------ | -------------------- |
| `ExecCtl` | OS process spawn + output streaming  | `erlexec` (hex dep)  |
| `GitCtl`  | git worktree/branch inspection       | `git` on `PATH`      |
| `McpCtl`  | MCP tool-definition schema builders  | none                 |

## Status: v0.1 skeleton (path-dep, not published)

This is a **standalone, additive extraction**. It is *not* yet wired into the
parent `dev_ide` app, because doing so requires removing the in-tree copies of
these libraries first (otherwise the modules `ExecCtl`/`GitCtl`/`McpCtl` are
defined twice and compilation fails).

### Promoting it to a real path dep (separate, deliberate step)

1. Delete the in-tree originals from the parent:
   `lib/exec_ctl{,.ex} lib/git_ctl{,.ex} lib/mcp_ctl{,.ex}`
2. Add to the parent `mix.exs` deps: `{:dev_ide_core, path: "dev_ide_core"}`
3. The parent's `DevIDE` boundary already lists `ExecCtl, GitCtl, McpCtl` as
   deps — those edges stay valid; only the compile source moves.

## Known pre-1.0 work

- `McpCtl.Schema` / `McpCtl.Params` embed DevIDE vocabulary (workspace ids,
  folder attachment, tmux/preview wording) in runtime description strings.
  Generic-ize via host config before publishing. `McpCtl.Tool` / `McpCtl.Error`
  are already clean.
