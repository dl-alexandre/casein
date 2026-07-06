import assert from "node:assert/strict"
import test from "node:test"

import { fileLinkAt, updateFileLinkStore } from "../js/terminal_file_links.mjs"

function link(row, from, to, path, line = null) {
  return { row, from, to, path, line }
}

test("full frames reset the store and apply the frame's links", () => {
  const store = new Map()
  store.set(9, [link(9, 0, 5, "old.ex")])

  updateFileLinkStore(store, {
    full_frame: true,
    cells: [[], []],
    file_links: [link(0, 4, 16, "lib/foo.ex", 12)]
  })

  assert.equal(store.has(9), false)
  assert.deepEqual(fileLinkAt(store, 0, 10), link(0, 4, 16, "lib/foo.ex", 12))
})

test("incremental frames clear exactly the repainted rows", () => {
  const store = new Map()
  store.set(1, [link(1, 0, 9, "keep/me.ex")])
  store.set(2, [link(2, 0, 9, "stale/row.ex")])

  updateFileLinkStore(store, {
    full_frame: false,
    rows: [{ index: 2, cells: [] }, { index: 3, cells: [] }],
    file_links: [link(3, 2, 8, "mix.exs")]
  })

  // Untouched row survives; repainted row 2 lost its stale link; row 3 gained one.
  assert.deepEqual(fileLinkAt(store, 1, 5), link(1, 0, 9, "keep/me.ex"))
  assert.equal(fileLinkAt(store, 2, 5), null)
  assert.deepEqual(fileLinkAt(store, 3, 4), link(3, 2, 8, "mix.exs"))
})

test("hydrated incremental payloads (rows + cells) still clear by rows", () => {
  const store = new Map()
  store.set(0, [link(0, 0, 9, "stale.ex")])

  // acceptRenderPayload spreads {...payload, cells}, keeping .rows around.
  updateFileLinkStore(store, {
    full_frame: false,
    rows: [{ index: 0, cells: [] }],
    cells: [[], []]
  })

  assert.equal(fileLinkAt(store, 0, 5), null)
})

test("metadata-only frames leave the store alone", () => {
  const store = new Map()
  store.set(4, [link(4, 1, 6, "lib/a.ex")])

  updateFileLinkStore(store, { scrollbar: { total: 10, offset: 0, len: 5 } })
  updateFileLinkStore(store, null)

  assert.deepEqual(fileLinkAt(store, 4, 3), link(4, 1, 6, "lib/a.ex"))
})

test("fileLinkAt matches inclusive column ranges only on the link's row", () => {
  const store = new Map()
  updateFileLinkStore(store, {
    full_frame: true,
    file_links: [link(2, 4, 10, "lib/foo.ex", 3), link(2, 20, 26, "mix.exs")]
  })

  assert.equal(fileLinkAt(store, 2, 3), null)
  assert.deepEqual(fileLinkAt(store, 2, 4), link(2, 4, 10, "lib/foo.ex", 3))
  assert.deepEqual(fileLinkAt(store, 2, 10), link(2, 4, 10, "lib/foo.ex", 3))
  assert.equal(fileLinkAt(store, 2, 11), null)
  assert.deepEqual(fileLinkAt(store, 2, 22), link(2, 20, 26, "mix.exs"))
  assert.equal(fileLinkAt(store, 1, 5), null)
  assert.equal(fileLinkAt(null, 2, 5), null)
})

test("malformed link entries are ignored", () => {
  const store = new Map()

  updateFileLinkStore(store, {
    full_frame: true,
    file_links: [
      { row: "0", from: 0, to: 5, path: "a.ex" },
      { row: 0, from: 5, to: 2, path: "b.ex" },
      { row: 0, from: 0, to: 5, path: "" },
      { row: 0, from: 0, to: 5 },
      link(0, 0, 5, "ok.ex")
    ]
  })

  assert.deepEqual(store.get(0), [link(0, 0, 5, "ok.ex")])
})
