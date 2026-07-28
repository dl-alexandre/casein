#!/usr/bin/env node
// Batch 4: API-request, download, and cleanup evidence.
//
// api       — the XHR/fetch traffic a page actually issued: sanitized URL,
//             method, status, timing. This is what turns "the page looked fine"
//             into "the page's data calls all returned 200 in budget".
// downloads — files the page handed to the browser (exports, reports). Only
//             metadata is recorded, never file contents: a walk report is
//             shareable and an exported CSV is exactly the kind of thing that
//             contains real records.
// cleanup   — proof that a gated mutation put the world back: the page's
//             cleanup_steps ran and passed. Recorded even when the page itself
//             failed, because a failed page that also leaked fixtures is two
//             defects, not one.
//
// SECRET HYGIENE: every URL is sanitized — query, fragment and userinfo are
// DROPPED (they carry tokens and session ids). Request/response bodies are
// never captured.

import { redactPagePath } from "./visual_baseline.mjs";

export const API_EVIDENCE_VERSION = "api-evidence@1";

/** Origin + path only. Same funnel the visual collector uses. */
export function sanitizeUrl(url) {
  return redactPagePath(url);
}

const API_RESOURCE_TYPES = new Set(["xhr", "fetch"]);

/**
 * Capture XHR/fetch responses for one page visit. `stop()` returns evidence,
 * or null when the page issued no API traffic — "no calls" and "not measured"
 * must stay distinguishable, so callers that *require* api evidence treat null
 * as missing (BLOCKED), never as a quiet pass.
 */
export function attachApi(page, { maxEntries = 200 } = {}) {
  const entries = [];
  let dropped = 0;
  const onResponse = (response) => {
    let request = null;
    try {
      request = response.request();
      if (!API_RESOURCE_TYPES.has(request.resourceType())) return;
    } catch {
      return; /* request already torn down */
    }
    if (entries.length >= maxEntries) {
      dropped += 1;
      return;
    }
    let ms = null;
    try {
      const t = request.timing();
      if (t && Number.isFinite(t.responseEnd) && t.responseEnd >= 0) ms = Number(t.responseEnd.toFixed(1));
    } catch {
      ms = null;
    }
    entries.push({
      url: sanitizeUrl(response.url()),
      method: request.method(),
      status: response.status(),
      ms,
    });
  };
  page.on("response", onResponse);
  return {
    stop() {
      page.off("response", onResponse);
      if (entries.length === 0) return null;
      return {
        collectorVersion: API_EVIDENCE_VERSION,
        entryCount: entries.length,
        truncated: dropped > 0,
        dropped,
        failedCount: entries.filter((e) => e.status >= 400).length,
        entries,
      };
    },
  };
}

/**
 * Capture downloads for one page visit. Metadata only — the browser may write
 * the file to a temp path, but the report records name + sanitized source URL,
 * never contents. Requires the context to be created with acceptDownloads.
 */
export function attachDownloads(page, { maxEntries = 20 } = {}) {
  const entries = [];
  const onDownload = (download) => {
    if (entries.length >= maxEntries) return;
    let url = null;
    let name = null;
    try {
      url = sanitizeUrl(download.url());
    } catch {
      url = null;
    }
    try {
      name = download.suggestedFilename();
    } catch {
      name = null;
    }
    entries.push({ filename: name, url });
  };
  page.on("download", onDownload);
  return {
    stop() {
      page.off("download", onDownload);
      if (entries.length === 0) return null;
      return {
        collectorVersion: API_EVIDENCE_VERSION,
        entryCount: entries.length,
        entries,
      };
    },
  };
}

/**
 * Fold a cleanup runPageSteps result into evidence. Null when nothing ran
 * (no cleanup declared, or the interactions gate blocked it) — required
 * cleanup evidence then fails closed instead of pretending the fixtures are
 * gone.
 */
export function cleanupEvidence(stepResult) {
  if (!stepResult) return null;
  const steps = stepResult.steps || [];
  const ran = stepResult.ran || 0;
  if (ran === 0 && !stepResult.failed) return null;
  return {
    collectorVersion: API_EVIDENCE_VERSION,
    ran,
    failed: stepResult.failed || 0,
    passed: (stepResult.failed || 0) === 0 && ran > 0,
    steps: steps.map((s) => ({ name: s.name || s.action || "?", action: s.action || "?", status: s.status })),
  };
}
