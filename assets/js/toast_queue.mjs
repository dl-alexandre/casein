// Pure toast scheduling for the single bottom-center toast surface.
//
// Before this module there were two unrelated transient-message systems: the
// server flash group (DaisyUI toast, top-right, no auto-dismiss) and a
// hand-rolled `#casein-clipboard-toast` (bottom-center, 4s auto-hide, one
// shared DOM node that the *next* message clobbered mid-display). This owns the
// scheduling half of the merge: what is on screen, for how long, and what waits.
//
// No DOM and no timers live here so the rules are testable without jsdom or
// wall-clock sleeps — callers pass `now` in and drive expiry from
// `nextDeadline`. See toast.js for the DOM presenter.

export const LANE_MESSAGE = "message"
export const LANE_HINT = "hint"

// Higher wins. `pending` is "your copy is staged, tap to finish" — actionable,
// so it outranks a plain confirmation but not a failure.
const PRIORITY = {error: 3, pending: 2, info: 1, shortcut: 0}

const DEFAULT_DURATION = {error: 6000, pending: 5000, info: 4000, shortcut: 2600}

// A visible item whose turn is over gets cut to this much remaining time when
// something more important arrives. Truncating instead of swapping outright
// means nothing is silently dropped, and the eye still registers the change.
export const PREEMPT_CUT_MS = 400

// Deep queues are a bug, not a feature: past this we shed the least important
// oldest entries rather than promising to show a backlog nobody will read.
export const MAX_QUEUED = 8

export function laneFor(kind) {
  return kind === "shortcut" ? LANE_HINT : LANE_MESSAGE
}

export function priorityOf(kind) {
  return PRIORITY[kind] ?? PRIORITY.info
}

export function defaultDuration(kind) {
  return DEFAULT_DURATION[kind] ?? DEFAULT_DURATION.info
}

export function createQueue() {
  return {
    seq: 0,
    dropped: 0,
    [LANE_MESSAGE]: {current: null, queue: []},
    [LANE_HINT]: {current: null, queue: []}
  }
}

function makeItem(state, {text, kind, duration, actions}, now) {
  return {
    id: `t${state.seq}`,
    kind,
    text,
    duration,
    startedAt: now,
    expiresAt: now + duration,
    count: 1,
    actions
  }
}

/**
 * Add a message. Returns a new state; the input is not mutated.
 *
 * Blank text is a no-op so call sites can pass through optional strings.
 */
export function enqueue(state, {text, kind = "info", duration, lane, actions} = {}, now = 0) {
  if (!text || !`${text}`.trim()) return state

  const resolvedKind = PRIORITY[kind] === undefined ? "info" : kind
  const resolvedLane = lane || laneFor(resolvedKind)
  const resolvedDuration = duration ?? defaultDuration(resolvedKind)

  const next = {...state, seq: state.seq + 1}
  const item = makeItem(
    next,
    {text: `${text}`, kind: resolvedKind, duration: resolvedDuration, actions},
    now
  )

  return resolvedLane === LANE_HINT
    ? enqueueHint(next, item)
    : enqueueMessage(next, item, now)
}

// A hint describes the click that just happened, so a newer hint always
// replaces an older one outright — a queue of stale coaching is worse than
// none. The hint lane is a separate slot, so hints never delay a real message.
function enqueueHint(state, item) {
  return {...state, [LANE_HINT]: {current: item, queue: []}}
}

function enqueueMessage(state, item, now) {
  const lane = state[LANE_MESSAGE]

  // Repeat of what is already on screen: bump the counter and extend, rather
  // than tear the node down and rebuild it (the old single-node bug, which read
  // as a flicker whenever an action fired twice).
  if (lane.current && lane.current.text === item.text) {
    const current = {
      ...lane.current,
      count: lane.current.count + 1,
      actions: item.actions,
      expiresAt: now + Math.max(lane.current.duration, item.duration)
    }
    return {...state, [LANE_MESSAGE]: {...lane, current}}
  }

  const queuedIdx = lane.queue.findIndex((queued) => queued.text === item.text)
  if (queuedIdx !== -1) {
    const queue = lane.queue.slice()
    queue[queuedIdx] = {
      ...queue[queuedIdx],
      count: queue[queuedIdx].count + 1,
      actions: item.actions
    }
    return {...state, [LANE_MESSAGE]: {...lane, queue}}
  }

  if (!lane.current) {
    return {...state, [LANE_MESSAGE]: {...lane, current: {...item, startedAt: now}}}
  }

  const {queue, dropped} = insertByPriority(lane.queue, item)
  const current = shouldPreempt(lane.current, item)
    ? {...lane.current, expiresAt: Math.min(lane.current.expiresAt, now + PREEMPT_CUT_MS)}
    : lane.current

  return {
    ...state,
    dropped: state.dropped + dropped,
    [LANE_MESSAGE]: {current, queue}
  }
}

function shouldPreempt(current, incoming) {
  return priorityOf(incoming.kind) > priorityOf(current.kind)
}

// Stable priority insert: equal priorities keep arrival order, so a burst of
// errors reads in the order it happened.
function insertByPriority(queue, item) {
  const incoming = priorityOf(item.kind)
  const idx = queue.findIndex((queued) => priorityOf(queued.kind) < incoming)
  const inserted = idx === -1 ? [...queue, item] : [...queue.slice(0, idx), item, ...queue.slice(idx)]

  if (inserted.length <= MAX_QUEUED) return {queue: inserted, dropped: 0}

  // Shed from the tail — lowest priority, oldest arrival.
  return {queue: inserted.slice(0, MAX_QUEUED), dropped: inserted.length - MAX_QUEUED}
}

/**
 * Retire anything whose time is up and promote the next waiting item.
 */
export function tick(state, now = 0) {
  let next = state

  for (const lane of [LANE_MESSAGE, LANE_HINT]) {
    const slot = next[lane]
    if (!slot.current || now < slot.current.expiresAt) continue

    const [promoted, ...rest] = slot.queue
    next = {
      ...next,
      [lane]: promoted
        ? {current: {...promoted, startedAt: now, expiresAt: now + promoted.duration}, queue: rest}
        : {current: null, queue: []}
    }
  }

  return next
}

/**
 * Dismiss the visible item in a lane — the click-to-close affordance.
 */
export function dismiss(state, lane, now = 0) {
  const slot = state[lane]
  if (!slot || !slot.current) return state

  return tick({...state, [lane]: {...slot, current: {...slot.current, expiresAt: now}}}, now)
}

export function visible(state) {
  return {
    [LANE_MESSAGE]: state[LANE_MESSAGE].current,
    [LANE_HINT]: state[LANE_HINT].current
  }
}

/**
 * Earliest moment the presenter must call `tick` again, or null when idle.
 * Lets the DOM layer run one timer instead of one per message.
 */
export function nextDeadline(state) {
  const deadlines = [state[LANE_MESSAGE].current, state[LANE_HINT].current]
    .filter(Boolean)
    .map((item) => item.expiresAt)

  return deadlines.length ? Math.min(...deadlines) : null
}

export function pendingCount(state) {
  return state[LANE_MESSAGE].queue.length
}
