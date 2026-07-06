# Tmux control plane

DevIDE uses tmux as the durable terminal engine and LiveView as the operator
surface. tmux owns PTYs, process groups, scrollback, session/window/pane
lifecycle, and reconnect behavior. LiveView and the API provide a safer,
agent-friendly control plane over that engine.

## Layer diagram

```text
LiveView / API / Agents
        │
        ▼
DevIDE.Terminals.TmuxTopology   (PubSub tag, audit on terminate)
DevIDE.Terminals.Tmux           (policy + adapter facade)
DevIDE.Terminals.TmuxPolicy     (session naming)
DevIDE.Terminals.TmuxRunner     (container argv wrapping)
        │
        ▼
TmuxCtl.Topology.Watcher        (GenServer poll + PubSub)
TmuxCtl.Topology                (pure snapshot / version hashes)
TmuxCtl.Client                  (@behaviour TmuxCtl.Adapter)
TmuxCtl.Runner                  (subprocess argv)
        │
        ▼
tmux server (host or container)
```

`TmuxCtl` is in-repo only: no DevIDE/Audit/WorkspaceSource references.
Tests swap `Application.get_env(:dev_ide, :tmux_adapter)` for
`TmuxCtl.Test.FakeAdapter` (aliased as `DevIDE.Test.FakeTmuxAdapter`).

## Adapter configuration (two keys)

DevIDE and `TmuxCtl` read adapter config from **different** application
env keys on purpose:

| Key | App | Used by | Purpose |
|-----|-----|---------|---------|
| `:tmux_adapter` | `:dev_ide` | `DevIDE.Terminals.Tmux`, `TmuxTopology`, LiveView, API, MCP | Product call sites; unchanged historical key |
| `:adapter` | `:tmux_ctl` | `TmuxCtl.Topology.Watcher` fallback when `tmux_resolver` is omitted | Generic watcher default |

At boot, `DevIde.Application.configure_tmux_ctl!/0` copies
`config :dev_ide, :tmux_ctl` (runner, session prefix, PubSub, prefix-bind
hint strings, etc.) into `config :tmux_ctl`. **Adapter selection is not
copied** — each layer keeps its own key.

**DevIDE watcher path:** `DevIDE.Terminals.TmuxTopology` injects
`tmux_resolver: fn -> Application.get_env(:dev_ide, :tmux_adapter, Tmux) end`
into `TmuxCtl.Topology.Watcher`, so production and tests always resolve the
facade/fake adapter from `:dev_ide`.

**Standalone `TmuxCtl` tests:** pass `tmux_resolver: fn -> TmuxCtl.Test.FakeAdapter end`
(or `tmux: adapter` for direct snapshots). Fake session state lives under
`:tmux_ctl` via `TmuxCtl.Test.FakeState` (`:fake_tmux_windows`, `:fake_tmux_panes`, …).

**Tests:** `config/test.exs` does not set `:tmux_adapter`; individual tests
set `Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)`.
`DevIDE.Test.FakeTmuxAdapter` is a `@behaviour TmuxCtl.Adapter` shim that
defdelegates to `TmuxCtl.Test.FakeAdapter`.

## Server selection & config (`-L` / `-f`)

DevIDE does **not** drive the host's default tmux server. Every invocation is
prefixed with a per-env server label (`DevIDE.Terminals.TmuxServer.args/0` →
`["-L", label]`): `devide` (prod), `devide_dev` (dev), `devide_test` (test).
Each label is a fully independent server — its own socket, session list, and
config — so DevIDE coexists with a plain SSH user's `tmux` (default server,
their `~/.tmux.conf`) and the three envs never collide on the shared devbox.

On the **host** path, `TmuxRunner` also appends `-f <file>` (precedence:
`:tmux_ctl, :config_file` → `:dev_ide, :tmux_config_file` →
`$DEV_IDE_TMUX_CONFIG` → bundled `priv/tmux/devide.conf`). **Container** sessions
skip `-f` and get the same options via `TmuxCtl.Client.apply_defaults/1`
instead. Because tmux reads `-f` only when it *starts* a server, config is
per-server, not per-client: a different config means a different `-L` label.
To attach from a shell: `tmux -L devide attach`.

See `docs/subsystems/terminals.md` ("Server isolation & config") for the full
table and the operator cutover note (changing a label points DevIDE at a fresh,
empty server; existing sessions on the old server become invisible).

## Core concepts

- **Topology** is the current projection of one tmux session: windows, panes,
  active ids, pane geometry, cwd, current command, and a version hash.
- **LiveView controls** render tmux windows as tabs and the active window's
  panes as the real tmux layout. Operators can focus, split, close, resize,
  drag-resize, rename, and inspect activity without leaving DevIDE.
- **Agent API** mirrors the LiveView mutations and always returns an updated
  topology snapshot after successful non-dry-run mutations.
- **Audit** records successful non-dry-run mutations as `tmux.*` events.

The raw tmux escape hatch remains available. Operators can still use tmux
prefix keys, command mode, or external tmux clients when needed.

DevIDE configures `:tmux_ctl, :terminal_env` at boot from
`DevIDE.Terminals.Shims.env/0`. `TmuxCtl.Client` applies those variables to
`new-session`, `new-window`, `split-window`, and `set-environment` defaults so
new shells inherit the DevIDE terminal capability contract. The generic
contract is `DEV_IDE_TERMINAL=1` and `DEV_IDE_CLIPBOARD=osc52`; app-specific
behavior stays lazy in command shims such as `~/.devide/terminal-shims/elio`.
The pane `PATH` also includes `~/.devide/tools/bin/`, where known missing tools
can be installed on first invocation. For example, typing `elio` in a DevIDE
terminal resolves the real binary if present; otherwise the shim runs
`devide ensure-installed elio` or its materialized fallback installer, then
launches Elio with OSC52 clipboard env.

## Topology API

All API routes require the configured API token and live under:

```text
/api/workspaces/:workspace_id
```

Every topology or mutation request must include `session` or `tmux_session`
as a query parameter or JSON body field.

```bash
curl -sS \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  "https://devide.example.test/api/workspaces/ws-1/topology?session=devide_alpha_u-dev"
```

Response shape:

```json
{
  "workspace_id": "ws-1",
  "session": "devide_alpha_u-dev",
  "active_window_id": "@1",
  "active_pane_id": "%2",
  "version": 1234567,
  "windows": [
    {
      "id": "@1",
      "index": 0,
      "name": "server",
      "active": true,
      "panes": 2,
      "activity": 1780849185,
      "current_command": "mix",
      "pane_list": []
    }
  ],
  "panes": [
    {
      "id": "%2",
      "window_id": "@1",
      "index": 0,
      "active": true,
      "left": 0,
      "top": 0,
      "width": 80,
      "height": 24,
      "current_command": "iex",
      "current_path": "/data/workspaces/example",
      "role": "agent",
      "activity": 1780849185,
      "activity_flag": false,
      "bell": false,
      "unseen_changes": false
    }
  ]
}
```

Pane activity fields are best-effort tmux alert metadata. DevIDE asks tmux for
pane-level activity/bell formats when available and falls back to the window
alert fields for the pane's window on tmux versions that do not expose
pane-specific alert formats.

`role` is DevIDE pane metadata persisted in tmux as the pane user option
`@devide_pane_role`. It is `null` for ordinary panes. The built-in
`agent_pair` templates set `operator` on the root pane, `agent` on the MCP
target pane, and `verify` on the verification pane so callers can identify
pane purpose without scraping scrollback.

Previous-session search is the read-only exception to the `session` parameter
rule: it composes live session directory rows, recent audit events, MCP
activity, and pane labels without hydrating history into LiveView. It is
bounded (`limit` defaults to 20 and clamps at 50), accepts `query`/`q`,
`workspace`/`workspace_id`/`workspace_name`, `session`/`session_id`,
`pane`/`pane_id`, `since`/`from`, and `until`/`to`, and returns JSON-safe
summaries only. The workspace filter narrows the already scoped route workspace
by id/name aliases or safe row metadata; it does not query across workspaces.
Results include a normalized `status` when known so callers can render
session/activity badges without parsing metadata.
Preview-context results include safe cause fields (`agent_action`,
`agent_session`, `agent_pane`) alongside title/status and URL/screenshot
references, so history can answer which agent action opened or inspected which
browser surface. When recording metadata has already been captured, the same
summary can carry recording ids/URLs/paths/status without loading the underlying
artifact.
The browser surface is the History side panel inside the workspace cockpit
(`?tab=history` on the workspace URL); it uses debounced filters, refreshes
from live audit/MCP activity broadcasts while open, and loads history lazily —
never during cockpit mount. The old `/workspaces/:id/previous-sessions` route
redirects there with its search params preserved.

```bash
curl -sS \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  "https://devide.example.test/api/workspaces/ws-1/previous_sessions?query=phoenix&session=devide_alpha_u-dev"
```

## Mutation conventions

Mutations return the same envelope:

```json
{
  "action": "pane_split",
  "dry_run": false,
  "result": {
    "pane_id": "%3"
  },
  "topology": {}
}
```

Dry-runs validate request shape and return the current topology without calling
tmux or emitting audit events:

```json
{
  "action": "pane_split",
  "dry_run": true,
  "topology": {}
}
```

Errors are intentionally stable and small:

```json
{
  "error": "pane_not_found"
}
```

Common errors:

- `session_required`
- `window_not_found`
- `pane_not_found`
- `name_required`
- `pane_id_required`
- `invalid_direction`
- `invalid_amount`
- `last_pane`
- `outside_root`
- `workspace_root_unavailable`

## Window mutations

Create a window:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","name":"tests","cwd":"."}' \
  "https://devide.example.test/api/workspaces/ws-1/windows"
```

Select a window:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev"}' \
  "https://devide.example.test/api/workspaces/ws-1/windows/@2/select"
```

Rename a window:

```bash
curl -sS -X PATCH \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","name":"server"}' \
  "https://devide.example.test/api/workspaces/ws-1/windows/@2"
```

Kill a window:

```bash
curl -sS -X DELETE \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev"}' \
  "https://devide.example.test/api/workspaces/ws-1/windows/@2"
```

## Pane mutations

Create a pane by splitting a target pane. `pane_id` and `target_pane_id` are
accepted for the split target.

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","target_pane_id":"%1","direction":"h"}' \
  "https://devide.example.test/api/workspaces/ws-1/panes"
```

Select a pane:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev"}' \
  "https://devide.example.test/api/workspaces/ws-1/panes/%2/select"
```

Split a pane explicitly:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","direction":"v"}' \
  "https://devide.example.test/api/workspaces/ws-1/panes/%2/split"
```

Resize a pane:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","direction":"right","amount":5}' \
  "https://devide.example.test/api/workspaces/ws-1/panes/%2/resize"
```

Resize directions are `left`, `right`, `up`, and `down`. Amount defaults to
`5` cells and is bounded to `1..50`.

Kill a pane:

```bash
curl -sS -X DELETE \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev"}' \
  "https://devide.example.test/api/workspaces/ws-1/panes/%2"
```

tmux and the adapter protect the last pane in a window; attempting to delete
it returns `last_pane`.

## Session templates

List built-in templates:

```bash
curl -sS \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  "https://devide.example.test/api/workspaces/ws-1/templates"
```

Apply a built-in template:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","dry_run":true}' \
  "https://devide.example.test/api/workspaces/ws-1/templates/generic_project/apply"
```

Preview how a saved exported template would reconcile against the current
session without mutating tmux:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","dry_run":true,"reconcile":true}' \
  "https://devide.example.test/api/workspaces/ws-1/templates/<saved-template-id>/apply"
```

Reconcile mode currently supports saved v2 exports only. With
`dry_run: true`, it returns a read-only `diff` object:

```json
{
  "action": "template_applied",
  "dry_run": true,
  "reconcile": true,
  "diff": {
    "strategy": "reconcile",
    "summary": {
      "reuse_windows": 1,
      "create_windows": 0,
      "reuse_panes": 2,
      "new_panes": 1,
      "send_commands": 1
    },
    "estimated_disruption": "medium",
    "changes": [
      {
        "action": "reuse_window",
        "target_id": "@1",
        "reason": "name_match"
      },
      {
        "action": "split_pane",
        "target_id": "%2",
        "reason": "no_matching_pane_signature"
      }
    ]
  }
}
```

Apply that same reconciliation plan:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","reconcile":true}' \
  "https://devide.example.test/api/workspaces/ws-1/templates/<saved-template-id>/apply"
```

Executable reconciliation is additive: it reuses matching windows/panes,
creates missing windows, splits missing panes, sends template commands for new
or mismatched panes, and restores startup focus. It does not delete or rename
existing tmux resources. Exact replay remains the default when `reconcile` is
omitted.

Export the current tmux topology as a DevIDE template v2 map and YAML:

```bash
curl -sS \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  "https://devide.example.test/api/workspaces/ws-1/templates/export?session=devide_alpha_u-dev&name=current_layout"
```

Save the current tmux topology as a persisted workspace template export:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","name":"daily_layout","description":"Daily dev stack","tags":["phoenix","daily"]}' \
  "https://devide.example.test/api/workspaces/ws-1/templates/export"
```

Dry-run a save without inserting a saved template or emitting audit:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"session":"devide_alpha_u-dev","name":"daily_layout","dry_run":true}' \
  "https://devide.example.test/api/workspaces/ws-1/templates/export"
```

Update saved template metadata:

```bash
curl -sS -X PATCH \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"name":"daily_layout_v2","description":"Updated daily dev stack","tags":["phoenix","ci"]}' \
  "https://devide.example.test/api/workspaces/ws-1/templates/00000000-0000-0000-0000-000000000000"
```

Only saved exported templates are mutable. Built-in templates remain read-only.
`dry_run: true` validates and returns the updated metadata shape without
persisting or emitting audit. If `session` is included, the response also
includes the current topology snapshot for that session.

List saved templates with a tag filter:

```bash
curl -sS \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  "https://devide.example.test/api/workspaces/ws-1/templates?tag=phoenix"
```

Tag filters match saved/exported templates. Built-ins are returned only when no
tag filter is present. Tags are normalized to lowercase strings; comma-separated
strings and JSON arrays are both accepted by save/update/duplicate operations.

Duplicate a saved workspace template export:

```bash
curl -sS -X POST \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{"name":"daily_layout_copy","description":"Safe variant for branch work","tags":["phoenix","branch"]}' \
  "https://devide.example.test/api/workspaces/ws-1/templates/00000000-0000-0000-0000-000000000000/duplicate"
```

If `name` is omitted, DevIDE chooses the next available copy name, such as
`daily_layout (copy)` or `daily_layout (copy 2)`. `dry_run: true` validates
and returns the duplicate shape without inserting or emitting audit.

Delete a saved workspace template export:

```bash
curl -sS -X DELETE \
  -H "authorization: Bearer $DEVIDE_API_TOKEN" \
  "https://devide.example.test/api/workspaces/ws-1/templates/00000000-0000-0000-0000-000000000000"
```

Response shape:

```json
{
  "workspace_id": "ws-1",
  "session": "devide_alpha_u-dev",
  "template": {
    "version": 2,
    "name": "current_layout",
    "root": "${workspace_root}",
    "metadata": {
      "source": "devide_topology_export",
      "session": "devide_alpha_u-dev",
      "topology_version": 1234567
    },
    "windows": [
      {
        "name": "server",
        "root": "${workspace_root}",
        "focus": true,
        "layout": {
          "direction": "horizontal",
          "panes": []
        }
      }
    ],
    "startup": {
      "window": "server",
      "pane": "app"
    }
  },
  "yaml": "version: 2\n..."
}
```

The exporter infers nested `horizontal` and `vertical` split trees only when
pane rectangles form clean partitions. Custom or ambiguous tmux layouts export
as `direction: "tiled"` rather than guessing.

`GET /templates` returns both built-in and saved exported templates. Built-ins
have `source: "built_in"` and `apply_supported: true`. Saved exports with
`schema_version: 2` have `source: "exported"` and `apply_supported: true`.
Applying a saved export is currently an imperative replay that creates the
captured windows and panes in the target session; it does not reconcile or
mutate existing panes into a desired state yet.

Built-in templates may declare pane roles. Applying `agent_pair` persists the
role metadata to tmux (`operator`, `agent`, `verify`), and subsequent topology
reads return those roles on the pane objects.
Terminal helpers use that metadata for safe agent targeting:
`DevIDE.Terminals.find_agent_pane/2` only returns a pane with `role: "agent"`;
`send_agent_prompt_to_agent_pane/3` refuses to send when the role is missing
instead of guessing from focus or process names. Missing-agent-pane errors
include `suggested_template: "agent_pair"`, `required_role: "agent"`, and
`auto_apply_option: :auto_apply_agent_pair` so clients can show a specific
recovery action or opt into the helper's one-shot auto-apply path.

## Audit events

Successful non-dry-run mutations emit audit events with `actor_id: "api"` for
API calls.

Window events:

- `tmux.window_created`
- `tmux.window_selected`
- `tmux.window_renamed`
- `tmux.window_killed`

Pane events:

- `tmux.pane_selected`
- `tmux.pane_split`
- `tmux.pane_resized`
- `tmux.pane_killed`

Lifecycle events:

- `tmux.session_terminated`

Template events:

- `tmux.template_applied`
- `tmux.template_exported`
- `tmux.template_saved`
- `tmux.template_deleted`

Window audit metadata includes `session`, `window_id`, `active_window_id`,
`active_pane_id`, `topology_version`, and `dry_run: false`.

Pane audit metadata includes `session`, `pane_id`, `active_window_id`,
`active_pane_id`, `topology_version`, and `dry_run: false`.

## Operator workflow

- **Window tabs** switch active tmux windows and show activity dots.
- **Pane layout** renders the active window's real tmux pane geometry.
- **Inactive panes** can be clicked to focus, split, resized with buttons or
  drag handles, and closed.
- **Active panes** keep the governed terminal surface protected from click
  bubbling.
- **Titles** use the compact `basename(cwd)` plus command label; hover shows
  the full path and command.
- **Session templates** can be saved from the current tmux layout. Saved v2
  templates preview a smart reconciliation diff before apply, with an exact
  replay escape hatch when the operator wants a fresh duplicate layout.
- **Consolidate session** in the command palette moves the current workspace's
  other tmux sessions into the active session, appending their windows there.
- **Focus mode** hides most DevIDE chrome for immersive terminal work.
- **Escape hatch**: raw tmux keybindings and external tmux clients remain
  valid because tmux is still the engine.

After every mutation, LiveView and API paths refresh topology so the UI,
agents, and audit trail converge on tmux as the source of truth.
