#!/usr/bin/env node
/**
 * #463 — real browser verification of assets/js/preview_bridge.js WITHOUT the
 * /verify harness and WITHOUT claiming clean-Win11 Preview MCP acceptance.
 *
 * Proves on this Linux box (slice 3 extends #832):
 *   - esbuild bundles preview_bridge.js to a browser IIFE
 *   - a static file:// HTML page loads that IIFE under Playwright Chromium
 *   - with ?casein_preview=1 the bridge emits casein:preview:bridge_ready
 *     and casein:preview:dom_loaded (CustomEvent + parent postMessage envelope)
 *   - body class phx-connected/phx-disconnected flips emit live_socket_* signals
 *   - window error emits casein:preview:client_error
 *   - phx:page-loading-start/stop emit page_loading_* signals
 *   - without casein_preview=1 (top-level, production NODE_ENV) the bridge
 *     does NOT install
 *
 * Does NOT prove:
 *   - clean-machine Windows install
 *   - agent-driven Preview MCP discover/open/observe/click/type/press/screenshot/close
 *   - packaged Node/Playwright/Chromium on Windows (see package smoke + #803)
 *   - own-origin / path-prefix preview proxy routing (sibling slice)
 *
 * Known host noise: page.screenshot Protocol error under load is host pressure;
 * this script does not require screenshots for the pass criteria.
 *
 * Usage:
 *   node scripts/verify_preview_bridge_file_page.mjs
 *   node scripts/verify_preview_bridge_file_page.mjs --json
 *
 * Exit 0 on pass, 1 on failure, 2 on missing deps.
 */
import { spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { createRequire } from "node:module"

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, "..")
const wantJson = process.argv.includes("--json")

const STEP_ORDER = [
  "esbuild_iife",
  "write_static_page",
  "launch_chromium",
  "load_file_url",
  "bridge_ready",
  "dom_loaded",
  "post_message_envelope",
  "live_socket_class_flip",
  "client_error_signal",
  "page_loading_signals",
  "disabled_without_preview_query",
]

function fail(code, msg, extra = {}) {
  const out = { ok: false, error: msg, ...extra }
  if (wantJson) console.log(JSON.stringify(out, null, 2))
  else console.error(`ERROR: ${msg}`)
  process.exit(code)
}

function resolveEsbuild() {
  const candidates = [
    path.join(ROOT, "assets/node_modules/esbuild/bin/esbuild"),
    path.join(ROOT, "assets/node_modules/.bin/esbuild"),
  ]
  for (const c of candidates) {
    if (fs.existsSync(c)) return c
  }
  try {
    const req = createRequire(path.join(ROOT, "assets/package.json"))
    return req.resolve("esbuild/bin/esbuild")
  } catch {
    return null
  }
}

function resolvePlaywright() {
  const candidates = [
    path.join(ROOT, "priv/scripts/node_modules/playwright"),
    path.join(ROOT, "priv/scripts/node_modules/playwright-core"),
  ]
  for (const c of candidates) {
    if (fs.existsSync(c)) return c
  }
  return null
}

function typesOf(sigs) {
  return (sigs || []).map((s) => s && s.type).filter(Boolean)
}

async function main() {
  const steps = Object.fromEntries(STEP_ORDER.map((id) => [id, { outcome: "not_run" }]))
  const mark = (id, outcome, notes = "") => {
    steps[id] = { outcome, notes }
  }

  const esbuildBin = resolveEsbuild()
  if (!esbuildBin) {
    fail(2, "esbuild not found under assets/node_modules — run npm ci in assets/")
  }

  const pwRoot = resolvePlaywright()
  if (!pwRoot) {
    fail(2, "playwright not found under priv/scripts/node_modules — run npm ci in priv/scripts/")
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "casein-463-bridge-"))
  const iifePath = path.join(tmp, "preview_bridge.iife.js")
  const childPath = path.join(tmp, "bridge_child.html")
  const parentPath = path.join(tmp, "bridge_parent.html")
  const disabledPath = path.join(tmp, "bridge_disabled.html")
  const entry = path.join(ROOT, "assets/js/preview_bridge.js")

  if (!fs.existsSync(entry)) {
    fail(1, `missing entry ${entry}`)
  }

  const build = spawnSync(
    esbuildBin,
    [
      entry,
      "--bundle",
      "--format=iife",
      "--global-name=CaseinPreviewBridge",
      `--outfile=${iifePath}`,
      "--platform=browser",
      "--target=es2020",
      '--define:process.env.NODE_ENV="production"',
      "--log-level=warning",
    ],
    { encoding: "utf8" }
  )
  if (build.status !== 0) {
    mark("esbuild_iife", "failed", (build.stderr || build.stdout || "").slice(0, 400))
    fail(1, "esbuild IIFE build failed", { steps, stderr: build.stderr })
  }
  if (!fs.existsSync(iifePath) || fs.statSync(iifePath).size < 100) {
    mark("esbuild_iife", "failed", "empty outfile")
    fail(1, "esbuild produced empty IIFE", { steps })
  }
  mark("esbuild_iife", "passed", `bytes=${fs.statSync(iifePath).size}`)

  // Child page: installed under ?casein_preview=1; parent captures postMessage.
  const childHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Casein Preview Bridge Child</title>
</head>
<body class="phx-connected">
  <h1 id="title">Casein Preview Bridge Child</h1>
  <p id="status">loading</p>
  <script src="./preview_bridge.iife.js"></script>
  <script>
    window.__caseinBridgeSignals = [];
    window.addEventListener("casein:preview:signal", (event) => {
      window.__caseinBridgeSignals.push(event.detail);
    });
    try {
      const api = window.CaseinPreviewBridge;
      if (!api || typeof api.installPreviewBridge !== "function") {
        document.getElementById("status").textContent = "missing_install";
      } else {
        api.installPreviewBridge({});
        document.getElementById("status").textContent = "installed";
      }
    } catch (err) {
      document.getElementById("status").textContent = "error:" + (err && err.message);
    }
  </script>
</body>
</html>
`

  const parentHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Casein Preview Bridge Parent</title>
</head>
<body>
  <h1>Casein Preview Bridge Parent</h1>
  <iframe id="child" src="./bridge_child.html?casein_preview=1" title="child"></iframe>
  <script>
    window.__caseinParentMessages = [];
    window.addEventListener("message", (event) => {
      const data = event.data;
      if (data && data.source === "casein-preview") {
        window.__caseinParentMessages.push(data);
      }
    });
  </script>
</body>
</html>
`

  // Top-level page without casein_preview=1 under production NODE_ENV must not install.
  const disabledHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Casein Preview Bridge Disabled</title>
</head>
<body>
  <p id="status">loading</p>
  <script src="./preview_bridge.iife.js"></script>
  <script>
    window.__caseinBridgeSignals = [];
    window.addEventListener("casein:preview:signal", (event) => {
      window.__caseinBridgeSignals.push(event.detail);
    });
    try {
      const api = window.CaseinPreviewBridge;
      const bridge = api && api.installPreviewBridge ? api.installPreviewBridge({}) : null;
      document.getElementById("status").textContent = bridge ? "installed" : "disabled";
    } catch (err) {
      document.getElementById("status").textContent = "error:" + (err && err.message);
    }
  </script>
</body>
</html>
`

  fs.writeFileSync(childPath, childHtml, "utf8")
  fs.writeFileSync(parentPath, parentHtml, "utf8")
  fs.writeFileSync(disabledPath, disabledHtml, "utf8")
  mark("write_static_page", "passed", "parent+child+disabled")

  const req = createRequire(path.join(ROOT, "priv/scripts/package.json"))
  const playwright = req("playwright")
  const chromium = playwright.chromium
  let browser
  try {
    browser = await chromium.launch({
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage"],
    })
    mark("launch_chromium", "passed")
  } catch (err) {
    mark("launch_chromium", "failed", String(err?.message || err).slice(0, 300))
    fail(1, "chromium launch failed", { steps })
  }

  const snapshot = {
    title: null,
    status: null,
    types: [],
    parentTypes: [],
    hasBridge: false,
    disabledStatus: null,
  }

  try {
    const context = await browser.newContext()
    const parentPage = await context.newPage()
    const parentUrl = pathToFileURL(parentPath).href

    const resp = await parentPage.goto(parentUrl, {
      waitUntil: "domcontentloaded",
      timeout: 30_000,
    })
    if (resp && resp.status() >= 400) {
      mark("load_file_url", "failed", `status=${resp.status()}`)
      fail(1, "parent file URL load failed", { steps })
    }
    mark("load_file_url", "passed", parentUrl)

    const child = parentPage.frameLocator("#child")
    await child.locator("#status").waitFor({ state: "attached", timeout: 10_000 })

    // Wait for child bridge_ready via evaluate on the iframe frame.
    const childFrame = parentPage.frame({ url: /bridge_child\.html/ })
    if (!childFrame) {
      mark("bridge_ready", "failed", "child frame missing")
      fail(1, "child iframe frame not found", { steps })
    }

    await childFrame.waitForFunction(
      () => {
        const sigs = window.__caseinBridgeSignals || []
        return sigs.some((s) => s && s.type === "casein:preview:bridge_ready")
      },
      { timeout: 10_000 }
    )

    const childSnap = await childFrame.evaluate(() => {
      const sigs = window.__caseinBridgeSignals || []
      return {
        status: document.getElementById("status")?.textContent || "",
        title: document.title,
        types: sigs.map((s) => s?.type).filter(Boolean),
        sources: sigs.map((s) => s?.source).filter(Boolean),
        versions: sigs.map((s) => s?.version),
        hasBridge: Boolean(window.__caseinPreviewBridge),
      }
    })

    snapshot.title = childSnap.title
    snapshot.status = childSnap.status
    snapshot.types = childSnap.types
    snapshot.hasBridge = childSnap.hasBridge

    if (childSnap.status !== "installed") {
      mark("bridge_ready", "failed", `status=${childSnap.status}`)
      fail(1, "bridge did not install on child page", { steps, snapshot })
    }
    if (!childSnap.types.includes("casein:preview:bridge_ready")) {
      mark("bridge_ready", "failed", `types=${childSnap.types.join(",")}`)
      fail(1, "missing bridge_ready signal", { steps, snapshot })
    }
    if (!childSnap.sources.every((s) => s === "casein-preview")) {
      mark("bridge_ready", "failed", "bad source")
      fail(1, "signal source mismatch", { steps, snapshot })
    }
    mark("bridge_ready", "passed")

    if (!childSnap.types.includes("casein:preview:dom_loaded")) {
      try {
        await childFrame.waitForFunction(
          () =>
            (window.__caseinBridgeSignals || []).some(
              (s) => s && s.type === "casein:preview:dom_loaded"
            ),
          { timeout: 3_000 }
        )
        const more = await childFrame.evaluate(() =>
          (window.__caseinBridgeSignals || []).map((s) => s?.type).filter(Boolean)
        )
        snapshot.types = more
      } catch {
        mark("dom_loaded", "failed", `types=${childSnap.types.join(",")}`)
        fail(1, "missing dom_loaded signal", { steps, snapshot })
      }
    }
    mark("dom_loaded", "passed")

    // Parent must have received the postMessage envelope (source/version/type).
    await parentPage.waitForFunction(
      () =>
        (window.__caseinParentMessages || []).some(
          (m) => m && m.type === "casein:preview:bridge_ready"
        ),
      { timeout: 5_000 }
    )
    const parentMsgs = await parentPage.evaluate(() => window.__caseinParentMessages || [])
    snapshot.parentTypes = parentMsgs.map((m) => m?.type).filter(Boolean)
    const readyMsg = parentMsgs.find((m) => m?.type === "casein:preview:bridge_ready")
    if (
      !readyMsg ||
      readyMsg.source !== "casein-preview" ||
      readyMsg.version !== 1 ||
      !readyMsg.payload ||
      typeof readyMsg.payload.request_id !== "string"
    ) {
      mark("post_message_envelope", "failed", JSON.stringify(readyMsg || null).slice(0, 200))
      fail(1, "parent postMessage envelope invalid", { steps, snapshot })
    }
    mark("post_message_envelope", "passed")

    // Live socket class flip: connected already emitted; flip to disconnected.
    await childFrame.evaluate(() => {
      document.body.classList.remove("phx-connected")
      document.body.classList.add("phx-disconnected")
    })
    await childFrame.waitForFunction(
      () =>
        (window.__caseinBridgeSignals || []).some(
          (s) => s && s.type === "casein:preview:live_socket_disconnected"
        ),
      { timeout: 5_000 }
    )
    await childFrame.evaluate(() => {
      document.body.classList.remove("phx-disconnected")
      document.body.classList.add("phx-connected")
    })
    await childFrame.waitForFunction(
      () => {
        const types = (window.__caseinBridgeSignals || []).map((s) => s?.type)
        const disc = types.lastIndexOf("casein:preview:live_socket_disconnected")
        const conn = types.lastIndexOf("casein:preview:live_socket_connected")
        return disc >= 0 && conn > disc
      },
      { timeout: 5_000 }
    )
    mark("live_socket_class_flip", "passed")

    // Client error via synthetic ErrorEvent.
    await childFrame.evaluate(() => {
      window.dispatchEvent(
        new ErrorEvent("error", {
          message: "casein_bridge_fixture_error",
          filename: "bridge_child.html",
          lineno: 1,
          colno: 1,
        })
      )
    })
    await childFrame.waitForFunction(
      () =>
        (window.__caseinBridgeSignals || []).some(
          (s) =>
            s &&
            s.type === "casein:preview:client_error" &&
            s.payload &&
            s.payload.message === "casein_bridge_fixture_error"
        ),
      { timeout: 5_000 }
    )
    mark("client_error_signal", "passed")

    // Page loading start/stop custom events (LiveView page loading hooks).
    await childFrame.evaluate(() => {
      window.dispatchEvent(
        new CustomEvent("phx:page-loading-start", { detail: { kind: "patch" } })
      )
      window.dispatchEvent(
        new CustomEvent("phx:page-loading-stop", { detail: { kind: "patch" } })
      )
    })
    await childFrame.waitForFunction(
      () => {
        const types = (window.__caseinBridgeSignals || []).map((s) => s?.type)
        return (
          types.includes("casein:preview:page_loading_start") &&
          types.includes("casein:preview:page_loading_stop")
        )
      },
      { timeout: 5_000 }
    )
    mark("page_loading_signals", "passed")

    // Refresh types after exercised signals.
    snapshot.types = await childFrame.evaluate(() =>
      (window.__caseinBridgeSignals || []).map((s) => s?.type).filter(Boolean)
    )

    // Disabled path: no casein_preview query, top-level, production bundle.
    const disabledPage = await context.newPage()
    const disabledUrl = pathToFileURL(disabledPath).href
    await disabledPage.goto(disabledUrl, { waitUntil: "domcontentloaded", timeout: 30_000 })
    await disabledPage.waitForFunction(
      () => {
        const s = document.getElementById("status")?.textContent
        return s === "disabled" || s === "installed" || (s && s.startsWith("error:"))
      },
      { timeout: 5_000 }
    )
    const disabledSnap = await disabledPage.evaluate(() => ({
      status: document.getElementById("status")?.textContent || "",
      types: (window.__caseinBridgeSignals || []).map((s) => s?.type).filter(Boolean),
      hasBridge: Boolean(window.__caseinPreviewBridge),
    }))
    snapshot.disabledStatus = disabledSnap.status
    if (disabledSnap.status !== "disabled" || disabledSnap.hasBridge || disabledSnap.types.length) {
      mark(
        "disabled_without_preview_query",
        "failed",
        JSON.stringify(disabledSnap).slice(0, 200)
      )
      fail(1, "bridge installed without casein_preview=1", { steps, snapshot })
    }
    mark("disabled_without_preview_query", "passed")
    await disabledPage.close()

    const result = {
      ok: true,
      schema: "casein_preview_bridge_file_page",
      schema_version: 2,
      issue: 463,
      proves: [
        "esbuild_iife_bundle_of_preview_bridge",
        "file_url_static_page_load",
        "playwright_chromium_drive",
        "bridge_ready_and_dom_loaded_signals",
        "parent_post_message_envelope",
        "live_socket_class_flip_signals",
        "client_error_signal",
        "page_loading_start_stop_signals",
        "disabled_without_casein_preview_query",
      ],
      does_not_prove: [
        "clean_win11_signed_install",
        "agent_driven_preview_mcp_walk",
        "packaged_windows_node_playwright_chromium",
        "own_origin_or_path_prefix_proxy",
      ],
      steps,
      snapshot,
    }

    if (wantJson) console.log(JSON.stringify(result, null, 2))
    else {
      console.log("OK: preview_bridge file:// IIFE walk passed (schema v2)")
      console.log("proves:", result.proves.join(", "))
      console.log("does_not_prove:", result.does_not_prove.join(", "))
    }
    process.exit(0)
  } finally {
    try {
      await browser?.close()
    } catch {
      /* ignore */
    }
    try {
      fs.rmSync(tmp, { recursive: true, force: true })
    } catch {
      /* ignore */
    }
  }
}

main().catch((err) => {
  fail(1, err?.message || String(err))
})
