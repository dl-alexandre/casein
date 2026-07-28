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
import {
  buildMatrix,
  isMutating,
  requiredEvidence,
  roleEnvPrefixes,
  runPreflight,
} from "./preflight_run.mjs";
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

// ── --preflight-only: manifest fan-in, no-navigation, exact exits ───────────
{
  const { mkdtempSync, writeFileSync, readFileSync, existsSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "preflight-selftest-"));

  const manifest = (extra = {}) => ({
    version: 1,
    login: { kind: "none" },
    pages: [{ name: "Dash", path: "/one/dashboard" }],
    safety: { read_only: true },
    report: { name: "t" },
    ...extra,
  });
  const write = (name, doc) => {
    const p = join(dir, name);
    writeFileSync(p, JSON.stringify(doc));
    return p;
  };

  // Manifest fan-in: role prefixes, evidence and mutation intent merge across
  // ALL selected manifests, not just the first.
  const a = manifest({ login: { kind: "click", params_from_env: ["WALK_A_EMAIL", "WALK_A_PASSWORD"] } });
  const b = manifest({
    login: { kind: "click", params_from_env: ["WALK_B_EMAIL"] },
    require_evidence: ["har"],
    pages: [{ name: "P", path: "/p", require_evidence: ["dom"] }],
  });
  assert(
    roleEnvPrefixes([a, b]).join(",") === "WALK_A,WALK_B",
    "role prefixes merge across manifests and drop _EMAIL/_PASSWORD suffixes",
  );
  assert(
    requiredEvidence([a, b]).join(",") === "dom,har",
    "required evidence merges walk-level and per-page across manifests",
  );
  assert(!isMutating([a, b]), "read_only manifests are not mutating");
  assert(isMutating([manifest({ safety: { read_only: false } })]), "read_only:false is mutating");

  // A recording fetch proves preflight performs exactly one safe GET of --base
  // and never touches a manifest page path.
  const seen = [];
  const fetchImpl = async (url, init = {}) => {
    seen.push({ url: String(url), method: init.method || "GET" });
    return { status: 200 };
  };
  const deps = {
    fetchImpl,
    // Credentials for the manifest's declared role, so the READY case exercises
    // resolution rather than accidentally asserting the BLOCKED path.
    env: { MIX_ENV: "dev", WALK_A_EMAIL: "a@example.test", WALK_A_PASSWORD: "x" },
    resolveChromium: () => ({}),
    chromiumPath: () => null,
    freeBytes: 4 * 1024 ** 3,
    leakedSessions: 0,
    now: "2026-01-01T00:00:00.000Z",
    stdout: () => {},
  };
  const args = { manifests: [write("a.json", a)], base: "http://127.0.0.1:1", out: join(dir, "out") };
  const res = await runPreflight(args, deps);

  assert(seen.length === 1, "preflight performs exactly one network request");
  assert(seen[0].method === "GET", "that request is a GET (no mutation verb)");
  assert(seen[0].url === "http://127.0.0.1:1", "it targets --base only");
  assert(
    !seen.some((r) => r.url.includes("/one/dashboard")),
    "preflight never navigates to a manifest page path",
  );
  assert(res.json.mutationsPerformed === 0, "preflight reports zero mutations");
  assert(existsSync(join(dir, "out", "preflight.json")), "preflight.json written");
  assert(existsSync(join(dir, "out", "preflight.txt")), "human preflight.txt written");
  {
    const onDisk = JSON.parse(readFileSync(join(dir, "out", "preflight.json"), "utf8"));
    assert(onDisk.schema === "preview-ui-walk/preflight@1", "preflight.json is the versioned matrix");
    assert(onDisk.rows.length === CATEGORIES.length, "preflight.json covers every category");
  }

  // Exit codes, exactly.
  assert(res.code === EXIT.READY, "healthy read-only walk -> 0 READY");

  // Missing role credentials must fail closed (required category).
  const noCreds = await runPreflight(args, { ...deps, env: { MIX_ENV: "dev" } });
  assert(noCreds.code === EXIT.BLOCKED, "unresolved role credentials -> 2 BLOCKED (fail closed)");

  const unsafe = await runPreflight(args, { ...deps, env: { MIX_ENV: "prod", WALK_A_EMAIL: "a", WALK_A_PASSWORD: "x" } });
  assert(unsafe.code === EXIT.UNSAFE, "production-like env -> 3 UNSAFE");

  const mutating = await runPreflight(
    { ...args, manifests: [write("mut.json", manifest({ safety: { read_only: false } }))] },
    { ...deps, env: {} },
  );
  assert(mutating.code === EXIT.UNSAFE, "mutating walk + unproven env -> 3 UNSAFE");

  const degraded = await runPreflight(
    { ...args, manifests: [write("ws.json", manifest({ require_evidence: ["ws"] }))] },
    deps,
  );
  assert(degraded.code === EXIT.DEGRADED, "unprovable OPTIONAL evidence -> 1 DEGRADED");

  const blockedHealth = await runPreflight(args, {
    ...deps,
    fetchImpl: async () => {
      throw new Error("ECONNREFUSED");
    },
  });
  assert(blockedHealth.code === EXIT.BLOCKED, "unreachable base -> 2 BLOCKED");

  const blockedBrowser = await runPreflight(args, {
    ...deps,
    resolveChromium: () => {
      throw new Error("cannot resolve playwright-core");
    },
  });
  assert(blockedBrowser.code === EXIT.BLOCKED, "required browser missing -> 2 BLOCKED (fail closed)");

  const blockedDisk = await runPreflight(args, { ...deps, freeBytes: 1024 });
  assert(blockedDisk.code === EXIT.BLOCKED, "insufficient disk -> 2 BLOCKED");

  // A bad manifest must block, never be walked past.
  writeFileSync(join(dir, "broken.json"), "{ not json");
  const blockedSchema = await runPreflight(
    { ...args, manifests: [join(dir, "broken.json")] },
    deps,
  );
  assert(blockedSchema.code === EXIT.BLOCKED, "unparseable manifest -> 2 BLOCKED");

  // The packed driver must actually expose the flag (guards against a repack
  // that silently drops the wiring).
  {
    const { unpack } = await import("./payload_pack.mjs");
    const src = unpack();
    assert(src.includes("--preflight-only"), "packed driver parses --preflight-only");
    assert(
      src.indexOf("if (a.preflightOnly)") < src.indexOf("chromium.launch"),
      "preflight branch precedes the browser launch (no-navigation is structural)",
    );
  }
}

// ── Batch 1: WebSocket / LiveView reconnect evidence ────────────────────────
{
  const { parsePhoenixFrame, sanitizeSocketUrl, summarize, attachWs } = await import(
    "./ws_collector.mjs"
  );
  const { wsProven } = await import("./preflight_run.mjs");

  // URL redaction: LiveView carries its signed token in the query string.
  assert(
    sanitizeSocketUrl("wss://h/live/websocket?vsn=2.0&token=SECRET") ===
      "wss://h/live/websocket?vsn=[redacted]&token=[redacted]",
    "socket URL query values are dropped, not masked",
  );
  assert(
    !sanitizeSocketUrl("wss://h/live/websocket?token=SECRET").includes("SECRET"),
    "socket URL never retains a token value",
  );
  assert(sanitizeSocketUrl("wss://h/live/websocket") === "wss://h/live/websocket", "no query is untouched");

  // Phoenix wire format.
  const join = parsePhoenixFrame(JSON.stringify(["1", "1", "lv:x", "phx_join", { url: "/x" }]));
  assert(join.event === "phx_join" && join.topic === "lv:x", "phx_join parsed");
  const ok = parsePhoenixFrame(JSON.stringify([null, "1", "lv:x", "phx_reply", { status: "ok", response: { rendered: "SECRET" } }]));
  assert(ok.status === "ok", "phx_reply status parsed");
  assert(!("response" in ok) && !JSON.stringify(ok).includes("SECRET"), "reply body never parsed out");
  assert(parsePhoenixFrame("not json") === null, "non-JSON frame ignored");
  assert(parsePhoenixFrame(JSON.stringify({ a: 1 })) === null, "non-array frame ignored");

  const sock = (over = {}) => ({
    url: "wss://h/live/websocket",
    openedAtMs: 0,
    closedAtMs: null,
    error: null,
    frames: [],
    counts: { sent: 0, received: 0 },
    liveview: { joins: 0, joinOk: 0, joinError: 0, topics: [] },
    ...over,
  });

  // Reconnect + recovery latency measured to the successful RE-JOIN.
  {
    const r = summarize({
      sockets: [
        sock({ openedAtMs: 0, closedAtMs: 100, liveview: { joins: 1, joinOk: 1, joinError: 0, topics: ["lv:x"] } }),
        sock({ openedAtMs: 250, liveview: { joins: 1, joinOk: 1, joinError: 0, topics: ["lv:x"] } }),
      ],
      opens: 2, closes: 1, errors: 0, framesDropped: 0, maxFrames: 200, frameEventsSeen: 4,
    });
    assert(r.reconnect.attempts === 1, "reconnect attempt detected");
    assert(r.reconnect.recovered === 1, "recovery detected");
    assert(r.reconnect.recoveryLatencyMs === 150, "recovery latency = close -> reopen");
    assert(r.liveview.joined === true && r.liveview.healthy === true, "healthy LiveView");
  }
  // A socket that reopens but never re-joins has NOT recovered.
  {
    const r = summarize({
      sockets: [
        sock({ openedAtMs: 0, closedAtMs: 100, liveview: { joins: 1, joinOk: 1, joinError: 0, topics: [] } }),
        sock({ openedAtMs: 200 }),
      ],
      opens: 2, closes: 1, errors: 0, framesDropped: 0, maxFrames: 200, frameEventsSeen: 3,
    });
    assert(r.reconnect.attempts === 1 && r.reconnect.recovered === 0, "reopen without re-join is not recovery");
    assert(r.reconnect.recoveryLatencyMs === null, "no recovery latency without a re-join");
  }
  // Join error is unhealthy but observable.
  {
    const r = summarize({
      sockets: [sock({ liveview: { joins: 1, joinOk: 0, joinError: 1, topics: ["lv:x"] } })],
      opens: 1, closes: 0, errors: 0, framesDropped: 0, maxFrames: 200, frameEventsSeen: 2,
    });
    assert(r.liveview.joined === false && r.liveview.healthy === false, "join error is unhealthy");
  }
  // Frame evidence UNAVAILABLE must not masquerade as a quiet-but-fine socket.
  {
    const r = summarize({
      sockets: [sock({ closedAtMs: 50 })],
      opens: 1, closes: 1, errors: 0, framesDropped: 0, maxFrames: 200, frameEventsSeen: 0,
    });
    assert(r.frames.observable === false, "no frame events -> frames.observable false");
    assert(r.liveview.observable === false, "LiveView state unobservable without frames");
    assert(
      r.liveview.joined === null && r.liveview.healthy === null,
      "unobservable LiveView is null, never false (we cannot claim it did not join)",
    );
    assert(r.counts.sockets === 1 && r.reconnect.disconnects === 1, "socket-level evidence still collected");
  }
  // Memory bound + payload non-retention.
  {
    const r = summarize({
      sockets: [sock({ frames: Array.from({ length: 5 }, () => ({ direction: "sent", size: 3 })) })],
      opens: 1, closes: 0, errors: 0, framesDropped: 7, maxFrames: 5, frameEventsSeen: 12,
    });
    assert(r.frames.truncated === true && r.frames.dropped === 7, "frame cap reports what it dropped");
    assert(r.frames.payloadsRetained === false, "collector declares payloads are never retained");
    // No frame may carry a body: assert on KEYS, not the "payloadsRetained"
    // flag's substring.
    const frameKeys = new Set(r.sockets.flatMap((s) => s.frames.flatMap((f) => Object.keys(f))));
    assert(
      !frameKeys.has("payload") && !frameKeys.has("body") && !frameKeys.has("text"),
      "no frame retains a payload/body/text key",
    );
  }
  assert(attachWs({ on() {}, off() {} }).stop() === null, "no socket -> null evidence, not an empty shell");

  // require_evidence:["ws"] must fail closed when frames are unobservable.
  assert(wsProven({ ws: { frames: { observable: true } } }) === true, "ws proven when frames observable");
  assert(wsProven({ ws: { frames: { observable: false } } }) === false, "ws NOT proven when frames unobservable");
  assert(wsProven(undefined) === false, "ws NOT proven without a probe (never assume capability)");

  // Regression pin for the root cause: a WebSocket cannot complete its upgrade
  // from a route-fulfilled fake origin, which yields zero frames and looks
  // exactly like "the driver does not support frame events". The scratch probe
  // must therefore stand up a REAL loopback HTTP origin for the page.
  {
    const c = await import("./collectors.mjs");
    assert(
      typeof c.startScratchOrigin === "function",
      "probe ships a real loopback origin (fake fulfilled origins cannot host a WebSocket)",
    );
    const origin = await c.startScratchOrigin();
    assert(/^http:\/\/127\.0\.0\.1:\d+\//.test(origin.url), "scratch origin is real loopback http");
    origin.close();
  }
}

// ── Batch 2: responsive named viewports + accessibility ─────────────────────
{
  const a11y = await import("./a11y_collector.mjs");
  const { a11yProven, viewportProven } = await import("./preflight_run.mjs");

  // Viewport normalization rejects junk loudly rather than walking a bad size.
  {
    const { viewports, invalid } = a11y.normalizeViewports([
      { name: "mobile", width: 390, height: 844 },
      { name: "", width: 100, height: 100 },
      { name: "bad", width: 0, height: 10 },
      { name: "nan", width: "x", height: 10 },
    ]);
    assert(viewports.length === 1 && viewports[0].name === "mobile", "valid viewport kept");
    assert(invalid.length === 3, "unnamed/zero/NaN viewports rejected, not silently coerced");
    assert(viewports[0].deviceScaleFactor === 1, "DPR defaults to 1 (screenshot px == DOM bounds)");
  }
  assert(a11y.normalizeViewports([]).viewports.length === 0, "empty list -> no viewports (v1 default)");
  assert(a11y.normalizeViewports(undefined).viewports.length === 0, "absent list -> no viewports");

  // Per-page narrowing of the walk-level viewport list.
  {
    const all = a11y.normalizeViewports(a11y.DEFAULT_VIEWPORTS).viewports;
    assert(a11y.viewportsForPage(all, []).length === all.length, "no page list -> all viewports");
    assert(a11y.viewportsForPage(all, ["desktop"]).map((v) => v.name).join() === "desktop", "page narrows to its subset");
    assert(a11y.viewportsForPage(all, ["nope"]).length === 0, "unknown viewport name selects nothing");
  }

  // Audit shape, with a fake page so the taxonomy is fixture-tested without a browser.
  {
    const fakePage = {
      setViewportSize: async () => {},
      evaluate: async () => ({
        violations: [
          { rule: "img-alt", wcag: "1.1.1", selector: "img", role: "img", name: "x", detail: "d" },
        ],
        counts: { "img-alt": 1 },
        elementsAudited: 3,
      }),
    };
    const one = await a11y.collectA11y(fakePage);
    assert(one.violationCount === 1 && one.counts["img-alt"] === 1, "audit summarizes violations");
    assert(one.engine === "structural-rules@1", "engine is versioned (rules can evolve deliberately)");

    const across = await a11y.collectAcrossViewports(
      fakePage,
      a11y.normalizeViewports(a11y.DEFAULT_VIEWPORTS).viewports,
    );
    assert(across.viewports.length === 2, "audited at every declared viewport");
    assert(across.totalViolations === 2, "violations summed across viewports");
    assert(across.observable === true, "observable when at least one audit succeeded");
  }

  // Fail-closed: an audit that never succeeds is unavailable, not "clean".
  {
    const brokenPage = { setViewportSize: async () => {}, evaluate: async () => { throw new Error("no"); } };
    assert((await a11y.collectA11y(brokenPage)) === null, "audit failure -> null, never a fake pass");
    const across = await a11y.collectAcrossViewports(
      brokenPage,
      a11y.normalizeViewports(a11y.DEFAULT_VIEWPORTS).viewports,
    );
    assert(across.observable === false, "no successful audit -> observable false");
    assert(
      across.totalViolations === 0 && across.observable === false,
      "zero violations with observable:false must not read as a clean page",
    );
  }
  assert(
    (await a11y.collectAcrossViewports({}, [])) === null,
    "no viewports -> null evidence (v1 walks unaffected)",
  );

  // Privacy: accessible names are truncated (they can echo user data).
  assert(a11y.MAX_NAME <= 60, "accessible-name cap is small enough to avoid leaking record text");

  // require_evidence gating.
  assert(a11yProven({ a11y: { observable: true } }) === true, "a11y proven when audits observable");
  assert(a11yProven({ a11y: { observable: false } }) === false, "a11y NOT proven when audits failed");
  assert(a11yProven(undefined) === false, "a11y NOT proven without a probe");
  assert(viewportProven({ viewport: { proven: true } }) === true, "viewport proven from probe");
  assert(viewportProven(undefined) === false, "viewport NOT proven without a probe");
}

if (failed) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nselftest: all pure-helper + taxonomy + pack-integrity checks passed");
