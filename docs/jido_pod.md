# Headless Jido workspace pod

First slice of [#1014](https://github.com/dl-alexandre/casein/issues/1014)
(parent [#1012](https://github.com/dl-alexandre/casein/issues/1012)). Replaces
one OpenCode OS/TUI process per worker on the headless path with a
workspace-keyed OTP coordinator and short-lived child workers.

## Boundary

- **Casein** owns workspace scope, worktrees, admission, cancellation, and
  lifecycle identity.
- **Workers** call typed Casein Code actions (`code_read`, `code_search`,
  `code_apply_patch`, `code_exec`) from [#1013](https://github.com/dl-alexandre/casein/issues/1013).
  They do not open a shell, walk the filesystem, or require a tmux pane.
- **Typed catalog:** `Casein.Agents.JidoActions` (#1015) is the worker-facing
  action surface. This pod still calls `JidoPod.CodeActions` for the four
  Code tools; the catalog adds distinct results, human-input, and handoff.
- **Projection:** `Casein.Agents.JidoLifecycle` (#1016) consumes pod
  transitions without changing this admit/cancel/resume contract.
- **Skills / fallback:** `Casein.Agents.JidoSkills` (#1017) selects Jido vs
  OpenCode and records fallback reasons. `git_status` / `git_diff` /
  `task_wait` / `task_cancel` remain `not_yet_supported` on the typed catalog.
- **Budgets:** `Casein.Agents.JidoBudgets` (#1018) enforces fleet share,
  provider concurrency, memory, crash/lease, and host pressure. See
  [`jido_budgets.md`](jido_budgets.md).

## Runtime selection

Default is legacy OpenCode.

| Switch | Effect |
|--------|--------|
| `CASEIN_JIDO_HEADLESS=1` / `config :casein, :jido_headless, true` | All workspaces admit onto the Jido pod |
| `CASEIN_JIDO_HEADLESS_WORKSPACES=ws-a,ws-b` / `:jido_headless_workspaces` | Those workspace ids only |
| admit `runtime: :opencode` | Always legacy, even when the flag is on |
| admit `runtime: :jido` | Jido only when the flag or workspace override is on |

`Casein.Agents.JidoPod.admit/1` returns `{:error, :legacy_opencode}` when the
legacy path is selected so callers can keep launching OpenCode.

## Manager MCP

External managers use Terminal MCP tools backed by
`Casein.Agents.JidoDelegate`:

| Tool | Role |
|------|------|
| `jido_admit` | Select + admit typed CodeTools actions (`code_read` / `code_search` / `code_apply_patch` / `code_exec`). Omit `runtime` to choose Jido when the workspace flag is on. |
| `jido_status` | Headless status/result (`headless: true`, no `pane_id`) |
| `jido_cancel` | Cancel one attempt |

`runtime: opencode` or a disabled workspace returns `{fallback?: true,
next_tool: "worker_launch"}` and starts no pod. Terminal/shell actions are
rejected at admit. See [`delegate-to-worker`](../.claude/skills/delegate-to-worker/SKILL.md).

## Lifecycle

`admitted → queued | running → awaiting_human | retrying | completed | failed | cancelled | timed_out | provider_unavailable`

- Per-workspace running and queue caps (defaults 2 / 4).
- Fleet-wide running cap (default 8) with least-running waiter fairness.
- Admit past the queue cap returns `{:error, :backpressure}`.
- A crashed worker is recorded, the fleet lease is released, and the attempt
  retries from the last completed action index (mutations are not replayed).
- Status is headless: `headless: true` and no `pane_id`. A missing tmux pane
  is not treated as a running worker.
- Transitions record `Casein.Agents.Activity` with `source: :jido_pod`.

## Limits

```elixir
config :casein, :jido_pod,
  max_running_per_workspace: 2,
  max_queued_per_workspace: 4,
  max_running_fleet: 8,
  max_share_per_workspace: 0.5,
  max_provider_inflight: 4,
  max_worker_memory_bytes: 2_000_000,
  max_action_output_bytes: 256_000,
  default_attempt_deadline_ms: 60_000,
  default_action_timeout_ms: 5_000,
  max_retries: 1
```

`Casein.Agents.JidoPod.snapshot/1` and `benchmark/1` expose process count,
memory, latency, throughput, and the documented OpenCode baseline
(one OS/TUI process + pane per worker). Full scenario comparison and
go/no-go live in `Casein.Agents.JidoBudgets.benchmark/1`.
