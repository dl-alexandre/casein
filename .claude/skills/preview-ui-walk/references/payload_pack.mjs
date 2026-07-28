#!/usr/bin/env node
// Deterministic unpack/repack for the preview-ui-walk driver payload.
//
// The driver body ships gzip+base64 sharded across playwright_walk_payload.pl0..plN
// (playwright_walk.mjs is only a loader). Editing the driver therefore means
// unpack -> edit -> repack, and until now there was no committed tool for that:
// the original generator lived in /tmp and is gone (see references/.land-marker).
//
// Determinism matters. gzip embeds an mtime and an OS byte, so a naive repack
// produces a different blob for identical source and every rebuild shows up as
// a spurious diff. We pin mtime=0 and level=9, then normalise the OS byte to
// 0xFF ("unknown"), so identical source always yields identical shards.
//
//   node payload_pack.mjs unpack [--out driver.mjs]
//   node payload_pack.mjs repack <driver.mjs>
//   node payload_pack.mjs verify            # shards decode + round-trip cleanly
//
// `verify` is what selftest.mjs calls: it proves the committed shards decode,
// and that repacking the decoded source reproduces byte-identical shards.

import { gunzipSync, gzipSync } from "node:zlib";
import { readFileSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SHARD_CHARS = 4000; // matches the committed pl* shard width
const PREFIX = "playwright_walk_payload";

export function shardPaths(dir = HERE) {
  const out = [];
  for (let i = 0; ; i++) {
    const p = join(dir, `${PREFIX}.pl${i}`);
    if (!existsSync(p)) break;
    out.push(p);
  }
  return out;
}

export function readPayloadB64(dir = HERE) {
  const single = join(dir, `${PREFIX}.b64`);
  if (existsSync(single)) return readFileSync(single, "utf8").trim();
  const shards = shardPaths(dir);
  if (shards.length === 0) throw new Error(`no ${PREFIX}.b64 or ${PREFIX}.pl* shards in ${dir}`);
  return shards.map((p) => readFileSync(p, "utf8").trim()).join("");
}

export function unpack(dir = HERE) {
  return gunzipSync(Buffer.from(readPayloadB64(dir), "base64")).toString("utf8");
}

/**
 * Deterministic gzip: fixed level, zeroed mtime, and OS byte normalised to
 * 0xFF. Byte 9 of a gzip member is the OS field; node writes the host OS there,
 * which would make shards differ across machines for identical input.
 */
export function packB64(source) {
  const gz = gzipSync(Buffer.from(source, "utf8"), { level: 9, mtime: 0 });
  if (gz.length > 9) gz[9] = 0xff;
  return gz.toString("base64");
}

export function shardsFor(source) {
  const b64 = packB64(source);
  const out = [];
  for (let i = 0; i < b64.length; i += SHARD_CHARS) out.push(b64.slice(i, i + SHARD_CHARS));
  return out;
}

export function repack(source, dir = HERE) {
  const next = shardsFor(source);
  for (const p of shardPaths(dir)) unlinkSync(p); // drop stale shards when count shrinks
  next.forEach((chunk, i) => writeFileSync(join(dir, `${PREFIX}.pl${i}`), `${chunk}\n`));
  return next.length;
}

/**
 * Round-trip proof used by selftest: the committed shards must decode, and
 * repacking that source must reproduce exactly the committed shards. A failure
 * means someone hand-edited shards or packed non-deterministically.
 */
export function verify(dir = HERE) {
  const committed = readPayloadB64(dir);
  const source = gunzipSync(Buffer.from(committed, "base64")).toString("utf8");
  const repacked = packB64(source);
  const decodesBack = gunzipSync(Buffer.from(repacked, "base64")).toString("utf8") === source;
  return {
    ok: decodesBack && repacked === committed,
    deterministic: repacked === committed,
    roundTrips: decodesBack,
    sourceBytes: source.length,
    shards: shardPaths(dir).length,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [cmd, arg] = process.argv.slice(2);
  if (cmd === "unpack") {
    const src = unpack();
    const out = arg === "--out" ? resolve(process.argv[4]) : null;
    if (out) {
      writeFileSync(out, src);
      console.log(`unpacked ${src.length} bytes -> ${out}`);
    } else process.stdout.write(src);
  } else if (cmd === "repack") {
    if (!arg) {
      console.error("usage: payload_pack.mjs repack <driver.mjs>");
      process.exit(2);
    }
    const n = repack(readFileSync(resolve(arg), "utf8"));
    console.log(`repacked into ${n} shard(s)`);
  } else if (cmd === "verify") {
    const r = verify();
    console.log(JSON.stringify(r, null, 2));
    process.exit(r.ok ? 0 : 1);
  } else {
    console.error("usage: payload_pack.mjs unpack|repack <file>|verify");
    process.exit(2);
  }
}
