#!/usr/bin/env node
// Pure-helper + taxonomy fixture smoke for preview-ui-walk (no browser).
//   node selftest.mjs

import { classifyRisk } from "./classify_risk.mjs";
import { classifyRisk as classifyRiskRuntime } from "./runtime_evidence.mjs";
import {
  expandEnvText,
  interactionsAllowed,
  walkNeedsRequiredInteractions,
} from "./page_steps.mjs";
import {
  countRuntimeErrors,
  defaultAppFramePrefixes,
  extractBounceReason,
  extractExceptionFromLogs,
  isHardFailStatus,
  isSignificantErrorLine,
  normalizeAppFramePrefixes,
  runtimeErrorEvidence,
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

if (failed) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nselftest: all pure-helper + taxonomy + pack-integrity checks passed");
