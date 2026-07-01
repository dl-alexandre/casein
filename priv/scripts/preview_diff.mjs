import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";

/** Production pixelmatch options — includeAA:false ignores font-smoothing churn. */
export const PIXELMATCH_OPTIONS = { threshold: 0.1, includeAA: false };

/**
 * Whether a mutating preview action should capture before/after frames for diffing.
 */
export function wantsVisualDiff(action, params = {}, entry = {}) {
  return action !== "screenshot" && params.diff !== false && !entry.recording;
}

/**
 * Compare two viewport PNG buffers and return diff stats plus a pixelmatch overlay.
 */
export function computeDiff(beforeBuf, afterBuf, opts = {}) {
  const a = PNG.sync.read(beforeBuf);
  const b = PNG.sync.read(afterBuf);

  if (a.width !== b.width || a.height !== b.height) {
    return { mismatch: true };
  }

  const { width, height } = a;
  const out = new PNG({ width, height });
  const matchOpts = {
    ...PIXELMATCH_OPTIONS,
    ...(opts.threshold != null ? { threshold: opts.threshold } : {}),
  };
  const changed = pixelmatch(a.data, b.data, out.data, width, height, matchOpts);

  const regions = deriveRegions(out.data, width, height, {
    cell: opts.cell ?? 32,
    cellHits: opts.cellHits ?? 8,
    minArea: opts.minArea ?? 256,
  });

  return {
    diff_pct: +((changed / (width * height)) * 100).toFixed(2),
    changed_pixels: changed,
    dimensions: { width, height },
    changed_regions: regions.rects,
    diff_png_base64: `data:image/png;base64,${PNG.sync.write(out).toString("base64")}`,
    noise_filtered: regions.dropped > 0,
  };
}

function deriveRegions(rgba, width, height, { cell, cellHits, minArea }) {
  const cols = Math.ceil(width / cell);
  const rows = Math.ceil(height / cell);
  const grid = new Uint32Array(cols * rows);

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      if (rgba[i + 3] > 0 && rgba[i] > 0) {
        grid[(y / cell | 0) * cols + (x / cell | 0)]++;
      }
    }
  }

  const marked = Array.from(grid, (n) => (n >= cellHits ? 1 : 0));
  const rects = mergeCells(marked, cols, rows, cell, width, height);
  const kept = rects.filter((r) => r.width * r.height >= minArea);

  return { rects: kept, dropped: rects.length - kept.length };
}

function mergeCells(marked, cols, rows, cell, width, height) {
  const visited = new Uint8Array(cols * rows);
  const rects = [];

  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      const start = row * cols + col;
      if (!marked[start] || visited[start]) continue;

      let minCol = col;
      let maxCol = col;
      let minRow = row;
      let maxRow = row;
      const stack = [start];
      visited[start] = 1;

      while (stack.length) {
        const idx = stack.pop();
        const r = (idx / cols) | 0;
        const c = idx % cols;

        minCol = Math.min(minCol, c);
        maxCol = Math.max(maxCol, c);
        minRow = Math.min(minRow, r);
        maxRow = Math.max(maxRow, r);

        const neighbours = [
          [r - 1, c],
          [r + 1, c],
          [r, c - 1],
          [r, c + 1],
        ];

        for (const [nr, nc] of neighbours) {
          if (nr < 0 || nc < 0 || nr >= rows || nc >= cols) continue;
          const nidx = nr * cols + nc;
          if (!marked[nidx] || visited[nidx]) continue;
          visited[nidx] = 1;
          stack.push(nidx);
        }
      }

      const x = minCol * cell;
      const y = minRow * cell;
      const rectWidth = Math.min(width - x, (maxCol - minCol + 1) * cell);
      const rectHeight = Math.min(height - y, (maxRow - minRow + 1) * cell);

      rects.push({ x, y, width: rectWidth, height: rectHeight });
    }
  }

  return rects;
}