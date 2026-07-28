#!/usr/bin/env node
// First real collector batch for preview-ui-walk: HAR, DOM snapshot, Server-Timing.
//
// These are the three that are self-contained (no product mutation, no extra
// service) and therefore provable by preflight: `probeCollectors` runs each one
// against a scratch page and reports whether it ACTUALLY produced evidence —
// so a readiness matrix asserts capability, not schema declarations.
//
// Every collector obeys the same contract:
//   * returns evidence, or null when it genuinely collected nothing
//   * NEVER throws into the walk — a collector defect must not fail a page that
//     otherwise passed; the fail-closed decision belongs to evidenceGuard,
//     which turns "required but null" into BLOCKED
//   * performs no product mutation

/**
 * HAR — request/response timing + status for the page load.
 *
 * Playwright's own `recordHar` writes at context close, which is too late for
 * per-page evidence, so we accumulate from response events instead. Bodies are
 * deliberately NOT captured: a walk report is shareable, and response bodies
 * routinely contain PII and session material.
 */
export function attachHar(page, { maxEntries = 500 } = {}) {
  const entries = [];
  const startedAt = Date.now();
  const onResponse = async (response) => {
    if (entries.length >= maxEntries) return;
    const request = response.request();
    let timing = null;
    try {
      timing = request.timing();
    } catch {
      /* request may already be gone */
    }
    entries.push({
      url: response.url(),
      method: request.method(),
      status: response.status(),
      resourceType: request.resourceType(),
      fromCache: response.fromServiceWorker?.() || false,
      timing: timing
        ? {
            startTime: timing.startTime,
            responseStart: timing.responseStart,
            responseEnd: timing.responseEnd,
          }
        : null,
    });
  };
  page.on("response", onResponse);
  return {
    stop() {
      page.off("response", onResponse);
      if (entries.length === 0) return null;
      return {
        version: "1.2-lite",
        capturedAt: new Date(startedAt).toISOString(),
        entryCount: entries.length,
        truncated: entries.length >= maxEntries,
        entries,
      };
    },
  };
}

/**
 * Server-Timing — the server's own view of where request time went.
 *
 * Parsed from the main document response header. Absent header => null (the
 * app does not emit it), which is honest "no evidence" rather than an empty
 * object that would read as "collected, nothing interesting".
 */
export function parseServerTiming(headerValue) {
  if (!headerValue || typeof headerValue !== "string") return null;
  const metrics = [];
  for (const part of headerValue.split(",")) {
    const segments = part.split(";").map((s) => s.trim()).filter(Boolean);
    if (segments.length === 0) continue;
    const name = segments[0];
    if (!name) continue;
    const metric = { name };
    for (const seg of segments.slice(1)) {
      const eq = seg.indexOf("=");
      if (eq === -1) continue;
      const key = seg.slice(0, eq).trim();
      const raw = seg.slice(eq + 1).trim().replace(/^"|"$/g, "");
      if (key === "dur") {
        const dur = Number(raw);
        if (Number.isFinite(dur)) metric.dur = dur;
      } else if (key === "desc") {
        metric.desc = raw;
      }
    }
    metrics.push(metric);
  }
  return metrics.length ? { metrics } : null;
}

export async function collectServerTiming(response) {
  if (!response) return null;
  let headers = {};
  try {
    headers = await response.allHeaders();
  } catch {
    return null;
  }
  const value = headers["server-timing"] || headers["Server-Timing"];
  return parseServerTiming(value);
}

/**
 * DOM snapshot — trimmed serialized DOM for post-hoc inspection.
 *
 * Trimmed on purpose: full outerHTML on a LiveView page is megabytes and drags
 * secrets (CSRF tokens, session-bearing hrefs) into a shareable artifact. We
 * keep structure and visible text, and strip attribute values that commonly
 * carry credentials.
 */
export const SENSITIVE_ATTR_RE = /^(value|content|data-csrf|csrf-token|token|authorization)$/i;

export function sanitizeDomHtml(html) {
  if (typeof html !== "string") return null;
  return html
    .replace(/<input([^>]*?)\svalue="[^"]*"/gi, "<input$1 value=\"[redacted]\"")
    .replace(/(name="_csrf_token"[^>]*?value=")[^"]*(")/gi, "$1[redacted]$2")
    .replace(/(<meta[^>]*name="csrf-token"[^>]*content=")[^"]*(")/gi, "$1[redacted]$2");
}

export async function collectDomSnapshot(page, { maxBytes = 512 * 1024 } = {}) {
  let html = null;
  try {
    html = await page.content();
  } catch {
    return null;
  }
  if (!html) return null;
  const sanitized = sanitizeDomHtml(html);
  const truncated = sanitized.length > maxBytes;
  return {
    capturedAt: new Date().toISOString(),
    bytes: sanitized.length,
    truncated,
    html: truncated ? sanitized.slice(0, maxBytes) : sanitized,
  };
}

/**
 * Prove the collectors actually collect, against a scratch page — this is what
 * lets preflight report capability instead of intent. No product URL is
 * touched: the page is fed inline content plus one same-document request.
 */
/**
 * Minimal Phoenix-protocol WS fixture. Speaks enough of the LiveView wire format
 * ([join_ref, ref, topic, event, payload]) to exercise join success and a
 * server-forced disconnect, so reconnect + recovery latency are proved rather
 * than assumed. Returns { url, close }.
 */
export async function startScratchOrigin() {
  const http = await import("node:http");
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<h1>preflight scratch</h1>");
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const { port } = server.address();
  return { url: `http://127.0.0.1:${port}/`, close: () => server.close() };
}

export async function startScratchLiveSocket({ dropFirstJoin = true } = {}) {
  const { resolveWs } = await import("./resolve_dep.mjs");
  const WebSocketServer = resolveWs()?.WebSocketServer || null;
  if (!WebSocketServer) return null; // ws unavailable -> caller reports MISSING
  let joins = 0;
  const wss = new WebSocketServer({ port: 0 });
  wss.on("connection", (socket) => {
    socket.on("message", (raw) => {
      let msg = null;
      try {
        msg = JSON.parse(String(raw));
      } catch {
        return;
      }
      const [joinRef, ref, topic, event] = msg;
      if (event !== "phx_join") return;
      joins += 1;
      // First join is accepted then dropped, forcing the client to reconnect;
      // the second join is accepted and stays up, so recovery is observable.
      socket.send(JSON.stringify([joinRef, ref, topic, "phx_reply", { status: "ok", response: {} }]));
      // terminate(), not close(1006): 1006 is a RESERVED code the ws library
      // refuses to send, and an abrupt termination is a truer simulation of the
      // network drop a LiveView reconnect actually has to survive.
      if (dropFirstJoin && joins === 1) setTimeout(() => socket.terminate(), 60);
    });
  });
  await new Promise((r) => wss.on("listening", r));
  const { port } = wss.address();
  return { url: `ws://127.0.0.1:${port}/live/websocket`, close: () => wss.close() };
}

export async function probeCollectors(browserFactory) {
  const result = { har: null, dom: null, server_timing: null, ws: null, a11y: null, viewport: null, resource_metrics: null, visual_baseline: null, api: null, downloads: null, preview_cookie: null, errors: [] };
  let browser = null;
  try {
    browser = await browserFactory();
    const page = await browser.newPage();
    // Serve a scratch document that emits Server-Timing so the parser is
    // exercised end-to-end rather than unit-only.
    await page.route("**/preflight-scratch", (route) =>
      route.fulfill({
        status: 200,
        headers: { "content-type": "text/html", "server-timing": "app;dur=12.3;desc=\"render\"" },
        body: "<html><body><h1>preflight</h1><input name=\"secret\" value=\"hunter2\"></body></html>",
      }),
    );
    const har = attachHar(page);
    const response = await page.goto("http://preflight.invalid/preflight-scratch");
    result.server_timing = await collectServerTiming(response);
    result.dom = await collectDomSnapshot(page);
    result.har = har.stop();

    // WebSocket / LiveView reconnect proof, still scratch-only: the page drives
    // a local socket, never a product URL, so preflight keeps its
    // no-navigation-to-product guarantee.
    try {
      const { attachWs } = await import("./ws_collector.mjs");
      // a11y + viewport proof: audit a fixture with one planted violation per
      // rule, across two viewports, so preflight reports proven capability.
      try {
        const a11y = await import("./a11y_collector.mjs");
        const { viewports } = a11y.normalizeViewports(a11y.DEFAULT_VIEWPORTS);
        await page.setContent(
          "<html><body><main><h1>a</h1><h3>b</h3><img src='data:image/gif;base64,R0lGODlhAQABAAAAACw=' width=20 height=20></main></body></html>",
        );
        result.a11y = await a11y.collectAcrossViewports(page, viewports);
        result.viewport = result.a11y ? { proven: true, count: viewports.length } : null;
      } catch (err) {
        result.errors.push(`a11y: ${String(err?.message || err)}`);
      }

      // Resource metrics proof: measure a page that does real DOM work so the
      // delta is non-trivial and the collector is proven, not merely present.
      try {
        const rm = await import("./resource_metrics.mjs");
        const { session, before } = await rm.beginResourceMetrics(page);
        await page.setContent(
          "<html><body><div id=a></div><script>for(let i=0;i<500;i++){const d=document.createElement('div');d.textContent=i;document.getElementById('a').appendChild(d)}</script></body></html>",
        );
        result.resource_metrics = await rm.collectResourceMetrics(page, { session, before });
      } catch (err) {
        result.errors.push(`resource_metrics: ${String(err?.message || err)}`);
      }

      // Visual-baseline proof against REAL Chromium pixels, still scratch-only:
      // two captures of the same fixture must compare identical, and a visible
      // mutation must exceed the 0.1% gate — proving screenshot bytes, decoder
      // and diff engine end-to-end without any product page or stored baseline.
      try {
        const vb = await import("./visual_baseline.mjs");
        const engineProof = vb.proveDiffEngine();
        if (!engineProof.observable) {
          result.errors.push(`visual_baseline: ${engineProof.reason}`);
        } else {
          await page.setContent(
            "<html><body style='margin:0;background:#123456'><div style='width:200px;height:200px;background:#abcdef'>stable</div></body></html>",
          );
          const first = await page.screenshot({ type: "png" });
          const second = await page.screenshot({ type: "png" });
          const identical = vb.comparePng(second, first);
          await page.setContent(
            "<html><body style='margin:0;background:#123456'><div style='width:200px;height:200px;background:#ff0000'>changed</div></body></html>",
          );
          const mutated = await page.screenshot({ type: "png" });
          const changed = vb.comparePng(mutated, first);
          const proven =
            identical.comparable === true &&
            identical.pass === true &&
            changed.comparable === true &&
            changed.pass === false;
          result.visual_baseline = {
            observable: proven,
            identicalChangedPixels: identical.changedPixels ?? null,
            mutationChangedRatio: changed.changedRatio ?? null,
          };
        }
      } catch (err) {
        result.errors.push(`visual_baseline: ${String(err?.message || err)}`);
      }

      // API + download proof, scratch-only: one fetch against a fulfilled
      // route, one data-URL download — no product traffic.
      try {
        const api = await import("./api_evidence.mjs");
        await page.route("**/preflight-api*", (route) =>
          route.fulfill({ status: 200, headers: { "content-type": "application/json" }, body: "{\"ok\":true}" }),
        );
        const apiTap = api.attachApi(page);
        const dlTap = api.attachDownloads(page);
        // setContent leaves the page on about:blank, where a RELATIVE fetch
        // has no base URL — the probe must fetch an absolute routed URL.
        await page.goto("http://preflight.invalid/preflight-scratch");
        await page.evaluate(() =>
          fetch("http://preflight.invalid/preflight-api?token=SECRET").then((r) => r.json()),
        );
        const dlWait = page.waitForEvent("download", { timeout: 3000 }).catch(() => null);
        await page.evaluate(() => {
          const a = document.createElement("a");
          a.href = "data:text/plain,preflight";
          a.download = "preflight-probe.txt";
          document.body.appendChild(a);
          a.click();
        });
        await dlWait;
        const apiEv = apiTap.stop();
        const dlEv = dlTap.stop();
        const apiClean =
          Boolean(apiEv) && apiEv.entries.every((e) => !String(e.url).includes("SECRET") && !String(e.url).includes("?"));
        result.api = { observable: Boolean(apiEv) && apiClean, entryCount: apiEv?.entryCount ?? 0 };
        result.downloads = { observable: Boolean(dlEv), entryCount: dlEv?.entryCount ?? 0 };
      } catch (err) {
        result.errors.push(`api/downloads: ${String(err?.message || err)}`);
      }

      const sock = await startScratchLiveSocket();
      const origin = await startScratchOrigin();

      // Preview cookie/storage proof: inject a cookie into the browser
      // context, navigate the SCRATCH origin, and read both the cookie and a
      // localStorage round-trip back. Proves the session-injection mechanics
      // the cookie-login path depends on — without any product page.
      try {
        if (origin) {
          const ctx = page.context();
          await ctx.addCookies([
            { name: "preflight_probe", value: "1", url: origin.url },
          ]);
          await page.goto(origin.url);
          const cookies = await ctx.cookies(origin.url);
          const cookieBack = cookies.some((c) => c.name === "preflight_probe" && c.value === "1");
          const storageBack = await page.evaluate(() => {
            try {
              localStorage.setItem("preflight_probe", "1");
              return localStorage.getItem("preflight_probe") === "1";
            } catch {
              return false;
            }
          });
          result.preview_cookie = { observable: cookieBack && storageBack, cookie: cookieBack, storage: storageBack };
        }
      } catch (err) {
        result.errors.push(`preview_cookie: ${String(err?.message || err)}`);
      }

      if (sock && origin) {
        // A WebSocket needs a real page origin; a fulfilled fake origin cannot
        // complete the upgrade, which yields zero frames and looks like missing
        // driver support.
        await page.goto(origin.url);
        const { attachWsBest } = await import("./ws_collector.mjs");
        const ws = await attachWsBest(page);
        await page.evaluate(async (url) => {
          // Connect, join, expect a server-forced close, then reconnect+rejoin.
          const connect = () =>
            new Promise((resolve) => {
              const s = new WebSocket(url);
              s.onopen = () => s.send(JSON.stringify(["1", "1", "lv:scratch", "phx_join", {}]));
              s.onclose = () => resolve("closed");
              setTimeout(() => resolve("open"), 400);
            });
          await connect();
          await connect();
        }, sock.url);
        await new Promise((r) => setTimeout(r, 400));
        result.ws = await ws.stop();
        result.ws_transport = ws.transport;
      }
      if (origin) origin.close();
      if (sock) sock.close();
    } catch (err) {
      result.errors.push(`ws: ${String(err?.message || err)}`);
    }

    await browser.close();
    browser = null;
  } catch (err) {
    result.errors.push(String(err?.message || err));
  } finally {
    if (browser) {
      try {
        await browser.close();
      } catch {
        /* ignore */
      }
    }
  }
  return result;
}
