# Tmux control plane

DevIDE uses tmux as the durable terminal engine and LiveView as the operator
surface. tmux owns PTYs, process groups, scrollback, session/window/pane
lifecycle, and reconnect behavior. LiveView and the API provide a safer,
agent-friendly control plane over that engine.

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
  -d '{"session":"devide_alpha_u-dev","name":"daily_layout","description":"Daily dev stack"}' \
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
- **Focus mode** hides most DevIDE chrome for immersive terminal work.
- **Escape hatch**: raw tmux keybindings and external tmux clients remain
  valid because tmux is still the engine.

After every mutation, LiveView and API paths refresh topology so the UI,
agents, and audit trail converge on tmux as the source of truth.
