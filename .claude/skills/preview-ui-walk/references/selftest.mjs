#!/usr/bin/env node
// Pure-helper + taxonomy fixture smoke for preview-ui-walk (no browser).
//   node selftest.mjs

import { classifyRisk } from "./classify_risk.mjs";
import {
  CATEGORIES,
  EXIT,
  STATE,
  checkCredentials,
  checkDisk,
  checkEnvSafety,
  checkLeakedSessions,
  redact,
  row,
  toJson,
  toText,
  verdict,
  verdictName,
} from "./preflight.mjs";
import { parseServerTiming, sanitizeDomHtml } from "./collectors.mjs";
import { verify as verifyPayload } from "./payload_pack.mjs";
import { classifyRisk as classifyRiskRuntime } from "./runtime_evidence.mjs";
import {
  expandEnvText,
  interactionsAllowed,
  walkNeedsRequiredInteractions,
} from "./page_steps.mjs";
import {
  countRuntimeErrors,
  defaultAppFramePrefixes,
  evidenceGuard,
  extractBounceReason,
  extractExceptionFromLogs,
  isBlockedStatus,
  isHardFailStatus,
  isSignificantErrorLine,
  normalizeAppFramePrefixes,
  RESULT_CLASSES,
  resultClass,
  runtimeErrorEvidence,
  statusColor,
  verdictFixture,
} from "./walk_verdict.mjs";

let failed = 0;
function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL:", msg);
    failed++;
  } else {
    console.log("ok:", msg);
  }
}

// ── classifyRisk: prod wins when both match (fail-closed) ──────────────────
assert(classifyRisk("https://dev-one-api.onemilc.com") === "ok", "dev-one-api is ok");
assert(classifyRisk("https://stage-one-api.onemilc.com") === "ok", "stage is ok");
assert(classifyRisk("https://api.onemilc.com") === "prod_like", "bare onemilc prod_like");
assert(classifyRisk("https://prod-api.example.com") === "prod_like", "prod-api prod_like");
assert(classifyRisk("https://app.devbox.milcgroup.com") === "ok", "devbox is ok");
assert(classifyRisk("https://foo.dev.bar.com") === "ok", ".dev. is ok");
// Conflict cases — prod must win over dev- substring
assert(
  classifyRisk("https://prod-dev-api.example.com") === "prod_like",
  "prod-dev-api: prod wins over dev-",
);
assert(
  classifyRisk("https://dev-prod-api.example.com") === "prod_like",
  "dev-prod-api: prod wins over dev-",
);
assert(
  classifyRisk("https://api.production.example.com") === "prod_like",
  "production host is prod_like",
);

// ── env expand ─────────────────────────────────────────────────────────────
process.env.WALK_LOGIN_EMAIL = "garlin@test.com";
assert(expandEnvText("${WALK_LOGIN_EMAIL}") === "garlin@test.com", "env expand works");
assert(expandEnvText("plain") === "plain", "plain text untouched");
let threw = false;
try {
  expandEnvText("${MISSING_VAR_XYZ}");
} catch {
  threw = true;
}
assert(threw, "missing env throws");

const gate = interactionsAllowed(
  { safety: { allow_interactions: true } },
  { env_check: { items: [{ key: "APP_API_URL", risk: "prod_like" }] } },
);
assert(gate.allowed === false && gate.code === "prod_like_env_check", "prod_like gate code");

assert(
  walkNeedsRequiredInteractions({
    pages: [{ steps: [{ action: "fill", selector: "#e", text: "x" }] }],
  }) === true,
  "walk needs interactions from pages",
);
assert(
  walkNeedsRequiredInteractions({
    login: { kind: "click", steps: [{ action: "fill", selector: "#e", text: "x" }] },
    pages: [],
  }) === true,
  "walk needs interactions from login.steps",
);
assert(
  walkNeedsRequiredInteractions({
    pages: [{ steps: [{ action: "assert_text", text: "hi" }] }],
  }) === false,
  "assert-only walk no interactions",
);

// ── Taxonomy fixtures (mainStatus × URL × steps) ───────────────────────────
assert(verdictFixture().status === "PASS", "clean page PASS");

assert(
  verdictFixture({
    mainStatus: 500,
    uok: false,
    landed: "http://x/login",
    bounceHit: "/login",
    navOutcome: "bounce",
  }).status === "CRASHED",
  "5xx before bounce → CRASHED (Tidewave not required)",
);

assert(
  verdictFixture({
    mainStatus: 500,
    loaded: false,
    uok: false,
    navOutcome: "timeout",
  }).status === "CRASHED",
  "5xx + timeout still CRASHED",
);

assert(
  verdictFixture({
    mainStatus: 200,
    uok: false,
    landed: "http://x/dashboard",
    wantPath: "/billing",
    bounceHit: "/dashboard",
    navOutcome: "bounce",
    loaded: false,
  }).status === "BOUNCED",
  "access bounce → BOUNCED",
);

assert(
  verdictFixture({
    mainStatus: 200,
    uok: true,
    stepsFailed: 1,
  }).status === "ASSERT_FAILED",
  "2xx + step fail → ASSERT_FAILED",
);

assert(
  verdictFixture({
    mainStatus: 200,
    uok: true,
    runtimeErrors: 1,
  }).status === "RUNTIME_ERROR",
  "server error logs → RUNTIME_ERROR (not ASSERT_FAILED)",
);

assert(
  verdictFixture({
    mainStatus: 200,
    uok: true,
    runtimeErrors: 2,
    stepsFailed: 1,
  }).status === "RUNTIME_ERROR",
  "RUNTIME_ERROR wins over step ASSERT_FAILED (server bug first)",
);

assert(
  verdictFixture({
    mainStatus: 200,
    loaded: false,
    uok: false,
    navOutcome: "timeout",
    landed: "http://x/pending",
    wantPath: "/admin",
  }).status === "TIMEOUT",
  "no land no bounce → TIMEOUT",
);

assert(
  verdictFixture({
    stepsBlockedOnly: true,
    stepsBlocked: { message: "SKIPPED: interactions blocked by prod_like_env_check" },
    mainStatus: null,
    uok: false,
  }).status === "SKIPPED",
  "blocked interactions → SKIPPED not FAIL",
);

assert(
  verdictFixture({
    within: false,
    uok: true,
    loaded: true,
  }).status === "PASS_SLOW",
  "over budget but landed → PASS_SLOW",
);

// Exception enrichment is optional — empty logs still leave CRASHED alone
assert(
  extractExceptionFromLogs({ logs: { levels: { error: { samples: [] } } } }) === null,
  "no logs → null exception (status still CRASHED independently)",
);
assert(
  extractExceptionFromLogs({
    logs: {
      levels: {
        error: {
          samples: ["** (KeyError) key :timezone not found", "scale_report_live.ex:57"],
        },
      },
    },
  })?.summary?.includes("KeyError"),
  "exception frame extracted when samples present",
);

// Prefer app frame over framework static.ex
{
  const ex = extractExceptionFromLogs({
    logs: {
      levels: {
        error: {
          samples: [
            "** (KeyError) key :timezone not found",
            "(phoenix_live_view/lib/phoenix_live_view/static.ex:324)",
            "(lib/one_web/live/scale_report_live.ex:57)",
          ],
        },
      },
    },
  });
  assert(
    ex?.frame?.includes("scale_report_live.ex:57"),
    "exception frame prefers app lib/one_web over static.ex",
  );
}

// Significant vs benign error lines
assert(
  isSignificantErrorLine("** (KeyError) key :timezone not found") === true,
  "KeyError is significant",
);
assert(
  isSignificantErrorLine("auth falls to local DB") === false,
  "benign auth fallback is not significant",
);
assert(
  countRuntimeErrors({
    logs: {
      levels: {
        error: {
          count: 2,
          samples: ["auth falls to local DB", "** (KeyError) key :x"],
        },
      },
    },
    error_log_count: 1,
  }) >= 1,
  "countRuntimeErrors counts significant samples",
);

// Bounce reason from LiveView flash fields
assert(
  extractBounceReason({
    liveview: {
      liveviews: [
        {
          fields: { flash: "unauthorized: missing :areas" },
          assign_keys: ["flash", "current_user"],
        },
      ],
    },
  })?.includes("unauthorized"),
  "bounce reason pulls flash",
);

// ── Exit semantics ─────────────────────────────────────────────────────────
assert(
  isHardFailStatus("CRASHED", {}) === true,
  "CRASHED hard-fails exit",
);
assert(
  isHardFailStatus("RUNTIME_ERROR", {}) === true,
  "RUNTIME_ERROR hard-fails exit",
);
assert(
  isHardFailStatus("ASSERT_FAILED", {}) === true,
  "ASSERT_FAILED hard-fails exit",
);
assert(
  isHardFailStatus("BOUNCED", { bounce: "/dashboard", landed: "http://x/dashboard" }) === false,
  "access bounce soft for exit",
);
assert(
  isHardFailStatus("BOUNCED", { bounce: "/login", landed: "http://x/login" }) === true,
  "auth bounce hard-fails exit",
);
assert(
  isHardFailStatus("BOUNCED", { bounce: "/dashboard" }, { strictAccess: true }) === true,
  "--strict-access hard-fails all bounces",
);
assert(isHardFailStatus("PASS", {}) === false, "PASS soft");
assert(isHardFailStatus("PASS_SLOW", {}) === false, "PASS_SLOW soft");
assert(isHardFailStatus("SKIPPED", {}) === true, "SKIPPED hard-fails");

// env_check strip must share ONE classifier with the interactions gate. A stale
// duplicate in runtime_evidence.mjs (missing the dev- rule) once blocked login
// against dev-* backends. Guard: both classifiers agree, incl. the dev- case.
assert(
  classifyRiskRuntime("https://dev-one-api.onemilc.com") === "ok",
  "runtime_evidence env_check classifier: dev-one-api is ok (not prod_like)",
);
assert(
  classifyRiskRuntime("https://dev-one-api.onemilc.com") === classifyRisk("https://dev-one-api.onemilc.com") &&
    classifyRiskRuntime("https://api.onemilc.com") === classifyRisk("https://api.onemilc.com"),
  "env_check and interactions gate use the same classifier",
);

// #3 — RUNTIME_ERROR hard-fails by default; --soft-runtime-error opts out; others unaffected.
assert(
  isHardFailStatus("RUNTIME_ERROR", {}) === true,
  "RUNTIME_ERROR hard-fails by default",
);
assert(
  isHardFailStatus("RUNTIME_ERROR", {}, { failRuntimeError: false }) === false,
  "--soft-runtime-error makes RUNTIME_ERROR soft",
);
assert(
  isHardFailStatus("CRASHED", {}, { failRuntimeError: false }) === true,
  "opt-out does not soften CRASHED",
);

// #4 — dedup repeated identical errors; keep unique + total + one sample; warnings never count.
const keyErr = (rid) =>
  `${rid} [error] ** (KeyError) key :timezone not found in lib/one_web/live/scale_report_live.ex:57`;
const dedup = runtimeErrorEvidence({
  logs: {
    levels: {
      error: {
        count: 70,
        samples: Array.from({ length: 70 }, (_, i) => keyErr(`request_id=r${i}`)),
      },
    },
  },
});
assert(dedup.count === 1, "70 identical KeyErrors dedupe to 1 unique");
assert(dedup.total === 70, "total occurrences preserved (70)");
assert(/KeyError/.test(dedup.sample || ""), "concise sample preserved");
assert(
  runtimeErrorEvidence({
    logs: { levels: { error: { count: 3, samples: ["[warning] deprecated foo", "recompiling", "phoenix_live_reload"] } } },
  }).count === 0,
  "warning/benign-only lines never trigger RUNTIME_ERROR",
);
assert(
  countRuntimeErrors({
    logs: { levels: { error: { count: 2, samples: [keyErr("request_id=a"), keyErr("request_id=b")] } } },
  }) === 1,
  "countRuntimeErrors returns the deduped count",
);

// #6 — app_frame_prefix accepts a bare string OR an ordered list.
assert(
  JSON.stringify(normalizeAppFramePrefixes("lib/one_web/")) === '["lib/one_web/"]',
  "app_frame_prefix accepts a bare string",
);
assert(
  JSON.stringify(normalizeAppFramePrefixes(["lib/a/", "lib/b/"])) === '["lib/a/","lib/b/"]',
  "app_frame_prefix accepts an ordered list",
);
assert(
  JSON.stringify(defaultAppFramePrefixes({ app_frame_prefix: "lib/custom/" })) === '["lib/custom/"]',
  "manifest app_frame_prefix string overrides the default",
);

// Pack integrity — the packed driver body (playwright_walk_payload.pl*) must
// decode to valid JS. Guards the land/repack step: a dropped base64 char once
// shipped a driver that couldn't load, while selftest still read "green" because
// nothing checked the pack. (See git history: pl1 short-by-one.)
{
  const { gunzipSync } = await import("node:zlib");
  const { readFileSync, existsSync } = await import("node:fs");
  const { fileURLToPath } = await import("node:url");
  const { dirname, join } = await import("node:path");
  const here = dirname(fileURLToPath(import.meta.url));
  let b64 = "";
  const single = join(here, "playwright_walk_payload.b64");
  if (existsSync(single)) {
    b64 = readFileSync(single, "utf8").trim();
  } else {
    for (let i = 0; existsSync(join(here, `playwright_walk_payload.pl${i}`)); i++) {
      b64 += readFileSync(join(here, `playwright_walk_payload.pl${i}`), "utf8").trim();
    }
  }
  assert(b64.length > 0, "packed driver payload present");
  assert(b64.length % 4 === 0, "packed payload base64 length is a multiple of 4");
  let src = "";
  let decodeOk = true;
  try {
    src = gunzipSync(Buffer.from(b64, "base64")).toString("utf8");
  } catch {
    decodeOk = false;
  }
  assert(decodeOk, "packed driver gunzips cleanly (CRC-valid)");
  assert(/preview-ui-walk/.test(src) && src.length > 10000, "decoded driver looks like the walk body");
}

// ── Normalized result classes ───────────────────────────────────────────────
// The four consumer-facing classes must never lose the richer diagnostic
// status, and must never report missing evidence as green.
assert(
  RESULT_CLASSES.join(",") === "PASS,FAILED,BLOCKED,NOT_TESTED",
  "result classes are exactly PASS/FAILED/BLOCKED/NOT_TESTED",
);
assert(resultClass("PASS") === "PASS", "PASS -> PASS");
assert(resultClass("PASS_SLOW") === "PASS", "PASS_SLOW keeps its status but classes as PASS");
assert(resultClass("SKIPPED") === "NOT_TESTED", "SKIPPED (interactions gate) -> NOT_TESTED");
assert(resultClass("BLOCKED") === "BLOCKED", "BLOCKED -> BLOCKED");
for (const s of ["FAIL", "ASSERT_FAILED", "CRASHED", "RUNTIME_ERROR", "TIMEOUT"]) {
  assert(resultClass(s) === "FAILED", `${s} -> FAILED`);
}
// An access-gated bounce never landed, so its assertions were not exercised:
// NOT_TESTED, not a false green and not a flattened red.
assert(
  resultClass("BOUNCED", { bounce: "/dashboard" }) === "NOT_TESTED",
  "tolerated access BOUNCED -> NOT_TESTED",
);
// An auth bounce (→ /login) is a real failure and must stay FAILED.
assert(
  resultClass("BOUNCED", { bounce: "/login" }) === "FAILED",
  "auth BOUNCED -> FAILED",
);
assert(
  resultClass("BOUNCED", { bounce: "/dashboard" }, { strictAccess: true }) === "FAILED",
  "--strict-access promotes any BOUNCED to FAILED",
);

// ── Fail-closed: BLOCKED hard-fails by default ──────────────────────────────
assert(isBlockedStatus("BLOCKED") && !isBlockedStatus("FAIL"), "isBlockedStatus discriminates");
assert(
  isHardFailStatus("BLOCKED", {}) === true,
  "BLOCKED hard-fails by default (fail closed on missing evidence)",
);
assert(
  isHardFailStatus("BLOCKED", {}, { failBlocked: false }) === false,
  "--soft-blocked downgrades BLOCKED to informational",
);
assert(
  statusColor("BLOCKED") !== statusColor("PASS") && statusColor("BLOCKED") !== statusColor("FAIL"),
  "BLOCKED is visually distinct from both PASS and FAIL",
);

// ── Evidence guard (fail closed when a required collector produced nothing) ──
assert(evidenceGuard([], {}) === null, "no required evidence -> no guard verdict");
assert(evidenceGuard(undefined, {}) === null, "absent requirement list -> no guard verdict");
assert(
  evidenceGuard(["har"], { har: { entries: 1 } }) === null,
  "present evidence -> no guard verdict",
);
{
  const g = evidenceGuard(["har", "a11y"], { har: { entries: 1 }, a11y: null });
  assert(g && g.status === "BLOCKED", "missing evidence yields BLOCKED");
  assert(
    g.missingEvidence.join(",") === "a11y" && /a11y/.test(g.reason),
    "BLOCKED names exactly which evidence was missing",
  );
}
// Empty containers count as "collected nothing", not as evidence.
assert(
  evidenceGuard(["har"], { har: {} })?.status === "BLOCKED",
  "empty object is not evidence",
);
assert(
  evidenceGuard(["dom"], { dom: [] })?.status === "BLOCKED",
  "empty array is not evidence",
);
assert(
  evidenceGuard(["cleanup"], { cleanup: false })?.status === "BLOCKED",
  "false is not evidence",
);
// v1 compatibility: manifests that declare no requirements behave exactly as before.
assert(
  resultClass(verdictFixture().status) === "PASS",
  "v1 fixture with no evidence requirements still classes PASS",
);

// ── Schema ⟷ driver contract (drift is a real defect, not cosmetics) ─────────
// Fields the driver actually reads MUST exist in the schema, or product repos
// get validation failures for manifests that work (and, worse, silently keep
// fields the driver ignores — see `login.form`).
{
  const { readFileSync } = await import("node:fs");
  const { fileURLToPath } = await import("node:url");
  const { dirname, join } = await import("node:path");
  const here = dirname(fileURLToPath(import.meta.url));
  const schema = JSON.parse(readFileSync(join(here, "preview-walk.schema.json"), "utf8"));
  const loginProps = schema.definitions.login.properties;
  const pageProps = schema.definitions.page.properties;

  for (const key of ["steps", "budget_ms", "params_from_env", "kind", "path", "lands_on"]) {
    assert(key in loginProps, `schema login.${key} exists (driver reads it)`);
  }
  assert(
    loginProps.form?.deprecated === true,
    "schema marks login.form deprecated (driver never reads it)",
  );
  // kind:"none" public walks must not be forced to declare a login route.
  assert(
    !Array.isArray(schema.definitions.login.required),
    "login has no unconditional required list (kind:none needs neither path nor lands_on)",
  );
  assert(
    JSON.stringify(schema.definitions.login.allOf || []).includes("lands_on"),
    "login conditionally requires path/lands_on for non-none kinds",
  );
  assert("asset" in pageProps, "schema page.asset exists (product tooling publishes it)");

  // New collector contract.
  assert("viewports" in schema.properties, "schema declares named viewports");
  assert("require_evidence" in schema.properties, "schema declares require_evidence");
  assert("retries" in schema.properties, "schema declares retries/flakiness");
  assert("viewport" in schema.definitions, "viewport definition present");
  const ev = schema.properties.require_evidence.items.enum;
  for (const key of ["har", "a11y", "dom", "server_timing", "ws", "cleanup", "audit_actor"]) {
    assert(ev.includes(key), `require_evidence enum covers ${key}`);
  }
  // v1 compatibility: the shipped examples must still validate unchanged.
  for (const name of ["authed-admin-example.json", "login-click-example.json"]) {
    const doc = JSON.parse(readFileSync(join(here, name), "utf8"));
    assert(doc && typeof doc === "object", `${name} parses (v1 example retained)`);
  }
}

// ── Preflight: one fixture per exit state ───────────────────────────────────
const okRows = () => CATEGORIES.map((c) => row(c.id, STATE.OK, "ok"));

assert(verdict(okRows()) === EXIT.READY, "all OK -> READY(0)");
assert(verdictName(EXIT.READY) === "READY", "verdict names round-trip");

{
  // Optional missing -> DEGRADED(1): read-only walks may proceed.
  const rows = okRows().map((r) => (r.id === "har" ? row("har", STATE.MISSING, "no har") : r));
  assert(verdict(rows) === EXIT.DEGRADED, "optional MISSING -> DEGRADED(1)");
  assert(/READ-ONLY OK/.test(toText(rows)), "DEGRADED text tells the operator read-only is allowed");
  assert(/BLOCKED, not PASS/.test(toText(rows)), "DEGRADED text warns pages will report BLOCKED");
}
{
  // Required missing -> BLOCKED(2): fail closed, do not run.
  const rows = okRows().map((r) =>
    r.id === "screenshot" ? row("screenshot", STATE.MISSING, "no screenshot") : r,
  );
  assert(verdict(rows) === EXIT.BLOCKED, "required MISSING -> BLOCKED(2) (fail closed)");
  assert(/DO NOT RUN/.test(toText(rows)), "BLOCKED text says do not run");
}
{
  const rows = okRows().map((r) => (r.id === "disk" ? row("disk", STATE.BLOCKED, "full") : r));
  assert(verdict(rows) === EXIT.BLOCKED, "explicit BLOCKED state -> BLOCKED(2)");
}
{
  // UNSAFE outranks everything, including a simultaneous required-missing row.
  const rows = okRows().map((r) => {
    if (r.id === "env_safety") return row("env_safety", STATE.UNSAFE, "prod-like");
    if (r.id === "screenshot") return row("screenshot", STATE.MISSING, "none");
    return r;
  });
  assert(verdict(rows) === EXIT.UNSAFE, "UNSAFE outranks BLOCKED -> UNSAFE(3)");
}
{
  // A mutating walk demands affirmatively-safe env, even if nothing is missing.
  const rows = okRows().map((r) =>
    r.id === "env_safety" ? row("env_safety", STATE.MISSING, "MIX_ENV unset") : r,
  );
  assert(verdict(rows, { mutating: true }) === EXIT.UNSAFE, "mutating + unproven env -> UNSAFE(3)");
  assert(verdict(rows, { mutating: false }) === EXIT.BLOCKED, "same rows read-only -> BLOCKED(2)");
}
assert(
  verdict(okRows().map((r) => (r.id === "har" ? row("har", STATE.SKIP, "n/a") : r))) === EXIT.READY,
  "SKIP never worsens the verdict",
);

// Environment safety fixtures.
assert(checkEnvSafety({ MIX_ENV: "dev" }).state === STATE.OK, "MIX_ENV=dev is safe");
assert(checkEnvSafety({ MIX_ENV: "test" }).state === STATE.OK, "MIX_ENV=test is safe");
assert(checkEnvSafety({ MIX_ENV: "prod" }).state === STATE.UNSAFE, "MIX_ENV=prod is UNSAFE");
assert(
  checkEnvSafety({ MIX_ENV: "dev", PHX_HOST: "app.production.example" }).state === STATE.UNSAFE,
  "production-looking host is UNSAFE even with MIX_ENV=dev",
);
assert(checkEnvSafety({}).state === STATE.MISSING, "unset MIX_ENV is unproven, not assumed safe");
assert(
  checkEnvSafety({}, { mutating: true }).state === STATE.UNSAFE,
  "unproven env + mutating -> UNSAFE (never guess before mutating)",
);

// Credentials: resolution only, never the secret.
{
  const env = { WALK_A_EMAIL: "a@example.com", WALK_A_PASSWORD: "s3cret", WALK_B_EMAIL: "b@x.io" };
  const r = checkCredentials(["WALK_A", "WALK_B"], env);
  assert(r.state === STATE.MISSING, "a role missing its password is MISSING");
  const blob = JSON.stringify(r);
  assert(!blob.includes("s3cret") && !blob.includes("a@example.com"), "credential row leaks no secret");
  assert(r.evidence.unresolved === 1, "credential row counts unresolved roles");
  assert(checkCredentials([], env).state === STATE.SKIP, "no roles configured -> SKIP");
  assert(
    checkCredentials(["WALK_A"], env).state === STATE.OK,
    "fully-resolved role set is OK",
  );
}
assert(redact("anything").hint === "set" && redact("").hint === "unset", "redact reports only set/unset");
assert(!("length" in redact("abcdef")), "redact never exposes secret length");

assert(checkDisk(2 * 1024 ** 3).state === STATE.OK, "ample disk is OK");
assert(checkDisk(1024).state === STATE.BLOCKED, "tiny disk is BLOCKED");
assert(checkDisk(NaN).state === STATE.MISSING, "unknown disk is MISSING");
assert(checkLeakedSessions(0).state === STATE.OK, "no leaked sessions is OK");
assert(checkLeakedSessions(3).state === STATE.MISSING, "leaked sessions flagged");

// JSON matrix shape + the no-mutation invariant.
{
  const j = toJson(okRows(), { now: "2026-01-01T00:00:00.000Z" });
  assert(j.schema === "preview-ui-walk/preflight@1", "JSON matrix is versioned");
  assert(j.verdict === "READY" && j.exitCode === 0, "JSON carries verdict + exit code");
  assert(j.mutationsPerformed === 0, "preflight reports zero mutations performed");
  assert(j.rows.length === CATEGORIES.length, "JSON matrix covers every category");
  for (const id of [
    "schema", "env_safety", "credentials", "app_health", "identity", "browser",
    "preview_mcp", "tidewave", "har", "ws", "dom", "screenshot", "a11y", "viewport",
    "visual_baseline", "resource_metrics", "db_read", "audit_actor", "artifact",
    "cleanup", "disk", "leaked_sessions",
  ]) {
    assert(j.rows.some((r) => r.id === id), `matrix covers ${id}`);
  }
}

// ── Collector batch (pure parts; the browser parts are proved by preflight) ──
assert(parseServerTiming(null) === null, "absent Server-Timing header -> null, not empty evidence");
assert(parseServerTiming("app;dur=1.5").metrics[0].dur === 1.5, "Server-Timing dur parsed");
assert(
  parseServerTiming('db;dur=2;desc="query"').metrics[0].desc === "query",
  "Server-Timing quoted desc parsed",
);
assert(parseServerTiming("a, b;dur=3").metrics.length === 2, "multiple Server-Timing metrics");
assert(
  !sanitizeDomHtml('<input name="x" value="hunter2">').includes("hunter2"),
  "DOM snapshot redacts input values",
);
assert(
  !sanitizeDomHtml('<meta name="csrf-token" content="abc123">').includes("abc123"),
  "DOM snapshot redacts the CSRF meta token",
);

// Payload pack determinism: committed shards must decode AND repack identically.
{
  const v = verifyPayload();
  assert(v.roundTrips, "committed driver payload decodes and round-trips");
  assert(v.deterministic, "repacking the driver reproduces byte-identical shards");
}

if (failed) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nselftest: all pure-helper + taxonomy + pack-integrity checks passed");
