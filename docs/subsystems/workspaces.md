# Workspaces

> The workspace aggregate: the source-agnostic addressable unit (§FP-5), its
> pluggable discovery/lifecycle source, the observed-state cache, and the
> read-only DB-isolation classifier.

## Responsibility

A **workspace** is the thing operators interact with (§FP-5); the host it lives
on is an implementation detail. This subsystem owns:

- The public value struct `DevIDE.Workspace` (source-agnostic; extras in `metadata`).
- The `DevIDE.WorkspaceSource` behaviour and its default `Local` implementation
  (directory-on-disk discovery + lifecycle).
- The observed-state cache (`DevIDE.Workspaces.State` + `WorkspaceRecord` +
  swappable adapters) — the redacted snapshot of what the IDE has *seen*, plus
  the persisted workspace **mode**.
- Read-only **DB isolation** classification (`Isolation`, `IsolationProbe`,
  `DbIsolation`) — labels a workspace `:local | :ephemeral | :shared_stage |
  :unsafe | :unknown` without ever opening a connection or printing secrets.
- File/git access for a workspace location, local or over `ssh`
  (`FileAccess`, `SshRunner`).
- Cross-workspace read models and viewer-aliasing (`SessionSummary`, `Aliases`).

The consumer-facing facade is `DevIDE.Workspaces` (at `lib/casein/workspaces.ex`,
**outside** this directory): all LiveViews/channels/plugs depend on it, never on a
source. It also owns folder-attach (`folder:`-prefixed ids, base64url path) and
`allowed_roots/0`.

## Module map

| Module | File | Role |
|---|---|---|
| `DevIDE.Workspace` | `lib/casein/workspace.ex` | Public value struct: `id, name, user, branch, status, path, metadata`. Source-agnostic. |
| `DevIDE.WorkspaceSource` | `lib/casein/workspace_source.ex` | Behaviour for discovery/lifecycle + optional-callback dispatch helpers (`prepare_local_argv`, `local_tmux_pane_shell`, `local_exec_cwd`, `default_log_service`, `detect_capabilities`, `create_form_fields`); `impl/0` reads the configured module. |
| `DevIDE.WorkspaceSource.Local` | `lib/casein/workspace_source/local.ex` | Default source: workspaces = subdirs of `:workspaces_root`; `status: :running`; start/stop no-ops; `delete` refused unless `allow_destructive`; `safe_host_path` gate. |
| `DevIDE.Workspaces.State` | `lib/casein/workspaces/state.ex` | Persistence boundary: `sync/1`, `persist_isolation/2`, `set_mode/2`, `mode_for/1`; `sanitize_manager_payload/1` deny-list; mode-change PubSub. |
| `DevIDE.Workspaces.State.WorkspaceRecord` | `lib/casein/workspaces/state/workspace_record.ex` | Cache struct: observed status, resolved `mode`, redacted isolation snapshot, `manager_payload`, `last_seen_at`. |
| `DevIDE.Workspaces.State.Adapter` | `lib/casein/workspaces/state/adapter.ex` | Persistence behaviour: `upsert/1`, `get/1`, `list/0`, `delete/1`. |
| `DevIDE.Workspaces.State.MemoryAdapter` | `lib/casein/workspaces/state/memory_adapter.ex` | GenServer-backed in-memory adapter (tests + dev fallback; the default). |
| `DevIDE.Workspaces.State.EctoAdapter` | `lib/casein/workspaces/state/ecto_adapter.ex` | Postgres adapter; upserts on `external_id` conflict into `workspace_records`. |
| `DevIDE.Workspaces.DbIsolation` | `lib/casein/workspaces/db_isolation.ex` | Read-only isolation snapshot struct (`isolation, source, summary, detected_at, signals`); never carries raw credentials. |
| `DevIDE.Workspaces.Isolation` | `lib/casein/workspaces/isolation.ex` | Public isolation API: `detect/2` (delegates to probe), `shared?/1`, `unsafe?/1`. |
| `DevIDE.Workspaces.Isolation.Patterns` | `lib/casein/workspaces/isolation/patterns.ex` | Host-pattern matcher for `:shared_db_patterns` / `:unsafe_db_patterns` (substring or `~r//`). |
| `DevIDE.Workspaces.IsolationProbe` | `lib/casein/workspaces/isolation_probe.ex` | Probe behaviour: `detect/2 :: DbIsolation.t()`. |
| `DevIDE.Workspaces.IsolationProbe.LocalAdapter` | `lib/casein/workspaces/isolation_probe/local_adapter.ex` | Filesystem-only probe: manager payload → env files → compose; classifies + aggregates signals. Default probe. |
| `DevIDE.Workspaces.FileAccess` | `lib/casein/workspaces/file_access.ex` | `ls/read/read_text/write_text/search/git_*` over a `{:local,_}` / `{:remote,host,_}` loc; remote via `ssh`. |
| `DevIDE.Workspaces.SshRunner` | `lib/casein/workspaces/ssh_runner.ex` | Test seam over `ssh`; default `SshRunner.System` shells out via `System.cmd`/`Port`. |
| `DevIDE.Workspaces.SessionSummary` | `lib/casein/workspaces/session_summary.ex` | Cross-workspace read model for switchers/pickers; `build/1`, `build_many/1`, `orphan_tmux_sessions/1`; dedupes path/name aliases. |
| `DevIDE.Workspaces.Aliases` | `lib/casein/workspaces/aliases.ex` | Maps a workspace id to the set of viewer ids that share its on-disk path (`@moduledoc false`). |

## Data flow / lifecycle

### Discovery → sync (read path)

```
Workspaces.list/get ──► WorkspaceSource.impl().list|get ──► [%Workspace{}]
                                                              │
                                                              └─► State.sync/1
                                                                    │ sanitize_manager_payload
                                                                    ▼
                                                              adapter.upsert (WorkspaceRecord)
```

Every facade `list/2` and `get/2` opportunistically `State.sync/1`s each result.
`sync/1` maps the `%Workspace{}` onto a `WorkspaceRecord` keyed by `external_id`
(`ws.id`, falling back to `ws.name`), scrubs credentials from `metadata` via
`sanitize_manager_payload/1`, `merge_existing/1`s over any prior record, and
upserts. The source is the authority for existence/lifecycle; the record is a
**redacted observation cache**, only as fresh as the last sync.

### Folder-attach (facade-level)

Ids prefixed `folder:` carry a base64url absolute path. `Workspaces.get/2`,
`attach_folder/1`, and `decode_folder_id/1` reconstruct a `%Workspace{metadata:
%{attached_folder: true}}` directly (bypassing the source), gated by
`path_under_allowed_roots?/1`, and `State.sync/1` it.

### Mode resolution

Effective mode is resolved with explicit precedence:

1. **Config override** — `:workspace_modes` map keyed by workspace id.
2. **Persisted** — `WorkspaceRecord.mode`.
3. **Default** — `:default_workspace_mode` (or `:review`).

`State.mode_for/1` returns `{mode, :config_override | :persisted | :default}`.
`WorkspaceMode.resolve/1` (in `DevIDE.Policy`) covers tiers 1 and 3;
`mode_for/1` inserts the persisted tier. `State.set_mode/2` writes tier 2 and
broadcasts `{:workspace_mode_changed, external_id, mode}` to subscribers of
`subscribe_mode_changes/1`. Valid modes: `:manual | :review |
:agent_write_locked | :shared_stage_guarded`.

### DB isolation probe

```
Isolation.detect(workspace, root) ──► probe.detect/2 (LocalAdapter)
   gather signals: manager payload → .env* → compose ──► classify each
   ──► aggregate to one label ──► %DbIsolation{}  ──► State.persist_isolation/2
```

`LocalAdapter` reads `.env`/`.env.local`/`.env.dev`/`.env.development` and
a fixed set — `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml` (each ≤64 KiB, via `Files.PathSafety`),
classifies each host through `isolation_for_host/1` (local hosts → `:local`,
container service names → `:ephemeral`, `Patterns.shared?/1` → `:shared_stage`,
`Patterns.unsafe?/1` → `:unsafe`), then `aggregate/1` picks the most severe
(any `:unsafe`, or `:shared_stage` mixed with another signal, escalates to
`:unsafe`). Credentials in URLs are masked into a `host:port/db` `summary`. No DB
connection is ever opened.

### File access

`FileAccess` dispatches on the `{:local, root}` / `{:remote, host, root}` loc
returned by `Workspaces.safe_host_loc/1`. Local ops use `DevIDE.Files`/`Git`/
`Search`; remote ops shell to `ssh` via `SshRunner` using the user's
`~/.ssh/config` (no in-band credentials), with portable `ls -lAp` / `grep -rnIF`
/ `git` parsing, a 2 MiB read cap, and optimistic-concurrency `write_text`.

## Public surface

Code outside this subsystem should generally enter through the facade
`DevIDE.Workspaces` (`list/2`, `get/2`, `create/2`, `start/2`, `stop/2`,
`delete/3`, `safe_host_path/1`, `safe_host_loc/1`, `attach_folder/1`,
`allowed_roots/0`, ownership/forward-auth helpers). Within the subsystem the key
entry points are:

- `DevIDE.WorkspaceSource.impl/0` — the configured source module.
- `DevIDE.WorkspaceSource.{prepare_local_argv,local_tmux_pane_shell,local_exec_cwd,default_log_service,detect_capabilities,create_form_fields}` — optional-callback dispatch with safe defaults when a source doesn't export them.
- `DevIDE.Workspaces.State.{sync/1, get/1, list/0, delete/1, set_mode/2, mode_for/1, persist_isolation/2, subscribe_mode_changes/1, sanitize_manager_payload/1}`.
- `DevIDE.Workspaces.Isolation.{detect/2, shared?/1, unsafe?/1}`.
- `DevIDE.Workspaces.FileAccess.{ls,read,read_text,write_text,search,git_status_short,git_diff,label}/_`.
- `DevIDE.Workspaces.SessionSummary.{build/1, build_many/1, orphan_tmux_sessions/1, path_label/1}`.
- `DevIDE.Workspaces.Aliases.{viewer_ids/1, linked?/2, folder_id_for_path/1, viewer_route_id/1}`.

### Configurable adapters

| Config key | Default | Selects |
|---|---|---|
| `:workspace_source` | `DevIDE.WorkspaceSource.Local` | Discovery/lifecycle source |
| `:workspace_state_adapter` | `DevIDE.Workspaces.State.MemoryAdapter` | Record persistence |
| `:isolation_probe` | `DevIDE.Workspaces.IsolationProbe.LocalAdapter` | DB isolation probe |
| `:ssh_runner` | `DevIDE.Workspaces.SshRunner.System` | Remote `ssh` execution (test seam) |
| `:workspaces_root` / `:workspaces_roots` | `/workspaces` / `[]` | Allowed filesystem roots |
| `:workspace_modes`, `:default_workspace_mode` | `%{}`, `:review` | Mode override / default |
| `:shared_db_patterns`, `:unsafe_db_patterns` | `[]`, `[]` | Isolation host patterns |

## Invariants & gotchas

1. **Sources never leak.** All source-specific data lives in `Workspace.metadata`;
   generic code reads only well-known keys (`ports`, `domain_base`, `type` — see
   the metadata contract in `architecture.md`). Never branch on `source == X`;
   add an optional `WorkspaceSource` callback instead.
2. **The record is redacted and stale by design.** `sanitize_manager_payload/1`
   drops `database_url`/`password`/`token`/… top-level and nested, and redacts
   secret-looking `env`/`environment` entries to `KEY=[REDACTED]`. It captures
   *observed* state, not authority — the source is the truth for existence and
   lifecycle.
3. **Isolation is read-only and never connects.** `IsolationProbe.LocalAdapter`
   only reads bounded files through `PathSafety`, masks URL credentials, and never
   opens a DB connection.
4. **Aggregation escalates.** A `:shared_stage` signal mixed with any other
   distinct signal aggregates to `:unsafe` — a deliberately conservative default.
5. **`Local` is safe-by-default.** `start`/`stop` are `{:ok, :noop}`; `delete`
   returns `{:error, :destructive_not_allowed}` unless `allow_destructive: true`;
   `create`/`delete` reject names containing `/` or `.`/`..`.
6. **`safe_host_path`/`safe_host_loc` are the only sanctioned path gate.**
   `Local.safe_host_path/1` requires the expanded path to sit under
   `allowed_roots/0`; `FileAccess` always operates on the resulting loc.
7. **Folder-attach and aliasing live on the facade, not the source.**
   `folder:`-prefixed ids bypass the source; `Aliases.viewer_ids/1` unions a
   workspace with its `folder:` id and every manager record sharing the same
   expanded host path so MCP/preview broadcasts reach whatever tab is open.
8. **Mode-change is broadcast only on `set_mode/2`**, on topic
   `"workspace_mode:<external_id>"`; config-override and default modes emit no event.
9. `Aliases` is intentionally `@moduledoc false` (internal helper).

## See also

- [`../architecture.md`](../architecture.md) — §FP-5, metadata contract, authority/adapter maps, config keys.
- [`../state_machines.md`](../state_machines.md) — workspace mode lifecycle and DB-isolation-forces-`:shared_stage_guarded` rule.
- [`../workspace_sources.md`](../workspace_sources.md) — how to implement a `WorkspaceSource`.
- [`../terminal.md`](../terminal.md) — terminal sessions referenced by `SessionSummary`.
- [`../glossary.md`](../glossary.md) — operational terminology.
