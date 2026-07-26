import assert from "node:assert/strict"
import test from "node:test"

import {pickerLinkToastDetail, resolvePickerCopyTarget} from "../js/picker_link_copy_url.mjs"

const SHARE_URL = "https://casein.devbox.milcgroup.com/workspaces/ws-1?session=wt-f9874a83"
const AGENT_URL =
  "https://casein.devbox.milcgroup.com/api/terminals/mcp?workspace_id=ws-1&tmux_session=casein_dalexandre-casein_wt-f9874a83"

test("plain click copies the human share link", () => {
  const dataset = {copySessionLink: SHARE_URL, copySessionLinkAgent: AGENT_URL, copyLinkKind: "session"}
  assert.deepEqual(resolvePickerCopyTarget(dataset, {}), {url: SHARE_URL, kind: "session"})
})

test("Ctrl-click upgrades to the agent MCP link", () => {
  const dataset = {copySessionLink: SHARE_URL, copySessionLinkAgent: AGENT_URL, copyLinkKind: "session"}
  assert.deepEqual(resolvePickerCopyTarget(dataset, {ctrlKey: true}), {url: AGENT_URL, kind: "agent"})
})

test("Cmd-click (metaKey) also upgrades to the agent MCP link", () => {
  const dataset = {copySessionLink: SHARE_URL, copySessionLinkAgent: AGENT_URL}
  assert.deepEqual(resolvePickerCopyTarget(dataset, {metaKey: true}), {url: AGENT_URL, kind: "agent"})
})

test("modifier without an agent URL falls back to the human link", () => {
  const dataset = {copySessionLink: SHARE_URL, copyLinkKind: "window"}
  assert.deepEqual(resolvePickerCopyTarget(dataset, {ctrlKey: true}), {url: SHARE_URL, kind: "window"})
})

test("kind defaults to session when unset", () => {
  assert.deepEqual(resolvePickerCopyTarget({copySessionLink: SHARE_URL}, {}), {
    url: SHARE_URL,
    kind: "session"
  })
})

test("toast detail reads tmux_session for agent links", () => {
  assert.equal(pickerLinkToastDetail(AGENT_URL), "f9874a83")
})
