// v2 actions[]: multi-navigation units folded to one verdict.
//
// Why this layer exists: a pages[] entry is ONE navigation with its own verdict
// and steps run inside a single page load (there is deliberately no `navigate`
// step). That makes the most important UAT assertion unexpressible in v1 —
// edit -> save -> REOPEN -> confirm it persisted needs two navigations, so it
// becomes two independent verdicts and nothing ever proves the second reflected
// the first.
//
// Everything here is pure: normalization, inheritance, templating and case
// expansion. The driver owns the browser; this module owns the shape.

import { normalizeViewports, viewportsForPage } from "./a11y_collector.mjs";
import { isMutatingStep } from "./page_steps.mjs";

/** Keys a phase inherits from its action when it does not set them itself. */
const SCALAR_INHERIT = ["budget_ms", "fail_on_slow", "strict_errors"];

/**
 * One internal model. A v1 pages[] entry becomes a one-phase action so the
 * driver has a single code path and v1 manifests behave identically — the
 * synthesized action is marked `synthetic` so the report can keep rendering a
 * flat page list rather than inventing an action grouping nobody asked for.
 */
export function normalizeActions(manifest = {}) {
  if (Array.isArray(manifest.actions) && manifest.actions.length > 0) {
    return manifest.actions.map((action, i) => ({
      ...action,
      name: action.name || `action ${i + 1}`,
      phases: Array.isArray(action.phases) ? action.phases : [],
      synthetic: false,
    }));
  }
  return (Array.isArray(manifest.pages) ? manifest.pages : []).map((page) => ({
    name: page.name,
    phases: [page],
    synthetic: true,
  }));
}

/** Does this phase change data? Inference is authoritative — see resolvePhase. */
export function phaseMutates(phase = {}) {
  const steps = [...(phase.steps || []), ...(phase.cleanup_steps || [])];
  if (steps.some((s) => isMutatingStep(s))) return true;
  // `mutates` may only ESCALATE. A phase whose navigation alone writes (a GET
  // that fires a job) declares it; `false` is never honored, so a manifest
  // cannot opt out of the retry, viewport and cleanup consequences.
  return phase.mutates === true;
}

export function actionMutates(action = {}) {
  return (action.phases || []).some((p) => phaseMutates(p));
}

/**
 * Resolve one phase into the effective page-like object the driver walks.
 *
 * Precedence is uniform: phase -> action -> walk -> driver default. Scalars
 * override; noise_patterns and require_evidence union; runtime deep-merges.
 * `cleanup_steps` are deliberately NOT inherited — cleanup is action-scoped and
 * runs once after the last phase, not once per phase.
 */
export function resolvePhase(manifest, action, phase, index) {
  const out = { ...phase };

  out.name = phase.name || `${action.name} · ${index + 1}`;
  out.lands_on = phase.lands_on || phase.path;

  for (const key of SCALAR_INHERIT) {
    if (out[key] === undefined && action[key] !== undefined) out[key] = action[key];
  }

  out.noise_patterns = unionArrays(phase.noise_patterns, action.noise_patterns);
  out.require_evidence = unionArrays(phase.require_evidence, action.require_evidence);
  if (action.runtime || phase.runtime) {
    out.runtime = { ...(action.runtime || {}), ...(phase.runtime || {}) };
  }

  // Cleanup belongs to the action; never let a phase inherit it.
  delete out.cleanup_steps;
  delete out.cleanup_budget_ms;

  out._action = action.name;
  out._phaseIndex = index;
  out._mutates = phaseMutates(phase);
  return out;
}

function unionArrays(a, b) {
  const merged = [...(Array.isArray(a) ? a : []), ...(Array.isArray(b) ? b : [])];
  return merged.length ? [...new Set(merged)] : undefined;
}

/**
 * Which login does this action run under, and under what stable key?
 *
 * The key is what the driver's session pool groups on, so every action sharing
 * an account logs in ONCE. Login is an action-level axis and never per phase:
 * an action must not split across browser contexts, or its carried state and
 * its cookie jar disagree halfway through.
 */
export function resolveLogin(manifest = {}, action = {}) {
  const registry = manifest.logins || null;
  if (action.login) {
    if (!registry || !registry[action.login]) {
      return { key: action.login, login: null, error: `unknown login key "${action.login}"` };
    }
    return { key: action.login, login: registry[action.login], error: null };
  }
  if (manifest.login) return { key: "__default__", login: manifest.login, error: null };
  if (registry) {
    const keys = Object.keys(registry);
    if (keys.length === 1) return { key: keys[0], login: registry[keys[0]], error: null };
    return {
      key: null,
      login: null,
      error: `action "${action.name}" must name a login (registry has ${keys.length} accounts)`,
    };
  }
  return { key: null, login: null, error: `action "${action.name}" has no login` };
}

/**
 * Expand actions into the physical visits the driver performs.
 *
 * The v1 expander is a cartesian product of pages x viewports. Applied naively
 * to actions that is a live trap: a 3-viewport walk containing a mutating
 * action would execute its mutation THREE times. Mutating actions are therefore
 * pinned to a single viewport and the rest are reported NOT_TESTED with a
 * reason, rather than silently multiplying writes.
 */
export function expandActionCases(manifest = {}, declaredViewports = undefined) {
  const actions = normalizeActions(manifest);
  const { viewports, invalid } = normalizeViewports(declaredViewports);
  if (invalid.length > 0) return { cases: [], invalid, unknown: [], pinned: [], errors: [] };

  const active = viewports.length > 0 ? viewports : [];
  const known = new Set(active.map((v) => v.name));
  const unknown = [];
  const pinned = [];
  const errors = [];
  const cases = [];

  for (let ai = 0; ai < actions.length; ai += 1) {
    const action = actions[ai];
    const login = resolveLogin(manifest, action);
    if (login.error) errors.push(login.error);

    const requested = Array.isArray(action.viewports) ? action.viewports : [];
    for (const name of requested) {
      if (!known.has(name)) unknown.push({ page: action.name, name });
    }
    let applicable = viewportsForPage(active, requested);
    if (applicable.length === 0) applicable = [DEFAULT_CASE_VIEWPORT];

    const mutates = actionMutates(action);
    let viewportsToRun = applicable;
    if (mutates && applicable.length > 1) {
      viewportsToRun = [applicable[0]];
      for (const skipped of applicable.slice(1)) {
        pinned.push({
          action: action.name,
          viewport: skipped.name,
          reason: "mutating action pinned to one viewport (a repeat run would repeat the write)",
        });
      }
    }

    for (const viewport of viewportsToRun) {
      cases.push({
        action,
        actionIndex: ai,
        loginKey: login.key,
        login: login.login,
        mutates,
        viewport,
        phases: action.phases.map((phase, pi) => ({
          phase,
          phaseIndex: pi,
          effective: resolvePhase(manifest, action, phase, pi),
        })),
      });
    }
  }

  return { cases, invalid, unknown, pinned, errors };
}

// Mirrors a11y_collector's implicit single-viewport default without importing a
// private constant; the driver overrides it from the real default anyway.
const DEFAULT_CASE_VIEWPORT = {
  name: "default",
  width: 1440,
  height: 900,
  deviceScaleFactor: 1,
  implicit: true,
};

/**
 * Fixture identity for records this walk creates.
 *
 * With no app-side audit trail there is no way to ask the database WHO changed
 * a row, so a naming convention is the only attribution available. It is
 * deliberately weak — it can only mark records the walk CREATED, never ones it
 * edited — but on a shared dataset "weak" is the difference between finding the
 * fixtures a failed cleanup left behind and never knowing they exist.
 *
 * `run` is passed in rather than generated here so the whole walk shares one id
 * and the value stays testable.
 */
export function fixtureIdentity(manifest = {}, run = null) {
  const prefix = manifest?.fixtures?.prefix || "walk";
  const id = run || "unknown";
  return { prefix, run: id, tag: `${prefix}-${id}` };
}

const FIXTURE_RE = /\{\{\s*fixture\.(prefix|run|tag)\s*\}\}/gi;

/** Substitute {{fixture.*}}. Unlike carry, these always resolve. */
export function applyFixture(value, fixture) {
  if (typeof value !== "string" || !fixture) return value;
  return value.replace(FIXTURE_RE, (_all, key) => String(fixture[key] ?? ""));
}

const CARRY_RE = /\{\{\s*carry\.([a-z][a-z0-9_]*)\s*\}\}/gi;

/** Does this string reference the carry bag at all? */
export function usesCarry(value) {
  return typeof value === "string" && /\{\{\s*carry\./i.test(value);
}

/** Does this string reference the fixture identity? */
export function usesFixture(value) {
  return typeof value === "string" && /\{\{\s*fixture\./i.test(value);
}

/**
 * Substitute {{carry.key}} references.
 *
 * Returns { text, missing }. A missing key is NEVER silently left as a literal:
 * templating "/skus/{{carry.id}}/edit" into a URL unresolved navigates
 * somewhere unintended, lands on a real page, and reports a confident wrong
 * answer. The caller turns `missing` into BLOCKED.
 */
export function applyCarry(value, bag = {}) {
  if (typeof value !== "string") return { text: value, missing: [] };
  const missing = [];
  const text = value.replace(CARRY_RE, (_all, key) => {
    const has = Object.prototype.hasOwnProperty.call(bag, key) && bag[key] != null;
    if (!has) {
      missing.push(key);
      return _all;
    }
    return String(bag[key]);
  });
  return { text, missing: [...new Set(missing)] };
}

/** Apply carry to every templated field of an effective phase. */
export function applyCarryToPhase(effective, bag = {}, fixture = null) {
  const out = { ...effective };
  const missing = [];
  const resolve = (v) => applyCarry(applyFixture(v, fixture), bag);
  for (const key of ["path", "lands_on"]) {
    const r = resolve(out[key]);
    out[key] = r.text;
    missing.push(...r.missing);
  }
  if (Array.isArray(out.steps)) {
    out.steps = out.steps.map((step) => {
      const next = { ...step };
      for (const key of ["text", "value", "path", "url", "lands_on", "selector"]) {
        if (usesCarry(next[key]) || usesFixture(next[key])) {
          const r = resolve(next[key]);
          next[key] = r.text;
          missing.push(...r.missing);
        }
      }
      return next;
    });
  }

  // Runtime probes template too. This is what lets a before/after query be
  // scoped to the RECORD under test — an unscoped `SELECT count(*) FROM skus`
  // on a shared dataset reports another session's writes as our delta, so a
  // change-detector without carry is a false-positive generator.
  if (out.runtime && typeof out.runtime === "object") {
    const rt = { ...out.runtime };
    if (usesCarry(rt.sql) || usesFixture(rt.sql)) {
      const r = resolve(rt.sql);
      rt.sql = r.text;
      missing.push(...r.missing);
    }
    if (rt.db_before_after) {
      const spec = typeof rt.db_before_after === "string"
        ? { sql: rt.db_before_after }
        : { ...rt.db_before_after };
      if (usesCarry(spec.sql) || usesFixture(spec.sql)) {
        const r = resolve(spec.sql);
        spec.sql = r.text;
        missing.push(...r.missing);
      }
      rt.db_before_after = spec;
    }
    if (Array.isArray(rt.probes)) {
      rt.probes = rt.probes.map((probe) => {
        if (!usesCarry(probe?.eval) && !usesFixture(probe?.eval)) return probe;
        const r = resolve(probe.eval);
        missing.push(...r.missing);
        return { ...probe, eval: r.text };
      });
    }
    out.runtime = rt;
  }

  return { phase: out, missing: [...new Set(missing)] };
}

/**
 * Read one carry value out of a landed page. Returns { key, value, error }.
 * `read` is injected so this stays pure and unit-testable:
 *   read.url()            -> current URL
 *   read.text(selector)   -> first match's text
 *   read.attr(sel, name)  -> first match's attribute
 */
export async function extractCarry(key, spec = {}, read = {}) {
  try {
    if (spec.from === "url") {
      if (!spec.pattern) return { key, value: null, error: "carry url source needs a pattern" };
      const url = await read.url();
      const m = new RegExp(spec.pattern).exec(String(url ?? ""));
      if (!m) return { key, value: null, error: `pattern did not match ${url}` };
      return { key, value: m[1] != null ? m[1] : m[0], error: null };
    }
    if (spec.from === "text") {
      if (!spec.selector) return { key, value: null, error: "carry text source needs a selector" };
      const v = await read.text(spec.selector);
      if (v == null || String(v).trim() === "") {
        return { key, value: null, error: `no text at ${spec.selector}` };
      }
      return { key, value: String(v).trim(), error: null };
    }
    if (spec.from === "attr") {
      if (!spec.selector || !spec.attr) {
        return { key, value: null, error: "carry attr source needs selector and attr" };
      }
      const v = await read.attr(spec.selector, spec.attr);
      if (v == null || String(v) === "") {
        return { key, value: null, error: `no ${spec.attr} at ${spec.selector}` };
      }
      return { key, value: String(v), error: null };
    }
    return { key, value: null, error: `unknown carry source "${spec.from}"` };
  } catch (err) {
    return { key, value: null, error: String(err?.message || err) };
  }
}

/** Run every carry spec declared on a phase. Required failures BLOCK. */
export async function extractCarries(phase = {}, read = {}) {
  const specs = phase.carry && typeof phase.carry === "object" ? phase.carry : null;
  if (!specs) return { values: {}, failed: [] };
  const values = {};
  const failed = [];
  for (const [key, spec] of Object.entries(specs)) {
    const r = await extractCarry(key, spec, read);
    if (r.error != null) {
      if (spec?.required !== false) failed.push({ key, error: r.error });
      continue;
    }
    values[key] = r.value;
  }
  return { values, failed };
}
