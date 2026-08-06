// Value normalization — the parity bar as code.
//
// Deliberately its own module rather than assert_value-private: the same rules
// (displayed precision, required units, currency placement) are what a
// cross-stack differ needs, so encoding them once means the differ consumes
// this instead of reimplementing it and disagreeing at the edges.
//
// Literal comparison stays the default everywhere. Normalization is opt-in.

const CURRENCY_RE = /^\s*([$€£¥])\s*(-?[\d,]+(?:\.\d+)?)\s*$/;
const TRAILING_CODE_RE = /^\s*(-?[\d,]+(?:\.\d+)?)\s*([A-Z]{3})\s*$/;
const NUMERIC_RE = /-?[\d,]+(?:\.\d+)?/;

/**
 * Pull a number and (when present) a unit out of a rendered string.
 *
 *   "50.00%"    -> { number: 50,     unit: "%"   }
 *   "$125.00"   -> { number: 125,    unit: "$"   }
 *   "125.00 USD"-> { number: 125,    unit: "USD" }
 *   "1 lb"      -> { number: 1,      unit: "lb"  }
 */
export function parseValue(raw) {
  const text = String(raw ?? "").trim();
  if (!text) return { number: null, unit: null, text };

  const currency = text.match(CURRENCY_RE);
  if (currency) {
    return { number: toNumber(currency[2]), unit: currency[1], text };
  }
  const code = text.match(TRAILING_CODE_RE);
  if (code) {
    return { number: toNumber(code[1]), unit: code[2], text };
  }
  const num = text.match(NUMERIC_RE);
  if (!num) return { number: null, unit: null, text };

  const number = toNumber(num[0]);
  const unit = text.slice(num.index + num[0].length).trim() || null;
  return { number, unit, text };
}

function toNumber(s) {
  const n = Number(String(s).replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

/**
 * Compare two rendered values under a normalization spec.
 *
 * Returns { equal, reason, actual, expected } — `reason` names the FIRST
 * difference so a report says "unit" or "precision", never just "not equal".
 *
 * Units must match exactly when the spec demands one: 1 lb and 1 kg are
 * different values even though the numbers agree, and that is the single most
 * common way a parity check quietly passes when it should not.
 */
export function compareValues(actualRaw, expectedRaw, spec = null) {
  const opts = spec || {};
  const trim = opts.trim !== false;
  let actual = String(actualRaw ?? "");
  let expected = String(expectedRaw ?? "");
  if (trim) {
    actual = actual.trim();
    expected = expected.trim();
  }
  if (opts.case_fold === true) {
    actual = actual.toLowerCase();
    expected = expected.toLowerCase();
  }

  if (!spec || !opts.as || opts.as === "string") {
    const equal = actual === expected;
    return {
      equal,
      reason: equal ? null : "text",
      actual,
      expected,
    };
  }

  const a = parseValue(actual);
  const e = parseValue(expected);

  if (a.number == null || e.number == null) {
    return {
      equal: false,
      reason: "unparseable",
      actual,
      expected,
    };
  }

  // A required unit is checked against BOTH sides: a spec that says "%" and an
  // actual rendered in "kg" is a difference even if the expectation forgot it.
  if (opts.unit) {
    for (const [side, parsed] of [["actual", a], ["expected", e]]) {
      if (parsed.unit != null && parsed.unit !== opts.unit) {
        return { equal: false, reason: `unit(${side})`, actual, expected };
      }
    }
  } else if ((a.unit || null) !== (e.unit || null)) {
    return { equal: false, reason: "unit", actual, expected };
  }

  const precision = Number.isInteger(opts.precision) ? opts.precision : null;
  if (precision == null) {
    const equal = a.number === e.number;
    return { equal, reason: equal ? null : "number", actual, expected };
  }

  const equal = round(a.number, precision) === round(e.number, precision);
  return { equal, reason: equal ? null : "precision", actual, expected };
}

function round(n, places) {
  const f = 10 ** places;
  // Nudge off binary-representation boundaries (1.005 is really 1.00499…)
  // so a value the app rendered as "1.01" does not compare as "1.00".
  return Math.round((n + Number.EPSILON * Math.sign(n) * Math.abs(n)) * f) / f;
}
