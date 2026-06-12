# Leader Keys (tmux conventions in DevIDE)

DevIDE adopts tmux's `C-b` prefix conventions for workspace chrome: session and
window switching, pane management, and picker navigation. The goal is that tmux
muscle memory works in the cockpit without relearning, and that every binding
remains a thin alias for UI the mouse can already reach.

## Architecture

Two client hooks own keyboard behavior; the server owns all business logic.

### `WorkspaceLeader` (`assets/js/workspace_leader.js`)

Mounted on the persistent workspace container so it survives tab switches.

- **Capture phase:** the `keydown` listener runs in the capture phase, before
  the terminal textarea sees the key, so `C-b` works even while the terminal
  has focus.
- **Action dispatch:** each bound key looks up a
  `[data-leader-action="<name>"]` element and calls `.click()` on it. Hidden
  elements (e.g. inside closed dropdowns) are fine — the click still fires the
  `phx-click` binding, so the server handles the action through the same
  handler the visible button uses.
- **No auto-timeout:** mirrors tmux. Leader mode stays armed until a second
  key arrives, `Escape` cancels, or a second `C-b` cancels.
- While armed, `<body>` carries `data-leader-active` for styling (the `.leader-kbd`
  hints in the chrome light up).

### `SessionPicker` (`assets/js/session_picker.js`)

Mounted on both the session and window dropdown `<details>`. Implements tmux
`choose-tree` navigation once the picker is open. The dropdowns are a full
replacement for tmux's native picker — `choose-tree` itself is never invoked
(`C-b` is intercepted before it can reach tmux), so the picker UX has to stand
on its own:

- **Selection mirrors tmux.** Whenever a dropdown is open, exactly one entry
  is selected (browser focus + a persistent `[data-picker-item]:focus`
  highlight in `app.css`). It starts on the `[data-picker-active]` entry —
  the session/window the terminal is attached to, where tmux's picker would
  put its cursor — and it is always the entry that `Enter` (or releasing a
  held `C-b s` / `C-b w`) navigates to.
- **Only real entries are navigable.** Navigation moves across
  `[data-picker-item]` elements only (sessions, windows, links) — never the
  window-count toggles, rename/kill, or refresh buttons, exactly like tmux's
  picker. Hidden entries (collapsed window lists) are skipped.
- **Fresh on open.** The session summary fires `terminal:refresh_sessions`
  and the window summary `tmux:refresh_topology`, so the list and the active
  highlight reflect live tmux state, not the last poll.

| Key      | Behavior                                                            |
| -------- | ------------------------------------------------------------------- |
| `↓` / `↑` | Move through visible items (shell, sessions, expanded windows, links) |
| `→`      | On a session with windows: expand the window list, focus first window |
| `←`      | On a window: collapse the list, refocus its session. On an expanded session: collapse |
| `Enter`  | Attach the focused item (native button click)                        |
| `Escape` | Close the picker, return focus to the trigger                        |

Opening the picker (mouse or `C-b s`) auto-focuses the active session.
Expansion state is client-side (`JS.toggle`); a LiveView re-render of the
dropdown collapses it again, matching the mouse toggle's behavior. The `→`/`←`
keys click the same per-session toggle button the mouse uses
(`#session-windows-toggle-<dom_id>`), so chevron rotation and display state
cannot drift between keyboard and pointer.

## Current bindings

All of these require the `C-b` prefix first (except where noted).

### Sessions and windows

| Keys      | tmux meaning      | DevIDE action (`data-leader-action`) |
| --------- | ----------------- | ------------------------------------ |
| `s`       | choose session    | `session-picker` — opens the session dropdown |
| `w`       | choose window     | `window-picker` — opens the window dropdown |
| `c`       | new window        | `new-window`                         |
| `n` / `p` | next/prev window  | `next-window` / `prev-window`        |
| `l`       | last window       | `last-window` — toggles to the window active before the last switch |
| `1`–`9`   | select window     | clicks `[data-tmux-window-index="N"]` |
| `,`       | rename window     | `rename-window` — opens the window dropdown, starts inline rename of the active window |
| `&`       | kill window       | `kill-window` — kills the active window |
| `d`       | detach            | `detach` — returns to the workspace shell |

### Panes

| Keys           | tmux meaning        | DevIDE action                          |
| -------------- | ------------------- | -------------------------------------- |
| `%` or `\|`    | split horizontally  | `split-right`                          |
| `"` or `-`     | split vertically    | `split-down`                           |
| `z`            | zoom pane           | `zoom`                                 |
| `x`            | kill pane           | `close-pane`                           |
| `o`            | next pane           | `pane-next`                            |
| `;`            | last pane           | `last-pane` — tmux `select-pane -l` on the active session |
| `←` `↓` `↑` `→` | directional focus  | `pane-left` / `pane-down` / `pane-up` / `pane-right` |

### Meta (no prefix unless noted)

| Keys          | Behavior                                                        |
| ------------- | --------------------------------------------------------------- |
| `C-b :`       | Open the command palette (tmux command prompt)                  |
| `C-b ?`       | Toggle the leader-key cheatsheet overlay (tmux list-keys)       |
| `Space`       | Focus the active terminal when nothing interactive is focused   |
| `C-b C-b`     | Cancel leader mode (deliberate deviation — see below)           |
| `C-b Escape`  | Cancel leader mode                                              |

## Deliberate deviations from tmux

- **Double `C-b` cancels instead of passing a literal `C-b` through.** In tmux,
  `C-b C-b` sends the prefix to the inner application (nested tmux, vim's
  page-back). DevIDE intercepts `C-b` in the capture phase, so it can never
  reach the terminal. We evaluated pass-through and decided against it: DevIDE
  terminals attach to DevIDE-managed tmux sessions, and in-terminal tmux
  control belongs to the governed control plane, not raw prefix forwarding.
- **`Space` → focus terminal** is a DevIDE addition with no tmux equivalent
  (tmux `Space` cycles layouts; we don't bind that).

## Adding a binding

1. Add the key → action name to `LEADER_ACTIONS` in
   `assets/js/workspace_leader.js`.
2. Put `data-leader-action="<name>"` on exactly one element in the workspace
   LiveView template whose `phx-click` performs the action. Hidden elements
   work; the element just has to exist in the DOM.
3. Optionally add a `<kbd class="leader-kbd">` hint near the visible control.

Keep the contract: the JS map only routes keys to clicks. Business logic stays
in LiveView event handlers.

## Adoption roadmap

### Bigger lifts (planned, in rough priority order)

1. **Activity/silence flags** (`monitor-activity` / `monitor-silence`): mark
   windows in the pickers when a pane prints output, and — more useful for
   agent fleets — when a pane goes quiet (agent likely finished or blocked).
   Hangs off the existing server-side tmux topology polling.
2. **Picker previews** (tmux `choose-tree` preview pane): focusing a window in
   the session picker shows a Ghostty snapshot of that pane. Snapshot
   infrastructure already exists (`snapshot_all`).
3. **`q` — pane number overlay:** flash pane indices, press a digit to focus.
   Valuable once a workspace has 4+ agent panes.
4. **`[` — copy mode / scrollback navigation:** biggest lift; most valuable on
   mobile where the key bar already has a select affordance.
5. **`!` — break pane into its own window:** promote an agent pane that
   outgrew its split.

### Deliberately not adopting

- **`synchronize-panes`** — typing into every agent pane at once is a footgun.
- **`t` (clock), marked panes (`m`), pane swapping (`{`/`}`)** — low value in
  this UI; splits are managed through the layout system instead.
