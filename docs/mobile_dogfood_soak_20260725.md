# Mobile companion dogfood soak — 2026-07-25

Status: complete

## Scope and invariants

This is a bounded real-world soak of the deployed mobile companion across
Devbox and Local Mac. Cached or inactive-origin cards remain read-only; every
mutation requires explicit trusted-origin activation and authoritative refresh;
intervention targets only a persisted `agent` pane; evidence and input remain
bounded and sanitized; the app keeps one explicit active origin with no silent
failover.

## Environment

- Soak base: `6277518406aedd93762d77e3611697076ca261c0`
- Android: Samsung SM-T390
- iOS: Coding iPad `00008030-000209510ED0C02E`
- Known external gap: APNs/FCM provider delivery is not treated as receipt
  evidence.

## Observations

| Time (UTC) | Scenario | Expected | Observed / evidence | Classification | Severity | Disposition |
|---|---|---|---|---|---|---|
| 23:18 | Normal poller uptake | Devbox builds exact `origin/master` through the clean gate | Deploy status reported target `62775184…` in the gate phase; timer active | Expected lifecycle | — | Monitored without interruption |
| 23:25 | Local Mac origin readiness | LAN desktop host is reachable | Loopback and `192.168.1.72:57585` returned the expected authenticated boundary; runtime ready | Green | — | Used as the Local Mac origin |
| 23:27 | Local Mac cockpit start | Menubar-authenticated cockpit opens | Mac UI was locked; the LAN host remained healthy | Environment limitation | — | Continued API and device lanes |
| 23:33 | Local Mac authenticated work | A normal one-time claim creates resumable work | Claim exchange redirected to a clean URL and created scratch session `casein___scratch___u-desktop-l6hjyon5` | Green | — | Local Mac has real resumable work |
| 23:34 | Agent Pair on installed Mac bundle | Scratch work gains a role-marked agent pane | Installed bundle revision `unknown` returned `workspace_root_unavailable`; current master already covers safe scratch roots | Stale installed build | Medium, already fixed upstream | Refresh the Mac bundle; do not duplicate the upstream fix |
| 23:26 | Devbox deploy/restart | Current master deploy proceeds without disturbing other gates | Poller waited on the shared coverage lock and later activated normally | Expected contention | — | Did not cancel another run |
| 23:28 | Clean signed iOS build | Exact-base signed app links | Link failed on missing Mob notification/deep-link bridge symbols from `AppDelegate.o` | Product defect | High | Fixed in PR #396 |
| 23:30 | Real authoritative intervention setup | A role-marked agent task produces a real attention card | Operator `%476`, agent `%477`, verify `%478`; real `run.approval_requested` produced card `needs_review:…:dogfood-soak-20260725-a` | Green | — | Used for Android intervention |
| 23:31 | Intervention projection | State, phase, availability, freshness, and excerpt are bounded and distinct | `needs_attention` / `review` / `live`; excerpt 225 chars; target role `agent`; absent evidence degraded cleanly | Green | — | Preserved |
| 23:34 | Android cold route and degraded origins | Killed-app route restores exact context; inactive/offline origin cannot mutate | SM-T390 opened the authoritative Devbox card; Local Mac/Devbox switching, Devbox offline read-only state, and recovery passed | Green physical | — | Preserve as regression evidence |
| 23:34 | Android follow-up entry | Automation enters exact authorized text | Samsung ADB/IME injection reordered one character; agent did not tap Send | Test automation limitation | — | Required byte-exact draft before send |
| 23:36 | Push readiness | Readiness distinguishes lifecycle from provider setup | APNs runtime ready but prior provider response `BadDeviceToken`; FCM reports `no_project_id` | External configuration | — | No delivery claim; no push rewrite |
| 23:37 | Privacy audit/log scan | No reply body, excerpt, credential, or terminal output leaks | Eight `mobile.*` audit rows and service logs had zero reply/credential/output matches | Green | — | Repeated after intervention |
| 23:43 | Physical Android follow-up across deploy restart | A stale authoritative target fails closed and explains recovery | Byte-exact `Continue.` tap returned `card not found`; all three pane hashes and occurrence counts remained unchanged because the server restarted between card render and action | Safe product defect | Medium | Expire the screen, remove actions, and require Action Center refresh |
| 23:46 | Exact-head iOS compatibility build | Pinned Mob links without losing warm/background routing | `4a72f437` linked, packaged, provisioned, and codesigned arm64; full native suite 136/136; direct screen delivery is bounded to 64 KiB with cold fallback | Fixed product defect | High | Merge after exact-head gate |
| 23:47 | Current-head iPad install | Signed app installs and exercises lifecycle/layout | CoreDevice 4016; no USB/libimobiledevice enumeration | External device blocker | — | No current-head physical iOS claims |
| 23:54 | Android privacy/crash follow-up | Failed stale action produces no sensitive or unstable behavior | Zero FATAL/ANR and zero reply, excerpt, bearer/JWT, or token-like matches in app logs; PWA escalation reached expected Google sign-in | Green physical | — | Preserve |
| 00:05 | Fresh authoritative Android intervention | One short response reaches only the exact role-marked agent pane | Physical SM-T390 sent byte-exact `Continue.` once; UI returned `Action accepted`; `%477` changed and contained one occurrence while operator `%476` and verify `%478` were byte-for-byte unchanged | Green physical | — | Preserve |
| 00:07 | Idempotent intervention replay | Reusing the exact request id cannot deliver twice | Durable accepted Android outcome replayed with `idempotent: true`; `%477` hash and one-occurrence count remained unchanged; no extra action audit was emitted | Green security | — | Preserve |
| 00:08 | Post-intervention audit/privacy | Audit is useful without retaining content | Audit recorded origin, platform, device link, card, outcome, and `target_role=agent`; zero reply-body and credential-key matches; Approve/Request changes/Deny remained available | Green privacy/lifecycle | — | Preserve |
| 00:09 | Older Android review layout | Header should wrap its title and Back touch target while leaving most of the canvas for content | Full-device SM-T390 captures showed 511 px of purple chrome: ~40% of 1280 px portrait and ~64% of 800 px landscape; title was displaced and Back stretched nearly full width | Product defect | Medium | Reproduce from killed launch and fix without device-size hacks |
| 00:12 | Physical Evidence Handoff | Live card shows bounded evidence and exact authenticated escalations | SM-T390 showed 2 contained files, 3-line diff, PNG metadata (33,949 bytes), `Devbox · live` freshness, and diff/preview/artifacts actions; each exact embedded PWA route reached the expected milc devbox Google-auth boundary | Green physical | — | No review mutation; preserve |
| 00:24 | Completed/stale cleanup after origin reconnect | Cards missing from the authoritative origin disappear instead of remaining actionable | After reconnecting to the newly deployed Devbox server, Action Center contained zero old dogfood-card, review-count, or live-card markers | Green physical | — | Preserve; no cached card authorized a mutation |
| 00:28 | Compact-header contract | Header controls remain intrinsic-width on narrow screens | Mob buttons default to `fill_width: true`; compact Back/Pair/overflow buttons had inherited that default and collapsed the weighted title. Explicit `fill_width: false` fixes the shared layout contract without platform renderer or device-size changes; focused screen tests passed 88/88 | Product defect | Medium | Fix prepared; exact-head physical validation recorded below |
| 00:35 | Final native verification | The shared fixes retain the mobile contracts | Full native suite passed 137/137; the changed stale-action screen passed strict Credo and 11/11 focused tests | Green automated | — | Preserve |
| 00:39 | Exact-head Android layout | Compact controls leave the canvas usable on the older tablet | Exact runtime `8dd7b5ff…` on physical SM-T390 passed Action Center, pairing, keyboard, and session-detail layouts in portrait and landscape; Back, touch, and scroll behavior remained usable | Fixed product defect | Medium | Header fix validated physically |
| 00:41 | Warm and killed Android lifecycle | Profiles and explicit origin survive process lifecycle | Warm resume retained Devbox context; killed launch retained both saved hosts and explicit Devbox activation with no silent failover. Cold BEAM startup took about 9.9 seconds before content appeared | Green with low-severity latency observation | Low | No speculative startup rewrite |
| 00:42 | Exact-head Android privacy/crash scan | Lifecycle and layout work leaks no sensitive content | Logcat contained zero FATAL/ANR, BEAM crash/error, reply-body, bearer, JWT-like, or access-token-value matches | Green physical | — | Preserve |

## Findings

- High, fixed: pinned Mob lacked two AppDelegate bridge callbacks, preventing a
  clean signed iOS link.
- Medium, reproducible: a deploy/restart can invalidate an in-memory card
  between render and action. Mutation correctly failed closed, but the raw
  `card not found` message invited a pointless retry.
- Medium, reproducible: compact header buttons inherited full-width behavior,
  collapsing titles and consuming most of an older Android screen. The fix is
  shared declarative layout data, not an Android renderer special case.
- Medium environment gap: the installed Local Mac bundle predates current
  scratch-root Agent Pair support, which is already fixed on master.
- External: the iPad transport is unavailable; APNs has a bad device token and
  FCM has no project id. No physical receipt or current-head iPad lifecycle
  claim is made.
- Low observation, unchanged: killed Android startup can remain on the splash
  surface for roughly ten seconds while the BEAM bundle starts. It recovered
  without a crash and did not justify a speculative startup rewrite in this
  bounded soak.
