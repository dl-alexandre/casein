import assert from "node:assert/strict"
import test from "node:test"

import {
  AGENT_REFERENCE_MIME,
  readAgentReference,
  referencePayload,
} from "../js/agent_reference_drag.mjs"

test("referencePayload builds a stable window reference from data attributes", () => {
  const element = {
    dataset: {
      agentReferenceKind: "window",
      agentReferenceWorkspaceId: "ws-1",
      agentReferenceSessionId: "session-1",
      agentReferenceWindowId: "@2",
      agentReferenceWindowIndex: "2",
      agentReferenceLabel: "tests",
    },
  }

  assert.deepEqual(referencePayload(element), {
    kind: "window",
    workspace_id: "ws-1",
    session_id: "session-1",
    tmux_session: "",
    window_id: "@2",
    window_index: "2",
    label: "tests",
  })
})

test("readAgentReference ignores unrelated and malformed drops", () => {
  assert.equal(readAgentReference({types: ["text/plain"]}), null)
  assert.equal(
    readAgentReference({
      types: [AGENT_REFERENCE_MIME],
      getData: () => "{broken",
    }),
    null,
  )
})
