// Runtime evidence for preview-ui-walk (Tidewave MCP):
//   - availability + env_check strip + app identity
//   - per-page get_logs deltas (error/warning/…)
//   - walk/page project_eval probes (allowlisted in the manifest)
//   - per-page SELECT-only SQL (via execute_sql_query)
//   - LiveView assign *keys* (+ optional small non-PII fields)
//
// Never mutates. When Tidewave is unreachable, callers mark
// skipped: tidewave_unavailable and keep the browser walk green/red on its own.

import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

// Host/path patterns that look like production write targets.
// Stage/sandbox/dev are intentionally NOT prod_like (still surfaced in preview).
const PROD_HINT =
  /(?:^|[./-])prod(?:uction)?(?:[./-]|$)|prod-api|api\.prod|amazonaws\.com\/prod/i;
const NONPROD_HINT =
  /stage|staging|sandbox|localhost|127\.0\.0\.1|\.dev\.|devbox|preview/i;

const SQL_SELECT_RE = /^\s*select\b/i;
const MAX_SQL_ROWS = 50;
const MAX_PROBE_CODE = 2000;

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
export async function tidewaveCall(mcpUrl, name, args = {}, timeoutMs = 15000) {
  const id = _rpcId++;
  const { body } = await httpJson(
    mcpUrl,
    {
      jsonrpc: "2.0",
      id,
      method: "tools/call",
      params: { name, arguments: args },
    },
    timeoutMs,
  );
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
 * or a bare scalar. Also strips Tidewave's "IO:\n…\nResult:\n…" envelope.
 */
export function parseEvalJson(text) {
  let v = String(text ?? "").trim();
  if (!v) return null;

  // Tidewave often wraps as: IO:\n...\n\nResult:\n"<json>"
  const resultIdx = v.search(/\nResult:\s*\n/i);
  if (resultIdx >= 0) {
    v = v.slice(resultIdx).replace(/^\n?Result:\s*\n/i, "").trim();
  }

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
  // bare atom-ish tokens
  if (v === "nil" || v === ":nil") return null;
  if (v === "true" || v === ":true") return true;
  if (v === "false" || v === ":false") return false;
  if (/^:\w+$/.test(v)) return v.slice(1);
  if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  return v;
}

/** Normalize probe/SQL expect comparisons (atoms, strings, numbers). */
export function valuesMatch(actual, expect) {
  if (expect === undefined) return true;
  if (actual === expect) return true;
  if (actual == null && expect == null) return true;
  // stringified equality after peeling atoms
  const a = normalizeScalar(actual);
  const e = normalizeScalar(expect);
  if (a === e) return true;
  if (typeof a === "number" && typeof e === "number" && Number.isFinite(a) && Number.isFinite(e)) {
    return a === e;
  }
  return String(a) === String(e);
}

function normalizeScalar(v) {
  if (v == null) return null;
  if (typeof v === "string") {
    const t = v.trim();
    if (t.startsWith(":") && t.length > 1) return t.slice(1);
    if (t === "nil") return null;
    if (t === "true") return true;
    if (t === "false") return false;
    if (/^-?\d+$/.test(t)) return Number(t);
    // quoted elixir/json string
    if (
      (t.startsWith('"') && t.endsWith('"')) ||
      (t.startsWith("'") && t.endsWith("'"))
    ) {
      return t.slice(1, -1);
    }
    return t;
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

// ─── Probes / SQL / LiveView ────────────────────────────────────────────────

/** Guard: reject free-form eval that looks mutating. Soft heuristics only. */
export function probeLooksUnsafe(code) {
  const s = String(code || "");
  if (s.length > MAX_PROBE_CODE) return "probe_code_too_long";
  // Common mutation verbs — walk is read-only.
  if (
    /\b(Repo\.(insert|update|delete|insert!|update!|delete!)|File\.(write|rm|rm_rf)|System\.(cmd|shell)|:os\.cmd|Mix\.Task\.run)\b/.test(
      s,
    )
  ) {
    return "probe_looks_mutating";
  }
  return null;
}

export function assertSelectOnly(sql) {
  const q = String(sql || "").trim();
  if (!q) return { ok: false, error: "empty_sql" };
  if (!SQL_SELECT_RE.test(q)) return { ok: false, error: "sql_must_be_select" };
  // Block multi-statement / sneaky writes
  if (/;\s*\S/.test(q)) return { ok: false, error: "sql_multi_statement" };
  if (/\b(insert|update|delete|drop|alter|truncate|create|grant|revoke)\b/i.test(q)) {
    return { ok: false, error: "sql_non_select_keyword" };
  }
  return { ok: true, query: q };
}

/**
 * Parse Tidewave execute_sql_query text (usually inspect(%Postgrex.Result{})).
 * Good enough for expect / expect_min on single-cell aggregates.
 */
export function parseSqlResult(text) {
  const s = String(text ?? "");
  if (!s.trim()) return { error: "empty_sql_result" };
  if (/\b(error|exception|\*\*)\b/i.test(s) && !/Postgrex\.Result|num_rows/.test(s)) {
    return { error: s.slice(0, 400) };
  }
  const numRows = Number(s.match(/num_rows:\s*(\d+)/)?.[1] ?? NaN);
  const colsMatch = s.match(/columns:\s*\[([^\]]*)\]/);
  const columns = colsMatch
    ? colsMatch[1]
        .split(",")
        .map((c) => c.trim().replace(/^"|"$/g, "").replace(/^'|'$/g, ""))
        .filter(Boolean)
    : [];

  // rows: [[1], [2]] or [[nil]] — take first cell of first row as scalar
  let scalar = null;
  const rowsBlock = s.match(/rows:\s*(\[[\s\S]*?\])\s*,\s*num_rows/);
  if (rowsBlock) {
    const firstCell = rowsBlock[1].match(/\[\s*\[\s*([^,\]]+?)\s*(?:,|\])/);
    if (firstCell) scalar = normalizeScalar(firstCell[1].trim());
  }

  return {
    num_rows: Number.isFinite(numRows) ? numRows : null,
    columns,
    scalar,
    raw: s.slice(0, 600),
  };
}

/** Run one allowlisted project_eval probe. */
export async function runProbe(mcpUrl, probe) {
  const name = probe?.name || "unnamed";
  const code = probe?.eval;
  if (!code) {
    return { name, status: "FAIL", error: "missing_eval" };
  }
  const unsafe = probeLooksUnsafe(code);
  if (unsafe) {
    return { name, status: "FAIL", error: unsafe };
  }
  try {
    const text = await tidewaveCall(
      mcpUrl,
      "project_eval",
      { code, timeout: 15000 },
      20000,
    );
    const value = parseEvalJson(text);
    const hasExpect = Object.prototype.hasOwnProperty.call(probe, "expect");
    const ok = !hasExpect || valuesMatch(value, probe.expect);
    return {
      name,
      status: ok ? "PASS" : "FAIL",
      value: summarizeValue(value),
      expect: hasExpect ? probe.expect : undefined,
      error: ok ? undefined : "expect_mismatch",
      note: probe.note,
    };
  } catch (e) {
    return { name, status: "FAIL", error: String(e.message || e) };
  }
}

function summarizeValue(v) {
  if (v == null) return null;
  if (typeof v === "string") return v.length > 200 ? `${v.slice(0, 200)}…` : v;
  if (typeof v === "number" || typeof v === "boolean") return v;
  try {
    const s = JSON.stringify(v);
    return s.length > 240 ? `${s.slice(0, 240)}…` : JSON.parse(s);
  } catch {
    return String(v).slice(0, 200);
  }
}

/** Run SELECT-only SQL for a page runtime block. */
export async function runSql(mcpUrl, pageRt = {}) {
  if (!pageRt.sql) return null;
  const gate = assertSelectOnly(pageRt.sql);
  if (!gate.ok) {
    return { status: "FAIL", error: gate.error, query: String(pageRt.sql).slice(0, 120) };
  }
  try {
    const text = await tidewaveCall(
      mcpUrl,
      "execute_sql_query",
      { query: gate.query },
      20000,
    );
    const parsed = parseSqlResult(text);
    if (parsed.error && parsed.num_rows == null && parsed.scalar == null) {
      return {
        status: "FAIL",
        error: parsed.error,
        query: gate.query.slice(0, 120),
      };
    }

    let status = "PASS";
    let error;
    if (Object.prototype.hasOwnProperty.call(pageRt, "expect")) {
      if (!valuesMatch(parsed.scalar, pageRt.expect)) {
        status = "FAIL";
        error = `expect ${JSON.stringify(pageRt.expect)} got ${JSON.stringify(parsed.scalar)}`;
      }
    }
    if (status === "PASS" && pageRt.expect_min != null) {
      const n = Number(parsed.scalar);
      if (!Number.isFinite(n) || n < Number(pageRt.expect_min)) {
        status = "FAIL";
        error = `expect_min ${pageRt.expect_min} got ${JSON.stringify(parsed.scalar)}`;
      }
    }
    // Cap what we surface
    return {
      status,
      error,
      query: gate.query.slice(0, 160),
      num_rows: parsed.num_rows,
      columns: (parsed.columns || []).slice(0, 12),
      scalar: parsed.scalar,
    };
  } catch (e) {
    return {
      status: "FAIL",
      error: String(e.message || e),
      query: gate.query.slice(0, 120),
    };
  }
}

/**
 * Capture LiveView evidence: view modules + assign *keys* only.
 * Optional `fields` pull small non-PII facts via a safe path walker.
 */
export async function captureLiveViews(mcpUrl, policy = {}, { pathHint } = {}) {
  if (policy && policy.enabled === false) {
    return { status: "disabled" };
  }
  const wantKeys = policy?.assign_keys !== false;
  const fields = Array.isArray(policy?.fields) ? policy.fields.slice(0, 12) : [];
  const fieldsJson = JSON.stringify(fields);
  const pathJson = JSON.stringify(pathHint || null);

  // :sys.get_state is more reliable than Debug.socket across LV versions.
  // Never encode PIDs or full assign maps — keys + optional allowlisted fields only.
  const code = `
    path_hint = ${pathJson}
    fields = ${fieldsJson}
    want_keys = ${wantKeys}

    get_in_assign = fn assigns, path ->
      parts = path |> to_string() |> String.split(".", trim: true)
      Enum.reduce_while(parts, assigns, fn part, acc ->
        atom_key =
          try do
            String.to_existing_atom(part)
          rescue
            ArgumentError -> nil
          end

        key =
          cond do
            is_map(acc) and Map.has_key?(acc, part) -> part
            atom_key != nil and is_map(acc) and Map.has_key?(acc, atom_key) -> atom_key
            true -> :__missing__
          end

        cond do
          key == :__missing__ -> {:halt, :__missing__}
          is_map(acc) -> {:cont, Map.get(acc, key)}
          is_struct(acc) ->
            try do
              {:cont, Map.get(acc, key)}
            rescue
              _ -> {:halt, :__missing__}
            end
          true -> {:halt, :__missing__}
        end
      end)
    end

    redact = fn v ->
      cond do
        is_nil(v) -> nil
        is_boolean(v) or is_number(v) or is_atom(v) -> v
        is_binary(v) ->
          cond do
            String.contains?(v, "@") and String.length(v) < 120 -> "[redacted-email]"
            String.length(v) > 80 -> String.slice(v, 0, 40) <> "…"
            true -> v
          end
        true ->
          s = inspect(v, limit: 3)
          if String.length(s) > 80, do: String.slice(s, 0, 80) <> "…", else: s
      end
    end

    liveviews =
      try do
        if Code.ensure_loaded?(Phoenix.LiveView.Debug) and
             function_exported?(Phoenix.LiveView.Debug, :list_liveviews, 0) do
          Phoenix.LiveView.Debug.list_liveviews()
        else
          []
        end
      rescue
        _ -> []
      end

    rows =
      Enum.map(liveviews, fn meta ->
        pid = Map.get(meta, :pid)
        view = Map.get(meta, :view) || Map.get(meta, :module)
        topic = Map.get(meta, :topic)

        assigns =
          try do
            case :sys.get_state(pid) do
              %{socket: %Phoenix.LiveView.Socket{assigns: a}} -> a
              %Phoenix.LiveView.Socket{assigns: a} -> a
              _ -> %{}
            end
          rescue
            _ -> %{}
          catch
            _, _ -> %{}
          end

        keys =
          if want_keys do
            assigns
            |> Map.delete(:__changed__)
            |> Map.keys()
            |> Enum.map(&to_string/1)
            |> Enum.sort()
          else
            []
          end

        field_map =
          for f <- fields, into: %{} do
            val = get_in_assign.(assigns, f)
            {to_string(f), if(val == :__missing__, do: nil, else: redact.(val))}
          end

        current_path =
          case get_in_assign.(assigns, "current_path") do
            :__missing__ -> nil
            p -> to_string(p)
          end

        %{
          "view" => inspect(view),
          "topic" => to_string(topic || ""),
          "assign_keys" => keys,
          "fields" => field_map,
          "current_path" => current_path
        }
      end)

    # Prefer LiveViews whose current_path matches the page we just opened.
    ranked =
      case path_hint do
        nil -> rows
        hint when is_binary(hint) ->
          {match, rest} =
            Enum.split_with(rows, fn r ->
              cp = r["current_path"]
              is_binary(cp) and (String.contains?(cp, hint) or String.contains?(hint, cp))
            end)
          match ++ rest
        _ -> rows
      end

    Jason.encode!(%{
      "status" => "ok",
      "count" => length(ranked),
      "liveviews" => Enum.take(ranked, 8)
    })
  `;

  try {
    const text = await tidewaveCall(
      mcpUrl,
      "project_eval",
      { code, timeout: 15000 },
      20000,
    );
    const parsed = parseEvalJson(text);
    if (parsed && typeof parsed === "object") {
      return {
        status: parsed.status || "ok",
        count: parsed.count ?? (parsed.liveviews || []).length,
        liveviews: Array.isArray(parsed.liveviews) ? parsed.liveviews : [],
      };
    }
    return { status: "error", error: "unparseable_liveview_snapshot", raw: String(text).slice(0, 200) };
  } catch (e) {
    return { status: "error", error: String(e.message || e) };
  }
}

/** Merge walk-level runtime.per_page[name] with page.runtime. */
export function mergePageRuntime(manifest, page) {
  const walk = manifest?.runtime || {};
  const fromMap = (walk.per_page && walk.per_page[page.name]) || {};
  const fromPage = page.runtime || {};
  return {
    probes: []
      .concat(fromMap.probes || [])
      .concat(fromPage.probes || []),
    sql: fromPage.sql ?? fromMap.sql,
    expect: fromPage.expect ?? fromMap.expect,
    expect_min: fromPage.expect_min ?? fromMap.expect_min,
    liveview: fromPage.liveview ?? fromMap.liveview,
    log_levels: fromPage.log_levels || fromMap.log_levels,
  };
}

function defaultLiveviewPolicy(manifest, pageRt) {
  const walk = manifest?.runtime?.liveview;
  const page = pageRt?.liveview;
  if (page && typeof page === "object") {
    return {
      enabled: page.enabled !== false,
      assign_keys: page.assign_keys !== false,
      fields: page.fields || walk?.fields || [],
    };
  }
  if (walk && typeof walk === "object") {
    return {
      enabled: walk.enabled !== false,
      assign_keys: walk.assign_keys !== false,
      fields: walk.fields || [],
    };
  }
  // If runtime.tidewave is on but liveview omitted, still capture keys (cheap, useful).
  return { enabled: true, assign_keys: true, fields: [] };
}

/**
 * Run priority-1+ runtime setup for a walk.
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
    probes: [],
    probes_failed: 0,
    // Per-level cursor: last seen log line text (for deltaLines).
    _log_cursors: {},
    _manifest: manifest,
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

  // Walk-level probes once at start (auth role, feature flags, …).
  const walkProbes = Array.isArray(rt.probes) ? rt.probes : [];
  if (walkProbes.length) {
    bag.probes = [];
    for (const p of walkProbes) {
      // eslint-disable-next-line no-await-in-loop
      const result = await runProbe(probe.url, p);
      bag.probes.push(result);
    }
    bag.probes_failed = bag.probes.filter((p) => p.status !== "PASS").length;
  }

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
export async function pageRuntimeLogs(runtimeBag, pageName, logLevels) {
  if (!runtimeBag || runtimeBag.tidewave?.status !== "ok") {
    return {
      status: runtimeBag?.tidewave?.status || "disabled",
      reason: runtimeBag?.tidewave?.reason || null,
    };
  }
  const levels = logLevels || runtimeBag.log_levels || ["error"];
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

/**
 * Full per-page runtime packet: logs + page probes + sql + liveview.
 * Safe to call when Tidewave is down — returns skipped status.
 */
export async function pageRuntimeEvidence(runtimeBag, page, manifest) {
  const pageRt = mergePageRuntime(manifest || runtimeBag?._manifest || {}, page);
  const levels = pageRt.log_levels || runtimeBag?.log_levels || ["error"];

  if (!runtimeBag || runtimeBag.tidewave?.status !== "ok") {
    return {
      status: runtimeBag?.tidewave?.status || "disabled",
      reason: runtimeBag?.tidewave?.reason || null,
      page: page.name,
    };
  }

  const logsPart = await pageRuntimeLogs(runtimeBag, page.name, levels);
  const mcpUrl = runtimeBag.tidewave.url;

  // Page-level probes
  const probes = [];
  for (const p of pageRt.probes || []) {
    // eslint-disable-next-line no-await-in-loop
    probes.push(await runProbe(mcpUrl, p));
  }

  const sql = await runSql(mcpUrl, pageRt);

  const lvPolicy = defaultLiveviewPolicy(manifest || runtimeBag._manifest, pageRt);
  let liveview = { status: "disabled" };
  if (lvPolicy.enabled) {
    liveview = await captureLiveViews(mcpUrl, lvPolicy, {
      pathHint: page.lands_on || page.path,
    });
  }

  const probesFailed = probes.filter((p) => p.status !== "PASS").length;
  const sqlFailed = sql && sql.status === "FAIL" ? 1 : 0;

  return {
    ...logsPart,
    probes,
    probes_failed: probesFailed,
    sql,
    liveview,
    evidence_failed: probesFailed + sqlFailed,
  };
}

/** True when env_check found any prod_like key. */
export function hasProdLikeEnv(runtimeBag) {
  return (runtimeBag?.env_check?.items || []).some((i) => i.risk === "prod_like");
}
