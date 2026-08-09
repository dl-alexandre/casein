import assert from "node:assert/strict"
import test from "node:test"

import {
  NARROW_MAX_PX,
  TABLET_MAX_PX,
  TABLET_MIN_PX,
  describeTabletBand,
  isPhysicalKeyboardEvidence,
  parseOverride,
  resolveCockpitLayout,
} from "../js/cockpit_layout.mjs"

test("parseOverride accepts auto/compact/desktop only", () => {
  assert.equal(parseOverride("compact"), "compact")
  assert.equal(parseOverride("desktop"), "desktop")
  assert.equal(parseOverride("auto"), "auto")
  assert.equal(parseOverride("nope"), "auto")
  assert.equal(parseOverride(null), "auto")
})

test("auto leaves layout to #735 CSS (null) for phone and wide bare tablet", () => {
  assert.equal(resolveCockpitLayout({viewportWidth: 390}), null)
  assert.equal(resolveCockpitLayout({viewportWidth: NARROW_MAX_PX}), null)
  // Wide coarse bare tablet: #735 already keeps desktop pickers — no attr.
  assert.equal(
    resolveCockpitLayout({viewportWidth: 820, keyboardEvidence: false}),
    null
  )
})

test("auto + keyboard does not upgrade phone / chrome-narrow", () => {
  assert.equal(
    resolveCockpitLayout({
      viewportWidth: 390,
      keyboardEvidence: true,
    }),
    null
  )
  assert.equal(
    resolveCockpitLayout({
      viewportWidth: 1400,
      chromeNarrow: true,
      keyboardEvidence: true,
    }),
    null
  )
})

test("auto + keyboard stamps desktop on wide viewports", () => {
  assert.equal(
    resolveCockpitLayout({
      viewportWidth: 820,
      keyboardEvidence: true,
    }),
    "desktop"
  )
})

test("explicit override wins", () => {
  assert.equal(
    resolveCockpitLayout({
      override: "desktop",
      viewportWidth: 390,
      keyboardEvidence: false,
    }),
    "desktop"
  )
  assert.equal(
    resolveCockpitLayout({
      override: "compact",
      viewportWidth: 1400,
      keyboardEvidence: true,
    }),
    "compact"
  )
})

test("physical keyboard evidence rejects soft-keyboard printables", () => {
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: true, key: "a"}), false)
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: true, key: "1"}), false)
  assert.equal(
    isPhysicalKeyboardEvidence({isTrusted: true, key: "a", isComposing: true}),
    false
  )
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: false, key: "Tab"}), false)
})

test("physical keyboard evidence accepts chords and navigation", () => {
  assert.equal(
    isPhysicalKeyboardEvidence({isTrusted: true, key: "p", ctrlKey: true}),
    true
  )
  assert.equal(
    isPhysicalKeyboardEvidence({isTrusted: true, key: "b", metaKey: true}),
    true
  )
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: true, key: "Tab"}), true)
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: true, key: "Escape"}), true)
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: true, key: "ArrowDown"}), true)
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: true, key: "F2"}), true)
  assert.equal(isPhysicalKeyboardEvidence({isTrusted: true, key: "Enter"}), true)
})

test("tablet band sits between sm and lg", () => {
  assert.equal(TABLET_MIN_PX, NARROW_MAX_PX + 1)
  assert.equal(TABLET_MAX_PX, 1023)
  assert.deepEqual(describeTabletBand({width: 820, height: 1180}), {
    inBand: true,
    orientation: "portrait",
    width: 820,
    height: 1180,
  })
  assert.deepEqual(describeTabletBand({width: 1180, height: 820}), {
    inBand: false,
    orientation: "landscape",
    width: 1180,
    height: 820,
  })
  assert.equal(describeTabletBand({width: 1024, height: 768}).inBand, false)
  assert.equal(describeTabletBand({width: 1023, height: 768}).inBand, true)
  assert.equal(describeTabletBand({width: 639, height: 1024}).inBand, false)
})
