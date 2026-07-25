// classifyRisk for preview-ui-walk — fail-closed when prod and non-prod both match.
// Prod wins first. NONPROD uses word-boundary \bdev- so "dev-one-api" is non-prod
// but "prod-dev-api" is still prod_like.

const PROD_HINT =
  /(?:^|[.\/-])prod(?:uction)?(?:[.\/-]|$)|prod-api|api\.prod|amazonaws\.com\/prod/i;
const NONPROD_HINT =
  /stage|staging|sandbox|localhost|127\.0\.0\.1|\.dev\.|\bdev-|devbox|preview/i;

export function classifyRisk(value) {
  if (value == null || value === "") return "unset";
  const s = String(value);
  // Prod wins first (fail-closed).
  if (PROD_HINT.test(s)) return "prod_like";
  // Explicit non-prod hostnames (stage-one-api / dev-one-api.onemilc.com, …).
  if (NONPROD_HINT.test(s)) return "ok";
  // Bare onemilc.com without stage/dev still treated as prod-like.
  if (/\.onemilc\.com\b/i.test(s)) return "prod_like";
  return "ok";
}

export { PROD_HINT, NONPROD_HINT };
