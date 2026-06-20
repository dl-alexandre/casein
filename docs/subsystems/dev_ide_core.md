# dev_ide_core — generic BEAM primitives

> Dependency-free, app-agnostic BEAM building blocks — OS process execution,
> git worktree inspection, and MCP tool-schema fragments — that the DevIDE app
> facades delegate into. It holds the mechanism; the policy stays in `DevIDE.*`.

## Responsibility

`dev_ide_core` is a separate Mix project, wired into the app as a path
dependency (`{:dev_ide_core, path: "dev_ide_core"}`, `mix.exs:87`). It ships
three leaf libraries — `ExecCtl`, `GitCtl`, `McpCtl` — each its own `Boundary`
with `deps: []`. The package root `DevIdeCore` (`dev_ide_core/lib/dev_ide_core.ex`)
is a thin documentation/convenience facade over the three; the libraries carry
no dependency on each other and may be used directly.

**What lives here vs. in the `lib/dev_ide` app.** The split is mechanism vs.
policy:

- **Here (generic):** subprocess spawn + output streaming over erlexec, the
  static command-id→argv map, git `rev-parse` parsing + ETS result caching, and
  reusable JSON-schema fragments / error normalization for MCP tool definitions.
  None of these read DevIDE workspace state, audit, or `Policy`.
- **In the app (`DevIDE.*`):** the *decisions* and side effects — audit logging,
  `DevIDE.Policy` admission, workspace-scoped argv building, agent-naming
  conventions, the actual MCP tool *implementations* (`DevIDE.Agents.*Tools`),
  and mutating git ops. The app facades wrap or delegate into the core libraries.

**Why a path package.** Pulling these out keeps the schema/argv/inspection
primitives dependency-free (each is its own boundary with no edges to the
DevIDE domain), so they compile and test standalone and could be extracted to
a generic `dev_ide_core` Hex package before a 1.0. The `@moduledoc`s for
`DevIdeCore`, `McpCtl`, and `McpCtl.Schema`/`McpCtl.Params` flag that those two
McpCtl modules still encode DevIDE-specific vocabulary (workspace ids, folder
attachment, tmux/preview wording) in their description strings and are slated
for a host-configurable vocabulary scrub before that generic 1.0.

## The three libraries

### ExecCtl — OS process execution + command allowlist

| Module | File | Role |
|--------|------|------|
| `ExecCtl` | `dev_ide_core/lib/exec_ctl.ex` | Boundary root (`deps: []`). erlexec streaming + static allowlists live here; DevIDE audit/policy/argv-building stays in `DevIDE.Commands.*`. |
| `ExecCtl.Allowlist` | `dev_ide_core/lib/exec_ctl/allowlist.ex` | **Authoritative** static `id → argv` map (`compile`, `test`, `format`, `precommit`, `assets.build`, `agent`, `claude`, `clauded`, `codex`, `grok`, `opencode`, `dogfood.fail`). `all/0`, `allowed?/1`, `argv_for/1`. No shell interpolation. |
| `ExecCtl.Port` | `dev_ide_core/lib/exec_ctl/port.ex` | erlexec port plumbing: spawn an OS process via `:exec.run/2` under a linked proxy + `:monitor`, stream `{:cmd_data, ref, :stdout\|:stderr, binary}` to a subscriber, deliver exactly one `{:cmd_exit, ref, exit_code \| {:error, reason}}`. 30s spawn timeout, 24h watchdog, `kill/1` via `:exec.kill(ospid, 15)`. |

### GitCtl — git worktree inspection + cache

| Module | File | Role |
|--------|------|------|
| `GitCtl` | `dev_ide_core/lib/git_ctl.ex` | Boundary root (`deps: []`). Subprocess parsing + optional ETS caching live here; DevIDE workspace policy and mutating git ops stay in `DevIDE.Git.*`. |
| `GitCtl.Inspector` | `dev_ide_core/lib/git_ctl/inspector.ex` | `inspect_cwd/1` → `{:ok, %GitCtl.Inspector{}}` \| `:error`. Single `git rev-parse --path-format=absolute …` parse yielding `toplevel`, `git_dir`, `git_common_dir`, `branch`, `head_sha`, `worktree?`, `detached?`, and a host-injected `agent`. Reads through `GitCtl.Cache`. |
| `GitCtl.Cache` | `dev_ide_core/lib/git_ctl/cache.ex` | `@moduledoc false`. Per-cwd ETS result cache with monotonic TTL (`lookup/2`, `store/2`, `table/0`, `ttl_ms/0`). Table name and TTL come from `:git_ctl` app env; ETS errors are rescued to `:miss`/`:ok` (the library never owns the table). |

### McpCtl — MCP tool-definition schema fragments + error normalization

| Module | File | Role |
|--------|------|------|
| `McpCtl` | `dev_ide_core/lib/mcp_ctl.ex` | Boundary root (`deps: []`). Schema fragments shared across DevIDE's agent-facing tools; the tool *implementations* stay in `DevIDE.Agents.*Tools`. |
| `McpCtl.Tool` | `dev_ide_core/lib/mcp_ctl/tool.ex` | `define/3` builds a `%{name, description, parameters}` tool map; `object/2` builds a JSON-schema `object` with `properties`/`required`. Already generic. |
| `McpCtl.Schema` | `dev_ide_core/lib/mcp_ctl/schema.ex` | Workspace-scoping JSON-schema fragments: `workspace_id_param/1` (`:terminal` vs `:preview` variant), `workspace_path_param/0`, `workspace_object/1`, `merge_workspace_properties/2`. Encodes DevIDE workspace-id / folder-attachment wording. |
| `McpCtl.Params` | `dev_ide_core/lib/mcp_ctl/params.ex` | Reusable per-field parameter fragments (`session`, `pane`, `lines`, `ansi`, `surface`, `selector`, `storage_profile`, `default_headers`, `preview_open_props`, `terminal_workspace_props`, …). Encodes tmux/preview vocabulary in descriptions. |
| `McpCtl.Error` | `dev_ide_core/lib/mcp_ctl/error.ex` | Normalizes a tool handler's `{:error, reason}` (atom / tuple / map / binary) into MCP-friendly payloads: `format/1`, `summary/1`, and `tool_result/1` (`%{content, structuredContent, isError: true}`). Already generic. |

## Delegation boundary

The DevIDE domain (`DevIDE` boundary in `lib/dev_ide_domain.ex`) lists `GitCtl`,
`ExecCtl`, and `McpCtl` among its allowed `deps`, and these app modules delegate
into them:

| Core module | DevIDE app delegator | Shape |
|-------------|----------------------|-------|
| `ExecCtl.Allowlist` | `DevIDE.Commands.Allowlist` (`lib/dev_ide/commands/allowlist.ex`) | Thin `defdelegate all/0`, `allowed?/1`, `argv_for/1`. The real id→argv map is in core; this is the source of truth. |
| `ExecCtl.Allowlist` (transitively) | `DevIDE.Commands` → `DevIDE.Policy` | `DevIDE.Commands.allowed?/1` re-exports the delegate; `DevIDE.Policy.can_run_command?/1` gates on `command_allowed?/1`, which calls `DevIDE.Commands.allowed?/1` (i.e. `ExecCtl.Allowlist.allowed?/1`) or a workflow command. |
| `GitCtl.Inspector` | `DevIDE.Git.Inspector` (`lib/dev_ide/git/inspector.ex`) | `inspect_cwd/1` delegates to `GitCtl.Inspector.inspect_cwd/1` and maps `%GitCtl.Inspector{}` → its own mirror struct. `infer_agent/1` is DevIDE workspace policy injected back into `GitCtl` via `config :git_ctl, agent_inference: {mod, fun}`. An `@after_compile` guard raises if the two structs' fields drift apart. |
| `GitCtl.Cache` | `DevIDE.Git.Inspector` / `DevIDE.Git.InspectorCache` (`lib/dev_ide/git/inspector_cache.ex`) | The app owns the ETS table named by `GitCtl.Cache.table/0` (created in a supervised `InspectorCache` GenServer); `GitCtl.Cache` only reads/writes it. |
| `McpCtl.Error` | `DevIDE.Agents.MCPError` (`lib/dev_ide/agents/mcp_error.ex`) | Thin `defdelegate format/1`, `summary/1`, `tool_result/1`. |
| `McpCtl.Tool` / `McpCtl.Params` / `McpCtl.Schema` | `DevIDE.Agents.TerminalTools`, `DevIDE.Agents.PreviewTools`, `DevIDE.Agents.AnnotationTools` | The tool modules `alias McpCtl.{Params, Tool}` and build their `definitions/0` from these fragments (`@type tool :: McpCtl.Tool.t()`). |

The authoritative allowlist arrow is worth stating plainly: **`ExecCtl.Allowlist`
is the real command map; `DevIDE.Commands.Allowlist` is a `defdelegate` wrapper,
and `DevIDE.Policy` admits a command id only if `ExecCtl.Allowlist` (via
`DevIDE.Commands`) knows it.** This is what `coverage_map.md` and the palette /
CLI references mean by "source of truth lives outside the assigned subsystem
paths."

## Public surface

- `ExecCtl.Allowlist.all/0`, `allowed?/1`, `argv_for/1` — the static command map.
- `ExecCtl.Port.run/3` (argv, erlexec opts, subscriber pid), `ExecCtl.Port.kill/1` — streaming subprocess execution.
- `GitCtl.Inspector.inspect_cwd/1` — worktree/checkout context (cached).
- `GitCtl.Cache.table/0`, `ttl_ms/0`, `lookup/2`, `store/2` — cache plumbing the host wires to its own ETS table.
- `McpCtl.Tool.define/3`, `McpCtl.Tool.object/2` — tool-definition map builders.
- `McpCtl.Schema.workspace_id_param/1`, `workspace_object/1`, `merge_workspace_properties/2` — workspace-scoping schema fragments.
- `McpCtl.Params.*` — per-field parameter fragments (terminal + preview tool params).
- `McpCtl.Error.format/1`, `summary/1`, `tool_result/1` — error normalization.
- `DevIdeCore` facade: `git_inspect/1` → `GitCtl.Inspector.inspect_cwd/1`; `exec_run/3` → `ExecCtl.Port.run/3`; `mcp_tool/3` → `McpCtl.Tool.define/3`.

## Invariants & gotchas

- **erlexec is the runtime dependency for `ExecCtl.Port`.** `dev_ide_core`'s
  `application/0` lists `extra_applications: [:logger, :erlexec]` — erlexec must
  be started, but `git` is an external binary, not an OTP app. `ExecCtl.Port`
  packs the OS exit status itself (`exit_code_of/1`: `status >> 8` on clean
  exit, `128 + signal` on signal death) and guarantees exactly one `:cmd_exit`.
- **Each library is a closed boundary (`deps: []`).** None of `ExecCtl`,
  `GitCtl`, `McpCtl` may depend on each other or on `DevIDE.*`. Keep host policy
  out: agent naming, audit, workspace scoping, and admission decisions belong in
  the app, not here.
- **These modules accept no app config beyond a narrow injection seam.**
  `GitCtl` reads only `:git_ctl` app env (`cache_table`, `cache_ttl_ms`,
  `agent_inference`); the `agent_inference` MFA/fun is the *only* way host
  conventions enter inspection (without it `:agent` stays `nil`). `GitCtl.Cache`
  rescues ETS `ArgumentError` to `:miss`/`:ok` because it does not own the table
  — the host (`DevIDE.Git.InspectorCache`) must create it.
- **`DevIDE.Git.Inspector` mirrors `GitCtl.Inspector`'s struct under an
  `@after_compile` guard.** Add a field to one and you must add it to the other,
  or the app fails to compile.
- **`McpCtl.Schema` / `McpCtl.Params` are not yet generic.** Their description
  strings hardcode DevIDE vocabulary (workspace ids, folder attachment,
  tmux/preview surfaces); `McpCtl.Tool` and `McpCtl.Error` already are generic.
  Treat the schema/params wording as DevIDE-coupled until the planned scrub.

## See also

- [`../reference/mcp_tools.md`](../reference/mcp_tools.md) — the agent-facing MCP
  tool catalog whose definitions are assembled from `McpCtl.Tool`/`Schema`/`Params`.
- [`code_intelligence.md`](code_intelligence.md) — `DevIDE.Git.Inspector` and the
  app-side git facade that delegates worktree detection into `GitCtl`.
- [`policy_deploy_export.md`](policy_deploy_export.md) — `DevIDE.Policy`, which
  admits command ids via the `ExecCtl.Allowlist`-backed `DevIDE.Commands` check.
- [`palette_commands.md`](palette_commands.md) +
  [`../reference/cli_and_keys.md`](../reference/cli_and_keys.md) — the palette /
  CLI surface that enumerates the `ExecCtl.Allowlist` command ids.
- [`../coverage_map.md`](../coverage_map.md) — the doc↔code coverage map that
  flagged `dev_ide_core/lib/*` as the unowned subsystem this doc now covers.
