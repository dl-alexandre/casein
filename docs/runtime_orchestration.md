# Runtime Orchestration v1

Runtime orchestration is DevIDE's bounded placement layer for JX runner
assignments. It records where approved safe actions should run, but it does not
add any execution power.

## Authority Boundary

- DevIDE still decides what can execute through policy checks and
  `DevIDE.Runners.SafeAction`.
- Runtime orchestration decides only environment placement: host, repo, branch,
  worktree path, tmux session binding, and concurrency.
- Runners stay policy-dumb. They poll, claim, execute the safe-action payload,
  and report.
- There is no shell/argv forwarding, no generic HTTP proxying, and no new
  runner mutation endpoint.

## Runtime Record

`DevIDE.Runtimes.Runtime` is the durable projection for a workspace execution
environment:

| Field | Meaning |
|---|---|
| `workspace_id` | Workspace whose safe actions may use the runtime |
| `host_id`, `os` | Host inventory match |
| `repo`, `branch` | Git placement identity |
| `worktree_path` | Modeled git worktree path under the workspace root |
| `runner_id`, `session_id`, `tmux_session_id` | Runner/session bindings |
| `isolation_mode` | Branch isolation mode, usually `worktree` |
| `status` | Runtime lifecycle projection |
| `capabilities`, `tools` | Host/runtime inventory used for placement |
| `concurrency_limit`, `active_assignments` | Placement capacity only |
| `created_at`, `heartbeat_at`, `expired_at` | Staleness and recovery timestamps |

Host capability inventory is stored separately in `DevIDE.Runtimes.Host`.
Lifecycle events are append-only `DevIDE.Runtimes.LifecycleEvent` records.

## Lifecycle

```
requested -> provisioned -> bound -> active -> idle -> expired -> cleaned
        \          \           \         \        \-> failed -> cleaned
         \----------\-----------\---------\---------------------------->
```

Valid placement events:

| Event | Transition |
|---|---|
| `runtime_requested` | `nil -> requested` |
| `runtime_provisioned` | `requested -> provisioned` |
| `runtime_bound` | `provisioned | idle -> bound` |
| `runtime_active` | `bound -> active` |
| `runtime_idle` | `active | bound -> idle` |
| `runtime_expired` | non-terminal runtime -> `expired` |
| `runtime_failed` | non-terminal runtime -> `failed` |
| `runtime_cleaned` | `expired | failed | idle -> cleaned` |

`Runtimes.project_lifecycle/1` reduces the event stream back to the current
status so recovery can verify that the stored projection matches append-only
history.

## Placement Rules

Placement is requested by adding runtime metadata to the existing assignment
enqueue path. DevIDE then:

1. Checks policy and safe-action authorization first.
2. Matches host inventory by workspace, host, OS, required tools/capabilities,
   repo, branch isolation mode, and host concurrency.
3. Reuses a compatible provisioned/idle runtime when capacity is available.
4. Otherwise creates a record-only git worktree model under the workspace root.
5. Binds the assignment by adding runtime routing metadata.

The runner claim still succeeds only through the existing poll endpoint and
safe-action capability match. Runtime fields never authorize commands.

## CLI

The DevIDE-owned CLI implementation backs JX-facing commands:

```bash
jx runtimes ls
jx runtimes show <runtime-id>
jx runtimes expire <runtime-id> --reason stale_runtime
jx runtimes cleanup
jx runtimes cleanup --stale
```

In this repo the same surface is available as:

```bash
mix jx.runtimes ls
mix jx.runtimes show <runtime-id>
mix jx.runtimes expire <runtime-id>
mix jx.runtimes cleanup
```

`expire` and `cleanup` update runtime records and append lifecycle events. v1
does not delete worktree directories or kill tmux sessions; those remain future
provisioner responsibilities.

## Recovery

- `expire_stale/2` marks old non-terminal runtimes as `expired` based on
  `heartbeat_at || created_at`.
- `cleanup_expired/2` moves expired runtimes to `cleaned`.
- A runtime event stream can be replayed with `project_lifecycle/1`.
- If projection and events disagree, the event stream is the recovery source of
  truth and the runtime row should be rebuilt from it.
