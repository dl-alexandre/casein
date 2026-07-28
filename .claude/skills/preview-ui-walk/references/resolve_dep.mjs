#!/usr/bin/env node
// Batch 4: ONE dependency resolver for every runtime dep the skill needs
// (playwright-core, ws, pixelmatch, pngjs).
//
// Why: each collector used to carry its own copy of the resolution dance, and
// they disagreed — the driver knew about npx caches, the visual collector knew
// about the npm global root, and a walk launched without NODE_PATH failed with
// "cannot resolve playwright-core" even though scripts/ensure-preview-walk-deps.sh
// had provisioned everything into the global root. Resolution order here is the
// union, most-explicit first:
//
//   1. per-dep env override (PW_CORE for playwright-core) — absolute path wins
//   2. normal require() from this directory
//   3. NODE_PATH entries (ESM import() ignores NODE_PATH; require honors it via
//      createRequire only when the process was started with it — probe explicitly)
//   4. the npm global root (`npm root -g`, cached per process)
//   5. newest ~/.npm/_npx/*/node_modules (npx cache, where playwright-core
//      historically lived on the devbox)
//
// Returns the loaded module or null — callers decide whether missing is
// MISSING/BLOCKED (preflight) or a die() (driver). Never throws.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";

const req = createRequire(import.meta.url);

let npmGlobalRoot = undefined; // undefined = not probed; null = unavailable

/** `npm root -g`, probed once per process. */
export function globalNpmRoot() {
  if (npmGlobalRoot !== undefined) return npmGlobalRoot;
  try {
    npmGlobalRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim() || null;
  } catch {
    npmGlobalRoot = null;
  }
  return npmGlobalRoot;
}

function tryRequireFrom(dir, name) {
  if (!dir) return null;
  try {
    return createRequire(path.join(dir, "x.js"))(name);
  } catch {
    return null;
  }
}

/**
 * Resolve one dependency by name. `envOverride` names an env var holding an
 * absolute path or module id to prefer (e.g. PW_CORE). The result is cached —
 * repeated calls are free.
 */
const cache = new Map();

export function resolveDep(name, { envOverride } = {}) {
  const key = `${envOverride || ""}:${name}`;
  if (cache.has(key)) return cache.get(key);
  const found = resolveUncached(name, envOverride);
  cache.set(key, found);
  return found;
}

function resolveUncached(name, envOverride) {
  if (envOverride && process.env[envOverride]) {
    try {
      return req(process.env[envOverride]);
    } catch {
      /* explicit override failed — fall through so a stale env var does not
         mask a working default resolution */
    }
  }
  try {
    return req(name);
  } catch {
    /* not local */
  }
  for (const dir of String(process.env.NODE_PATH || "").split(path.delimiter).filter(Boolean)) {
    const m = tryRequireFrom(dir, name);
    if (m) return m;
  }
  {
    const m = tryRequireFrom(globalNpmRoot(), name);
    if (m) return m;
  }
  const npx = path.join(os.homedir(), ".npm", "_npx");
  if (fs.existsSync(npx)) {
    let entries = [];
    try {
      entries = fs.readdirSync(npx);
    } catch {
      entries = [];
    }
    for (const d of entries) {
      const m = tryRequireFrom(path.join(npx, d, "node_modules"), name);
      if (m) return m;
    }
  }
  return null;
}

/** The four deps this skill runs on, with their conventional overrides. */
export function resolvePlaywrightCore() {
  return resolveDep("playwright-core", { envOverride: "PW_CORE" });
}

export function resolveWs() {
  return resolveDep("ws");
}

export function resolveDiffEngine() {
  const pixelmatch = resolveDep("pixelmatch");
  const pngjs = resolveDep("pngjs");
  if (!pixelmatch || !pngjs?.PNG) return null;
  return { pixelmatch, PNG: pngjs.PNG };
}
