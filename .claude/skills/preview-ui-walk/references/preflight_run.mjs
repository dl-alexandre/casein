#!/usr/bin/env node
// --preflight-only runner: loads the selected manifests, builds ONE merged
// readiness matrix, writes preflight.json + human output, and returns the exit
// code. It never walks and never mutates.
//
// The no-mutation guarantee is structural, not a promise: the driver branches
// here BEFORE launching a browser or entering the walk loop, and the only
// network the runner performs is a single GET of the base URL for health. It
// never requests a manifest page path and never issues a non-GET.

import fs from "node:fs";
import path from "node:path";
import {
  CATEGORIES,
  EXIT,
  STATE,
  checkCredentials,
  checkDisk,
  checkEnvSafety,
  checkLeakedSessions,
  row,
  toJson,
  toText,
  verdict,
} from "./preflight.mjs";

/** Role env prefixes a manifest needs, derived from login.params_from_env. */
export function roleEnvPrefixes(manifests) {
  const prefixes = new Set();
  for (const m of manifests) {
    for (const name of m?.login?.params_from_env || []) {
      const trimmed = String(name).replace(/_(EMAIL|PASSWORD)$/, "");
      if (trimmed) prefixes.add(trimmed);
    }
  }
  return [...prefixes].sort();
}

/** Collectors a manifest requires, walk-level plus per page. */
export function requiredEvidence(manifests) {
  const req = new Set();
  for (const m of manifests) {
    for (const k of m?.require_evidence || []) req.add(k);
    for (const p of m?.pages || []) for (const k of p?.require_evidence || []) req.add(k);
  }
  return [...req].sort();
}

/** Does any manifest intend to mutate? Drives the UNSAFE rule. */
export function isMutating(manifests) {
  return manifests.some((m) => m?.safety && m.safety.read_only === false);
}

export function checkSchema(loaded) {
  const bad = loaded.filter((l) => l.error);
  if (bad.length) {
    return row("schema", STATE.BLOCKED, `${bad.length} manifest(s) failed to load: ${bad[0].error}`);
  }
  const missing = loaded.filter((l) => !l.manifest?.pages || !l.manifest?.report?.name);
  if (missing.length) {
    return row("schema", STATE.BLOCKED, `${missing.length} manifest(s) missing pages/report.name`);
  }
  const pages = loaded.reduce((n, l) => n + (l.manifest.pages?.length || 0), 0);
  return row("schema", STATE.OK, `${loaded.length} manifest(s), ${pages} page(s)`);
}

/** Single GET of the base URL. A read — never a page path, never a non-GET. */
export async function checkAppHealth(base, { fetchImpl = fetch, timeoutMs = 8000 } = {}) {
  if (!base) return row("app_health", STATE.BLOCKED, "no --base");
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchImpl(base, { method: "GET", redirect: "manual", signal: ctl.signal });
    const status = res.status;
    if (status >= 500) return row("app_health", STATE.BLOCKED, `base returned ${status}`);
    return row("app_health", STATE.OK, `base returned ${status}`);
  } catch (err) {
    return row("app_health", STATE.BLOCKED, `base unreachable: ${String(err?.message || err)}`);
  } finally {
    clearTimeout(timer);
  }
}

export function checkBrowser({ resolveChromium, chromiumPath } = {}) {
  try {
    if (typeof resolveChromium === "function") resolveChromium();
  } catch (err) {
    return row("browser", STATE.MISSING, `playwright-core unresolvable: ${String(err?.message || err)}`);
  }
  try {
    const p = typeof chromiumPath === "function" ? chromiumPath() : null;
    if (p && !fs.existsSync(p)) return row("browser", STATE.MISSING, `chromium missing at ${p}`);
    return row("browser", STATE.OK, p ? "playwright-core + chromium present" : "playwright-core present");
  } catch (err) {
    return row("browser", STATE.MISSING, `chromium unresolvable: ${String(err?.message || err)}`);
  }
}

/**
 * An optional collector is OK when the walk requires it AND we can prove it, or
 * when the walk does not require it at all (nothing to prove). It is MISSING
 * only when the manifest requires evidence we cannot produce — which is what
 * turns into a BLOCKED page at walk time.
 */
export function checkCollector(id, { required, proven }) {
  if (!required) return row(id, STATE.SKIP, "not required by manifest");
  return proven
    ? row(id, STATE.OK, "collector proven")
    : row(id, STATE.MISSING, "required by manifest but not proven available");
}

const PROVEN_COLLECTORS = new Set(["har", "dom", "server_timing", "screenshot"]);

/**
 * `ws` is proven only when the driver can actually observe FRAMES. Socket-level
 * evidence (open/close/reconnect) works everywhere, but LiveView join status is
 * derived from frames, and some Playwright/Chromium builds emit the `websocket`
 * event while never emitting framesent/framereceived. Reporting ws as available
 * in that case would let a manifest requiring `ws` pass with no join evidence —
 * exactly the false green this suite exists to prevent. Callers pass the probe
 * result; absent a probe we refuse to claim the capability.
 */
export function a11yProven(probe) {
  return Boolean(probe && probe.a11y && probe.a11y.observable);
}

export function viewportProven(probe) {
  return Boolean(probe && probe.viewport && probe.viewport.proven);
}

export function wsProven(probe) {
  return Boolean(probe && probe.ws && probe.ws.frames && probe.ws.frames.observable);
}

export async function buildMatrix(args, deps = {}) {
  const {
    env = process.env,
    fetchImpl = fetch,
    resolveChromium,
    chromiumPath,
    freeBytes,
    leakedSessions,
    now,
  } = deps;

  const loaded = (args.manifests || []).map((p) => {
    try {
      return { path: p, manifest: JSON.parse(fs.readFileSync(p, "utf8")) };
    } catch (err) {
      return { path: p, error: String(err?.message || err) };
    }
  });
  const manifests = loaded.filter((l) => l.manifest).map((l) => l.manifest);
  const mutating = isMutating(manifests);
  const required = new Set(requiredEvidence(manifests));

  const rows = [];
  rows.push(checkSchema(loaded));
  rows.push(checkEnvSafety(env, { mutating }));
  rows.push(checkCredentials(roleEnvPrefixes(manifests), env));
  rows.push(await checkAppHealth(args.base, { fetchImpl }));
  rows.push(row("identity", STATE.OK, `base=${args.base || "?"} manifests=${manifests.length}`));
  rows.push(checkBrowser({ resolveChromium, chromiumPath }));
  rows.push(row("preview_mcp", STATE.SKIP, "not exercised by --preflight-only"));
  rows.push(
    args.tidewaveUrl
      ? row("tidewave", STATE.OK, "tidewave url configured")
      : row("tidewave", required.has("audit_actor") || required.has("db_before_after")
          ? STATE.MISSING
          : STATE.SKIP, "no --tidewave-url"),
  );
  for (const id of [
    "har", "ws", "dom", "screenshot", "a11y", "viewport", "visual_baseline",
    "resource_metrics", "db_read", "audit_actor", "artifact", "cleanup",
  ]) {
    const key = id === "db_read" ? "db_before_after" : id;
    rows.push(
      checkCollector(id, {
        required: required.has(key) || id === "screenshot",
        proven:
          id === "ws"
            ? wsProven(deps.collectorProbe)
            : id === "a11y"
              ? a11yProven(deps.collectorProbe)
              : id === "viewport"
                ? viewportProven(deps.collectorProbe)
                : PROVEN_COLLECTORS.has(id),
      }),
    );
  }
  rows.push(checkDisk(freeBytes));
  rows.push(checkLeakedSessions(leakedSessions));

  // Keep report order stable and complete.
  const byId = new Map(rows.map((r) => [r.id, r]));
  const ordered = CATEGORIES.map(
    (c) => byId.get(c.id) || row(c.id, STATE.SKIP, "not evaluated"),
  );
  return { rows: ordered, mutating, now };
}

export async function runPreflight(args, deps = {}) {
  const { rows, mutating, now } = await buildMatrix(args, deps);
  const opts = { mutating, now };
  const code = verdict(rows, opts);
  const json = toJson(rows, opts);
  const text = toText(rows, opts);

  if (args.out) {
    fs.mkdirSync(args.out, { recursive: true });
    fs.writeFileSync(path.join(args.out, "preflight.json"), `${JSON.stringify(json, null, 2)}\n`);
    fs.writeFileSync(path.join(args.out, "preflight.txt"), `${text}\n`);
  }
  const write = deps.stdout || ((s) => process.stdout.write(s));
  write(args.json ? `${JSON.stringify(json, null, 2)}\n` : `${text}\n`);
  return { code, json, text };
}

export { EXIT };
