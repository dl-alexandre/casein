// The terminal connection/attachment decision, as one pure state machine.
//
// The LiveView hook used to send every recovery signal through one
// requestTerminalResync(hook, freeTextReason) helper. That preserved recovery,
// but erased whether the trigger was attachment loss, a sizing-role change, a
// document lifecycle edge, or an explicit surface refit. This module keeps
// those inputs typed while deliberately preserving the current response.
//
// It owns no browser, LiveView, Ghostty, DOM, clock, or timer. The hook executes
// the returned effects. Timer ownership remains empty in this slice: migrating
// the hook's five existing timers into phase-owned effects is tracked by #987.

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
  HOOK_DESTROYED: "hook_destroyed"
})

export const ConnectionEffect = Object.freeze({
  REQUEST_RESYNC: "request_resync",
  CANCEL_TIMER: "cancel_timer"
})

export const INITIAL_CONNECTION_PHASE = ConnectionPhase.DETACHED

export const CONNECTION_PHASES = Object.freeze(Object.values(ConnectionPhase))
export const TERMINAL_CONNECTION_PHASES = Object.freeze([ConnectionPhase.DISPOSED])

// Slice 1 intentionally assigns no timers to the connection machine. Keeping
// the ownership table explicit makes the cancellation invariant executable
// now, and gives #987 one place to move each legacy timer into later.
export const CONNECTION_TIMERS_BY_PHASE = Object.freeze(
  Object.fromEntries(CONNECTION_PHASES.map((phase) => [phase, Object.freeze([])]))
)

export const CONNECTION_EFFECTS_BY_PHASE = Object.freeze({
  [ConnectionPhase.DETACHED]: Object.freeze([]),
  [ConnectionPhase.ATTACHING]: Object.freeze([ConnectionEffect.REQUEST_RESYNC]),
  [ConnectionPhase.ATTACHED]: Object.freeze([ConnectionEffect.REQUEST_RESYNC]),
  [ConnectionPhase.REATTACHING]: Object.freeze([ConnectionEffect.REQUEST_RESYNC]),
  [ConnectionPhase.DISPOSED]: Object.freeze([])
})

function resync(reason) {
  return {type: ConnectionEffect.REQUEST_RESYNC, reason}
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

/**
 * @param {string} phase one of ConnectionPhase
 * @param {{type: string, reason?: string, lifecycleType?: string}} event
 * @returns {{phase: string, effects: Array<{type: string, reason?: string, timer?: string}>}}
 */
export function transitionTerminalConnection(phase = INITIAL_CONNECTION_PHASE, event = {}) {
  if (!CONNECTION_PHASES.includes(phase)) {
    throw new TypeError(`unknown terminal connection phase: ${phase}`)
  }

  const nextPhase = nextPhaseFor(phase, event.type)
  const effects = cancelledTimerEffects(phase, nextPhase)
  const resyncEffect = resyncEffectFor(phase, event)
  if (resyncEffect) effects.push(resyncEffect)

  return {phase: nextPhase, effects}
}
