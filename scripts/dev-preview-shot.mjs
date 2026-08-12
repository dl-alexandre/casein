#!/usr/bin/env node
//
// dev-preview-shot.mjs — screenshot a URL at a chosen viewport with mobile/touch
// emulation, using the playwright bundled in priv/scripts/node_modules.
//
// This emulates a real mobile device (pointer: coarse + touch), so responsive
// chrome gated on `@media (pointer: coarse)` renders — not just width-gated UI.
//
// Usage:
//   node scripts/dev-preview-shot.mjs <url> <out.png> [WxH] [--desktop]
//
//   WxH        viewport, default 390x844 (iPhone-ish). Ignored shape for --desktop.
//   --desktop  fine pointer, 1280x900 — use to confirm mobile chrome is HIDDEN.
//
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Resolve playwright from this checkout (never a host operator path) — #248.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(path.join(root, "priv/scripts/package.json"));
const { chromium } = require("playwright");

const [, , url, out, sizeArg] = process.argv;
const desktop = process.argv.includes("--desktop");
if (!url || !out) {
  console.error("usage: dev-preview-shot.mjs <url> <out.png> [WxH] [--desktop]");
  process.exit(2);
}

const [w, h] = (sizeArg && sizeArg.includes("x") ? sizeArg : "390x844")
  .split("x")
  .map((n) => parseInt(n, 10));

const browser = await chromium.launch();
const context = desktop
  ? await browser.newContext({ viewport: { width: 1280, height: 900 } })
  : await browser.newContext({
      viewport: { width: w, height: h },
      hasTouch: true,
      isMobile: true,
      deviceScaleFactor: 2,
    });

const page = await context.newPage();
await page.goto(url, { waitUntil: "networkidle", timeout: 30000 });
// LiveView connects after first paint; give the socket a beat to mount chrome.
await page.waitForTimeout(1500);
await page.screenshot({ path: out, fullPage: false });
await browser.close();
console.log(`shot ${desktop ? "desktop" : `${w}x${h} mobile`} -> ${out}`);
