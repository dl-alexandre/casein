#!/usr/bin/env node
/**
 * Minimal newline-delimited JSON daemon for PreviewCtl.Playwright.Bridge tests.
 */
const readline = require("readline");
const fs = require("fs");

const rl = readline.createInterface({ input: process.stdin });

rl.on("line", (line) => {
  let payload;

  try {
    payload = JSON.parse(line);
  } catch (_error) {
    process.stdout.write(JSON.stringify({ ok: false, error: "invalid_json" }) + "\n");
    return;
  }

  const action = payload.action;
  const url = payload.url || "about:blank";

  // Deterministic in-flight hold for the concurrency test: park the request
  // until a sentinel file appears, so the Bridge's `pending` slot stays set
  // long enough for a second command to observe it. No other action blocks.
  if (action === "block") {
    const releasePath = payload.release_path;
    const poll = () => {
      if (releasePath && fs.existsSync(releasePath)) {
        process.stdout.write(JSON.stringify({ ok: true, url }) + "\n");
      } else {
        setTimeout(poll, 10);
      }
    };
    poll();
    return;
  }

  const result = { ok: true, url };

  if (
    action === "observe_live" ||
    action === "click" ||
    action === "type" ||
    action === "press" ||
    action === "reload" ||
    action === "go_back" ||
    action === "go_forward"
  ) {
    result.observation = {
      url,
      title: "Fake Page",
      dom_summary: {
        title: "Fake Page",
        headings: ["Hello"],
        links: [],
        visible_text: "Hello",
        byte_size: 100,
        url
      },
      console_errors: [],
      network_errors: []
    };

    if (
      (action === "click" || action === "type" || action === "press") &&
      payload.params?.diff !== false
    ) {
      result.diff = {
        diff_pct: 1.0,
        changed_pixels: 128,
        dimensions: { width: 1280, height: 720 },
        changed_regions: [{ x: 0, y: 0, width: 100, height: 40 }],
        diff_png_base64: "data:image/png;base64,AA==",
        settled: true,
        noise_filtered: false
      };
    }
  }

  if (action === "screenshot") {
    result.observation = { url, title: "Fake Page" };
    result.artifact = "fake-screenshot";
  }

  if (action === "get_storage" || action === "clear_storage") {
    result.local_storage = { key: "value" };
    result.session_storage = {};
    result.console_errors = [];
    result.network_errors = [];
  }

  if (action === "record_start") {
    result.recording_id = payload.params?.recording_id || "rec-1";
  }

  if (action === "record_stop") {
    result.recording_id = "rec-1";
    result.video_path = "/tmp/fake.webm";
  }

  process.stdout.write(JSON.stringify(result) + "\n");
});