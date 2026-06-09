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
const DAEMON_STARTED_AT = Date.now();
const BROWSER_IDLE_MS = envMs(
  ["DEVIDE_PLAYWRIGHT_BROWSER_IDLE_MS", "DEV_IDE_PREVIEW_BROWSER_IDLE_MS"],
  5 * 60 * 1000
);
const BROWSER_MAX_AGE_MS = envMs(
  ["DEVIDE_PLAYWRIGHT_BROWSER_MAX_AGE_MS", "DEV_IDE_PREVIEW_BROWSER_MAX_AGE_MS"],
  30 * 60 * 1000
);
const DAEMON_MAX_AGE_MS = envMs(
  ["DEVIDE_PLAYWRIGHT_DAEMON_MAX_AGE_MS", "DEV_IDE_PREVIEW_DAEMON_MAX_AGE_MS"],
  60 * 60 * 1000
);
const SWEEP_MS = envMs(
  ["DEVIDE_PLAYWRIGHT_SWEEP_MS", "DEV_IDE_PREVIEW_SWEEP_INTERVAL_MS"],
  60 * 1000
);
let maintenanceRunning = false;
let retiring = false;

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
  await closeAllBrowsers();
  process.exit(0);
}

async function daemon() {
  const rl = createInterface({ input: process.stdin, terminal: false });
  const maintenance = setInterval(() => {
    maintenanceTick().catch(() => {
      // best effort; individual command handlers will still surface failures
    });
  }, SWEEP_MS);

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

  clearInterval(maintenance);
  await closeAllBrowsers();
}

async function handlePayload(payload) {
  await maintenanceTick({ allowRetire: false });

  const { action, url, browser_id: id, params = {} } = payload;

  switch (action) {
    case "close": {
      const entry = browsers.get(id);
      if (entry) {
        await closeBrowser(id, entry);
        browsers.delete(id);
      }
      return ok({ closed: true });
    }

    case "click":
    case "type":
    case "press":
    case "screenshot": {
      const { entry, page } = await pageFor(id, url);

      try {
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
      } finally {
        releaseBrowser(entry);
      }
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
  let entry = browsers.get(id);
  if (!entry) {
    entry = {
      browser: await chromium.launch({ headless: true, args: LAUNCH_ARGS }),
      createdAt: Date.now(),
      lastUsedAt: Date.now(),
      active: 0,
    };
    browsers.set(id, entry);
  }

  entry.active += 1;
  entry.lastUsedAt = Date.now();

  try {
    const context = entry.browser.contexts()[0] || (await entry.browser.newContext());
    const page = context.pages()[0] || (await context.newPage());
    if (url && page.url() !== url) {
      await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    }
    return { entry, browser: entry.browser, page };
  } catch (error) {
    releaseBrowser(entry);
    throw error;
  }
}

function releaseBrowser(entry) {
  entry.active = Math.max(0, entry.active - 1);
  entry.lastUsedAt = Date.now();
}

async function maintenanceTick(opts = {}) {
  if (maintenanceRunning) return;

  const allowRetire = opts.allowRetire ?? true;

  maintenanceRunning = true;
  try {
    await closeExpiredBrowsers();

    if (DAEMON_MAX_AGE_MS > 0 && Date.now() - DAEMON_STARTED_AT >= DAEMON_MAX_AGE_MS) {
      retiring = true;
    }

    if (allowRetire && retiring && idleBrowserCount() === browsers.size) {
      await closeAllBrowsers();
      process.exit(0);
    }
  } finally {
    maintenanceRunning = false;
  }
}

async function closeExpiredBrowsers() {
  const now = Date.now();

  for (const [id, entry] of browsers.entries()) {
    if (entry.active > 0) continue;

    const idleExpired = BROWSER_IDLE_MS > 0 && now - entry.lastUsedAt >= BROWSER_IDLE_MS;
    const ageExpired = BROWSER_MAX_AGE_MS > 0 && now - entry.createdAt >= BROWSER_MAX_AGE_MS;

    if (idleExpired || ageExpired) {
      await closeBrowser(id, entry);
      browsers.delete(id);
    }
  }
}

async function closeAllBrowsers() {
  for (const [id, entry] of browsers.entries()) {
    await closeBrowser(id, entry);
  }

  browsers.clear();
}

async function closeBrowser(_id, entry) {
  try {
    await entry.browser.close();
  } catch {
    // best effort
  }
}

function idleBrowserCount() {
  let count = 0;

  for (const entry of browsers.values()) {
    if (entry.active === 0) count += 1;
  }

  return count;
}

function envMs(names, fallback) {
  for (const name of names) {
    const value = Number.parseInt(process.env[name] || "", 10);
    if (Number.isFinite(value) && value >= 0) return value;
  }

  return fallback;
}

function ok(result) {
  return { ok: true, ...result };
}

function fail(error) {
  return { ok: false, error };
}

main();
