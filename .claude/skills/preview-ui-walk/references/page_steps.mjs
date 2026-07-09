// Page step runner for preview-ui-walk.
//
// Read-only steps always allowed: wait_for, assert_selector, assert_text, assert_url, settle.
// Mutating steps (click, fill, type, press, select, check) require:
//   safety.allow_interactions === true  AND  no prod_like env_check hits
// and still refuse names listed in safety.deny_events (matched against step.event).
//
// Steps are product-owned in pages[].steps. Drivers never invent clicks.

const READ_ONLY = new Set([
  "wait_for",
  "wait_for_selector",
  "assert_selector",
  "assert_text",
  "assert_url",
  "settle",
  "screenshot", // no-op marker; walk always screenshots
]);

const MUTATING = new Set([
  "click",
  "fill",
  "type",
  "press",
  "select",
  "check",
  "uncheck",
  "hover", // soft; still gated because it can open menus that load writes
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
  if (!steps.length) return { status: "PASS", steps: [], ran: 0 };

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
        // Fail closed when interactions were requested but blocked? Prefer FAIL so
        // a walk that *needs* a click doesn't greenwash as navigate-only.
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
        error: String(e.message || e).slice(0, 300),
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
      await page.waitForSelector(sel, {
        timeout,
        state: step.state || "visible",
      });
      return;
    }
    case "assert_selector": {
      if (!sel) throw new Error("assert_selector needs selector");
      const loc = page.locator(sel).first();
      const count = await loc.count();
      if (!count) throw new Error(`selector not found: ${sel}`);
      if (step.state === "hidden") {
        if (await loc.isVisible()) throw new Error(`selector visible (expected hidden): ${sel}`);
      } else if (!(await loc.isVisible().catch(() => false))) {
        // attached but not visible still counts unless require_visible:false
        if (step.require_visible !== false) {
          throw new Error(`selector not visible: ${sel}`);
        }
      }
      return;
    }
    case "assert_text": {
      const body = await page.locator("body").innerText();
      const needle = String(text ?? "");
      if (!needle) throw new Error("assert_text needs text");
      if (!body.includes(needle)) {
        throw new Error(`text not found: ${needle.slice(0, 80)}`);
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
    case "screenshot":
      return;
    case "click": {
      if (!sel) throw new Error("click needs selector");
      await page.click(sel, { timeout });
      if (step.wait_ms) await page.waitForTimeout(step.wait_ms);
      return;
    }
    case "fill": {
      if (!sel) throw new Error("fill needs selector");
      await page.fill(sel, String(text ?? ""), { timeout });
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
