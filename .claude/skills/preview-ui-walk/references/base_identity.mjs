// Prove --base points at the app you meant to walk.
//
// Preview ports are ephemeral and RECYCLED: 41000..41049 for preview envs and
// 41050..41079 for runtime-owned servers are handed out from a pool. A manifest
// or run-book that hardcodes `--base http://127.0.0.1:<port>` therefore has two
// failure modes, and only one of them is loud:
//
//   nothing listening  -> connection refused, obvious
//   SOMEONE ELSE'S app -> the walk navigates, asserts, screenshots and
//                         publishes a confident report about the wrong
//                         application
//
// The second is the false green this whole engine exists to prevent, arriving
// through the base URL rather than through a page. A walk cannot detect it by
// looking at pages: a different app's 200s look exactly like the right app's.
// The only defence is asking the target to identify itself BEFORE walking.
//
// Failing this check is BLOCKED, never FAILED: we never reached the app under
// test, so nothing about it was proved.

/** Read a possibly-dotted key path out of a parsed body. */
export function readPath(obj, path) {
  return String(path).split(".").reduce((acc, key) => {
    if (acc == null || typeof acc !== "object") return undefined;
    return acc[key];
  }, obj);
}

/**
 * Compare one expectation. Values are compared as strings so a health endpoint
 * answering 3 and "3" agree — the question is identity, not typing.
 */
function matches(actual, expected) {
  if (actual === undefined) return false;
  if (expected === null) return actual === null;
  return String(actual) === String(expected);
}

/**
 * Judge a base-identity probe.
 *
 * @param spec    manifest `base_identity` block
 * @param probe   { ok, status, body, error }
 * @returns { pass, reason, checked }
 */
export function identityVerdict(spec, probe = {}) {
  if (!spec) return { pass: true, reason: null, checked: [] };

  const min = Number.isInteger(spec.min_status) ? spec.min_status : 200;
  const max = Number.isInteger(spec.max_status) ? spec.max_status : 299;

  if (probe.error) {
    return {
      pass: false,
      reason: `base did not answer ${spec.path || "/health"}: ${probe.error}`,
      checked: [],
    };
  }
  if (!Number.isInteger(probe.status)) {
    return { pass: false, reason: "base identity probe returned no status", checked: [] };
  }
  if (probe.status < min || probe.status > max) {
    return {
      pass: false,
      reason: `base answered ${probe.status} at ${spec.path || "/health"} (want ${min}..${max})`,
      checked: [],
    };
  }

  const body = String(probe.body ?? "");

  if (spec.expect_text != null && !body.includes(String(spec.expect_text))) {
    return {
      pass: false,
      reason: `base identity text not found: ${String(spec.expect_text).slice(0, 80)}`,
      checked: [],
    };
  }

  const expect = spec.expect && typeof spec.expect === "object" ? spec.expect : null;
  if (!expect || Object.keys(expect).length === 0) {
    return { pass: true, reason: null, checked: spec.expect_text != null ? ["expect_text"] : [] };
  }

  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return {
      pass: false,
      reason: `base identity body is not JSON, cannot check ${Object.keys(expect).join(", ")}`,
      checked: [],
    };
  }

  const checked = [];
  for (const [key, want] of Object.entries(expect)) {
    const got = readPath(parsed, key);
    checked.push(key);
    if (!matches(got, want)) {
      // Name both sides: "wrong app" and "right app, wrong build" are different
      // problems and the operator must not have to guess which one this is.
      return {
        pass: false,
        reason:
          `base identity mismatch: ${key} is ${JSON.stringify(got ?? null)}, ` +
          `expected ${JSON.stringify(want)} — --base may point at a different app ` +
          `(preview ports are recycled)`,
        checked,
      };
    }
  }

  return { pass: true, reason: null, checked };
}

/**
 * Perform the probe. Kept separate from the verdict so the judgement stays pure
 * and testable without a server.
 */
export async function probeBaseIdentity(base, spec, { fetchImpl = fetch, timeoutMs = 8000 } = {}) {
  if (!spec) return { ok: true, status: null, body: "", error: null };
  const path = spec.path || "/health";
  let url;
  try {
    url = new URL(path, base).toString();
  } catch (err) {
    return { ok: false, status: null, body: "", error: `bad base/path: ${String(err?.message || err)}` };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { signal: controller.signal, redirect: "follow" });
    const body = await res.text().catch(() => "");
    return { ok: true, status: res.status, body, error: null };
  } catch (err) {
    const msg = String(err?.message || err);
    return {
      ok: false,
      status: null,
      body: "",
      error: msg.includes("abort") ? `timed out after ${timeoutMs}ms` : msg,
    };
  } finally {
    clearTimeout(timer);
  }
}
