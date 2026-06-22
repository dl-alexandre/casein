# Native ghostty_ex terminal integration — SPECULATIVE SKETCH

> **⚠️ STATUS: SPECULATIVE. NOT VERIFIED against `ghostty_ex` source.**
>
> No `ghostty_ex` or Mob checkout was reachable when this was written. Every
> claim about how `ghostty_ex` exposes its grid, PTY, snapshots, or resize is an
> **assumption**, tagged `⟦ASSUMPTION⟧`. The single biggest unknown (the
> "rendering boundary", §1) changes large parts of the rest. Treat this as a
> thinking tool to react to, not a design to implement. Open questions that gate
> real decisions are collected in §6.

## 0. The goal (as I understand it)

A native iOS/Android IDE on Mob + on-device BEAM, where `ghostty_ex` is a
**first-class native terminal view** — real touch/gesture input, native
rendering, tuned for a phone — not a webview compromise. This sketch is about
embedding and tuning that one view; the dev loop in this folder is the
scaffolding to iterate on it.

## 1. The decision everything hangs on: where does ghostty render?

Ghostty is a terminal *emulator* — it contains (a) a VT parser + grid/state
machine and (b) a GPU renderer (Metal on Apple). Which of those `ghostty_ex`
exposes determines the whole architecture. Two models:

### Model A — ghostty owns the pixels (native surface handoff)
Ghostty's own GPU renderer draws into a native layer (`CAMetalLayer` /
Android `Surface`); SwiftUI/Compose hosts that layer and only forwards input +
sizing. BEAM never sees cell data on the hot path.

```
┌ SwiftUI/Compose host view ────────────────┐
│  UIViewRepresentable → CAMetalLayer        │  ← ghostty draws here (native)
│        ▲ input events        │ resize      │
└────────┼──────────────────────┼────────────┘
         │                      │
   ⟦ghostty_ex NIF / port⟧  ⟦resize/PTY⟧
         │                      │
   BEAM: Mob terminal GenServer (owns PTY, lifecycle, session)
```

- **Pros:** ghostty's renderer is fast and correct (ligatures, wide chars,
  styling) for free; minimal data crosses the BEAM boundary.
- **Cons:** you're embedding ghostty's renderer on mobile (it targets desktop
  today — ⟦ASSUMPTION⟧ that a mobile Metal/Surface path exists or is buildable);
  "tuning the rendering" means patching ghostty, not your Elixir/Swift code.

### Model B — ghostty is the state machine, you render the grid
`ghostty_ex` exposes the **cell grid as data** (chars + style attrs per cell,
cursor, scrollback); you render it yourself in SwiftUI/Compose (or your own
Metal layer). BEAM/`ghostty_ex` drives the VT state machine and PTY.

```
PTY bytes → ghostty VT parser → cell grid (data)
                                   │  ⟦snapshot / diff API⟧
                              Mob GenServer ── pushes grid/diffs ──▶ native view renders cells
                                   ▲ input (keys/text) ── from native view
```

- **Pros:** full control over rendering and gestures — the actual ask ("tuned
  exactly the way you want"). No dependency on ghostty's mobile GPU story.
- **Cons:** you reimplement the renderer (font shaping, wide/combining chars,
  styling, cursor, selection) — substantial, and easy to get subtly wrong.

**My read:** the phrase "highly customizable native experience" points at
**Model B for input/gestures regardless**, and likely Model B for rendering too
— but that hinges on whether `ghostty_ex` actually exposes a grid snapshot
(§6 Q1). If it only exposes a renderer surface, you're in Model A and "tuning"
means upstream ghostty work. **This is the first thing to confirm.**

## 2. Rendering approach (assuming Model B)

⟦ASSUMPTION⟧ `ghostty_ex` can hand BEAM a frame: a 2-D array of cells, each
`{codepoint(s), fg, bg, attrs(bold/italic/underline/...), width}` plus cursor
pos and a frame/sequence id.

- **iOS:** don't put one `Text` per cell. Either (a) a single `CALayer` /
  `MTKView` you draw glyphs into with Core Text run caching, or (b) a `Canvas`
  (iOS 15+) drawing positioned glyph runs. Monospace + fixed cell metrics makes
  layout a multiply, not a text-layout pass.
- **Android:** `Canvas.drawText` per styled run on a `SurfaceView`/`Compose
  Canvas`; cache `Paint` per style combo.
- **Font/metrics:** fixed advance width per cell from the monospace font; wide
  (CJK/emoji) cells span 2 columns — honor ghostty's reported `width` rather than
  measuring yourself, or the grid desyncs.
- **Cursor/selection** are overlays on top of the glyph layer, not part of it,
  so they update without a full redraw.

## 3. Input mapping (touch/gestures → PTY)

The native part that can't come from a webview. Gestures translate to **bytes
written to the PTY** ⟦via a `ghostty_ex`/GenServer `write/2`⟧, or to local view
actions (scrollback) that never reach the PTY:

| Gesture | Action | Goes to |
|---|---|---|
| Tap | Move cursor to cell (emit arrow-key sequence, or nothing in raw apps) | PTY (app-dependent) |
| Long-press | Start selection / context menu (copy, paste) | local + clipboard |
| Drag after long-press | Extend selection | local |
| One-finger vertical drag | Scrollback | **local only** (viewport, not PTY) |
| Two-finger drag | Send arrow keys (for `vim`/`less`) | PTY |
| Pinch | Font size / cell size | local re-layout + **PTY resize** (§4) |
| On-screen modifier bar | Ctrl/Esc/Tab/arrows (the dev_ide keybar idea) | PTY |

- **Soft keyboard:** the hard part on mobile. A hidden text field captures IME
  input; commit each character/composition as PTY bytes. Multi-stage IME
  (CJK, autocorrect) needs care — commit on confirm, not per keystroke.
- **Scrollback is a viewport concern, not a PTY concern** — scrolling must not
  write to the PTY or you'll corrupt full-screen apps.

## 4. Lifecycle (ties into `Mob.Dev.Connection`)

- **Resize:** pinch/rotate/keyboard-show changes the visible rows×cols →
  ⟦`ghostty_ex` resize⟧ → `TIOCSWINSZ` on the PTY so apps reflow. Debounce; send
  the *final* size, not every intermediate frame.
- **Background/foreground:** reuse the supervised `Mob.Dev.Connection` pattern.
  On background, stop pushing frames to the (now-invisible, possibly-suspended)
  view; the PTY + ghostty state keep running under the BEAM supervisor. On
  foreground, request a **full snapshot** (not a diff — you missed frames) and
  repaint. On iOS this dovetails with the honest "reconnect-on-foreground" model
  already documented — the *terminal session survives in the BEAM*, the *view*
  re-syncs.
- **Session ownership:** PTY + ghostty instance live in a supervised GenServer
  keyed by session, exactly like the rest of the IDE — the view is a disposable
  subscriber, matching the `Mob.Dev.Connection` philosophy (state in the
  GenServer, not the view).

## 5. Performance

- **Push diffs, not full frames.** ⟦ASSUMPTION⟧ ghostty can report dirty
  rows/cells. Steady-state typing dirties one row; a full repaint per keystroke
  on a 4K-cell grid is wasteful. Send `{frame_id, [changed_cell|changed_row]}`.
- **Coalesce on the BEAM side.** A burst of PTY output (e.g. `cat bigfile`) can
  emit hundreds of frames/sec; collapse to display refresh rate (~60fps) before
  crossing the NIF/port boundary — render the latest grid state, don't replay
  every intermediate.
- **Boundary cost:** if `ghostty_ex` is a NIF, grid access is cheap but long
  work must not block the scheduler (dirty NIF / chunk it). If it's a port,
  serialize diffs compactly (binary, not term-heavy maps).
- **Glyph run caching** (§2) is the other hot path: cache shaped runs keyed by
  `{text, style}`; monospace makes positioning O(1).

## 6. Open questions that gate real decisions

These need real `ghostty_ex` / Mob answers before any of the above is more than a
sketch:

1. **Rendering boundary (§1):** does `ghostty_ex` expose a **cell-grid
   snapshot** (Model B) or only a **native render surface** (Model A)? Everything
   downstream depends on this.
2. **Grid snapshot API:** if Model B — what's the shape? Full grid only, or
   dirty-region/diff support? What's in a cell (style attrs, hyperlinks, wide
   flag, combining chars)?
3. **Input/write API:** how does one feed bytes to the PTY — `ghostty_ex.write/2`
   on the instance, or directly to a PTY GenServer? Synchronous or cast?
4. **Resize API:** how are rows/cols changed, and does it drive `TIOCSWINSZ`
   automatically or do we?
5. **Instance lifecycle:** how is a ghostty/PTY instance created, supervised, and
   torn down? Is it a NIF resource, a port, or a GenServer already?
6. **NIF vs port:** which is it? Determines blocking/coalescing strategy (§5).
7. **Mobile renderer (Model A only):** is there any existing iOS/Android GPU path
   in ghostty, or would Model A require upstream work?
8. **Scrollback ownership:** does ghostty hold scrollback, or must the view?
   Affects where the scroll gesture reads from.

## 7. How this reconciles into PR #49

Once §6 is answered, this file gets rewritten from "sketch" to "design," the
`# ASSUMED MOB API` tags in the staged tooling get replaced with real
signatures, and the terminal GenServer contract here lines up with the actual
`ghostty_ex` instance lifecycle. Until then: **assumptions only.**
