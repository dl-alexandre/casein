#!/usr/bin/env node

import { createInterface } from "node:readline";
import { chromium } from "playwright";

const browsers = new Map();

process.on("SIGINT", () => shutdown(0));
process.on("SIGTERM", () => shutdown(0));

await main();

async function main() {
  const rl = createInterface({ input: process.stdin, terminal: false });

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    let request;

    try {
      request = JSON.parse(trimmed);
    } catch (error) {
      write({ ok: false, error: error.message || "invalid_json" });
      continue;
    }

    const { id, command, payload = {} } = request;

    try {
      const result = await handleCommand(command, payload);
      write({ id, ok: true, result });
    } catch (error) {
      write({ id, ok: false, error: error.message || "playwright_failed" });
    }
  }

  await closeAll();
}

async function handleCommand(command, payload) {
  switch (command) {
    case "open_browser":
      return await openBrowser(payload);
    case "navigate":
      return await navigate(payload);
    case "observe":
      return await observe(payload);
    case "cdp":
      return await cdp(payload);
    case "screenshot":
      return await screenshot(payload);
    case "close_browser":
      return await closeBrowser(payload);
    default:
      throw new Error("unknown_command");
  }
}

async function openBrowser(payload) {
  const browserId = payload.browser_id;
  const browserRef = `playwright-${browserId}`;
  const options = payload.options || {};
  const browser = await chromium.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  const context = await browser.newContext();
  const entry = {
    browserId,
    browser,
    context,
    page: null,
    cdpSession: null,
    health: newHealth(),
  };

  await context.exposeBinding("__devidePreviewSignal", (_source, message) => {
    handlePreviewSignal(entry, message);
  });

  await context.addInitScript(() => {
    window.addEventListener("devide:preview:signal", (event) => {
      if (typeof window.__devidePreviewSignal === "function") {
        window.__devidePreviewSignal(event.detail);
      }
    });
  });

  const page = await context.newPage();
  entry.page = page;

  page.on("console", (message) => {
    write({
      type: "event",
      browser_id: browserId,
      event: ["console", message.type(), message.text()],
    });
  });

  if (options.url && options.url !== "about:blank") {
    await page.goto(options.url, { waitUntil: "domcontentloaded", timeout: 15_000 });
  }

  browsers.set(browserRef, entry);
  return { browser_ref: browserRef };
}

async function navigate(payload) {
  const entry = entryFor(payload.browser_ref);
  transitionHealth(entry, "devide:preview:page_loading_start", {
    url: payload.url,
    timestamp: Date.now(),
  });
  emitHealth(entry);

  const response = await entry.page.goto(payload.url, {
    waitUntil: "domcontentloaded",
    timeout: 15_000,
  });
  transitionHealth(entry, "devide:preview:page_loading_stop", {
    url: entry.page.url(),
    timestamp: Date.now(),
  });

  return {
    url: entry.page.url(),
    title: await safeTitle(entry.page),
    status: response?.status() || 200,
    health: healthSnapshot(entry.health),
  };
}

async function observe(payload) {
  const entry = entryFor(payload.browser_ref);

  return {
    url: entry.page.url(),
    title: await safeTitle(entry.page),
    status: 200,
    health: healthSnapshot(entry.health),
  };
}

async function cdp(payload) {
  const entry = entryFor(payload.browser_ref);
  entry.cdpSession ||= await entry.context.newCDPSession(entry.page);
  return await entry.cdpSession.send(payload.method, payload.params || {});
}

async function screenshot(payload) {
  const entry = entryFor(payload.browser_ref);
  const options = payload.options || {};
  const type = options.format === "jpeg" ? "jpeg" : "png";
  const buffer = await entry.page.screenshot({ type });

  return {
    url: entry.page.url(),
    mime_type: `image/${type}`,
    data_base64: buffer.toString("base64"),
  };
}

async function closeBrowser(payload) {
  const entry = entryFor(payload.browser_ref);
  browsers.delete(payload.browser_ref);
  await entry.browser.close();
  return { closed: true };
}

function entryFor(browserRef) {
  const entry = browsers.get(browserRef);
  if (!entry) throw new Error("browser_not_found");
  return entry;
}

function handlePreviewSignal(entry, message) {
  if (!message || message.source !== "casein-preview" || typeof message.type !== "string") {
    return;
  }

  const payload = message.payload && typeof message.payload === "object" ? message.payload : {};
  transitionHealth(entry, message.type, payload);

  write({
    type: "event",
    browser_id: entry.browserId,
    event: ["preview_signal", message.type, payload, healthSnapshot(entry.health)],
  });
}

function emitHealth(entry) {
  write({
    type: "event",
    browser_id: entry.browserId,
    event: ["health", healthSnapshot(entry.health)],
  });
}

function newHealth() {
  return {
    state: "browser_started",
    bridge_ready: false,
    dom_loaded: false,
    live_socket_connected: null,
    last_event_type: null,
    last_event_at: null,
    client_errors: [],
  };
}

function transitionHealth(entry, type, payload = {}) {
  const health = entry.health;
  health.last_event_type = type;
  health.last_event_at = Number.isFinite(payload.timestamp) ? payload.timestamp : Date.now();

  if (type === "devide:preview:bridge_ready") {
    health.bridge_ready = true;
  } else if (type === "devide:preview:dom_loaded") {
    health.dom_loaded = true;
  } else if (type === "devide:preview:live_socket_connected") {
    health.live_socket_connected = true;
  } else if (type === "devide:preview:live_socket_disconnected") {
    health.live_socket_connected = false;
    health.state = "degraded";
    return;
  } else if (type === "devide:preview:page_loading_start") {
    health.state = "navigation_started";
    health.dom_loaded = false;
    health.live_socket_connected = null;
    return;
  } else if (type === "devide:preview:client_error") {
    health.state = "degraded";
    health.client_errors = [payload, ...health.client_errors].slice(0, 10);
    return;
  }

  deriveHealthState(health);
}

function deriveHealthState(health) {
  if (health.state === "crashed" || health.state === "degraded") return;

  if (health.dom_loaded && health.live_socket_connected === true) {
    health.state = "liveview_stable";
  } else if (health.live_socket_connected === true) {
    health.state = "live_socket_connected";
  } else if (health.dom_loaded) {
    health.state = "dom_loaded";
  }
}

function healthSnapshot(health) {
  return {
    state: health.state,
    bridge_ready: health.bridge_ready,
    dom_loaded: health.dom_loaded,
    live_socket_connected: health.live_socket_connected,
    last_event_type: health.last_event_type,
    last_event_at: health.last_event_at,
    client_errors: health.client_errors,
  };
}

async function safeTitle(page) {
  try {
    return await page.title();
  } catch {
    return "";
  }
}

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

async function closeAll() {
  const entries = [...browsers.values()];
  browsers.clear();
  await Promise.all(entries.map((entry) => entry.browser.close().catch(() => {})));
}

async function shutdown(code) {
  await closeAll();
  process.exit(code);
}
