#!/usr/bin/env node
// Pure-helper + taxonomy fixture smoke for preview-ui-walk (no browser).
//   node selftest.mjs

import { createServer } from "node:http";
import { classifyRisk } from "./classify_risk.mjs";
import { prepareSourceTree, validateReportTree } from "./artifact_publish.mjs";
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
import {
  parseServerTiming,
  sanitizeDomHtml,
  sanitizeEvidenceUrl,
} from "./collectors.mjs";
import {
  buildMatrix,
  checkCollector,
  isMutating,
  requiredEvidence,
  requiredTidewaveTools,
  roleEnvPrefixes,
  runPreflight,
} from "./preflight_run.mjs";
import { verify as verifyPayload } from "./payload_pack.mjs";
import {
  beginPageRuntime,
  classifyRisk as classifyRiskRuntime,
  pageRuntimeLogs,
  probeTidewave,
} from "./runtime_evidence.mjs";
import {
  expandEnvText,
  interactionsAllowed,
  runPageSteps,
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

const interactionCalls = [];
const fakePage = {
  fill: async (...args) => interactionCalls.push(["fill", ...args]),
  waitForTimeout: async (...args) => interactionCalls.push(["wait", ...args]),
};
const fillResult = await runPageSteps(
  fakePage,
  {
    steps: [
      {
        action: "fill",
        selector: "#email",
        text: "demo@test.com",
        wait_ms: 250,
      },
    ],
  },
  {
    manifest: { safety: { allow_interactions: true } },
    runtimeBag: { env_check: { items: [] } },
    base: "http://127.0.0.1:4000",
  },
);
assert(fillResult.status === "PASS", "fill with settle passes");
assert(
  interactionCalls.some(([kind, wait]) => kind === "wait" && wait === 250),
  "fill honors wait_ms",
);
assert(
  requiredTidewaveTools([
    { runtime: { tidewave: true, required_tools: ["project_eval", "custom_probe"] } },
  ]).includes("custom_probe"),
  "explicit Tidewave required_tools are included in preflight",
);
{
  const fsPublish = await import("node:fs");
  const osPublish = await import("node:os");
  const pathPublish = await import("node:path");
  const reportDir = fsPublish.mkdtempSync(
    pathPublish.join(osPublish.tmpdir(), "artifact-publish-selftest-"),
  );
  fsPublish.writeFileSync(
    pathPublish.join(reportDir, "report.html"),
    '<img src="shot.png"><a href="#page-dashboard">dashboard</a>',
  );
  fsPublish.writeFileSync(pathPublish.join(reportDir, "shot.png"), "png");
  assert(
    validateReportTree(reportDir).files.length === 2,
    "artifact publisher validates a complete external-image report",
  );
  fsPublish.writeFileSync(pathPublish.join(reportDir, "report.html"), '<img src="missing.png">');
  let missingReferenceFailed = false;
  try {
    validateReportTree(reportDir);
  } catch {
    missingReferenceFailed = true;
  }
  assert(missingReferenceFailed, "artifact publisher rejects missing local references");
  fsPublish.writeFileSync(pathPublish.join(reportDir, "report.html"), '<img src="shot.png">');
  const workspaceDir = fsPublish.mkdtempSync(
    pathPublish.join(osPublish.tmpdir(), "artifact-workspace-selftest-"),
  );
  const prepared = prepareSourceTree(
    reportDir,
    validateReportTree(reportDir).files,
    workspaceDir,
  );
  assert(prepared.staged, "artifact publisher stages reports outside CASEIN_CHECKOUT");
  assert(
    fsPublish.readFileSync(pathPublish.join(prepared.sourceRoot, "shot.png"), "utf8") === "png",
    "artifact publisher stages the validated report tree",
  );
  prepared.cleanup();
  assert(
    !fsPublish.existsSync(prepared.sourceRoot),
    "artifact publisher removes linked-worktree staging",
  );
  fsPublish.rmSync(workspaceDir, { recursive: true, force: true });
  fsPublish.rmSync(reportDir, { recursive: true, force: true });
}

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
  countRuntimeErrors({
    required_tidewave: true,
    liveview: { status: "error", error: "transport lost" },
  }) === 1,
  "required LiveView evidence loss counts as a runtime error",
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
assert(
  verdictFixture({
    within: false,
    uok: true,
    loaded: true,
    slowIsFailure: true,
  }).status === "SLOW",
  "strict over-budget landing → SLOW",
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

  // Batch 4: REQUIRED evidence that cannot be proven is BLOCKED (exit 2),
  // never merely DEGRADED — running anyway would publish a report that
  // silently lacks evidence the manifest promised.
  const requiredGap = await runPreflight(
    { ...args, manifests: [write("ws.json", manifest({ require_evidence: ["ws"] }))] },
    deps,
  );
  assert(requiredGap.code === EXIT.BLOCKED, "required-but-unproven evidence -> 2 BLOCKED (fail closed)");
  assert(
    requiredGap.json.rows.find((r) => r.id === "ws")?.state === "BLOCKED",
    "the unproven required collector row itself is BLOCKED",
  );
  // …and the same walk with a probe that PROVES ws is READY again.
  const provenWs = await runPreflight(
    { ...args, manifests: [write("ws.json", manifest({ require_evidence: ["ws"] }))] },
    { ...deps, collectorProbe: { ws: { frames: { observable: true } } } },
  );
  assert(provenWs.code === EXIT.READY, "required evidence proven by the probe -> READY");

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

  {
    const pages = [
      { name: "All", path: "/all" },
      { name: "Desktop", path: "/desktop", viewports: ["desktop"] },
    ];
    const expanded = a11y.expandWalkCases(pages, a11y.DEFAULT_VIEWPORTS);
    assert(expanded.cases.length === 3, "logical pages expand into every applicable viewport visit");
    assert(
      expanded.cases.map(({ page, viewport }) => `${page.name}:${viewport.name}`).join(",") ===
        "All:mobile,All:desktop,Desktop:desktop",
      "viewport expansion is page-major and preserves per-page narrowing",
    );
    const implicit = a11y.expandWalkCases([{ name: "V1", path: "/" }], undefined);
    assert(
      implicit.cases.length === 1 &&
        implicit.cases[0].viewport.name === "default" &&
        implicit.cases[0].viewport.implicit === true,
      "omitted viewports retain one explicit default visit",
    );
    const unknown = a11y.expandWalkCases(
      [{ name: "Bad", path: "/", viewports: ["tablet"] }],
      a11y.DEFAULT_VIEWPORTS,
    );
    assert(unknown.unknown.length === 1 && unknown.cases.length === 0, "unknown page viewport is fail-closed");
  }

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
  assert(
    checkCollector("viewport", { required: true, proven: true }).required === true,
    "manifest-required collectors are labelled required in the readiness matrix",
  );
}

assert(
  sanitizeEvidenceUrl("https://user:pass@example.test/path?token=SECRET#frag") ===
    "https://example.test/path",
  "evidence URLs drop userinfo, query values and fragments",
);

// ── Batch 3a: browser + server resource metrics ─────────────────────────────
{
  const rm = await import("./resource_metrics.mjs");
  const { resourceMetricsProven } = await import("./preflight_run.mjs");

  // CDP metric normalization: known names mapped, unknown dropped.
  {
    const n = rm.normalizeCdpMetrics([
      { name: "Nodes", value: 120 },
      { name: "JSHeapUsedSize", value: 2048 },
      { name: "TotallyUnknown", value: 1 },
      { name: "Nodes2", value: 5 },
    ]);
    assert(n.domNodes === 120 && n.jsHeapUsedBytes === 2048, "known CDP metrics mapped to stable keys");
    assert(!("TotallyUnknown" in n) && Object.keys(n).length === 2, "unknown metrics dropped, not passed through");
  }
  assert(rm.normalizeCdpMetrics([]) === null, "no metrics -> null (not an empty object)");
  assert(rm.normalizeCdpMetrics(undefined) === null, "non-array input -> null");
  assert(
    rm.normalizeCdpMetrics([{ name: "Nodes", value: NaN }]) === null,
    "non-finite values are not metrics",
  );

  // Deltas are what attribute a leak to the page that caused it.
  {
    const d = rm.deltaMetrics({ domNodes: 100, jsHeapUsedBytes: 1000 }, { domNodes: 340, jsHeapUsedBytes: 1500 });
    assert(d.domNodes === 240 && d.jsHeapUsedBytes === 500, "delta subtracts the before snapshot");
  }
  assert(rm.deltaMetrics(null, { domNodes: 7 }).domNodes === 7, "no before -> first observation reported as-is");
  assert(rm.deltaMetrics({ domNodes: 1 }, null) === null, "no after -> null delta");
  {
    // A key missing from `before` must not be treated as zero.
    const d = rm.deltaMetrics({ domNodes: 5 }, { domNodes: 9, layoutCount: 3 });
    assert(d.layoutCount === 3, "key absent from before is reported as-is, never invented as a delta");
    assert(!("frames" in d), "keys absent from after are dropped, never invented as zero");
  }

  // Attribution: the point of correlating server and browser cost.
  {
    const server = rm.correlate({
      nav: { ttfbMs: 100 },
      browserDelta: { scriptDurationSec: 0.01 },
      serverTiming: { metrics: [{ name: "db", dur: 80 }] },
    });
    assert(server.attribution === "server", "server-dominated TTFB attributes to server");
    assert(server.serverTotalMs === 80 && server.ttfbMs === 100, "correlation reports both sides");

    const browser = rm.correlate({
      nav: { ttfbMs: 10 },
      browserDelta: { scriptDurationSec: 0.5 },
      serverTiming: { metrics: [{ name: "db", dur: 1 }] },
    });
    assert(browser.attribution === "browser", "script-dominated time attributes to browser");

    const unknown = rm.correlate({ nav: null, browserDelta: null, serverTiming: null });
    assert(unknown.attribution === "unknown", "no signals -> unknown, never a guessed attribution");
  }

  // Fail closed: nothing measurable -> null, not a zeroed report.
  {
    const page = { evaluate: async () => null };
    assert((await rm.collectResourceMetrics(page, { session: null })) === null, "nothing measurable -> null");
    const page2 = { evaluate: async () => ({ ttfbMs: 5, loadMs: 20 }) };
    const ev = await rm.collectResourceMetrics(page2, { session: null });
    assert(ev.observable === true && ev.browser === null, "nav-only still observable, browser side honestly null");
  }
  assert(resourceMetricsProven({ resource_metrics: { observable: true } }) === true, "rm proven when observable");
  assert(resourceMetricsProven({ resource_metrics: { observable: false } }) === false, "rm NOT proven when unobservable");
  assert(resourceMetricsProven(undefined) === false, "rm NOT proven without a probe");
}

// ── Batch 3b: visual baseline evidence ──────────────────────────────────────
{
  const vb = await import("./visual_baseline.mjs");
  const { visualBaselineProven } = await import("./preflight_run.mjs");
  const { mkdtempSync, mkdirSync, writeFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join, dirname } = await import("node:path");

  // Stable key: all four components, session material dropped, isolation real.
  const keyOf = (over = {}) =>
    vb.baselineKey({
      workflow: "admin-smoke",
      pagePath: "/admin/pens?token=SECRET#frag",
      viewport: "desktop",
      sourceIdentity: "one@abc123",
      ...over,
    });
  assert(keyOf() === "admin-smoke/one-abc123/desktop/admin-pens", "key is the four-part slug");
  assert(!keyOf().toLowerCase().includes("secret"), "key never carries query/session material");
  assert(keyOf({ sourceIdentity: "one@def456" }) !== keyOf(), "different source identity -> different key (isolation)");
  assert(keyOf({ viewport: "mobile" }) !== keyOf(), "different viewport -> different key");
  assert(keyOf({ workflow: "other-walk" }) !== keyOf(), "different workflow -> different key");
  assert(keyOf({ pagePath: "/admin/pens" }) === keyOf(), "query/fragment never changes the key");
  for (const missing of ["workflow", "viewport", "sourceIdentity"]) {
    let threw = false;
    try {
      keyOf({ [missing]: "" });
    } catch {
      threw = true;
    }
    assert(threw, `missing ${missing} component throws — no defaulted keys, no merged populations`);
  }
  assert(keyOf({ pagePath: "/" }) === "admin-smoke/one-abc123/desktop/root", "root path keys as root, not empty");

  // Redaction: query, fragment, userinfo are DROPPED, never masked.
  assert(vb.redactPagePath("/x?session=S#f") === "/x", "relative path loses query+fragment");
  assert(vb.redactPagePath("https://u:pw@h:81/x?t=S") === "https://h:81/x", "absolute URL loses userinfo+query");

  // Pixel comparison against the pinned engine.
  const engine = vb.loadDiffEngine();
  assert(Boolean(engine), "pinned pixelmatch+pngjs resolve (scripts/ensure-preview-walk-deps.sh)");
  const basePng = vb.makePng(100, 100, [10, 20, 30, 255], { engine });
  const perturbed = (n) =>
    vb.makePng(100, 100, [10, 20, 30, 255], {
      engine,
      paint: (png) => {
        for (let i = 0; i < n; i++) png.data[i * 4] = 250;
      },
    });
  {
    const r = vb.comparePng(vb.makePng(100, 100, [10, 20, 30, 255], { engine }), basePng, { engine });
    assert(r.comparable === true && r.pass === true && r.changedPixels === 0, "identical pixels PASS with zero changed");
    assert(r.collectorVersion === vb.COLLECTOR_VERSION, "evidence carries the collector version");
  }
  {
    const r = vb.comparePng(perturbed(10), basePng, { engine });
    assert(r.pass === true && r.changedRatio === 0.001, "EXACTLY 0.1% changed passes (the contract is 'exceeds')");
  }
  assert(vb.comparePng(perturbed(9), basePng, { engine }).pass === true, "below 0.1% passes");
  {
    const r = vb.comparePng(perturbed(11), basePng, { engine });
    assert(r.pass === false && r.mismatch === "pixels", "above 0.1% fails as a pixel mismatch");
    assert(r.changedPixels === 11 && r.totalPixels === 10000, "changed-pixel count and total are reported exactly");
    assert(Boolean(r.diffPng), "a diff image is produced for the report");
    assert(/0\.1/.test(r.reason), "failure reason names the threshold");
  }
  {
    const r = vb.comparePng(vb.makePng(100, 90, [10, 20, 30, 255], { engine }), basePng, { engine });
    assert(r.comparable === true && r.pass === false && r.mismatch === "dimensions", "dimension mismatch is a HARD visual failure");
    assert(r.changedPixels === null, "no pixel count is invented for a dimension mismatch");
  }
  {
    const r = vb.comparePng(basePng, basePng, { engine, candidateDpr: 2, baselineDpr: 1 });
    assert(r.pass === false && r.mismatch === "dpr", "DPR mismatch is a HARD visual failure");
  }
  assert(
    vb.comparePng(Buffer.from("not a png"), basePng, { engine }).comparable === false,
    "undecodable candidate -> not comparable (missing evidence, not a fake verdict)",
  );

  // Fake durable store: a real on-disk artifact worktree + a recording JSON-RPC
  // stub, so read/accept are exercised against the actual wire+disk shapes.
  const storeDir = mkdtempSync(join(tmpdir(), "visual-store-"));
  const calls = [];
  const rpcOk = (payload) => ({
    ok: true,
    status: 200,
    json: async () => ({ result: { content: [{ text: JSON.stringify(payload) }] } }),
  });
  const fakeFetch = (worktree) =>
    async (url, init = {}) => {
      const body = JSON.parse(init.body || "{}");
      calls.push({ tool: body?.params?.name, args: body?.params?.arguments });
      if (body?.params?.name === "artifact_list") {
        return rpcOk({
          artifacts: worktree
            ? [{ id: "art-1", name: "visual-baselines-admin-smoke", retired: false, worktree_path: worktree }]
            : [],
        });
      }
      return rpcOk({ id: "art-1" });
    };
  const store = { url: "http://127.0.0.1:1/api/artifacts/mcp", token: "TOKEN-VALUE-NEVER-LOGGED", workspaceId: "ws-1" };
  const manifest = {
    report: { name: "admin-smoke" },
    require_evidence: ["visual_baseline"],
    visual_baseline: { source_identity: "one@abc123" },
    pages: [{ name: "Pens", path: "/admin/pens" }],
  };
  const goodKey = vb.baselineKey({
    workflow: "admin-smoke",
    pagePath: "/admin/pens",
    viewport: "default",
    sourceIdentity: "one@abc123",
  });
  const plant = (png, meta) => {
    const p = join(storeDir, "baselines", goodKey, "baseline.png");
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, png);
    writeFileSync(join(dirname(p), "baseline.json"), JSON.stringify(meta ?? { sourceIdentity: "one@abc123", dpr: 1, sha256: "x" }));
  };

  // Missing baseline (store exists, slot empty) -> unavailable -> BLOCKED.
  {
    calls.length = 0;
    const ev = await vb.collectVisualBaseline({
      shotBytes: basePng,
      manifest,
      pagePath: "/admin/pens",
      viewportName: "default",
      store,
      deps: { fetchImpl: fakeFetch(storeDir) },
    });
    assert(ev.comparable === false && ev.status === "missing_baseline", "missing baseline -> not comparable");
    const v = vb.visualVerdict(true, ev);
    assert(v?.blocked && /visual_baseline/.test(v.blocked.reason), "required + missing baseline -> BLOCKED verdict");
    assert(vb.visualVerdict(false, ev) === null, "not required -> no verdict influence");
  }

  // Accepted baseline present -> compared; the compare path NEVER writes.
  plant(basePng);
  {
    calls.length = 0;
    const ev = await vb.collectVisualBaseline({
      shotBytes: perturbed(11),
      manifest,
      pagePath: "/admin/pens?tok=S",
      viewportName: "default",
      dpr: 1,
      store,
      deps: { fetchImpl: fakeFetch(storeDir) },
    });
    assert(ev.comparable === true && ev.pass === false, "candidate vs accepted baseline compared");
    assert(ev.key === goodKey, "walk key matches the accepted slot despite the query string");
    assert(ev.acceptedSourceIdentity === "one@abc123", "accepted source identity is reported");
    assert(
      calls.every((c) => c.tool === "artifact_list"),
      "walk compare path performs READS only — a walk can never bless new pixels",
    );
    const vf = vb.visualVerdict(true, ev);
    assert(vf?.failed && !vf.blocked, "comparable mismatch -> hard visual failure, not BLOCKED");
    // Secret hygiene: serialized evidence never carries the bearer token.
    const { baselinePng: _b, diffPng: _d, ...pub } = ev;
    assert(!JSON.stringify(pub).includes(store.token), "evidence never contains the store token");
  }

  // Store unreachable / read failure -> BLOCKED, never a silent pass.
  {
    const ev = await vb.collectVisualBaseline({
      shotBytes: basePng,
      manifest,
      pagePath: "/admin/pens",
      viewportName: "default",
      store,
      deps: {
        fetchImpl: async () => {
          throw new Error("ECONNREFUSED");
        },
      },
    });
    assert(ev.comparable === false && ev.status === "store_unreachable", "artifact MCP down -> store_unreachable");
    assert(Boolean(vb.visualVerdict(true, ev)?.blocked), "store failure fails closed as BLOCKED");
  }
  {
    const evNoStore = await vb.collectVisualBaseline({
      shotBytes: basePng,
      manifest,
      pagePath: "/admin/pens",
      viewportName: "default",
      store: null,
    });
    assert(evNoStore.comparable === false && /not configured/.test(evNoStore.reason), "unconfigured store is explicit");
    const evNoSrc = await vb.collectVisualBaseline({
      shotBytes: basePng,
      manifest: { report: { name: "x" }, visual_baseline: {} },
      pagePath: "/p",
      viewportName: "default",
      store,
    });
    assert(/source_identity/.test(evNoSrc.reason), "missing explicit source identity refuses to compare");
  }

  // Explicit acceptance is the ONLY write path, and it writes durable bytes.
  {
    calls.length = 0;
    const res = await vb.acceptBaseline(
      store,
      "visual-baselines-admin-smoke",
      goodKey,
      { png: basePng, meta: { sourceIdentity: "one@abc123", dpr: 1, pagePath: vb.redactPagePath("/admin/pens?t=S") } },
      { fetchImpl: fakeFetch(storeDir), now: () => "2026-01-01T00:00:00.000Z" },
    );
    assert(Boolean(res.ok) && res.ok.artifact_id === "art-1", "explicit accept writes via artifact_update");
    const update = calls.find((c) => c.tool === "artifact_update");
    assert(Boolean(update), "accept targets the existing store artifact");
    const pngFile = update.args.files.find((f) => f.path.endsWith("baseline.png"));
    assert(pngFile.encoding === "base64" && Buffer.from(pngFile.content, "base64").equals(Buffer.from(basePng)), "baseline PNG round-trips as base64 bytes");
    const metaFile = update.args.files.find((f) => f.path.endsWith("baseline.json"));
    const record = JSON.parse(metaFile.content);
    assert(record.sha256 && record.collectorVersion === vb.COLLECTOR_VERSION && record.acceptedAt === "2026-01-01T00:00:00.000Z", "accepted record carries sha256 + collector version + acceptance time");
    assert(!metaFile.content.includes("t=S"), "accepted metadata never retains query material");

    calls.length = 0;
    const created = await vb.acceptBaseline(
      store,
      "visual-baselines-admin-smoke",
      goodKey,
      { png: basePng, meta: {} },
      { fetchImpl: fakeFetch(null), now: () => "2026-01-01T00:00:00.000Z" },
    );
    assert(calls.some((c) => c.tool === "artifact_create") && Boolean(created.ok), "first accept creates the durable store artifact");

    const failed_ = await vb.acceptBaseline(
      store,
      "visual-baselines-admin-smoke",
      goodKey,
      { png: basePng, meta: {} },
      {
        fetchImpl: async (url, init = {}) => {
          const body = JSON.parse(init.body || "{}");
          if (body?.params?.name === "artifact_list") {
            return rpcOk({ artifacts: [{ id: "art-1", name: "visual-baselines-admin-smoke", retired: false }] });
          }
          return { ok: true, status: 200, json: async () => ({ result: { isError: true, content: [{ text: "disk full" }] } }) };
        },
      },
    );
    assert(Boolean(failed_.error) && /disk full/.test(failed_.error), "artifact write failure surfaces loudly, never a silent accept");
  }

  // Verdict taxonomy integration.
  assert(
    verdictFixture({ visualBlocked: { reason: "required evidence unavailable: visual_baseline (missing_baseline)" } }).status === "BLOCKED",
    "visual evidence unavailable -> BLOCKED page",
  );
  assert(
    verdictFixture({ visualFailed: { reason: "visual baseline: changed pixels 0.2% > 0.1%" } }).status === "ASSERT_FAILED",
    "visual mismatch -> ASSERT_FAILED page",
  );
  assert(
    verdictFixture({ mainStatus: 500, visualBlocked: { reason: "x" } }).status === "CRASHED",
    "a crash outranks missing visual evidence",
  );
  assert(
    verdictFixture({ visualBlocked: { reason: "x" }, actionableConsole: ["e"] }).status === "BLOCKED",
    "missing visual evidence is decided BEFORE browser-error assertions (fail closed)",
  );

  // Preflight readiness: required visual evidence classifies missing artifact
  // connectivity / baselines as BLOCKED — read-only, no baseline created.
  {
    const proof = { observable: true };
    const none = await vb.checkVisualBaselineReadiness([manifest], { store: null, deps: { engineProof: proof } });
    assert(none.state === "BLOCKED" && /not configured/.test(none.detail), "no artifact store -> BLOCKED");
    const unreachable = await vb.checkVisualBaselineReadiness([manifest], {
      store,
      deps: { engineProof: proof, fetchImpl: async () => { throw new Error("down"); } },
    });
    assert(unreachable.state === "BLOCKED" && /unavailable/.test(unreachable.detail), "unreachable store -> BLOCKED");
    calls.length = 0;
    const present = await vb.checkVisualBaselineReadiness([manifest], {
      store,
      deps: { engineProof: proof, fetchImpl: fakeFetch(storeDir) },
    });
    assert(present.state === "OK", "accepted baseline present -> OK");
    assert(calls.every((c) => c.tool === "artifact_list"), "preflight readiness performs READS only");
    const missingBl = await vb.checkVisualBaselineReadiness(
      [{ ...manifest, pages: [{ name: "Other", path: "/admin/other" }] }],
      { store, deps: { engineProof: proof, fetchImpl: fakeFetch(storeDir) } },
    );
    assert(missingBl.state === "BLOCKED" && /accept explicitly/.test(missingBl.detail), "missing accepted baseline -> BLOCKED with the accept hint");
    const noIdentity = await vb.checkVisualBaselineReadiness(
      [{ ...manifest, visual_baseline: {} }],
      { store, deps: { engineProof: proof, fetchImpl: fakeFetch(storeDir) } },
    );
    assert(noIdentity.state === "BLOCKED" && /source_identity/.test(noIdentity.detail), "undeclared source identity -> BLOCKED");
    const badEngine = await vb.checkVisualBaselineReadiness([manifest], {
      store,
      deps: { engineProof: { observable: false, reason: "no pixelmatch" } },
    });
    assert(badEngine.state === "BLOCKED" && /ensure-preview-walk-deps/.test(badEngine.detail), "unproven diff engine -> BLOCKED with the provisioning hint");
  }
  // End-to-end --preflight-only: required visual evidence drives the exit code.
  {
    const dir = mkdtempSync(join(tmpdir(), "visual-preflight-"));
    const manifestPath = join(dir, "walk.json");
    writeFileSync(
      manifestPath,
      JSON.stringify({
        version: 1,
        login: { kind: "none" },
        pages: [{ name: "Pens", path: "/admin/pens" }],
        safety: { read_only: true },
        report: { name: "admin-smoke" },
        require_evidence: ["visual_baseline"],
        visual_baseline: { source_identity: "one@abc123" },
      }),
    );
    const pfDeps = {
      env: { MIX_ENV: "dev" },
      resolveChromium: () => ({}),
      chromiumPath: () => null,
      freeBytes: 4 * 1024 ** 3,
      leakedSessions: 0,
      now: "2026-01-01T00:00:00.000Z",
      stdout: () => {},
      visualEngineProof: { observable: true },
    };
    const pfArgs = { manifests: [manifestPath], base: "http://127.0.0.1:1" };
    const noStore = await runPreflight(pfArgs, { ...pfDeps, fetchImpl: async () => ({ status: 200 }), artifactStore: null });
    assert(noStore.code === EXIT.BLOCKED, "required visual evidence + no artifact store -> preflight BLOCKED (exit 2)");
    assert(
      noStore.json.rows.find((r) => r.id === "visual_baseline")?.state === "BLOCKED",
      "the visual_baseline row itself is BLOCKED, not merely MISSING",
    );
    const withStore = await runPreflight(pfArgs, {
      ...pfDeps,
      fetchImpl: fakeFetch(storeDir),
      artifactStore: store,
    });
    assert(withStore.code === EXIT.READY, "engine proven + store reachable + baseline accepted -> READY");
  }

  assert(visualBaselineProven({ visual_baseline: { observable: true } }) === true, "vb proven when probe observable");
  assert(visualBaselineProven({ visual_baseline: { observable: false } }) === false, "vb NOT proven when probe failed");
  assert(visualBaselineProven(undefined) === false, "vb NOT proven without a probe");

  // The engine self-proof used by preflight.
  assert(vb.proveDiffEngine().observable === true, "scratch-fixture diff-engine proof passes end-to-end");

  // Packed-driver wiring markers (guards against a repack dropping the wiring),
  // and the structural guarantee that the driver cannot accept baselines.
  {
    const { unpack } = await import("./payload_pack.mjs");
    const src = unpack();
    assert(src.includes("collectVisualBaseline"), "packed driver collects visual evidence");
    assert(src.includes("visualBlocked:") && src.includes("visualFailed:"), "packed driver folds visual verdicts fail-closed");
    assert(src.includes("require_evidence") && src.includes("visual_baseline"), "packed driver gates on require_evidence visual_baseline");
    assert(!src.includes("acceptBaseline"), "packed driver has NO acceptance path — walks structurally cannot bless pixels");
  }
}

// ── Batch 3b: real-Chromium visual fixture (skipped only when no browser) ────
{
  let chromium = null;
  let exe = null;
  try {
    const { createRequire } = await import("node:module");
    const { execFileSync } = await import("node:child_process");
    const os = await import("node:os");
    const fsx = await import("node:fs");
    const pathx = await import("node:path");
    const globalRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
    const req = createRequire(pathx.join(globalRoot, "x.js"));
    chromium = req("playwright-core").chromium;
    const root = pathx.join(os.homedir(), ".cache", "ms-playwright");
    const dirs = fsx.readdirSync(root).filter((d) => /^chromium-\d+$/.test(d)).sort();
    for (const d of dirs.reverse()) {
      for (const [sub, bin] of [["chrome-linux64", "chrome"], ["chrome-linux", "chrome"]]) {
        const cand = pathx.join(root, d, sub, bin);
        if (fsx.existsSync(cand)) {
          exe = cand;
          break;
        }
      }
      if (exe) break;
    }
  } catch {
    /* unresolvable -> skip below */
  }
  if (!chromium || !exe || process.env.PREVIEW_WALK_SELFTEST_NO_BROWSER === "1") {
    console.log("skip: real-Chromium visual fixture (playwright-core/chromium unavailable)");
  } else {
    const vb = await import("./visual_baseline.mjs");
    const browser = await chromium.launch({ executablePath: exe, headless: true });
    try {
      const page = await browser.newPage({ viewport: { width: 320, height: 240 } });
      await page.setContent(
        "<html><body style='margin:0;background:#123456'><div style='width:120px;height:120px;background:#abcdef'>stable</div></body></html>",
      );
      const first = await page.screenshot({ type: "png" });
      const second = await page.screenshot({ type: "png" });
      const identical = vb.comparePng(second, first);
      assert(
        identical.comparable === true && identical.pass === true && identical.changedPixels === 0,
        "real Chromium: identical captures compare with zero changed pixels",
      );
      await page.setContent(
        "<html><body style='margin:0;background:#123456'><div style='width:120px;height:120px;background:#ff0000'>changed</div></body></html>",
      );
      const mutated = await page.screenshot({ type: "png" });
      const changed = vb.comparePng(mutated, first);
      assert(
        changed.comparable === true && changed.pass === false && changed.changedRatio > 0.001,
        "real Chromium: a visible mutation exceeds the 0.1% gate",
      );
    } finally {
      await browser.close();
    }
  }
}

// ── Batch 4: shared dep resolution ───────────────────────────────────────────
{
  const r = await import("./resolve_dep.mjs");
  assert(Boolean(r.resolvePlaywrightCore()?.chromium), "shared resolver finds playwright-core (no NODE_PATH needed)");
  assert(Boolean(r.resolveWs()?.WebSocketServer), "shared resolver finds ws");
  assert(Boolean(r.resolveDiffEngine()), "shared resolver finds pixelmatch+pngjs");
  assert(r.resolveDep("definitely-not-a-real-pkg-xyz") === null, "unknown dep -> null, never a throw");
}

// ── Batch 4: bounded retries + flakiness ─────────────────────────────────────
{
  const rp = await import("./retry_policy.mjs");
  const readOnlyPage = { name: "P", path: "/p", steps: [{ action: "assert_text", text: "x" }] };
  const mutatingPage = { name: "M", path: "/m", steps: [{ action: "click", selector: "#b" }] };
  const cleanupPage = { name: "C", path: "/c", cleanup_steps: [{ action: "click", selector: "#del" }] };

  {
    const p = rp.retryPolicy({ retries: { max_attempts: 3 } }, readOnlyPage);
    assert(p.maxAttempts === 3, "read-only page honors max_attempts");
    assert(p.retryOn.has("TIMEOUT") && p.retryOn.has("RUNTIME_ERROR"), "default retryable set is TIMEOUT+RUNTIME_ERROR");
    assert(rp.shouldRetry("TIMEOUT", 1, p) === true, "TIMEOUT on attempt 1 retries");
    assert(rp.shouldRetry("TIMEOUT", 3, p) === false, "attempts are bounded at max_attempts");
    assert(rp.shouldRetry("PASS", 1, p) === false, "a pass never retries");
    assert(rp.shouldRetry("ASSERT_FAILED", 1, p) === false, "ASSERT_FAILED never retries");
  }
  {
    const p = rp.retryPolicy({ retries: { max_attempts: 4, retry_on: ["TIMEOUT", "ASSERT_FAILED", "BOUNCED"] } }, readOnlyPage);
    assert(p.retryOn.has("TIMEOUT") && !p.retryOn.has("ASSERT_FAILED") && !p.retryOn.has("BOUNCED"), "unsafe retry_on statuses are dropped, never honored");
    assert(p.droppedStatuses.join(",") === "ASSERT_FAILED,BOUNCED", "dropped statuses are recorded, not silently ignored");
  }
  {
    const p = rp.retryPolicy({ retries: { max_attempts: 5, retry_on: ["TIMEOUT"] } }, mutatingPage);
    assert(p.maxAttempts === 1, "mutating page pinned to ONE attempt regardless of manifest");
    assert(/never replayed/.test(p.reason), "the pin is explained, not silent");
    assert(rp.shouldRetry("TIMEOUT", 1, p) === false, "a mutating page NEVER replays");
  }
  assert(
    rp.retryPolicy({ retries: { max_attempts: 5 } }, cleanupPage).maxAttempts === 1,
    "mutating cleanup_steps also pin the page to one attempt",
  );
  assert(rp.pageHasMutatingSteps(mutatingPage) && rp.pageHasMutatingSteps(cleanupPage), "mutation detection covers steps and cleanup_steps");
  assert(rp.pageHasMutatingSteps(readOnlyPage) === false, "assert-only steps stay read-only");

  {
    const p = rp.retryPolicy({ retries: { max_attempts: 3 } }, readOnlyPage);
    assert(rp.flakinessEvidence([{ status: "PASS", ms: 100 }], p) === null, "single clean attempt -> no flakiness record");
    const f = rp.flakinessEvidence([{ status: "TIMEOUT", ms: 900 }, { status: "PASS", ms: 200 }], p);
    assert(f.flaky === true && f.attemptCount === 2 && f.finalStatus === "PASS", "disagreeing attempts mark the page flaky even when it ends green");
    const same = rp.flakinessEvidence([{ status: "TIMEOUT", ms: 1 }, { status: "TIMEOUT", ms: 2 }], p);
    assert(same.flaky === false, "agreeing attempts are not flaky — just consistently failing");
  }

  // Verdict integration.
  assert(
    verdictFixture({ evidenceBlocked: { reason: "required evidence unavailable: api", missingEvidence: ["api"] } }).status === "BLOCKED",
    "required api/downloads/cleanup evidence missing -> BLOCKED page",
  );
  assert(
    verdictFixture({ evidenceBlocked: { reason: "x" }, actionableConsole: ["e"] }).status === "BLOCKED",
    "missing evidence is decided BEFORE browser-error assertions",
  );
  assert(
    verdictFixture({ mainStatus: 500, evidenceBlocked: { reason: "x" } }).status === "CRASHED",
    "a crash outranks missing evidence",
  );
  assert(
    verdictFixture({ cleanupFailed: { reason: "cleanup failed: 1 step(s) did not pass" } }).status === "ASSERT_FAILED",
    "failed cleanup -> ASSERT_FAILED (fixtures may be left behind)",
  );
}

// ── Batch 4: API-request + download + cleanup evidence ───────────────────────
{
  const api = await import("./api_evidence.mjs");
  assert(api.sanitizeUrl("http://h:81/api/x?token=SECRET#f") === "http://h:81/api/x", "API URLs lose query+fragment");

  const fakePage = () => {
    const handlers = {};
    return {
      on: (ev, fn) => { handlers[ev] = fn; },
      off: (ev) => { delete handlers[ev]; },
      emit: (ev, arg) => handlers[ev] && handlers[ev](arg),
    };
  };
  const fakeResponse = ({ url, status = 200, type = "fetch", ms = 12.3 }) => ({
    url: () => url,
    status: () => status,
    request: () => ({
      resourceType: () => type,
      method: () => "GET",
      timing: () => ({ responseEnd: ms }),
    }),
  });

  {
    const page = fakePage();
    const tap = api.attachApi(page);
    page.emit("response", fakeResponse({ url: "http://h/api/a?tok=S" }));
    page.emit("response", fakeResponse({ url: "http://h/api/b", status: 500 }));
    page.emit("response", fakeResponse({ url: "http://h/img.png", type: "image" }));
    const ev = tap.stop();
    assert(ev.entryCount === 2, "only xhr/fetch traffic is captured");
    assert(ev.failedCount === 1, "≥400 responses are counted as failed");
    assert(ev.entries.every((e) => !e.url.includes("?") && !e.url.includes("S" + "ECRET")), "captured URLs are sanitized");
    assert(ev.entries[0].ms === 12.3, "timing is recorded");
  }
  {
    const page = fakePage();
    const tap = api.attachApi(page, { maxEntries: 1 });
    page.emit("response", fakeResponse({ url: "http://h/api/a" }));
    page.emit("response", fakeResponse({ url: "http://h/api/b" }));
    const ev = tap.stop();
    assert(ev.entryCount === 1 && ev.truncated === true && ev.dropped === 1, "entry cap reports what it dropped");
  }
  assert(api.attachApi(fakePage()).stop() === null, "no API traffic -> null evidence (fails closed when required)");

  {
    const page = fakePage();
    const tap = api.attachDownloads(page);
    page.emit("download", { url: () => "http://h/export.csv?sid=S", suggestedFilename: () => "export.csv" });
    const ev = tap.stop();
    assert(ev.entryCount === 1 && ev.entries[0].filename === "export.csv", "download metadata captured");
    assert(!ev.entries[0].url.includes("?"), "download source URL sanitized");
  }
  assert(api.attachDownloads(fakePage()).stop() === null, "no downloads -> null evidence");

  assert(api.cleanupEvidence(null) === null, "no cleanup ran -> null evidence");
  assert(api.cleanupEvidence({ ran: 0, failed: 0, steps: [] }) === null, "zero steps ran -> null (gate blocked or nothing declared)");
  {
    const ok = api.cleanupEvidence({ ran: 2, failed: 0, steps: [{ name: "del", action: "click", status: "PASS" }] });
    assert(ok.passed === true, "clean cleanup passes");
    const bad = api.cleanupEvidence({ ran: 2, failed: 1, steps: [{ name: "del", action: "click", status: "FAIL" }] });
    assert(bad.passed === false && bad.failed === 1, "failed cleanup is failed evidence, not absence");
  }

  // evidenceGuard fail-closed wiring for the new keys.
  assert(
    evidenceGuard(["api"], { api: null })?.status === "BLOCKED",
    "required api evidence null -> BLOCKED via evidenceGuard",
  );
  assert(evidenceGuard(["cleanup"], { cleanup: { passed: true, ran: 1 } }) === null, "present cleanup evidence satisfies the guard");
}

// ── Batch 4: presweep health attestation + real probes ──────────────────────
{
  const pf = await import("./preflight_run.mjs");

  // Deployment identity parsing: exact env + 40-char revision or refusal.
  const sha40 = "a".repeat(40);
  {
    const id = pf.parseDeploymentIdentity({ environment: "dev", git_sha: sha40 });
    assert(id.environment === "dev" && id.revision === sha40, "env + 40-char sha parsed exactly");
  }
  {
    const id = pf.parseDeploymentIdentity({
      status: "ok",
      deployment: { environment: "dev", revision: sha40 },
    });
    assert(
      id.environment === "dev" && id.revision === sha40,
      "nested health deployment envelope parsed exactly",
    );
  }
  assert(pf.parseDeploymentIdentity({ environment: "dev", git_sha: "d3888dd5" }).revision === null, "short sha refused");
  assert(/40-char/.test(pf.parseDeploymentIdentity({ environment: "dev", git_sha: "v1.2.3" }).reason), "version labels refused with a named reason");
  assert(/environment/.test(pf.parseDeploymentIdentity({ git_sha: sha40 }).reason), "missing environment named");
  assert(pf.parseDeploymentIdentity("nope").revision === null, "non-object deployment data refused");

  {
    const okFetch = async () => ({ status: 200, json: async () => ({ environment: "dev", revision: sha40 }) });
    const r = await pf.checkDeploymentIdentity("http://127.0.0.1:1/health?probe=S", { fetchImpl: okFetch });
    assert(r.state === "OK" && r.detail.includes(`rev=${sha40}`) && r.detail.includes("env=dev"), "identity row attests exact env + revision");
    assert(!r.detail.includes("probe=S"), "health URL in the matrix is sanitized (query dropped)");
    const bad = await pf.checkDeploymentIdentity("http://127.0.0.1:1/health", {
      fetchImpl: async () => ({ status: 200, json: async () => ({ environment: "dev", sha: "short" }) }),
    });
    assert(bad.state === "MISSING", "unparseable identity is MISSING, never invented");
    const down = await pf.checkDeploymentIdentity("http://127.0.0.1:1/health", {
      fetchImpl: async () => { throw new Error("ECONNREFUSED"); },
    });
    assert(down.state === "MISSING" && /unreachable/.test(down.detail), "unreachable health url reported honestly");
    const none = await pf.checkDeploymentIdentity(null, { base: "http://b", manifestCount: 1 });
    assert(none.state === "OK" && /unattested/.test(none.detail), "no health url -> honest unattested placeholder");
  }

  // Operator expectation verification: exact equality or BLOCKED, and the
  // health check stays GET-only.
  {
    const deployed = { environment: "dev", revision: sha40 };
    const seen = [];
    const okFetch = async (url, init = {}) => {
      seen.push({ url: String(url), method: init.method || "GET" });
      return { status: 200, json: async () => deployed };
    };
    const verify = (over = {}) =>
      pf.checkDeploymentIdentity("http://127.0.0.1:1/health", {
        fetchImpl: okFetch,
        expectEnvironment: "dev",
        expectRevision: sha40,
        ...over,
      });

    const match = await verify();
    assert(match.state === "OK" && /matches operator expectation/.test(match.detail), "exact env + revision match -> OK, marked verified");
    assert(seen.every((r) => r.method === "GET"), "identity verification traffic is GET-only");

    const wrongEnv = await verify({ expectEnvironment: "staging" });
    assert(wrongEnv.state === "BLOCKED" && /environment mismatch/.test(wrongEnv.detail), "wrong environment -> BLOCKED");

    const wrongRev = await verify({ expectRevision: "b".repeat(40) });
    assert(wrongRev.state === "BLOCKED" && /revision mismatch/.test(wrongRev.detail), "wrong revision -> BLOCKED");

    const before = seen.length;
    const malformed = await verify({ expectRevision: "d3888dd5" });
    assert(malformed.state === "BLOCKED" && /40-char/.test(malformed.detail), "malformed expected revision -> BLOCKED");
    assert(seen.length === before, "malformed expectation fails closed BEFORE any network");

    const upper = await verify({ expectRevision: sha40.toUpperCase() });
    assert(upper.state === "OK", "revision comparison is case-insensitive hex");

    const noUrl = await pf.checkDeploymentIdentity(null, { expectEnvironment: "dev" });
    assert(noUrl.state === "BLOCKED" && /no --health-url/.test(noUrl.detail), "expectations without a health url -> BLOCKED");

    const unreachable = await pf.checkDeploymentIdentity("http://127.0.0.1:1/health", {
      fetchImpl: async () => { throw new Error("down"); },
      expectEnvironment: "dev",
    });
    assert(unreachable.state === "BLOCKED", "expectations + unreachable health url -> BLOCKED (was MISSING in record mode)");

    const unparseable = await pf.checkDeploymentIdentity("http://127.0.0.1:1/health", {
      fetchImpl: async () => ({ status: 200, json: async () => ({ environment: "dev", sha: "short" }) }),
      expectEnvironment: "dev",
    });
    assert(unparseable.state === "BLOCKED", "expectations + malformed deployed identity -> BLOCKED");
  }

  // End-to-end: a mismatch drives the preflight exit code to 2.
  {
    const { mkdtempSync, writeFileSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const dir = mkdtempSync(join(tmpdir(), "identity-preflight-"));
    const manifestPath = join(dir, "walk.json");
    writeFileSync(
      manifestPath,
      JSON.stringify({
        version: 1,
        login: { kind: "none" },
        pages: [{ name: "P", path: "/p" }],
        safety: { read_only: true },
        report: { name: "t" },
      }),
    );
    const okFetch = async (url) =>
      String(url).includes("/health")
        ? { status: 200, json: async () => ({ environment: "dev", revision: sha40 }) }
        : { status: 200 };
    const base = {
      env: { MIX_ENV: "dev" },
      fetchImpl: okFetch,
      resolveChromium: () => ({}),
      chromiumPath: () => null,
      freeBytes: 4 * 1024 ** 3,
      leakedSessions: 0,
      now: "2026-01-01T00:00:00.000Z",
      stdout: () => {},
    };
    const argsBase = {
      manifests: [manifestPath],
      base: "http://127.0.0.1:1",
      healthUrl: "http://127.0.0.1:1/health",
      expectEnvironment: "dev",
      expectRevision: sha40,
    };
    const good = await runPreflight(argsBase, base);
    assert(good.code === EXIT.READY, "verified identity -> READY");
    const bad = await runPreflight({ ...argsBase, expectRevision: "c".repeat(40) }, base);
    assert(bad.code === EXIT.BLOCKED, "identity mismatch -> preflight exit 2 BLOCKED");
    // Env-var path: WALK_EXPECT_* behaves identically to the flags.
    const viaEnv = await runPreflight(
      { manifests: [manifestPath], base: "http://127.0.0.1:1", healthUrl: "http://127.0.0.1:1/health" },
      { ...base, env: { MIX_ENV: "dev", WALK_EXPECT_ENVIRONMENT: "staging" } },
    );
    assert(viaEnv.code === EXIT.BLOCKED, "WALK_EXPECT_ENVIRONMENT mismatch -> BLOCKED via env vars");
  }

  // Tidewave: tools/list proves the exact collectors, required gaps BLOCKED.
  {
    const response = (status, payload) => ({
      status,
      text: async () => JSON.stringify(payload),
    });
    const allTools = {
      result: {
        tools: [
          { name: "get_logs" },
          { name: "project_eval" },
          { name: "execute_sql_query" },
        ],
      },
    };
    const ok = await pf.checkTidewave("http://127.0.0.1:1/tidewave/mcp?x=S", {
      fetchImpl: async () => response(200, allTools),
      requiredTools: ["get_logs", "project_eval"],
    });
    assert(ok.state === "OK" && !ok.detail.includes("x=S"), "tidewave tools/list -> OK, url sanitized");
    const http404 = await pf.checkTidewave("http://127.0.0.1:1/tidewave/mcp", {
      fetchImpl: async () => response(404, { error: "not found" }),
      required: true,
    });
    assert(http404.state === "BLOCKED" && /HTTP 404/.test(http404.detail), "required tidewave HTTP 404 -> BLOCKED");
    const missingTool = await pf.checkTidewave("http://127.0.0.1:1/tidewave/mcp", {
      fetchImpl: async () => response(200, { result: { tools: [{ name: "get_logs" }] } }),
      required: true,
      requiredTools: ["get_logs", "project_eval"],
    });
    assert(
      missingTool.state === "BLOCKED" && /project_eval/.test(missingTool.detail),
      "required tidewave collector missing -> BLOCKED",
    );
    const reqDown = await pf.checkTidewave("http://127.0.0.1:1/tidewave/mcp", {
      fetchImpl: async () => { throw new Error("down"); },
      required: true,
    });
    assert(reqDown.state === "BLOCKED", "required tidewave unreachable -> BLOCKED");
    const optNone = await pf.checkTidewave(null, {});
    assert(optNone.state === "SKIP", "no tidewave url and not required -> SKIP");
    const reqNone = await pf.checkTidewave(null, { required: true });
    assert(reqNone.state === "BLOCKED", "required tidewave with no url -> BLOCKED");

    const tools = requiredTidewaveTools(
      [{ runtime: { tidewave: true }, pages: [{ runtime: { sql: "SELECT 1" } }] }],
      new Set(),
    );
    assert(
      tools.join(",") === "execute_sql_query,get_logs,project_eval",
      "manifest runtime needs map to exact Tidewave tools",
    );

    const server = createServer((_req, res) => {
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "not found" }));
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    try {
      const probe = await probeTidewave(
        `http://127.0.0.1:${address.port}/tidewave/mcp`,
      );
      assert(
        probe.ok === false && /HTTP 404/.test(probe.error),
        "runtime Tidewave probe rejects a JSON HTTP 404",
      );
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }

    let attempts = 0;
    const retryServer = createServer((_req, res) => {
      attempts++;
      if (attempts < 3) {
        res.writeHead(503, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "warming" }));
        return;
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          result: { tools: [{ name: "get_logs" }, { name: "project_eval" }] },
        }),
      );
    });
    await new Promise((resolve) => retryServer.listen(0, "127.0.0.1", resolve));
    const retryAddress = retryServer.address();
    try {
      const probe = await probeTidewave(
        `http://127.0.0.1:${retryAddress.port}/tidewave/mcp`,
        ["project_eval"],
      );
      assert(
        probe.ok === true && probe.attempts === 3 && attempts === 3,
        "runtime Tidewave probe retries transient 5xx with a bounded attempt count",
      );
      const missing = await probeTidewave(
        `http://127.0.0.1:${retryAddress.port}/tidewave/mcp`,
        ["execute_sql_query"],
      );
      assert(
        missing.ok === false && missing.missing_tools.includes("execute_sql_query"),
        "runtime Tidewave probe enforces explicit required tool inventory",
      );
    } finally {
      await new Promise((resolve) => retryServer.close(resolve));
    }

    const logSnapshots = [
      "baseline\n[error] ** (RuntimeError) late page A lib/one_web/a.ex:10",
      "baseline\n[error] ** (RuntimeError) late page A lib/one_web/a.ex:10\n[error] ** (RuntimeError) page B lib/one_web/b.ex:20",
    ];
    let logSnapshot = 0;
    const logServer = createServer((_req, res) => {
      const text = logSnapshots[Math.min(logSnapshot, logSnapshots.length - 1)];
      logSnapshot++;
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: logSnapshot,
          result: { content: [{ type: "text", text }] },
        }),
      );
    });
    await new Promise((resolve) => logServer.listen(0, "127.0.0.1", resolve));
    const logAddress = logServer.address();
    try {
      const runtimeBag = {
        require_tidewave: true,
        log_levels: ["error"],
        tidewave: {
          status: "ok",
          url: `http://127.0.0.1:${logAddress.port}/tidewave/mcp`,
        },
        stability_failures: [],
        between_page_logs: [],
        between_page_error_log_total: 0,
        boundary_evidence_failures: 0,
        _log_cursors: { error: "baseline" },
        _last_page: "Page A",
      };
      const boundary = await beginPageRuntime(runtimeBag, { name: "Page B" }, {});
      const pageLogs = await pageRuntimeLogs(runtimeBag, "Page B");
      assert(
        boundary.error_log_count === 1 &&
          boundary.previous_page === "Page A" &&
          boundary.next_page === "Page B" &&
          runtimeBag.between_page_logs.length === 1,
        "pre-navigation boundary preserves late prior-page logs as walk-level evidence",
      );
      assert(
        countRuntimeErrors(boundary) === 1 &&
          pageLogs.error_log_count === 1 &&
          pageLogs.logs.levels.error.samples[0].includes("page B"),
        "pre-navigation boundary prevents late prior-page logs from charging the next page",
      );
    } finally {
      await new Promise((resolve) => logServer.close(resolve));
    }

    const downServer = createServer((_req, res) => {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "down" }));
    });
    await new Promise((resolve) => downServer.listen(0, "127.0.0.1", resolve));
    const downAddress = downServer.address();
    try {
      const pageLogs = await pageRuntimeLogs(
        {
          require_tidewave: true,
          log_levels: ["error"],
          tidewave: {
            status: "ok",
            url: `http://127.0.0.1:${downAddress.port}/tidewave/mcp`,
          },
          _log_cursors: {},
        },
        "Dashboard",
      );
      assert(
        pageLogs.status === "error" && pageLogs.runtime_error_count === 1,
        "required per-page Tidewave loss becomes a runtime error, not an empty green delta",
      );
    } finally {
      await new Promise((resolve) => downServer.close(resolve));
    }
  }

  // Artifact store: read-only artifact_list round-trip; token never leaks.
  {
    const store = { url: "http://127.0.0.1:1/api/artifacts/mcp", token: "TOKEN-NEVER-SHOWN", workspaceId: "ws" };
    const ok = await pf.checkArtifactStore({
      store,
      fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ result: { content: [{ text: JSON.stringify({ count: 2, artifacts: [] }) }] } }) }),
    });
    assert(ok.state === "OK" && !ok.detail.includes("TOKEN"), "artifact_list ok -> OK, token never in detail");
    const reqDown = await pf.checkArtifactStore({ store, required: true, fetchImpl: async () => { throw new Error("down"); } });
    assert(reqDown.state === "BLOCKED", "required artifact store unreachable -> BLOCKED");
    const none = await pf.checkArtifactStore({ store: null, required: true });
    assert(none.state === "BLOCKED" && /not configured/.test(none.detail), "required artifact store unconfigured -> BLOCKED");
  }

  assert(pf.previewCookieProven({ preview_cookie: { observable: true } }) === true, "preview cookie proven from probe");
  assert(pf.previewCookieProven(undefined) === false, "preview cookie NOT proven without a probe");
  assert(pf.apiProven({ api: { observable: true } }) === true && pf.apiProven(undefined) === false, "api proven only via probe");
  assert(pf.downloadsProven({ downloads: { observable: true } }) === true && pf.downloadsProven(undefined) === false, "downloads proven only via probe");
}

// ── Batch 4: packed-driver wiring markers ────────────────────────────────────
{
  const { unpack } = await import("./payload_pack.mjs");
  const src = unpack();
  assert(src.includes("class LoginFailure"), "packed driver has the typed login failure");
  assert(src.includes("writeLoginFailureArtifacts"), "packed driver writes matrix+screenshot+results+report on login failure");
  assert(src.includes("login-failure.png"), "login-failure screenshot is part of the evidence set");
  assert(src.includes("retryPolicy") && src.includes("shouldRetry") && src.includes("flakinessEvidence"), "packed driver wires bounded retries");
  assert(src.includes("attachApi") && src.includes("attachDownloads") && src.includes("cleanupEvidence"), "packed driver wires api/download/cleanup evidence");
  assert(
    src.includes("attachHar") &&
      src.includes("collectDomSnapshot") &&
      src.includes("collectA11y") &&
      src.includes("collectResourceMetrics"),
    "packed driver wires every collector required by the full product manifests",
  );
  assert(
    src.includes("expandWalkCases") &&
      src.includes("applyViewport") &&
      src.includes("collectViewportEvidence") &&
      src.includes("casesByDpr") &&
      src.includes("deviceScaleFactor,"),
    "packed driver executes and attests every declared viewport in a DPR-correct context",
  );
  assert(
    src.includes("const page = await context.newPage()") &&
      src.includes("await page.close()") &&
      src.includes("await loginPage.close()") &&
      !src.includes("session.page"),
    "packed driver isolates every visit from stale LiveView navigation while reusing auth context",
  );
  assert(src.includes("cleanup_steps"), "packed driver runs finally-style cleanup steps");
  assert(
    src.includes("settlePage(page, a.settleMs)") &&
      !src.includes("waitForTimeout(a.settleMs)"),
    "packed driver uses bounded adaptive readiness instead of a fixed per-page sleep",
  );
  assert(
    src.includes("await beginPageRuntime(runtimeBag, pg, m);") &&
      src.indexOf("await beginPageRuntime(runtimeBag, pg, m);") <
        src.indexOf("let { loaded, navOutcome, bounceHit } = await navigatePage"),
    "packed driver establishes a Tidewave log boundary before page navigation",
  );
  assert(
    src.includes('shot_file: shot ? shotFile : null') &&
      !src.includes('shotBuf.toString("base64")'),
    "packed report references external screenshots instead of embedding duplicate base64",
  );
  assert(
    src.includes('evidence_layout: "per-page-v1"') &&
      src.includes("evidenceFileFor(result, index)") &&
      src.includes("compactResult(result, evidenceFile)") &&
      src.includes("Full evidence (JSON)") &&
      !src.includes('detailJson("Tidewave", rt)') &&
      !src.includes('detailJson("Evidence", {'),
    "packed report stores full evidence in bounded per-page JSON files",
  );
  assert(src.includes("acceptDownloads: true"), "browser context accepts downloads for download evidence");
  assert(src.includes("evidenceBlocked:"), "packed driver folds required-evidence gaps fail-closed");
  assert(src.includes("--health-url"), "packed driver exposes the health attestation flag");
  assert(
    src.includes("--expect-environment") && src.includes("--expect-revision"),
    "packed driver exposes operator identity expectations",
  );
  assert(src.includes("collectorProbe"), "packed --preflight-only runs the scratch collector probe");
  assert(!src.includes("acceptBaseline"), "driver still has NO baseline acceptance path");
  assert(
    src.indexOf("if (a.preflightOnly)") < src.indexOf("const browser = await chromium.launch"),
    "preflight branch still precedes the walk's browser launch",
  );
}

if (failed) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nselftest: all pure-helper + taxonomy + pack-integrity checks passed");
