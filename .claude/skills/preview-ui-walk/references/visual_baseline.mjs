#!/usr/bin/env node
// Batch 3b: visual baseline evidence — pixel-level regression against an
// explicitly accepted baseline.
//
// Baselines live in the durable Casein Artifact store (a git-committed artifact
// worktree written via the artifact MCP), NEVER a local-only cache: a baseline
// that evaporates with a tmpdir cannot anchor a regression claim. Every
// baseline slot is addressed by a stable key made of ALL FOUR of:
//
//   workflow (report.name) + page path + named viewport + accepted source identity
//
// so baselines accepted for one workflow / viewport / source identity can never
// be silently compared against another's pixels.
//
// Acceptance is an EXPLICIT action (`visual_baseline.mjs accept …`). A normal
// walk only compares; it never creates or updates a baseline, so new pixels are
// never blessed as a side effect of a green run.
//
// Comparison is deliberately rigid:
//   * width, height, and DPR must match EXACTLY — any mismatch is a hard visual
//     failure (a resized capture is a different claim, not a fuzzy match);
//   * changed pixels beyond MAX_CHANGED_RATIO (0.1%) fail; exactly at the
//     threshold passes (the contract is "exceeds").
//
// SECRET HYGIENE: keys and stored metadata carry the page PATH only — query
// strings and fragments are dropped (they carry tokens and session material),
// and the store client never logs or persists the bearer token.
//
// The diff engine is pixelmatch + pngjs — proven, tiny, CJS — pinned and
// provisioned by scripts/ensure-preview-walk-deps.sh alongside playwright-core
// and ws. Resolution mirrors the ws collector: createRequire + global root.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { createRequire } from "node:module";

export const COLLECTOR_VERSION = "visual-baseline@1";
/** Fail when changedPixels / totalPixels EXCEEDS this (0.1%). Equal passes. */
export const MAX_CHANGED_RATIO = 0.001;

// ── deps ─────────────────────────────────────────────────────────────────────

const req = createRequire(import.meta.url);

function resolveDep(name) {
  try {
    return req(name);
  } catch {
    /* try global root */
  }
  const root = process.env.NODE_PATH;
  if (root) {
    try {
      return createRequire(path.join(root, "x.js"))(name);
    } catch {
      /* fall through */
    }
  }
  try {
    const { execFileSync } = req("node:child_process");
    const globalRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
    return createRequire(path.join(globalRoot, "x.js"))(name);
  } catch {
    return null;
  }
}

/** pixelmatch + pngjs, or null when unavailable (preflight reports MISSING). */
export function loadDiffEngine() {
  const pixelmatch = resolveDep("pixelmatch");
  const pngjs = resolveDep("pngjs");
  if (!pixelmatch || !pngjs?.PNG) return null;
  return { pixelmatch, PNG: pngjs.PNG };
}

// ── identity ─────────────────────────────────────────────────────────────────

/**
 * Strip everything that can carry session material from a URL or path:
 * query, fragment, and userinfo are DROPPED (not masked). Returns path only
 * for relative inputs, origin+path for absolute ones.
 */
export function redactPagePath(input) {
  const s = String(input || "");
  if (!s) return "";
  try {
    if (s.includes("://")) {
      const u = new URL(s);
      return `${u.protocol}//${u.host}${u.pathname}`;
    }
  } catch {
    /* treat as path */
  }
  return s.split("?")[0].split("#")[0];
}

function slug(component) {
  return String(component)
    .trim()
    .replace(/^\/+|\/+$/g, "")
    .replace(/[^a-zA-Z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase();
}

/**
 * The stable baseline key. ALL components are required — a missing one is a
 * hard error, never a defaulted key, because a defaulted component silently
 * merges baseline populations that must stay isolated.
 */
export function baselineKey({ workflow, pagePath, viewport, sourceIdentity }) {
  const parts = {
    workflow: slug(workflow),
    page: slug(redactPagePath(pagePath)) || "root",
    viewport: slug(viewport),
    source: slug(sourceIdentity),
  };
  for (const [name, v] of Object.entries(parts)) {
    if (!v && !(name === "page" && parts.page === "root")) {
      throw new Error(`baselineKey: missing ${name} component`);
    }
  }
  return `${parts.workflow}/${parts.source}/${parts.viewport}/${parts.page}`;
}

// ── pixel comparison ─────────────────────────────────────────────────────────

/**
 * Compare candidate PNG bytes against baseline PNG bytes.
 *
 * Returns evidence with `comparable: true` and pass/fail, or
 * `comparable: false` with a reason when no meaningful comparison happened
 * (undecodable bytes, missing engine). Dimension/DPR mismatches ARE comparable
 * — they are hard failures, not missing evidence.
 */
export function comparePng(candidateBytes, baselineBytes, { candidateDpr = 1, baselineDpr = 1, engine } = {}) {
  const eng = engine || loadDiffEngine();
  if (!eng) return { comparable: false, reason: "diff engine unavailable (pixelmatch/pngjs)" };

  let cand = null;
  let base = null;
  try {
    cand = eng.PNG.sync.read(Buffer.from(candidateBytes));
  } catch (err) {
    return { comparable: false, reason: `candidate PNG undecodable: ${String(err?.message || err)}` };
  }
  try {
    base = eng.PNG.sync.read(Buffer.from(baselineBytes));
  } catch (err) {
    return { comparable: false, reason: `baseline PNG undecodable: ${String(err?.message || err)}` };
  }

  const common = {
    comparable: true,
    collectorVersion: COLLECTOR_VERSION,
    candidate: { width: cand.width, height: cand.height, dpr: candidateDpr },
    baseline: { width: base.width, height: base.height, dpr: baselineDpr },
  };

  if (cand.width !== base.width || cand.height !== base.height) {
    return {
      ...common,
      pass: false,
      reason: `dimension mismatch: candidate ${cand.width}x${cand.height} vs baseline ${base.width}x${base.height}`,
      mismatch: "dimensions",
      changedPixels: null,
      changedRatio: null,
      diffPng: null,
    };
  }
  if (Number(candidateDpr) !== Number(baselineDpr)) {
    return {
      ...common,
      pass: false,
      reason: `DPR mismatch: candidate ${candidateDpr} vs baseline ${baselineDpr}`,
      mismatch: "dpr",
      changedPixels: null,
      changedRatio: null,
      diffPng: null,
    };
  }

  const { width, height } = cand;
  const diff = new eng.PNG({ width, height });
  const changedPixels = eng.pixelmatch(cand.data, base.data, diff.data, width, height, {
    threshold: 0.1,
  });
  const totalPixels = width * height;
  const changedRatio = totalPixels ? changedPixels / totalPixels : 0;
  const pass = changedRatio <= MAX_CHANGED_RATIO;
  return {
    ...common,
    pass,
    mismatch: pass ? null : "pixels",
    reason: pass
      ? null
      : `changed pixels ${(changedRatio * 100).toFixed(4)}% > ${(MAX_CHANGED_RATIO * 100).toFixed(1)}% (${changedPixels}/${totalPixels})`,
    changedPixels,
    changedRatio: Number(changedRatio.toFixed(8)),
    totalPixels,
    diffPng: changedPixels > 0 ? eng.PNG.sync.write(diff) : null,
  };
}

// ── Casein Artifact store client ─────────────────────────────────────────────

/** Store config from env; null when the artifact MCP is not wired. */
export function storeFromEnv(env = process.env) {
  const url = env.CASEIN_ARTIFACT_MCP_URL;
  const token = env.CASEIN_API_TOKEN;
  const workspaceId = env.CASEIN_WORKSPACE_ID;
  if (!url || !token || !workspaceId) return null;
  return { url, token, workspaceId };
}

/** Default durable store artifact name for a workflow. */
export function storeName(manifest) {
  const explicit = manifest?.visual_baseline?.store;
  if (explicit) return String(explicit);
  const workflow = manifest?.report?.name || "walk";
  return `visual-baselines-${slug(workflow)}`;
}

/**
 * One JSON-RPC tools/call against the artifact MCP. Never throws; never
 * includes the token in any returned string (errors are messages only).
 */
export async function mcpCall(store, tool, args, { fetchImpl = fetch, timeoutMs = 15000 } = {}) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchImpl(store.url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${store.token}`,
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: tool, arguments: { workspace_id: store.workspaceId, ...args } },
      }),
      signal: ctl.signal,
    });
    if (!res.ok) return { error: `artifact MCP ${tool} → HTTP ${res.status}` };
    const body = await res.json();
    if (body.error) return { error: `artifact MCP ${tool} → ${body.error.message || "rpc error"}` };
    const result = body.result || {};
    if (result.isError) {
      const text = result.content?.[0]?.text || "tool error";
      return { error: `artifact MCP ${tool} → ${String(text).slice(0, 200)}` };
    }
    if (result.structuredContent && typeof result.structuredContent === "object") {
      return { ok: result.structuredContent };
    }
    const text = result.content?.[0]?.text;
    try {
      return { ok: JSON.parse(text) };
    } catch {
      return { ok: text ?? null };
    }
  } catch (err) {
    return { error: `artifact MCP ${tool} unreachable: ${String(err?.message || err)}` };
  } finally {
    clearTimeout(timer);
  }
}

/** Find the baseline-store artifact project by name (read-only). */
export async function findStoreArtifact(store, name, opts = {}) {
  const listed = await mcpCall(store, "artifact_list", {}, opts);
  if (listed.error) return { error: listed.error };
  const artifacts = listed.ok?.artifacts || [];
  const hit = artifacts.find((a) => a?.name === name && !a?.retired);
  return { ok: hit || null };
}

function baselineFilePaths(key) {
  return {
    png: `baselines/${key}/baseline.png`,
    meta: `baselines/${key}/baseline.json`,
  };
}

/**
 * Read one accepted baseline. Reads the artifact worktree from disk (the walk
 * driver runs on the same box as Casein) with an HTTP fallback via the
 * artifact's preview server. Read-only — never creates anything.
 *
 * Returns { status: "ok"|"missing_baseline"|"missing_store"|"store_unreachable"|"read_failed", … }.
 */
export async function readBaseline(store, name, key, { fetchImpl = fetch, fsImpl = fs } = {}) {
  const found = await findStoreArtifact(store, name, { fetchImpl });
  if (found.error) return { status: "store_unreachable", reason: found.error };
  if (!found.ok) return { status: "missing_store", reason: `no artifact named ${name}` };
  const artifact = found.ok;
  const paths = baselineFilePaths(key);

  const worktree = artifact.worktree_path;
  if (worktree) {
    const pngPath = path.join(worktree, paths.png);
    const metaPath = path.join(worktree, paths.meta);
    try {
      if (fsImpl.existsSync(pngPath) && fsImpl.existsSync(metaPath)) {
        return {
          status: "ok",
          artifact_id: artifact.id,
          png: fsImpl.readFileSync(pngPath),
          meta: JSON.parse(fsImpl.readFileSync(metaPath, "utf8")),
        };
      }
      if (fsImpl.existsSync(worktree)) {
        return { status: "missing_baseline", artifact_id: artifact.id, reason: `no accepted baseline at ${paths.png}` };
      }
    } catch (err) {
      return { status: "read_failed", artifact_id: artifact.id, reason: String(err?.message || err) };
    }
  }

  // Same-box disk read unavailable — try the artifact's own preview server.
  if (artifact.preview_url) {
    try {
      const base = String(artifact.preview_url).replace(/\/$/, "");
      const pngRes = await fetchImpl(`${base}/${paths.png}`);
      const metaRes = await fetchImpl(`${base}/${paths.meta}`);
      if (pngRes.ok && metaRes.ok) {
        return {
          status: "ok",
          artifact_id: artifact.id,
          png: Buffer.from(await pngRes.arrayBuffer()),
          meta: await metaRes.json(),
        };
      }
      if (pngRes.status === 404 || metaRes.status === 404) {
        return { status: "missing_baseline", artifact_id: artifact.id, reason: `no accepted baseline at ${paths.png}` };
      }
      return { status: "read_failed", artifact_id: artifact.id, reason: `preview fetch → ${pngRes.status}/${metaRes.status}` };
    } catch (err) {
      return { status: "read_failed", artifact_id: artifact.id, reason: String(err?.message || err) };
    }
  }
  return { status: "read_failed", artifact_id: artifact.id, reason: "artifact has no worktree_path or preview_url" };
}

/**
 * EXPLICIT acceptance: write candidate bytes as the accepted baseline for
 * `key`. This is the ONLY code path that creates or updates a baseline, and it
 * exists only behind the `accept` CLI verb / a deliberate caller — the walk
 * compare path never calls it.
 */
export async function acceptBaseline(store, name, key, { png, meta }, { fetchImpl = fetch, now = () => new Date().toISOString() } = {}) {
  const paths = baselineFilePaths(key);
  const record = {
    key,
    ...meta,
    collectorVersion: COLLECTOR_VERSION,
    acceptedAt: now(),
    sha256: crypto.createHash("sha256").update(png).digest("hex"),
  };
  const files = [
    { path: paths.png, content: Buffer.from(png).toString("base64"), encoding: "base64" },
    { path: paths.meta, content: `${JSON.stringify(record, null, 2)}\n` },
  ];

  const found = await findStoreArtifact(store, name, { fetchImpl });
  if (found.error) return { error: found.error };
  let result;
  if (found.ok) {
    result = await mcpCall(store, "artifact_update", { artifact_id: found.ok.id, files }, { fetchImpl });
  } else {
    result = await mcpCall(store, "artifact_create", { name, kind: "static", files }, { fetchImpl });
  }
  if (result.error) return { error: result.error };
  return { ok: { artifact_id: result.ok?.id || found.ok?.id || null, key, record } };
}

// ── walk-time collection ─────────────────────────────────────────────────────

/**
 * Compare one page screenshot against its accepted baseline. READ-ONLY against
 * the store. Returns evidence:
 *
 *   comparable:true  → { pass, changedPixels, changedRatio, … }
 *   comparable:false → { reason } (missing store/baseline/config/engine)
 *
 * The fail-closed folding lives in `visualVerdict` so drivers and tests share
 * one decision table.
 */
export async function collectVisualBaseline({
  shotBytes,
  manifest,
  pagePath,
  viewportName,
  dpr = 1,
  store,
  deps = {},
}) {
  const cfg = manifest?.visual_baseline || {};
  const sourceIdentity = cfg.source_identity;
  if (!sourceIdentity) {
    return { comparable: false, reason: "manifest.visual_baseline.source_identity not declared (explicit accepted source identity required)" };
  }
  if (!store) {
    return { comparable: false, reason: "artifact store not configured (CASEIN_ARTIFACT_MCP_URL / CASEIN_API_TOKEN / CASEIN_WORKSPACE_ID)" };
  }
  if (!shotBytes) {
    return { comparable: false, reason: "no candidate screenshot captured" };
  }

  let key;
  try {
    key = baselineKey({
      workflow: manifest?.report?.name || "walk",
      pagePath,
      viewport: viewportName,
      sourceIdentity,
    });
  } catch (err) {
    return { comparable: false, reason: String(err?.message || err) };
  }

  const name = storeName(manifest);
  const baseline = await readBaseline(store, name, key, deps);
  if (baseline.status !== "ok") {
    return {
      comparable: false,
      reason: `${baseline.status}: ${baseline.reason || ""}`.trim(),
      key,
      store: name,
      status: baseline.status,
    };
  }

  const result = comparePng(shotBytes, baseline.png, {
    candidateDpr: dpr,
    baselineDpr: Number(baseline.meta?.dpr ?? baseline.meta?.deviceScaleFactor ?? 1),
    engine: deps.engine,
  });
  return {
    ...result,
    key,
    store: name,
    sourceIdentity,
    acceptedSourceIdentity: baseline.meta?.sourceIdentity ?? sourceIdentity,
    acceptedAt: baseline.meta?.acceptedAt || null,
    baselineSha256: baseline.meta?.sha256 || null,
    baselinePng: baseline.png,
  };
}

/**
 * Fold visual evidence into the verdict, fail closed:
 *   required + no comparison → BLOCKED (missing evidence is never green)
 *   comparable + !pass       → hard visual failure (ASSERT_FAILED family)
 *   otherwise                → null (no influence)
 */
export function visualVerdict(required, evidence) {
  if (!required) return null;
  if (!evidence || evidence.comparable !== true) {
    return {
      blocked: {
        reason: `required evidence unavailable: visual_baseline${evidence?.reason ? ` (${evidence.reason})` : ""}`,
      },
      failed: null,
    };
  }
  if (evidence.pass === false) {
    return { blocked: null, failed: { reason: `visual baseline: ${evidence.reason}` } };
  }
  return null;
}

// ── proof fixtures (preflight / selftest) ────────────────────────────────────

/** Generate a solid-color PNG with optional per-pixel overrides. */
export function makePng(width, height, rgba = [10, 20, 30, 255], { engine, paint } = {}) {
  const eng = engine || loadDiffEngine();
  if (!eng) return null;
  const png = new eng.PNG({ width, height });
  for (let i = 0; i < width * height; i++) {
    png.data[i * 4] = rgba[0];
    png.data[i * 4 + 1] = rgba[1];
    png.data[i * 4 + 2] = rgba[2];
    png.data[i * 4 + 3] = rgba[3];
  }
  if (paint) paint(png);
  return eng.PNG.sync.write(png);
}

/**
 * Prove the diff engine against a scratch fixture — no product page, no
 * artifact store, no baseline creation. Identical must pass, an above-threshold
 * perturbation must fail, and a dimension mismatch must hard-fail.
 */
export function proveDiffEngine() {
  const engine = loadDiffEngine();
  if (!engine) return { observable: false, reason: "pixelmatch/pngjs unresolvable" };
  const a = makePng(100, 100, [10, 20, 30, 255], { engine });
  const b = makePng(100, 100, [10, 20, 30, 255], {
    engine,
    paint: (png) => {
      // 11 pixels of 10,000 → 0.11% > 0.1%
      for (let i = 0; i < 11; i++) png.data[i * 4] = 250;
    },
  });
  const c = makePng(100, 90, [10, 20, 30, 255], { engine });
  const identical = comparePng(a, a, { engine });
  const changed = comparePng(b, a, { engine });
  const resized = comparePng(c, a, { engine });
  const ok =
    identical.comparable === true &&
    identical.pass === true &&
    identical.changedPixels === 0 &&
    changed.comparable === true &&
    changed.pass === false &&
    changed.mismatch === "pixels" &&
    resized.comparable === true &&
    resized.pass === false &&
    resized.mismatch === "dimensions";
  return { observable: ok, reason: ok ? null : "scratch fixture comparison did not behave" };
}

/**
 * Preflight classification for required visual evidence. Read-only: proves the
 * engine on a scratch fixture, checks store connectivity, and checks that an
 * accepted baseline EXISTS for every (page × viewport) the manifests require —
 * without ever creating or updating one, and without touching product pages.
 *
 * Returns { state: "OK"|"BLOCKED", detail } — missing connectivity or missing
 * baselines are BLOCKED (not merely degraded) because a walk that requires
 * visual evidence cannot produce a trustworthy report without them.
 */
export async function checkVisualBaselineReadiness(manifests, { store = storeFromEnv(), deps = {} } = {}) {
  const engineProof = deps.engineProof || proveDiffEngine();
  if (!engineProof.observable) {
    return { state: "BLOCKED", detail: `diff engine unproven: ${engineProof.reason || "?"} — run scripts/ensure-preview-walk-deps.sh` };
  }
  if (!store) {
    return { state: "BLOCKED", detail: "artifact store not configured (CASEIN_ARTIFACT_MCP_URL / CASEIN_API_TOKEN / CASEIN_WORKSPACE_ID)" };
  }

  let missing = 0;
  let checked = 0;
  for (const m of manifests || []) {
    const walkRequired = (m?.require_evidence || []).includes("visual_baseline");
    const cfg = m?.visual_baseline || {};
    const pages = (m?.pages || []).filter(
      (p) => walkRequired || (p?.require_evidence || []).includes("visual_baseline"),
    );
    if (!pages.length) continue;
    if (!cfg.source_identity) {
      return { state: "BLOCKED", detail: `manifest ${m?.report?.name || "?"} requires visual_baseline but declares no visual_baseline.source_identity` };
    }
    const name = storeName(m);
    const viewports = (m?.viewports || []).map((v) => v?.name).filter(Boolean);
    const names = viewports.length ? viewports : ["default"];
    for (const p of pages) {
      const pageViewports = Array.isArray(p?.viewports) && p.viewports.length ? p.viewports : names;
      for (const vp of pageViewports) {
        checked += 1;
        const key = baselineKey({
          workflow: m?.report?.name || "walk",
          pagePath: p.path,
          viewport: vp,
          sourceIdentity: cfg.source_identity,
        });
        const read = await readBaseline(store, name, key, deps);
        if (read.status === "store_unreachable" || read.status === "read_failed") {
          return { state: "BLOCKED", detail: `artifact store unavailable: ${read.reason || read.status}` };
        }
        if (read.status !== "ok") missing += 1;
      }
    }
  }
  if (missing > 0) {
    return {
      state: "BLOCKED",
      detail: `${missing}/${checked} accepted baseline(s) missing — accept explicitly with visual_baseline.mjs accept`,
    };
  }
  return { state: "OK", detail: `diff engine proven; ${checked} accepted baseline(s) present` };
}

// ── CLI: explicit acceptance + proof ─────────────────────────────────────────

function cliDie(msg) {
  console.error(`[visual-baseline] ERROR: ${msg}`);
  process.exit(2);
}

async function cliAccept(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i];
    const v = argv[i + 1];
    if (k === "--run") args.run = v;
    else if (k === "--manifest") args.manifest = v;
    else if (k === "--source-identity") args.sourceIdentity = v;
    else if (k === "--viewport") args.viewport = v;
    else if (k === "--page") args.page = v;
    else cliDie(`unknown arg ${k}`);
  }
  if (!args.run || !args.manifest || !args.sourceIdentity) {
    cliDie("usage: visual_baseline.mjs accept --run <outdir> --manifest <m.json> --source-identity <id> [--viewport <name>] [--page <name>]");
  }
  const manifest = JSON.parse(fs.readFileSync(args.manifest, "utf8"));
  const results = JSON.parse(fs.readFileSync(path.join(args.run, "results.json"), "utf8"));
  const store = storeFromEnv();
  if (!store) cliDie("artifact store not configured (CASEIN_ARTIFACT_MCP_URL / CASEIN_API_TOKEN / CASEIN_WORKSPACE_ID)");
  const name = storeName(manifest);
  const viewportName = args.viewport || manifest?.visual_baseline?.viewport || "default";

  let accepted = 0;
  for (const pageResult of results.pages || []) {
    if (args.page && pageResult.name !== args.page) continue;
    // Only bless candidates from pages that landed and rendered: a BOUNCED or
    // CRASHED capture must never become the accepted truth. BLOCKED is allowed
    // ONLY when the block is the missing visual baseline itself (first accept).
    const blockedForVisual =
      pageResult.status === "BLOCKED" && /visual_baseline/.test(pageResult.status_reason || "");
    const passing = pageResult.status === "PASS" || pageResult.status === "PASS_SLOW";
    if (!passing && !blockedForVisual) {
      console.log(`[visual-baseline] skip ${pageResult.name}: status ${pageResult.status} is not acceptable as a baseline`);
      continue;
    }
    if (!pageResult.shot_file) {
      console.log(`[visual-baseline] skip ${pageResult.name}: no screenshot in run`);
      continue;
    }
    const png = fs.readFileSync(path.join(args.run, pageResult.shot_file));
    const key = baselineKey({
      workflow: manifest?.report?.name || "walk",
      pagePath: pageResult.path,
      viewport: viewportName,
      sourceIdentity: args.sourceIdentity,
    });
    const meta = {
      workflow: manifest?.report?.name || "walk",
      pagePath: redactPagePath(pageResult.path),
      viewport: viewportName,
      sourceIdentity: args.sourceIdentity,
      dpr: Number(pageResult.visual?.candidate?.dpr ?? 1),
    };
    const res = await acceptBaseline(store, name, key, { png, meta });
    if (res.error) cliDie(`accept ${pageResult.name} failed: ${res.error}`);
    accepted += 1;
    console.log(`[visual-baseline] accepted ${key} (artifact ${res.ok.artifact_id})`);
  }
  console.log(`[visual-baseline] ${accepted} baseline(s) accepted into artifact "${name}"`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === "accept") {
    await cliAccept(rest);
  } else if (cmd === "prove") {
    const proof = proveDiffEngine();
    console.log(JSON.stringify(proof, null, 2));
    process.exit(proof.observable ? 0 : 1);
  } else {
    cliDie("usage: visual_baseline.mjs accept … | prove");
  }
}
