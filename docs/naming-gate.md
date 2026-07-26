# Casein launch decision and naming risk register

> Public product name: **Casein**
>
> Previous public name: **DevIDE**
>
> Decision: **GO WITH ACCEPTED RISKS** (2026-07-22)

The product owner has directed the project to launch under the public name
**Casein**. A dedicated domain is not required for launch: the existing source,
documentation, and distribution channels remain canonical until the team
chooses to add or migrate them.

This decision does not claim that every naming risk is resolved. The objective
checks below remain the evidence register, with unresolved items recorded as
accepted or deferred instead of silently marked `PASS`. This document is not
legal clearance, and the collision evidence is not a legal conclusion.

> ### AMENDMENT — implementation identity migrated (2026-07-24)
>
> The paragraph below (and the "Initial launch scope" exclusions that follow)
> recorded the **initial** 2026-07-22 scope, which deliberately kept the
> implementation identifiers unchanged. The product owner has since directed
> the separate migration that scope anticipated, and it has been executed:
>
> - **Migrated to Casein:** module namespace (`DevIDE.*` → `Casein.*`), OTP app
>   atom (`:dev_ide` → `:casein`), environment variables (`DEV_IDE_*` →
>   `CASEIN_*`), source directories, the release + `bin/casein`, `mix casein.*`
>   tasks, systemd units, infra scripts, docker identity, Windows desktop
>   identity, the MCP server, frontend event/CSS namespaces, and DB + private
>   package names.
> - **Frozen by design:** the `DEVIDE_*` env namespace (a separate namespace
>   that now coexists with `CASEIN_*`) and the `:ghostty` app atom. (The
>   `X-DevIDE-Caller-Pane` caller-pane header and the remaining user-facing
>   DevIDE copy were later renamed too — the header as a coordinated wire cutover
>   where running agents send the old name until restarted. The only DevIDE names
>   that remain are the `native/` Apple/OS-registered ids pending registration,
>   and the former-name references in this record.)
> - **N4 updated:** the canonical repository was renamed
>   `dl-alexandre/dev_ide` → **`dl-alexandre/casein`** (still private). GitHub
>   redirects the former URL.
> - **Still deferred**, because each needs an external registration or a
>   running-system re-provisioning that a source-only rename would break: the
>   public host name (`devide.devbox.milcgroup.com` — needs DNS + Caddy in
>   milc-devbox), the Apple bundle id `com.alexandrefamilyfarm.devide-mob`
>   (needs an Apple App ID + provisioning profile), and the workspace slug
>   `dalexandre-devide` together with the tmux session prefix and MCP server
>   slugs derived from it (needs workspace re-provisioning). The live host also
>   still uses the `/opt/devide`, `/etc/devide`, `/run/devide` paths; the deploy
>   scripts target those, with `casein` aliases symlinked on the box.
> - **N3 unchanged:** no unqualified `casein` package coordinate is claimed or
>   published. The renamed package names are private and unpublished.
> - **Before making the repository public**, its history must be scrubbed of
>   devbox/internal infrastructure detail (hostnames, paths, tokens). That is a
>   separate, not-yet-performed step.

The public-brand decision was deliberately separate from implementation
identity. *(Superseded by the amendment above.)* Keep `DevIDE.*`, `:dev_ide`,
`dev_ide`, and `DEV_IDE_*` unchanged. Existing commands, package coordinates,
repository paths, release artifacts, URLs, and deployment configuration remain
compatibility surfaces unless a separate migration is approved.

## Initial launch scope

- Use **Casein** in the README hero, product brief, glossary, and documentation
  index.
- Keep the existing GitHub repository as the canonical source location.
- Do not claim or publish an unqualified `casein` package coordinate.
- Do not block launch on owning `casein.com` or another dedicated domain.
- Do not rename application modules, OTP app names, environment variables,
  commands, services, database identities, telemetry labels, or tmux prefixes.
- Make any broader UI, repository, package, or URL migration a separate,
  reversible change.

## Objective checklist and disposition

| ID | Objective check | Evidence required | Casein disposition |
|---|---|---|---|
| **N1 — Legal clearance** | Review the exact name, close spellings, and phonetic equivalents for intended software and SaaS goods/services in launch jurisdictions. | Dated search exports and qualified written review for relevant jurisdictions and classes. | **DEFERRED / ACCEPTED RISK** — no qualified clearance is recorded. This remains a follow-up and is not represented as complete. |
| **N2 — Product collision** | Identify active exact-name software and decide whether it creates an unacceptable mistaken-identity risk. | Exact-name searches across source hosts, registries, app stores, product directories, and the general web. | **ACCEPTED RISK** — the owner has chosen to launch despite the Rails CMS and other exact-name repositories. |
| **N3 — Install namespace** | Control every advertised install coordinate, or use a qualified coordinate that cannot be confused with an existing package. | Registry ownership records and the exact proposed install command. | **NOT IN INITIAL SCOPE** — existing `casein` packages are not ours, so the launch will not advertise that unqualified coordinate. |
| **N4 — Web and source identity** | Publish one canonical source location. A dedicated domain is optional and must not be implied as controlled without evidence. | Link to the controlled canonical repository or site; ownership proof for any additional identity claimed later. | **PASS FOR INITIAL SCOPE** — the existing `dl-alexandre/casein` repository remains canonical; no dedicated domain is required or claimed. |
| **N5 — Search distinction** | Measure whether target users can distinguish this product from protein-related and existing software results. | Dated, signed-out result captures for `Casein software` and `Casein developer tool`. | **DEFERRED / ACCEPTED RISK** — current search results are not distinctive. Treat search position as a post-launch acquisition risk, not a launch gate. |
| **N6 — Spoken and written comprehension** | With at least 10 target users, measure spelling after hearing, pronunciation after reading, and unaided 24-hour recall. | Participant script, anonymized first responses, totals, and date. | **DEFERRED** — no test is recorded. |
| **N7 — Positioning fit** | After reading only the hero, at least 8 of 10 target users identify a durable workspace for people and coding agents; no more than 2 identify food, nutrition, or biotechnology as the primary product category. | Anonymized comprehension responses using the fixed prompt below. | **DEFERRED** — no test is recorded. |
| **N8 — Migration safety** | Bound the launch surface, preserve compatibility identifiers, and keep the public-copy change reversible. | Reviewed surface inventory, explicit exclusions, compatibility note, and rollback commit. | **PASS FOR INITIAL SCOPE** — the rollout is limited to five documentation files, internal identifiers remain stable, and the change can be reverted independently. |
| **N9 — Decision record** | Record a dated owner decision that states the launch name, scope, unresolved risks, and compatibility boundary. | A committed decision record linked from the documentation index. | **PASS** — this document records the 2026-07-22 owner direction to launch as Casein without a dedicated-domain prerequisite. |

## Current collision evidence

The records below are discovery evidence, not a legal conclusion. Recheck them
before claiming clearance or an unqualified package or web identity.

- [RubyGems `casein`](https://rubygems.org/gems/casein) is an existing Rails CMS
  package. On 2026-07-22 its registry API reported version `5.5.1.0` and more
  than 136,000 downloads.
- [npm `casein`](https://www.npmjs.com/package/casein) is an existing package
  for writing Sass/CSS with JavaScript.
- GitHub contains an established [Casein Rails CMS](https://github.com/russellquinn/casein)
  and multiple other exact-name software repositories.
- [Verisign RDAP for `casein.com`](https://rdap.verisign.com/com/v1/domain/CASEIN.COM)
  reports the domain registered through 2031. This does not block the scoped
  launch because no dedicated domain is required or claimed.
- Google Registry RDAP returned `not found` for
  [`casein.dev`](https://pubapi.registry.google/rdap/domain/casein.dev) and
  [`casein.app`](https://pubapi.registry.google/rdap/domain/casein.app) on
  2026-07-22. That is not evidence that either domain is purchasable,
  unreserved, or controlled.
- No qualified trademark clearance has been completed. The
  [USPTO trademark search](https://tmsearch.uspto.gov/),
  [EUIPO eSearch](https://euipo.europa.eu/eSearch/), and
  [UK IPO trademark search](https://trademarks.ipo.gov.uk/ipo-tmtext) remain
  follow-up inputs; database searches do not replace qualified legal judgment.

## Test script

Use the same artifact and questions for every participant. Do not mention milk,
protein, DevIDE, or the intended pronunciation before the first response.

1. Show **Casein** for five seconds. Ask the participant to say it.
2. Say the name once. Ask the participant to write it.
3. Show the README hero. Ask: “What does this product do, and who is it for?”
4. Ask: “What existing product or category does this name make you think of?”
5. After 24 hours, ask the participant to recall the name without a hint.

Record the first response verbatim, then score it against N6 and N7. Changing
the prompt, coaching the participant, or discarding an unfavorable association
invalidates that result.

## Decision record

- [x] Product owner selected **Casein** as the public product name.
- [x] A dedicated domain was removed as a launch prerequisite.
- [x] Known product, search, namespace, and legal-clearance risks are recorded.
- [x] Initial launch scope and compatibility exclusions are explicit.
- [x] Public copy uses Casein while implementation identifiers remain stable.
- [ ] Complete qualified legal review before representing the name as cleared.
- [ ] Reserve any future package, repository, social, or domain identity before
      advertising it as canonical.
- [ ] Run the comprehension and positioning tests when launch feedback is
      available.

The current decision is **GO WITH ACCEPTED RISKS** for the scoped public-copy
launch. That authorization does not silently expand to package publication,
repository transfer, domain acquisition, or internal identifier migration.
