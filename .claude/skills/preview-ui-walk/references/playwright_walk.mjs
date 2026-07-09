#!/usr/bin/env node
// preview-ui-walk driver for COOKIE/REDIRECT-login apps — the path walk.py can't
// do. DevIDE's preview MCP blocks 302s, so a redirect login silently produces a
// false green (screenshots stay on the pre-login page). This drives the box's
// cached Chromium directly via playwright-core with a server-minted session
// cookie, and — critically — verifies the landed URL per page.
//
// Still READ-ONLY: navigate + screenshot + collect console/network only. Never
// click/type/submit; honor the manifest's safety.deny_events regardless.
//
// Runtime on the devbox (see SKILL.md "Auth reality"):
//   - playwright-core lives under ~/.npm/_npx/*/node_modules — run from a dir
//     where it resolves, or: NODE_PATH=$(dirname $(find ~/.npm/_npx -name playwright-core -type d|head -1)) node playwright_walk.mjs …
//   - cached Chromium at ~/.cache/ms-playwright/chromium-<build>; auto-discovered
//     (override with PW_CHROMIUM=/abs/path/to/chrome).
//
// Usage:
//   node playwright_walk.mjs --manifest m.json --base http://127.0.0.1:<port> --out ./run \
//     [--settle-ms 1500] [--tidewave-url http://127.0.0.1:<port>/tidewave/mcp]
//
// Manifest login (app-owned .devide/preview-walk.json):
//   "login": { "kind": "redirect_cookie", "path": "/dev/login", "lands_on": "/admin" }
//   // legacy: "type": "cookie"
// Optional runtime (priority-1 collector):
//   "runtime": { "tidewave": true, "log_levels": ["error","warning"] }
//   "safety":  { "env_check": ["APP_API_URL", …] }
//
// Emits: <out>/report.html, <out>/results.json, <out>/shot-*.png.

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { beginRuntime, pageRuntimeLogs } from "./runtime_evidence.mjs";

const require = createRequire(import.meta.url);

function die(msg) {
  console.error(`[preview-ui-walk] ERROR: ${msg}`);
  process.exit(2);
}

// playwright-core is CJS and (on the devbox) lives only in npx caches, which ESM
// `import` + NODE_PATH won't find — so resolve it with require(): PW_CORE
// override, then a plain resolve, then the newest ~/.npm/_npx/*/playwright-core.
function loadChromium() {
  const tryReq = (spec) => {
    try { return require(spec).chromium; } catch { return null; }
  };
  if (process.env.PW_CORE) {
    const c = tryReq(process.env.PW_CORE);
    if (c) return c;
    die(`PW_CORE=${process.env.PW_CORE} did not export chromium`);
  }
  let c = tryReq("playwright-core");
  if (c) return c;
  const npx = path.join(os.homedir(), ".npm", "_npx");
  if (fs.existsSync(npx)) {
    for (const d of fs.readdirSync(npx)) {
      const cand = path.join(npx, d, "node_modules", "playwright-core");
      if (fs.existsSync(cand)) {
        c = tryReq(cand);
        if (c) return c;
      }
    }
  }
  die("cannot resolve playwright-core — `npm i playwright-core` or set PW_CORE=/abs/path");
}

function parseArgs(argv) {
  const a = { settleMs: 1500, tidewaveUrl: null };
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i], v = argv[i + 1];
    if (k === "--manifest") a.manifest = v;
    else if (k === "--base") a.base = v.replace(/\/$/, "");
    else if (k === "--out") a.out = v;
    else if (k === "--settle-ms") a.settleMs = parseInt(v, 10);
    else if (k === "--tidewave-url") a.tidewaveUrl = v;
    else die(`unknown arg ${k}`);
  }
  if (!a.manifest || !a.base || !a.out) die("need --manifest, --base, --out");
  return a;
}

function wantsCookieLogin(login) {
  return login.kind === "redirect_cookie" || login.type === "cookie";
}

function mergeLoginParams(login) {
  const params = { ...(login.params || {}) };
  for (const envName of login.params_from_env || []) {
    if (process.env[envName] != null && process.env[envName] !== "") {
      // Map WALK_LOGIN_EMAIL → email when key not set
      const key =
        envName === "WALK_LOGIN_EMAIL"
          ? "email"
          : envName === "WALK_LOGIN_ROLE"
            ? "role"
            : envName.toLowerCase();
      if (params[key] == null) params[key] = process.env[envName];
    }
  }
  return { ...login, params };
}

// Newest cached Chromium binary, unless PW_CHROMIUM overrides. Playwright's build
// layout varies (chrome-linux64/chrome now, chrome-linux/chrome historically; a
// headless_shell as last resort), so probe known candidates. Full builds win.
function chromiumPath() {
  if (process.env.PW_CHROMIUM) return process.env.PW_CHROMIUM;
  const root = path.join(os.homedir(), ".cache", "ms-playwright");
  if (!fs.existsSync(root)) die(`no cached Chromium under ${root} (set PW_CHROMIUM)`);
  const buildNo = (d) => parseInt(d.split("-").pop(), 10) || 0;
  const dirs = fs.readdirSync(root).filter((d) => /^chromium(_headless_shell)?-\d+$/.test(d));
  const ordered = [
    ...dirs.filter((d) => d.startsWith("chromium-")).sort((x, y) => buildNo(y) - buildNo(x)),
    ...dirs.filter((d) => d.startsWith("chromium_headless_shell-")).sort((x, y) => buildNo(y) - buildNo(x)),
  ];
  const candidates = [
    ["chrome-linux64", "chrome"],
    ["chrome-linux", "chrome"],
    ["chrome-headless-shell-linux64", "chrome-headless-shell"],
  ];
  for (const b of ordered) {
    for (const [sub, bin] of candidates) {
      const exe = path.join(root, b, sub, bin);
      if (fs.existsSync(exe)) return exe;
    }
  }
  die(`no Chromium binary under ${root} (set PW_CHROMIUM)`);
}

// Mint the session cookie server-side: curl follows the login redirects and keeps
// every Set-Cookie in a Netscape jar, which the preview MCP's 302 block cannot.
function mintCookies(base, login) {
  const qs = new URLSearchParams(login.params || {}).toString();
  const url = base + login.path + (qs ? `?${qs}` : "");
  const jar = path.join(os.tmpdir(), `pw-jar-${process.pid}.txt`);
  try {
    execFileSync("curl", ["-sS", "-c", jar, "-L", "-o", "/dev/null", url], {
      timeout: 30000,
    });
  } catch (e) {
    die(`curl login failed for ${login.path}: ${e.message}`);
  }
  const cookies = [];
  for (const line of fs.readFileSync(jar, "utf8").split("\n")) {
    if (!line || line.startsWith("#") && !line.startsWith("#HttpOnly_")) continue;
    const l = line.replace(/^#HttpOnly_/, "");
    const p = l.split("\t");
    if (p.length >= 7) cookies.push({ name: p[5], value: p[6], url: base });
  }
  fs.rmSync(jar, { force: true });
  if (!cookies.length) die(`login set no cookies (${login.path}) — check the bypass route`);
  return cookies;
}

// Expected path is a prefix/substring of the landed path (query strings and
// trailing segments don't false-fail). A gated page bounced to /login fails here.
function urlOk(landed, expected) {
  if (!landed) return null;
  let p = landed;
  try { p = new URL(landed).pathname; } catch {}
  const want = expected.split("?")[0].replace(/\/$/, "");
  return p.includes(want) || p === expected;
}

// Smoke walks care about "did the page land and render?", not third-party badge
// CSP, nested-iframe CSP (LiveDashboard embed), or nonce inline-style noise.
// Those still show up as raw counts/samples; they do not flip PASS→FAIL unless
// the page opts into `strict_errors: true`.
const DEFAULT_NOISE_RE =
  /Content Security Policy|ERR_BLOCKED_BY_CSP|\bcsp\b|shields\.io|badge\.svg|github\.com\/.*\/badge|Applying inline style violates|Executing inline script violates/i;

function noisePatterns(page, manifest) {
  const extras = []
    .concat(manifest.noise_patterns || [])
    .concat(page.noise_patterns || []);
  if (!extras.length) return DEFAULT_NOISE_RE;
  const parts = [DEFAULT_NOISE_RE.source, ...extras.map((p) => {
    try { return new RegExp(p, "i").source; } catch { return null; }
  }).filter(Boolean)];
  return new RegExp(parts.join("|"), "i");
}

function actionable(errors, noiseRe) {
  return (errors || []).filter((e) => !noiseRe.test(String(e)));
}

function pageVerdict({ loaded, within, uok, mainStatus, actionableConsole, actionableNetwork }) {
  if (!loaded || !within || uok === false) return "FAIL";
  if (mainStatus != null && mainStatus >= 400) return "FAIL";
  // Default smoke: after noise filter, leftover console/network still fail so
  // real JS/API breaks don't greenwash. Document 4xx already handled above.
  if (actionableConsole.length || actionableNetwork.length) return "FAIL";
  return "PASS";
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const m = JSON.parse(fs.readFileSync(a.manifest, "utf8"));
  fs.mkdirSync(a.out, { recursive: true });

  // Priority-1 runtime: Tidewave probe + env_check strip (before browser work).
  const runtimeBag = await beginRuntime(m, {
    base: a.base,
    tidewaveUrl: a.tidewaveUrl,
  });
  if (runtimeBag.fatal) die(runtimeBag.fatal);
  if (runtimeBag.requested) {
    const tw = runtimeBag.tidewave || {};
    console.log(
      `[preview-ui-walk] runtime tidewave=${tw.status}` +
        (tw.url ? ` url=${tw.url}` : "") +
        (tw.error ? ` err=${tw.error}` : ""),
    );
    const risks = (runtimeBag.env_check?.items || []).filter((i) => i.risk === "prod_like");
    if (risks.length) {
      console.log(
        `[preview-ui-walk] ⚠ env_check prod_like: ${risks.map((r) => r.key).join(", ")}`,
      );
    }
  }

  const chromium = loadChromium();
  const browser = await chromium.launch({ executablePath: chromiumPath(), headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });

  const login = mergeLoginParams(m.login || {});
  if (wantsCookieLogin(login)) {
    await context.addCookies(mintCookies(a.base, login));
    console.log(`[preview-ui-walk] minted session cookie via ${login.path}`);
  }

  const page = await context.newPage();
  const results = [];
  for (const pg of m.pages) {
    const consoleErrors = [];
    const networkErrors = [];
    let mainStatus = null;
    const onConsole = (msg) => { if (msg.type() === "error") consoleErrors.push(msg.text()); };
    const onPageError = (err) => consoleErrors.push(String(err));
    const onResponse = (r) => {
      try {
        if (r.request().isNavigationRequest() && r.frame() === page.mainFrame()) {
          mainStatus = r.status();
        }
      } catch { /* frame torn down */ }
      if (r.status() >= 400) networkErrors.push(`${r.status()} ${r.url()}`);
    };
    const onFailed = (req) =>
      networkErrors.push(`failed ${req.url()} ${req.failure()?.errorText || ""}`.trim());
    page.on("console", onConsole);
    page.on("pageerror", onPageError);
    page.on("response", onResponse);
    page.on("requestfailed", onFailed);

    const budget = pg.budget_ms || 15000;
    const t0 = Date.now();
    let loaded = true;
    try {
      await page.goto(a.base + pg.path, { waitUntil: "networkidle", timeout: budget });
    } catch {
      loaded = false;
    }
    await page.waitForTimeout(a.settleMs);
    const elapsed = Date.now() - t0;
    const landed = page.url();
    const uok = urlOk(landed, pg.lands_on || pg.path);
    const noiseRe = noisePatterns(pg, m);
    const actConsole = actionable(consoleErrors, noiseRe);
    const actNetwork = actionable(networkErrors, noiseRe);
    // strict_errors: true keeps pre-filter behavior (any console/network fails).
    const strict = pg.strict_errors === true || m.strict_errors === true;
    const ceForVerdict = strict ? consoleErrors : actConsole;
    const neForVerdict = strict ? networkErrors : actNetwork;

    const shotFile = `shot-${String(results.length).padStart(2, "0")}.png`;
    let shot = null;
    try {
      const buf = await page.screenshot({ type: "png" });
      fs.writeFileSync(path.join(a.out, shotFile), buf);
      shot = `data:image/png;base64,${buf.toString("base64")}`;
    } catch {}

    page.off("console", onConsole);
    page.off("pageerror", onPageError);
    page.off("response", onResponse);
    page.off("requestfailed", onFailed);

    const within = elapsed <= budget;
    let status = pageVerdict({
      loaded,
      within,
      uok,
      mainStatus,
      actionableConsole: ceForVerdict,
      actionableNetwork: neForVerdict,
    });

    // Server log *delta* for this page only (Tidewave ring buffer is cumulative).
    // Silent BEAM errors during the page load fail a "green" shell.
    const runtimePage = await pageRuntimeLogs(runtimeBag, pg.name);
    const serverErrors = runtimePage.error_log_count || 0;
    if (status === "PASS" && runtimePage.status === "ok" && serverErrors > 0) {
      status = "FAIL";
    }

    results.push({
      name: pg.name, path: pg.path, ms: elapsed, budget_ms: pg.budget_ms,
      console_errors: consoleErrors.length, network_errors: networkErrors.length,
      actionable_console_errors: actConsole.length,
      actionable_network_errors: actNetwork.length,
      console_samples: actConsole.slice(0, 5),
      network_samples: actNetwork.slice(0, 5),
      main_status: mainStatus,
      runtime: runtimePage,
      status, shot, shot_file: shot ? shotFile : null, landed, url_ok: uok,
    });
    const flag = uok === false ? `  ⚠ landed=${landed}` : "";
    const noise =
      consoleErrors.length - actConsole.length + networkErrors.length - actNetwork.length;
    const noiseNote = noise > 0 ? ` noise=${noise}` : "";
    const twNote =
      runtimePage.status === "ok"
        ? ` tw_err_logs=${serverErrors}`
        : runtimePage.status === "skipped"
          ? " tw=skipped"
          : runtimeBag.requested
            ? ` tw=${runtimePage.status || "?"}`
            : "";
    console.log(
      `[preview-ui-walk] ${status.padEnd(4)} ${pg.name.padEnd(16)} ${String(elapsed).padStart(6)}ms  ` +
        `ce=${actConsole.length}/${consoleErrors.length} ne=${actNetwork.length}/${networkErrors.length}` +
        `${noiseNote}${twNote}${flag}`,
    );
  }

  await browser.close();

  // Do not serialize internal cursors into the artifact payload.
  const { _log_cursors: _drop, ...runtimePublic } = runtimeBag;
  const payload = {
    base: a.base,
    runtime: runtimePublic,
    pages: results.map((r) => {
      const { shot, ...rest } = r;
      return rest; // keep results.json smaller; shots are on disk
    }),
  };
  // Still keep shot paths; re-add shot only in report from files if needed
  fs.writeFileSync(
    path.join(a.out, "results.json"),
    JSON.stringify(payload, null, 2),
  );
  // Report needs inline shots — rebuild from results that still have shot in memory
  writeReport(a.out, m, results, runtimeBag);
  const passed = results.filter((r) => r.status === "PASS").length;
  console.log(`[preview-ui-walk] ${passed}/${results.length} pages PASS -> ${a.out}/report.html`);
  process.exit(passed === results.length ? 0 : 1);
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function writeReport(out, m, results, runtimeBag) {
  const rows = results.map((r) => {
    const img = r.shot ? `<img src="${r.shot}" width="240">` : "—";
    const color = r.status === "PASS" ? "#2ea043" : "#f85149";
    const redirect =
      r.url_ok === false
        ? `<br><small style="color:#f85149">↳ redirected to ${esc(r.landed)}</small>`
        : "";
    const samples = (r.console_samples || []).concat(r.network_samples || []).slice(0, 3)
      .map((s) => `<div style="font-size:11px;color:#f85149;max-width:28rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(s)}</div>`)
      .join("");
    const rt = r.runtime || {};
    let twCell = "—";
    if (rt.status === "ok") {
      const errN = rt.error_log_count || 0;
      const warnN = rt.logs?.levels?.warning?.count;
      twCell =
        `error_logs=${errN}` +
        (warnN != null ? `<br>warning_logs=${warnN}` : "") +
        (errN > 0 && rt.logs?.levels?.error?.samples?.length
          ? rt.logs.levels.error.samples
              .slice(0, 2)
              .map(
                (s) =>
                  `<div style="font-size:11px;color:#f85149;max-width:22rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(s)}</div>`,
              )
              .join("")
          : "");
    } else if (rt.status === "skipped") {
      twCell = `<span style="color:#d29922">skipped: ${esc(rt.reason || "tidewave_unavailable")}</span>`;
    } else if (rt.status === "disabled") {
      twCell = "disabled";
    } else if (rt.status) {
      twCell = esc(rt.status);
    }
    return `<tr><td>${img}</td><td><b>${esc(r.name)}</b><br><code>${esc(r.path)}</code>${redirect}` +
      `<br><small>landed ${esc(String(r.landed || ""))}</small></td>` +
      `<td>${r.ms}ms<br><small>budget ${r.budget_ms}</small>` +
      (r.main_status != null ? `<br><small>HTTP ${r.main_status}</small>` : "") +
      `</td>` +
      `<td>console ${r.actionable_console_errors ?? r.console_errors}/${r.console_errors}` +
      `<br>network ${r.actionable_network_errors ?? r.network_errors}/${r.network_errors}` +
      `${samples}</td>` +
      `<td>${twCell}</td>` +
      `<td style="color:${color}"><b>${r.status}</b></td></tr>`;
  });

  const strip = runtimeStripHtml(runtimeBag);
  const name = (m.report && m.report.name) || "preview-ui-walk";
  const doc = `<!doctype html><meta charset=utf-8><title>${esc(name)}</title>
<style>
body{font-family:system-ui,Arial;margin:2rem;background:#0b1021;color:#e6e6e6}
table{border-collapse:collapse;width:100%}
td,th{border-top:1px solid #333;padding:.6rem;vertical-align:top;text-align:left}
code{color:#79c0ff}
.meta{color:#9aa4b2}
.strip{background:#12182b;border:1px solid #2a3348;border-radius:8px;padding:1rem;margin:1rem 0}
.pill{display:inline-block;padding:.1rem .45rem;border-radius:999px;font-size:12px;font-weight:700}
.ok{background:#1a3d24;color:#3fb950}.warn{background:#3d3010;color:#d29922}.bad{background:#3d1a1a;color:#f85149}
</style>
<h1>${esc(name)}</h1>
<p class="meta">Authenticated (Playwright) read-only walk.
Browser errors are <code>actionable/raw</code>; Tidewave server logs are a separate column.</p>
${strip}
<table><tr><th>Screen</th><th>Page</th><th>Load</th><th>Browser</th><th>Tidewave</th><th>Result</th></tr>
${rows.join("\n")}</table>`;
  fs.writeFileSync(path.join(out, "report.html"), doc);
}

function runtimeStripHtml(runtimeBag) {
  if (!runtimeBag || !runtimeBag.requested) {
    return `<div class="strip meta">Runtime evidence: <span class="pill">disabled</span> (set <code>runtime.tidewave: true</code> in the manifest)</div>`;
  }
  const tw = runtimeBag.tidewave || {};
  let twPill = `<span class="pill warn">skipped</span>`;
  if (tw.status === "ok") twPill = `<span class="pill ok">ok</span>`;
  else if (tw.status === "disabled") twPill = `<span class="pill">disabled</span>`;
  else if (tw.status === "skipped") twPill = `<span class="pill warn">skipped: ${esc(tw.reason || "unavailable")}</span>`;

  const app = runtimeBag.app || {};
  const envItems = runtimeBag.env_check?.items || [];
  const envRows = envItems
    .map((i) => {
      const pill =
        i.risk === "prod_like"
          ? "bad"
          : i.risk === "unset"
            ? "warn"
            : "ok";
      return `<tr><td><code>${esc(i.key)}</code></td><td><span class="pill ${pill}">${esc(i.risk)}</span></td><td class="meta">${esc(i.preview || "—")}</td></tr>`;
    })
    .join("");

  return `<div class="strip">
  <div><b>Runtime</b> Tidewave ${twPill}
    ${tw.url ? ` · <code>${esc(tw.url)}</code>` : ""}
    ${tw.error ? ` · <span class="meta">${esc(tw.error)}</span>` : ""}
  </div>
  <div class="meta" style="margin-top:.4rem">
    app cwd: <code>${esc(app.cwd || "—")}</code>
    · git: <code>${esc(app.git_sha || "—")}</code>
    · MIX_ENV: <code>${esc(app.mix_env || "—")}</code>
    · server error log total (sum of per-page tails): <b>${runtimeBag.error_log_total ?? 0}</b>
    · env_check source: <code>${esc(runtimeBag.env_check?.source || "none")}</code>
  </div>
  ${
    envRows
      ? `<table style="margin-top:.6rem;max-width:40rem"><tr><th>env</th><th>risk</th><th>preview</th></tr>${envRows}</table>`
      : ""
  }
</div>`;
}

main().catch((e) => die(e.stack || String(e)));
