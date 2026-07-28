#!/usr/bin/env node
// Unified preflight readiness matrix for preview-ui-walk.
//
// Answers "can this walk run, and will its evidence mean anything?" WITHOUT
// touching product data. Preflight performs NO product mutations: every check
// is a read, a probe, or a capability test against a scratch page. That is
// enforced structurally — a check declares `mutates: true` and the runner
// refuses to execute it (there are none today; the field exists so a future
// check cannot quietly become destructive).
//
// Exit codes (see EXIT):
//   0 READY          — everything required and optional is present
//   1 DEGRADED       — required present; some OPTIONAL evidence missing.
//                      Read-only walks may proceed; the report will carry
//                      BLOCKED rows for whatever could not be collected.
//   2 BLOCKED        — a REQUIRED capability is missing. Do not run.
//   3 UNSAFE         — environment looks production-like, or a mutating walk
//                      was requested where mutation is prohibited. Never run.
//
// UNSAFE outranks BLOCKED outranks DEGRADED: the worst finding wins, so a
// prod-looking target can never be downgraded to "just missing evidence".

export const EXIT = { READY: 0, DEGRADED: 1, BLOCKED: 2, UNSAFE: 3 };

// Check states. `SKIP` means not applicable to this manifest (e.g. no roles
// configured) and never worsens the verdict.
export const STATE = {
  OK: "OK",
  MISSING: "MISSING",
  BLOCKED: "BLOCKED",
  UNSAFE: "UNSAFE",
  SKIP: "SKIP",
};

/** Categories, in report order. Each is required or optional. */
export const CATEGORIES = [
  { id: "schema", label: "Schema & manifests", required: true },
  { id: "env_safety", label: "Environment safety", required: true },
  { id: "credentials", label: "Role credentials", required: true },
  { id: "app_health", label: "App health & assets", required: true },
  { id: "identity", label: "Deployed/source/workflow identity", required: false },
  { id: "browser", label: "Chromium / playwright-core", required: true },
  { id: "preview_mcp", label: "Preview MCP & cookie injection", required: false },
  { id: "tidewave", label: "Tidewave / logs / correlation / LiveView", required: false },
  { id: "har", label: "HAR collector", required: false },
  { id: "ws", label: "WebSocket collector", required: false },
  { id: "dom", label: "DOM snapshot collector", required: false },
  { id: "screenshot", label: "Screenshot collector", required: true },
  { id: "a11y", label: "Accessibility collector", required: false },
  { id: "viewport", label: "Viewport support", required: false },
  { id: "visual_baseline", label: "Visual baseline", required: false },
  { id: "resource_metrics", label: "Resource metrics", required: false },
  { id: "api", label: "API request collector", required: false },
  { id: "downloads", label: "Download collector", required: false },
  { id: "db_read", label: "DB read visibility", required: false },
  { id: "audit_actor", label: "Audit actor visibility", required: false },
  { id: "artifact", label: "Artifact publish / durable URL", required: false },
  { id: "cleanup", label: "Fixture cleanup capability", required: false },
  { id: "disk", label: "Disk space", required: true },
  { id: "leaked_sessions", label: "Leaked preview/browser sessions", required: false },
];

const CATEGORY_BY_ID = new Map(CATEGORIES.map((c) => [c.id, c]));

/**
 * Secret hygiene: credential checks report only whether a value RESOLVED and
 * where it came from — never the value, never a prefix, never a length (a
 * length leaks entropy for short secrets). `redact` is the single funnel.
 */
export function redact(value) {
  if (value == null || value === "") return { resolved: false, hint: "unset" };
  return { resolved: true, hint: "set" };
}

/**
 * Build one row. `state` drives the verdict; `detail` is human text that must
 * never contain a secret.
 */
export function row(id, state, detail, extra = {}) {
  const cat = CATEGORY_BY_ID.get(id);
  if (!cat) throw new Error(`unknown preflight category: ${id}`);
  return {
    id,
    label: cat.label,
    required: cat.required,
    state,
    detail: detail || "",
    ...extra,
  };
}

/**
 * Fold rows into an exit code, worst-first.
 *
 * A MISSING **required** row is BLOCKED (fail closed): running a walk whose
 * required capability is absent produces a report that cannot be trusted.
 * A MISSING **optional** row is DEGRADED — read-only walks may proceed, and the
 * corresponding pages will surface as BLOCKED rather than silently passing.
 */
export function verdict(rows, { mutating = false } = {}) {
  let worst = EXIT.READY;
  const bump = (code) => {
    if (code > worst) worst = code;
  };
  for (const r of rows) {
    if (r.state === STATE.UNSAFE) bump(EXIT.UNSAFE);
    else if (r.state === STATE.BLOCKED) bump(EXIT.BLOCKED);
    else if (r.state === STATE.MISSING) bump(r.required ? EXIT.BLOCKED : EXIT.DEGRADED);
  }
  // A mutating walk requires an affirmatively safe environment. If env safety
  // is anything but OK, mutation is prohibited outright.
  if (mutating) {
    const env = rows.find((r) => r.id === "env_safety");
    if (!env || env.state !== STATE.OK) worst = EXIT.UNSAFE;
  }
  return worst;
}

export function verdictName(code) {
  return Object.keys(EXIT).find((k) => EXIT[k] === code) || "UNKNOWN";
}

/** Machine-readable matrix. Stable key order so diffs are reviewable. */
export function toJson(rows, opts = {}) {
  const code = verdict(rows, opts);
  const counts = { OK: 0, MISSING: 0, BLOCKED: 0, UNSAFE: 0, SKIP: 0 };
  for (const r of rows) counts[r.state] = (counts[r.state] || 0) + 1;
  return {
    schema: "preview-ui-walk/preflight@1",
    generatedAt: opts.now || new Date().toISOString(),
    mutating: Boolean(opts.mutating),
    mutationsPerformed: 0, // preflight never mutates; asserted by selftest
    verdict: verdictName(code),
    exitCode: code,
    counts,
    rows: rows.map((r) => ({
      id: r.id,
      label: r.label,
      required: r.required,
      state: r.state,
      detail: r.detail,
      ...(r.evidence ? { evidence: r.evidence } : {}),
    })),
  };
}

const GLYPH = { OK: "✓", MISSING: "○", BLOCKED: "✗", UNSAFE: "!", SKIP: "-" };

/** Human matrix. Aligned so a reader scans the state column, not the prose. */
export function toText(rows, opts = {}) {
  const code = verdict(rows, opts);
  const width = Math.max(...rows.map((r) => r.label.length), 10);
  const lines = ["preview-ui-walk preflight — readiness matrix", ""];
  for (const r of rows) {
    const req = r.required ? "required" : "optional";
    lines.push(
      `  ${GLYPH[r.state] || "?"} ${r.label.padEnd(width)}  ${r.state.padEnd(7)} ${req.padEnd(8)} ${r.detail}`.trimEnd(),
    );
  }
  const missingRequired = rows.filter((r) => r.required && r.state === STATE.MISSING);
  const missingOptional = rows.filter((r) => !r.required && r.state === STATE.MISSING);
  lines.push("");
  lines.push(`  verdict: ${verdictName(code)} (exit ${code})`);
  if (code === EXIT.UNSAFE) {
    lines.push("  DO NOT RUN — environment is unsafe or mutation is prohibited here.");
  } else if (code === EXIT.BLOCKED) {
    lines.push(
      `  DO NOT RUN — required capability missing: ${missingRequired.map((r) => r.id).join(", ")}`,
    );
  } else if (code === EXIT.DEGRADED) {
    lines.push(
      `  READ-ONLY OK — optional evidence missing: ${missingOptional.map((r) => r.id).join(", ")}`,
    );
    lines.push("  Pages needing that evidence will report BLOCKED, not PASS.");
  } else {
    lines.push("  READY — all required and optional capabilities present.");
  }
  return lines.join("\n");
}

/**
 * Environment safety. Anything that smells like production is UNSAFE, and the
 * check is deliberately paranoid: an unknown environment is NOT treated as
 * safe, because the cost of guessing wrong is mutating real data.
 */
export function checkEnvSafety(env = {}, { mutating = false } = {}) {
  const host = String(env.PHX_HOST || "");
  const mix = String(env.MIX_ENV || "");
  const api = String(env.ONE_API_URL || "");
  const prodish = /prod|production/i;
  if (prodish.test(host) || prodish.test(mix) || prodish.test(api)) {
    return row("env_safety", STATE.UNSAFE, "target looks production-like (PHX_HOST/MIX_ENV/ONE_API_URL)");
  }
  if (!mix) {
    return row(
      "env_safety",
      mutating ? STATE.UNSAFE : STATE.MISSING,
      "MIX_ENV unset — environment unproven; mutation prohibited",
    );
  }
  if (mix === "dev" || mix === "test") {
    return row("env_safety", STATE.OK, `MIX_ENV=${mix}`);
  }
  return row("env_safety", STATE.UNSAFE, `MIX_ENV=${mix} is not dev/test`);
}

/**
 * Credentials for every configured role. Reports resolution only — never the
 * secret, and never its length.
 */
export function checkCredentials(roleEnvPrefixes = [], env = {}) {
  if (!roleEnvPrefixes.length) return row("credentials", STATE.SKIP, "no roles configured");
  const detail = [];
  let missing = 0;
  for (const prefix of roleEnvPrefixes) {
    const email = redact(env[`${prefix}_EMAIL`]);
    const password = redact(env[`${prefix}_PASSWORD`]);
    const ok = email.resolved && password.resolved;
    if (!ok) missing += 1;
    detail.push(`${prefix}:${ok ? "set" : "unset"}`);
  }
  return row(
    "credentials",
    missing === 0 ? STATE.OK : STATE.MISSING,
    detail.join(" "),
    { evidence: { roles: roleEnvPrefixes.length, unresolved: missing } },
  );
}

/** Disk headroom — a walk that fills the disk corrupts its own evidence. */
export function checkDisk(freeBytes, { minBytes = 512 * 1024 * 1024 } = {}) {
  if (!Number.isFinite(freeBytes)) return row("disk", STATE.MISSING, "free space unknown");
  const mb = Math.round(freeBytes / 1048576);
  return freeBytes >= minBytes
    ? row("disk", STATE.OK, `${mb} MB free`)
    : row("disk", STATE.BLOCKED, `${mb} MB free < ${Math.round(minBytes / 1048576)} MB required`);
}

/** Leaked sessions from a previous run inflate/poison the next one. */
export function checkLeakedSessions(count) {
  if (!Number.isFinite(count)) return row("leaked_sessions", STATE.MISSING, "could not enumerate");
  return count === 0
    ? row("leaked_sessions", STATE.OK, "none")
    : row("leaked_sessions", STATE.MISSING, `${count} leaked session(s) — close before running`);
}
