// Pure page-verdict helpers for preview-ui-walk (no browser / no Tidewave).
// Import from playwright_walk.mjs and selftest.mjs so the decision tree is
// fixture-tested — taxonomy regressions hide in (mainStatus × URL × steps).

/**
 * Classify page outcome. Auth/access failures must never look identical to
 * wrong credentials or a generic FAIL — taxonomy is the UAT signal.
 *
 *   PASS | PASS_SLOW | SLOW | SKIPPED | BOUNCED | CRASHED | RUNTIME_ERROR |
 *   ASSERT_FAILED | TIMEOUT | FAIL
 *
 * Order matters:
 *   1. SKIPPED — interactions gate (not bad credentials)
 *   2. CRASHED — HTTP 5xx from main document (independent of Tidewave)
 *   3. BOUNCED — wrong known route
 *   4. 4xx / TIMEOUT
 *   5. BLOCKED — required visual evidence could not be compared (fail closed,
 *      BEFORE assertions: missing evidence must never be outrun by a green)
 *   6. RUNTIME_ERROR — server error logs / probes / SQL (real bug signal)
 *   7. ASSERT_FAILED — content steps, browser console/network, or a visual
 *      baseline mismatch (changed pixels / dimensions / DPR)
 *   8. PASS_SLOW / PASS
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
  visualBlocked,
  visualFailed,
  evidenceBlocked,
  cleanupFailed,
  liveViewFailure,
  slowIsFailure = false,
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

  // Required evidence that could not be collected (api/downloads/cleanup via
  // evidenceGuard): BLOCKED before any assertion outcome, so "collector
  // produced nothing" can never read as green.
  if (evidenceBlocked) {
    return {
      status: "BLOCKED",
      reason: evidenceBlocked.reason || "required evidence unavailable",
      missingEvidence: evidenceBlocked.missingEvidence || [],
    };
  }

  // Required visual evidence that could not be compared: BLOCKED before any
  // assertion outcome, so "no baseline / store down" can never read as green.
  if (visualBlocked) {
    return {
      status: "BLOCKED",
      reason: visualBlocked.reason || "required evidence unavailable: visual_baseline",
      missingEvidence: ["visual_baseline"],
    };
  }

  // A LiveView can return an intact 200 SSR document, then crash while the
  // websocket mounts. Content assertions against the stale SSR DOM are not a
  // pass: the user sees Phoenix's reconnect/error state and has no live page.
  if (liveViewFailure) {
    return {
      status: "RUNTIME_ERROR",
      reason: liveViewFailure.reason || "LiveView client failed to connect",
    };
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
  // Visual baseline mismatch (pixels beyond threshold, or dimension/DPR drift)
  // is an assertion loss, same family as a failed content step.
  if (visualFailed) {
    return {
      status: "ASSERT_FAILED",
      reason: visualFailed.reason || "visual baseline mismatch",
    };
  }
  // A cleanup step that ran and lost means fixtures may be left behind — an
  // assertion loss even when the page itself rendered fine.
  if (cleanupFailed) {
    return {
      status: "ASSERT_FAILED",
      reason: cleanupFailed.reason || "cleanup failed",
    };
  }
  if ((actionableConsole && actionableConsole.length) || (actionableNetwork && actionableNetwork.length)) {
    return {
      status: "ASSERT_FAILED",
      reason: `browser errors console=${(actionableConsole || []).length} network=${(actionableNetwork || []).length}`,
    };
  }

  // Slow but correct landing — not the same as FAIL.
  if (!within && uok !== false) {
    return {
      status: slowIsFailure ? "SLOW" : "PASS_SLOW",
      reason: "landed correctly but exceeded readiness budget_ms",
    };
  }

  return { status: "PASS", reason: null };
}

export function isPassingStatus(status) {
  return status === "PASS" || status === "PASS_SLOW";
}

/**
 * Turn the browser's `[data-phx-main]` state into a page-verdict signal.
 * Non-LiveView pages have no such root and remain valid walk targets.
 */
export function liveViewClientFailure(state) {
  if (!state || state.present !== true) return null;
  const errorClasses = Array.isArray(state.error_classes) ? state.error_classes : [];
  if (errorClasses.length > 0) {
    return {
      reason: `LiveView client entered error state (${errorClasses.join(", ")})`,
    };
  }
  if (state.connected !== true) {
    return { reason: "LiveView client did not connect" };
  }
  if (state.loading === true) {
    return { reason: "LiveView client remained in loading state" };
  }
  return null;
}

/**
 * Normalized result classes — the four states a *consumer* (report, gate,
 * dashboard, product README) is allowed to reason about.
 *
 * The richer diagnostic statuses above are NOT replaced: every row keeps its
 * `status` (BOUNCED / RUNTIME_ERROR / ASSERT_FAILED / …) for triage, and gains
 * a `resultClass` for reporting. Collapsing straight to red/green was the old
 * failure mode — a missing precondition looked identical to a real defect, and
 * a page that was never exercised looked identical to a pass.
 */
export const RESULT_CLASSES = ["PASS", "FAILED", "BLOCKED", "NOT_TESTED"];

/**
 * Diagnostic status for the one action outcome the page-level taxonomy has no
 * word for: a mutation landed and the verification that was supposed to prove
 * it never produced an answer.
 *
 * It is not BLOCKED (something DID happen), not FAILED (no assertion ran and
 * lost), not PASS, and not NOT_TESTED. Left unnamed it collapses into one of
 * those and the operator loses the only signal that says "data was changed and
 * nobody knows into what" — which on a shared dataset also silently becomes the
 * next run's precondition.
 *
 * It is a STATUS, not a fifth RESULT_CLASS: consumers still see BLOCKED
 * ("nothing was proved"), so no dashboard or gate needs to learn a new class.
 */
export const MUTATED_UNVERIFIED = "MUTATED_UNVERIFIED";

/**
 * BLOCKED is a first-class *diagnostic* status too: it means a precondition or
 * required evidence was unavailable, so the assertion never got to run. It is
 * distinct from FAILED (the assertion ran and lost) and from NOT_TESTED (we
 * deliberately did not run it).
 */
export function isBlockedStatus(status) {
  return status === "BLOCKED";
}

/**
 * Map a diagnostic status to its normalized class.
 *
 *   PASS, PASS_SLOW                      -> PASS
 *   BLOCKED                              -> BLOCKED
 *   SKIPPED (interactions gate)          -> NOT_TESTED
 *   BOUNCED that is *not* a hard fail    -> NOT_TESTED
 *   everything else                      -> FAILED
 *
 * The tolerated-BOUNCED case is why NOT_TESTED exists rather than folding into
 * PASS or FAILED: an access-gated page never landed, so its assertions were
 * never exercised. Calling that PASS would be a false green; calling it FAILED
 * would flatten the taxonomy that `isHardFailStatus` deliberately preserves for
 * role sweeps. The diagnostic status stays BOUNCED either way.
 */
export function resultClass(status, row = {}, opts = {}) {
  if (status === MUTATED_UNVERIFIED) return "BLOCKED";
  if (isBlockedStatus(status)) return "BLOCKED";
  if (isPassingStatus(status)) return "PASS";
  if (status === "SKIPPED") return "NOT_TESTED";
  if (status === "BOUNCED" && !isHardFailStatus(status, row, opts)) return "NOT_TESTED";
  return "FAILED";
}

/**
 * Fail-closed evidence guard. When a manifest *requires* a collector (HAR,
 * a11y, DB before/after, audit actor, cleanup verification, …) and the
 * collector could not produce evidence, the page must not silently pass.
 *
 * Returns a BLOCKED verdict naming the missing evidence, or null when
 * everything required is present. Callers fold the result into `pageVerdict`
 * BEFORE any assertion runs, so "evidence unavailable" can never be reported
 * as green.
 *
 *   requiredEvidence: ["har", "a11y"]  (from the manifest)
 *   collected:        { har: {...}, a11y: null }
 *   -> { status: "BLOCKED", reason: "required evidence unavailable: a11y" }
 */
export function evidenceGuard(requiredEvidence, collected = {}) {
  const required = Array.isArray(requiredEvidence) ? requiredEvidence : [];
  if (required.length === 0) return null;
  const missing = required.filter((key) => {
    const value = collected?.[key];
    if (value == null || value === false) return true;
    if (Array.isArray(value)) return value.length === 0;
    if (typeof value === "object") return Object.keys(value).length === 0;
    return false;
  });
  if (missing.length === 0) return null;
  return {
    status: "BLOCKED",
    reason: `required evidence unavailable: ${missing.join(", ")}`,
    missingEvidence: missing,
  };
}

/**
 * Fold a v2 action's phase rows into ONE verdict.
 *
 * An action is a sequence of navigations sharing a browser context, a carried
 * state bag, and a single outcome — the unit that maps to one tracker issue.
 * Folding is where the taxonomy earns its keep, because the interesting cases
 * are asymmetric: the SAME phase status means different things depending on
 * whether a mutation has already landed.
 *
 *   any phase FAILED (not TIMEOUT)          -> FAILED
 *   BLOCKED/TIMEOUT, nothing mutated yet    -> BLOCKED / FAILED (v1 semantics)
 *   BLOCKED/TIMEOUT, a mutation landed      -> MUTATED_UNVERIFIED
 *   every phase passed                      -> PASS
 *
 * The fold is derived from facts (did a mutating phase execute), never from a
 * declared phase role: a label like role:"verify" can be mis-set by whoever
 * writes the manifest, and the dangerous state is exactly the one you cannot
 * afford to have mis-labelled.
 *
 * Conservative on "did it mutate": a mutating phase that was ATTEMPTED counts,
 * even if it then failed, because a half-applied mutation is indistinguishable
 * from an unapplied one at this layer. Only SKIPPED (the interactions gate
 * refused it) proves nothing ran.
 *
 * @param phases rows in execution order: { status, mutating, name }
 * @returns { status, reason, mutated, cleanupRequired, phaseIndex, phase }
 */
export function actionVerdict(phases = [], opts = {}) {
  const list = Array.isArray(phases) ? phases : [];
  if (list.length === 0) {
    return {
      status: "BLOCKED",
      reason: "action ran no phases",
      mutated: false,
      cleanupRequired: false,
      phaseIndex: -1,
      phase: null,
    };
  }

  let mutated = false;
  for (let i = 0; i < list.length; i += 1) {
    const phase = list[i] || {};
    const status = phase.status;
    // SKIPPED means the interactions gate refused the step, so nothing ran.
    if (phase.mutating === true && status !== "SKIPPED") mutated = true;

    const cls = resultClass(status, phase, opts);
    if (cls === "PASS" || cls === "NOT_TESTED") continue;

    const at = { phaseIndex: i, phase: phase.name || `phase ${i + 1}`, mutated };
    const label = at.phase;

    // Unproven outcomes: nothing answered the question.
    if (status === "BLOCKED" || status === "TIMEOUT" || status === MUTATED_UNVERIFIED) {
      if (mutated) {
        return {
          ...at,
          status: MUTATED_UNVERIFIED,
          reason:
            `mutation landed, then "${label}" returned ${status} — the change was ` +
            `applied but never verified; fixtures may be left behind`,
          cleanupRequired: true,
        };
      }
      // Nothing mutated: keep v1 semantics exactly (TIMEOUT stays a failure).
      return {
        ...at,
        status: status === "TIMEOUT" ? "TIMEOUT" : "BLOCKED",
        reason: `"${label}" returned ${status} before anything was changed`,
        cleanupRequired: false,
      };
    }

    // An assertion ran and lost. This outranks MUTATED_UNVERIFIED: a concrete
    // failed assertion is more actionable than "could not verify" — but if a
    // mutation landed first, cleanup is still owed.
    return {
      ...at,
      status: status || "FAIL",
      reason: `"${label}" returned ${status}`,
      cleanupRequired: mutated,
    };
  }

  return {
    status: "PASS",
    reason: "",
    mutated,
    cleanupRequired: mutated,
    phaseIndex: -1,
    phase: null,
  };
}

/**
 * Settle the check-then-act race on a shared dataset.
 *
 * Prerequisites are evaluated before phase 1 and re-evaluated after any action
 * failure. If a predicate held before and does not hold after, the app was
 * probably not at fault — another session or a human consumed the record
 * mid-run.
 *
 * CRITICAL asymmetry: this reclassification only applies when the action did
 * NOT mutate. If the action changed data, the action ITSELF is a candidate
 * cause of the precondition delta, and silently rewriting FAILED to BLOCKED
 * would hide real defects behind our own side effects. For mutating actions the
 * delta is recorded as `preconditionDelta` for triage and the status is left
 * exactly as the fold decided.
 *
 * @param verdict output of actionVerdict
 * @param before/after arrays of { name, ok }
 */
export function reclassifyPreconditionLost(verdict, before = [], after = []) {
  if (!verdict || resultClass(verdict.status, verdict) === "PASS") return verdict;

  const held = new Map((Array.isArray(before) ? before : []).map((p) => [p?.name, p?.ok === true]));
  const lost = (Array.isArray(after) ? after : [])
    .filter((p) => held.get(p?.name) === true && p?.ok !== true)
    .map((p) => p.name);

  if (lost.length === 0) return verdict;
  if (verdict.mutated) {
    // Our own writes could explain this. Surface it; never act on it.
    return { ...verdict, preconditionDelta: lost };
  }
  return {
    ...verdict,
    status: "BLOCKED",
    reason: `precondition_lost: ${lost.join(", ")} held before the action and not after`,
    preconditionLost: lost,
    preconditionDelta: lost,
  };
}

/**
 * Exit-code hard-fail set.
 *
 * Access-gating bounces (e.g. resource → /dashboard) are often expected on
 * role sweeps — they must not collapse the richer taxonomy back to flat red.
 * Auth bounces (→ /login) always hard-fail. Opt into `--strict-access` to
 * hard-fail every BOUNCED.
 *
 * RUNTIME_ERROR hard-fails by default (a 200-but-server-errored page is a real
 * bug). Opt out with `--soft-runtime-error` (`failRuntimeError:false`) to treat
 * it as informational — e.g. sweeping a backend with known-noisy logs — while
 * CRASHED and the rest still fail.
 */
export function isHardFailStatus(
  status,
  row = {},
  { strictAccess = false, failRuntimeError = true, failBlocked = true } = {},
) {
  if (isPassingStatus(status)) return false;
  // A mutation landed and could not be verified. Deliberately NOT downgradable
  // by --soft-blocked: on a shared dataset this is the one state that also
  // corrupts the NEXT run's preconditions, so an exploratory run is exactly
  // when you least want it hidden.
  if (status === MUTATED_UNVERIFIED) return true;
  // FAIL CLOSED: missing required evidence hard-fails by default. A walk that
  // could not collect what it was told to collect has not proved anything, so
  // it must not exit green. `failBlocked:false` (--soft-blocked) downgrades it
  // to informational for exploratory runs only.
  if (isBlockedStatus(status)) return failBlocked;
  if (status === "BOUNCED") {
    if (strictAccess) return true;
    if (isAuthBounce(row)) return true;
    return false;
  }
  if (status === "RUNTIME_ERROR" && !failRuntimeError) return false;
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
/**
 * Canonicalize an error-log line so repeated instances of the *same* bug collapse
 * to one. Strips volatile request/correlation ids, timestamps, pids, durations,
 * and hex addresses. Used to deduplicate the RUNTIME_ERROR evidence count so a
 * KeyError that logs 70×/page reads as "1 unique (70 total)", not "70 errors".
 */
export function normalizeErrorLine(line) {
  return String(line || "")
    .replace(/\b(request_id|correlation_id|pid|conn|ref)=\S+/gi, "$1=·")
    .replace(/\b\d{2}:\d{2}:\d{2}(\.\d+)?\b/g, "·") // timestamps
    .replace(/#PID<[^>]+>|<0\.\d+\.\d+>/g, "#PID<·>") // erlang pids
    .replace(/0x[0-9a-f]+/gi, "0x·") // hex addrs
    .replace(/\b\d+(\.\d+)?(ms|µs|us|s)\b/g, "·") // durations
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Deduplicated RUNTIME_ERROR evidence: unique significant error signatures plus
 * total occurrences and one concise sample. `count` (unique) is what the gate and
 * report use; `total` is preserved for context.
 */
export function runtimeErrorEvidence(runtimePage = {}) {
  const errLevel = runtimePage?.logs?.levels?.error || {};
  const samples = errLevel.samples || [];
  const rawCount = errLevel.count ?? runtimePage.error_log_count ?? 0;

  let unique = 0;
  let total = 0;
  let sample = null;
  if (samples.length) {
    const significant = samples.filter(isSignificantErrorLine);
    total = significant.length;
    const seen = new Set();
    for (const line of significant) {
      const key = normalizeErrorLine(line);
      if (!seen.has(key)) {
        seen.add(key);
        if (sample == null) sample = String(line).slice(0, 240);
      }
    }
    unique = seen.size;
  } else if (rawCount > 0) {
    // No samples to filter — a non-zero error delta is one signal (Tidewave
    // didn't provide lines to dedup against).
    unique = 1;
    total = rawCount;
  }

  const probes = runtimePage.probes_failed || 0;
  const sqlFail = runtimePage.sql?.status === "FAIL" ? 1 : 0;
  const liveviewFail =
    runtimePage.required_tidewave === true && runtimePage.liveview?.status === "error" ? 1 : 0;
  return {
    count: unique + probes + sqlFail + liveviewFail, // gate/verdict signal (deduped)
    unique,
    total,
    probes_failed: probes,
    sql_failed: sqlFail,
    liveview_failed: liveviewFail,
    sample,
  };
}

/**
 * Count *significant, deduplicated* error signals for the RUNTIME_ERROR gate.
 * Warning-level deltas never contribute (only `logs.levels.error`). Repeated
 * identical entries collapse to one via `normalizeErrorLine`. Probe/SQL failures
 * each add one.
 */
export function countRuntimeErrors(runtimePage = {}) {
  return runtimeErrorEvidence(runtimePage).count;
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
 * Normalize an app-frame-prefix config value to a non-empty string array.
 * Accepts a bare string ("lib/one_web/"), a comma-separated string, or an
 * ordered list (["lib/one_web/", "lib/one/"]). Returns [] for empty/absent.
 */
export function normalizeAppFramePrefixes(value) {
  if (value == null) return [];
  const list = Array.isArray(value)
    ? value
    : String(value).split(",");
  return list.map((s) => String(s).trim()).filter(Boolean);
}

/**
 * Default app-source prefixes for exception frame preference. Config precedence:
 * manifest `runtime.app_frame_prefix` (string | ordered list) → the plural
 * `app_frame_prefixes` alias → `WALK_APP_FRAME_PREFIXES` env (comma-sep) →
 * built-in default. First matching frame wins; callers fall back to the existing
 * frame heuristic when none match.
 */
export function defaultAppFramePrefixes(runtimeCfg = {}) {
  const fromCfg = normalizeAppFramePrefixes(
    runtimeCfg.app_frame_prefix ?? runtimeCfg.app_frame_prefixes,
  );
  if (fromCfg.length) return fromCfg;
  const fromEnv = normalizeAppFramePrefixes(process.env.WALK_APP_FRAME_PREFIXES);
  if (fromEnv.length) return fromEnv;
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
    // BLOCKED reads as "could not prove", visually distinct from both green and
    // red so a reader never mistakes missing evidence for either.
    case "BLOCKED":
      return "#8957e5";
    // Distinct from BLOCKED's purple: this one says "we changed data and cannot
    // prove what happened", which is a different call to action (go clean up).
    case MUTATED_UNVERIFIED:
      return "#db6d28";
    case "CRASHED":
    case "RUNTIME_ERROR":
    case "ASSERT_FAILED":
    case "FAIL":
    default:
      return "#f85149";
  }
}

/** Minimal synthetic phase row for action-fold fixture tests. */
export function phaseFixture(status = "PASS", overrides = {}) {
  return { name: `phase-${status}`, status, mutating: false, ...overrides };
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
