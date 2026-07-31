import test from "node:test"
import assert from "node:assert/strict"

import {
  DEAD_ZONE_PX,
  applyResize,
  axisDelta,
  cellPxFor,
  clamp,
  cloneGeometries,
  directionFor,
  neighborForResize,
  paneStyle,
  sameLayoutStructure,
  signedCells,
} from "../js/tmux_pane_geometry.mjs"

// A 2x2 grid in a 100x40-cell window:
//
//   %0 (0,0 50x20) | %1 (50,0 50x20)
//   ----------------+----------------
//   %2 (0,20 50x20) | %3 (50,20 50x20)
function grid() {
  return new Map([
    ["%0", {left: 0, top: 0, width: 50, height: 20}],
    ["%1", {left: 50, top: 0, width: 50, height: 20}],
    ["%2", {left: 0, top: 20, width: 50, height: 20}],
    ["%3", {left: 50, top: 20, width: 50, height: 20}],
  ])
}

const BOUNDS = {width: 100, height: 40}

// The geometry tmux actually reports: one cell per divider, so neighbours are
// separated by a gap rather than sharing an edge. Read from a live 216x69
// window split into four panes (columns 0-107 | 108 divider | 109-215).
//
//   %a (0,0 108x35)  | %c (109,0  107x34)
//   -- divider row 35 ------ divider row 34 --
//   %b (0,36 108x33) | %d (109,35 107x34)
function dividedGrid() {
  return new Map([
    ["%a", {left: 0, top: 0, width: 108, height: 35}],
    ["%b", {left: 0, top: 36, width: 108, height: 33}],
    ["%c", {left: 109, top: 0, width: 107, height: 34}],
    ["%d", {left: 109, top: 35, width: 107, height: 34}],
  ])
}

test("clamp bounds values on both sides", () => {
  assert.equal(clamp(5, 1, 10), 5)
  assert.equal(clamp(0, 1, 10), 1)
  assert.equal(clamp(11, 1, 10), 10)
})

test("signedCells returns 0 inside the dead zone", () => {
  assert.equal(signedCells(DEAD_ZONE_PX - 1, 12, 50), 0)
  assert.equal(signedCells(-(DEAD_ZONE_PX - 1), 12, 50), 0)
})

test("signedCells rounds to cells, keeps sign, floors at 1 past the dead zone", () => {
  assert.equal(signedCells(24, 12, 50), 2)
  assert.equal(signedCells(-24, 12, 50), -2)
  // Past the dead zone but under half a cell still commits one cell.
  assert.equal(signedCells(DEAD_ZONE_PX, 100, 50), 1)
})

test("signedCells clamps to maxAmount", () => {
  assert.equal(signedCells(1200, 12, 50), 50)
  assert.equal(signedCells(-1200, 12, 50), -50)
})

test("signedCells survives a zero cell width", () => {
  assert.equal(signedCells(24, 0, 50), 24)
})

test("directionFor maps axis and sign", () => {
  assert.equal(directionFor("x", 5), "right")
  assert.equal(directionFor("x", -5), "left")
  assert.equal(directionFor("y", 5), "down")
  assert.equal(directionFor("y", -5), "up")
})

test("axisDelta follows the drag axis", () => {
  const drag = {axis: "x", startX: 100, startY: 200}
  assert.equal(axisDelta(drag, {clientX: 130, clientY: 260}), 30)
  drag.axis = "y"
  assert.equal(axisDelta(drag, {clientX: 130, clientY: 260}), 60)
})

test("cellPxFor derives cell size from bounds, falls back when empty", () => {
  const rect = {width: 800, height: 400}
  assert.equal(cellPxFor({bounds: BOUNDS, axis: "x"}, rect), 8)
  assert.equal(cellPxFor({bounds: BOUNDS, axis: "y"}, rect), 10)
  assert.equal(cellPxFor({bounds: {width: 0, height: 0}, axis: "x"}, rect), 12)
})

test("neighborForResize finds the adjacent pane per direction", () => {
  const geos = grid()
  assert.equal(neighborForResize(geos, "%0", "right"), "%1")
  assert.equal(neighborForResize(geos, "%1", "left"), "%0")
  assert.equal(neighborForResize(geos, "%0", "down"), "%2")
  assert.equal(neighborForResize(geos, "%2", "up"), "%0")
})

test("neighborForResize ignores panes that only touch diagonally", () => {
  const geos = grid()
  // %3 touches %0 only at the corner — never a resize neighbor.
  geos.delete("%1")
  geos.delete("%2")
  assert.equal(neighborForResize(geos, "%0", "right"), null)
  assert.equal(neighborForResize(geos, "%0", "down"), null)
})

test("neighborForResize returns null for unknown panes and edges", () => {
  const geos = grid()
  assert.equal(neighborForResize(geos, "%9", "right"), null)
  assert.equal(neighborForResize(geos, "%1", "right"), null)
})

test("applyResize grows the pane and shrinks the neighbor symmetrically", () => {
  const geos = grid()
  applyResize(geos, "%0", "right", 10)
  assert.equal(geos.get("%0").width, 60)
  assert.equal(geos.get("%1").width, 40)
  // The neighbor's leading edge has to follow the moving boundary, or the
  // grown pane simply paints over it.
  assert.equal(geos.get("%1").left, 60)

  applyResize(geos, "%2", "up", 5)
  assert.equal(geos.get("%2").top, 15)
  assert.equal(geos.get("%2").height, 25)
  assert.equal(geos.get("%0").height, 15)
})

test("neighborForResize sees across the tmux divider cell", () => {
  const geos = dividedGrid()
  assert.equal(neighborForResize(geos, "%a", "right"), "%c")
  assert.equal(neighborForResize(geos, "%c", "left"), "%a")
  assert.equal(neighborForResize(geos, "%a", "down"), "%b")
  assert.equal(neighborForResize(geos, "%b", "up"), "%a")
})

test("a divided-grid drag never overlaps the neighbor", () => {
  const geos = dividedGrid()
  applyResize(geos, "%a", "right", 6)

  const dragged = geos.get("%a")
  const neighbor = geos.get("%c")

  // Divider cell preserved, no overlap, and the window total is unchanged.
  assert.equal(dragged.left + dragged.width, 114)
  assert.equal(neighbor.left, 115)
  assert.equal(neighbor.left + neighbor.width, 216)

  const down = dividedGrid()
  applyResize(down, "%a", "down", 4)
  assert.equal(down.get("%a").top + down.get("%a").height, 39)
  assert.equal(down.get("%b").top, 40)
  assert.equal(down.get("%b").top + down.get("%b").height, 69)
})

test("applyResize on a window edge moves only the pane", () => {
  const geos = grid()
  applyResize(geos, "%1", "right", 10)
  assert.equal(geos.get("%1").width, 60)
  assert.equal(geos.get("%0").width, 50)
})

test("applyResize is a no-op for zero amount or unknown pane", () => {
  const geos = grid()
  applyResize(geos, "%0", "right", 0)
  applyResize(geos, "%9", "right", 10)
  assert.deepEqual(geos.get("%0"), grid().get("%0"))
  assert.deepEqual(geos.get("%1"), grid().get("%1"))
})

test("cloneGeometries copies values and keeps el references", () => {
  const el = {tag: "section"}
  const geos = new Map([["%0", {el, left: 0, top: 0, width: 50, height: 20}]])
  const copy = cloneGeometries(geos)

  copy.get("%0").width = 99
  assert.equal(geos.get("%0").width, 50)
  assert.equal(copy.get("%0").el, el)
})

test("paneStyle converts cells to percentages, guarding zero bounds", () => {
  const style = paneStyle({left: 50, top: 20, width: 50, height: 20}, BOUNDS)
  assert.deepEqual(style, {left: 50, top: 50, width: 50, height: 50})

  const guarded = paneStyle({left: 10, top: 10, width: 10, height: 10}, {width: 0, height: 0})
  assert.deepEqual(guarded, {left: 0, top: 0, width: 0, height: 0})
})

test("sameLayoutStructure accepts value-only geometry changes", () => {
  const base = grid()
  const current = grid()
  current.get("%0").width = 60
  current.get("%1").left = 60
  assert.equal(sameLayoutStructure(base, BOUNDS, current, {...BOUNDS}), true)
})

test("sameLayoutStructure rejects pane-set changes", () => {
  const base = grid()

  const killed = grid()
  killed.delete("%3")
  assert.equal(sameLayoutStructure(base, BOUNDS, killed, BOUNDS), false)

  const swapped = grid()
  swapped.delete("%3")
  swapped.set("%4", {left: 50, top: 20, width: 50, height: 20})
  assert.equal(sameLayoutStructure(base, BOUNDS, swapped, BOUNDS), false)
})

test("sameLayoutStructure rejects window bounds changes", () => {
  const base = grid()
  assert.equal(sameLayoutStructure(base, BOUNDS, grid(), {width: 100, height: 41}), false)
})
