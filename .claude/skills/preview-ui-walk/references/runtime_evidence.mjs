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

const PROD_HINT =
  /onemilc\.com|amazonaws\.com\/prod|\.prod\.|production|prod-api|api\.prod/i;

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
 * Returns { levels: { error: { count, samples }, ... }, raw_count }
 */
export async function fetchLogs(mcpUrl, levels = ["error"], tail = 40) {
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
      };
      out.raw_count += lines.length;
    } catch (e) {
      out.levels[level] = {
        count: null,
        error: String(e.message || e),
        samples: [],
      };
    }
  }
  return out;
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

function classifyRisk(value) {
  if (value == null || value === "") return "unset";
  if (PROD_HINT.test(String(value))) return "prod_like";
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
  return bag;
}

/** Per-page log snapshot after navigate. */
export async function pageRuntimeLogs(runtimeBag, pageName) {
  if (!runtimeBag || runtimeBag.tidewave?.status !== "ok") {
    return {
      status: runtimeBag?.tidewave?.status || "disabled",
      reason: runtimeBag?.tidewave?.reason || null,
    };
  }
  const levels = runtimeBag.log_levels || ["error"];
  const logs = await fetchLogs(runtimeBag.tidewave.url, levels, 40);
  const errorCount = logs.levels.error?.count || 0;
  runtimeBag.error_log_total = (runtimeBag.error_log_total || 0) + (errorCount || 0);
  return {
    status: "ok",
    page: pageName,
    logs,
    error_log_count: errorCount,
  };
}
