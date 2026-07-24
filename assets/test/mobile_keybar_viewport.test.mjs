import assert from "node:assert/strict"
import test from "node:test"

import {
  CHROME_WOBBLE_MAX_GAP_PX,
  GAP_JITTER_PX,
  INSET_ANIMATION_STEP_PX,
  KEYBOARD_OPEN_MIN_GAP_PX,
  effectiveKeyboardOpen,
  keyboardGap,
  keyboardOpenForGap,
  planViewportCommit,
  shouldCommitViewportInset
} from "../js/mobile_keybar_viewport.mjs"

test("keyboardGap is zero with the keyboard closed and the viewport settled", () => {
  assert.equal(keyboardGap({innerHeight: 812, height: 812, offsetTop: 0}), 0)
  // Sub-pixel viewport reports round to whole pixels.
  assert.equal(keyboardGap({innerHeight: 812, height: 811.6, offsetTop: 0}), 0)
})

test("keyboardGap reports the soft-keyboard height when it opens", () => {
  assert.equal(keyboardGap({innerHeight: 812, height: 466, offsetTop: 0}), 346)
  // iOS keeps offsetTop nonzero while the keyboard scrolls the page.
  assert.equal(keyboardGap({innerHeight: 812, height: 466, offsetTop: 20}), 326)
})

test("keyboardGap never goes negative when the visual viewport overshoots", () => {
  assert.equal(keyboardGap({innerHeight: 812, height: 820, offsetTop: 0}), 0)
})

test("keyboardGap returns null while pinch-zoomed", () => {
  // Zoomed in: vv.height shrinks by the zoom factor — that gap is not a
  // keyboard and must not resize the terminal or auto-hide the header.
  assert.equal(keyboardGap({innerHeight: 812, height: 406, offsetTop: 120, scale: 2}), null)
  assert.equal(keyboardGap({innerHeight: 812, height: 780, offsetTop: 0, scale: 1.05}), null)
  // scale ~1 (keyboard-only geometry) passes through.
  assert.equal(keyboardGap({innerHeight: 812, height: 466, offsetTop: 0, scale: 1.0}), 346)
  assert.equal(keyboardGap({innerHeight: 812, height: 466, offsetTop: 0, scale: 1.01}), 346)
})

test("keyboardGap tolerates missing geometry", () => {
  assert.equal(keyboardGap({}), null)
  assert.equal(keyboardGap({innerHeight: 812, height: NaN}), null)
  // Browsers without a scale/offsetTop report still work.
  assert.equal(keyboardGap({innerHeight: 812, height: 466, offsetTop: undefined, scale: undefined}), 346)
})

test("keyboardOpenForGap uses the open threshold", () => {
  assert.equal(keyboardOpenForGap(0), false)
  assert.equal(keyboardOpenForGap(KEYBOARD_OPEN_MIN_GAP_PX), false)
  assert.equal(keyboardOpenForGap(KEYBOARD_OPEN_MIN_GAP_PX + 1), true)
  assert.equal(keyboardOpenForGap(null), false)
})

test("effectiveKeyboardOpen ignores URL-bar wobble without terminal focus", () => {
  const wobble = KEYBOARD_OPEN_MIN_GAP_PX + 20
  assert.ok(wobble <= CHROME_WOBBLE_MAX_GAP_PX)
  assert.equal(effectiveKeyboardOpen(wobble, {terminalFocused: false, wasOpen: false}), false)
  assert.equal(effectiveKeyboardOpen(wobble, {terminalFocused: true, wasOpen: false}), true)
  // Stay open once committed until the gap drops below the open floor.
  assert.equal(effectiveKeyboardOpen(wobble, {terminalFocused: false, wasOpen: true}), true)
  assert.equal(effectiveKeyboardOpen(0, {terminalFocused: false, wasOpen: true}), false)
  // Large gaps always count as keyboard even without focus.
  assert.equal(effectiveKeyboardOpen(CHROME_WOBBLE_MAX_GAP_PX + 1, {terminalFocused: false}), true)
})

test("shouldCommitViewportInset always commits the first measurement", () => {
  assert.equal(shouldCommitViewportInset({gap: 0, inset: 44}), true)
  assert.equal(shouldCommitViewportInset({gap: 0, inset: 44, lastGap: null, lastInset: null}), true)
})

test("shouldCommitViewportInset ignores keyboard-animation jitter", () => {
  assert.equal(
    shouldCommitViewportInset({gap: 301, inset: 329, lastGap: 300, lastInset: 328}),
    false
  )
  assert.equal(
    shouldCommitViewportInset({gap: 300 + GAP_JITTER_PX, inset: 328, lastGap: 300, lastInset: 328}),
    true
  )
})

test("shouldCommitViewportInset commits when only the bar height moved", () => {
  // Rotation / chrome-narrow / app-mode: gap steady, bar height changed.
  assert.equal(shouldCommitViewportInset({gap: 0, inset: 69, lastGap: 0, lastInset: 44}), true)
})

test("shouldCommitViewportInset rejects unusable measurements", () => {
  assert.equal(shouldCommitViewportInset({gap: NaN, inset: 44, lastGap: 0, lastInset: 44}), false)
  assert.equal(shouldCommitViewportInset({gap: 0, inset: NaN, lastGap: 0, lastInset: 44}), false)
})

test("planViewportCommit commits the first paint immediately without an open edge", () => {
  assert.deepEqual(
    planViewportCommit({gap: 0, inset: 44, keyboardOpen: false}),
    {pinBar: true, commitInset: true, settle: false, openChanged: false}
  )
})

test("planViewportCommit commits keyboard open/close edges immediately", () => {
  assert.deepEqual(
    planViewportCommit({
      gap: 120,
      inset: 148,
      keyboardOpen: true,
      lastGap: 0,
      lastInset: 44,
      lastKeyboardOpen: false
    }),
    {pinBar: true, commitInset: true, settle: false, openChanged: true}
  )

  assert.deepEqual(
    planViewportCommit({
      gap: 0,
      inset: 44,
      keyboardOpen: false,
      lastGap: 300,
      lastInset: 328,
      lastKeyboardOpen: true
    }),
    {pinBar: true, commitInset: true, settle: false, openChanged: true}
  )
})

test("planViewportCommit steps mid-animation instead of every frame", () => {
  // Sub-step motion: pin bar, settle later — no terminal refit yet.
  assert.deepEqual(
    planViewportCommit({
      gap: 10,
      inset: 38,
      keyboardOpen: true,
      lastGap: 0,
      lastInset: 28,
      lastKeyboardOpen: true
    }),
    {pinBar: true, commitInset: false, settle: true, openChanged: false}
  )

  // Crossed a quanta: commit a stepped size and still settle for the exact end.
  assert.deepEqual(
    planViewportCommit({
      gap: INSET_ANIMATION_STEP_PX,
      inset: 28 + INSET_ANIMATION_STEP_PX,
      keyboardOpen: true,
      lastGap: 0,
      lastInset: 28,
      lastKeyboardOpen: true
    }),
    {pinBar: true, commitInset: true, settle: true, openChanged: false}
  )
})

test("planViewportCommit ignores sub-pixel noise once settled", () => {
  assert.deepEqual(
    planViewportCommit({
      gap: 300,
      inset: 328,
      keyboardOpen: true,
      lastGap: 300,
      lastInset: 328,
      lastKeyboardOpen: true
    }),
    {pinBar: true, commitInset: false, settle: false, openChanged: false}
  )

  assert.deepEqual(
    planViewportCommit({
      gap: 301,
      inset: 329,
      keyboardOpen: true,
      lastGap: 300,
      lastInset: 328,
      lastKeyboardOpen: true
    }),
    {pinBar: true, commitInset: false, settle: false, openChanged: false}
  )
})

test("planViewportCommit rejects unusable measurements", () => {
  assert.deepEqual(
    planViewportCommit({gap: NaN, inset: 44, keyboardOpen: false}),
    {pinBar: false, commitInset: false, settle: false, openChanged: false}
  )
})
