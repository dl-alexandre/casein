import assert from "node:assert/strict"
import test from "node:test"

import {JSDOM} from "jsdom"

import {
  resolveSwipeTarget,
  swipeThresholdPx,
  swipeWindowList,
  swipeWindowProgress,
} from "../js/window_swipe.mjs"

test("swipeWindowProgress: small travel is undecided", () => {
  const s = swipeWindowProgress(4, 2)
  assert.equal(s.axis, null)
  assert.equal(s.ready, false)
  assert.equal(s.progress, 0)
})

test("swipeWindowProgress: vertical-dominant locks out the swipe", () => {
  const s = swipeWindowProgress(10, 60)
  assert.equal(s.axis, "v")
  assert.equal(s.dir, null)
})

test("swipeWindowProgress: pull left → next window, enters from right edge", () => {
  const s = swipeWindowProgress(-70, 10, {threshold: 120})
  assert.equal(s.axis, "h")
  assert.equal(s.dir, "next")
  assert.equal(s.edge, "right")
  assert.ok(s.progress > 0 && s.progress < 1)
  assert.equal(s.ready, false)
})

test("swipeWindowProgress: pull right → prev window, enters from left edge", () => {
  const s = swipeWindowProgress(80, -12, {threshold: 120})
  assert.equal(s.dir, "prev")
  assert.equal(s.edge, "left")
})

test("swipeWindowProgress: a fast flick commits before full travel", () => {
  // Only ~58% of the threshold, but a quick fling in the same direction commits.
  const s = swipeWindowProgress(-70, 8, {threshold: 120, velocity: -0.9})
  assert.equal(s.axis, "h")
  assert.equal(s.ready, true)
  assert.equal(s.flick, true)
  assert.ok(s.progress < 1)
})

test("swipeWindowProgress: a flick against the drag direction does not commit", () => {
  // Velocity points right while the drag is leftward → not a real flick.
  const s = swipeWindowProgress(-70, 8, {threshold: 120, velocity: 0.9})
  assert.equal(s.ready, false)
  assert.equal(s.flick, false)
})

test("swipeWindowProgress: a slow drag below threshold is not ready", () => {
  const s = swipeWindowProgress(-70, 8, {threshold: 120, velocity: -0.1})
  assert.equal(s.ready, false)
  assert.equal(s.flick, false)
})

test("swipeWindowProgress: past threshold is ready and clamps at 1", () => {
  const s = swipeWindowProgress(-240, 20, {threshold: 120})
  assert.equal(s.axis, "h")
  assert.equal(s.dir, "next")
  assert.equal(s.ready, true)
  assert.equal(s.progress, 1)
})

test("swipeWindowProgress: horizontal must clearly lead vertical", () => {
  // |dx| barely over |dy| but under startPx → undecided.
  assert.equal(swipeWindowProgress(9, 8, {startPx: 12}).axis, null)
  // Diagonal where dy >= dx is not a horizontal swipe.
  assert.equal(swipeWindowProgress(40, 40).axis, null)
})

test("swipeThresholdPx clamps to a thumb-comfortable range", () => {
  assert.equal(swipeThresholdPx(200), 90) // 0.32*200=64 → floor 90
  assert.equal(swipeThresholdPx(1000), 160) // 0.32*1000=320 → cap 160
  assert.equal(swipeThresholdPx(400), 128) // 0.32*400
  assert.equal(swipeThresholdPx(0), 115) // fallback width 360 → 0.32*360≈115
})

// --- swipeWindowList / resolveSwipeTarget -----------------------------------

function dom(html) {
  return new JSDOM(html).window.document
}

function stripDoc(windows, {leaderJson} = {}) {
  const document = dom(
    `<div id="leader"></div><div phx-hook="WindowTabStrip"><div data-tab-scroller></div></div>`,
  )
  const scroller = document.querySelector("[data-tab-scroller]")
  windows.forEach(({index, name, active}) => {
    const tab = document.createElement("div")
    tab.setAttribute("data-ctx-window-id", `@${index}`)
    tab.setAttribute("data-window-index", String(index))
    tab.setAttribute("data-window-name", name)
    tab.setAttribute("data-window-activity", "idle")
    if (active) tab.setAttribute("data-active-window", "true")
    scroller.appendChild(tab)
  })
  const leader = document.querySelector("#leader")
  if (leaderJson !== undefined) leader.setAttribute("data-tmux-windows", leaderJson)
  return {scroller, leader}
}

const win = (index, name, active = false) => ({
  index: String(index),
  name,
  activity: "idle",
  attention: "",
  active,
})

test("resolveSwipeTarget: next/prev land either side of the active window", () => {
  const windows = [win(0, "shell"), win(1, "claude", true), win(2, "logs")]

  const next = resolveSwipeTarget(windows, "next")
  assert.equal(next.adjacent.name, "logs")
  assert.equal(next.position, 3)
  assert.equal(next.count, 3)
  assert.equal(next.current.name, "claude")

  const prev = resolveSwipeTarget(windows, "prev")
  assert.equal(prev.adjacent.name, "shell")
  assert.equal(prev.position, 1)
})

test("resolveSwipeTarget: wraps at both ends like tmux", () => {
  assert.equal(
    resolveSwipeTarget([win(0, "shell", true), win(1, "claude")], "prev").adjacent.name,
    "claude",
  )
  assert.equal(
    resolveSwipeTarget([win(0, "shell"), win(1, "claude", true)], "next").adjacent.name,
    "shell",
  )
})

test("resolveSwipeTarget: a lone window reports itself, not just the absence", () => {
  const target = resolveSwipeTarget([win(0, "claude", true)], "next")
  assert.equal(target.adjacent, undefined)
  assert.equal(target.reason, "only")
  assert.equal(target.count, 1)
  assert.equal(target.current.name, "claude")
})

test("resolveSwipeTarget: distinguishes no windows from an unmarked active one", () => {
  assert.equal(resolveSwipeTarget([], "next").reason, "unavailable")
  assert.equal(resolveSwipeTarget(null, "next").reason, "unavailable")

  const unmarked = resolveSwipeTarget([win(0, "shell"), win(1, "claude")], "next")
  assert.equal(unmarked.reason, "unknown_active")
  assert.equal(unmarked.count, 2)
})

test("swipeWindowList: reads the rendered strip when it is there", () => {
  const {scroller, leader} = stripDoc([
    {index: 0, name: "shell"},
    {index: 1, name: "claude", active: true},
  ])

  const list = swipeWindowList(scroller, leader)
  assert.deepEqual(
    list.map((w) => [w.index, w.name, w.active]),
    [
      ["0", "shell", false],
      ["1", "claude", true],
    ],
  )
})

test("swipeWindowList: falls back to the leader root in focus mode", () => {
  // Focus mode unmounts the header, so there is no strip to read — the swipe
  // must still name its target instead of claiming there is no other window.
  const encoded = JSON.stringify([win(0, "shell", true), win(1, "claude")])
  const {leader} = stripDoc([], {leaderJson: encoded})

  const list = swipeWindowList(null, leader)
  assert.equal(list.length, 2)
  assert.equal(resolveSwipeTarget(list, "next").adjacent.name, "claude")
})

test("swipeWindowList: survives a missing or corrupt data island", () => {
  const {leader} = stripDoc([])
  assert.deepEqual(swipeWindowList(null, null), [])
  assert.deepEqual(swipeWindowList(null, leader), [])

  const {leader: broken} = stripDoc([], {leaderJson: "{not json"})
  assert.deepEqual(swipeWindowList(null, broken), [])

  const {leader: notList} = stripDoc([], {leaderJson: '{"windows": []}'})
  assert.deepEqual(swipeWindowList(null, notList), [])
})
