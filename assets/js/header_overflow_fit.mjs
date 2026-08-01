// Size budget for the header ⋯ overflow menu.
//
// The menu is absolutely positioned against the ⋯ button, so CSS alone cannot
// know how much room is left around it — a static cap either scrolls/wraps a
// menu that had plenty of viewport left, or runs off the edge on a small one.
// The hook measures the anchor and asks for a budget; this is the arithmetic.

// Space kept between the menu and the viewport edge. Covers the menu's own 2px
// top margin plus a little breathing room for the shadow.
export const MENU_GUTTER_PX = 12

// Below this the menu is unusable as a list, so let it overhang and scroll
// rather than collapse to a two-item slot.
export const MENU_MIN_HEIGHT_PX = 160

// Narrower than this the menu wraps its own labels, so let it overhang.
export const MENU_MIN_WIDTH_PX = 192

// A dropdown that spans a 4K monitor is not a dropdown. Content decides the
// real width (`width: max-content`); this is only the outer sanity bound.
export const MENU_MAX_WIDTH_PX = 576

// Returns the max-height in px for a menu hanging below `anchorBottom`
// (viewport coordinates), or null when the inputs are not measurable yet.
export function overflowMenuMaxHeight({anchorBottom, viewportHeight}) {
  if (!Number.isFinite(anchorBottom) || !Number.isFinite(viewportHeight)) return null
  if (viewportHeight <= 0) return null

  const available = Math.round(viewportHeight - anchorBottom - MENU_GUTTER_PX)
  return Math.max(available, MENU_MIN_HEIGHT_PX)
}

// Returns the max-width in px for a right-anchored menu whose right edge sits
// at `anchorRight` (viewport coordinates). The room it can grow into is
// everything to its left, so the anchor's right edge is the budget.
export function overflowMenuMaxWidth({anchorRight, viewportWidth}) {
  if (!Number.isFinite(anchorRight) || !Number.isFinite(viewportWidth)) return null
  if (viewportWidth <= 0) return null

  const available = Math.round(Math.min(anchorRight, viewportWidth) - MENU_GUTTER_PX)
  return Math.min(Math.max(available, MENU_MIN_WIDTH_PX), MENU_MAX_WIDTH_PX)
}
