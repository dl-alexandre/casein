import test from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const assetsDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const root = path.dirname(assetsDir)
const script = path.join(root, "scripts", "verify_preview_bridge_file_page.mjs")
const bridgeSrc = path.join(assetsDir, "js", "preview_bridge.js")

test("preview_bridge source exposes installPreviewBridge and casein_preview gate", () => {
  const src = fs.readFileSync(bridgeSrc, "utf8")
  assert.match(src, /export function installPreviewBridge/)
  assert.match(src, /casein_preview/)
  assert.match(src, /casein:preview:bridge_ready/)
  assert.match(src, /casein:preview:dom_loaded/)
  assert.match(src, /casein:preview:client_error/)
  assert.match(src, /casein:preview:live_socket_connected/)
  assert.match(src, /casein:preview:page_loading_start/)
  assert.match(src, /postMessage/)
})

test("verify_preview_bridge_file_page.mjs exists and documents honesty bounds", () => {
  const src = fs.readFileSync(script, "utf8")
  assert.match(src, /does_not_prove/)
  assert.match(src, /clean_win11_signed_install/)
  assert.match(src, /own_origin_or_path_prefix_proxy/)
  assert.match(src, /esbuild/)
  assert.match(src, /playwright/)
  assert.match(src, /schema_version: 2/)
  assert.match(src, /post_message_envelope/)
  assert.match(src, /disabled_without_preview_query/)
  // Screenshots are intentionally not required (host Protocol error noise).
  assert.match(src, /does not require screenshots/)
  assert.doesNotMatch(src, /page\.screenshot\(/)
})

test(
  "esbuild IIFE + playwright file:// walk covers bridge signal contract v2",
  { timeout: 120_000 },
  () => {
    const result = spawnSync(process.execPath, [script, "--json"], {
      encoding: "utf8",
      cwd: root,
      env: { ...process.env, NODE_ENV: "test" },
      timeout: 110_000,
    })

    if (result.status === 2) {
      assert.fail(`missing deps: ${result.stderr || result.stdout}`)
    }

    assert.equal(result.status, 0, result.stderr || result.stdout)
    const doc = JSON.parse(result.stdout)
    assert.equal(doc.ok, true)
    assert.equal(doc.issue, 463)
    assert.equal(doc.schema_version, 2)
    assert.equal(doc.steps.esbuild_iife.outcome, "passed")
    assert.equal(doc.steps.bridge_ready.outcome, "passed")
    assert.equal(doc.steps.dom_loaded.outcome, "passed")
    assert.equal(doc.steps.post_message_envelope.outcome, "passed")
    assert.equal(doc.steps.live_socket_class_flip.outcome, "passed")
    assert.equal(doc.steps.client_error_signal.outcome, "passed")
    assert.equal(doc.steps.page_loading_signals.outcome, "passed")
    assert.equal(doc.steps.disabled_without_preview_query.outcome, "passed")
    assert.ok(doc.proves.includes("bridge_ready_and_dom_loaded_signals"))
    assert.ok(doc.proves.includes("parent_post_message_envelope"))
    assert.ok(doc.proves.includes("disabled_without_casein_preview_query"))
    assert.ok(doc.does_not_prove.includes("clean_win11_signed_install"))
    assert.ok(doc.does_not_prove.includes("agent_driven_preview_mcp_walk"))
    assert.ok(doc.does_not_prove.includes("own_origin_or_path_prefix_proxy"))
    assert.ok(doc.snapshot.types.includes("casein:preview:bridge_ready"))
    assert.ok(doc.snapshot.types.includes("casein:preview:dom_loaded"))
    assert.ok(doc.snapshot.types.includes("casein:preview:live_socket_disconnected"))
    assert.ok(doc.snapshot.types.includes("casein:preview:client_error"))
    assert.ok(doc.snapshot.types.includes("casein:preview:page_loading_start"))
    assert.ok(doc.snapshot.parentTypes.includes("casein:preview:bridge_ready"))
    assert.equal(doc.snapshot.disabledStatus, "disabled")
  }
)
