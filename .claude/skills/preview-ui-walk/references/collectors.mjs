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
export async function probeCollectors(browserFactory) {
  const result = { har: null, dom: null, server_timing: null, errors: [] };
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
