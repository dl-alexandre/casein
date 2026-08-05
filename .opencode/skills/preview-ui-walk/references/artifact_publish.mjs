#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { mcpCall, storeFromEnv } from "./visual_baseline.mjs";

function die(message) {
  console.error(`[preview-ui-walk] publish failed: ${message}`);
  process.exit(1);
}

function argsFrom(argv) {
  const out = {};
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--out") out.out = argv[++index];
    else if (arg === "--name") out.name = argv[++index];
    else if (arg === "--prompt") out.prompt = argv[++index];
    else if (arg === "--help") out.help = true;
    else throw new Error(`unknown argument ${arg}`);
  }
  return out;
}

function walkFiles(root, dir = root) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const absolute = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...walkFiles(root, absolute));
    else if (entry.isFile()) files.push(path.relative(root, absolute).split(path.sep).join("/"));
  }
  return files.sort();
}

function localReferences(html) {
  const refs = [];
  const pattern = /\b(?:href|src)\s*=\s*["']([^"']+)["']/gi;
  for (const match of html.matchAll(pattern)) {
    const value = match[1].trim();
    if (
      !value ||
      value.startsWith("#") ||
      value.startsWith("/") ||
      /^(?:https?:|wss?:|data:|blob:|mailto:|javascript:)/i.test(value)
    ) {
      continue;
    }
    refs.push(value.split(/[?#]/, 1)[0]);
  }
  return refs;
}

export function validateReportTree(root, files = walkFiles(root)) {
  const available = new Set(files);
  const missing = [];
  for (const file of files.filter((name) => name.endsWith(".html"))) {
    const html = fs.readFileSync(path.join(root, file), "utf8");
    for (const reference of localReferences(html)) {
      let decoded = reference;
      try {
        decoded = decodeURIComponent(reference);
      } catch {
        missing.push(`${file} -> invalid URI ${reference}`);
        continue;
      }
      const target = path.posix.normalize(path.posix.join(path.posix.dirname(file), decoded));
      if (target === ".." || target.startsWith("../") || !available.has(target)) {
        missing.push(`${file} -> ${reference}`);
      }
    }
  }
  if (missing.length) {
    throw new Error(`missing or escaping report reference(s): ${missing.slice(0, 10).join(", ")}`);
  }
  return { files, html_files: files.filter((name) => name.endsWith(".html")).length };
}

function workspaceRoot(outDir) {
  const configured = process.env.CASEIN_CHECKOUT?.trim();
  if (configured) {
    const resolved = fs.realpathSync(configured);
    if (!fs.statSync(resolved).isDirectory()) {
      throw new Error(`CASEIN_CHECKOUT is not a directory: ${resolved}`);
    }
    return resolved;
  }
  return execFileSync("git", ["-C", outDir, "rev-parse", "--show-toplevel"], {
    encoding: "utf8",
  }).trim();
}

function inside(root, target) {
  const relative = path.relative(root, target);
  return relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`));
}

export function prepareSourceTree(outDir, files, workspace) {
  const sourceRoot = fs.realpathSync(outDir);
  if (inside(workspace, sourceRoot)) {
    return { sourceRoot, staged: false, cleanup() {} };
  }

  const stagingParent = path.join(workspace, "tmp", "casein-artifact-staging");
  fs.mkdirSync(stagingParent, { recursive: true });
  const stagedRoot = fs.mkdtempSync(path.join(stagingParent, "walk-"));

  try {
    for (const file of files) {
      const source = path.join(sourceRoot, file);
      const destination = path.join(stagedRoot, file);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      try {
        fs.linkSync(source, destination);
      } catch (error) {
        if (!["EXDEV", "EPERM", "EACCES"].includes(error?.code)) throw error;
        fs.copyFileSync(source, destination);
      }
    }
  } catch (error) {
    fs.rmSync(stagedRoot, { recursive: true, force: true });
    throw error;
  }

  return {
    sourceRoot: stagedRoot,
    staged: true,
    cleanup() {
      fs.rmSync(stagedRoot, { recursive: true, force: true });
    },
  };
}

function sourceEntry(workspace, sourceRoot, destination, source = destination) {
  const absolute = path.resolve(sourceRoot, source);
  const relative = path.relative(workspace, absolute);
  if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`)) {
    throw new Error(`output must be inside the workspace checkout: ${absolute}`);
  }
  return {
    path: destination,
    source_path: relative.split(path.sep).join("/"),
  };
}

export async function publishReport({
  outDir,
  name,
  prompt = "Publish preview UI walk evidence",
  store = storeFromEnv(),
}) {
  if (!store) {
    throw new Error(
      "artifact store not configured (CASEIN_ARTIFACT_MCP_URL / CASEIN_API_TOKEN / CASEIN_WORKSPACE_ID)",
    );
  }
  const absoluteOut = path.resolve(outDir);
  if (!fs.statSync(absoluteOut).isDirectory()) throw new Error(`not a directory: ${absoluteOut}`);
  const checked = validateReportTree(absoluteOut);
  if (!checked.files.includes("index.html") && !checked.files.includes("report.html")) {
    throw new Error("report output has neither index.html nor report.html");
  }

  const workspace = workspaceRoot(absoluteOut);
  const prepared = prepareSourceTree(absoluteOut, checked.files, workspace);

  try {
    const files = checked.files.map(
      (file) => sourceEntry(workspace, prepared.sourceRoot, file),
    );
    if (!checked.files.includes("index.html")) {
      files.push(sourceEntry(workspace, prepared.sourceRoot, "index.html", "report.html"));
    }

    const opts = { timeoutMs: 120_000 };
    const listed = await mcpCall(store, "artifact_list", {}, opts);
    if (listed.error) throw new Error(listed.error);
    const existing = (listed.ok?.artifacts || []).find(
      (artifact) => artifact?.name === name && !artifact?.retired,
    );
    const write = existing
      ? await mcpCall(
          store,
          "artifact_update",
          { artifact_id: existing.id, prompt, files },
          opts,
        )
      : await mcpCall(store, "artifact_create", { name, kind: "html", prompt, files }, opts);
    if (write.error) throw new Error(write.error);

    const artifactId = write.ok?.id || existing?.id;
    if (!artifactId) throw new Error("artifact write returned no id");
    const parity = await mcpCall(store, "artifact_verify", { artifact_id: artifactId }, opts);
    if (parity.error) throw new Error(parity.error);
    if (parity.ok?.status !== "ok" || parity.ok?.file_count < files.length) {
      throw new Error(`artifact parity incomplete: ${JSON.stringify(parity.ok)}`);
    }
    const served = await mcpCall(store, "artifact_serve", { artifact_id: artifactId }, opts);
    if (served.error) throw new Error(served.error);

    return {
      artifact_id: artifactId,
      public_url: served.ok?.public_url || write.ok?.public_url || null,
      file_count: parity.ok.file_count,
      parity: parity.ok.status,
      staged: prepared.staged,
    };
  } finally {
    prepared.cleanup();
  }
}

async function main() {
  const args = argsFrom(process.argv.slice(2));
  if (args.help) {
    console.log("usage: artifact_publish.mjs --out DIR --name NAME [--prompt TEXT]");
    return;
  }
  if (!args.out || !args.name) die("--out and --name are required");
  try {
    console.log(JSON.stringify(await publishReport({
      outDir: args.out,
      name: args.name,
      prompt: args.prompt,
    })));
  } catch (error) {
    die(String(error?.message || error));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
