# Workspace deep links

DevIDE workspace URLs encode enough state to reopen the same terminal view another
operator (or another browser tab) was looking at.

## URL grammar

```
/workspaces/{workspace_id}[?query]
```

Query parameters (stable order when DevIDE writes them):

| Param | Example | Meaning |
|-------|---------|---------|
| `host` | `devbox-2` | Remote workspace host (omitted for local) |
| `session` | `u-dalexandre-dnkouc4l` | DevIDE tab session id — always present in the address bar |
| `window` | `@1` | tmux window id — included whenever a session is active |
| `pane` | `%2` | tmux pane id — included when the window has multiple panes, or when zoomed |
| `zoom` | `1` | Active pane is zoomed (`resize-pane -Z`); requires `pane` |
| `tmux_session` | `devide_…` | Attach hint when switching sessions (internal) |
| `tab` | `history` | Cockpit tab to open (`terminal`, `files`, `search`, `diff`, `artifacts`, `run`, `proposals`, `logs`, `history`); unknown values are ignored |
| `drawer` | `notifications` | Overlay drawer to open (`notifications` is the only value); unknown values are ignored |

`tab` is a one-shot open hint: it selects the tab (with that tab's lazy
hydration) on the mount/patch that carries it, and DevIDE does not re-emit it
when patching the address bar afterwards. `tab=history` additionally seeds the
History panel's search filters from the previous-sessions query params
(`query`, `source`, `session`, `pane`, `since`, `until`, `limit`, and their
aliases) — this is how old `/workspaces/:id/previous-sessions` bookmarks keep
working through the legacy redirect.

`drawer` is the same kind of one-shot open hint for overlay drawers, and —
unlike `tab` — it also works on the dashboard at `/`, because the
notifications drawer is a global (user-scoped) surface rendered by both the
dashboard and the workspace cockpit. `drawer=notifications` opens the
notifications drawer (inbox, mark read / resolve / mute, delivery
preferences); `/?drawer=notifications` is the target of the legacy
`/notifications` redirect. The drawer's list loads lazily when it opens; only
the unread badge count loads at mount.

### Canonicalization

- Omit empty/nil params.
- If `zoom=1`, `pane` must be present.
- Single-pane windows omit `pane` unless zoomed.
- `zoom` is omitted when not zoomed.

### Examples

```
/workspaces/ws-1?session=u-dev-abc123&window=%400
/workspaces/ws-1?session=u-dev-abc123&window=%401&pane=%403
/workspaces/ws-1?session=u-dev-abc123&window=%401&pane=%403&zoom=1
/workspaces/ws-1?session=u-dev-abc123&window=%400&pane=%400&zoom=1
```

## Restoration

On `handle_params/3`, DevIDE applies params in order:

1. `session` — switch DevIDE tab session
2. `window` — `select-window` in tmux
3. Topology refresh when needed
4. `pane` — `select-pane` (after topology hydrates; stashed as `:pending_url_pane`)
5. `zoom` — idempotent `ensure_zoomed/3` (stashed as `:pending_url_zoom`)

Missing session/window/pane shows a **view link notice** banner with fallbacks.

Terminals are raw everywhere, so there is no `mode` param — every window opens
a raw shell. A stray `?mode=raw` from an old link is silently ignored.

## Share surfaces

| Surface | URL scope |
|---------|-----------|
| Session copy (picker, workspace index) | `?session=` only |
| Window copy (picker row) | `?session=&window=` |
| Full view (`C-b y`, leader copy-link) | session + window + pane + zoom when set |

Clipboard toasts append a short suffix, e.g. `dnkouc4l · window @1 · pane %3 · zoomed`.

## Implementation

- `CaseinWeb.WorkspaceLive.Show.ViewDeepLink` — query build/restore
- `TerminalState.workspace_window_path/2` — address-bar patches (delegates to view path)
- `TmuxCtl.Client` — `pane_zoomed_flag` in topology; `ensure_zoomed/3`

### Idle-gated topology patches

User actions (picker, leader keys, pane/window clicks) patch the URL immediately
and refresh the interaction clock.

When tmux topology drifts externally (CLI zoom, attach elsewhere), the LiveView
syncs UI state on every poll but only `push_patch`es the address bar if the
operator has been idle for **4 seconds**. `TerminalActivity` (`assets/js/terminal_activity.js`)
reports terminal key/pointer/wheel input; server `terminal:user_interaction`
events and forced patches update `terminal_last_interaction_ms`.