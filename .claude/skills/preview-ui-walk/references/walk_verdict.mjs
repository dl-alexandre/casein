// Pure page-verdict helpers for preview-ui-walk (no browser / no Tidewave).
// Import from playwright_walk.mjs and selftest.mjs so the decision tree is
// fixture-tested — taxonomy regressions hide in (mainStatus × URL × steps).

/**
 * Classify page outcome. Auth/access failures must never look identical to
 * wrong credentials or a generic FAIL — taxonomy is the UAT signal.
 *
 *   PASS | PASS_SLOW | SKIPPED | BOUNCED | CRASHED | ASSERT_FAILED | TIMEOUT | FAIL
 *
 * Order matters:
 *   1. SKIPPED — interactions gate (not bad credentials)
 *   2. CRASHED — HTTP 5xx from main document (independent of Tidewave)
 *   3. BOUNCED — wrong known route
 *   4. 4xx / TIMEOUT / ASSERT_FAILED
 *   5. PASS_SLOW / PASS
 *
 * Tidewave only *enriches* CRASHED with exception frames; it never decides
 * the status. A 500 with tidewave down is still CRASHED (no frame).
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

  if (stepsFailed > 0) {
    return { status: "ASSERT_FAILED", reason: `${stepsFailed} step(s) failed` };
  }
  if (evidenceFailed > 0) {
    return { status: "ASSERT_FAILED", reason: "runtime evidence failed (logs/probes/sql)" };
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
  // CRASHED, ASSERT_FAILED, TIMEOUT, FAIL, SKIPPED, unknown
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
  const authSinks = ["/login", "/sign_in", "/signin", "/users/log_in", "/session/new"];
  const hit = bounce || path;
  return authSinks.some((s) => hit === s || hit.startsWith(s + "/") || hit.includes(s));
}

/** Pull a short exception + top frame from Tidewave error-log samples (5xx pages). */
export function extractExceptionFromLogs(runtimePage) {
  const samples = runtimePage?.logs?.levels?.error?.samples || [];
  if (!samples.length) return null;
  const joined = samples.join("\n");
  // Elixir: ** (KeyError) key :timezone not found … \n     (module path:line)
  const ex =
    joined.match(/\*\*\s*\(([A-Za-z.]+)\)\s*([^\n]+)/) ||
    joined.match(
      /\b((?:Postgrex|Ecto|RuntimeError|ArgumentError|KeyError|FunctionClauseError)[^\n]*)/,
    );
  const frame =
    joined.match(/\((?:file|lib)[^)]+\.exs?:\d+\)/) ||
    joined.match(/([A-Za-z0-9_./]+\.ex:\d+)/) ||
    joined.match(/([a-z0-9_]+_live\.ex:\d+)/i);
  if (!ex && !frame) {
    const first = samples.find((s) => String(s).trim());
    return first ? { summary: String(first).slice(0, 240) } : null;
  }
  return {
    exception: ex
      ? (ex[1] && ex[2] ? `${ex[1]}: ${ex[2].trim()}` : ex[0]).slice(0, 240)
      : null,
    frame: frame ? frame[0].slice(0, 120) : null,
    summary: [ex && (ex[0] || "").trim(), frame && frame[0]]
      .filter(Boolean)
      .join(" @ ")
      .slice(0, 280),
  };
}

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
    stepsFailed: 0,
    stepsBlockedOnly: false,
    stepsBlocked: null,
    navOutcome: "ok",
    ...overrides,
  });
}
