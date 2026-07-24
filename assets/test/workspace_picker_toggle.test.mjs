import assert from "node:assert/strict"
import test from "node:test"

import {
  pickerCloseEvent,
  pickerElementVisible,
  pickerToggleDecision,
  visiblePickerSurfaces,
} from "../js/workspace_picker_toggle.mjs"

const closed = {
  mobileLayout: false,
  mobileOpen: false,
  sessionsOpen: false,
  windowsOpen: false,
}

test("repeating the session picker shortcut closes the open sidebar", () => {
  assert.equal(
    pickerToggleDecision("session-picker", {...closed, sessionsOpen: true, windowsOpen: true}),
    "close-sidebar"
  )
})

test("repeating the window picker shortcut closes the open sidebar", () => {
  assert.equal(
    pickerToggleDecision("window-picker", {...closed, windowsOpen: true}),
    "close-sidebar"
  )
})

test("a different closed picker still opens", () => {
  assert.equal(
    pickerToggleDecision("session-picker", {...closed, windowsOpen: true}),
    "open-sidebar"
  )
})

test("mobile picker shortcuts toggle the shared navigation sheet", () => {
  assert.equal(
    pickerToggleDecision("session-picker", {...closed, mobileLayout: true, mobileOpen: true}),
    "close-mobile"
  )
  assert.equal(
    pickerToggleDecision("window-picker", {...closed, mobileLayout: true}),
    "open-mobile"
  )
})

test("Escape closes whichever picker surface is visible", () => {
  assert.equal(pickerCloseEvent({...closed, windowsOpen: true}), "sidebar:close")
  assert.equal(pickerCloseEvent({...closed, sessionsOpen: true}), "sidebar:close")
  assert.equal(pickerCloseEvent({...closed, mobileOpen: true}), "mobile_nav:close")
  assert.equal(pickerCloseEvent(closed), null)
})

test("visiblePickerSurfaces ignores mounted but CSS-hidden pickers", () => {
  const elements = {
    "[data-mobile-nav-sheet]": {offsetParent: {}},
    "[data-sessions-picker-sidebar]": {offsetParent: null},
    "[data-window-picker-sidebar]": {offsetParent: {}},
  }
  const root = {querySelector: (selector) => elements[selector] || null}

  assert.deepEqual(visiblePickerSurfaces(root), {
    mobileOpen: true,
    sessionsOpen: false,
    windowsOpen: true,
  })
})

test("fixed-position picker chrome can be visible without an offset parent", () => {
  assert.equal(
    pickerElementVisible({offsetParent: null, getClientRects: () => [{width: 320, height: 480}]}),
    true
  )
  assert.equal(pickerElementVisible({offsetParent: null, getClientRects: () => []}), false)
})
