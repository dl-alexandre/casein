// Manifest validation against the committed JSON Schema — at preflight, not by
// hand.
//
// Why this exists: `additionalProperties: false` already describes every legal
// key, but nothing ran the schema at run time. A misspelled key ("step" for
// "steps", "cleanup_step" for "cleanup_steps") therefore produced a walk that
// navigated, asserted NOTHING, cleaned up nothing — and reported PASS. A
// manifest that proves nothing reporting green is the exact failure this suite
// exists to prevent, and actions[] added ~15 more keys to mistype.
//
// Deliberately dependency-free: the schema ships beside the drivers, and adding
// a validator dependency would put walks behind an npm install on a box that
// may have none. This supports the subset of draft-07 the schema actually uses.
//
// DESIGN RULE: never reject a valid manifest. Any keyword this does not
// understand is SKIPPED rather than failed — a false "invalid" would block a
// working walk, which is worse than the typo it was trying to catch.

const SUPPORTED = new Set([
  "type", "properties", "additionalProperties", "required", "enum", "const",
  "items", "minItems", "maxItems", "uniqueItems", "minProperties",
  "minLength", "maxLength", "pattern", "minimum", "maximum",
  "$ref", "oneOf", "anyOf", "allOf", "propertyNames", "default",
  "if", "then", "else", "not",
  "description", "deprecated", "title", "$schema", "$id", "definitions",
  "x-driver",
]);

// Keyword positions, so the scanner below can tell a KEYWORD from a property
// NAME. Without this distinction every property in the schema reads as an
// unsupported keyword and the drift signal is pure noise.
const SCHEMA_MAP_KEYWORDS = new Set(["properties", "definitions", "patternProperties"]);
const SCHEMA_KEYWORDS = new Set([
  "items", "additionalProperties", "propertyNames", "not", "if", "then", "else",
]);
const SCHEMA_LIST_KEYWORDS = new Set(["allOf", "anyOf", "oneOf"]);

/**
 * Keywords the schema uses that this validator does not implement.
 *
 * Unimplemented keywords make the validator PERMISSIVE (it skips them), never
 * wrong — so this is a drift signal, not an error: if someone adds `if`/`then`
 * to the schema, the selftest says so instead of silently under-validating.
 */
export function unsupportedKeywords(schema) {
  const found = new Set();
  (function scan(node) {
    if (!node || typeof node !== "object" || Array.isArray(node)) return;
    for (const [key, value] of Object.entries(node)) {
      if (SCHEMA_MAP_KEYWORDS.has(key)) {
        // Keys here are names, not keywords; values are schemas.
        for (const sub of Object.values(value || {})) scan(sub);
        continue;
      }
      if (!SUPPORTED.has(key)) found.add(key);
      if (SCHEMA_KEYWORDS.has(key)) {
        scan(value);
      } else if (SCHEMA_LIST_KEYWORDS.has(key)) {
        for (const sub of value || []) scan(sub);
      }
    }
  })(schema);
  return [...found].sort();
}

function resolveRef(root, ref) {
  if (typeof ref !== "string" || !ref.startsWith("#/")) return null;
  let node = root;
  for (const part of ref.slice(2).split("/")) {
    node = node?.[part.replace(/~1/g, "/").replace(/~0/g, "~")];
    if (node == null) return null;
  }
  return node;
}

function typeOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (Number.isInteger(value)) return "integer";
  return typeof value;
}

function typeMatches(value, want) {
  const actual = typeOf(value);
  if (want === "number") return actual === "number" || actual === "integer";
  if (want === "integer") return actual === "integer";
  return actual === want;
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

/**
 * Collect every property name a schema declares for an object, following $ref
 * and allOf. Needed because `page` is a thin allOf wrapper whose properties
 * live in `page_body` — checking additionalProperties without following the
 * ref would reject every legal page key.
 */
function declaredProperties(root, schema, seen = new Set()) {
  const out = new Set();
  if (!schema || typeof schema !== "object") return out;
  if (schema.$ref) {
    if (seen.has(schema.$ref)) return out;
    seen.add(schema.$ref);
    for (const k of declaredProperties(root, resolveRef(root, schema.$ref), seen)) out.add(k);
  }
  for (const k of Object.keys(schema.properties || {})) out.add(k);
  for (const sub of schema.allOf || []) {
    for (const k of declaredProperties(root, sub, seen)) out.add(k);
  }
  return out;
}

/** Does this schema (following $ref/allOf) forbid extra properties? */
function forbidsExtra(root, schema, seen = new Set()) {
  if (!schema || typeof schema !== "object") return false;
  if (schema.additionalProperties === false) return true;
  if (schema.$ref && !seen.has(schema.$ref)) {
    seen.add(schema.$ref);
    if (forbidsExtra(root, resolveRef(root, schema.$ref), seen)) return true;
  }
  return (schema.allOf || []).some((sub) => forbidsExtra(root, sub, seen));
}

function validateNode(root, schema, value, path, errors) {
  if (!schema || typeof schema !== "object") return;

  if (schema.$ref) {
    const target = resolveRef(root, schema.$ref);
    if (target) validateNode(root, target, value, path, errors);
    // Sibling keywords still apply (the page/phase wrappers add `required`).
  }

  if (schema.type) {
    const wanted = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!wanted.some((t) => typeMatches(value, t))) {
      errors.push({ path, message: `expected ${wanted.join(" or ")}, got ${typeOf(value)}` });
      return; // further checks would cascade noise
    }
  }

  if (schema.enum && !schema.enum.some((e) => deepEqual(e, value))) {
    errors.push({ path, message: `must be one of ${JSON.stringify(schema.enum)}` });
  }
  if ("const" in schema && !deepEqual(schema.const, value)) {
    errors.push({ path, message: `must be ${JSON.stringify(schema.const)}` });
  }

  if (typeof value === "string") {
    if (schema.minLength != null && value.length < schema.minLength) {
      errors.push({ path, message: `shorter than ${schema.minLength}` });
    }
    if (schema.pattern) {
      let re = null;
      try {
        re = new RegExp(schema.pattern);
      } catch {
        re = null; // unparseable pattern: skip rather than false-fail
      }
      if (re && !re.test(value)) {
        errors.push({ path, message: `does not match ${schema.pattern}` });
      }
    }
  }

  if (typeof value === "number") {
    if (schema.minimum != null && value < schema.minimum) {
      errors.push({ path, message: `below minimum ${schema.minimum}` });
    }
    if (schema.maximum != null && value > schema.maximum) {
      errors.push({ path, message: `above maximum ${schema.maximum}` });
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems != null && value.length < schema.minItems) {
      errors.push({ path, message: `needs at least ${schema.minItems} item(s)` });
    }
    if (schema.uniqueItems === true) {
      const seen = new Set();
      for (const item of value) {
        const key = JSON.stringify(item);
        if (seen.has(key)) errors.push({ path, message: `duplicate item ${key}` });
        seen.add(key);
      }
    }
    if (schema.items) {
      value.forEach((item, i) => validateNode(root, schema.items, item, `${path}[${i}]`, errors));
    }
  }

  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const key of schema.required || []) {
      if (!(key in value)) errors.push({ path, message: `missing required "${key}"` });
    }
    if (schema.minProperties != null && Object.keys(value).length < schema.minProperties) {
      errors.push({ path, message: `needs at least ${schema.minProperties} propert(ies)` });
    }

    // THE check this module exists for.
    if (forbidsExtra(root, schema)) {
      const allowed = declaredProperties(root, schema);
      for (const key of Object.keys(value)) {
        if (!allowed.has(key)) {
          errors.push({
            path: path ? `${path}.${key}` : key,
            message: `unknown key "${key}"${suggest(key, allowed)}`,
          });
        }
      }
    }

    if (schema.propertyNames?.pattern) {
      let re = null;
      try {
        re = new RegExp(schema.propertyNames.pattern);
      } catch {
        re = null;
      }
      if (re) {
        for (const key of Object.keys(value)) {
          if (!re.test(key)) {
            errors.push({ path: `${path}.${key}`, message: `key does not match ${schema.propertyNames.pattern}` });
          }
        }
      }
    }

    for (const [key, sub] of Object.entries(schema.properties || {})) {
      if (key in value) validateNode(root, sub, value[key], path ? `${path}.${key}` : key, errors);
    }

    // additionalProperties as a SCHEMA (the logins registry): validate values.
    if (schema.additionalProperties && typeof schema.additionalProperties === "object") {
      const declared = new Set(Object.keys(schema.properties || {}));
      for (const [key, sub] of Object.entries(value)) {
        if (declared.has(key)) continue;
        validateNode(root, schema.additionalProperties, sub, `${path}.${key}`, errors);
      }
    }
  }

  for (const sub of schema.allOf || []) validateNode(root, sub, value, path, errors);

  // if/then/else — the schema uses this for the real rule that a login must
  // declare path/lands_on unless kind is "none". Skipping it would silently
  // under-validate exactly the conditional a product manifest gets wrong.
  if (schema.if) {
    const probe = [];
    validateNode(root, schema.if, value, path, probe);
    const branch = probe.length === 0 ? schema.then : schema.else;
    if (branch) validateNode(root, branch, value, path, errors);
  }

  if (schema.not) {
    const probe = [];
    validateNode(root, schema.not, value, path, probe);
    if (probe.length === 0) {
      errors.push({ path, message: "matches a forbidden shape" });
    }
  }

  for (const kind of ["anyOf", "oneOf"]) {
    const branches = schema[kind];
    if (!Array.isArray(branches) || branches.length === 0) continue;
    const branchErrors = branches.map((b) => {
      const errs = [];
      validateNode(root, b, value, path, errs);
      return errs;
    });
    if (!branchErrors.some((e) => e.length === 0)) {
      // Report the closest branch rather than every branch's noise.
      const best = branchErrors.reduce((a, b) => (b.length < a.length ? b : a));
      errors.push({
        path,
        message: `does not match any allowed shape (closest: ${best[0]?.message || "unknown"})`,
      });
    }
  }
}

/** "cleanup_step" -> ' (did you mean "cleanup_steps"?)' */
function suggest(key, allowed) {
  let best = null;
  let bestScore = Infinity;
  for (const candidate of allowed) {
    const d = distance(key, candidate);
    if (d < bestScore) {
      bestScore = d;
      best = candidate;
    }
  }
  const limit = Math.max(1, Math.floor(key.length / 3));
  return best && bestScore <= limit ? ` (did you mean "${best}"?)` : "";
}

function distance(a, b) {
  const m = a.length;
  const n = b.length;
  let prev = Array.from({ length: n + 1 }, (_, j) => j);
  for (let i = 1; i <= m; i += 1) {
    const cur = [i];
    for (let j = 1; j <= n; j += 1) {
      cur[j] = Math.min(
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
    }
    prev = cur;
  }
  return prev[n];
}

/**
 * Validate one manifest. Returns { ok, errors: [{path, message}] }.
 * Errors are capped: twenty is already a "this manifest is wrong" signal, and
 * an uncapped dump buries the first (usually causal) one.
 */
export function validateManifest(schema, manifest) {
  const errors = [];
  validateNode(schema, schema, manifest, "", errors);
  // allOf/anyOf branches re-walk the same node, so an unknown key is reported
  // once per branch. Dedupe by (path, message) — six copies of one typo reads
  // like six problems.
  const seen = new Set();
  const unique = errors.filter((e) => {
    const key = `${e.path} ${e.message}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  return { ok: unique.length === 0, errors: unique.slice(0, 20) };
}
