# Runtimes

> Record-only registry that projects where a workspace's work has executed — hosts, agent worktrees, and their lifecycle — without ever holding command-execution authority.

## Responsibility

`DevIDE.Runtimes` is a **record-only** service. After the fleet + runner-assignment
removal, the architecture collapsed to a single runtime per workspace: there is no
dynamic placement, no host *selection* engine, no assignment scheduler. The
subsystem stores where work *has* run, not where it *should* run, and never accepts
argv, shells, HTTP proxy targets, or mutation commands (see the `@moduledoc` on
`lib/dev_ide/runtimes.ex` and `DevIDE.Runtimes.StateMachine`).

Its live jobs are:

- **Host registry** — `list_hosts/0` feeds the workspace picker (where a new
  workspace can run).
- **Agent worktree discovery** — agents report the git worktrees they create via
  `observe_worktree/2`; `list_agent_worktrees/1` lists them for the workspace show
  view, agent events, and terminal MCP.
- **Status export** — `list_runtimes/1` / `get_runtime/1` snapshot runtimes for the
  read API and `Export.WorkspaceStatus`.
- **Maintenance** — `heartbeat/2`, `expire_runtime/2` (plus a stale sweep),
  `cleanup_runtime/2` for TTL eviction, driven from the runtimes CLI.

## Module map

| Module | File | Role |
| --- | --- | --- |
| `DevIDE.Runtimes` | `lib/dev_ide/runtimes.ex` | Context + adapter behaviour. Public API, agent-worktree validation/upsert, lifecycle transitions, payload shaping. (Sibling of the assigned dir; the rest of the table lives under it.) |
| `DevIDE.Runtimes.Runtime` | `lib/dev_ide/runtimes/runtime.ex` | Durable projection struct of a workspace execution environment. |
| `DevIDE.Runtimes.Host` | `lib/dev_ide/runtimes/host.ex` | Host capability-inventory struct used for placement context. |
| `DevIDE.Runtimes.LifecycleEvent` | `lib/dev_ide/runtimes/lifecycle_event.ex` | Append-only lifecycle event struct (the event stream that projects status). |
| `DevIDE.Runtimes.Profile` | `lib/dev_ide/runtimes/profile.ex` | Normalizes dev-server *intent* (command/ports/surfaces) into metadata; builds preview-surface payloads. Metadata only — no execution. |
| `DevIDE.Runtimes.StateMachine` | `lib/dev_ide/runtimes/state_machine.ex` | Lifecycle transition rules + event-stream reducer (`reduce/1`). |
| `DevIDE.Runtimes.EctoAdapter` | `lib/dev_ide/runtimes/ecto_adapter.ex` | Postgres-backed adapter (prod/dev). Implements the `DevIDE.Runtimes` behaviour. |
| `DevIDE.Runtimes.MemoryAdapter` | `lib/dev_ide/runtimes/memory_adapter.ex` | In-memory GenServer adapter (test). Implements the behaviour. |
| `DevIDE.Runtimes.RuntimeRow` | `lib/dev_ide/runtimes/runtime_row.ex` | Ecto schema for `workspace_runtimes`. |
| `DevIDE.Runtimes.HostRow` | `lib/dev_ide/runtimes/host_row.ex` | Ecto schema for `runtime_hosts`. |
| `DevIDE.Runtimes.LifecycleEventRow` | `lib/dev_ide/runtimes/lifecycle_event_row.ex` | Ecto schema for `runtime_lifecycle_events`. |

## Data flow / lifecycle

**Adapter selection.** All persistence goes through `impl/0`, which reads
`config :dev_ide, :runtimes_adapter` (default `MemoryAdapter`). `config/config.exs`
sets `EctoAdapter`; `config/test.exs` sets `MemoryAdapter`. Both satisfy the
`@callback`s declared on `DevIDE.Runtimes`. The `MemoryAdapter` is a named
`GenServer` and must be supervised when used.

**Agent worktree observation** (`observe_worktree/2`, the primary write path):

1. Load the parent `Workspaces.State.WorkspaceRecord` for `workspace_id`.
2. Resolve `worktree_path` (from `worktree_path` / `runtime_path` / `path`),
   expanded against the workspace `host_path`; must be an existing directory.
3. `Git.Inspector.inspect_cwd/1` reads git facts (toplevel, branch, common dir,
   head sha, worktree?/detached?).
4. `validate_agent_worktree/3` admits the path only if it sits under the workspace
   root, **or** under an allowed agent-worktree root *and* its git common dir proves
   it belongs to the parent workspace's repo. The workspace's own main checkout is
   rejected (`:main_checkout_not_allowed`).
5. `upsert_agent_worktree_runtime/4` creates or updates the `Runtime` with
   `isolation_mode: "worktree"` and `metadata["kind"] = "agent_worktree"`. New
   runtimes are written `requested` → then immediately transitioned to
   `provisioned` (two events); existing ones get a `runtime_heartbeat` event.

**Status projection.** Status lives on the `Runtime` row but is *also* derivable
from the event stream: `StateMachine.reduce/1` folds `LifecycleEvent`s through
`transition_event/2`. Valid statuses are `requested → provisioned → expired →
cleaned` (with `requested`/`provisioned → cleaned` shortcuts); `cleaned` is
terminal. `runtime_heartbeat` events do not change status.

**Maintenance.** `expire_stale/2` lists all runtimes, filters by TTL
(`@default_ttl_seconds = 3600`, against heartbeat-or-creation time), and expires
them. `cleanup_expired/2` then transitions `expired` runtimes to `cleaned`. The CLI
`cleanup --stale` runs both in sequence.

## Public surface

Called by API / LiveView / MCP / export code:

- `register_host/1`, `get_host/1`, `list_hosts/0` — host registry.
- `observe_worktree/2` — record an agent-created worktree (validated).
- `list_agent_worktrees/1` — worktree payloads for a workspace, newest-active first,
  excluding `cleaned`/`expired`/`failed`.
- `list_runtimes/1`, `get_runtime/1` — snapshots (filters normalized to string keys:
  `workspace_id`, `host_id`/`host`, `status`, `repo`, `branch`,
  `isolation_mode`/`branch_isolation`, `runtime_id`/`id`).
- `heartbeat/2`, `expire_runtime/2`, `cleanup_runtime/2` — lifecycle mutations
  (each appends a `LifecycleEvent`).
- `expire_stale/2`, `cleanup_expired/2` — TTL sweeps.
- `payload/1`, `event_payload/1` — read-API JSON shapes; `payload/1` inlines
  `runtime_profile` and `preview_surfaces` via `Profile`.
- `runtime_profile/1`, `runtime_preview_surfaces/1` — profile/preview accessors.
- `decorate_assignment_metadata/1`, `runtime_id_from_metadata/1` — enrich assignment
  metadata read surfaces with the current runtime projection.
- `project_lifecycle/1` — delegates to `StateMachine.reduce/1`.

`DevIDE.Runtimes.Profile`: `from_attrs/1`, `normalize/1`, `for_runtime/1`,
`preview_surfaces/2`. Builtins: `phoenix` (:4000), `vite` (:5173), `static` (:8000),
`custom`.

Processes: only `MemoryAdapter` is a long-lived process (test-only GenServer). The
`EctoAdapter` and the context are stateless modules.

## Invariants & gotchas

- **Record-only.** Nothing here executes commands, starts Docker, or spawns a shell.
  `Profile` is *intent metadata* for a future provisioner; it carries a `command`
  field but never runs it.
- **Single runtime, no fleet.** Placement/orchestration/runner-assignment was
  removed. Treat any "fleet"/"runner picks work" language as historical.
- **Agent-worktree admission is a security boundary.** Paths must be under the
  workspace root or a configured agent-worktree root (`:agent_worktree_roots` config,
  `DEV_IDE_AGENT_WORKTREE_ROOTS` env, plus defaults like
  `$TMPDIR/devide-agent-worktrees`, `~/.claude`, `~/.local/share/{opencode,codex}`).
  The main checkout is explicitly refused.
- **`isolation_mode`** for observed worktrees is always `"worktree"`; `host_id`
  defaults to `"local"`.
- **`events_for/1` is intentionally unbounded** (see the audit note in
  `EctoAdapter`): replay/export need the full history, and counts stay small. Switch
  to a `:limit` with a visible banner only past ~500, never a silent cap.
- **Status is doubly sourced** — stored on the row and reducible from events. Keep
  them consistent; transitions go through the context (which appends an event), not
  by mutating the row directly.
- **`@moduledoc false`** on the three `*Row` schemas is deliberate (they are
  storage-only Ecto schemas with no public behaviour).

## See also

- [../architecture.md](../architecture.md) — single-runtime cockpit framing; FP-2/FP-6/FP-7 removal.
- [../glossary.md](../glossary.md) — definitions of *Runtime*, *Host*, *Capability*, *Agent*.
- [../state_machines.md](../state_machines.md) — runtime-orchestration lifecycle in the broader state-machine catalog.
- [../workspace_sources.md](../workspace_sources.md) — workspace ↔ source/host mapping.
- [../preview_mcp.md](../preview_mcp.md) — consumer of `Profile.preview_surfaces/2`.
