// Vertical background fill for DOM-rendered terminal cells.
//
// Cell backgrounds are painted by inline <span>s, and an inline box's
// background only covers the font's content box (ascent + descent). The grid
// spaces rows every --devide-terminal-line-height px — taller than the content
// box — so a hairline of the <pre>'s theme background shows at every row
// boundary. Full-screen TUIs that paint their own background over every cell
// (Grok/Composer) turn that into a bright rule across every row whenever the
// terminal theme is light (e.g. Catppuccin Latte).
//
// Vertical padding on a non-replaced inline box extends its painted background
// without changing the line box, so padding each background run by the
// half-leading closes the seam without moving the grid. The bottom pad gets an
// extra half pixel so fractional line-box positions can't reopen a subpixel
// seam; the overhang paints before (and therefore under) the next row's own
// background and text, so it can never cover ink.
export function backgroundLeadingPad(lineHeightPx, contentHeightPx) {
  if (!(lineHeightPx > 0) || !(contentHeightPx > 0)) return null

  const leading = lineHeightPx - contentHeightPx
  if (leading <= 0) return null

  const half = leading / 2
  return {top: roundPx(half), bottom: roundPx(half + 0.5)}
}

function roundPx(value) {
  return Math.round(value * 100) / 100
}
