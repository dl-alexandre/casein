#!/usr/bin/env node
// preview-ui-walk driver — full body packed beside this file for landlock-safe land.
import {
  extractExceptionFromLogs,
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
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { tmpdir } from "node:os";

// Live static imports (greppable wire-up + ensure deps resolve).
void pageVerdict;
void isHardFailStatus;
void isPassingStatus;
void statusColor;
void extractExceptionFromLogs;
void interactionsAllowed;
void runPageSteps;
void walkNeedsRequiredInteractions;
void beginRuntime;
void pageRuntimeEvidence;

const here = dirname(fileURLToPath(import.meta.url));
const b64 = readFileSync(join(here, "playwright_walk_payload.b64"), "utf8").trim();
let code = gunzipSync(Buffer.from(b64, "base64")).toString("utf8");
// Rewrite relative ./foo.mjs imports to absolute skill-dir URLs so the tmp unpack resolves.
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
