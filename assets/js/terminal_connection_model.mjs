// The terminal connection/attachment decision, as one pure state machine.
//
// The LiveView hook used to send every recovery signal through one
// requestTerminalResync(hook, freeTextReason) helper. That preserved recovery,
// but erased whether the trigger was attachment loss, a sizing-role change, a
// document lifecycle edge, or an explicit surface refit. This module keeps
// those inputs typed while deliberately preserving the current response.
//
// It owns no browser, LiveView, Ghostty, DOM, clock, or timer. The hook executes
// the returned effects. The five legacy hook timers are phase-owned: a start is
// legal only while the successor owns that timer, and a phase change cancels
// every timer the predecessor owned exclusively.

export const ConnectionPhase = Object.freeze({
  DETACHED: "detached",
  ATTACHING: "attaching",
  ATTACHED: "attached",
  REATTACHING: "reattaching",
  DISPOSED: "disposed"
})

export const ConnectionEvent = Object.freeze({
  HOOK_MOUNTED: "hook_mounted",
  FRAME_ATTACHED: "frame_attached",
  FRAME_PROTOCOL_RESYNC: "frame_protocol_resync",
  SIZE_AUTHORITY_GAINED: "size_authority_gained",
  SIZE_AUTHORITY_LOST: "size_authority_lost",
  DOCUMENT_LIFECYCLE_RESUMED: "document_lifecycle_resumed",
  SURFACE_REFIT_REQUESTED: "surface_refit_requested",
  LIVEVIEW_RECONNECTED: "liveview_reconnected",
  TIMER_REQUESTED: "timer_requested",
  TIMER_CANCEL_REQUESTED: "timer_cancel_requested",
  HOOK_DESTROYED: "hook_destroyed"
})

export const ConnectionEffect = Object.freeze({
  REQUEST_RESYNC: "request_resync",
  START_TIMER: "start_timer",
  CANCEL_TIMER: "cancel_timer"
})

export const ConnectionTimer = Object.freeze({
  AUTHORITY_LATCH: "authority_latch",
  FIT_REHEAL: "fit_reheal",
  LAYOUT: "layout",
  LONGPRESS: "longpress",
  SHRINK_CONFIRM: "shrink_confirm"
})

export const INITIAL_CONNECTION_PHASE = ConnectionPhase.DETACHED

export const CONNECTION_PHASES = Object.freeze(Object.values(ConnectionPhase))
export const TERMINAL_CONNECTION_PHASES = Object.freeze([ConnectionPhase.DISPOSED])

export const LIVE_CONNECTION_TIMERS = Object.freeze([
  ConnectionTimer.AUTHORITY_LATCH,
  ConnectionTimer.FIT_REHEAL,
  ConnectionTimer.LAYOUT,
  ConnectionTimer.LONGPRESS,
  ConnectionTimer.SHRINK_CONFIRM
])

const NO_TIMERS = Object.freeze([])

export const CONNECTION_TIMERS_BY_PHASE = Object.freeze({
  [ConnectionPhase.DETACHED]: NO_TIMERS,
  [ConnectionPhase.ATTACHING]: LIVE_CONNECTION_TIMERS,
  [ConnectionPhase.ATTACHED]: LIVE_CONNECTION_TIMERS,
  [ConnectionPhase.REATTACHING]: LIVE_CONNECTION_TIMERS,
  [ConnectionPhase.DISPOSED]: NO_TIMERS
})

const LIVE_EFFECTS = Object.freeze([
  ConnectionEffect.REQUEST_RESYNC,
  ConnectionEffect.START_TIMER,
  ConnectionEffect.CANCEL_TIMER
])

export const CONNECTION_EFFECTS_BY_PHASE = Object.freeze({
  [ConnectionPhase.DETACHED]: Object.freeze([]),
  [ConnectionPhase.ATTACHING]: LIVE_EFFECTS,
  [ConnectionPhase.ATTACHED]: LIVE_EFFECTS,
  [ConnectionPhase.REATTACHING]: LIVE_EFFECTS,
  [ConnectionPhase.DISPOSED]: Object.freeze([])
})

function resync(reason) {
  return {type: ConnectionEffect.REQUEST_RESYNC, reason}
}

function ownsTimer(phase, timer) {
  return (CONNECTION_TIMERS_BY_PHASE[phase] || []).includes(timer)
}

function nextPhaseFor(phase, eventType) {
  if (eventType === ConnectionEvent.HOOK_DESTROYED) return ConnectionPhase.DISPOSED
  if (phase === ConnectionPhase.DISPOSED) return phase

  switch (eventType) {
    case ConnectionEvent.HOOK_MOUNTED:
      return phase === ConnectionPhase.DETACHED ? ConnectionPhase.ATTACHING : phase
    case ConnectionEvent.FRAME_ATTACHED:
      return phase === ConnectionPhase.ATTACHING || phase === ConnectionPhase.REATTACHING
        ? ConnectionPhase.ATTACHED
        : phase
    case ConnectionEvent.FRAME_PROTOCOL_RESYNC:
      return phase === ConnectionPhase.DETACHED ? phase : ConnectionPhase.ATTACHING
    case ConnectionEvent.LIVEVIEW_RECONNECTED:
      return phase === ConnectionPhase.DETACHED ? phase : ConnectionPhase.REATTACHING
    default:
      return phase
  }
}

function resyncEffectFor(phase, event = {}) {
  if (
    phase === ConnectionPhase.DETACHED ||
    phase === ConnectionPhase.DISPOSED
  ) return null

  switch (event.type) {
    case ConnectionEvent.FRAME_PROTOCOL_RESYNC:
      return resync(event.reason || "frame_protocol_resync")
    case ConnectionEvent.SIZE_AUTHORITY_GAINED:
      return resync("became_size_authority")
    case ConnectionEvent.SIZE_AUTHORITY_LOST:
      return resync("became_size_observer")
    case ConnectionEvent.DOCUMENT_LIFECYCLE_RESUMED:
      return resync(`lifecycle:${event.lifecycleType || "unknown"}`)
    case ConnectionEvent.SURFACE_REFIT_REQUESTED:
      return resync(event.reason || "terminal_surface_refit")
    case ConnectionEvent.LIVEVIEW_RECONNECTED:
      return resync("liveview_reconnected")
    default:
      return null
  }
}

function cancelledTimerEffects(phase, nextPhase) {
  if (phase === nextPhase) return []

  const nextTimers = new Set(CONNECTION_TIMERS_BY_PHASE[nextPhase] || [])
  return (CONNECTION_TIMERS_BY_PHASE[phase] || [])
    .filter((timer) => !nextTimers.has(timer))
    .map((timer) => ({type: ConnectionEffect.CANCEL_TIMER, timer}))
}

function requestedTimerEffects(phase, event = {}) {
  const timer = event.timer
  if (!timer || !ownsTimer(phase, timer)) return []

  if (event.type === ConnectionEvent.TIMER_REQUESTED) {
    const start = {type: ConnectionEffect.START_TIMER, timer}
    if (event.delay != null) start.delay = event.delay
    return [{type: ConnectionEffect.CANCEL_TIMER, timer}, start]
  }

  if (event.type === ConnectionEvent.TIMER_CANCEL_REQUESTED) {
    return [{type: ConnectionEffect.CANCEL_TIMER, timer}]
  }

  return []
}

/**
 * @param {string} phase one of ConnectionPhase
 * @param {{type: string, reason?: string, lifecycleType?: string, timer?: string, delay?: number}} event
 * @returns {{phase: string, effects: Array<{type: string, reason?: string, timer?: string, delay?: number}>}}
 */
export function transitionTerminalConnection(phase = INITIAL_CONNECTION_PHASE, event = {}) {
  if (!CONNECTION_PHASES.includes(phase)) {
    throw new TypeError(`unknown terminal connection phase: ${phase}`)
  }

  const nextPhase = nextPhaseFor(phase, event.type)
  const effects = cancelledTimerEffects(phase, nextPhase)
  const resyncEffect = resyncEffectFor(phase, event)
  if (resyncEffect) effects.push(resyncEffect)
  effects.push(...requestedTimerEffects(nextPhase, event))

  return {phase: nextPhase, effects}
}
