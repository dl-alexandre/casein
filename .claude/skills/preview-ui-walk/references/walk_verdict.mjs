// Pure page-verdict helpers for preview-ui-walk (no browser / no Tidewave).
// Import from playwright_walk.mjs and selftest.mjs so the decision tree is
// fixture-tested — taxonomy regressions hide in (mainStatus × URL × steps).

/**
 * Classify page outcome. Auth/access failures must never look identical to
 * wrong credentials or a generic FAIL — taxonomy is the UAT signal.
 *
 *   PASS | PASS_SLOW | SKIPPED | BOUNCED | CRASHED | RUNTIME_ERROR |
 *   ASSERT_FAILED | TIMEOUT | FAIL
 *
 * Order matters:
 *   1. SKIPPED — interactions gate (not bad credentials)
 *   2. CRASHED — HTTP 5xx from main document (independent of Tidewave)
 *   3. BOUNCED — wrong known route
 *   4. 4xx / TIMEOUT
 *   5. RUNTIME_ERROR — server error logs / probes / SQL (real bug signal)
 *   6. ASSERT_FAILED — content steps or browser console/network
 *   7. PASS_SLOW / PASS
 *
 * Tidewave only *enriches* CRASHED with exception frames; it never decides
 * the status. A 500 with tidewave down is still CRASHED (no frame).
 *
 * RUNTIME_ERROR vs ASSERT_FAILED: a server error-log delta (e.g. 70 logged
 * errors on pens-dm-alert) must not share a verdict with a missing h1 assert.
 * CI gates hard-fail both by default; the distinct status is the triage signal.
 */
export function pageVerdict({
  loaded,
  within,
  uok,
  mainStatus,
  landed,
  wantPath,
  bounceHit,
  actionableConsole,
  actionableNetwork,
  evidenceFailed,
  runtimeErrors,
  stepsFailed,
  stepsBlockedOnly,
  stepsBlocked,
  navOutcome,
}) {
  // Interactions gate blocked required mutating steps (e.g. login fill/click).
  if (stepsBlockedOnly && stepsBlocked) {
    return {
      status: "SKIPPED",
      reason: stepsBlocked.message || `interactions blocked: ${stepsBlocked.reason}`,
    };
  }

  // 5xx before bounce/timeout — crash is definitive even if the SPA then
  // navigates to /login or an error shell. Does not require Tidewave.
  if (mainStatus != null && mainStatus >= 500) {
    return { status: "CRASHED", reason: `HTTP ${mainStatus}` };
  }

  // Known-route bounce only (not every wrong URL — those are TIMEOUT/FAIL).
  if (bounceHit || navOutcome === "bounce") {
    return {
      status: "BOUNCED",
      reason: `expected ${wantPath}, landed ${landed || "?"}${
        bounceHit ? ` (known route ${bounceHit})` : ""
      }`,
    };
  }

  if (mainStatus != null && mainStatus >= 400) {
    return { status: "FAIL", reason: `HTTP ${mainStatus}` };
  }

  // Navigation never reached lands_on and did not stabilize on a known bounce.
  if (!loaded || navOutcome === "timeout" || uok === false) {
    // Slow success: settle finished on the right URL after the wait timed out.
    if (uok === true) {
      /* fall through to content checks */
    } else {
      return {
        status: "TIMEOUT",
        reason: `did not land on ${wantPath} within budget (landed ${landed || "?"})`,
      };
    }
  }

  // Server-side evidence (error logs / probes / SQL) — not content asserts.
  const rtN =
    runtimeErrors != null
      ? runtimeErrors
      : evidenceFailed != null
        ? evidenceFailed
        : 0;
  if (rtN > 0) {
    return {
      status: "RUNTIME_ERROR",
      reason:
        runtimeErrors != null
          ? `runtime evidence failed (server errors/probes/sql: ${rtN})`
          : "runtime evidence failed (logs/probes/sql)",
    };
  }

  if (stepsFailed > 0) {
    return { status: "ASSERT_FAILED", reason: `${stepsFailed} step(s) failed` };
  }
  if ((actionableConsole && actionableConsole.length) || (actionableNetwork && actionableNetwork.length)) {
    return {
      status: "ASSERT_FAILED",
      reason: `browser errors console=${(actionableConsole || []).length} network=${(actionableNetwork || []).length}`,
    };
  }

  // Slow but correct landing — not the same as FAIL.
  if (!within && uok !== false) {
    return { status: "PASS_SLOW", reason: "landed correctly but exceeded budget_ms" };
  }

  return { status: "PASS", reason: null };
}

export function isPassingStatus(status) {
  return status === "PASS" || status === "PASS_SLOW";
}

/**
 * Exit-code hard-fail set.
 *
 * Access-gating bounces (e.g. resource → /dashboard) are often expected on
 * role sweeps — they must not collapse the richer taxonomy back to flat red.
 * Auth bounces (→ /login) always hard-fail. Opt into `--strict-access` to
 * hard-fail every BOUNCED.
 */
export function isHardFailStatus(status, row = {}, { strictAccess = false } = {}) {
  if (isPassingStatus(status)) return false;
  if (status === "BOUNCED") {
    if (strictAccess) return true;
    if (isAuthBounce(row)) return true;
    return false;
  }
  // CRASHED, RUNTIME_ERROR, ASSERT_FAILED, TIMEOUT, FAIL, SKIPPED, unknown
  return true;
}

export function isAuthBounce(row = {}) {
  const bounce = String(row.bounce || "");
  const landed = String(row.landed || "");
  let path = landed;
  try {
    path = new URL(landed).pathname;
  } catch {
    /* keep */
  }
  return isAuthBouncePath(bounce || path);
}

/** True when a path/URL looks like an unauthenticated sink. */
export function isAuthBouncePath(pathOrUrl) {
  let path = String(pathOrUrl || "");
  try {
    if (path.includes("://")) path = new URL(path).pathname;
  } catch {
    /* keep */
  }
  const authSinks = ["/login", "/sign_in", "/signin", "/users/log_in", "/session/new"];
  return authSinks.some((s) => path === s || path.startsWith(s + "/") || path.includes(s));
}

/**
 * Patterns that mean a real server bug in error-log lines (not every [error] line).
 * Benign auth-fallback / deprecation noise is excluded so RUNTIME_ERROR stays
 * gate-worthy.
 */
export const SIGNIFICANT_ERROR_RE =
  /\*\*\s*\(|\b(KeyError|FunctionClauseError|ArgumentError|UndefinedFunctionError|RuntimeError|ArithmeticError|MatchError|CaseClauseError|Protocol\.UndefinedError|Ecto\.|Postgrex|DBConnection|GenServer|CRASH REPORT|error gen_server|EXIT|noproc|timeout_value)\b/i;

export const BENIGN_ERROR_RE =
  /auth falls to local|falls? back to local|expected login|DeprecationWarning|phoenix_live_reload|LiveReloader|webpack|esbuild|file_system|watching directories|recompiling|compiling|warning:\s*the\s+protocol|CORS|favicon\.ico/i;

/**
 * Count *significant* error-log lines (and optional probe/sql failures).
 * Warning-level deltas never contribute. Empty samples with a raw error count
 * still count when count > 0 and we have no samples to filter (conservative
 * only when samples exist — if samples present, only significant ones count).
 */
export function countRuntimeErrors(runtimePage = {}) {
  let n = 0;
  const errLevel = runtimePage?.logs?.levels?.error || {};
  const samples = errLevel.samples || [];
  const rawCount = errLevel.count ?? runtimePage.error_log_count ?? 0;

  if (samples.length) {
    n += samples.filter(isSignificantErrorLine).length;
  } else if (rawCount > 0) {
    // No samples to filter — treat non-zero error delta as signal (old behaviour
    // was any error log). Prefer samples when Tidewave provides them.
    n += rawCount > 0 ? 1 : 0;
  }

  n += runtimePage.probes_failed || 0;
  if (runtimePage.sql?.status === "FAIL") n += 1;
  // evidence_failed is probes+sql only in runtime_evidence; avoid double-count
  // if caller already summed it without log significance.
  return n;
}

export function isSignificantErrorLine(line) {
  const s = String(line || "");
  if (!s.trim()) return false;
  if (BENIGN_ERROR_RE.test(s)) return false;
  if (SIGNIFICANT_ERROR_RE.test(s)) return true;
  // Generic Logger.error with stack-ish path:line still counts
  if (/\.ex:\d+/.test(s) && /\[error\]|error/i.test(s)) return true;
  return false;
}

/**
 * Default app-source prefixes for exception frame preference.
 * Override via runtime.app_frame_prefixes or WALK_APP_FRAME_PREFIXES (comma-sep).
 */
export function defaultAppFramePrefixes(runtimeCfg = {}) {
  if (Array.isArray(runtimeCfg.app_frame_prefixes) && runtimeCfg.app_frame_prefixes.length) {
    return runtimeCfg.app_frame_prefixes.map(String);
  }
  const env = process.env.WALK_APP_FRAME_PREFIXES;
  if (env && env.trim()) {
    return env.split(",").map((s) => s.trim()).filter(Boolean);
  }
  // Most-specific first. Do NOT include bare "lib/" — it matches
  // phoenix_live_view/lib/…/static.ex and hides the app frame.
  return ["lib/one_web/", "lib/one/"];
}

/**
 * Pull a short exception + preferred *app* frame from Tidewave error-log samples.
 * Prefers first frame under app_frame_prefixes (e.g. lib/one_web/…_live.ex:57)
 * over framework frames (static.ex, phoenix/…).
 */
export function extractExceptionFromLogs(runtimePage, opts = {}) {
  const samples = runtimePage?.logs?.levels?.error?.samples || [];
  if (!samples.length) return null;
  const joined = samples.join("\n");
  const prefixes = opts.appFramePrefixes || defaultAppFramePrefixes(opts.runtimeCfg || {});

  const ex =
    joined.match(/\*\*\s*\(([A-Za-z.]+)\)\s*([^\n]+)/) ||
    joined.match(
      /\b((?:Postgrex|Ecto|RuntimeError|ArgumentError|KeyError|FunctionClauseError)[^\n]*)/,
    );

  const frameMatches = [
    ...joined.matchAll(/\((?:file\s+)?([^)]+\.exs?:\d+)\)/g),
    ...joined.matchAll(/([A-Za-z0-9_./]+\.ex:\d+)/g),
  ].map((m) => m[1] || m[0]);

  const uniq = [];
  for (const f of frameMatches) {
    const clean = String(f).replace(/^\(|\)$/g, "");
    if (!uniq.includes(clean)) uniq.push(clean);
  }

  const isFramework = (f) =>
    /phoenix|plug|bandit|cowboy|ecto\/|db_connection|elixir\/|telemetry|mint\/|finch\//i.test(
      f,
    );

  // Prefer: configured app prefix → *_live.ex → non-framework → first
  let frame =
    uniq.find((f) => prefixes.some((p) => f.includes(p))) ||
    uniq.find((f) => /_live\.ex:\d+/i.test(f) && !isFramework(f)) ||
    uniq.find((f) => !isFramework(f)) ||
    uniq[0] ||
    null;

  if (!ex && !frame) {
    const first = samples.find((s) => String(s).trim() && isSignificantErrorLine(s));
    return first ? { summary: String(first).slice(0, 240) } : null;
  }
  return {
    exception: ex
      ? (ex[1] && ex[2] ? `${ex[1]}: ${ex[2].trim()}` : ex[0]).slice(0, 240)
      : null,
    frame: frame ? String(frame).slice(0, 120) : null,
    summary: [ex && (ex[0] || "").trim(), frame]
      .filter(Boolean)
      .join(" @ ")
      .slice(0, 280),
  };
}

/**
 * Human-readable bounce reason from LiveView assigns / flash (when Tidewave
 * captured them). Turns "BOUNCED → /dashboard" into "unauthorized: missing :areas".
 */
export function extractBounceReason(runtimePage) {
  const lvs = runtimePage?.liveview?.liveviews || [];
  if (!lvs.length) return null;

  const reasons = [];
  for (const lv of lvs) {
    const fields = lv.fields || {};
    const keys = lv.assign_keys || [];

    // Prefer explicit flash fields
    for (const key of ["flash", "flash.error", "flash.info", "flash_error", "flash_info"]) {
      const v = fields[key];
      if (v == null || v === "" || v === "%{}") continue;
      const s = stringifyFlash(v);
      if (s) reasons.push(s);
    }

    // Common halt / auth assign keys (stringified)
    for (const key of Object.keys(fields)) {
      if (/halt|unauthorized|forbidden|error_message|auth_error|access/i.test(key)) {
        const s = stringifyFlash(fields[key]);
        if (s) reasons.push(`${key}: ${s}`);
      }
    }

    // Hint from assign keys alone when flash empty
    if (!reasons.length && keys.length) {
      const hintKeys = keys.filter((k) =>
        /flash|unauthorized|permission|role|areas|scopes|access/i.test(String(k)),
      );
      if (hintKeys.length) {
        reasons.push(`assigns hint: ${hintKeys.slice(0, 6).join(", ")}`);
      }
    }
  }

  if (!reasons.length) return null;
  // de-dupe
  const uniq = [...new Set(reasons.map((r) => String(r).slice(0, 200)))];
  return uniq.join(" · ").slice(0, 320);
}

function stringifyFlash(v) {
  if (v == null) return null;
  if (typeof v === "string") {
    const t = v.trim();
    if (!t || t === "%{}" || t === "nil") return null;
    return t.slice(0, 200);
  }
  if (typeof v === "object") {
    try {
      const s = JSON.stringify(v);
      if (s === "{}" || s === "null") return null;
      return s.slice(0, 200);
    } catch {
      return String(v).slice(0, 200);
    }
  }
  return String(v).slice(0, 200);
}

/** Default LiveView fields pulled for bounce diagnostics (non-PII, small). */
export const BOUNCE_DIAG_FIELDS = [
  "flash",
  "page_title",
  "live_action",
  "current_path",
];

export function statusColor(status) {
  switch (status) {
    case "PASS":
    case "PASS_SLOW":
      return "#2ea043";
    case "SKIPPED":
    case "BOUNCED":
    case "TIMEOUT":
      return "#d29922";
    case "CRASHED":
    case "RUNTIME_ERROR":
    case "ASSERT_FAILED":
    case "FAIL":
    default:
      return "#f85149";
  }
}

/** Minimal synthetic input for fixture tests. */
export function verdictFixture(overrides = {}) {
  return pageVerdict({
    loaded: true,
    within: true,
    uok: true,
    mainStatus: 200,
    landed: "http://127.0.0.1/admin",
    wantPath: "/admin",
    bounceHit: null,
    actionableConsole: [],
    actionableNetwork: [],
    evidenceFailed: 0,
    runtimeErrors: 0,
    stepsFailed: 0,
    stepsBlockedOnly: false,
    stepsBlocked: null,
    navOutcome: "ok",
    ...overrides,
  });
}
