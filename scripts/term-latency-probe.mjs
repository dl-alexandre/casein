#!/usr/bin/env node
//
// term-latency-probe.mjs — measure raw-terminal echo latency at several
// synthetic RTTs, using the ?termlat harness in ghostty_terminal.js.
//
// Drives an isolated dev-preview instance (see scripts/dev-preview-instance.sh),
// focuses the raw Ghostty terminal, types isolated keystrokes, and reads back
// window.devideTermLatency.stats() (p50/p95 of perceived echo latency).
//
// Usage:
//   node scripts/term-latency-probe.mjs [baseURL] [samples]
//   node scripts/term-latency-probe.mjs http://127.0.0.1:4196/workspaces/preview-sandbox?host=local 50
//
import { chromium } from "/data/workspaces/dalexandre/dev_ide/priv/scripts/node_modules/playwright/index.mjs";

const base =
  process.argv[2] ||
  "http://127.0.0.1:4196/workspaces/preview-sandbox?host=local";
const samples = parseInt(process.argv[3] || "50", 10);
const injects = [0, 40, 80, 160];

const sep = base.includes("?") ? "&" : "?";
const browser = await chromium.launch();

const rows = [];
for (const inject of injects) {
  // Fresh context+page per RTT — a reused page raced the terminal remount.
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  page.on("console", (m) => {
    const t = m.text();
    if (t.startsWith("[termlat]")) console.log("  page:", t);
  });

  const url = `${base}${sep}termlat=${inject}`;
  await page.goto(url, { waitUntil: "networkidle", timeout: 30000 });

  await page
    .waitForFunction(() => typeof window.devideTermLatency === "object", { timeout: 25000 })
    .catch(() => {});
  const input = await page
    .waitForSelector('[data-ghostty-input="true"]', { state: "attached", timeout: 25000 })
    .catch(() => null);
  if (!input) {
    rows.push({ inject, error: "no raw terminal input found (is the workspace in manual mode?)" });
    await context.close();
    continue;
  }
  // Let LiveView mount, the PTY spawn, the shell print its prompt, and the
  // first full frame paint before we start correlating keystrokes ↔ echoes.
  await page.waitForTimeout(4500);

  await page.click('[phx-hook="GhosttyTerminal"]').catch(() => {});
  await input.focus().catch(() => {});
  await page.evaluate(() => window.devideTermLatency && window.devideTermLatency.reset());

  // Type isolated printable chars; gaps keep one keystroke ↔ one echo frame.
  // Space keystrokes wider than the largest round trip so only one is ever in
  // flight — otherwise FIFO frame↔keystroke attribution drifts at high RTT.
  const interval = Math.max(140, inject + 120);
  for (let i = 0; i < samples; i += 1) {
    await page.keyboard.type("x");
    await page.waitForTimeout(interval);
  }
  for (let i = 0; i < samples; i += 1) await page.keyboard.press("Backspace");
  await page.waitForTimeout(500);

  const stats = await page.evaluate(() =>
    window.devideTermLatency ? window.devideTermLatency.stats() : null
  );
  rows.push({ inject, ...(stats || { error: "no stats" }) });
  await context.close();
}

await browser.close();

console.log("\n=== raw-terminal echo latency (ms) ===");
console.log("injectRTT | p50 | p95 |  n  | (perceived echo per keystroke)");
for (const r of rows) {
  if (r.error) {
    console.log(`${String(r.inject).padStart(8)} | ${r.error}`);
    continue;
  }
  console.log(
    `${String(r.inject).padStart(8)} | ${String(Math.round(r.p50)).padStart(3)} | ` +
      `${String(Math.round(r.p95)).padStart(3)} | ${String(r.n).padStart(3)}`
  );
}
console.log(JSON.stringify(rows));
