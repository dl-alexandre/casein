# Terminal renderer — browser-internals lessons, applied

Source: Addy Osmani, "How modern browsers work." Mapped onto dev_ide's terminal
renderer (`assets/js/ghostty_terminal.js`, `assets/js/terminal_canvas.js`) after
reading the actual code. Several "lessons" were already handled or don't apply —
recorded here honestly so the remaining work is scoped, not re-discovered.

## Scorecard

| # | Lesson | Status | Where / why |
|---|---|---|---|
| L2 | Dirty-region repaint | **Already done** | `terminal_canvas.js` `rowsEqual` skips unchanged rows; only changed rows repaint. Finer (column-range) repaint would clip italic/bold glyph overhang — **not** added without browser verification. |
| L3 | Retained-buffer scroll (translate texture) | **N/A here** | The client canvas paints only the **server-pushed viewport rows**, not a client-side scrollback texture. Scrollback lives server-side (ghostty `scroll/2` + tmux history). There is no texture to translate; the row-diff already skips unchanged rows on scroll. |
| L6 | Crash isolation (render vs. session) | **Already aligned** | `SessionOwner` owns PTY/session state; the view is a disposable subscriber (see `docs/subsystems/ghostty_terminal_contract.md` §5). No code. |
| L5 | rAF-coalesced paint | **Shipped, default-OFF** | New `paintCanvasCellsCoalesced` collapses bursty `onRenderCells` calls to one paint/frame. Gated behind `data-coalesce="raf"` / `localStorage["devide:terminal-coalesce"]="raf"`, **and** only active in the already-opt-in canvas branch. Inert until both flags are set. |
| L4 | Glyph atlas | **Deferred** | A GPU-atlas win under WebGL; in Canvas2D, `fillText` over a style-run beats N `drawImage` blits and risks subpixel/DPR misalignment. Belongs with L1. |
| L1 | OffscreenCanvas + Worker raster | **Deferred** | Moves raster off the main thread (the browser's core trick). It's a worker-protocol rewrite that **must be verified in a real browser** — not shipped on faith to a live terminal. |

## Why L5 is default-OFF (the honest caveat)

The canvas render path is timing-coupled: selection preservation
(`ghostty_terminal.js`, the "vendor render + RLE both rebuild innerHTML" guard),
the latency HUD, and pushText→render perf markers all key off *when* a frame
paints. rAF-coalescing changes that timing (next frame vs. inline). That is a
real behavior change that **cannot be verified in this environment** (no JS test
suite; no browser). So the code is landed inert, ready to verify by flag flip.

### How to verify L5 (needs a browser)

1. `localStorage["devide:terminal-renderer"] = "canvas"` (enable canvas).
2. `localStorage["devide:terminal-coalesce"] = "raf"` (enable coalescing).
3. Reload; run heavy output (`cat largefile`, `yes | head -n 100000`).
4. Confirm: no visual corruption, selection/copy still works, cursor aligned,
   and the latency HUD / perf markers stay sane. Compare jank vs. coalesce off.

Once verified, coalescing can become the canvas default, and L1/L4 (worker + GL
atlas) become the next step — at which point the canvas renderer can target
becoming the default over the DOM `innerHTML` path.

## What is NOT worth copying from the browser

A terminal is a fixed monospace grid: no reflow, no renderer-side line-breaking,
cell position is `row*cellH, col*cellW` (O(1)). Skip the browser's layout-tree /
style-resolution / stacking-context machinery — it solves problems we don't have.
The transferable subset is narrow: off-main-thread raster, retained buffer +
dirty rects, glyph atlas, rAF-coalesced frames, crash-isolated render.
