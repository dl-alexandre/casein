#!/usr/bin/env node
/**
 * Playwright helper for DevIDE preview control.
 *
 * One-shot:  node preview_playwright.mjs '<json>'
 * Daemon:     node preview_playwright.mjs --daemon   (newline-delimited JSON on stdin)
 */

import { createInterface } from "readline";
import fs from "fs/promises";
import { chromium } from "playwright";
import { computeDiff, wantsVisualDiff } from "./preview_diff.mjs";

const browsers = new Map();
const instrumentedPages = new WeakSet();
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

  const {
    action,
    url,
    browser_id: id,
    params = {},
    default_headers = {},
    storage_state_path: storageStatePath,
  } = payload;
  const headers = sanitizeHeaders(default_headers);
  const storagePath = sanitizeStorageStatePath(storageStatePath);

  switch (action) {
    case "close": {
      const entry = browsers.get(id);
      if (entry) {
        await closeBrowser(id, entry);
        browsers.delete(id);
      }
      return ok({ closed: true });
    }

    case "observe_live": {
      const { entry, page } = await pageFor(id, url, headers, storagePath);

      try {
        await waitForNetworkIdle(page);
        await persistStorageState(entry);
        const observation = await pageObservation(page, entry);

        return ok({
          url: page.url(),
          observation,
        });
      } finally {
        releaseBrowser(entry);
      }
    }

    case "get_storage": {
      const { entry, page } = await pageFor(id, url, headers, storagePath);

      try {
        const storage = await storageSnapshot(page);
        await persistStorageState(entry);
        const diagnostics = flushDiagnostics(entry);

        return ok({
          url: page.url(),
          local_storage: storage.local_storage,
          session_storage: storage.session_storage,
          console_errors: diagnostics.console_errors,
          network_errors: diagnostics.network_errors,
        });
      } finally {
        releaseBrowser(entry);
      }
    }

    case "clear_storage": {
      const { entry, page } = await pageFor(id, url, headers, storagePath);

      try {
        await page.context().clearCookies();
        await page.evaluate(() => {
          try {
            window.localStorage.clear();
          } catch {}

          try {
            window.sessionStorage.clear();
          } catch {}
        });

        await persistStorageState(entry);
        const storage = await storageSnapshot(page);
        const diagnostics = flushDiagnostics(entry);

        return ok({
          url: page.url(),
          local_storage: storage.local_storage,
          session_storage: storage.session_storage,
          console_errors: diagnostics.console_errors,
          network_errors: diagnostics.network_errors,
        });
      } finally {
        releaseBrowser(entry);
      }
    }

    case "go_back":
    case "go_forward":
    case "reload": {
      const { entry, page } = await pageFor(id, url, headers, storagePath);

      try {
        if (action === "go_back") {
          await page.goBack({ waitUntil: "domcontentloaded", timeout: 15_000 });
        } else if (action === "go_forward") {
          await page.goForward({ waitUntil: "domcontentloaded", timeout: 15_000 });
        } else {
          await page.reload({ waitUntil: "domcontentloaded", timeout: 15_000 });
        }

        await persistStorageState(entry);
        const observation = await pageObservation(page, entry);

        return ok({
          url: page.url(),
          observation,
        });
      } finally {
        releaseBrowser(entry);
      }
    }

    case "click":
    case "type":
    case "press":
    case "screenshot": {
      const { entry, page } = await pageFor(id, url, headers, storagePath);

      try {
        const wantsDiff = wantsVisualDiff(action, params, entry);
        let before = null;
        if (wantsDiff) {
          // Diff is best-effort: a screenshot failure must not abort the action.
          try {
            before = await page.screenshot({ type: "png" });
          } catch {
            before = null;
          }
        }

        if (action === "click") {
          if (params.selector) {
            const loc = await resolveLocator(page, params.selector, params.nth);
            await loc.click({ timeout: 10_000 });
          } else if (params.x != null && params.y != null) {
            await page.mouse.click(params.x, params.y);
          } else throw new Error("invalid_target");
        } else if (action === "type") {
          const loc = await resolveLocator(page, params.selector, params.nth);
          await loc.fill(params.text ?? "", { timeout: 10_000 });
        } else if (action === "press") {
          await page.keyboard.press(params.key);
        } else if (action === "screenshot") {
          const buffer = await page.screenshot({ type: "png" });
          const artifact = `data:image/png;base64,${buffer.toString("base64")}`;
          await persistStorageState(entry);
          const observation = await pageObservation(page, entry);

          return ok({
            url: page.url(),
            observation: { ...observation, screenshot: { artifact } },
            artifact,
          });
        }

        let settled = true;
        if (wantsDiff) {
          settled = await waitForNetworkIdle(page);
        }

        await persistStorageState(entry);
        const observation = await pageObservation(page, entry);

        let diff;
        if (wantsDiff && before) {
          try {
            const after = await page.screenshot({ type: "png" });
            const computed = computeDiff(before, after);
            if (!computed?.mismatch && computed.changed_pixels > 0) {
              diff = { ...computed, settled };
            }
          } catch {
            // Best-effort: drop the diff, keep the action + observation.
            diff = undefined;
          }
        }

        return ok({
          url: page.url(),
          observation,
          ...(diff ? { diff } : {}),
        });
      } finally {
        releaseBrowser(entry);
      }
    }

    // Server-side recording. recordVideo is a context-creation option and the
    // video path is only readable after the context closes, so start replaces
    // the session's context with a recording one (re-navigating), and stop
    // closes it to finalize+harvest the webm. The next command lazily rebuilds a
    // normal context (storageState persists across), so the session survives.
    case "record_start": {
      const { entry } = await pageFor(id, url, headers, storagePath);

      try {
        await persistStorageState(entry);
        const existing = entry.browser.contexts()[0];
        if (existing) await existing.close();

        const options = await contextOptions(storagePath);
        if (params.dir) {
          options.recordVideo = { dir: params.dir };
          if (params.width && params.height) {
            options.recordVideo.size = { width: params.width, height: params.height };
          }
        }

        const context = await entry.browser.newContext(options);
        entry.headerKey = headersKey(headers);
        entry.headerOriginKey = scopedHeaderOriginKey(entry.currentUrl);
        entry.storageStatePath = storagePath;
        await installScopedHeaders(context, headers, entry.currentUrl);

        const page = await context.newPage();
        attachPageDiagnostics(page, entry);
        if (url) {
          await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
        }

        entry.recording = { recordingId: params.recording_id, dir: params.dir };
        return ok({ recording_id: params.recording_id });
      } finally {
        releaseBrowser(entry);
      }
    }

    case "record_stop": {
      const entry = browsers.get(id);
      if (!entry || !entry.recording) return fail("not_recording");

      entry.active += 1;
      entry.lastUsedAt = Date.now();

      try {
        await persistStorageState(entry);

        let videoPath = null;
        const context = entry.browser.contexts()[0];
        if (context) {
          const page = context.pages()[0];
          const video = page && page.video();
          await context.close();

          if (video) {
            try {
              videoPath = await video.path();
            } catch {
              videoPath = null;
            }
          }
        }

        const recordingId = entry.recording.recordingId;
        entry.recording = null;
        // Force the next command to build a fresh, non-recording context.
        entry.headerKey = null;
        entry.headerOriginKey = null;

        return ok({ recording_id: recordingId, video_path: videoPath });
      } finally {
        releaseBrowser(entry);
      }
    }

    default:
      return fail("not_allowed");
  }
}

async function waitForNetworkIdle(page) {
  try {
    await page.waitForLoadState("networkidle", { timeout: 5_000 });
    return true;
  } catch {
    // Live apps can keep sockets or polling open. Return the best current DOM.
    return false;
  }
}

// Resolve a CSS selector to a single locator without Playwright strict mode.
// The responsive cockpit renders many controls multiple times (hidden duplicates
// across breakpoints), so a bare selector routinely matches >1 element and the
// strict page.click/page.fill APIs would throw. We instead target an explicit
// 0-based `nth` when given, otherwise the first VISIBLE match (hidden duplicates
// are common), falling back to the first DOM match when nothing reports visible.
async function resolveLocator(page, selector, nth) {
  if (!selector) throw new Error("invalid_target");

  const loc = page.locator(selector);

  if (Number.isInteger(nth)) {
    return loc.nth(nth);
  }

  let count;
  try {
    count = await loc.count();
  } catch {
    count = 0;
  }

  if (count === 0) throw new Error(`no_match:${selector}`);

  for (let i = 0; i < count; i++) {
    const candidate = loc.nth(i);
    try {
      if (await candidate.isVisible()) return candidate;
    } catch {
      // Element detached/unstable between count and check; keep scanning.
    }
  }

  // No match reported visible — fall back to the first DOM match so the action
  // still proceeds (and surfaces a real timeout if it truly cannot interact).
  return loc.first();
}

// Chromium's setuid sandbox can't initialize when running as root or inside a
// container without user namespaces (the devbox case, DEV_IDE_ON_DEVBOX=true),
// where launch otherwise hangs. --no-sandbox is safe here: the helper only ever
// loads workspace-trusted, origin-gated URLs validated upstream by PreviewControl.
// --disable-gpu avoids a headless GPU/SwiftShader init hang on the devbox when
// rasterizing for screenshots; --no-sandbox/--disable-dev-shm-usage are the
// standard container/root flags.
const LAUNCH_ARGS = ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"];

async function pageFor(id, url, headers = {}, storageStatePath = null) {
  let entry = browsers.get(id);
  if (!entry) {
    entry = {
      browser: await chromium.launch({ headless: true, args: LAUNCH_ARGS }),
      headerKey: headersKey(headers),
      storageStatePath,
      createdAt: Date.now(),
      lastUsedAt: Date.now(),
      active: 0,
      consoleErrors: [],
      networkErrors: [],
    };
    browsers.set(id, entry);
  }

  entry.active += 1;
  entry.lastUsedAt = Date.now();
  entry.currentUrl = url;

  try {
    const context = await contextFor(entry, headers, storageStatePath);
    const page = context.pages()[0] || (await context.newPage());
    attachPageDiagnostics(page, entry);

    if (url && page.url() !== url) {
      await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15_000 });
    }

    return { entry, browser: entry.browser, page };
  } catch (error) {
    releaseBrowser(entry);
    throw error;
  }
}

async function contextFor(entry, headers, storageStatePath) {
  const key = headersKey(headers);
  const originKey = scopedHeaderOriginKey(entry.currentUrl);
  const existing = entry.browser.contexts()[0];

  if (!existing) {
    entry.headerKey = key;
    entry.headerOriginKey = originKey;
    entry.storageStatePath = storageStatePath;
    const context = await entry.browser.newContext(await contextOptions(storageStatePath));
    await installScopedHeaders(context, headers, entry.currentUrl);
    return context;
  }

  if (entry.headerKey !== key || entry.headerOriginKey !== originKey) {
    await existing.close();
    entry.headerKey = key;
    entry.headerOriginKey = originKey;
    entry.storageStatePath = storageStatePath;
    const context = await entry.browser.newContext(await contextOptions(storageStatePath));
    await installScopedHeaders(context, headers, entry.currentUrl);
    return context;
  }

  return existing;
}

async function contextOptions(storageStatePath) {
  const options = { deviceScaleFactor: 1 };

  // DPR invariant: keep deviceScaleFactor at Playwright's default (1). Screenshot
  // pixels and diff region coordinates are device pixels; DOM element bounds from
  // getBoundingClientRect() are CSS pixels. They align only when DPR is 1.
  if (storageStatePath && (await fileExists(storageStatePath))) {
    options.storageState = storageStatePath;
  }

  return options;
}

async function installScopedHeaders(context, headers, url) {
  const headerEntries = Object.entries(headers || {});
  if (headerEntries.length === 0) return;

  const origin = scopedHeaderOrigin(url);
  if (!origin) return;

  await context.route("**/*", async (route) => {
    const request = route.request();
    const requestUrl = new URL(request.url());

    if (requestUrl.origin !== origin) {
      await route.continue();
      return;
    }

    await route.continue({
      headers: {
        ...request.headers(),
        ...headers,
      },
    });
  });
}

function scopedHeaderOriginKey(url) {
  return scopedHeaderOrigin(url) || "";
}

function scopedHeaderOrigin(url) {
  if (!url) return null;

  try {
    const parsed = new URL(url);

    // Direct app previews on arbitrary localhost ports must not receive DevIDE
    // auth headers; those headers leak into third-party sub-resource requests
    // and trigger CORS preflights. DevIDE/proxy pages still need the headers.
    if (isLoopbackHost(parsed.hostname) && !isDevideLoopbackPort(parsed.port)) {
      return null;
    }

    return parsed.origin;
  } catch {
    return null;
  }
}

function isLoopbackHost(hostname) {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}

function isDevideLoopbackPort(port) {
  return port === "" || port === "4000";
}

async function persistStorageState(entry) {
  if (!entry.storageStatePath) return;

  const context = entry.browser.contexts()[0];
  if (!context) return;

  await fs.mkdir(dirname(entry.storageStatePath), { recursive: true });
  await context.storageState({ path: entry.storageStatePath });
}

async function fileExists(path) {
  try {
    const stat = await fs.stat(path);
    return stat.isFile();
  } catch {
    return false;
  }
}

function dirname(path) {
  const index = path.lastIndexOf("/");
  return index > 0 ? path.slice(0, index) : ".";
}

function sanitizeStorageStatePath(path) {
  if (typeof path !== "string" || path.length === 0) return null;
  if (path.includes("\0")) return null;
  return path;
}

function sanitizeHeaders(headers) {
  if (!headers || typeof headers !== "object" || Array.isArray(headers)) return {};

  return Object.fromEntries(
    Object.entries(headers)
      .filter(([key, value]) => {
        return (
          typeof key === "string" &&
          key.length > 0 &&
          !/[\r\n:]/.test(key) &&
          typeof value === "string" &&
          !/[\r\n]/.test(value)
        );
      })
      .slice(0, 20)
  );
}

function headersKey(headers) {
  return JSON.stringify(Object.entries(headers).sort(([a], [b]) => a.localeCompare(b)));
}

function attachPageDiagnostics(page, entry) {
  if (instrumentedPages.has(page)) return;
  instrumentedPages.add(page);

  page.on("console", (message) => {
    if (message.type() !== "error") return;

    appendDiagnostic(entry.consoleErrors, {
      type: "console",
      level: message.type(),
      text: truncateText(message.text()),
      location: message.location(),
    });
  });

  page.on("pageerror", (error) => {
    appendDiagnostic(entry.consoleErrors, {
      type: "pageerror",
      name: error.name,
      message: truncateText(error.message),
      stack: truncateText(error.stack),
    });
  });

  page.on("response", (response) => {
    if (response.ok()) return;

    appendDiagnostic(entry.networkErrors, {
      type: "response",
      url: response.url(),
      method: response.request().method(),
      status: response.status(),
      status_text: response.statusText(),
    });
  });

  page.on("requestfailed", (request) => {
    appendDiagnostic(entry.networkErrors, {
      type: "requestfailed",
      url: request.url(),
      method: request.method(),
      error_text: request.failure()?.errorText || "request_failed",
    });
  });
}

async function pageObservation(page, entry) {
  const summary = await summarizePage(page);
  const diagnostics = flushDiagnostics(entry);

  return {
    url: page.url(),
    title: summary.title,
    dom_summary: summary,
    console_errors: diagnostics.console_errors,
    network_errors: diagnostics.network_errors,
  };
}

async function storageSnapshot(page) {
  return await page.evaluate(() => {
    const snapshot = (storage) => {
      try {
        return Object.fromEntries(
          Array.from({ length: storage.length }, (_value, index) => {
            const key = storage.key(index);
            return [key, storage.getItem(key)];
          }).filter(([key]) => key != null)
        );
      } catch (error) {
        return { __error: error?.message || "storage_unavailable" };
      }
    };

    return {
      local_storage: snapshot(window.localStorage),
      session_storage: snapshot(window.sessionStorage),
    };
  });
}

async function summarizePage(page) {
  const html = await page.content();
  const htmlSummary = summarizeHtml(html, page.url());

  try {
    const liveSummary = await page.evaluate(() => {
      const normalizedText = (value) => (value || "").replace(/\s+/g, " ").trim();
      const isVisible = (element) => {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return (
          style.visibility !== "hidden" &&
          style.display !== "none" &&
          rect.width > 0 &&
          rect.height > 0
        );
      };

      const headings = Array.from(document.querySelectorAll("h1, h2, h3"))
        .filter(isVisible)
        .map((element) => normalizedText(element.innerText || element.textContent))
        .filter(Boolean)
        .slice(0, 6);

      const links = Array.from(document.querySelectorAll("a[href]"))
        .filter(isVisible)
        .map((element) => ({
          href: element.getAttribute("href"),
          text: normalizedText(element.innerText || element.textContent),
        }))
        .filter((link) => link.href || link.text)
        .slice(0, 12);

      const attrValue = (value) => String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
      const selectorFor = (element) => {
        if (element.id) return `#${CSS.escape(element.id)}`;
        const testId = element.getAttribute("data-testid");
        if (testId) return `[data-testid="${attrValue(testId)}"]`;
        const aria = element.getAttribute("aria-label");
        if (aria) return `${element.tagName.toLowerCase()}[aria-label="${attrValue(aria)}"]`;
        const href = element.getAttribute("href");
        if (href && element.tagName.toLowerCase() === "a") return `a[href="${attrValue(href)}"]`;
        const name = element.getAttribute("name");
        if (name) return `${element.tagName.toLowerCase()}[name="${attrValue(name)}"]`;
        const type = element.getAttribute("type");
        if (type) return `${element.tagName.toLowerCase()}[type="${attrValue(type)}"]`;
        return element.tagName.toLowerCase();
      };

      const roleFor = (element) => {
        const explicit = element.getAttribute("role");
        if (explicit) return explicit;
        const tag = element.tagName.toLowerCase();
        if (tag === "a") return "link";
        if (tag === "button") return "button";
        if (["input", "textarea", "select"].includes(tag)) return "textbox";
        return tag;
      };

      const elements = Array.from(
        document.querySelectorAll(
          'a[href], button, input, textarea, select, [role="button"], [role="link"], [data-testid]'
        )
      )
        .filter(isVisible)
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            role: roleFor(element),
            name:
              normalizedText(element.getAttribute("aria-label")) ||
              normalizedText(element.innerText || element.textContent) ||
              normalizedText(element.getAttribute("placeholder")) ||
              normalizedText(element.getAttribute("name")) ||
              normalizedText(element.getAttribute("value")),
            selector: selectorFor(element),
            tag: element.tagName.toLowerCase(),
            href: element.getAttribute("href"),
            type: element.getAttribute("type"),
            visible: true,
            bounds: {
              x: Math.round(rect.x),
              y: Math.round(rect.y),
              width: Math.round(rect.width),
              height: Math.round(rect.height),
            },
          };
        })
        .filter((element) => element.selector);

      const elements_truncated = elements.length > 40;

      return {
        headings,
        links,
        elements: elements.slice(0, 40),
        elements_truncated,
        visible_text: normalizedText(document.body?.innerText || "").slice(0, 2000),
      };
    });

    return { ...htmlSummary, ...liveSummary };
  } catch {
    return htmlSummary;
  }
}

function summarizeHtml(html, url) {
  return {
    title: titleFromHtml(html),
    headings: headingsFromHtml(html),
    links: linksFromHtml(html),
    elements: [],
    visible_text: visibleTextFromHtml(html),
    byte_size: Buffer.byteLength(html || "", "utf8"),
    url,
  };
}

function titleFromHtml(html) {
  const match = /<title[^>]*>(.*?)<\/title>/is.exec(html || "");
  return match ? stripTags(match[1]) : null;
}

function headingsFromHtml(html) {
  return Array.from((html || "").matchAll(/<h[1-3][^>]*>(.*?)<\/h[1-3]>/gis))
    .map((match) => stripTags(match[1]))
    .filter(Boolean)
    .slice(0, 6);
}

function linksFromHtml(html) {
  return Array.from((html || "").matchAll(/<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)<\/a>/gis))
    .map((match) => ({ href: match[1], text: stripTags(match[2]) }))
    .filter((link) => link.href || link.text)
    .slice(0, 12);
}

function visibleTextFromHtml(html) {
  return stripTags(
    (html || "")
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
  )
    .replace(/\s+/g, " ")
    .slice(0, 2000);
}

function stripTags(text) {
  return (text || "")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

function appendDiagnostic(list, item) {
  list.push({ ...item, at: new Date().toISOString() });

  if (list.length > 50) {
    list.splice(0, list.length - 50);
  }
}

function flushDiagnostics(entry) {
  const consoleErrors = entry.consoleErrors.splice(0);
  const networkErrors = entry.networkErrors.splice(0);

  return {
    console_errors: consoleErrors,
    network_errors: networkErrors,
  };
}

function truncateText(value) {
  const text = String(value || "");
  return text.length > 2000 ? `${text.slice(0, 2000)}…` : text;
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
