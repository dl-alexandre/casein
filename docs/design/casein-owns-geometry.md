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
- A **slot** is a node in Casein's layout tree: a position, a size, and a reference to
  whatever fills it — a PTY, a preview, a file editor, an inspector.

They are one-to-one only for terminals, and not at all for feature panes.

**Do not let both be called "pane" in code** — but the fix is not the one that first suggests
itself. Renaming the tmux side is unaffordable: `pane_id` appears **~1,655 times in the
domain, 908 in the web tier, and 92 in JS**. That is not a rename, it is touching every file
that deals with panes.

The affordable direction is the opposite, and it works because **Casein's layout tree barely
exists yet** — `Cockpit.Inspectors` is days old. We are naming a new concept, not renaming an
entrenched one.

- **`pane_id` keeps its current meaning**: a tmux pane, which after this is simply a PTY with
  a size. Zero churn.
- **The layout node gets its own word from day one** and never borrows "pane".

This also keeps the agent-facing contract correct as it stands. `terminal_send_keys(pane:
"%3")` is right and should stay right — agents address *processes*, not layout, and should
not acquire a layout concept they never needed.

### The word: `slot`

It is already in the codebase meaning exactly this, in the `Casein.Panes.Pane` moduledoc:

> Start the pane's backend on an **already-allocated slot**… Called by the execute/reconcile
> pipeline after geometry exists (**the slot is a real tmux pane**).

Existing usage is negligible (~18 in the domain; most web hits are LiveView's `slot :`
template DSL), and it has a natural verb the docs already use — *"a new pane type slots into
any layout."*

The alternatives are taken or weaker: `node` (~320 uses — tree nodes, file-tree nodes),
`frame` (~115 — render frames, the frozen frame in the transitions), `region` (~23, already
meaning the inspector region specifically). `tile` is free but carries no existing meaning
here.

**A slot is a position in Casein's layout tree. A slot is filled by something — a PTY
(referenced by `pane_id`), a preview, a file editor, an inspector.**

**Rule (issue #750):** `pane_id` = a tmux pane / PTY; `slot_id` = a node in Casein's
layout tree. `Casein.Cockpit.Inspectors` and `Casein.Cockpit.Geometry` use slot
vocabulary for layout nodes; tmux-facing APIs and MCP keep `pane` / `pane_id`.

### Where the churn actually is

Not the 2,655 sites. The real work is the feature-pane registries: today a preview or file
pane holds a *tmux* `pane_id` (its holder's rectangle), and after this they have no tmux pane
at all and need a `slot_id`. That is `pane_ref` territory — 27 sites plus the two registries.

One honest wrinkle: `Casein.Panes.Pane` ends up slightly misnamed, since it becomes the
behaviour for *things that fill slots* rather than for panes. Leave it rather than churn a
merged behaviour, but know the name is a little off rather than pretending the split is
perfectly clean.

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

## Sequencing

Tracked as issue #748. Each step is independently useful and shrinks the next.

1. **Inspectors** — done. #690 / PR #700: Casein owns one split; geometry is a tree
   (`Casein.Cockpit.Geometry`) so it can grow.
2. **Naming** — #750: call the layout node a **slot** before the tree spreads. `pane_id`
   stays a tmux PTY. Coordinate; do not race shared-file renames with other tracks.
3. **Foundation alignment** — code and subsystem docs must not still claim "tmux is the
   geometry allocator." Behaviour modules (`Casein.Panes.Pane`, feature-pane registries)
   point at this page. No runtime cutover yet.
4. **Preview and file panes** — not filed yet. Drop the tmux binding and holder scripts;
   registries already exist.
5. **Terminals last** — not filed yet. ~53 reconciliation sites and crash-recovery paths.
   Keep using the single `computeTerminalLayout` fit path; never grow a second one.
   Vendor `<pre>` 8px padding stays excluded from fit math; grep `terminal owner size ->`
   when diagnosing stranded 80×24 corners (`sendReady` clobber).

Phases 4–5 are weeks of work and must not start as drive-by refactors against the current
backlog.

## Non-goals

- Not removing tmux. It stays the persistence boundary.
- Not changing agent spawning, session lifetime, or scrollback.
- Not a redesign of what the cockpit looks like. Same layouts, different owner.
- Not renaming the ~2,655 `pane_id` sites, the MCP tool surface, or `Casein.Panes.Pane`.
