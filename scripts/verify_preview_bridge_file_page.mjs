#!/usr/bin/env node
/**
 * #463 — real browser verification of assets/js/preview_bridge.js WITHOUT the
 * /verify harness and WITHOUT claiming clean-Win11 Preview MCP acceptance.
 *
 * Proves on this Linux box:
 *   - esbuild bundles preview_bridge.js to a browser IIFE
 *   - a static file:// HTML page loads that IIFE
 *   - playwright-core (from priv/scripts playwright) drives Chromium
 *   - with ?casein_preview=1 the bridge emits casein:preview:bridge_ready
 *     and casein:preview:dom_loaded (captured via page.evaluate listeners)
 *
 * Does NOT prove:
 *   - clean-machine Windows install
 *   - agent-driven Preview MCP discover/open/observe/click/type/press/screenshot/close
 *   - packaged Node/Playwright/Chromium on Windows (see package smoke + #803)
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
  // try require from assets
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
  const htmlPath = path.join(tmp, "bridge_fixture.html")
  const entry = path.join(ROOT, "assets/js/preview_bridge.js")

  if (!fs.existsSync(entry)) {
    fail(1, `missing entry ${entry}`)
  }

  // --- esbuild IIFE ---
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
      // process.env.NODE_ENV is referenced; define for browser
      "--define:process.env.NODE_ENV=\"production\"",
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

  // --- static page ---
  // Install exposes installPreviewBridge on the IIFE global.
  // With ?casein_preview=1 the bridge enables even under production NODE_ENV.
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Casein Preview Bridge File Fixture</title>
</head>
<body class="phx-connected">
  <h1 id="title">Casein Preview Bridge File Fixture</h1>
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
  fs.writeFileSync(htmlPath, html, "utf8")
  // copy is unnecessary — iife already beside html; script src is relative
  mark("write_static_page", "passed", path.basename(htmlPath))

  // --- playwright ---
  // Resolve from priv/scripts so package exports work (not a bare file URL).
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

  try {
    const page = await browser.newPage()
    const fileUrl = pathToFileURL(htmlPath).href + "?casein_preview=1"

    const resp = await page.goto(fileUrl, { waitUntil: "domcontentloaded", timeout: 30_000 })
    // file:// may yield null response
    if (resp && resp.status() >= 400) {
      mark("load_file_url", "failed", `status=${resp.status()}`)
      fail(1, "file URL load failed", { steps })
    }
    mark("load_file_url", "passed", fileUrl)

    // Wait for bridge signals
    await page.waitForFunction(
      () => {
        const sigs = window.__caseinBridgeSignals || []
        const types = sigs.map((s) => s && s.type)
        return types.includes("casein:preview:bridge_ready")
      },
      { timeout: 10_000 }
    )

    const snapshot = await page.evaluate(() => {
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

    if (snapshot.status !== "installed") {
      mark("bridge_ready", "failed", `status=${snapshot.status}`)
      fail(1, "bridge did not install on page", { steps, snapshot })
    }
    if (!snapshot.types.includes("casein:preview:bridge_ready")) {
      mark("bridge_ready", "failed", `types=${snapshot.types.join(",")}`)
      fail(1, "missing bridge_ready signal", { steps, snapshot })
    }
    if (!snapshot.sources.every((s) => s === "casein-preview")) {
      mark("bridge_ready", "failed", "bad source")
      fail(1, "signal source mismatch", { steps, snapshot })
    }
    mark("bridge_ready", "passed")

    // dom_loaded may race before listener if emitted via microtask before
    // listener attach — re-check; if missing, the bridge still installed.
    // Our HTML attaches the listener BEFORE installPreviewBridge, so it should fire.
    if (!snapshot.types.includes("casein:preview:dom_loaded")) {
      // brief poll
      try {
        await page.waitForFunction(
          () =>
            (window.__caseinBridgeSignals || [])
              .map((s) => s?.type)
              .includes("casein:preview:dom_loaded"),
          { timeout: 3_000 }
        )
      } catch {
        mark("dom_loaded", "failed", `types=${snapshot.types.join(",")}`)
        fail(1, "missing dom_loaded signal", { steps, snapshot })
      }
    }
    mark("dom_loaded", "passed")

    const result = {
      ok: true,
      schema: "casein_preview_bridge_file_page",
      schema_version: 1,
      issue: 463,
      proves: [
        "esbuild_iife_bundle_of_preview_bridge",
        "file_url_static_page_load",
        "playwright_chromium_drive",
        "bridge_ready_and_dom_loaded_signals",
      ],
      does_not_prove: [
        "clean_win11_signed_install",
        "agent_driven_preview_mcp_walk",
        "packaged_windows_node_playwright_chromium",
      ],
      steps,
      snapshot: {
        title: snapshot.title,
        status: snapshot.status,
        types: snapshot.types,
        hasBridge: snapshot.hasBridge,
      },
    }

    if (wantJson) console.log(JSON.stringify(result, null, 2))
    else {
      console.log("OK: preview_bridge file:// IIFE walk passed")
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
