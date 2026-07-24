import assert from "node:assert/strict"
import test from "node:test"

import {
  HOLD_MS,
  isPreferredWakeLockSurface,
  isWakeLockSupported,
  shouldAcquireWakeLock,
  shouldHandleWakeLockPing,
  wakeLockPingPlan,
  wakeLockVisibilityDecision,
} from "../js/wake_lock_retry.mjs"

test("isWakeLockSupported requires a navigator with wakeLock", () => {
  assert.equal(isWakeLockSupported(undefined), false)
  assert.equal(isWakeLockSupported(null), false)
  assert.equal(isWakeLockSupported({}), false)
  assert.equal(isWakeLockSupported({wakeLock: {}}), true)
})

test("isPreferredWakeLockSurface is mobile/standalone only", () => {
  assert.equal(isPreferredWakeLockSurface({}), false)
  assert.equal(isPreferredWakeLockSurface({coarsePointer: false, standalone: false}), false)
  assert.equal(isPreferredWakeLockSurface({coarsePointer: true}), true)
  assert.equal(isPreferredWakeLockSurface({standalone: true}), true)
  assert.equal(isPreferredWakeLockSurface({coarsePointer: true, standalone: true}), true)
})

test("shouldHandleWakeLockPing requires support and preferred surface", () => {
  assert.equal(shouldHandleWakeLockPing({supported: false, preferredSurface: true}), false)
  assert.equal(shouldHandleWakeLockPing({supported: true, preferredSurface: false}), false)
  assert.equal(shouldHandleWakeLockPing({supported: true, preferredSurface: true}), true)
})

test("shouldAcquireWakeLock skips when a sentinel is held or the tab is hidden", () => {
  assert.equal(shouldAcquireWakeLock({hasSentinel: false, visibilityState: "visible"}), true)
  assert.equal(shouldAcquireWakeLock({hasSentinel: true, visibilityState: "visible"}), false)
  assert.equal(shouldAcquireWakeLock({hasSentinel: false, visibilityState: "hidden"}), false)
  assert.equal(shouldAcquireWakeLock({hasSentinel: false, visibilityState: "prerender"}), false)
})

test("wakeLockVisibilityDecision re-acquires on return within the hold window", () => {
  const lastPingAt = 1_000_000
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "visible",
      lastPingAt,
      now: lastPingAt + HOLD_MS - 1,
    }),
    "acquire",
  )
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "visible",
      lastPingAt,
      now: lastPingAt + HOLD_MS,
    }),
    "none",
  )
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "visible",
      lastPingAt,
      now: lastPingAt + HOLD_MS + 5_000,
    }),
    "none",
  )
})

test("wakeLockVisibilityDecision releases whenever the tab is not visible", () => {
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "hidden",
      lastPingAt: Date.now(),
      now: Date.now(),
    }),
    "release",
  )
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "prerender",
      lastPingAt: 0,
      now: 0,
    }),
    "release",
  )
})

test("wakeLockVisibilityDecision tolerates non-finite lastPingAt", () => {
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "visible",
      lastPingAt: NaN,
      now: 1000,
    }),
    "none",
  )
})

test("wakeLockVisibilityDecision honours a custom holdMs", () => {
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "visible",
      lastPingAt: 100,
      now: 150,
      holdMs: 40,
    }),
    "none",
  )
  assert.equal(
    wakeLockVisibilityDecision({
      visibilityState: "visible",
      lastPingAt: 100,
      now: 130,
      holdMs: 40,
    }),
    "acquire",
  )
})

test("wakeLockPingPlan is a no-op when unsupported or not preferred", () => {
  assert.deepEqual(
    wakeLockPingPlan({supported: false, preferredSurface: true}),
    {act: false, acquire: false, scheduleReleaseMs: null},
  )
  assert.deepEqual(
    wakeLockPingPlan({supported: true, preferredSurface: false}),
    {act: false, acquire: false, scheduleReleaseMs: null},
  )
})

test("wakeLockPingPlan arms release timer and acquires when visible without sentinel", () => {
  assert.deepEqual(
    wakeLockPingPlan({
      supported: true,
      preferredSurface: true,
      hasSentinel: false,
      visibilityState: "visible",
    }),
    {act: true, acquire: true, scheduleReleaseMs: HOLD_MS},
  )
  assert.deepEqual(
    wakeLockPingPlan({
      supported: true,
      preferredSurface: true,
      hasSentinel: true,
      visibilityState: "visible",
    }),
    {act: true, acquire: false, scheduleReleaseMs: HOLD_MS},
  )
  assert.deepEqual(
    wakeLockPingPlan({
      supported: true,
      preferredSurface: true,
      hasSentinel: false,
      visibilityState: "hidden",
    }),
    {act: true, acquire: false, scheduleReleaseMs: HOLD_MS},
  )
})

test("HOLD_MS is 45 seconds", () => {
  assert.equal(HOLD_MS, 45_000)
})
