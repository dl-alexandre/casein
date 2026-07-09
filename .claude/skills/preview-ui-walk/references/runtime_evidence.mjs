// Priority-1 runtime evidence for preview-ui-walk:
//   - Tidewave availability
//   - per-page get_logs (error/warning)
//   - safety.env_check strip (prefer app env via project_eval)
//
// Never mutates. SQL/probes beyond env + logs are out of scope for v1 collector.
// When Tidewave is unreachable, callers mark skipped: tidewave_unavailable.

import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

// Host/path patterns that look like production write targets.
// Stage/sandbox/dev are intentionally NOT prod_like (still surfaced in preview).
const PROD_HINT =
  /(?:^|[./-])prod(?:uction)?(?:[./-]|$)|prod-api|api\.prod|amazonaws\.com\/prod/i;
const NONPROD_HINT =
  /stage|staging|sandbox|localhost|127\.0\.0\.1|\.dev\.|devbox|preview/i;

/**
 * Resolve Tidewave MCP URL.
 * Order: explicit → DEVIDE_TIDEWAVE_MCP_URL → <appBase>/tidewave/mcp
 */
export function resolveTidewaveUrl({ base, explicit } = {}) {
  if (explicit && String(explicit).trim()) return normalizeMcpUrl(explicit);
  const env = process.env.DEVIDE_TIDEWAVE_MCP_URL;
  if (env && env.trim()) return normalizeMcpUrl(env);
  if (base && String(base).trim()) {
    try {
      const u = new URL(base);
      return `${u.protocol}//${u.host}/tidewave/mcp`;
    } catch {
      /* ignore */
    }
  }
  return null;
}

export function normalizeMcpUrl(url) {
  const base = String(url).trim().replace(/\/$/, "");
  if (base.endsWith("/tidewave/mcp")) return base;
  if (base.endsWith("/tidewave")) return `${base}/mcp`;
  return `${base}/tidewave/mcp`;
}

function httpJson(url, body, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    let u;
    try {
      u = new URL(url);
    } catch (e) {
      reject(e);
      return;
    }
    const lib = u.protocol === "https:" ? https : http;
    const data = JSON.stringify(body);
    const req = lib.request(
      {
        hostname: u.hostname,
        port: u.port || (u.protocol === "https:" ? 443 : 80),
        path: u.pathname + u.search,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json, text/event-stream",
          "Content-Length": Buffer.byteLength(data),
        },
        timeout: timeoutMs,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          // plain JSON or last SSE data: line
          let obj = null;
          try {
            obj = JSON.parse(raw);
          } catch {
            for (const line of raw.split("\n")) {
              const t = line.trim();
              if (!t.startsWith("data:")) continue;
              try {
                obj = JSON.parse(t.slice(5).trim());
              } catch {
                /* keep scanning */
              }
            }
          }
          if (!obj) {
            reject(new Error(`non-json tidewave response (${res.statusCode}): ${raw.slice(0, 200)}`));
            return;
          }
          resolve({ status: res.statusCode, body: obj });
        });
      },
    );
    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("tidewave request timeout"));
    });
    req.write(data);
    req.end();
  });
}

let _rpcId = 1;

/** Call a Tidewave MCP tool; returns parsed text content or throws. */
export async function tidewaveCall(mcpUrl, name, args = {}) {
  const id = _rpcId++;
  const { body } = await httpJson(mcpUrl, {
    jsonrpc: "2.0",
    id,
    method: "tools/call",
    params: { name, arguments: args },
  });
  if (body.error) {
    const msg = body.error.message || JSON.stringify(body.error);
    throw new Error(`tidewave ${name}: ${msg}`);
  }
  const content = body.result?.content;
  if (Array.isArray(content)) {
    return content
      .map((c) => (c && c.type === "text" ? c.text : ""))
      .filter(Boolean)
      .join("\n");
  }
  if (body.result?.structuredContent != null) {
    return JSON.stringify(body.result.structuredContent);
  }
  return "";
}

/**
 * project_eval returns Elixir values as text — often a JSON-encoded string
 * wrapped once more by the tool. Peel JSON layers until we get an object/array
 * or a bare scalar.
 */
export function parseEvalJson(text) {
  let v = String(text ?? "").trim();
  if (!v) return null;
  for (let i = 0; i < 4; i++) {
    try {
      const p = JSON.parse(v);
      if (p !== null && typeof p === "object") return p;
      if (typeof p === "string") {
        v = p;
        continue;
      }
      return p;
    } catch {
      break;
    }
  }
  return v;
}

/** Probe Tidewave; returns { ok, url, error?, server? }. */
export async function probeTidewave(mcpUrl) {
  if (!mcpUrl) return { ok: false, url: null, error: "no_tidewave_url" };
  try {
    // tools/list is enough to prove the MCP is alive
    const { body } = await httpJson(mcpUrl, {
      jsonrpc: "2.0",
      id: _rpcId++,
      method: "tools/list",
      params: {},
    });
    if (body.error) {
      return { ok: false, url: mcpUrl, error: body.error.message || "tools/list error" };
    }
    const tools = body.result?.tools || [];
    const names = tools.map((t) => t.name).filter(Boolean);
    if (!names.includes("get_logs")) {
      return {
        ok: false,
        url: mcpUrl,
        error: "get_logs_missing",
        tools: names,
      };
    }
    return {
      ok: true,
      url: mcpUrl,
      tools: names,
      server: body.result?.serverInfo || null,
    };
  } catch (e) {
    return { ok: false, url: mcpUrl, error: String(e.message || e) };
  }
}

/**
 * Fetch recent logs for one or more levels.
 * Returns { levels: { error: { count, samples, lines }, ... }, raw_count }
 *
 * IMPORTANT: Tidewave get_logs returns a *cumulative* ring buffer tail, not a
 * per-request delta. Callers must use `deltaLines` + a cursor so one sticky
 * error does not fail every subsequent page.
 */
export async function fetchLogs(mcpUrl, levels = ["error"], tail = 80) {
  const out = { levels: {}, raw_count: 0 };
  for (const level of levels) {
    try {
      const text = await tidewaveCall(mcpUrl, "get_logs", { tail, level });
      const lines = String(text || "")
        .split("\n")
        .map((l) => l.trim())
        .filter(Boolean);
      out.levels[level] = {
        count: lines.length,
        samples: lines.slice(-5),
        lines,
      };
      out.raw_count += lines.length;
    } catch (e) {
      out.levels[level] = {
        count: null,
        error: String(e.message || e),
        samples: [],
        lines: [],
      };
    }
  }
  return out;
}

/**
 * Lines that appeared after the previous tail snapshot.
 * Uses the last line of `prev` as a cursor inside `next` (lastIndexOf).
 */
export function deltaLines(prev, next) {
  const a = Array.isArray(prev) ? prev : [];
  const b = Array.isArray(next) ? next : [];
  if (!b.length) return [];
  if (!a.length) return b.slice();
  const marker = a[a.length - 1];
  const idx = b.lastIndexOf(marker);
  if (idx === -1) return b.slice(); // rotated or first sample
  return b.slice(idx + 1);
}

/** Redact secrets in env values for the report. */
export function redactEnvValue(v) {
  if (v == null || v === "") return null;
  const s = String(v);
  // URLs: keep host, drop query/userinfo
  try {
    const u = new URL(s);
    return `${u.protocol}//${u.host}${u.pathname === "/" ? "" : u.pathname}`;
  } catch {
    /* not a URL */
  }
  // Hostnames / short tokens — show as-is
  if (s.length <= 48 && /^[A-Za-z0-9._:-]+$/.test(s)) return s;
  if (s.length <= 12) return s;
  return `${s.slice(0, 6)}…${s.slice(-4)}`;
}

export function classifyRisk(value) {
  if (value == null || value === "") return "unset";
  const s = String(value);
  // Explicit non-prod hostnames win (stage-one-api.onemilc.com is not prod).
  if (NONPROD_HINT.test(s)) return "ok";
  if (PROD_HINT.test(s)) return "prod_like";
  // Bare onemilc.com without stage/dev still treated as prod-like.
  if (/\.onemilc\.com\b/i.test(s)) return "prod_like";
  return "ok";
}

/**
 * Build env_check strip.
 * Prefer Tidewave project_eval to read the *app* environment when available.
 */
export async function envCheckStrip(keys, { mcpUrl, tidewaveOk } = {}) {
  const list = Array.isArray(keys) ? keys.filter(Boolean) : [];
  if (!list.length) return { source: "none", items: [] };

  if (tidewaveOk && mcpUrl) {
    try {
      // Read env vars inside the BEAM app (not the agent host).
      const code =
        "keys = " +
        JSON.stringify(list) +
        "; map = Map.new(keys, fn k -> {k, System.get_env(k)} end); Jason.encode!(map)";
      const text = await tidewaveCall(mcpUrl, "project_eval", { code, timeout: 10000 });
      const map = parseEvalJson(text) || {};
      const items = list.map((key) => {
        const value = map[key] ?? null;
        return {
          key,
          present: value != null && value !== "",
          risk: classifyRisk(value),
          preview: redactEnvValue(value),
        };
      });
      return { source: "tidewave_project_eval", items };
    } catch (e) {
      return {
        source: "tidewave_failed",
        error: String(e.message || e),
        items: list.map((key) => hostEnvItem(key)),
      };
    }
  }

  return {
    source: "agent_process_env",
    items: list.map((key) => hostEnvItem(key)),
  };
}

function hostEnvItem(key) {
  const value = process.env[key];
  return {
    key,
    present: value != null && value !== "",
    risk: classifyRisk(value),
    preview: redactEnvValue(value),
  };
}

/** Best-effort app identity via Tidewave. */
export async function appIdentity(mcpUrl) {
  if (!mcpUrl) return null;
  try {
    const code = `
      cwd = File.cwd!()
      sha =
        case System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: cwd, stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end
      Jason.encode!(%{
        "cwd" => cwd,
        "git_sha" => sha,
        "mix_env" => System.get_env("MIX_ENV"),
        "phx_host" => System.get_env("PHX_HOST")
      })
    `;
    const text = await tidewaveCall(mcpUrl, "project_eval", { code, timeout: 10000 });
    const parsed = parseEvalJson(text);
    if (parsed && typeof parsed === "object") return parsed;
    return { raw: String(text).slice(0, 200) };
  } catch (e) {
    return { error: String(e.message || e) };
  }
}

/**
 * Run priority-1 runtime setup for a walk.
 * Returns a runtime bag attached to results.json / report.
 */
export async function beginRuntime(manifest, { base, tidewaveUrl } = {}) {
  const rt = manifest.runtime || {};
  const want = rt.tidewave === true;
  const requireTw = rt.require_tidewave === true;
  const logLevels = Array.isArray(rt.log_levels) && rt.log_levels.length
    ? rt.log_levels
    : ["error"];

  const bag = {
    requested: want,
    require_tidewave: requireTw,
    log_levels: logLevels,
    tidewave: { status: "disabled", url: null },
    env_check: { source: "none", items: [] },
    app: null,
    error_log_total: 0,
    // Per-level cursor: last seen log line text (for deltaLines).
    _log_cursors: {},
  };

  if (!want) return bag;

  const url = resolveTidewaveUrl({ base, explicit: tidewaveUrl });
  const probe = await probeTidewave(url);
  if (!probe.ok) {
    bag.tidewave = {
      status: "skipped",
      reason: "tidewave_unavailable",
      url: probe.url,
      error: probe.error,
    };
    // Still try host env_check as a weak signal
    bag.env_check = await envCheckStrip(manifest.safety?.env_check, {
      tidewaveOk: false,
    });
    if (requireTw) {
      bag.fatal = `runtime.require_tidewave but Tidewave unavailable: ${probe.error}`;
    }
    return bag;
  }

  bag.tidewave = {
    status: "ok",
    url: probe.url,
    tools: probe.tools,
    server: probe.server,
  };
  bag.env_check = await envCheckStrip(manifest.safety?.env_check, {
    mcpUrl: probe.url,
    tidewaveOk: true,
  });
  bag.app = await appIdentity(probe.url);

  // Baseline cursors so pre-walk noise does not fail page 1.
  try {
    const baseline = await fetchLogs(probe.url, logLevels, 80);
    for (const [level, entry] of Object.entries(baseline.levels || {})) {
      const lines = entry.lines || [];
      bag._log_cursors[level] = lines.length ? lines[lines.length - 1] : null;
    }
  } catch {
    /* empty cursors → first page treats full tail as delta (acceptable) */
  }

  return bag;
}

/** Per-page log *delta* after navigate (not cumulative ring-buffer size). */
export async function pageRuntimeLogs(runtimeBag, pageName) {
  if (!runtimeBag || runtimeBag.tidewave?.status !== "ok") {
    return {
      status: runtimeBag?.tidewave?.status || "disabled",
      reason: runtimeBag?.tidewave?.reason || null,
    };
  }
  const levels = runtimeBag.log_levels || ["error"];
  const logs = await fetchLogs(runtimeBag.tidewave.url, levels, 80);
  const delta = { levels: {}, raw_count: 0 };
  let errorCount = 0;

  for (const level of levels) {
    const entry = logs.levels[level] || { lines: [], samples: [] };
    const prevMarker = runtimeBag._log_cursors?.[level];
    const prev = prevMarker != null ? [prevMarker] : [];
    const newLines = deltaLines(prev, entry.lines || []);
    // Advance cursor to end of current tail
    const all = entry.lines || [];
    if (all.length) {
      runtimeBag._log_cursors = runtimeBag._log_cursors || {};
      runtimeBag._log_cursors[level] = all[all.length - 1];
    }
    delta.levels[level] = {
      count: newLines.length,
      samples: newLines.slice(-5),
      // omit full lines from report payload — samples only
    };
    delta.raw_count += newLines.length;
    if (level === "error") errorCount = newLines.length;
  }

  runtimeBag.error_log_total = (runtimeBag.error_log_total || 0) + errorCount;
  return {
    status: "ok",
    page: pageName,
    logs: delta,
    error_log_count: errorCount,
    // cumulative tail sizes kept for debugging only
    tail_sizes: Object.fromEntries(
      Object.entries(logs.levels || {}).map(([k, v]) => [k, v.count]),
    ),
  };
}
