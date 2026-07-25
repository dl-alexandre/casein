#!/usr/bin/env node
// Pure-helper + taxonomy fixture smoke for preview-ui-walk (no browser).
//   node selftest.mjs

import { classifyRisk } from "./runtime_evidence.mjs";
import {
  expandEnvText,
  interactionsAllowed,
  walkNeedsRequiredInteractions,
} from "./page_steps.mjs";
import {
  extractExceptionFromLogs,
  isHardFailStatus,
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

// classifyRisk: prod wins when both match (fail-closed)
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

// env expand
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

// Taxonomy fixtures (mainStatus x URL x steps)
assert(verdictFixture().status === "PASS", "clean page PASS");

assert(
  verdictFixture({
    mainStatus: 500,
    uok: false,
    landed: "http://x/login",
    bounceHit: "/login",
    navOutcome: "bounce",
  }).status === "CRASHED",
  "5xx before bounce -> CRASHED (Tidewave not required)",
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
  "access bounce -> BOUNCED",
);

assert(
  verdictFixture({
    mainStatus: 200,
    uok: true,
    stepsFailed: 1,
  }).status === "ASSERT_FAILED",
  "2xx + step fail -> ASSERT_FAILED",
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
  "no land no bounce -> TIMEOUT",
);

assert(
  verdictFixture({
    stepsBlockedOnly: true,
    stepsBlocked: { message: "SKIPPED: interactions blocked by prod_like_env_check" },
    mainStatus: null,
    uok: false,
  }).status === "SKIPPED",
  "blocked interactions -> SKIPPED not FAIL",
);

assert(
  verdictFixture({
    within: false,
    uok: true,
    loaded: true,
  }).status === "PASS_SLOW",
  "over budget but landed -> PASS_SLOW",
);

// Exception enrichment is optional — empty logs still leave CRASHED alone
assert(
  extractExceptionFromLogs({ logs: { levels: { error: { samples: [] } } } }) === null,
  "no logs -> null exception (status still CRASHED independently)",
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

// Exit semantics
assert(
  isHardFailStatus("CRASHED", {}) === true,
  "CRASHED hard-fails exit",
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

if (failed) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nselftest: all pure-helper + taxonomy checks passed");
