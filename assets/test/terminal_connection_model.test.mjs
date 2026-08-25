// The terminal connection model contract.
//
// These invariants prove that the extracted model is internally consistent.
// They do not prove that wiring it into the real viewer preserved behavior;
// that is verified separately against a worktree-local Casein viewer.

import assert from "node:assert/strict"
import test from "node:test"

import {
  CONNECTION_EFFECTS_BY_PHASE,
  CONNECTION_PHASES,
  CONNECTION_TIMERS_BY_PHASE,
  ConnectionEffect,
  ConnectionEvent,
  ConnectionPhase,
  ConnectionTimer,
  INITIAL_CONNECTION_PHASE,
  LIVE_CONNECTION_TIMERS,
  TERMINAL_CONNECTION_PHASES,
  transitionTerminalConnection
} from "../js/terminal_connection_model.mjs"

const EVENTS = [
  {type: ConnectionEvent.HOOK_MOUNTED},
  {type: ConnectionEvent.FRAME_ATTACHED},
  {type: ConnectionEvent.FRAME_PROTOCOL_RESYNC, reason: "frame_seq_gap"},
  {type: ConnectionEvent.SIZE_AUTHORITY_GAINED},
  {type: ConnectionEvent.SIZE_AUTHORITY_LOST},
  {type: ConnectionEvent.DOCUMENT_LIFECYCLE_RESUMED, lifecycleType: "pageshow"},
  {type: ConnectionEvent.SURFACE_REFIT_REQUESTED, reason: "tabs_resized"},
  {type: ConnectionEvent.LIVEVIEW_RECONNECTED},
  {type: ConnectionEvent.TIMER_REQUESTED, timer: ConnectionTimer.LAYOUT, delay: 75},
  {type: ConnectionEvent.TIMER_CANCEL_REQUESTED, timer: ConnectionTimer.LAYOUT},
  {type: ConnectionEvent.HOOK_DESTROYED}
]

const RESYNC_EVENTS = [
  [ConnectionEvent.FRAME_PROTOCOL_RESYNC, {reason: "frame_seq_gap"}, "frame_seq_gap"],
  [ConnectionEvent.SIZE_AUTHORITY_GAINED, {}, "became_size_authority"],
  [ConnectionEvent.SIZE_AUTHORITY_LOST, {}, "became_size_observer"],
  [ConnectionEvent.DOCUMENT_LIFECYCLE_RESUMED, {lifecycleType: "pageshow"}, "lifecycle:pageshow"],
  [ConnectionEvent.SURFACE_REFIT_REQUESTED, {reason: "tabs_resized"}, "tabs_resized"],
  [ConnectionEvent.LIVEVIEW_RECONNECTED, {}, "liveview_reconnected"]
]

test("I1: no phase emits an effect that phase cannot produce", () => {
  for (const phase of CONNECTION_PHASES) {
    const allowed = new Set(CONNECTION_EFFECTS_BY_PHASE[phase])

    for (const event of EVENTS) {
      const result = transitionTerminalConnection(phase, event)
      for (const effect of result.effects) {
        assert.ok(allowed.has(effect.type), `${phase}/${event.type} emitted illegal ${effect.type}`)
      }
    }
  }
})

test("I2: every phase is reachable from detached", () => {
  const reached = new Set([INITIAL_CONNECTION_PHASE])
  const queue = [INITIAL_CONNECTION_PHASE]

  while (queue.length > 0) {
    const phase = queue.shift()
    for (const event of EVENTS) {
      const next = transitionTerminalConnection(phase, event).phase
      if (!reached.has(next)) {
        reached.add(next)
        queue.push(next)
      }
    }
  }

  assert.deepEqual([...reached].sort(), [...CONNECTION_PHASES].sort())
})

test("I3: every non-terminal phase can escape to a different phase", () => {
  const terminal = new Set(TERMINAL_CONNECTION_PHASES)

  for (const phase of CONNECTION_PHASES.filter((candidate) => !terminal.has(candidate))) {
    assert.ok(
      EVENTS.some((event) => transitionTerminalConnection(phase, event).phase !== phase),
      `${phase} has no escaping transition`
    )
  }
})

test("I4: a transition cancels every timer owned only by its predecessor", () => {
  for (const phase of CONNECTION_PHASES) {
    for (const event of EVENTS) {
      const result = transitionTerminalConnection(phase, event)
      if (result.phase === phase) continue

      const successorTimers = new Set(CONNECTION_TIMERS_BY_PHASE[result.phase])
      const expected = CONNECTION_TIMERS_BY_PHASE[phase].filter((timer) => !successorTimers.has(timer))
      const cancelled = result.effects
        .filter((effect) => effect.type === ConnectionEffect.CANCEL_TIMER)
        .map((effect) => effect.timer)

      assert.deepEqual(cancelled.sort(), expected.sort(), `${phase}/${event.type} leaked a timer`)
    }
  }
})

test("live phases own the five legacy hook timers; terminal phases own none", () => {
  const live = new Set([
    ConnectionPhase.ATTACHING,
    ConnectionPhase.ATTACHED,
    ConnectionPhase.REATTACHING
  ])

  assert.deepEqual(
    [...LIVE_CONNECTION_TIMERS],
    [
      ConnectionTimer.AUTHORITY_LATCH,
      ConnectionTimer.FIT_REHEAL,
      ConnectionTimer.LAYOUT,
      ConnectionTimer.LONGPRESS,
      ConnectionTimer.SHRINK_CONFIRM
    ]
  )

  for (const phase of CONNECTION_PHASES) {
    if (live.has(phase)) {
      assert.deepEqual(CONNECTION_TIMERS_BY_PHASE[phase], LIVE_CONNECTION_TIMERS, `${phase} must own the five timers`)
    } else {
      assert.deepEqual(CONNECTION_TIMERS_BY_PHASE[phase], [], `${phase} must not own a timer`)
    }
  }
})

test("destroying a live phase cancels every owned timer", () => {
  for (const phase of [ConnectionPhase.ATTACHING, ConnectionPhase.ATTACHED, ConnectionPhase.REATTACHING]) {
    const result = transitionTerminalConnection(phase, {type: ConnectionEvent.HOOK_DESTROYED})
    assert.equal(result.phase, ConnectionPhase.DISPOSED)
    assert.deepEqual(
      result.effects,
      LIVE_CONNECTION_TIMERS.map((timer) => ({type: ConnectionEffect.CANCEL_TIMER, timer}))
    )
  }
})

test("a phase may start or cancel only the timers it owns", () => {
  for (const phase of CONNECTION_PHASES) {
    const owned = new Set(CONNECTION_TIMERS_BY_PHASE[phase])

    for (const timer of LIVE_CONNECTION_TIMERS) {
      const started = transitionTerminalConnection(phase, {
        type: ConnectionEvent.TIMER_REQUESTED,
        timer,
        delay: 40
      })
      const cancelled = transitionTerminalConnection(phase, {
        type: ConnectionEvent.TIMER_CANCEL_REQUESTED,
        timer
      })

      const startEffects = started.effects.filter((effect) => effect.type === ConnectionEffect.START_TIMER)
      const cancelEffects = cancelled.effects.filter((effect) => effect.type === ConnectionEffect.CANCEL_TIMER)

      if (owned.has(timer)) {
        assert.deepEqual(startEffects, [{type: ConnectionEffect.START_TIMER, timer, delay: 40}])
        assert.deepEqual(started.effects[0], {type: ConnectionEffect.CANCEL_TIMER, timer})
        assert.deepEqual(cancelEffects, [{type: ConnectionEffect.CANCEL_TIMER, timer}])
      } else {
        assert.deepEqual(startEffects, [])
        assert.deepEqual(cancelEffects, [])
      }
    }
  }
})

test("an unknown or missing timer request emits nothing", () => {
  const phase = ConnectionPhase.ATTACHED

  assert.deepEqual(
    transitionTerminalConnection(phase, {type: ConnectionEvent.TIMER_REQUESTED, timer: "not_a_timer"}).effects,
    []
  )
  assert.deepEqual(
    transitionTerminalConnection(phase, {type: ConnectionEvent.TIMER_REQUESTED}).effects,
    []
  )
  assert.deepEqual(
    transitionTerminalConnection(phase, {type: ConnectionEvent.TIMER_CANCEL_REQUESTED}).effects,
    []
  )
})

test("the six resync events preserve the current response in every phase", () => {
  for (const phase of CONNECTION_PHASES) {
    for (const [type, detail, reason] of RESYNC_EVENTS) {
      const result = transitionTerminalConnection(phase, {type, ...detail})
      const requests = result.effects.filter((effect) => effect.type === ConnectionEffect.REQUEST_RESYNC)

      if (phase === ConnectionPhase.DETACHED || phase === ConnectionPhase.DISPOSED) {
        assert.deepEqual(requests, [], `${phase}/${type} must not touch an unattached hook`)
      } else {
        assert.deepEqual(requests, [{type: ConnectionEffect.REQUEST_RESYNC, reason}])
      }
    }
  }
})

test("only attachment-loss events change an active attachment phase", () => {
  const ordinaryRefits = [
    ConnectionEvent.SIZE_AUTHORITY_GAINED,
    ConnectionEvent.SIZE_AUTHORITY_LOST,
    ConnectionEvent.DOCUMENT_LIFECYCLE_RESUMED,
    ConnectionEvent.SURFACE_REFIT_REQUESTED,
    ConnectionEvent.TIMER_REQUESTED,
    ConnectionEvent.TIMER_CANCEL_REQUESTED
  ]

  for (const type of ordinaryRefits) {
    assert.equal(
      transitionTerminalConnection(ConnectionPhase.ATTACHED, {
        type,
        timer: ConnectionTimer.LAYOUT,
        delay: 75
      }).phase,
      ConnectionPhase.ATTACHED
    )
  }

  assert.equal(
    transitionTerminalConnection(ConnectionPhase.ATTACHED, {
      type: ConnectionEvent.FRAME_PROTOCOL_RESYNC,
      reason: "frame_seq_gap"
    }).phase,
    ConnectionPhase.ATTACHING
  )
  assert.equal(
    transitionTerminalConnection(ConnectionPhase.ATTACHED, {
      type: ConnectionEvent.LIVEVIEW_RECONNECTED
    }).phase,
    ConnectionPhase.REATTACHING
  )
})
