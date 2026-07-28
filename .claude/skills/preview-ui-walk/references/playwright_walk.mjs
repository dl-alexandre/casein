#!/usr/bin/env node
// preview-ui-walk driver — full body packed as pl0..plN beside this file (landlock-safe land).
import {
  countRuntimeErrors,
  defaultAppFramePrefixes,
  extractBounceReason,
  extractExceptionFromLogs,
  isAuthBouncePath,
  isHardFailStatus,
  isPassingStatus,
  pageVerdict,
  statusColor,
} from "./walk_verdict.mjs";
import {
  interactionsAllowed,
  runPageSteps,
  walkNeedsRequiredInteractions,
} from "./page_steps.mjs";
import { beginRuntime, pageRuntimeEvidence } from "./runtime_evidence.mjs";
import { collectVisualBaseline, storeFromEnv, visualVerdict } from "./visual_baseline.mjs";
import { resolvePlaywrightCore } from "./resolve_dep.mjs";
import { attachApi, attachDownloads, cleanupEvidence } from "./api_evidence.mjs";
import { flakinessEvidence, retryPolicy, shouldRetry } from "./retry_policy.mjs";
import { gunzipSync } from "node:zlib";
import { readFileSync, writeFileSync, unlinkSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { tmpdir } from "node:os";

void pageVerdict;
void isHardFailStatus;
void isPassingStatus;
void statusColor;
void extractExceptionFromLogs;
void extractBounceReason;
void countRuntimeErrors;
void defaultAppFramePrefixes;
void isAuthBouncePath;
void interactionsAllowed;
void runPageSteps;
void walkNeedsRequiredInteractions;
void beginRuntime;
void pageRuntimeEvidence;
void collectVisualBaseline;
void storeFromEnv;
void visualVerdict;
void resolvePlaywrightCore;
void attachApi;
void attachDownloads;
void cleanupEvidence;
void flakinessEvidence;
void retryPolicy;
void shouldRetry;

const here = dirname(fileURLToPath(import.meta.url));
let b64 = "";
const single = join(here, "playwright_walk_payload.b64");
if (existsSync(single)) {
  b64 = readFileSync(single, "utf8").trim();
} else {
  for (let i = 0; ; i++) {
    const p = join(here, `playwright_walk_payload.pl${i}`);
    if (!existsSync(p)) break;
    const chunk = readFileSync(p, "utf8").trim();
    if (!chunk) break;
    b64 += chunk;
  }
}
if (!b64) {
  console.error("[preview-ui-walk] ERROR: missing playwright_walk_payload.b64 (or pl* shards)");
  process.exit(2);
}
let code = gunzipSync(Buffer.from(b64, "base64")).toString("utf8");
const hereUrl = pathToFileURL(here.endsWith("/") ? here : here + "/").href;
code = code.replace(
  /(from\s+|import\s*\()(["'])\.\/([^"']+\.mjs)\2/g,
  (m, pref, q, rel) => `${pref}${q}${hereUrl}${rel}${q}`,
);
const out = join(tmpdir(), `preview-ui-walk-driver-${process.pid}.mjs`);
writeFileSync(out, code);
try {
  await import(pathToFileURL(out).href);
} finally {
  try { unlinkSync(out); } catch { /* ignore */ }
}
