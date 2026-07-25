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

const here = dirname(fileURLToPath(import.meta.url));
let b64 = "";
const single = join(here, "playwright_walk_payload.b64");
if (existsSync(single)) {
  b64 = readFileSync(single, "utf8").trim();
} else {
  for (let i = 0; ; i++) {
    const p = join(here, `playwright_walk_payload.pl${i}`);
    if (!existsSync(p)) break;
    b64 += readFileSync(p, "utf8").trim();
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
