# Terminal surface crash isolation — design pass

Status: **analysis + recommendation, implementation deferred pending sign-off**
Branch: `agent/claude/ui-cut-20260703` (Phase 3 of the UI-cut refactor)
Date: 2026-07-03

## Problem

Everything in the workspace cockpit runs in one LiveView process
(`CaseinWeb.WorkspaceLive.Show`). The per-pane `PaneWorker`s (which own the
`Ghostty.Terminal` emulators and PTY backends) are **linked** to that
process. A crash anywhere in chrome/panel logic therefore:

1. kills every PaneWorker and its emulator state,
2. reloads the whole page on the client,
3. restarts the terminals, which re-attach to tmux and repaint.

The question for Phase 3: should the terminal surface become a **sticky
child LiveView** (`live_render(..., sticky: true)`) so terminals survive a
crash in the surrounding chrome?

## What a crash actually costs today

Less than it first appears:

- **No terminal data is lost.** The source of truth is the tmux session on
  the host. Workers re-attach to the same session and repaint the full
  screen. (This is the same convergence path as a normal reconnect.)
- **Live emulator scrollback is not worth preserving.** Agent TUIs run on
  the alt screen, so the live emulator's scrollback is empty anyway — the
  pane-history viewer reads tmux capture history instead (see
  `agent/pane-scrollback-20260702` work).
- The real cost is the **reload flash**: a full page reload, remount, and
  ~1s of repaint across all panes.

## Option A — sticky child LiveView owning the terminal surface

`TerminalSurfaceLive`, rendered with `sticky: true`, owns the PaneWorkers,
the Ghostty push_event channel, and the `tmux_pane_geometry` tile.

What it buys:
- Terminals keep streaming through a chrome crash; no reload flash.
- The Show LV sheds `terminal_state.ex` / `terminal_events.ex` weight.

What it costs (why this is the risky cut):
- **Sticky children receive no parent assigns.** All hub state the surface
  reads (topology, active pane/window, terminal_sid, preview panes, themes,
  mutations-enabled) must be re-threaded over PubSub (the `SessionEvents`
  bus from PR #92 is the natural carrier). Every one of those flows is a
  convergence invariant today; each re-threading is a chance to reintroduce
  the multi-viewer tearing class of bugs we just finished eliminating.
- **Every `terminal:*` / `tmux:*` event re-routes.** Hooks bind events to
  the nearest LiveView, so input, focus, resize, splits, zoom — all of
  `terminal_events.ex` — move to the child, but several of those handlers
  write hub state (tab, session bar, preview panes) that lives in the
  parent, forcing a parent↔child message protocol on the hottest input
  path (keystroke echo currently budgeted at 8ms flush windows).
- The authz gate must be replicated on the child LV (its own
  `attach_hook` + allowlist — `PanelGate` makes this cheap now, but the
  event allowlist splits in two).
- Estimated blast radius: `show.ex`, `terminal_state.ex` (37K),
  `terminal_events.ex` (29K), `pane_worker.ex`, the TerminalSurface/
  TmuxPaneResize/Ghostty JS hooks, plus every LiveView test that drives
  terminal events through Show.

## Option B — decouple PaneWorker lifetime from the LiveView

Keep one LiveView, but move PaneWorkers under a workspace-scoped
supervisor (the `SessionOwner` generation from the terminal data-structure
roadmap) instead of linking them to the LV. On LV crash the client still
reloads, but workers + emulators survive; the remounting LV re-attaches to
the running workers and pushes one full frame per pane.

- Removes the emulator restart and most of the repaint cost; the reload
  flash remains.
- No event re-routing, no PubSub re-threading, no split authz.
- Aligns with the existing SessionOwner/SessionEvents direction — the
  `:session_owner` backend already moves the transport out of the LV.
- Needs care on two points: worker GC (workers must die when *no* viewer
  holds them — the multi-viewer refcount, same shape as SessionOwner's
  generation logic) and frame-sequence reset on re-attach (viewer must
  treat re-attach as a fresh full-frame epoch, or we recreate the stale-
  cell class of corruption).

## Recommendation

**Do not build the sticky child LiveView now.** Its main benefit (no
reload flash) is real but modest, and its cost lands exactly on the
render-perfection invariants and input latency budget. If crash isolation
becomes a felt pain, do **Option B first** — it captures most of the
benefit (no emulator loss, near-instant re-attach repaint) with a fraction
of the risk, and it is the natural next slice of the SessionOwner roadmap
anyway. Revisit Option A only if, after B, the reload flash itself is
still hurting.

## If/when Option A is approved, the slice order

1. Land Option B (supervised workers + re-attach epoch) — prerequisite,
   halves what the sticky child has to own.
2. Introduce `TerminalSurfaceLive` rendering only the geometry tile,
   subscribed to `SessionEvents` for topology/active-pane; parent keeps
   emitting the same bus events it does today.
3. Move `terminal:*` input events to the child; keep `tmux:*`
   topology-mutating events on the parent (they write hub state).
4. Only then flip `sticky: true`, and soak with the multi-viewer
   convergence suite before enabling by default.
