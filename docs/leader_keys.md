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
  `[data-leader-action="<name>"]` element and calls `.click()` on it. The
  click fires the `phx-click` binding, so the server handles the action
  through the same handler the visible button uses.
- **Central dispatch targets:** every action lives on exactly one hidden
  `<button>` in a dispatch div in the workspace LiveView, rendered outside
  the chrome block — so bindings keep working in focus mode (chrome hidden).
  Visible chrome buttons share the `phx-click` handlers but carry no
  `data-leader-action`. Exceptions: `C-b s` lives on the session dropdown
  `<summary>`; `C-b w` opens the transient window sidebar beside the terminal;
  and `1`–`9` targets the window tabs — those require visible chrome.
- **No auto-timeout:** mirrors tmux. Leader mode stays armed until a second
  key arrives, `Escape` cancels, or a second `C-b` cancels.
- The header `C-b` button toggles the same leader mode for pointer/touch users.
- While armed, `<body>` carries `data-leader-active` for styling (the header
  `C-b` button and `.leader-kbd` hints in the chrome light up).

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
| `←`      | On a window: collapse the list, refocus its session. On an expanded session: collapse. With nothing to collapse: menu hop — the window picker backs out into the session picker (`data-picker-hop-left`) |
| typing   | Filter visible entries (tmux choose-tree `f`); matches the name/detail spans (`data-picker-label`) so index digits and badges can't surprise-match. The query shows in a line at the top of the menu; `Backspace` edits |
| (focus)  | Focusing an entry previews its tmux target — a text capture rendered in a pane at the bottom of the menu (`terminal:picker_preview` reply, debounced 200ms, cached while the menu is open, session validated against the workspace tmux prefix) |
| `o`      | Open the focused entry in a new browser tab (session and window pickers) |
| `l`      | Copy the focused entry's shareable link (always includes `?session=`; window links also carry `&window=`) |
| `r`      | Rename the focused entry inline — a top-level window row renames the window, a session row renames the session. Nested child rows (windows under a non-active session) are skipped, since rename targets the active session's tmux session |
| `&`      | In the window picker, kill the focused top-level window after confirmation. Pane rows are ignored |
| `Enter`  | Attach the focused item (native button click)                        |
| `Escape` | Clear the filter if one is typed; otherwise close the picker and return focus to the trigger |

Each picker menu shows a footer hint: `↑↓ move · o open · l copy link · r rename`.
The window picker adds `· & kill` when a focused window can be killed.

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
| `w`       | choose window     | `window-picker` — opens the transient window sidebar |
| `(` / `)` | previous/next session | `prev-session` / `next-session` — cycles through the current workspace's DevIDE terminal sessions |
| `c`       | new window        | `new-window`                         |
| `n` / `p` | next/prev window  | `next-window` / `prev-window`        |
| `l`       | last window       | `last-window` — toggles to the window active before the last switch |
| `y`       | (custom)          | `copy-link` — copies a full-view link (session, window, pane, zoom when set) |
| `1`–`9`   | select window     | clicks `[data-tmux-window-index="N"]` |
| `,`       | rename window     | `rename-window` — starts inline rename on the active window tab |
| `$`       | rename session    | `rename-session` — opens the session dropdown, starts inline rename of the active session. Stored as the tmux user option `@devide_session_alias` (not a real `rename-session`, which would break the load-bearing `devide_<workspace>_<sid>` name). Works for any session, including the default/landing session (which renders as a normal row marked "home") |
| `&`       | kill window       | `kill-window` — kills the active window after a confirm prompt (tmux asks y/n too) |
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
| `q`            | pane index overlay  | flash pane indices; press `0`–`9` to focus |
| `←` `↓` `↑` `→` | directional focus  | `pane-left` / `pane-down` / `pane-up` / `pane-right` |

### Meta (no prefix unless noted)

| Keys          | Behavior                                                        |
| ------------- | --------------------------------------------------------------- |
| `C-b :`       | Open the command palette (tmux command prompt)                  |
| `C-b ?`       | Open the help overlay; press again to cycle its tabs (Shortcuts / Preview). `Esc` or a backdrop click closes it |
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
2. Add a hidden `<button>` with `data-leader-action="<name>"` to the central
   dispatch div in the workspace LiveView template (search for
   "Central leader-key dispatch targets") whose `phx-click` performs the
   action. Keep the contract: exactly one element per action, and the
   dispatch div stays outside the chrome block so focus mode keeps working.
3. Optionally add a `<kbd class="leader-kbd">` hint near the visible control
   (the visible button does **not** get `data-leader-action`).

Keep the contract: the JS map only routes keys to clicks. Business logic stays
in LiveView event handlers.

## Adoption roadmap

### Shipped

- **`q` — pane number overlay:** `C-b q` flashes each pane's tmux index
  (0–9); press a digit to focus that pane, `Escape` or `q` to dismiss.
  Client-only (`WorkspaceLeader` + `data-pane-index` on pane tiles); digit
  selection dispatches `tmux:select_pane` like a click on an inactive tile.

- **Activity flags in the pickers** (tmux `monitor-activity` / window `#`
  flag): every window carries a freshness dot (`:fresh` < 30s,
  `:recent` < 5min, `:idle`) in both the window dropdown and the session
  picker's expanded window rows, and each session row inherits its freshest
  window's state. Data path: `SessionDirectory.put_session_windows/1` stores
  raw tmux `window_activity` timestamps in `metadata.window_activity` — a key
  deliberately **outside** the `Compose.stable_hash/1` allowlist, so freshness
  updates never re-broadcast the tab list. The dots are recomputed whenever
  the tab list is read, and opening a picker forces `refresh_now`, so they are
  current exactly when visible. Dots are hidden at `:idle` to keep the picker
  quiet.

- **Quiet-agent flags** (tmux `monitor-silence`): a window whose active pane
  runs an interactive agent (`Boundary.interactive_command_ids/0`) and has
  been silent for 60s–30min is flagged violet — the "agent finished or is
  blocked on input" signal. `DevIDE.Terminals.Activity.agent_window_quiet?/1`
  quantizes the volatile activity timestamp into a boolean stored in the
  **stable** `metadata.windows` map, so the flip (and only the flip)
  re-broadcasts the tab list — a notification with no per-poll churn. Surfaced
  as a violet dot on window rows in both pickers (supersedes the activity
  dot), a session-row rollup, and a badge on the session-picker trigger in the
  header so it is visible without opening anything. Non-agent windows never
  flag, no matter how silent.

- **tmux's own picker is fully retired.** Three layers guarantee the LiveView
  pickers are the only picker surface:
  1. The status line is off (`apply_defaults`: `status off`), so tmux never
     renders a window list row.
  2. `WorkspaceLeader` stops `C-b` (and the second key, and the cancelling
     `Escape`) with `stopImmediatePropagation` — the terminal handlers don't
     check `defaultPrevented`, so without this the PTY received a real `C-b`,
     tmux armed its native prefix, and the next raw keystroke became a tmux
     command (`w` drew choose-tree in-pane behind the LiveView dropdown).
  3. For prefixes that bypass the browser entirely (agents sending keys over
     the terminal MCP, direct SSH attaches), `apply_defaults` rebinds
     `prefix w` / `prefix s` to a `display-message` hint pointing at the
     DevIDE pickers. State-mutating bindings (`c`, `n`, `p`, splits, `z`,
     `x`) stay native — topology polling reflects them; only the in-terminal
     picker UI is replaced. Key tables are server-wide; on a devbox every
     session is DevIDE-managed.

### Bigger lifts (planned, in rough priority order)

1. **Picker previews** (tmux `choose-tree` preview pane): focusing a window in
   the session picker shows a Ghostty snapshot of that pane. Snapshot
   infrastructure already exists (`snapshot_all`).
2. **`[` — copy mode / scrollback navigation:** biggest lift; most valuable on
   mobile where the key bar already has a select affordance.
4. **`!` — break pane into its own window:** promote an agent pane that
   outgrew its split.

### Deliberately not adopting

- **`synchronize-panes`** — typing into every agent pane at once is a footgun.
- **`t` (clock), marked panes (`m`), pane swapping (`{`/`}`)** — low value in
  this UI; splits are managed through the layout system instead.
