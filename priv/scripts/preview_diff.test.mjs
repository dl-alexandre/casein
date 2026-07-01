import assert from "node:assert/strict";
import test from "node:test";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { PIXELMATCH_OPTIONS, computeDiff, wantsVisualDiff } from "./preview_diff.mjs";

function solidPng(width, height, rgba) {
  const png = new PNG({ width, height });

  for (let i = 0; i < png.data.length; i += 4) {
    png.data[i] = rgba[0];
    png.data[i + 1] = rgba[1];
    png.data[i + 2] = rgba[2];
    png.data[i + 3] = rgba[3];
  }

  return PNG.sync.write(png);
}

function withRect(baseBuf, x, y, width, height, rgba) {
  const png = PNG.sync.read(baseBuf);

  for (let row = y; row < y + height; row++) {
    for (let col = x; col < x + width; col++) {
      const i = (row * png.width + col) * 4;
      png.data[i] = rgba[0];
      png.data[i + 1] = rgba[1];
      png.data[i + 2] = rgba[2];
      png.data[i + 3] = rgba[3];
    }
  }

  return PNG.sync.write(png);
}

test("computeDiff reports changed pixels and regions", () => {
  const before = solidPng(64, 64, [255, 255, 255, 255]);
  const after = withRect(before, 8, 8, 32, 16, [0, 0, 255, 255]);

  const diff = computeDiff(before, after);

  assert.equal(diff.mismatch, undefined);
  assert.ok(diff.diff_pct > 0);
  assert.ok(diff.changed_pixels > 0);
  assert.ok(diff.changed_regions.length >= 1);
  assert.match(diff.diff_png_base64, /^data:image\/png;base64,/);
});

test("computeDiff returns mismatch for different dimensions", () => {
  const before = solidPng(64, 64, [255, 255, 255, 255]);
  const after = solidPng(32, 32, [255, 255, 255, 255]);

  assert.deepEqual(computeDiff(before, after), { mismatch: true });
});

test("computeDiff ignores identical frames", () => {
  const before = solidPng(32, 32, [240, 240, 240, 255]);
  const diff = computeDiff(before, before);

  assert.equal(diff.changed_pixels, 0);
  assert.equal(diff.diff_pct, 0);
});

test("computeDiff sets noise_filtered when changed regions fall below minArea", () => {
  const before = solidPng(64, 64, [255, 255, 255, 255]);
  const after = withRect(before, 8, 8, 20, 10, [0, 0, 255, 255]);

  const diff = computeDiff(before, after, { minArea: 5000 });

  assert.ok(diff.changed_pixels > 0);
  assert.equal(diff.changed_regions.length, 0);
  assert.equal(diff.noise_filtered, true);
});

test("computeDiff keeps regions at or above minArea", () => {
  const before = solidPng(128, 128, [255, 255, 255, 255]);
  const after = withRect(before, 16, 16, 32, 16, [0, 0, 255, 255]);

  const diff = computeDiff(before, after);

  assert.ok(diff.changed_regions.length >= 1);
  assert.ok(diff.changed_regions.every((region) => region.width * region.height >= 256));
  assert.equal(diff.noise_filtered, false);
});

test("computeDiff hardcodes includeAA:false in production pixelmatch options", () => {
  assert.equal(PIXELMATCH_OPTIONS.includeAA, false);
  assert.equal(PIXELMATCH_OPTIONS.threshold, 0.1);
});

test("includeAA:false suppresses font-smoothing-only halo churn", () => {
  const before = antiAliasedHaloPng(200);
  const after = antiAliasedHaloPng(230);

  const withAA = countChangedPixels(before, after, true);
  const withoutAA = countChangedPixels(before, after, false);
  const diff = computeDiff(before, after);

  assert.ok(withAA > withoutAA, "includeAA:true is more sensitive to halo-only churn");
  assert.ok(withoutAA < withAA / 2, "includeAA:false suppresses most halo-only pixels");
  assert.equal(diff.changed_pixels, withoutAA);
});

test("wantsVisualDiff gates screenshot, diff:false, and active recording", () => {
  assert.equal(wantsVisualDiff("screenshot", {}, {}), false);
  assert.equal(wantsVisualDiff("click", { diff: false }, {}), false);
  assert.equal(wantsVisualDiff("type", { diff: false }, {}), false);
  assert.equal(wantsVisualDiff("press", { diff: false }, {}), false);
  assert.equal(wantsVisualDiff("click", {}, { recording: { recordingId: "rec-1" } }), false);
  assert.equal(wantsVisualDiff("click", {}, {}), true);
  assert.equal(wantsVisualDiff("type", {}, {}), true);
  assert.equal(wantsVisualDiff("press", {}, {}), true);
});

function antiAliasedHaloPng(gray) {
  const width = 64;
  const height = 64;
  const png = new PNG({ width, height });

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;

      if (x >= 20 && x < 40 && y >= 20 && y < 40) {
        png.data[i] = 0;
        png.data[i + 1] = 0;
        png.data[i + 2] = 0;
      } else if (x >= 19 && x < 41 && y >= 19 && y < 41) {
        png.data[i] = gray;
        png.data[i + 1] = gray;
        png.data[i + 2] = gray;
      } else {
        png.data[i] = 255;
        png.data[i + 1] = 255;
        png.data[i + 2] = 255;
      }

      png.data[i + 3] = 255;
    }
  }

  return PNG.sync.write(png);
}

function countChangedPixels(beforeBuf, afterBuf, includeAA) {
  const a = PNG.sync.read(beforeBuf);
  const b = PNG.sync.read(afterBuf);
  const out = new PNG({ width: a.width, height: a.height });

  return pixelmatch(a.data, b.data, out.data, a.width, a.height, {
    threshold: 0.1,
    includeAA,
  });
}