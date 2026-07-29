#!/usr/bin/env node
// Batch 2: responsive named viewports + accessibility evidence.
//
// Deliberately NOT an axe-core wrapper. Vendoring axe would add a ~500 KB
// third-party bundle to a skill that must stay auditable, and its ruleset
// changes under you between versions — a walk that silently reports different
// violations after a dependency bump is worse than one that reports fewer,
// stable, explainable ones. Instead we assert a small set of structural rules
// that (a) map to real WCAG failures, (b) are computable from the DOM without a
// rules engine, and (c) do not produce false positives that erode trust.
//
// Rules implemented (each cites the WCAG SC it maps to):
//   img-alt          1.1.1  non-decorative <img> needs alt text
//   control-name     4.1.2  interactive controls need an accessible name
//   form-label       3.3.2  form inputs need a programmatic label
//   doc-lang         3.1.1  <html> needs a lang attribute
//   heading-order    1.3.1  heading levels must not skip
//   dup-main         1.3.1  at most one <main> landmark
//
// PRIVACY: violations record selector + role + a TRUNCATED accessible name.
// Names are user-visible UI text, but a name can echo user data (e.g. a row
// action labelled with a customer name), so it is capped, and no attribute
// values, form values or inner HTML are captured.

export const MAX_NAME = 60;
export const DEFAULT_VIEWPORTS = [
  { name: "mobile", width: 390, height: 844 },
  { name: "desktop", width: 1280, height: 720 },
];
export const DEFAULT_WALK_VIEWPORT = {
  name: "default",
  width: 1280,
  height: 900,
  deviceScaleFactor: 1,
  implicit: true,
};

/** Normalize a manifest viewport list; invalid entries are dropped loudly. */
export function normalizeViewports(list) {
  if (!Array.isArray(list) || list.length === 0) return { viewports: [], invalid: [] };
  const viewports = [];
  const invalid = [];
  for (const v of list) {
    const name = typeof v?.name === "string" ? v.name.trim() : "";
    const width = Number(v?.width);
    const height = Number(v?.height);
    if (!name || !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      invalid.push(v);
      continue;
    }
    viewports.push({
      name,
      width: Math.round(width),
      height: Math.round(height),
      // DPR stays 1 unless asked: screenshot pixels and DOM bounds only align
      // at DPR 1, and visual-baseline diffing depends on that alignment.
      deviceScaleFactor: Number.isFinite(Number(v?.device_scale_factor))
        ? Number(v.device_scale_factor)
        : 1,
    });
  }
  return { viewports, invalid };
}

/** Which declared viewports apply to a page (page list narrows the walk list). */
export function viewportsForPage(all, pageNames) {
  if (!Array.isArray(pageNames) || pageNames.length === 0) return all;
  const wanted = new Set(pageNames);
  return all.filter((v) => wanted.has(v.name));
}

/**
 * Expand logical manifest pages into the physical viewport visits the driver
 * must perform. An omitted viewport list retains the v1 single default visit.
 */
export function expandWalkCases(pages, declaredViewports) {
  const logicalPages = Array.isArray(pages) ? pages : [];
  const { viewports, invalid } = normalizeViewports(declaredViewports);
  if (invalid.length > 0) {
    return { cases: [], invalid, unknown: [] };
  }

  const activeViewports = viewports.length > 0 ? viewports : [DEFAULT_WALK_VIEWPORT];
  const knownNames = new Set(activeViewports.map((viewport) => viewport.name));
  const unknown = [];
  const cases = [];

  for (const page of logicalPages) {
    const requested = Array.isArray(page?.viewports) ? page.viewports : [];
    for (const name of requested) {
      if (!knownNames.has(name)) unknown.push({ page: page?.name || page?.path || "?", name });
    }
    for (const viewport of viewportsForPage(activeViewports, requested)) {
      cases.push({ page, viewport });
    }
  }

  return { cases, invalid, unknown };
}

/**
 * The in-page audit. Runs as a single evaluate so it costs one round trip per
 * viewport. Kept dependency-free and defensive: any rule that throws is skipped
 * rather than failing the page.
 */
export const AUDIT_FN = function auditA11y(maxName) {
  const trunc = (s) => (typeof s === "string" ? s.trim().slice(0, maxName) : "");
  const sel = (el) => {
    if (!el) return "";
    if (el.id) return `#${el.id}`;
    const cls = (el.className || "").toString().trim().split(/\s+/).filter(Boolean)[0];
    return cls ? `${el.tagName.toLowerCase()}.${cls}` : el.tagName.toLowerCase();
  };
  const name = (el) =>
    trunc(
      el.getAttribute?.("aria-label") ||
        (el.getAttribute?.("aria-labelledby") &&
          document.getElementById(el.getAttribute("aria-labelledby"))?.textContent) ||
        el.textContent ||
        el.getAttribute?.("title") ||
        "",
    );
  const visible = (el) => {
    const r = el.getBoundingClientRect?.();
    return !!r && r.width > 0 && r.height > 0;
  };
  const violations = [];
  const push = (rule, wcag, el, detail) =>
    violations.push({ rule, wcag, selector: sel(el), role: el?.getAttribute?.("role") || el?.tagName?.toLowerCase() || "", name: name(el), detail });

  try {
    if (!document.documentElement.getAttribute("lang")) {
      violations.push({ rule: "doc-lang", wcag: "3.1.1", selector: "html", role: "document", name: "", detail: "missing lang attribute" });
    }
  } catch (e) { /* skip rule */ }

  try {
    for (const img of document.querySelectorAll("img")) {
      if (!visible(img)) continue;
      const alt = img.getAttribute("alt");
      const decorative = alt === "" || img.getAttribute("aria-hidden") === "true" || img.getAttribute("role") === "presentation";
      if (alt === null && !decorative) push("img-alt", "1.1.1", img, "img has no alt attribute");
    }
  } catch (e) { /* skip rule */ }

  try {
    for (const el of document.querySelectorAll("button, a[href], [role=button], [role=link]")) {
      if (!visible(el)) continue;
      if (!name(el)) push("control-name", "4.1.2", el, "interactive control has no accessible name");
    }
  } catch (e) { /* skip rule */ }

  try {
    for (const el of document.querySelectorAll("input, select, textarea")) {
      if (!visible(el)) continue;
      const type = (el.getAttribute("type") || "").toLowerCase();
      if (type === "hidden" || type === "submit" || type === "button") continue;
      const labelled =
        el.getAttribute("aria-label") ||
        el.getAttribute("aria-labelledby") ||
        (el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`)) ||
        el.closest("label");
      if (!labelled) push("form-label", "3.3.2", el, "form control has no programmatic label");
    }
  } catch (e) { /* skip rule */ }

  try {
    const levels = [...document.querySelectorAll("h1,h2,h3,h4,h5,h6")]
      .filter(visible)
      .map((h) => ({ el: h, level: Number(h.tagName.slice(1)) }));
    for (let i = 1; i < levels.length; i++) {
      if (levels[i].level - levels[i - 1].level > 1) {
        push("heading-order", "1.3.1", levels[i].el, `heading jumps h${levels[i - 1].level} -> h${levels[i].level}`);
      }
    }
  } catch (e) { /* skip rule */ }

  try {
    const mains = [...document.querySelectorAll("main, [role=main]")].filter(visible);
    if (mains.length > 1) push("dup-main", "1.3.1", mains[1], `${mains.length} main landmarks`);
  } catch (e) { /* skip rule */ }

  return {
    violations,
    counts: violations.reduce((acc, v) => ({ ...acc, [v.rule]: (acc[v.rule] || 0) + 1 }), {}),
    elementsAudited: document.querySelectorAll("img, button, a[href], input, select, textarea, h1,h2,h3,h4,h5,h6, main").length,
  };
};

/** Run the audit at the page's current viewport. Never throws into the walk. */
export async function collectA11y(page, { maxName = MAX_NAME } = {}) {
  try {
    const res = await page.evaluate(AUDIT_FN, maxName);
    if (!res) return null;
    return {
      capturedAt: new Date().toISOString(),
      rules: ["img-alt", "control-name", "form-label", "doc-lang", "heading-order", "dup-main"],
      engine: "structural-rules@1",
      elementsAudited: res.elementsAudited,
      violationCount: res.violations.length,
      counts: res.counts,
      violations: res.violations,
    };
  } catch {
    return null;
  }
}

/**
 * Walk a page across every applicable viewport, auditing at each. Returns
 * per-viewport evidence keyed by name so a report can show "passes on desktop,
 * fails on mobile" — the responsive regression a single-viewport walk misses.
 */
export async function collectAcrossViewports(page, viewports, { audit = collectA11y, screenshot = null } = {}) {
  if (!Array.isArray(viewports) || viewports.length === 0) return null;
  const results = [];
  for (const v of viewports) {
    try {
      await page.setViewportSize({ width: v.width, height: v.height });
      const a11y = await audit(page);
      const shot = screenshot ? await screenshot(page, v) : null;
      results.push({ viewport: v.name, width: v.width, height: v.height, a11y, screenshot: shot });
    } catch (err) {
      results.push({ viewport: v.name, width: v.width, height: v.height, a11y: null, error: String(err?.message || err) });
    }
  }
  const totals = results.reduce((n, r) => n + (r.a11y?.violationCount || 0), 0);
  return {
    capturedAt: new Date().toISOString(),
    viewports: results,
    // observable:false when NO viewport produced an audit — the fail-closed
    // signal, distinct from "audited and found nothing wrong".
    observable: results.some((r) => r.a11y != null),
    totalViolations: totals,
  };
}
