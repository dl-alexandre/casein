import test from "node:test"
import assert from "node:assert/strict"

import {
  applyOverlayRect,
  parsePaneRectJson,
  rectFromSectionElement,
  resolveOverlayRect,
} from "../js/pane_overlay_rect.mjs"

test("parsePaneRectJson accepts valid pane rect JSON", () => {
  assert.deepEqual(parsePaneRectJson('{"left":0,"top":10,"width":50,"height":90}'), {
    left: 0,
    top: 10,
    width: 50,
    height: 90,
  })
})

test("parsePaneRectJson rejects malformed payloads", () => {
  assert.equal(parsePaneRectJson(""), null)
  assert.equal(parsePaneRectJson("not-json"), null)
  assert.equal(parsePaneRectJson('{"left":0,"top":1,"width":2}'), null)
})

test("rectFromSectionElement reads inline percentage geometry", () => {
  const section = {
    style: {
      left: "12.5%",
      top: "0%",
      width: "37.5%",
      height: "100%",
    },
  }

  assert.deepEqual(rectFromSectionElement(section), {
    left: 12.5,
    top: 0,
    width: 37.5,
    height: 100,
  })
})

test("resolveOverlayRect prefers the live section geometry", () => {
  const layout = {
    querySelector(selector) {
      assert.equal(selector, 'section[data-pane-id="%2"]')
      return {
        style: {
          left: "60%",
          top: "0%",
          width: "40%",
          height: "100%",
        },
      }
    },
  }

  const overlay = {
    dataset: {
      paneId: "%2",
      paneRect: '{"left":0,"top":0,"width":66.6667,"height":100}',
    },
    parentElement: layout,
  }

  assert.deepEqual(resolveOverlayRect(overlay), {
    left: 60,
    top: 0,
    width: 40,
    height: 100,
  })
})

test("applyOverlayRect writes absolute percentage placement", () => {
  const el = {style: {}}

  applyOverlayRect(el, {left: 10, top: 5, width: 45, height: 90}, {entered: true})

  assert.equal(el.style.position, "absolute")
  assert.equal(el.style.left, "10%")
  assert.equal(el.style.top, "5%")
  assert.equal(el.style.width, "45%")
  assert.equal(el.style.height, "90%")
  assert.equal(el.style.zIndex, "40")
})