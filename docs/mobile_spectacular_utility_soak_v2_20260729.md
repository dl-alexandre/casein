# Mobile Spectacular Utility Soak v2 — 2026-07-29

This is the privacy-bounded physical dogfood record for Coding iPad and Android
SM-T390. Do not place credentials, pairing handles, prompts, message bodies,
terminal output, raw logs, commands, or file contents in this document.

## Metrics

| Metric | Before | Target | After |
|---|---:|---:|---:|
| Connected meaningful-transition p95 | not yet measured | <= 2 s | Not measured in this slice. The structured cohorts measure connection-generation-start to first-card and are reported under cold restored feed and reconnect catch-up; they are not relabeled as a connected meaningful-transition interval |
| Server snapshot-render tail | Coding iPad p50 approximately 165 ms, max 6.37 s; SM-T390 p50 approximately 166 ms, cold max 9.66 s, reconnect max 13.70 s, with 5 of 24 Android samples over 1 s; baseline snapshots held 32 cards and encoded to approximately 162 KB | No multi-second render tail without weakening authorization | 33-card p50 approximately 19 ms on both platforms; max 23.040 ms on Coding iPad and 30.086 ms on SM-T390 |
| Cold restored live feed | prior iPad < 2 s; Android not normalized | < 3 s | Final exact-`cc37fd78` first-card elapsed p95 is 2.259 s on Coding iPad and 3.396 s on SM-T390 across 10/10 complete cold generations per platform. Android misses the target by 396 ms; its native transport-establishment duration p95 is 2.294 s while server token-through-join-reply p95 is 121 ms |
| Reconnect catch-up | prior evidence qualitative | < 5 s | Final successful connection-generation to first-card p95 is 0.921 s on Coding iPad and 2.902 s on SM-T390 across 10/10 recovered paints per platform. Earlier Android Wi-Fi-enable-to-recovery p95 remains 10.479 s because association/backoff precedes the successful generation; the two intervals are kept distinct |
| Intervention completion | 80% historical | 100% naturally available actions | Clarification proven on both platforms; the broader action catalog was not measured in this slice. One physical submit produced one authoritative delivery/resolution independently on iPad and Android, while same-request replay remains server-contract tested |
| Exact resume completion | 90% historical | >= 95% | pending |
| Duplicate telemetry / guarded delivery | 0 observed historically | 0 | Both final structured platform cohorts have zero duplicate or repeated timing stages. The physical clarification path used one submit and produced one guarded delivery independently per platform; same-request action replay remains contract-tested rather than claimed from a physical double-submit |
| Desktop-required rate | not recoverable | measured, then reduced where safe | pending |

## Timestamped observations

| Time (America/Los_Angeles) | Platform/scenario | Expected | Observed | Evidence | Class/severity | Disposition |
|---|---|---|---|---|---|---|
| 2026-07-29 start | Shared baseline | Current master, explicit canonical origin, privacy-safe metrics | Clean worktrees at `56f4a324`; prior physical Android and iPad evidence remains valid | Git/source/audit aggregates | Green | Start parallel automation baseline |
| 2026-07-29 start | Durable transitions | Semantic transitions support since-last-viewed/catch-up | Production table has zero rows despite active work; cause not yet established | Count only; no contents | Investigation | Trace event eligibility and observer persistence before changing code |
| 2026-07-29 22:40 | Canonical device links | Both platforms have valid workspace-scoped canonical links; legacy origins stay separate | Android and iOS each have a valid workspace-scoped canonical-origin link; legacy-origin profiles remain distinct and read-only | Bounded DB identity/count/last-seen query; no token values | Green | Preserve profiles and migration separation |
| 2026-07-29 22:41 | Live Work cursor | Meaningful live-only changes survive background/reconnect and dedupe | Reconciliation broadcast replaced the in-memory cards without calling durable transition recording | Source trace + empty production transition count | Product defect / medium | Record only semantic upsert/disappearance transitions; focused tests pass |
| 2026-07-29 22:42 | Destructive review action | Server-declared destructive action requires explicit confirmation | Native Deny button dispatched on first tap despite `destructive?` and confirmation fields | Independent source/adversarial review | Product defect / high | Add confirm/cancel state and focused tests |
| 2026-07-29 22:42 | Open action screen loses network | Controls immediately become visibly read-only until authoritative refresh | Transport rejected offline mutation, but screen retained enabled controls and stale copy | Independent source/adversarial review | UX/safety defect / medium | Track feed status, disable controls, require fresh snapshot |
| 2026-07-29 22:43 | Android baseline | Casein-only lifecycle/layout navigation works without clearing production data | Canonical origin, lifecycle, portrait/landscape, scroll/back, Needs Me and Live pass; cold 7.877–8.148 s, warm 0.786–0.826 s | UIAutomator on SM-T390 at base `56f4a324` | Performance investigation | Separate process launch from authoritative-feed latency; offline run continues |
| 2026-07-29 22:43 | iPad baseline | Casein-only signed automation sees full canvas and lifecycle | 3 pass, 1 intentional skip, 0 fail; cold foreground 1.869 s, warm 0.183 s; portrait 810×1080 and landscape 1080×810 | XCUITest on Coding iPad at base `56f4a324` | Green / measurement pending | Reinstall exact provenance and measure authoritative Live join |
| 2026-07-29 22:47 | iPad authoritative hydration | Restored authoritative Live feed appears in under 3 s | Foreground appeared in 1.617 s; authoritative Live appeared in 6.352 s | Signed XCUITest aggregate; raw result artifact not retained | Product performance defect / medium | Preconnect the one trusted active origin while local dashboard state boots; remeasure on reviewed head |
| 2026-07-29 22:52 | Android exact-base provenance | Physical behavior comes from exact current-base BEAMs without replacing profile data | 1,396 exact-base BEAMs installed in place; dashboard module digest matched; killed launch 6.517 s, warm 0.883 s, offline-to-authenticated 9.403 s | UIAutomator on SM-T390; package data preserved | Performance defect / medium | Remeasure early-preconnect head |
| 2026-07-29 22:53 | Android paired summary | Useful filters/cards remain above the fold on the older screen | Exact base reproducibly left a large blank summary area in portrait and landscape, pushing the inbox below the fold | Derived UI assertion; raw screenshots not retained | UX defect / medium | Remove the weighted mixed-control row; use bounded full-width summary controls and physically recheck |
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
| 2026-07-30 04:46 | Authoritative clarification projection | Only a real server event for the disposable exact role-marked agent target creates Needs Me | The server-declared clarification appeared as one origin-qualified Needs Me card on both devices; duplicate target events coalesced to the newest revision | Bounded card identity/count and aggregate topology metadata; no pane contents or response body retained | Green | Contract landed in PR #471 and deployed in descendant `a76244c2` |
| 2026-07-30 04:59 | Physical clarification action | A fresh physical action delivers once to the exact agent, resolves authoritatively, and leaves no stale mobile action | Coding iPad dispatched once; the server recorded one delivery outcome and resolution; both devices then showed zero clarification cards after authoritative refresh. No operator, verify, or unrelated target was eligible under the guarded contract | Privacy-bounded action/resolution audit atoms, card counts, exact target-role metadata, and physical UI state | Green with UX defect | Fix the snapshot/result race that briefly rendered a misleading expired message while delivery confirmation was in flight |
| 2026-07-30 05:04 | Android response entry | Older Android controlled input preserves exact bounded text while BEAM echoes arrive | Sequential input was reproducibly reordered before submission; a focus-aware Android edit buffer retained exact sequential and atomic accessibility input on SM-T390. The safe pairing fixture was never submitted | JVM state tests, data-preserving physical instrumentation, package/profile persistence checks | Product defect / medium | Land the platform-only reconciliation fix and repeat the disposable clarification action on the deployed build |
| 2026-07-30 05:05 | Cold hydration stages | Authoritative feed readiness, rather than harness settling, meets the three-second target | Coding iPad n=10 p50/p95 0.715/0.811 s. SM-T390 primary samples 2.874/2.900/2.984 s, p50 2.900 s and p95 2.984 s | Privacy-bounded stage timestamps only | Green | Keep harness launch timing separate from product feed readiness |
| 2026-07-30 05:05 | Android reconnect stages | Reconnect reaches authoritative state within five seconds unless a measured platform/network floor dominates | End-to-end was 10.53 s; Wi-Fi association plus IPv4 took about 8.76 s after enable, while transport and authoritative join completed about 1.77 s later | Android connectivity timestamps plus privacy-bounded application stages | External/platform floor | Do not weaken single-origin authority or add silent failover to mask Android 9 radio association |
| 2026-07-30 06:31 | Late action-screen subscription | A screen opened after the one active topic joined receives the latest authoritative card without reconnecting or changing origin | The topic client joined correctly, but action screens could miss the already-delivered snapshot and remain non-authoritative until a later event | Source trace, focused subscriber tests, and independent adversarial review | Product defect / medium | Cache one bounded authoritative snapshot per active topic and replay it only to subscribers of that exact topic |
| 2026-07-30 06:44 | Subscriber lifecycle bounds | Authoritative replay does not outlive a topic subscription, pairing, or origin | Review found a final-unwatch cache leak and redundant process monitors; the final implementation clears topic state on final unwatch and owns one monitor per subscriber PID | 21 focused SessionClient tests, 188 full native tests, independent clean review | Product defect / medium | Fixed in PR #474 without adding polling, another socket, or a new server model |
| 2026-07-30 06:48 | Android disabled actions | Offline/stale controls are both visually and behaviorally disabled | Material and compact buttons previously retained a dispatch path after becoming disabled | Focused JVM tests and full Android unit suite | Product defect / medium | Disabled state now gates both rendering semantics and dispatch |
| 2026-07-30 06:52 | iPad exact merged build | A cold launch restores the authoritative clarification and late-opened response screen | Data-preserving signed install of merge `9d221942`; cold launch restored the Devbox card, and Respond opened the bounded 280-character action screen after authoritative target restoration. Portrait, full-canvas landscape, and background/foreground passed | Exact packaged/device BEAM hashes, strict codesign, signed XCUITest results, privacy-safe screenshots | Green | Keep iPad installed profile/data; no second physical submission was needed for cross-platform delivery proof |
| 2026-07-30 06:53 | Deploy restart degradation | Lost ephemeral pane state cannot be guessed from a durable card | During deployment, the clarification remained visible but Respond degraded to the workspace fallback until the disposable role-marked agent state was authoritatively reported again | Card/UI state plus aggregate role/topology metadata; no pane contents | Green / fail-closed | Preserve fallback; never retarget from stale locator data |
| 2026-07-30 06:55 | Android exact merged action | The real clarification response reaches the disposable agent once and no other pane | Data-preserving exact merge install showed the authoritative role-marked excerpt and enabled response. One physical Send produced one `mobile.clarification_resolved`, one card intervention, one attention action, and one resume intervention audit sequence, followed by `Action accepted` and authoritative card resolution | Privacy-bounded audit atoms, role-qualified target match, and aggregate topology roles; raw UI artifacts, message bodies, and pane output not retained | Green | Exactly one physical submit; operator, verify, and unrelated panes were ineligible and received no guarded delivery |
| 2026-07-30 06:57 | Android offline/inactive safety | Cached or inactive-origin cards remain visibly read-only and cannot dispatch | Offline card rendered `Last known · Offline · Read-only`; tapping did not navigate or mutate. Local Mac and Devbox profiles remained distinct, and killed/warm launch after resolution fell back to the correct origin-qualified Action Center | Derived UI assertions and no new mutation audit; raw UI artifacts not retained | Green | Preserve explicit activation and authoritative refresh before action |
| 2026-07-30 07:00 | Replay evidence boundary | Same request IDs replay the stored result without a second delivery | Server adversarial tests cover same-request replay. The physical UI was intentionally tapped once: after authoritative acceptance it exposes no retry control and a second tap would mint a new request ID rather than test idempotent replay | Server contract tests plus physical one-submit audit count | Honest limitation | Do not manufacture a second physical delivery claim or add a retry surface solely for testability |
| 2026-07-30 07:02 | Canonical deployment | The reviewed mobile merge is active through the normal poller and remains present after master advances | Poller first activated exact merge `9d221942`; it then activated healthy master `ecb230a2`, a proven descendant containing the merge. Deploy service exited successfully and canonical `/healthz` passed | Host revision, git ancestry, systemd result, canonical health endpoint | Green | No manual production mutation |
| 2026-07-31 | Structured native timing boundary | Native timing is externally observable without exposing generic application logs | Mob merge `f8e296a4` added a dedicated seven-field timing call with native validation and a static public iOS log format; generic Mob logging remains private | Exact source pin, focused/adversarial/full tests, independent clean review | Green | Collect only reconstructed allowlisted markers and emit aggregate results |
| 2026-07-31 | Connection-generation snapshot guard | A new transport establishes its own valid version baseline and malformed or regressing snapshots fail closed | On each transport generation the join snapshot becomes the baseline; later missing, non-integer, or lower versions are rejected, equal versions remain valid refreshes, and the accepted version is not persisted across process or server restart | Focused native contract tests and exact reviewed Casein head `d208d681` | Green | Preserve origin scoping and reset only on a genuinely new transport generation |
| 2026-07-31 | Canonical structured deploy and installs | Reviewed server/client integration is active and both physical apps match it without erasing saved state | Reviewed Casein head `d208d681` merged and activated as `cc37fd78` through the normal poller. Exact signed Coding iPad and SM-T390 builds were installed in place with app/profile data preserved | Git ancestry, poller revision/health, artifact provenance, signature/package checks | Green | Both physical cohorts accepted |
| 2026-07-31 | Deployment control-plane bound | An unavailable Caddy admin endpoint cannot hold a healthy release activation open indefinitely | Caddy reconciliation now occurs after activation and uses bounded fail-safe admin connect/total timeouts; an admin timeout is reported as a post-activation boundary rather than blocking the activated release | Hermetic timeout tests plus normal-poller activation | Green | Keep the Caddy admin health issue distinct from application activation health |
| 2026-07-31 | First structured iOS harness attempt | Only complete, accepted cycles enter the latency cohort | The first failed harness sample did not produce a complete accepted stage sequence and is retained only as harness/setup evidence | Bounded harness outcome; no raw result or device log retained | Non-cohort evidence | Exclude it from counts and latency summaries; repeat clean cycles |
| 2026-07-31 | Android broad harness attempt | A broad harness deadline does not identify product transport or render latency | The broad Android harness timed out without yielding a complete attributable timing cycle | Bounded harness outcome; no raw hierarchy, screenshot, or device log retained | Harness-only evidence | Draw no latency conclusion; use the narrow structured cohort |
| 2026-07-31 | Android split-runtime exactness | An exact debug APK is not accepted as an exact runnable Mob build until its separately deployed BEAM tree also matches | The reviewed APK was intact, but five allowlisted app BEAMs differed from exact `cc37fd78`; a bounded boot classification was `casein_mob` / `start` / `undef`. The canonical single-device filesystem deploy with the required Android bundle ID made all five digests exact and restored a live foreground process without clearing app or profile data | APK signature/hash and allowlisted BEAM digest checks; fixed-category boot classifier only | Recovered deployment skew | Require both APK provenance and an app-BEAM manifest in future Android exactness gates; never treat a standalone debug APK reinstall as a full Mob deploy |
| 2026-07-31 | Android post-repair timing canary | A complete cold feed and explicit offline state precede the full cohort | One cold generation painted first cards at 3052.883 ms; transport, join, receive, accept, and render durations were 2147.646, 284.647, 61.131, 0.560, and 64.306 ms. Offline profile status, card-stream status, and stale-warning copy all passed; 9 planned reconnect attempts failed only with `transport_disconnected`. The card-context assertion was excluded from this timing canary because no attributable cached-card branch was reachable; prior physical cached-card read-only proof remains separate | Fixed-schema aggregate and allowlisted UI milestones only | Valid canary / non-cohort | Run the 10-cycle timing/recovery cohort with offline transport/status assertions; do not relabel it as new cached-card-action proof |
| 2026-07-31 | Accepted Coding iPad structured cohort | Complete cold and reconnect generations produce bounded first-card timing with no integrity failures | Cold 10/10 first-card elapsed p95 2259.0 ms; reconnect 10/10 p95 921.399 ms. All malformed, duplicate, repeated-stage, elapsed-regression, generation-cycle-conflict, and snapshot-rejection counts were zero | Fixed-schema aggregate output only; exact app provenance reverified | Green / final | Keep the failed first harness attempt outside the cohort; retain the accepted aggregates only |
| 2026-07-31 | Coding iPad privacy teardown | Exact app provenance remains available without retaining raw collection material | The exact `cc37fd78` signed app was reinstalled and verified in place with saved data preserved; ephemeral in-memory collection artifacts were then destroyed | Signature/package provenance plus aggregate-only record | Green | No raw line, generation, device identifier, or content artifact retained |
| 2026-07-31 | Accepted SM-T390 structured cohort | Complete cold and recovery cycles produce bounded first-card timing with no integrity failures | Cold 10/10 first-card elapsed p95 3395.583 ms; 10/10 recovered first paints had successful-generation p95 2902.425 ms. All malformed, duplicate, repeated-stage, elapsed-regression, generation-cycle-conflict, and snapshot-rejection counts were zero; all 70 failed-outcome markers were expected `transport_disconnected` markers | Fixed-schema aggregate output only; APK and separately deployed BEAM provenance reverified | Green / final | Keep OS association/backoff distinct from the successful connection-generation interval |
| 2026-07-31 | Bounded server-stage correlation | Native first-card tails are compared with the authoritative join path without collecting content | Token-through-join-reply p95 was 120.584/65.828 ms for Android cold/reconnect and 69.443/51.695 ms for iOS cold/reconnect. Snapshot-render p95 stayed between 18.946 and 19.244 ms; all snapshots held 36 cards | Recorder aggregate only; 15/14 Android and 13/10 iOS cold/reconnect joins | Green | Snapshot projection and server hydration are not current optimization targets |
| 2026-07-31 | Snapshot-size sample | Encoded size is measured only in a short, explicitly enabled window | One cold join per platform encoded the same 36-card snapshot to 181,944 bytes; render durations were 14.330 ms on Android and 13.013 ms on iOS | Aggregate size/count/timing only | Green | Sizing was immediately disabled and the recorder cleared |
| 2026-07-31 | Android and server teardown | The accepted evidence remains without disposable driver or recorder state | External Android driver packages were removed, Wi-Fi was restored, the exact app remained foreground with its original UID and data, and server sizing/recording was disabled and cleared | Fixed postflight booleans and exact provenance checks | Green | Preserve installed profiles and exact apps |

## Final connection-timing decomposition — 2026-07-30

The first instrumented runs localized the residual tail to snapshot projection,
not WebSocket transport, token verification, channel join, observer publication,
or native paint. Eager terminal-dependent intervention projection accumulated
across full snapshots, and evidence projection spent 362–532 ms in typical
samples and 7.769 s in one tail sample even though none of the 32 cards declared
evidence. PR #483 made intervention projection pure while retaining exact
target validation at submit and immediately before delivery. PR #485 added an
early return only for canonically absent evidence; nonempty, malformed,
shadowed, or otherwise declared candidates still use the prior fail-closed
authorization and validation path.

These aggregate measurements came from exact combined deploy `2f33061f`.
Small-sample p95 is reported as the observed maximum where `n=3` or `n=4`. No
raw log line, connection generation, unique workspace or origin identifier,
unique hardware identifier or serial, payload, credential, or content was
retained.

| Surface | Sample | Aggregate result | Interpretation |
|---|---:|---|---|
| Server `snapshot_rendered`, Coding iPad | 33 cards, n=4 | p50 19.198 ms; p95/max 23.040 ms | Server projection is not the multi-second owner |
| Server `snapshot_rendered`, SM-T390 cold | 33 cards, n=4 | p50 19.295 ms; p95/max 30.086 ms | Cold projection remains bounded |
| Server `snapshot_rendered`, SM-T390 reconnect | 33 cards, n=4 | p50 19.045 ms; p95/max 21.614 ms | Reconnect projection remains bounded |
| Server observer work | recorded samples | max 1.264 ms | Observer work is below the projection interval |
| SM-T390 client cold | n=3 | connected-to-paint p95 616 ms; join p95 495 ms; render-ready p95 64 ms | The native connected path is below the two-second target |
| SM-T390 client reconnect | n=3 | connected-to-paint p95 492 ms; join p95 360 ms; render-ready p95 74 ms | Reconnected native processing is also below target |
| SM-T390 stage integrity | 3 cold + 3 reconnect | exactly 6 receive, 6 accept, and 6 paint stages; 0 reject, duplicate, crash, or ANR | The measured cycles were complete and deduplicated |
| SM-T390 cold authoritative feed | n=3 | p95 3.175 s | Current cold result misses the three-second target by 175 ms |
| SM-T390 Wi-Fi recovery | measured recovery cycles | p95 10.479 s | Association/backoff, not projection, owns the long recovery tail |
| Coding iPad lifecycle at exact `28123fd4` | 4 cold cycles | 4/4 no-screenshot tests passed; three-cycle checkpoint foreground p50/p95 3.040/3.100 s and authoritative Live 7.480/7.640 s | Canonical profile and authoritative Live remained useful; native client-stage attribution remained unavailable |

The Coding iPad client stages first used Elixir Logger, whose native
stdout/stderr path is redirected to app-private storage. PR #487 routed the
same bounded line through Mob's `mob_nif.log/2`, but Mob implements that call
with dynamic `%s` arguments to `NSLog`. iOS 26+ redacts those dynamic arguments
before they reach Unified Logging, as documented in
[Apple's iOS & iPadOS 26 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes),
while Mob also redirects the unaffected stdout/stderr path before BEAM startup.
Default relay, forced relay, and one bounded console trial therefore yielded
zero marker matches. No private app log, raw device log, connection generation,
or unique device identifier was read or retained. The lifecycle result remains
valid, but it does not prove which client interval owns the
authoritative-Live delay.

### Change and evidence chain

| PR | Scope | Status in this record |
|---|---|---|
| #483 | Pure server projection path | Included in exact combined deploy `2f33061f` |
| #484 | Attempted info-level client-stage visibility | Included in the combined deploy; physical iPad collection still could not see the redirected Logger output |
| #485 | Empty-evidence fast path | Included in exact combined deploy `2f33061f` |
| #487 | Exact-head native `NSLog` visibility repair | Review-clean, exact-head gated, merged and activated as `28123fd4`; 4/4 physical cold lifecycle tests passed, but iOS 26+ dynamic-string redaction left zero externally visible markers |
| Mob `f8e296a4` | Dedicated validated native feed-stage logger | Review-clean and merged into the exact Mob base; native tests and both platform checks passed |
| #489 | Bounded post-activation Caddy admin reconciliation | Review-clean, exact-head gated, merged, and present in the deployed descendant |
| #490 / reviewed `d208d681` | Casein structured caller, exact Mob pin, and invalid-envelope fail-safe | Review-clean, exact-head gated, merged, and activated through the normal poller as `cc37fd78`; exact signed in-place device installs completed |

### Privacy-safe native timing and version boundary

Generic Mob logging remains private because it can carry arbitrary application
text. Mob `f8e296a4` instead exposes one dedicated function whose seven fields
are `connection_generation`, `cycle`, `stage`, `duration_ms`, `elapsed_ms`,
`outcome`, and `reason_code`. Native validation requires a canonical 22-character
unpadded generation, allowlisted categorical values, finite nonnegative timing
values with at most three decimal places, bounded signed-32-bit magnitude, and
`duration_ms <= elapsed_ms`. iOS reconstructs those validated fields through a
static `os_log` format with explicit public visibility; Android emits the same
fixed field order. Generic log text is neither promoted nor collected.

The Casein caller records stage-to-stage time in `duration_ms` and cumulative
time from the current connection-generation start in `elapsed_ms`. It skips an
invalid native telemetry envelope without interrupting the authoritative feed,
while unexpected native failures still surface. The collector accepts only the
fixed ordered schema and retains a per-run HMAC surrogate rather than the raw
generation; output contains only allowlisted aggregate categories and timing
summaries.

The snapshot-version rule has the same connection scope. Every newly
established transport resets the accepted version, and its join snapshot is the
baseline for that generation. Within the same connection and origin, a later
snapshot with a missing, non-integer, or lower version is rejected; an equal
version is a legitimate refresh. No accepted version is persisted across
process or server restarts because the server observer version can restart.

### Final structured native cohorts

The exact reviewed code is deployed and installed on both platforms. Coding
iPad and SM-T390 now have complete privacy-safe cold and reconnect/recovery
cohorts. The first failed iOS harness sample remains explicitly non-cohort
evidence. The Android broad harness timeout remains a harness-only result and
supports no product latency conclusion.

| Platform / cycle | Accepted cohort | First-card elapsed p95 | Stage-duration p95 (ms) | Integrity | Status |
|---|---:|---:|---|---|---|
| Coding iPad cold | 10/10 complete generations | 2259.0 ms | `transport_connected` 454.122; `mobile_join_replied` 361.918; `snapshot_received` 15.774; `snapshot_accepted` 0.223; `first_cards_render_ready` 29.622 | 0 malformed, duplicate, repeated, regression, conflict, or rejection | final |
| Coding iPad reconnect | 10/10 complete generations | 921.399 ms | `transport_connected` 470.571; `mobile_join_replied` 388.514; `snapshot_received` 46.123; `snapshot_accepted` 0.419; `first_cards_render_ready` 38.396 | 0 malformed, duplicate, repeated, regression, conflict, or rejection | final |
| SM-T390 cold | 10/10 complete generations | 3395.583 ms | `transport_connected` 2293.572; `mobile_join_replied` 547.290; `snapshot_received` 62.277; `snapshot_accepted` 0.597; `first_cards_render_ready` 92.436 | 0 malformed, duplicate, repeated, regression, conflict, or rejection | final / target miss 395.583 ms |
| SM-T390 reconnect | 10/10 recovered first paints | 2902.425 ms from successful generation start | `transport_connected` 2461.502; `mobile_join_replied` 369.306; `snapshot_received` 64.862; `snapshot_accepted` 0.696; `first_cards_render_ready` 89.601 | 0 malformed, duplicate, repeated, regression, conflict, or rejection; only expected transport disconnects | final |

Across the accepted iOS cohorts, exactly 10 failed-outcome markers were the
expected planned `transport_disconnected` markers. Across the Android recovery
cohort, all 70 failed-outcome markers were also expected
`transport_disconnected` markers; there was no other failed group. Android
reconnect latency is computed only over the ten successful generations that
reached first paint, not from Wi-Fi enable through OS association and retry.
Only complete accepted cycles count. Percentiles use nearest-rank aggregation,
and p95 remains unset for any group with fewer than ten samples. After aggregate
export, ephemeral collection artifacts and disposable driver packages were
destroyed. Raw log lines, connection generations, device identifiers,
credentials, and content are not retained.

### Final server-stage correlation

The recorder was enabled only for bounded aggregate collection against the
exact serving release and was disabled and cleared after each export. It
retained no payloads, card text, identifiers, credentials, or individual event
records.

| Platform / cycle | Joins | Token verification p95 | Join-started duration p95 | Observer snapshot p95 | Snapshot render p95 | Token-through-join-reply p95 |
|---|---:|---:|---:|---:|---:|---:|
| SM-T390 cold | 15 | 3.924 ms | 105.759 ms | 0.258 ms | 18.946 ms | 120.584 ms |
| SM-T390 reconnect | 14 | 3.645 ms | 45.497 ms | 0.213 ms | 18.985 ms | 65.828 ms |
| Coding iPad cold | 13 | 4.109 ms | 52.347 ms | 0.192 ms | 19.244 ms | 69.443 ms |
| Coding iPad reconnect | 10 | 3.335 ms | 30.190 ms | 0.182 ms | 18.987 ms | 51.695 ms |

Every snapshot in those groups contained 36 cards. In a separate one-cold-join
per-platform sizing window, each encoded snapshot was 181,944 bytes and rendered
in 14.330 ms on SM-T390 and 13.013 ms on Coding iPad.

The client and server measurements agree: snapshot receive, validation, render,
observer work, and server hydration are not owners of the remaining latency.
Android's largest interval is native transport establishment at 2.294 s cold
and 2.462 s on successful reconnect generations. No snapshot/hydration
optimization or transport-protocol replacement is justified by this evidence.
The next performance measurement belongs inside that native transport interval:
route readiness, DNS, TCP, TLS, and WebSocket upgrade should be separated before
any reconnect-policy change.

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

The follow-up clarification slice adds the missing authoritative Needs Me source
without inventing a generalized task database. Subsequent narrow reliability
slices keep Android's focused edit buffer stable across stale parent echoes,
prevent a resolved-card snapshot from racing the in-flight delivery result into
a misleading expired state, and replay the latest bounded authoritative snapshot
to late action-screen subscribers. The replay cache is scoped to the exact active
topic and is cleared on final unwatch, disconnect, pairing reset, and origin
switch.

The final physical action used only the disposable role-marked agent target.
Android supplied the one cross-platform completion after iPad independently
proved the same authoritative action path. The server recorded one resolution
and one guarded delivery sequence, while cached/offline state remained read-only.
Same-request replay remains adversarially contract-tested rather than falsely
claimed from a second physical tap that would generate a different request ID.

The final structured timing slice closes the hydration question. Both native
clients accept and paint the versioned snapshot promptly, and bounded server
aggregation places token verification, observer work, snapshot rendering, and
the complete join reply well below the multi-second Android tail. The justified
next performance work is narrower native transport-stage instrumentation, not a
snapshot/hydration rewrite or a change from the existing WebSocket transport.

The Android startup interruption also establishes an operational exactness
boundary: this debug packaging model splits the signed APK from the app-private
BEAM tree. Future exact-install postflight should verify both the APK and a
bounded app-BEAM manifest. No production launcher or startup change is justified
by the recovered deployment skew.

DairyPhone issue #457 remains physically unavailable in this soak. Source review
narrows the unresolved camera-only path to the upstream `mob_scanner` iOS bridge:
the released plugin ignores the requested QR-only format set and selects the
first metadata object. Casein's shared compact parser already accepts the bounded
scanner-edge artifacts covered by its cross-platform vectors. No speculative
dependency fork or weakened parser was added without a connected DairyPhone
reproduction; the issue remains an explicitly scoped external physical blocker.
