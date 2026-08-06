#!/usr/bin/env node
// Batch 3a: browser + server resource metrics.
//
// Browser side comes from CDP Performance.getMetrics (JS heap, DOM nodes,
// layout/style recalc counts, task duration) plus PerformanceNavigationTiming
// from the page. Server side is whatever the app already reports — Server-Timing
// (batch 1) and Tidewave probes — correlated by the same page identity, so a
// slow page can be attributed to the browser or the server instead of guessed.
//
// Deltas, not absolutes. A walk visits many pages in one browser, so raw heap
// or node counts are cumulative and near-meaningless per page. We snapshot
// before and after each page and report the DELTA, which is what actually
// attributes a leak or a layout storm to the page that caused it. Absolute
// values are kept alongside for context.
//
// No payloads, no page content: counters only.

/** CDP metric names we care about, mapped to stable report keys. */
export const METRIC_KEYS = {
  JSHeapUsedSize: "jsHeapUsedBytes",
  JSHeapTotalSize: "jsHeapTotalBytes",
  Nodes: "domNodes",
  JSEventListeners: "jsEventListeners",
  Documents: "documents",
  Frames: "frames",
  LayoutCount: "layoutCount",
  RecalcStyleCount: "recalcStyleCount",
  LayoutDuration: "layoutDurationSec",
  RecalcStyleDuration: "recalcStyleDurationSec",
  ScriptDuration: "scriptDurationSec",
  TaskDuration: "taskDurationSec",
};

/** Flatten CDP's [{name,value}] into our stable keys; unknown metrics dropped. */
export function normalizeCdpMetrics(metrics) {
  if (!Array.isArray(metrics)) return null;
  const out = {};
  for (const m of metrics) {
    const key = METRIC_KEYS[m?.name];
    if (key && Number.isFinite(m.value)) out[key] = m.value;
  }
  return Object.keys(out).length ? out : null;
}

/**
 * Delta between two snapshots. Keys present in `after` but not `before` are
 * reported as-is (first observation); keys missing from `after` are dropped —
 * we never invent a zero, because "not measured" and "measured zero" are
 * different claims.
 */
export function deltaMetrics(before, after) {
  if (!after) return null;
  if (!before) return { ...after };
  const out = {};
  for (const [k, v] of Object.entries(after)) {
    out[k] = Number.isFinite(before[k]) ? Number((v - before[k]).toFixed(6)) : v;
  }
  return out;
}

/** Navigation timing from the page (real user-facing phase durations). */
export const NAV_TIMING_FN = function navTiming() {
  try {
    const [nav] = performance.getEntriesByType("navigation");
    if (!nav) return null;
    const r = (n) => (Number.isFinite(n) ? Number(n.toFixed(2)) : null);
    return {
      dnsMs: r(nav.domainLookupEnd - nav.domainLookupStart),
      connectMs: r(nav.connectEnd - nav.connectStart),
      ttfbMs: r(nav.responseStart - nav.requestStart),
      responseMs: r(nav.responseEnd - nav.responseStart),
      domContentLoadedMs: r(nav.domContentLoadedEventEnd - nav.startTime),
      loadMs: r(nav.loadEventEnd - nav.startTime),
      transferBytes: Number.isFinite(nav.transferSize) ? nav.transferSize : null,
      encodedBytes: Number.isFinite(nav.encodedBodySize) ? nav.encodedBodySize : null,
    };
  } catch {
    return null;
  }
};

export async function snapshotBrowserMetrics(session) {
  if (!session) return null;
  try {
    const { metrics } = await session.send("Performance.getMetrics");
    return normalizeCdpMetrics(metrics);
  } catch {
    return null;
  }
}

/**
 * Correlate server-side cost with the browser view. `serverTiming` comes from
 * the batch-1 collector; `tidewave` is an optional per-page probe result. The
 * point is attribution: ttfb high + server total high => server; ttfb low +
 * scriptDuration high => browser.
 */
export function correlate({ nav, browserDelta, serverTiming }) {
  const serverMs = Array.isArray(serverTiming?.metrics)
    ? serverTiming.metrics.reduce((n, m) => n + (Number.isFinite(m.dur) ? m.dur : 0), 0)
    : null;
  const ttfb = Number.isFinite(nav?.ttfbMs) ? nav.ttfbMs : null;
  const script = Number.isFinite(browserDelta?.scriptDurationSec)
    ? browserDelta.scriptDurationSec * 1000
    : null;
  let attribution = "unknown";
  if (serverMs != null && ttfb != null) {
    // Server-Timing accounts for most of TTFB => the server is the cost centre.
    attribution = serverMs >= ttfb * 0.5 ? "server" : script != null && script > ttfb ? "browser" : "network";
  } else if (script != null && ttfb != null) {
    attribution = script > ttfb ? "browser" : "network";
  }
  return { serverTotalMs: serverMs, ttfbMs: ttfb, scriptMs: script == null ? null : Number(script.toFixed(2)), attribution };
}

/**
 * Full page collection. `session` is a CDP session (Performance domain enabled
 * by the caller). Returns null when nothing at all could be measured — the
 * fail-closed signal, distinct from "measured and everything was zero".
 */
export async function collectResourceMetrics(page, { session, before, serverTiming } = {}) {
  const after = await snapshotBrowserMetrics(session);
  let nav = null;
  try {
    nav = await page.evaluate(NAV_TIMING_FN);
  } catch {
    nav = null;
  }
  if (!after && !nav) return null;
  const browserDelta = deltaMetrics(before, after);
  return {
    capturedAt: new Date().toISOString(),
    observable: Boolean(after || nav),
    browser: after || null,
    browserDelta: browserDelta || null,
    navigation: nav,
    correlation: correlate({ nav, browserDelta, serverTiming }),
  };
}

/** Enable the Performance domain and take the "before" snapshot. */
export async function beginResourceMetrics(page, { session } = {}) {
  const ctx = page?.context?.();
  const s = session || (ctx?.newCDPSession ? await ctx.newCDPSession(page) : null);
  if (!s) return { session: null, before: null };
  try {
    await s.send("Performance.enable");
  } catch {
    /* domain may already be enabled */
  }
  return { session: s, before: await snapshotBrowserMetrics(s) };
}
