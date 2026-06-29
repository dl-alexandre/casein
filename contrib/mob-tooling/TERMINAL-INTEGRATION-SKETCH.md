# Native ghostty terminal integration — DESIGN (grounded on the verified contract)

> **⚠️ STATUS — split, after PR #50/#51/#52.** The terminal half of this document
> is **no longer speculative**: the `ghostty` grid/PTY/input contract is read from
> real source and recorded in
> [`docs/subsystems/ghostty_terminal_contract.md`](../../docs/subsystems/ghostty_terminal_contract.md)
> (the `ghostty` hex dep, locked `0.4.9`). Where this file once said
> `⟦ASSUMPTION⟧` about cells, resize, input, or scrollback, it now cites that
> contract. The browser renderer's perf lessons are likewise verified in
> [`docs/subsystems/terminal_renderer_lessons.md`](../../docs/subsystems/terminal_renderer_lessons.md).
>
> **What is still genuinely speculative** and stays tagged `⟦DESIGN⟧`:
> 1. the **native iOS/Android renderer** — dev_ide renders the grid in a browser
>    today; a SwiftUI/Compose/Metal view that consumes the same `cells/1`
>    contract is a *design target, not built code*; and
> 2. the **Mob device task surface** (`mix mob.*`, `Mob.Device.subscribe/1`),
>    which remains `# ASSUMED MOB API` in this folder because no Mob checkout is
>    reachable. See §7.
>
> Read the contract doc first; this file is the *mobile view* design that sits on
> top of it.

## 0. The goal (as I understand it)

A native iOS/Android IDE on Mob + on-device BEAM, where the ghostty terminal is a
**first-class native terminal view** — real touch/gesture input, native
rendering, tuned for a phone — not a webview compromise. This sketch is about
embedding and tuning that one view; the dev loop in this folder is the
scaffolding to iterate on it.

## 1. The decision everything hung on — RESOLVED: Model B

Ghostty is a terminal *emulator* — (a) a VT parser + grid/state machine and (b) a
GPU renderer. The question was which of those the dep exposes. **Answered:** the
`ghostty` dep exposes the **cell grid as data** via `Ghostty.Terminal.cells/1 ::
[[cell()]]`, and dev_ide already renders that grid itself client-side. That is
**Model B, and it already ships for web** (contract §3). Input is encoded by the
dep too (§3 below), so BEAM drives the VT state machine + PTY and the view is a
pure renderer/​input-source.

For the record, the abandoned alternative:

### ~~Model A — ghostty owns the pixels~~ (not how the dep works)
The dep does **not** hand out a native render surface; it hands out the grid.
A native GPU-surface handoff would be upstream ghostty work and is not the path
dev_ide is on. Kept here only so the choice is legible.

### Model B — ghostty is the state machine, you render the grid ✅
`cells/1` returns the grid; you render it in SwiftUI/Compose (or a Metal layer).
This is the *actual ask* ("tuned exactly the way you want") and matches what the
browser renderer already does — a native view is a second renderer against the
**same verified contract**, not a new architecture.

## 2. Rendering (Model B) — corrected cell shape

The earlier draft guessed a per-cell `{codepoints, fg, bg, attrs, width}` record.
**The real shape** (contract §2, `Ghostty.Terminal.Cell`) is the 4-tuple:

```elixir
{grapheme, fg, bg, flags}   # grapheme :: binary (glyph cluster)
                            # fg/bg    :: color | nil
                            # flags    :: bitmask (bold/italic/faint/underline/…)
```

with three consequences the native renderer must honor:

- **No `row`/`col` and no `width` field.** Position is the index in the
  `[[cell()]]` returned by `cells/1`. Wide glyphs (CJK/emoji) are the `grapheme`
  in one cell followed by a trailing `blank?` cell — **honor the grid layout,
  never measure width yourself**, or the grid desyncs.
- **`snapshot/2` is not the grid.** It returns a *rendered* `:html | :plain |
  :vt` binary (artifacts/preview). The live grid is `cells/1`.
- **No dirty-region API.** 0.4.9 returns the full grid; incremental rendering is
  an **app-level diff** — dev_ide threads `previous_cells → last_render_cells` and
  encodes only what changed (contract §3). A native view does the same row-diff.

Native renderer mechanics (still `⟦DESIGN⟧` — not built):

- **iOS ⟦DESIGN⟧:** don't put one `Text` per cell. A single `MTKView`/`CALayer`
  drawn with Core Text run caching, or a `Canvas` (iOS 15+) of positioned glyph
  runs. Monospace + fixed cell metrics make layout a multiply, not a text pass.
- **Android ⟦DESIGN⟧:** `Canvas.drawText` per styled run on a
  `SurfaceView`/Compose `Canvas`; cache `Paint` per style combo.
- **Cursor/selection** are overlays on top of the glyph layer, so they update
  without a full redraw — and `Ghostty.Terminal.cursor/1` gives the position
  (contract §2), so the view doesn't track it independently.

The browser-renderer scorecard (renderer-lessons doc) maps straight onto a native
view: a terminal is a **fixed monospace grid** (`row*cellH, col*cellW`, O(1)) — so
skip layout/reflow machinery; the transferable subset is dirty-rect repaint,
glyph atlas, off-main-thread raster, and frame coalescing.

## 3. Input — use ghostty's encoders, NOT hand-rolled escapes

The earlier draft mapped gestures to ANSI sequences by hand. **The dep already
encodes input correctly** (contract §4), respecting the app's mouse mode, so the
gesture layer's job is to *construct events*, not emit `\e[A`:

- **Keys:** build a `Ghostty.KeyEvent`, call `input_key/2 → {:ok, bytes} | :none`,
  write the bytes to the PTY. (`Ghostty.KeyDecoder.decode/1` for the reverse.)
- **Touch/mouse:** build a `Ghostty.MouseEvent`, call `input_mouse/2 → {:ok,
  bytes}`. Because it honors `mouse_modes/1`, a tap/drag becomes the *right*
  sequence for `vim`/`less` vs. a raw shell — for free.
- **Focus:** `encode_focus/1`, gated on focus-reporting.
- **Raw bytes** when you truly have them: `write/2` (a `GenServer.call`, iodata).

The gesture→action mapping is still the native design surface (`⟦DESIGN⟧`); only
the *encoding* step is now settled. The mapping intent:

| Gesture | Action | Goes to |
|---|---|---|
| Tap | Move cursor (`MouseEvent` → `input_mouse/2`, app-dependent) | PTY |
| Long-press | Start selection / context menu (copy, paste) | local + clipboard |
| Drag after long-press | Extend selection | local |
| One-finger vertical drag | Scrollback → `Ghostty.Terminal.scroll/2` | **local/viewport, never PTY** |
| Two-finger drag | Arrow keys (`KeyEvent` → `input_key/2`) for `vim`/`less` | PTY |
| Pinch | Font/cell size: local re-layout + **PTY resize** (§4) | local + resize |
| On-screen modifier bar | Ctrl/Esc/Tab/arrows (the dev_ide keybar idea) | PTY |

- **Soft keyboard ⟦DESIGN⟧:** a hidden text field captures IME input; commit each
  composition as a `KeyEvent`. Multi-stage IME (CJK, autocorrect) commits on
  confirm, not per keystroke. (Mirrors the web hook's hidden
  `<textarea data-ghostty-input>`, contract §3.)
- **Scrollback is a viewport concern, not a PTY concern** — drive
  `Ghostty.Terminal.scroll/2`; never write to the PTY or you corrupt full-screen
  apps.

## 4. Lifecycle — verified ownership + resize

- **Resize (verified):** `Ghostty.Terminal.resize/3` / `Ghostty.PTY.resize/3`,
  arg order **`(server, cols, rows)`** (contract §5, confirmed in #52). Call it
  from the session owner on pinch/rotate/keyboard-show, **debounced to the final
  size**. We do **not** poke `TIOCSWINSZ` — the dep does.
- **Background/foreground ⟦DESIGN, but grounded⟧:** reuse the supervised
  `Mob.Dev.Connection` reconnect-on-foreground pattern. On background, stop
  pushing frames to the suspended view; the PTY + ghostty state keep running
  under the BEAM supervisor. On foreground, request a **full snapshot** (`cells/1`
  — there are no diffs to catch up on) and repaint. This dovetails with the
  honest iOS "the *session* survives in the BEAM, the *view* re-syncs" model
  already documented in `README-development.md`.
- **Session ownership (verified):** production terminals are **tmux-backed**
  `DevIDE.Terminals.Session`, keyed by `{workspace, sid}` under `SessionOwner`
  (contract §5) — *not* a per-pane `Ghostty.PTY` (that direct backend is
  legacy/test). A native view is a disposable subscriber to that same owner,
  exactly like the web pane. State lives in the GenServer, not the view.

## 5. Performance — what's settled vs. still open

- **Dirty diff is app-level (verified).** The dep returns the full grid; dev_ide
  computes changed rows (`rowsEqual` in `terminal_canvas.js`, renderer-lessons
  L2). A native view ports the same row-diff; finer column-range repaint risks
  clipping italic/bold overhang — defer it (L2 caveat).
- **Coalesce bursty output (shipped for web, default-OFF).** `cat bigfile` emits
  many frames/sec; collapse to display refresh. The web path now has
  `paintCanvasCellsCoalesced` (rAF, L5) **landed inert behind a flag** because it
  changes paint timing and can't be browser-verified in this environment. A
  native renderer should coalesce on the BEAM side *and* in the view's display
  loop from the start — the lesson is proven, the web toggle just isn't on yet.
- **Boundary cost (verified NIF).** `ghostty` is a **NIF** (Zig via `zigler`,
  contract §1/§6 Q6), so grid access is cheap — but long work must not block the
  scheduler (dirty NIF / chunk). No port-serialization concern.
- **Glyph run caching ⟦DESIGN⟧** (§2) is the native hot path: cache shaped runs
  keyed by `{text, style}`; monospace makes positioning O(1). Glyph-atlas/​worker
  raster are deferred even on web (L1/L4) — same call for native.

## 6. The §6 open questions — RESOLVED (see contract §6)

Each is now answered from source; one line, pointer to the contract:

1. **Render boundary:** Model B, *already shipped for web* via `cells/1`.
2. **Grid API:** `cells/1 :: [[{grapheme, fg, bg, flags}]]`; `snapshot/2` is a
   rendered artifact; dirty-diff is app-level.
3. **Input/write:** prefer `input_key/2` + `input_mouse/2` (encode events);
   `write/2` (call, iodata) for raw bytes.
4. **Resize:** `resize(server, cols, rows)` from the session owner, debounced.
5. **Lifecycle:** tmux-backed `Terminals.Session` per `{workspace, sid}` under
   `SessionOwner`; direct `Ghostty.PTY` is legacy/test.
6. **NIF vs port:** NIF, fixed by the dep.
7. **Mobile renderer:** ⟦still unverified⟧ — no native shell on the box; the
   *contract it would consume* is verified, the renderer is not built (§7).
8. **Scrollback:** ghostty (`scroll/2` / `scrollbar/1`) + tmux history — not a
   BEAM-side buffer.

## 7. The fence: what stays genuinely unverified

Everything above about the **terminal contract** is source-verified. Two things
are **not**, and keep their tags:

- **Native iOS/Android renderer (`⟦DESIGN⟧`).** dev_ide renders the grid in a
  browser. A SwiftUI/Compose/Metal renderer consuming `cells/1` is a design
  target. The contract it consumes is settled; the renderer is unbuilt.
- **Mob device task surface (`# ASSUMED MOB API`).** `mix mob.dev`,
  `mix mob.ping`, `mix mob.connect`, and `Mob.Device.subscribe/1`'s event shape
  remain assumed in this folder — no Mob/MeshX checkout is reachable. The
  dev-loop scaffolding here is written against a *described* contract.

When the Mob checkout and a native shell land on the box, these get the same
source-verified treatment as the terminal contract did in #50 — the `⟦DESIGN⟧`
and `# ASSUMED MOB API` tags get replaced with real signatures, **not before**.
