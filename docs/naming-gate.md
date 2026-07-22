# Public naming gate

> Candidate: **Casein**
>
> Current public name: **DevIDE**
>
> Gate status: **BLOCKED** (assessment dated 2026-07-22)

This is a release gate, not a preference survey. A candidate name is approved
only when every blocking check below is `PASS`, the evidence is linked, and the
decision owners record a dated go/no-go decision. `UNKNOWN` blocks just as
surely as `FAIL`; scores and enthusiasm cannot average away a hard conflict.

Until this gate passes, **Casein is a candidate codename only**. Do not use it
as the product name in the README, documentation titles, UI, package metadata,
release artifacts, repository name, or public URLs. Candidate/research records
such as this gate may name it explicitly without presenting it as the product.

The naming decision is deliberately separate from implementation identity.
Keep `DevIDE.*`, `:dev_ide`, and `DEV_IDE_*` unchanged during this campaign. A
future public-brand decision does not authorize a codebase-wide rename.

## Blocking checklist

| ID | Objective pass condition | Required evidence | Casein status |
|---|---|---|---|
| **N1 — Legal clearance** | A qualified reviewer clears the exact name, close spellings, and phonetic equivalents for the intended software and SaaS goods/services in every launch jurisdiction. | Dated search exports and written sign-off covering at least US classes 9 and 42, plus EU and UK equivalents if those markets are in launch scope. | **UNKNOWN** — no clearance or sign-off is recorded. |
| **N2 — Product collision** | No active software or developer-tool product creates a likely mistaken-identity problem, or counsel and the product owner explicitly accept and document the risk. | Exact-name search across GitHub, general web results, app stores, and relevant product directories; owner, activity, category, and last-updated date for every material collision. | **FAIL** — Casein is already the name of a Rails CMS and several software repositories. |
| **N3 — Install namespace** | Every intended install command and package coordinate is controlled, or a tested qualified alternative is both unambiguous and acceptable to target users. | Registry ownership screenshots or API records for each planned ecosystem, plus the exact proposed install commands. | **UNKNOWN** — exact `casein` packages exist on RubyGems and npm, and no intended/qualified namespace plan is recorded. |
| **N4 — Web and source identity** | The team controls the primary domain and canonical source/social identities before announcement. Redirects and typo-defense names are documented. | Registrar receipts, DNS ownership proof, organization/repository ownership, and a redirect map. A registry `not found` response alone is not ownership. | **UNKNOWN** — `casein.com` is registered, and no Casein domain or canonical source identity is recorded as controlled. |
| **N5 — Search distinction** | In a clean, signed-out search, at least 15 of the first 20 results for both `NAME software` and `NAME developer tool` refer to this product. No conflicting software product appears in the first five. | Dated result capture from two search engines in the US and one intended non-US market. | **FAIL** — current results are dominated by the milk protein and existing Casein software. |
| **N6 — Spoken and written comprehension** | In a test with at least 10 target users, at least 8 spell the name correctly after hearing it once, at least 8 pronounce it acceptably after reading it once, and at least 8 recall it after 24 hours. | Participant script, anonymized responses, totals, and date. Do not coach pronunciation before the first response. | **UNKNOWN** — no test is recorded. |
| **N7 — Positioning fit** | After reading only the proposed hero, at least 8 of 10 target users identify the product as a durable workspace for people and coding agents; no more than 2 identify it primarily with food, nutrition, or biotechnology. | Anonymized comprehension responses using the fixed prompt in §Test script. | **UNKNOWN** — no test is recorded. |
| **N8 — Migration safety** | A complete public-surface inventory, staged rollout, compatibility period, redirect plan, and one-release rollback are reviewed before any rename commit. | Checked migration inventory with owners for docs, UI, domains, repository, release assets, package coordinates, telemetry labels, and support material. | **UNKNOWN** — intentionally deferred until N1–N7 pass. |
| **N9 — Decision record** | Product, engineering, and legal/brand owners sign one dated decision that cites N1–N8 evidence and names the launch spelling, capitalization, pronunciation, and canonical URL. | Committed decision record with all approvers and no open blocking item. | **UNKNOWN**. |

## Current collision evidence

The records below are discovery evidence, not a legal conclusion. Recheck all
of them within 30 days of a naming decision.

- [RubyGems `casein`](https://rubygems.org/gems/casein) is an existing Rails CMS
  package. On 2026-07-22 its registry API reported version `5.5.1.0` and more
  than 136,000 downloads.
- [npm `casein`](https://www.npmjs.com/package/casein) is an existing package
  for writing Sass/CSS with JavaScript.
- GitHub contains an established [Casein Rails CMS](https://github.com/russellquinn/casein)
  and multiple other exact-name software repositories.
- [Verisign RDAP for `casein.com`](https://rdap.verisign.com/com/v1/domain/CASEIN.COM)
  reports the domain registered through 2031. Google Registry RDAP returned
  `not found` for [`casein.dev`](https://pubapi.registry.google/rdap/domain/casein.dev)
  and [`casein.app`](https://pubapi.registry.google/rdap/domain/casein.app) on
  2026-07-22, but that is not evidence that either domain is purchasable,
  unreserved, or controlled.
- No qualified trademark clearance has been completed. Search and preserve
  results from the [USPTO trademark search](https://tmsearch.uspto.gov/),
  [EUIPO eSearch](https://euipo.europa.eu/eSearch/), and
  [UK IPO trademark search](https://trademarks.ipo.gov.uk/ipo-tmtext) before
  review; database searches do not replace qualified legal judgment.

## Test script

Use the same artifact and questions for every participant. Do not mention milk,
protein, DevIDE, or the candidate's intended pronunciation before the first
response.

1. Show the candidate name for five seconds. Ask the participant to say it.
2. Say the candidate once. Ask the participant to write it.
3. Show the README hero draft with the candidate substituted only in the test
   copy. Ask: “What does this product do, and who is it for?”
4. Ask: “What existing product or category does this name make you think of?”
5. After 24 hours, ask the participant to recall the name without a hint.

Record the first response verbatim, then score it against N6 and N7. Changing
the prompt, coaching the participant, or discarding an unfavorable association
invalidates that result.

## Decision procedure

- [ ] Assign one accountable owner for each of N1–N9.
- [ ] Attach dated evidence beside every row; use `PASS`, `FAIL`, or `UNKNOWN`.
- [ ] Stop at the first `FAIL` unless the candidate itself changes.
- [ ] Re-run time-sensitive searches within 30 days of the final decision.
- [ ] Record the final go/no-go decision and all approvers.
- [ ] Only after a recorded `GO`, open a separate public-brand rollout plan.

The current decision is **NO-GO**. The Casein campaign may refine positioning
and test copy, but it must not ship Casein as the public product name while this
document remains blocked.
