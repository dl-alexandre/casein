// Page step runner for preview-ui-walk.
//
// Read-only steps always allowed:
//   wait_for, assert_selector, assert_text, assert_url, assert_iframe,
//   assert_http, settle, screenshot
// Mutating steps (click, fill, type, press, select, check) require:
//   safety.allow_interactions === true  AND  no prod_like env_check hits
// and still refuse names listed in safety.deny_events (matched against step.event).
//
// Frame scope: set step.frame / step.iframe to a CSS selector (or true for
// "iframe") so assert_selector / assert_text / wait_for run inside that frame.
// assert_iframe is the dedicated "embed actually loaded" check — catches the
// LiveDashboard false-green (shell OK, gray broken-document iframe).
//
// Steps are product-owned in pages[].steps. Drivers never invent clicks.

const READ_ONLY = new Set([
  "wait_for",
  "wait_for_selector",
  "assert_selector",
  "assert_text",
  "assert_url",
  "assert_iframe",
  "assert_http",
  "settle",
  "screenshot",
]);

const MUTATING = new Set([
  "click",
  "fill",
  "type",
  "press",
  "select",
  "check",
  "uncheck",
  "hover",
]);

export function stepKind(step) {
  return String(step?.action || step?.kind || "").toLowerCase();
}

export function isMutatingStep(step) {
  return MUTATING.has(stepKind(step));
}

/**
 * Decide whether interactions may run for this walk.
 * Returns { allowed: boolean, reason?: string }
 */
export function interactionsAllowed(manifest, runtimeBag) {
  const safety = manifest?.safety || {};
  if (safety.read_only === true && safety.allow_interactions !== true) {
    return { allowed: false, reason: "safety.read_only (set allow_interactions:true to opt in)" };
  }
  if (safety.allow_interactions !== true) {
    return { allowed: false, reason: "safety.allow_interactions is not true" };
  }
  const prod = (runtimeBag?.env_check?.items || []).filter((i) => i.risk === "prod_like");
  if (prod.length) {
    return {
      allowed: false,
      reason: `env_check prod_like: ${prod.map((p) => p.key).join(", ")}`,
    };
  }
  return { allowed: true };
}

function denyEventHit(step, denyList) {
  if (!denyList?.length) return null;
  const event = step.event || step.phx_click || step.name;
  if (!event) return null;
  const hit = denyList.find((d) => String(event).includes(d) || d === event);
  return hit || null;
}

/**
 * Run pages[].steps against a Playwright page.
 * Returns { status: "PASS"|"FAIL"|"SKIPPED", steps: [...] }
 */
export async function runPageSteps(page, pageSpec, { manifest, runtimeBag, base } = {}) {
  const steps = Array.isArray(pageSpec.steps) ? pageSpec.steps : [];
  if (!steps.length) return { status: "PASS", steps: [], ran: 0, failed: 0, skipped: 0 };

  const gate = interactionsAllowed(manifest, runtimeBag);
  const deny = manifest?.safety?.deny_events || [];
  const results = [];
  let failed = 0;
  let skipped = 0;

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i] || {};
    const kind = stepKind(step);
    const label = step.name || `${kind || "step"}#${i}`;
    const timeout = step.timeout_ms || pageSpec.budget_ms || 8000;

    if (!kind) {
      results.push({ name: label, action: null, status: "FAIL", error: "missing_action" });
      failed++;
      continue;
    }

    if (isMutatingStep(step)) {
      if (!gate.allowed) {
        results.push({
          name: label,
          action: kind,
          status: "SKIPPED",
          error: `mutating_step_blocked: ${gate.reason}`,
        });
        skipped++;
        if (step.required !== false) {
          results[results.length - 1].status = "FAIL";
          failed++;
          skipped--;
        }
        continue;
      }
      const hit = denyEventHit(step, deny);
      if (hit) {
        results.push({
          name: label,
          action: kind,
          status: "FAIL",
          error: `deny_events hit: ${hit}`,
        });
        failed++;
        continue;
      }
    }

    try {
      // eslint-disable-next-line no-await-in-loop
      await executeStep(page, step, { timeout, base });
      results.push({ name: label, action: kind, status: "PASS" });
    } catch (e) {
      results.push({
        name: label,
        action: kind,
        status: "FAIL",
        error: String(e.message || e).slice(0, 400),
      });
      failed++;
      if (step.continue_on_fail !== true) break;
    }
  }

  return {
    status: failed ? "FAIL" : "PASS",
    steps: results,
    ran: results.filter((r) => r.status === "PASS").length,
    failed,
    skipped,
  };
}

/** Resolve main page vs frameLocator for frame-scoped steps. */
function frameSelector(step) {
  const f = step.frame ?? step.iframe;
  if (f == null || f === false) return null;
  if (f === true) return "iframe";
  return String(f);
}

/**
 * @returns {import('playwright-core').Page | import('playwright-core').FrameLocator}
 */
function resolveScope(page, step) {
  const sel = frameSelector(step);
  if (!sel) return page;
  // FrameLocator: locator() works; no page.evaluate / request.
  return page.frameLocator(sel).first();
}

async function executeStep(page, step, { timeout, base }) {
  const kind = stepKind(step);
  const sel = step.selector || step.css || step.locator;
  const text = step.text ?? step.value ?? step.contains;

  switch (kind) {
    case "settle": {
      const ms = step.ms || step.settle_ms || 500;
      await page.waitForTimeout(ms);
      return;
    }
    case "wait_for":
    case "wait_for_selector": {
      if (!sel) throw new Error("wait_for needs selector");
      const scope = resolveScope(page, step);
      if (scope === page) {
        await page.waitForSelector(sel, {
          timeout,
          state: step.state || "visible",
        });
      } else {
        await scope.locator(sel).first().waitFor({
          timeout,
          state: step.state || "visible",
        });
      }
      return;
    }
    case "assert_selector": {
      if (!sel) throw new Error("assert_selector needs selector");
      const scope = resolveScope(page, step);
      const loc = scope.locator(sel).first();
      const count = await loc.count();
      if (!count) {
        throw new Error(
          `selector not found: ${sel}` +
            (frameSelector(step) ? ` (frame ${frameSelector(step)})` : ""),
        );
      }
      if (step.state === "hidden") {
        if (await loc.isVisible()) throw new Error(`selector visible (expected hidden): ${sel}`);
      } else if (!(await loc.isVisible().catch(() => false))) {
        if (step.require_visible !== false) {
          throw new Error(`selector not visible: ${sel}`);
        }
      }
      return;
    }
    case "assert_text": {
      const needle = String(text ?? "");
      if (!needle) throw new Error("assert_text needs text");
      const scope = resolveScope(page, step);
      const body = await scope.locator("body").innerText();
      if (!body.includes(needle)) {
        throw new Error(
          `text not found: ${needle.slice(0, 80)}` +
            (frameSelector(step) ? ` (frame ${frameSelector(step)})` : ""),
        );
      }
      return;
    }
    case "assert_url": {
      const landed = page.url();
      let path = landed;
      try {
        path = new URL(landed).pathname;
      } catch {
        /* keep */
      }
      const want = step.path || step.lands_on || step.url || text;
      if (!want) throw new Error("assert_url needs path");
      const ok =
        path.includes(String(want).split("?")[0]) ||
        landed.includes(String(want));
      if (!ok) throw new Error(`url ${path} does not match ${want}`);
      return;
    }
    case "assert_iframe": {
      // Prove an embed loaded real content — not just that the shell has <iframe>.
      const iframeSel = step.selector || step.iframe || "iframe";
      const iframe = page.locator(iframeSel).first();
      if (!(await iframe.count())) {
        throw new Error(`no iframe matching ${iframeSel}`);
      }
      // Prefer attached + visible chrome
      if (step.require_visible !== false) {
        const vis = await iframe.isVisible().catch(() => false);
        if (!vis) throw new Error(`iframe not visible: ${iframeSel}`);
      }

      const handle = await iframe.elementHandle();
      if (!handle) throw new Error(`iframe element handle missing: ${iframeSel}`);
      let frame = await handle.contentFrame();
      // contentFrame can be null briefly while navigating; poll
      const deadline = Date.now() + timeout;
      while (!frame && Date.now() < deadline) {
        await page.waitForTimeout(100);
        frame = await handle.contentFrame();
      }
      if (!frame) {
        throw new Error(
          `iframe has no contentFrame (cross-origin blocked, crashed, or never loaded): ${iframeSel}`,
        );
      }

      try {
        await frame.waitForLoadState("domcontentloaded", { timeout: Math.min(timeout, 8000) });
      } catch {
        /* continue — we'll still inspect body */
      }
      // Extra settle for LiveView dashboards inside the frame
      await page.waitForTimeout(step.settle_ms || 400);

      let bodyText = "";
      let html = "";
      try {
        bodyText = await frame.locator("body").innerText({ timeout: 3000 });
      } catch {
        bodyText = "";
      }
      try {
        html = await frame.content();
      } catch {
        html = "";
      }

      const trimmed = bodyText.replace(/\s+/g, " ").trim();
      const minChars = step.min_chars != null ? Number(step.min_chars) : 40;
      if (trimmed.length < minChars && html.length < (step.min_html || 800)) {
        throw new Error(
          `iframe empty/broken (body_chars=${trimmed.length}, html_len=${html.length})` +
            (trimmed ? ` body="${trimmed.slice(0, 60)}…"` : ""),
        );
      }

      // Browser broken-document chrome sometimes leaves almost no text
      if (/err_|^about:blank$/i.test(frame.url() || "")) {
        throw new Error(`iframe navigated to error/blank: ${frame.url()}`);
      }

      if (text) {
        const needle = String(text);
        if (!trimmed.includes(needle) && !html.includes(needle)) {
          throw new Error(
            `iframe missing text "${needle.slice(0, 80)}" (url=${frame.url()})`,
          );
        }
      }

      if (step.url_includes) {
        const u = frame.url() || "";
        if (!u.includes(String(step.url_includes))) {
          throw new Error(`iframe url ${u} missing ${step.url_includes}`);
        }
      }
      return;
    }
    case "assert_http": {
      // Session-aware GET via the browser context (cookies from login).
      const path = step.path || step.url || text;
      if (!path) throw new Error("assert_http needs path");
      const url =
        path.startsWith("http://") || path.startsWith("https://")
          ? path
          : `${String(base || "").replace(/\/$/, "")}${path.startsWith("/") ? path : `/${path}`}`;
      const maxRedirects = step.max_redirects != null ? Number(step.max_redirects) : 5;
      const res = await page.request.get(url, {
        maxRedirects,
        timeout,
        failOnStatusCode: false,
      });
      const status = res.status();
      const maxStatus = step.max_status != null ? Number(step.max_status) : 399;
      const minStatus = step.min_status != null ? Number(step.min_status) : 200;
      if (status < minStatus || status > maxStatus) {
        throw new Error(`HTTP ${status} for ${url} (want ${minStatus}–${maxStatus})`);
      }
      if (step.expect_text) {
        const body = await res.text();
        if (!body.includes(String(step.expect_text))) {
          throw new Error(`HTTP body missing "${String(step.expect_text).slice(0, 80)}"`);
        }
      }
      return;
    }
    case "screenshot":
      return;
    case "click": {
      if (!sel) throw new Error("click needs selector");
      const scope = resolveScope(page, step);
      if (scope === page) await page.click(sel, { timeout });
      else await scope.locator(sel).first().click({ timeout });
      if (step.wait_ms) await page.waitForTimeout(step.wait_ms);
      return;
    }
    case "fill": {
      if (!sel) throw new Error("fill needs selector");
      const scope = resolveScope(page, step);
      if (scope === page) await page.fill(sel, String(text ?? ""), { timeout });
      else await scope.locator(sel).first().fill(String(text ?? ""), { timeout });
      return;
    }
    case "type": {
      if (!sel) throw new Error("type needs selector");
      await page.type(sel, String(text ?? ""), { timeout, delay: step.delay_ms || 0 });
      return;
    }
    case "press": {
      const key = step.key || text;
      if (!key) throw new Error("press needs key");
      if (sel) await page.press(sel, key, { timeout });
      else await page.keyboard.press(key);
      return;
    }
    case "select": {
      if (!sel) throw new Error("select needs selector");
      await page.selectOption(sel, step.value ?? text, { timeout });
      return;
    }
    case "check":
    case "uncheck": {
      if (!sel) throw new Error(`${kind} needs selector`);
      if (kind === "check") await page.check(sel, { timeout });
      else await page.uncheck(sel, { timeout });
      return;
    }
    case "hover": {
      if (!sel) throw new Error("hover needs selector");
      await page.hover(sel, { timeout });
      return;
    }
    default:
      throw new Error(`unknown step action: ${kind}`);
  }
}
