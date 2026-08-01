import assert from "node:assert/strict"
import test from "node:test"

import {
  MENU_GUTTER_PX,
  MENU_MAX_WIDTH_PX,
  MENU_MIN_HEIGHT_PX,
  MENU_MIN_WIDTH_PX,
  overflowMenuMaxHeight,
  overflowMenuMaxWidth
} from "../js/header_overflow_fit.mjs"

test("a tall viewport gets the whole run to the bottom, not a 28rem cap", () => {
  // Header bottom at 44px in a 1080px window: 1024px of room, well past the
  // 448px static cap the menu used to scroll inside.
  assert.equal(
    overflowMenuMaxHeight({anchorBottom: 44, viewportHeight: 1080}),
    1080 - 44 - MENU_GUTTER_PX
  )
})

test("the budget shrinks with the room actually left below the anchor", () => {
  assert.equal(
    overflowMenuMaxHeight({anchorBottom: 300, viewportHeight: 700}),
    700 - 300 - MENU_GUTTER_PX
  )
})

test("sub-pixel anchor rects round to whole pixels", () => {
  assert.equal(
    overflowMenuMaxHeight({anchorBottom: 44.6, viewportHeight: 812}),
    Math.round(812 - 44.6 - MENU_GUTTER_PX)
  )
})

test("a cramped viewport floors at the minimum rather than collapsing", () => {
  assert.equal(overflowMenuMaxHeight({anchorBottom: 380, viewportHeight: 420}), MENU_MIN_HEIGHT_PX)
  // Anchor scrolled below the fold: still a usable menu, never a negative one.
  assert.equal(overflowMenuMaxHeight({anchorBottom: 900, viewportHeight: 420}), MENU_MIN_HEIGHT_PX)
})

test("unmeasurable input yields null so the CSS fallback stays in force", () => {
  assert.equal(overflowMenuMaxHeight({anchorBottom: NaN, viewportHeight: 812}), null)
  assert.equal(overflowMenuMaxHeight({anchorBottom: 44, viewportHeight: undefined}), null)
  assert.equal(overflowMenuMaxHeight({anchorBottom: 44, viewportHeight: 0}), null)

  assert.equal(overflowMenuMaxWidth({anchorRight: NaN, viewportWidth: 1440}), null)
  assert.equal(overflowMenuMaxWidth({anchorRight: 1400, viewportWidth: undefined}), null)
  assert.equal(overflowMenuMaxWidth({anchorRight: 1400, viewportWidth: 0}), null)
})

test("the right-anchored menu may grow into everything left of the ⋯ button", () => {
  // 1400px of room to the left, so only the sanity bound applies.
  assert.equal(overflowMenuMaxWidth({anchorRight: 1400, viewportWidth: 1440}), MENU_MAX_WIDTH_PX)
})

test("a narrow viewport hands back the room that is actually there", () => {
  assert.equal(overflowMenuMaxWidth({anchorRight: 360, viewportWidth: 390}), 360 - MENU_GUTTER_PX)
})

test("width floors at the min rather than crushing labels", () => {
  assert.equal(overflowMenuMaxWidth({anchorRight: 90, viewportWidth: 390}), MENU_MIN_WIDTH_PX)
})

test("an anchor reported past the right edge is clamped to the viewport", () => {
  // Horizontal overscroll can put the rect beyond innerWidth; the menu still
  // may not claim more room than the window has.
  assert.equal(overflowMenuMaxWidth({anchorRight: 900, viewportWidth: 400}), 400 - MENU_GUTTER_PX)
})
