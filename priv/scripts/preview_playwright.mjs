#!/usr/bin/env node
/**
 * Playwright helper for DevIDE preview control.
 *
 * One-shot:  node preview_playwright.mjs '<json>'
 * Daemon:     node preview_playwright.mjs --daemon   (newline-delimited JSON on stdin)
 */

import { createInterface } from "readline";
import { chromium } from "playwright";

const browsers = new Map();

async function main() {
  if (process.argv.includes("--daemon")) {
    await daemon();
    return;
  }

  const payload = JSON.parse(process.argv[2] || "{}");
  const result = await handlePayload(payload);
  console.log(JSON.stringify(result));

  // One-shot mode (the Elixir adapter invokes us per command via System.cmd,
  // which blocks until we exit). A launched browser keeps the event loop alive,
  // so close everything and exit explicitly — otherwise the caller hangs.
  for (const browser of browsers.values()) {
    try {
      await browser.close();
    } catch {
      // best effort
    }
  }
  process.exit(0);
}

async function daemon() {
  const rl = createInterface({ input: process.stdin, terminal: false });

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    try {
      const payload = JSON.parse(trimmed);
      const result = await handlePayload(payload);
      process.stdout.write(JSON.stringify(result) + "\n");
    } catch (error) {
      process.stdout.write(
        JSON.stringify({ ok: false, error: error.message || "playwright_failed" }) + "\n"
      );
    }
  }
}

async function handlePayload(payload) {
  const { action, url, browser_id: id, params = {} } = payload;

  switch (action) {
    case "close": {
      const browser = browsers.get(id);
      if (browser) {
        await browser.close();
        browsers.delete(id);
      }
      return ok({ closed: true });
    }

    case "click":
    case "type":
    case "press":
    case "screenshot": {
      const { page } = await pageFor(id, url);
      if (action === "click") {
        if (params.selector) await page.click(params.selector, { timeout: 10_000 });
        else if (params.x != null && params.y != null) await page.mouse.click(params.x, params.y);
        else throw new Error("invalid_target");
      } else if (action === "type") {
        await page.fill(params.selector, params.text ?? "", { timeout: 10_000 });
      } else if (action === "press") {
        await page.keyboard.press(params.key);
      } else if (action === "screenshot") {
        const buffer = await page.screenshot({ type: "png" });
        const artifact = `data:image/png;base64,${buffer.toString("base64")}`;
        return ok({
          url: page.url(),
          observation: { url: page.url(), screenshot: { artifact } },
          artifact,
        });
      }

      const title = await page.title();
      return ok({
        url: page.url(),
        observation: {
          url: page.url(),
          title,
          dom_summary: { title },
          console_errors: [],
          network_errors: [],
        },
      });
    }

    default:
      return fail("not_allowed");
  }
}

// Chromium's setuid sandbox can't initialize when running as root or inside a
// container without user namespaces (the devbox case, DEV_IDE_ON_DEVBOX=true),
// where launch otherwise hangs. --no-sandbox is safe here: the helper only ever
// loads workspace-trusted, origin-gated URLs validated upstream by PreviewControl.
// --disable-gpu avoids a headless GPU/SwiftShader init hang on the devbox when
// rasterizing for screenshots; --no-sandbox/--disable-dev-shm-usage are the
// standard container/root flags.
const LAUNCH_ARGS = ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"];

async function pageFor(id, url) {
  let browser = browsers.get(id);
  if (!browser) {
    browser = await chromium.launch({ headless: true, args: LAUNCH_ARGS });
    browsers.set(id, browser);
  }

  const context = browser.contexts()[0] || (await browser.newContext());
  const page = context.pages()[0] || (await context.newPage());
  if (url && page.url() !== url) {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
  }
  return { browser, page };
}

function ok(result) {
  return { ok: true, ...result };
}

function fail(error) {
  return { ok: false, error };
}

main();