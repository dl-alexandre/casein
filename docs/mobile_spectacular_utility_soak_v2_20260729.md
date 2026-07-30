# Mobile Spectacular Utility Soak v2 — 2026-07-29

This is the privacy-bounded physical dogfood record for Coding iPad and Android
SM-T390. Do not place credentials, pairing handles, prompts, message bodies,
terminal output, raw logs, commands, or file contents in this document.

## Metrics

| Metric | Before | Target | After |
|---|---:|---:|---:|
| Connected meaningful-transition p95 | not yet measured | <= 2 s | pending |
| Cold restored live feed | prior iPad < 2 s; Android not normalized | < 3 s | iPad foreground 1.693 s, authoritative feed 6.148 s; SM-T390 authenticated 6.725 s |
| Reconnect catch-up | prior evidence qualitative | < 5 s | SM-T390 9.954 s; safe but above target |
| Intervention completion | 80% historical | 100% naturally available actions | not exercised: no authoritative action card was declared |
| Exact resume completion | 90% historical | >= 95% | pending |
| Duplicate transitions/actions | 0 observed historically | 0 | pending |
| Desktop-required rate | not recoverable | measured, then reduced where safe | pending |

## Timestamped observations

| Time (America/Los_Angeles) | Platform/scenario | Expected | Observed | Evidence | Class/severity | Disposition |
|---|---|---|---|---|---|---|
| 2026-07-29 start | Shared baseline | Current master, explicit canonical origin, privacy-safe metrics | Clean worktrees at `56f4a324`; prior physical Android and iPad evidence remains valid | Git/source/audit aggregates | Green | Start parallel automation baseline |
| 2026-07-29 start | Durable transitions | Semantic transitions support since-last-viewed/catch-up | Production table has zero rows despite active work; cause not yet established | Count only; no contents | Investigation | Trace event eligibility and observer persistence before changing code |
| 2026-07-29 22:40 | Canonical device links | Both platforms have valid workspace-scoped canonical links; legacy origins stay separate | Android and iOS each have a valid link to workspace `e7c18b93-688b-4bb0-904d-ac93d61e9372` under the same `casein_…` origin; `devide_…`/`dev_ide` records remain distinct | Bounded DB identity/count/last-seen query; no token values | Green | Preserve profiles and migration separation |
| 2026-07-29 22:41 | Live Work cursor | Meaningful live-only changes survive background/reconnect and dedupe | Reconciliation broadcast replaced the in-memory cards without calling durable transition recording | Source trace + empty production transition count | Product defect / medium | Record only semantic upsert/disappearance transitions; focused tests pass |
| 2026-07-29 22:42 | Destructive review action | Server-declared destructive action requires explicit confirmation | Native Deny button dispatched on first tap despite `destructive?` and confirmation fields | Independent source/adversarial review | Product defect / high | Add confirm/cancel state and focused tests |
| 2026-07-29 22:42 | Open action screen loses network | Controls immediately become visibly read-only until authoritative refresh | Transport rejected offline mutation, but screen retained enabled controls and stale copy | Independent source/adversarial review | UX/safety defect / medium | Track feed status, disable controls, require fresh snapshot |
| 2026-07-29 22:43 | Android baseline | Casein-only lifecycle/layout navigation works without clearing production data | Canonical origin, lifecycle, portrait/landscape, scroll/back, Needs Me and Live pass; cold 7.877–8.148 s, warm 0.786–0.826 s | UIAutomator on SM-T390 at base `56f4a324` | Performance investigation | Separate process launch from authoritative-feed latency; offline run continues |
| 2026-07-29 22:43 | iPad baseline | Casein-only signed automation sees full canvas and lifecycle | 3 pass, 1 intentional skip, 0 fail; cold foreground 1.869 s, warm 0.183 s; portrait 810×1080 and landscape 1080×810 | XCUITest on Coding iPad at base `56f4a324` | Green / measurement pending | Reinstall exact provenance and measure authoritative Live join |
| 2026-07-29 22:47 | iPad authoritative hydration | Restored authoritative Live feed appears in under 3 s | Foreground appeared in 1.617 s; authoritative Live appeared in 6.352 s | Signed XCUITest on Coding iPad; `/tmp/casein-soak-ios-final.xcresult` | Product performance defect / medium | Preconnect the one trusted active origin while local dashboard state boots; remeasure on reviewed head |
| 2026-07-29 22:52 | Android exact-base provenance | Physical behavior comes from exact current-base BEAMs without replacing profile data | 1,396 exact-base BEAMs installed in place; dashboard module digest matched; killed launch 6.517 s, warm 0.883 s, offline-to-authenticated 9.403 s | UIAutomator on SM-T390; package data preserved | Performance defect / medium | Remeasure early-preconnect head |
| 2026-07-29 22:53 | Android paired summary | Useful filters/cards remain above the fold on the older screen | Exact base reproducibly left a large blank summary area in portrait and landscape, pushing the inbox below the fold | `/private/tmp/casein-soak-android-evidence/exact-base-portrait-final.png` and landscape companion | UX defect / medium | Remove the weighted mixed-control row; use bounded full-width summary controls and physically recheck |
| 2026-07-29 22:56 | Native contract suite | Shared native changes remain compatible | 181/181 tests passed after updating iOS project metadata assertions for the reusable soak target | Full `native/casein_mob` ExUnit suite | Green | Continue exact-head review and physical revalidation |
| 2026-07-29 23:15 | Action trust boundary | Every mutation is origin- and authoritative-revision-bound before replay | Review actions and free-text follow-up now carry server revisions; unknown origins and stale revisions fail before effect or replay | 65 focused server/channel tests plus independent adversarial review | Product safety defect / high | Fixed; exact-device replay and stale-card proof pending deployed head |
| 2026-07-29 23:21 | Reusable physical harnesses | Both platforms have bounded, data-preserving automation | Android instrumentation APK builds independently of the native target; signed iOS UI-test runner builds for Coding iPad; successful runs retain no task-bearing screenshots | Gradle `assembleDebugAndroidTest`; Xcode signed `build-for-testing` | Green | Run both against the reviewed commit |
| 2026-07-29 23:22 | Upstream Mob status | Temporary downstream layout protection remains until upstream is safe | GenericJam/mob PR #75 remains open; Casein keeps its current full-width behavior | Read-only upstream check | External dependency | Do not remove the existing downstream protection |
| 2026-07-29 23:31 | Android reviewed head | Exact reviewed state remains safe and fixes the older-screen layout | UI automation passed; the artificial paired-summary gap is gone. Cold 7.955 s, warm 0.766 s, offline recovery 10.302 s; no crash/ANR or unsafe fallback | SM-T390 UIAutomator at `1ecc52ea`; profile preserved | Green functionality / performance limitation | Keep honest older-device timings; do not trade safety for a synthetic budget win |
| 2026-07-29 23:33 | iPad reviewed head | Exact reviewed state boots and exposes authoritative Action Center | Signed install preserved data but remained at `Starting BEAM…` beyond 40 s; no crash report. The only boot-path delta was transport preconnect before Repo startup/migrations | Coding iPad console and XCUITest at `1ecc52ea` | Product defect / blocking | Move preconnect after persistence initialization, retain overlap with root-screen startup, and physically revalidate before merge |
| 2026-07-29 23:39 | iPad reordered preconnect | Moving transport work after persistence initialization resolves embedded boot | Exact signed `d2f590a5` still remained at `Starting BEAM…`; Repo ordering was not the cause | Coding iPad console and signed artifact provenance | Product defect / blocking | Remove speculative startup preconnect entirely and restore the previously proven watcher-driven connection path |
| 2026-07-29 23:56 | iPad module bisect | Compact dashboard layout remains renderable when no resume context exists | Exact-base control booted; feature Review screen alone booted; feature Dashboard alone reproduced the hang. The layout moved an optional `resume_button/2` into an unfiltered child list, emitting a nil child when no resume context existed | Single-module device BEAM bisect with exact hashes | Product defect / blocking | Reject nil children in the paired summary and assert the no-resume paired tree recursively contains none |
| 2026-07-30 00:01 | Final exact-head devices | Reviewed native state boots and remains safe on both connected devices | Coding iPad: 3 applicable UI tests passed, 1 no-card skip, full portrait/landscape canvas, no crashes. SM-T390: UIAutomator passed with compact layout, offline read-only/reconnect, no crash/ANR | Signed/data-preserving iPad build and exact device BEAM hashes; Android exact device BEAM hash | Green functionality / performance follow-up | Land reviewed fix; retain measured cold hydration/reconnect budgets as unresolved performance work rather than weaken authority checks |
| 2026-07-30 01:05 | Deployed disposable-agent action proof | A harmless prompt in the explicit disposable agent pane yields a server-declared clarification card on both devices | Guarded delivery targeted only the role-marked agent pane, but neither device received an action card after authoritative refresh; Live remained healthy, Needs Me remained empty, and Android offline/recovery remained visibly stale then authoritative | Aggregate transition counts plus bounded iPad and SM-T390 UI automation; no pane contents or message bodies captured | Missing authoritative projection / follow-up | Do not fabricate a card or bypass the typed action contract; design a narrow server-declared clarification event before claiming physical action/replay proof |

## Findings

Findings will be classified as product defect, UX friction, external blocker, or
operator/tooling limitation. Only reproducible high/medium defects and cheap
low-severity friction are candidates for changes.

Current bounded fixes address four observed defects: durable Live Work cursor
transitions, destructive-action confirmation, truthful offline action state, and
the older-screen paired-summary layout. The intervention catalog is also narrowed to actions
coherent with the authoritative card posture. No new action kinds, terminal
surface, simultaneous connection, silent failover, or sensitive telemetry was
introduced.

DairyPhone issue #457 remains physically unavailable in this soak. Source review
narrows the unresolved camera-only path to the upstream `mob_scanner` iOS bridge:
the released plugin ignores the requested QR-only format set and selects the
first metadata object. Casein's shared compact parser already accepts the bounded
scanner-edge artifacts covered by its cross-platform vectors. No speculative
dependency fork or weakened parser was added without a connected DairyPhone
reproduction; the issue remains an explicitly scoped external physical blocker.
