# CLI & Keys — external surface reference

> The operator-facing entrypoints into DevIDE: the `devide` operator CLI, the
> mix tasks, the static command allowlist that gates palette/agent runs, and
> the `C-b` leader-key bindings the cockpit hands to the keyboard.

This is a **reference** for the external surface — what a human or agent can
invoke from outside Elixir code. For the narrative on *why* the leader keys are
shaped the way they are (the tmux-convention contract, picker navigation, the
adoption roadmap), the authoritative doc is
[`../leader_keys.md`](../leader_keys.md); this doc only catalogs the surface and
cross-links it.

## Responsibility

Expose and gate the small set of named, argv-style entrypoints DevIDE offers to
operators and agents — and nothing more. Three concerns live here:

1. **Operator CLI** — `jx runtimes …` (the Elixir `DevIDE.CLI` dispatcher, per the
   code's usage strings) and the separate `devide` bash launcher
   (`agent` / `mcp` subcommands) for agent bring-up.
2. **Command allowlist** — a static `id → argv` map. The palette, run panel, and
   review-agent runner may only invoke an id that exists in it; there is no
   shell interpolation and no free-form argv path.
3. **Leader keys** — the browser-side `C-b` prefix system that aliases keyboard
   shortcuts to existing `phx-click` handlers. Keys only route to clicks; all
   business logic stays in LiveView (see [`../leader_keys.md`](../leader_keys.md)).

## Module map

| Module / file | File | Role |
| --- | --- | --- |
| `DevIDE.CLI` | `lib/dev_ide/cli.ex` | Top dispatcher: routes `["runtimes" \| args]` to the runtimes CLI; otherwise returns usage. (Sibling of the assigned `cli/` dir.) |
| `DevIDE.CLI.Runtimes` | `lib/dev_ide/cli/runtimes.ex` | Read/control CLI for runtime records: `ls`, `show <id>`, `expire <id>`, `cleanup [id] [--stale]`. Returns `{:ok, text}` / `{:error, msg}`. |
| `DevIDE.Commands` | `lib/dev_ide/commands.ex` | Re-exports allowlist enumeration; owns the only remaining executor — a local erlexec `spawn/3` used by `DevIDE.Agents.Run`. (Sibling of the assigned `commands/` dir.) |
| `DevIDE.Commands.Allowlist` | `lib/dev_ide/commands/allowlist.ex` | Thin `defdelegate` facade to `ExecCtl.Allowlist` so palette/read-only callers enumerate ids without the execution graph. |
| `ExecCtl.Allowlist` | `dev_ide_core/lib/exec_ctl/allowlist.ex` | The canonical static `id → argv` map (`all/0`, `allowed?/1`, `argv_for/1`). Lives in the core boundary. |
| `Mix.Tasks.DevIde.Preview.Demo` | `lib/mix/tasks/dev_ide.preview.demo.ex` | `mix dev_ide.preview.demo` — live demo of the agent-first preview loop against a v3 workspace. |
| `WorkspaceLeader` (JS hook) | `assets/js/workspace_leader.js` | `C-b` leader system + `Space`→focus-terminal; captures keydown before the terminal, dispatches to `[data-leader-action]`. |

The `scripts/devide` bash launcher (`agent launch\|env\|doctor`, `mcp ensure`) is
the operator's PATH entrypoint for agent bring-up; it does not call into Elixir
and is documented under AGENTS.md, not here.

## Data flow / lifecycle

### Operator runtimes CLI

`DevIDE.CLI.run(argv)` → `DevIDE.CLI.Runtimes.run(argv)` → `DevIDE.Runtimes`
context. Each verb returns a tagged result the caller renders:

- `ls [--workspace W] [--status S]` → tab-separated table from
  `Runtimes.list_runtimes/1` (header row + one line per runtime).
- `show <id>` → `Runtimes.payload/1` merged with `events_for/1`, JSON-encoded
  pretty; `:error` → `"runtime not found: <id>"`.
- `expire <id> [--reason R]` → `Runtimes.expire_runtime/2` (default reason
  `"operator_expired"`).
- `cleanup <id>` → single-runtime `Runtimes.cleanup_runtime/1`.
- `cleanup [--stale]` (bulk) → `Runtimes.expire_stale/1` (only with `--stale`)
  then always `Runtimes.cleanup_expired/0`; reports `expired=N cleaned=M`.

### Command allowlist gating

`DevIDE.Palette.Actions` / `WorkspaceLive.Show.RunPanel` enumerate ids via
the `DevIDE.Commands.Allowlist.all/0` facade → `ExecCtl.Allowlist`. A run
request is checked with `allowed?/1` and resolved to argv with `argv_for/1`;
unknown ids cannot reach `DevIDE.Commands.spawn/3`. The spawn path streams
`{:cmd_data, ref, :stdout|:stderr, bin}` and `{:cmd_exit, ref, code}` to the
subscriber pid (no PTY, line-buffered).

### Leader-key dispatch

Browser `keydown` (capture phase, on the persistent workspace container) →
`WorkspaceLeader._handleKeydown`. `C-b` arms leader mode (`<body
data-leader-active>`); the next key is looked up in the `LEADER_ACTIONS` map
and routed to a single hidden `[data-leader-action="<name>"]` element, whose
`phx-click` the server already handles. Digits `1`–`9` click
`[data-tmux-window-index]`; `C-b q` opens a client-only pane-index overlay.
Leader has **no auto-timeout** — it stays armed until the second key, `Escape`,
or a second `C-b`. Full navigation/picker semantics: [`../leader_keys.md`](../leader_keys.md).

## Public surface

Functions and entrypoints other code (or operators) call:

- **`DevIDE.CLI.run/1`** — operator dispatcher; the `devide` Elixir surface.
- **`DevIDE.CLI.Runtimes.run/1`** — runtimes verbs (`ls`/`show`/`expire`/`cleanup`).
- **`DevIDE.Commands.allowlist/0`, `allowed?/1`, `argv_for/1`** — allowlist
  enumeration/lookup (delegate chain to `ExecCtl.Allowlist`).
- **`DevIDE.Commands.spawn/3`, `kill/1`** — the only local executor; argv must
  come from a resolved allowlist id.
- **`ExecCtl.Allowlist.all/0` / `allowed?/1` / `argv_for/1`** — canonical map.
- **`mix dev_ide.preview.demo [name] [--surface S] [--adapter memory|playwright]`**
  — runs `Mix.Tasks.DevIde.Preview.Demo.run/1` (requires `app.start`, runs
  `ecto.migrate`, then exercises `DevIDE.PreviewControl`).
- **`WorkspaceLeader` hook** (`phx-hook="WorkspaceLeader"`) — the keyboard
  surface; pushes events like `mobile_nav:open`, `tmux:select_pane`,
  `terminal:scheme`, `terminal:set_preset` to the Show LiveView.

### Allowlisted command ids (current)

From `ExecCtl.Allowlist`: `compile`, `test`, `format`, `precommit`,
`assets.build`, `agent`, `claude`, `clauded`, `codex`, `grok`, `opencode`, and
`dogfood.fail` (a deliberate non-zero-exit fixture). This map is the source of
truth for the run panel and palette command items.

### Leader bindings (catalog)

The `LEADER_ACTIONS` map in `workspace_leader.js`. All require the `C-b` prefix
first; full descriptions and tmux mapping live in
[`../leader_keys.md`](../leader_keys.md).

| Key(s) | Action |
| --- | --- |
| `s` / `w` | `session-picker` / `window-picker` |
| `c` / `C` | `new-window` / `new-window-tab` |
| `n` / `p` / `l` | `next-window` / `prev-window` / `last-window` |
| `1`–`9` | select window (`[data-tmux-window-index]`) |
| `,` / `&` | `rename-window` / `kill-window` |
| `d` | `detach` |
| `%` `\|` / `"` `-` | `split-right` / `split-down` |
| `z` / `x` / `o` / `;` | `zoom` / `close-pane` / `pane-next` / `last-pane` |
| `q` | `pane-overlay` (client-only index overlay; `0`–`9` to focus) |
| `←` `↓` `↑` `→` | `pane-left` / `pane-down` / `pane-up` / `pane-right` |
| `y` | `copy-link` (full-view link) |
| `:` / `?` | `palette` / `help` |
| `Space` (no prefix) | focus active terminal when nothing interactive is focused |
| `C-b` / `Escape` (armed) | cancel leader mode |

## Invariants & gotchas

- **Allowlist is the only argv source.** `DevIDE.Commands.spawn/3` runs fixed
  argv resolved from an allowlist id; there is no free-form / shell-interpolated
  path. Adding a runnable command means editing `ExecCtl.Allowlist` (FP-1:
  execution authority is server-side).
- **`cleanup` flag-vs-id clause ordering.** `run(["cleanup", "--" <> _ | rest])`
  must precede the single-id clause, or a flag like `--stale` is swallowed as a
  runtime id. Bulk `expire_stale/1` only runs *with* `--stale`; `cleanup_expired/0`
  always runs.
- **Leader keys route to clicks, never keystrokes.** Each action maps to exactly
  one hidden `[data-leader-action]` element; the JS never sends raw bytes to the
  PTY. Business logic stays in LiveView handlers. See the "Adding a binding"
  contract in [`../leader_keys.md`](../leader_keys.md).
- **`stopImmediatePropagation` on `C-b` is load-bearing.** Terminal handlers
  don't check `defaultPrevented`; without it the PTY gets a real `C-b` and tmux
  arms its own prefix, fighting the LiveView picker.
- **No leader auto-timeout** (mirrors tmux): armed until second key, `Escape`,
  or double `C-b`. Double `C-b` cancels (deliberate deviation from tmux's
  prefix pass-through — see [`../leader_keys.md`](../leader_keys.md)).
- **Mobile fallback.** On touch/narrow layouts the desktop dropdowns are
  CSS-hidden; `C-b s`/`C-b w` push `mobile_nav:open` instead of clicking a
  `display:none` `<summary>`.
- **`DevIDE.Commands.Allowlist` is a facade.** It only `defdelegate`s to
  `ExecCtl.Allowlist`; edit the core module to change commands, not the facade.
- **Mix task requirements.** `dev_ide.preview.demo` uses `@requirements
  ["app.start"]` and runs `ecto.migrate`; it calls `System.stop()` on success,
  so it is a one-shot demo, not a long-lived task.

## See also

- [`../leader_keys.md`](../leader_keys.md) — **authoritative** leader-key /
  picker doc (conventions, `choose-tree` navigation, adoption roadmap).
- [`../architecture.md`](../architecture.md) — first principles (FP-1 execution
  authority server-side; FP-3 UI reflects runtime truth).
- [`../preview_mcp.md`](../preview_mcp.md) — preview control surface the demo
  mix task exercises.
- [`../tmux_control_plane.md`](../tmux_control_plane.md) — the tmux topology the
  leader keys and runtimes CLI act on.
