# Casein owns geometry

> **The boundary.** tmux owns durable PTY sessions, process supervision, and crash
> recovery — it is the persistence boundary. **It does not decide where anything appears.**
> Casein owns pane arrangement, sizing, and focus, and tells each PTY what dimensions it has.

## The decision

Casein takes geometry. tmux keeps one pane per terminal and stops tiling.

This was gated for a long time on one question: *must a real terminal see the layout?* If a
human runs `tmux attach` over SSH and expects their split arrangement, tmux has to own the
rectangles. **The operator never attaches from a terminal**, so it does not.

Note what this is *not* justified by. Every other argument for tmux owning geometry
dissolved on inspection over the course of the design work:

- **Agent addressability** comes from MCP plus the registries, not from tmux.
- **Durability** comes from the registries (`PreviewPanes`, `FilePanes`) and from tmux
  *sessions* — not from tmux *layout*.
- **The `casein-preview <url>` gesture** works without occupying a rectangle: the command can
  register a preview and have the cockpit surface it.
- **The agents don't care.** Every worker lives one-per-pane and never uses tiling. This was
  never about the fleet.

## What each side owns

The separation is the whole design. Getting it fuzzy is how this fails.

| | tmux | Casein |
|---|---|---|
| Durable PTY sessions | **owns** | — |
| Process supervision, crash recovery | **owns** | — |
| Session / window as durable containers | **owns** | — |
| Scrollback and replay on reconnect | **owns** | — |
| Which panes exist in a view | — | **owns** |
| Arrangement, splits, zoom, swap | — | **owns** |
| Pane sizing (cols/rows told to the PTY) | — | **owns** |
| Focus | — | **owns** |

tmux remains the persistence boundary (FP-9) and the reason a closed browser does not kill an
agent. Nothing about that changes. What changes is that a tmux pane stops meaning *a
rectangle* and starts meaning only *a running process with a size*.

## The naming hazard

After this change there are two different things that today share one word.

- A **tmux pane** is a PTY: a process, a size, an id. It has no position.
- A **Casein pane** is a node in a layout: a position, a size, and a reference to whatever
  fills it — a PTY, a preview, a file editor, an inspector.

They are one-to-one only for terminals, and not at all for feature panes.

**Do not let both be called "pane" in code.** The cheapest fix is to name the tmux side for
what it now is — PTY, or terminal process — and keep "pane" for the layout node, since that
is what the web tier, the pane behaviour, and the templates already mean by it. A codebase
where `pane_id` sometimes means a rectangle and sometimes a process is the predictable way
this goes wrong.

## Sizing is the load-bearing flow

A PTY still needs cols and rows. Today tmux derives them from its own layout. After this,
**Casein must tell it**, and getting that wrong renders terminals incorrectly — wrapped
lines, misplaced cursors, corrupted TUIs.

The path already exists and should be extended rather than replaced: the browser reports a
fitted size (`ghostty_terminal.js` `requestLayout` → `pushEvent("resize", {cols, rows})`),
and `SessionOwner` records the focused viewer's viewport and stamps it onto the shared tmux
window. Multi-viewer arbitration is already solved there and must not gain a second answer.

What changes is only the source of truth for the rectangle: Casein computes it, derives
cols/rows, and drives the same resize path.

## What must not regress

- **Durability.** A closed browser must still leave every agent running and every scrollback
  intact. If a change makes layout ownership touch session lifetime, it is wrong.
- **Crash recovery.** `docs/subsystems/tmux_crash_recovery.md` describes hard-won behaviour.
  Layout is not allowed to become a recovery input.
- **Agent spawning.** `spawn-agent-worker.sh` creates a window and runs a runtime in it. That
  flow is untouched — it never used tiling.
- **`tmux attach` still works.** Sessions remain attachable; they simply show flat. We are
  removing tmux's layout *authority*, not tmux.

## What it buys

- Splits, zoom, and swap become server-side state — no shell-out, no waiting to be told the
  resulting rectangle, no two-phase `request_*_transition` → `commit_*` round trip.
- Most of the ~53 reconciliation sites in the web tier (`refresh_tmux_topology`,
  geometry-ready guards, topology-version checks) stop existing, because there is one layout
  model rather than two that must agree.
- The holder scripts (`priv/scripts/casein-file-pane`, and the rectangle half of
  `casein-preview`) disappear. They exist only to occupy a rectangle.
- Pixel geometry rather than character cells, so a diff, preview, or inspector is not
  quantized to a text grid.
- Layouts tmux cannot express become possible. The inspector region is already one.

The transition modules (`tmux_layout_transition`, `tmux_split_transition`,
`tmux_swap_transition`, `tmux_zoom_transition`, and the coordinator) get **simpler**, not
deleted: they exist to animate toward a rectangle you had to wait for. When the target is
known immediately, the freeze-clip-crossfade work that avoids scaling terminal glyphs still
applies, but the two-phase wait does not.

## Sequencing — not now

This is weeks of work touching crash recovery and three subsystem docs, and it should not
start against the current backlog. The order, when it does:

1. **Inspectors** — already done. #690 has Casein owning one split with the geometry modelled
   as a tree specifically so it can grow into this.
2. **Preview and file panes** — they already have their registries; this is dropping the tmux
   binding and the holder script.
3. **Terminals last** — that is where the reconciliation sites and the recovery paths live.

Each step is independently useful, and each one shrinks the next.

## Non-goals

- Not removing tmux. It stays the persistence boundary.
- Not changing agent spawning, session lifetime, or scrollback.
- Not a redesign of what the cockpit looks like. Same layouts, different owner.
- Not starting now.
