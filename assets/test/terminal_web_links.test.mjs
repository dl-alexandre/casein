import assert from "node:assert/strict"
import test from "node:test"

import { webLinkAt, updateWebLinkStore } from "../js/terminal_web_links.mjs"

function link(row, from, to, url) {
  return { row, from, to, url }
}

test("wrapped row segments resolve to the complete URL", () => {
  const store = new Map()
  const url = "https://example.com/a/very/long/path"

  updateWebLinkStore(store, {
    full_frame: true,
    web_links: [link(2, 5, 19, url), link(3, 0, 19, url), link(4, 0, 3, url)]
  })

  assert.equal(webLinkAt(store, 2, 8).url, url)
  assert.equal(webLinkAt(store, 3, 8).url, url)
  assert.equal(webLinkAt(store, 4, 2).url, url)
})

test("incremental frames clear every server-selected link row", () => {
  const store = new Map()
  store.set(1, [link(1, 0, 9, "https://keep.test")])
  store.set(2, [link(2, 0, 9, "https://stale.test")])
  store.set(3, [link(3, 0, 9, "https://stale.test")])

  const url = "https://fresh.test/a/long/path"
  updateWebLinkStore(store, {
    full_frame: false,
    rows: [{ index: 2, cells: [] }],
    web_link_rows: [2, 3],
    web_links: [link(2, 4, 9, url), link(3, 0, 8, url)]
  })

  assert.equal(webLinkAt(store, 1, 4).url, "https://keep.test")
  assert.equal(webLinkAt(store, 2, 5).url, url)
  assert.equal(webLinkAt(store, 3, 5).url, url)
})
