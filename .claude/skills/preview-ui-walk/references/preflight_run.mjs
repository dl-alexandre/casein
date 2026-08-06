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
import { checkVisualBaselineReadiness, storeFromEnv } from "./visual_baseline.mjs";
import { normalizeViewports } from "./a11y_collector.mjs";
import { expandActionCases, normalizeActions } from "./actions.mjs";
import { validateManifest } from "./schema_validate.mjs";

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
    for (const act of m?.actions || []) {
      for (const k of act?.require_evidence || []) req.add(k);
      for (const ph of act?.phases || []) for (const k of ph?.require_evidence || []) req.add(k);
    }
  }
  return [...req].sort();
}

/** Tidewave tools needed by the selected manifests, not just by the server. */
export function requiredTidewaveTools(manifests, evidence = new Set()) {
  const tools = new Set(["get_logs"]);
  for (const manifest of manifests) {
    for (const name of manifest?.runtime?.required_tools || []) {
      if (typeof name === "string" && name.trim()) tools.add(name.trim());
    }
  }
  const usesRuntimeEval = manifests.some((manifest) => {
    const runtime = manifest?.runtime || {};
    return runtime.tidewave === true;
  });
  const usesSql = manifests.some((manifest) => {
    const runtime = manifest?.runtime || {};
    if (Object.values(runtime.per_page || {}).some((page) => page?.sql)) return true;
    return (manifest?.pages || []).some((page) => page?.runtime?.sql);
  });

  if (usesRuntimeEval || evidence.has("audit_actor")) tools.add("project_eval");
  if (usesSql || evidence.has("db_before_after")) tools.add("execute_sql_query");
  return [...tools].sort();
}

/** Does any manifest intend to mutate? Drives the UNSAFE rule. */
export function isMutating(manifests) {
  return manifests.some((m) => m?.safety && m.safety.read_only === false);
}

/**
 * Some evidence keys need per-phase CONFIG to produce anything: requiring them
 * without it can only ever BLOCK mid-walk. Catch it at preflight, where the
 * message can name the phase instead of reading as a mysterious collector gap.
 *
 * This is the footgun that action-level require_evidence creates: the list
 * unions into EVERY phase, so one query on one phase does not satisfy a
 * requirement declared for the whole action.
 */
export function missingCollectorConfig(manifest) {
  const needsConfig = {
    db_before_after: (phase, action) =>
      Boolean(phase?.runtime?.db_before_after || action?.runtime?.db_before_after ||
        manifest?.runtime?.per_page?.[phase?.name]?.db_before_after),
    cleanup: (phase, action) =>
      Boolean((phase?.cleanup_steps || []).length || (action?.cleanup_steps || []).length),
    prereq: (phase, action) => Boolean((action?.prereq || []).length),
  };
  const walkLevel = manifest?.require_evidence || [];

  for (const action of normalizeActions(manifest)) {
    for (const phase of action.phases || []) {
      const required = new Set([
        ...walkLevel,
        ...(action.require_evidence || []),
        ...(phase.require_evidence || []),
      ]);
      for (const [key, hasConfig] of Object.entries(needsConfig)) {
        if (!required.has(key)) continue;
        if (hasConfig(phase, action)) continue;
        const where = action.synthetic
          ? `page "${phase.name}"`
          : `action "${action.name}" phase "${phase.name || phase.path}"`;
        return (
          `${where} requires evidence "${key}" but declares no ${key} config — ` +
          `it can only BLOCK. Declare it on the phase that produces the evidence, not the whole action.`
        );
      }
    }
  }
  return null;
}

export function checkSchema(loaded, schemaDoc = null) {
  const bad = loaded.filter((l) => l.error);
  if (bad.length) {
    return row("schema", STATE.BLOCKED, `${bad.length} manifest(s) failed to load: ${bad[0].error}`);
  }

  // Validate against the committed JSON Schema. `additionalProperties: false`
  // already describes every legal key, but until this ran at preflight a
  // misspelled key ("step" for "steps") silently produced a walk that asserted
  // nothing and reported PASS.
  if (schemaDoc) {
    for (const { manifest, path: file } of loaded) {
      const result = validateManifest(schemaDoc, manifest);
      if (!result.ok) {
        const first = result.errors[0];
        return row(
          "schema",
          STATE.BLOCKED,
          `${file || manifest?.report?.name || "manifest"} is invalid: ${first.path ? `${first.path}: ` : ""}${first.message}` +
            (result.errors.length > 1 ? ` (+${result.errors.length - 1} more)` : ""),
        );
      }
    }
  }
  // v2: a manifest declares pages[] OR actions[]. Requiring pages[] would
  // BLOCK every actions-only manifest at preflight.
  const missing = loaded.filter(
    (l) =>
      (!l.manifest?.pages && !l.manifest?.actions) || !l.manifest?.report?.name,
  );
  if (missing.length) {
    return row(
      "schema",
      STATE.BLOCKED,
      `${missing.length} manifest(s) missing pages[]/actions[] or report.name`,
    );
  }
  let logicalPages = 0;
  let viewportVisits = 0;
  for (const { manifest } of loaded) {
    const normalized = normalizeViewports(manifest.viewports);
    if (normalized.invalid.length > 0) {
      return row(
        "schema",
        STATE.BLOCKED,
        `${manifest.report.name} has ${normalized.invalid.length} invalid viewport declaration(s)`,
      );
    }
    const names = normalized.viewports.map((viewport) => viewport.name);
    if (new Set(names).size !== names.length) {
      return row("schema", STATE.BLOCKED, `${manifest.report.name} has duplicate viewport names`);
    }
    const expanded = expandActionCases(manifest, manifest.viewports);
    if (expanded.unknown.length > 0) {
      const first = expanded.unknown[0];
      return row(
        "schema",
        STATE.BLOCKED,
        `${manifest.report.name} page ${first.page} references unknown viewport ${first.name}`,
      );
    }
    if (expanded.errors.length > 0) {
      return row("schema", STATE.BLOCKED, `${manifest.report.name}: ${expanded.errors[0]}`);
    }
    const configGap = missingCollectorConfig(manifest);
    if (configGap) {
      return row("schema", STATE.BLOCKED, `${manifest.report.name}: ${configGap}`);
    }

    const actions = normalizeActions(manifest);
    logicalPages += actions.reduce((n, act) => n + act.phases.length, 0);
    viewportVisits += expanded.cases.reduce((n, c) => n + c.phases.length, 0);
  }
  return row(
    "schema",
    STATE.OK,
    `${loaded.length} manifest(s), ${logicalPages} logical page(s), ${viewportVisits} viewport visit(s)`,
  );
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

/** Strip query/fragment/userinfo before a URL reaches a report line. */
function sanitizedUrl(url) {
  try {
    const u = new URL(String(url));
    return `${u.protocol}//${u.host}${u.pathname}`;
  } catch {
    return String(url || "").split("?")[0].split("#")[0];
  }
}

/**
 * Parse deployment data into an EXACT attestation: the environment string and
 * a full 40-char hex revision. Anything less is refused, not approximated — a
 * 12-char prefix or a "vX.Y" label is not an identity a regression can be
 * pinned to.
 */
export function parseDeploymentIdentity(data) {
  if (!data || typeof data !== "object") {
    return { environment: null, revision: null, reason: "deployment data is not an object" };
  }
  const deployment =
    data.deployment && typeof data.deployment === "object" ? data.deployment : {};
  const env =
    [
      deployment.environment,
      deployment.env,
      deployment.mix_env,
      deployment.MIX_ENV,
      data.environment,
      data.env,
      data.mix_env,
      data.MIX_ENV,
    ].find(
      (v) => typeof v === "string" && v.trim(),
    ) || null;
  const revRaw =
    [
      deployment.revision,
      deployment.git_sha,
      deployment.sha,
      deployment.commit,
      deployment.git_revision,
      data.revision,
      data.git_sha,
      data.sha,
      data.commit,
      data.git_revision,
    ].find(
      (v) => typeof v === "string" && v.trim(),
    ) || null;
  const revision = revRaw && /^[0-9a-f]{40}$/i.test(revRaw.trim()) ? revRaw.trim().toLowerCase() : null;
  let reason = null;
  if (!env) reason = "deployment data lacks an environment field";
  else if (!revRaw) reason = "deployment data lacks a revision field";
  else if (!revision) reason = `revision is not a 40-char hex sha (got ${revRaw.trim().slice(0, 12)}…)`;
  return { environment: env, revision, reason };
}

/**
 * Health attestation: one GET of the configured health URL, deployment data
 * parsed into env + 40-char revision. GET-only, never a manifest page path.
 *
 * Two modes:
 *   RECORD  — no expectations supplied: the row records what the deployment
 *             reports (or MISSING when it cannot be parsed). No health URL →
 *             an honest "unattested" placeholder.
 *   VERIFY  — `expectEnvironment` / `expectRevision` supplied (operator input
 *             via --expect-environment / --expect-revision or
 *             WALK_EXPECT_ENVIRONMENT / WALK_EXPECT_REVISION): the deployed
 *             identity must match EXACTLY. A missing health URL, unreachable
 *             endpoint, unparseable identity, malformed expectation, or ANY
 *             mismatch is BLOCKED (exit 2) — a walk pointed at the wrong
 *             environment or the wrong build must not produce a report at
 *             all. Environment comparison is exact string equality; revisions
 *             are full 40-char hex compared case-insensitively.
 */
export async function checkDeploymentIdentity(
  healthUrl,
  { fetchImpl = fetch, timeoutMs = 8000, base, manifestCount, expectEnvironment, expectRevision } = {},
) {
  const verifying = Boolean(expectEnvironment || expectRevision);
  const failState = verifying ? STATE.BLOCKED : STATE.MISSING;

  // Malformed operator input fails closed BEFORE any network: a 12-char
  // expectation could never verify anything and must not look like it did.
  if (expectRevision && !/^[0-9a-f]{40}$/i.test(String(expectRevision).trim())) {
    return row(
      "identity",
      STATE.BLOCKED,
      `expected revision is not a full 40-char hex sha (got ${String(expectRevision).trim().slice(0, 12)}…)`,
      { required: true },
    );
  }

  if (!healthUrl) {
    if (verifying) {
      return row(
        "identity",
        STATE.BLOCKED,
        "expected environment/revision supplied but no --health-url to verify against",
        { required: true },
      );
    }
    return row("identity", STATE.OK, `base=${base || "?"} manifests=${manifestCount ?? "?"} (no --health-url; deployment identity unattested)`);
  }
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchImpl(healthUrl, { method: "GET", redirect: "manual", signal: ctl.signal });
    if (res.status >= 400) {
      return row(
        "identity",
        failState,
        `health url returned ${res.status} (${sanitizedUrl(healthUrl)})`,
        { required: verifying },
      );
    }
    let data = null;
    try {
      data = await res.json();
    } catch {
      return row(
        "identity",
        failState,
        `health response is not JSON (${sanitizedUrl(healthUrl)})`,
        { required: verifying },
      );
    }
    const id = parseDeploymentIdentity(data);
    if (!id.environment || !id.revision) {
      return row(
        "identity",
        failState,
        `${id.reason} (${sanitizedUrl(healthUrl)})`,
        { required: verifying },
      );
    }
    if (expectEnvironment && id.environment !== String(expectEnvironment)) {
      return row(
        "identity",
        STATE.BLOCKED,
        `environment mismatch: expected "${expectEnvironment}", deployed "${id.environment}" (${sanitizedUrl(healthUrl)})`,
        { required: true },
      );
    }
    if (expectRevision && id.revision !== String(expectRevision).trim().toLowerCase()) {
      return row(
        "identity",
        STATE.BLOCKED,
        `revision mismatch: expected ${String(expectRevision).trim().toLowerCase()}, deployed ${id.revision} (${sanitizedUrl(healthUrl)})`,
        { required: true },
      );
    }
    const verified = verifying ? " — matches operator expectation" : "";
    return row(
      "identity",
      STATE.OK,
      `env=${id.environment} rev=${id.revision}${verified} (${sanitizedUrl(healthUrl)})`,
      {
        required: verifying,
        evidence: { environment: id.environment, revision: id.revision, verified: verifying },
      },
    );
  } catch (err) {
    return row(
      "identity",
      failState,
      `health url unreachable: ${String(err?.message || err)}`,
      { required: verifying },
    );
  } finally {
    clearTimeout(timer);
  }
}

/**
 * REAL Tidewave probe — a tools/list round-trip that verifies every collector
 * the selected manifests need. Tidewave's HTTP transport does not accept the
 * empty initialize handshake used by some generic MCP clients.
 */
export async function checkTidewave(
  url,
  {
    fetchImpl = fetch,
    timeoutMs = 8000,
    required = false,
    requiredTools = ["get_logs"],
  } = {},
) {
  if (!url) {
    return row(
      "tidewave",
      required ? STATE.BLOCKED : STATE.SKIP,
      required ? "runtime evidence required but no --tidewave-url" : "no --tidewave-url",
      { required },
    );
  }
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }),
      signal: ctl.signal,
    });
    if (res.status < 200 || res.status >= 300) {
      return row(
        "tidewave",
        required ? STATE.BLOCKED : STATE.MISSING,
        `tools/list → HTTP ${res.status} (${sanitizedUrl(url)})`,
        { required },
      );
    }

    const raw = await res.text();
    let payload = null;
    try {
      payload = JSON.parse(raw);
    } catch {
      for (const line of raw.split("\n")) {
        const value = line.trim();
        if (!value.startsWith("data:")) continue;
        try {
          payload = JSON.parse(value.slice(5).trim());
        } catch {
          // Keep scanning SSE frames for the JSON-RPC response.
        }
      }
    }

    if (!payload || payload.error) {
      const message = payload?.error?.message || "unparseable response";
      return row(
        "tidewave",
        required ? STATE.BLOCKED : STATE.MISSING,
        `tools/list failed: ${message} (${sanitizedUrl(url)})`,
        { required },
      );
    }

    const available = (payload.result?.tools || []).map((tool) => tool?.name).filter(Boolean);
    const missing = requiredTools.filter((name) => !available.includes(name));
    if (missing.length > 0) {
      return row(
        "tidewave",
        required ? STATE.BLOCKED : STATE.MISSING,
        `missing required tools: ${missing.join(", ")} (${sanitizedUrl(url)})`,
        { required, evidence: { tools: available, missing_tools: missing } },
      );
    }

    return row(
      "tidewave",
      STATE.OK,
      `tools/list → ${available.length} tools; required tools present (${sanitizedUrl(url)})`,
      { required, evidence: { tools: available, required_tools: requiredTools } },
    );
  } catch (err) {
    return row(
      "tidewave",
      required ? STATE.BLOCKED : STATE.MISSING,
      `unreachable: ${String(err?.message || err)} (${sanitizedUrl(url)})`,
      { required },
    );
  } finally {
    clearTimeout(timer);
  }
}

/**
 * REAL artifact-store probe: a read-only artifact_list round-trip using the
 * env-provided store. Required-but-unavailable is BLOCKED. The bearer token
 * never appears in any detail string.
 */
export async function checkArtifactStore({ store, fetchImpl = fetch, required = false } = {}) {
  if (!store) {
    return row(
      "artifact",
      required ? STATE.BLOCKED : STATE.SKIP,
      required
        ? "required but artifact store not configured (CASEIN_ARTIFACT_MCP_URL / CASEIN_API_TOKEN / CASEIN_WORKSPACE_ID)"
        : "artifact store not configured",
      { required },
    );
  }
  const { mcpCall } = await import("./visual_baseline.mjs");
  const listed = await mcpCall(store, "artifact_list", {}, { fetchImpl });
  if (listed.error) {
    return row(
      "artifact",
      required ? STATE.BLOCKED : STATE.MISSING,
      listed.error,
      { required },
    );
  }
  const count = listed.ok?.count ?? (listed.ok?.artifacts || []).length;
  return row(
    "artifact",
    STATE.OK,
    `artifact_list ok (${count} project(s)) at ${sanitizedUrl(store.url)}`,
    { required },
  );
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
 * A collector row is OK when the walk requires it AND we can prove it, or SKIP
 * when the walk does not require it at all (nothing to prove). A collector the
 * manifest REQUIRES but we cannot prove is BLOCKED (exit 2) — running anyway
 * would produce a report that silently lacks evidence it promised, which is
 * the false green this suite exists to kill. (Until batch 4 this was MISSING/
 * DEGRADED; required gaps now fail closed.)
 */
export function checkCollector(id, { required, proven }) {
  if (!required) return row(id, STATE.SKIP, "not required by manifest", { required: false });
  return proven
    ? row(id, STATE.OK, "collector proven", { required: true })
    : row(id, STATE.BLOCKED, "required by manifest but not proven available", { required: true });
}

const PROVEN_COLLECTORS = new Set(["har", "dom", "server_timing", "screenshot", "cleanup"]);

/**
 * `ws` is proven only when the driver can actually observe FRAMES. Socket-level
 * evidence (open/close/reconnect) works everywhere, but LiveView join status is
 * derived from frames, and some Playwright/Chromium builds emit the `websocket`
 * event while never emitting framesent/framereceived. Reporting ws as available
 * in that case would let a manifest requiring `ws` pass with no join evidence —
 * exactly the false green this suite exists to prevent. Callers pass the probe
 * result; absent a probe we refuse to claim the capability.
 */
export function resourceMetricsProven(probe) {
  return Boolean(probe && probe.resource_metrics && probe.resource_metrics.observable);
}

export function visualBaselineProven(probe) {
  return Boolean(probe && probe.visual_baseline && probe.visual_baseline.observable);
}

export function apiProven(probe) {
  return Boolean(probe && probe.api && probe.api.observable);
}

export function downloadsProven(probe) {
  return Boolean(probe && probe.downloads && probe.downloads.observable);
}

export function previewCookieProven(probe) {
  return Boolean(probe && probe.preview_cookie && probe.preview_cookie.observable);
}

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
  const viewportRequired = manifests.some(
    (manifest) => Array.isArray(manifest?.viewports) && manifest.viewports.length > 0,
  );

  const rows = [];
  // The schema ships beside the drivers; read it here so a manifest is
  // validated by the same file the authoring docs point at.
  let schemaDoc = null;
  try {
    const { readFileSync } = await import("node:fs");
    const { fileURLToPath } = await import("node:url");
    const { dirname, join } = await import("node:path");
    schemaDoc = JSON.parse(
      readFileSync(join(dirname(fileURLToPath(import.meta.url)), "preview-walk.schema.json"), "utf8"),
    );
  } catch {
    schemaDoc = null; // unreadable schema must not block a walk
  }
  rows.push(checkSchema(loaded, schemaDoc));
  rows.push(checkEnvSafety(env, { mutating }));
  // Credentials are demanded ONLY for the manifests actually selected on the
  // command line — a repo full of other walks must not block this one.
  rows.push(checkCredentials(roleEnvPrefixes(manifests), env));
  rows.push(await checkAppHealth(args.base, { fetchImpl }));
  rows.push(
    await checkDeploymentIdentity(args.healthUrl || env.WALK_HEALTH_URL, {
      fetchImpl,
      base: args.base,
      manifestCount: manifests.length,
      expectEnvironment: args.expectEnvironment || env.WALK_EXPECT_ENVIRONMENT,
      expectRevision: args.expectRevision || env.WALK_EXPECT_REVISION,
    }),
  );
  rows.push(checkBrowser({ resolveChromium, chromiumPath }));
  rows.push(
    previewCookieProven(deps.collectorProbe)
      ? row("preview_mcp", STATE.OK, "cookie + storage injection proven in a scratch browser context")
      : row("preview_mcp", STATE.SKIP, "not exercised (no browser probe)"),
  );
  const tidewaveRequired =
    required.has("audit_actor") ||
    required.has("db_before_after") ||
    manifests.some((m) => m?.runtime?.require_tidewave === true);
  const tidewaveRow = await checkTidewave(args.tidewaveUrl || env.CASEIN_TIDEWAVE_MCP_URL, {
    fetchImpl,
    required: tidewaveRequired,
    requiredTools: requiredTidewaveTools(manifests, required),
  });
  rows.push(tidewaveRow);
  // db_before_after rides Tidewave's SELECT-only path: it is provable exactly
  // when Tidewave is. Without this it would stay unprovable and BLOCK a
  // manifest that requires a collector the driver actually implements.
  const dbReadProven = tidewaveRow.state === STATE.OK;
  // Visual baseline is stricter than the generic collector check: when
  // required, missing Artifact connectivity or a missing accepted baseline is
  // BLOCKED outright (a walk that cannot compare cannot prove anything), and
  // the diff engine must prove itself on a scratch fixture — all read-only,
  // no product page, no baseline created.
  let visualRow = null;
  if (required.has("visual_baseline")) {
    const store =
      "artifactStore" in deps ? deps.artifactStore : storeFromEnv(env);
    const readiness = await checkVisualBaselineReadiness(manifests, {
      store,
      deps: { fetchImpl, fsImpl: deps.fsImpl, engineProof: deps.visualEngineProof },
    });
    visualRow = row(
      "visual_baseline",
      readiness.state === "OK" ? STATE.OK : STATE.BLOCKED,
      readiness.detail,
      { required: true },
    );
  }

  // Artifact store: a REAL read-only artifact_list round-trip. Required when
  // any manifest depends on the store (visual baselines live there).
  const artifactStore = "artifactStore" in deps ? deps.artifactStore : storeFromEnv(env);
  const artifactRow = await checkArtifactStore({
    store: artifactStore,
    fetchImpl,
    required: required.has("visual_baseline"),
  });

  const PROBED = {
    ws: wsProven,
    a11y: a11yProven,
    resource_metrics: resourceMetricsProven,
    viewport: viewportProven,
    api: apiProven,
    downloads: downloadsProven,
  };
  for (const id of [
    "har", "ws", "dom", "screenshot", "a11y", "viewport", "visual_baseline",
    "resource_metrics", "api", "downloads", "db_read", "audit_actor",
    "artifact", "cleanup",
  ]) {
    if (id === "visual_baseline" && visualRow) {
      rows.push(visualRow);
      continue;
    }
    if (id === "artifact") {
      rows.push(artifactRow);
      continue;
    }
    const key = id === "db_read" ? "db_before_after" : id;
    rows.push(
      checkCollector(id, {
        required: required.has(key) || id === "screenshot" || (id === "viewport" && viewportRequired),
        proven:
          id === "db_read"
            ? dbReadProven
            : PROBED[id]
              ? PROBED[id](deps.collectorProbe)
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
