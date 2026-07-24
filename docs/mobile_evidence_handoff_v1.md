# Mobile intervention proof and Evidence Handoff v1

Status: implementation complete; verification in progress
Base at implementation start: `ff77f6fb93c79cceedd7503735f5ff8afb699571`

## Product outcome

From Android or iPad, a paired user can understand why a role-marked agent
needs attention, inspect a bounded server-authored evidence summary, send one
short reply to that exact agent pane, and escalate to the exact authenticated
PWA surface for deeper work.

## Invariants

- One explicit active origin connection; inactive-origin cache is read-only.
- Cached cards never authorize a mutation.
- Unknown origins never activate or retarget a request.
- Every intervention reloads the authoritative card and revalidates the exact
  workspace, tmux session, pane id, and persisted `role=agent` marker.
- Locators are navigation data, never authorization.
- Evidence is bounded, sanitized, workspace-contained, and server projected.
- Push, telemetry, and caches never contain credentials, reply bodies, raw
  terminal logs, unbounded diffs, or sensitive artifact contents.

## Work slices

1. Ground a real Devbox `needs_attention` card on a dedicated `agent_pair`
   session and validate the physical intervention loop. Recreate the card after
   any deploy because authoritative refresh must reject a locator whose pane
   disappeared.
2. Diagnose and fix the iPad landscape/full-canvas defect using device evidence.
3. Add a versioned Evidence Handoff projection and compact native rendering.
4. Run adversarial/full tests, physical regression checks, exact-head PR gates,
   merge, and normal poller deployment.

## Grounded device evidence

- Android SM-T390 delivered one short follow-up from authoritative card `h`.
  The response appeared once in role-marked agent pane `%484` and zero times in
  operator `%483` and verify `%485`. The durable outcome was accepted, the
  audit record contained metadata only (no message or output), and replaying the
  same request id returned `idempotent=true` without another pane write.
- The first Android attempt exposed a real same-origin reconnect race: stale
  client join metadata suppressed joins on a fresh transport. The rejected
  push never left the device. `SessionClient` now resets join statuses and
  rejoins every subscribed topic whenever a new transport connects.
- A credential was exposed to local diagnostic output during one device probe.
  That device-link credential was immediately revoked, the app was force
  stopped, and the device was securely re-paired through a mode-600 temporary
  link that was deleted after use.
- iPad killed-app routing and background/foreground restoration opened the
  authoritative card with bounded output and an explicit agent target. Portrait
  and landscape filled the scene canvas. The final signed run exceeded five
  minutes without a new crash, CPU, disk, OpenSSL, RAND, or EPMD error report.
- APNs (`BadDeviceToken`) and FCM (`NOT_FOUND`, no Firebase app configuration)
  blocked real external push delivery. Supported product deep links exercised
  the same warm/cold routing without claiming notification delivery.

## Physical limitations

- CoreDevice reported success for warm `openURL` on the iPadOS 27 beta but did
  not deliver a scene callback; killed-app payload routing and background
  restoration were proven instead.
- The connected iPad did not expose automated resizable-window management or
  accessibility keyboard-focus commands. Full-scene portrait/landscape and
  system windowed presentation were inspected, but automated split-view
  geometry and keyboard-focus assertions remain unavailable on this device.
- Embedded iOS EPMD remains stable after suspension but its listener does not
  recover until a cold restart. The product websocket and UI do reconnect.

## Platform ownership

- Android lane: `native/devide_mob/android/**`, SM-T390 build/install/logcat and
  lifecycle evidence.
- iOS lane: `native/devide_mob/ios/**`, signed iPad build/install/logs, lifecycle,
  and landscape evidence.
- Lead lane: all shared Elixir contracts, server actions, shared Mob state/UI,
  migrations, PR scope, and integration decisions.

Generated Mob bridge artifacts and shared dependency/bootstrap operations are
serialized between platform lanes.
