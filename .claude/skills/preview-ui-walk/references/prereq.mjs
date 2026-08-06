// Action prerequisites: "is this action testable on this dataset right now?"
//
// So the engine does not report "not implemented" when the truth is "no
// eligible data on this site". Every predicate compiles to a primitive that
// ALREADY exists — SELECT-only execute_sql_query, or a project_eval probe — so
// this is a typed facade, not a second checking engine.
//
// The rule that matters more than the vocabulary: a predicate that cannot be
// EVALUATED is missing evidence, not a pass and not a skip. Route it through
// require_evidence: ["prereq"] and the existing evidenceGuard produces BLOCKED,
// instead of inheriting runtime's `skipped: tidewave_unavailable` degradation —
// which would delete the gate exactly when the environment is unhealthy.

import { assertSelectOnly, runProbe, runSql } from "./runtime_evidence.mjs";

/** Identify a predicate in reports and in precondition_lost accounting. */
export function prereqName(p = {}, index = 0) {
  if (p.name) return p.name;
  if (p.type === "record_exists") return `${p.type}:${p.of || "?"}`;
  if (p.type === "feature_enabled") return `${p.type}:${p.flag || "?"}`;
  if (p.type === "account_can") return `${p.type}:${p.permission || "?"}`;
  return `${p.type || "prereq"}#${index + 1}`;
}

/** Quote a scalar for an inlined SQL literal. Values come from the manifest. */
function sqlLiteral(v) {
  if (v === null) return "NULL";
  if (typeof v === "number") return Number.isFinite(v) ? String(v) : "NULL";
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
  return `'${String(v).replace(/'/g, "''")}'`;
}

/** Identifiers are manifest-authored, but never interpolate them unchecked. */
function safeIdent(name) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(String(name || "")) ? String(name) : null;
}

/**
 * Compile one predicate to { kind: "sql"|"eval", ... } or { error }.
 * Compilation is pure and unit-testable; execution is the caller's job.
 */
export function compilePrereq(p = {}, index = 0) {
  const name = prereqName(p, index);
  switch (p.type) {
    case "record_exists": {
      const table = safeIdent(p.of);
      if (!table) return { name, error: `record_exists needs a valid table name (got ${p.of})` };
      const clauses = [];
      for (const [col, val] of Object.entries(p.where || {})) {
        const ident = safeIdent(col);
        if (!ident) return { name, error: `invalid column name "${col}"` };
        clauses.push(val === null ? `${ident} IS NULL` : `${ident} = ${sqlLiteral(val)}`);
      }
      const where = clauses.length ? ` WHERE ${clauses.join(" AND ")}` : "";
      return {
        name,
        kind: "sql",
        sql: `SELECT count(*) FROM ${table}${where}`,
        expect_min: Number.isInteger(p.min) ? p.min : 1,
      };
    }
    case "feature_enabled": {
      if (!p.flag) return { name, error: "feature_enabled needs a flag" };
      return {
        name,
        kind: "eval",
        eval: p.eval || `Application.get_env(:app, :features, [])[:${p.flag}] == true`,
        expect: Object.prototype.hasOwnProperty.call(p, "expect") ? p.expect : true,
      };
    }
    case "account_can": {
      if (!p.permission) return { name, error: "account_can needs a permission" };
      if (!p.eval) {
        return {
          name,
          error:
            `account_can:${p.permission} needs an explicit \`eval\` — permission lookup is ` +
            "app-specific and guessing it would produce a confident wrong answer",
        };
      }
      return {
        name,
        kind: "eval",
        eval: p.eval,
        expect: Object.prototype.hasOwnProperty.call(p, "expect") ? p.expect : true,
      };
    }
    case "sql": {
      if (!p.query) return { name, error: "sql prereq needs a query" };
      const gate = assertSelectOnly(p.query);
      if (!gate.ok) return { name, error: gate.error };
      const out = { name, kind: "sql", sql: gate.query };
      if (Object.prototype.hasOwnProperty.call(p, "expect")) out.expect = p.expect;
      if (Object.prototype.hasOwnProperty.call(p, "expect_min")) out.expect_min = p.expect_min;
      if (out.expect === undefined && out.expect_min === undefined) out.expect_min = 1;
      return out;
    }
    case "eval": {
      if (!p.eval) return { name, error: "eval prereq needs an eval" };
      const out = { name, kind: "eval", eval: p.eval };
      out.expect = Object.prototype.hasOwnProperty.call(p, "expect") ? p.expect : true;
      return out;
    }
    default:
      return { name, error: `unknown prereq type "${p.type}"` };
  }
}

/**
 * Evaluate an action's prerequisites.
 *
 * Returns { evaluated, results: [{name, ok, error}], unmet, blocked }.
 *  - `blocked` is set when a predicate could not be evaluated at all (no
 *    Tidewave, bad compile, transport failure). That is missing evidence.
 *  - `unmet` lists predicates that evaluated cleanly and came back false.
 * The two are deliberately different: "we could not ask" is not "the answer
 * was no", and only the second says anything about the dataset.
 */
export async function evaluatePrereqs(prereqs, runtimeBag = {}, opts = {}) {
  const list = Array.isArray(prereqs) ? prereqs : [];
  if (list.length === 0) return { evaluated: true, results: [], unmet: [], blocked: null };

  const mcpUrl = runtimeBag?.tidewave?.url || opts.mcpUrl || null;
  const twOk = runtimeBag?.tidewave?.status === "ok" || opts.force === true;
  if (!mcpUrl || !twOk) {
    return {
      evaluated: false,
      results: list.map((p, i) => ({ name: prereqName(p, i), ok: null, error: "tidewave_unavailable" })),
      unmet: [],
      blocked: "prerequisites could not be evaluated: Tidewave unavailable",
    };
  }

  const results = [];
  let blocked = null;
  for (let i = 0; i < list.length; i += 1) {
    const compiled = compilePrereq(list[i], i);
    if (compiled.error) {
      results.push({ name: compiled.name, ok: null, error: compiled.error });
      blocked = blocked || `prerequisite "${compiled.name}" could not be compiled: ${compiled.error}`;
      continue;
    }
    try {
      if (compiled.kind === "sql") {
        const r = await runSql(mcpUrl, {
          sql: compiled.sql,
          ...(compiled.expect !== undefined ? { expect: compiled.expect } : {}),
          ...(compiled.expect_min !== undefined ? { expect_min: compiled.expect_min } : {}),
        });
        if (!r) {
          results.push({ name: compiled.name, ok: null, error: "no_result" });
          blocked = blocked || `prerequisite "${compiled.name}" returned no result`;
          continue;
        }
        // A transport/SQL error is "could not ask"; a clean FAIL is "answer: no".
        if (r.error && r.status === "FAIL" && !/expect/.test(String(r.error))) {
          results.push({ name: compiled.name, ok: null, error: r.error });
          blocked = blocked || `prerequisite "${compiled.name}" errored: ${r.error}`;
          continue;
        }
        results.push({ name: compiled.name, ok: r.status === "PASS", error: r.error || null });
      } else {
        const r = await runProbe(mcpUrl, {
          name: compiled.name,
          eval: compiled.eval,
          expect: compiled.expect,
        });
        if (r.error && r.status === "FAIL" && !/expect/.test(String(r.error))) {
          results.push({ name: compiled.name, ok: null, error: r.error });
          blocked = blocked || `prerequisite "${compiled.name}" errored: ${r.error}`;
          continue;
        }
        results.push({ name: compiled.name, ok: r.status === "PASS", error: r.error || null });
      }
    } catch (err) {
      const msg = String(err?.message || err);
      results.push({ name: compiled.name, ok: null, error: msg });
      blocked = blocked || `prerequisite "${compiled.name}" threw: ${msg}`;
    }
  }

  return {
    evaluated: blocked == null,
    results,
    unmet: results.filter((r) => r.ok === false).map((r) => r.name),
    blocked,
  };
}

/**
 * The evidence value handed to evidenceGuard. Deliberately null when nothing
 * could be evaluated, so `require_evidence: ["prereq"]` fails closed through
 * the existing guard rather than a bespoke branch.
 */
export function prereqEvidence(outcome) {
  if (!outcome || outcome.results.length === 0) return null;
  if (!outcome.evaluated) return null;
  return { checked: outcome.results.length, results: outcome.results, unmet: outcome.unmet };
}
