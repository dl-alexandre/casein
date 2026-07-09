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
//   node playwright_walk.mjs --manifest m.json --base http://127.0.0.1:<port> --out ./run [--settle-ms 1500]
//
// Manifest login block for this driver:
//   "login": { "type": "cookie", "path": "/auth/superadmin/mock",
//              "params": { "email": "you@x.com", "role": "superadmin" },
//              "lands_on": "/superadmin" }
//
// Emits: <out>/report.html, <out>/results.json, <out>/shot-*.png.

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

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
  const a = { settleMs: 1500 };
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i], v = argv[i + 1];
    if (k === "--manifest") a.manifest = v;
    else if (k === "--base") a.base = v.replace(/\/$/, "");
    else if (k === "--out") a.out = v;
    else if (k === "--settle-ms") a.settleMs = parseInt(v, 10);
    else die(`unknown arg ${k}`);
  }
  if (!a.manifest || !a.base || !a.out) die("need --manifest, --base, --out");
  return a;
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

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const m = JSON.parse(fs.readFileSync(a.manifest, "utf8"));
  fs.mkdirSync(a.out, { recursive: true });

  const chromium = loadChromium();
  const browser = await chromium.launch({ executablePath: chromiumPath(), headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });

  const login = m.login || {};
  if (login.type === "cookie") {
    await context.addCookies(mintCookies(a.base, login));
    console.log(`[preview-ui-walk] minted session cookie via ${login.path}`);
  }

  const page = await context.newPage();
  const results = [];
  for (const pg of m.pages) {
    const consoleErrors = [];
    const networkErrors = [];
    const onConsole = (msg) => { if (msg.type() === "error") consoleErrors.push(msg.text()); };
    const onPageError = (err) => consoleErrors.push(String(err));
    const onResponse = (r) => { if (r.status() >= 400) networkErrors.push(`${r.status()} ${r.url()}`); };
    const onFailed = (req) => networkErrors.push(`failed ${req.url()}`);
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
    const status =
      loaded && within && consoleErrors.length === 0 && uok !== false ? "PASS" : "FAIL";
    results.push({
      name: pg.name, path: pg.path, ms: elapsed, budget_ms: pg.budget_ms,
      console_errors: consoleErrors.length, network_errors: networkErrors.length,
      status, shot, shot_file: shot ? shotFile : null, landed, url_ok: uok,
    });
    const flag = uok === false ? `  ⚠ landed=${landed}` : "";
    console.log(
      `[preview-ui-walk] ${status.padEnd(4)} ${pg.name.padEnd(16)} ${String(elapsed).padStart(6)}ms  ce=${consoleErrors.length} ne=${networkErrors.length}${flag}`,
    );
  }

  await browser.close();

  fs.writeFileSync(
    path.join(a.out, "results.json"),
    JSON.stringify({ base: a.base, pages: results }, null, 2),
  );
  writeReport(a.out, m, results);
  const passed = results.filter((r) => r.status === "PASS").length;
  console.log(`[preview-ui-walk] ${passed}/${results.length} pages PASS -> ${a.out}/report.html`);
  process.exit(passed === results.length ? 0 : 1);
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function writeReport(out, m, results) {
  const rows = results.map((r) => {
    const img = r.shot ? `<img src="${r.shot}" width="240">` : "—";
    const color = r.status === "PASS" ? "#2ea043" : "#f85149";
    const redirect =
      r.url_ok === false
        ? `<br><small style="color:#f85149">↳ redirected to ${esc(r.landed)}</small>`
        : "";
    return `<tr><td>${img}</td><td><b>${esc(r.name)}</b><br><code>${esc(r.path)}</code>${redirect}</td>` +
      `<td>${r.ms}ms<br><small>budget ${r.budget_ms}</small></td>` +
      `<td>console ${r.console_errors}<br>network ${r.network_errors}</td>` +
      `<td style="color:${color}"><b>${r.status}</b></td></tr>`;
  });
  const name = (m.report && m.report.name) || "preview-ui-walk";
  const doc = `<!doctype html><meta charset=utf-8><title>${esc(name)}</title>
<style>body{font-family:system-ui,Arial;margin:2rem;background:#0b1021;color:#e6e6e6}
table{border-collapse:collapse;width:100%}td{border-top:1px solid #333;padding:.6rem;vertical-align:top}
code{color:#79c0ff}th{text-align:left;padding:.6rem}</style>
<h1>${esc(name)}</h1>
<p>Authenticated (Playwright) read-only walk of <code>${esc(m.workspace || "")}</code>.</p>
<table><tr><th>Screen</th><th>Page</th><th>Load</th><th>Errors</th><th>Result</th></tr>
${rows.join("\n")}</table>`;
  fs.writeFileSync(path.join(out, "report.html"), doc);
}

main().catch((e) => die(e.stack || String(e)));
