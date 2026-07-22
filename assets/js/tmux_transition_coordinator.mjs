// Transaction coordinator for short-lived tmux layout transitions.
//
// The browser owns only the visual preview/frozen frame. tmux remains the
// authority: commit() validates the captured layout version server-side and
// returns the confirmed projection that applyConfirmed() waits to see in the
// live DOM before animate() uncovers it.

export class TmuxTransitionCoordinator {
  constructor() {
    this.activeTransition = null
    this.nextId = 1
  }

  async run({
    base,
    capture,
    preview,
    commit,
    applyConfirmed,
    animate,
    rollback,
    cleanup,
    onError,
  }) {
    this.cancel("superseded")

    const transition = {
      id: this.nextId,
      base,
      controller: new AbortController(),
      frozen: null,
      cleanup,
      cleanupPromise: null,
    }

    this.nextId += 1
    this.activeTransition = transition

    try {
      // Capture must remain synchronous: waiting here would allow terminal
      // output or a topology patch to change the pixels paired with base.
      transition.frozen = capture?.(base) ?? null
      throwIfAborted(transition.controller.signal)

      await preview?.({base, frozen: transition.frozen, signal: transition.controller.signal})
      throwIfAborted(transition.controller.signal)

      const confirmed = await commit(base, transition.controller.signal)
      throwIfAborted(transition.controller.signal)

      if (!confirmed || confirmed.ok === false) {
        throw transitionError(confirmed?.error || "commit_failed", confirmed)
      }

      await applyConfirmed?.(confirmed, transition.controller.signal)
      throwIfAborted(transition.controller.signal)

      await animate?.({
        frozen: transition.frozen,
        before: base,
        confirmed,
        signal: transition.controller.signal,
      })

      return {ok: true, confirmed}
    } catch (error) {
      const cancelled = transition.controller.signal.aborted || error?.name === "AbortError"

      if (!cancelled) {
        try {
          await rollback?.({base, frozen: transition.frozen, error})
        } catch (_) {
          // Reconciliation will still restore server truth. A visual rollback
          // failure must never prevent frozen-frame cleanup.
        }

        onError?.(error)
      }

      return {ok: false, cancelled, error}
    } finally {
      try {
        await this._cleanupTransition(transition)
      } finally {
        if (this.activeTransition === transition) this.activeTransition = null
      }
    }
  }

  cancel(reason = "cancelled") {
    const active = this.activeTransition
    if (!active || active.controller.signal.aborted) return
    active.controller.abort(reason)

    // Remove the old shield synchronously before a superseding run captures
    // its frame. The stored promise keeps finally idempotent for async cleanup.
    void this._cleanupTransition(active)
  }

  _cleanupTransition(transition) {
    if (transition.cleanupPromise) return transition.cleanupPromise

    try {
      transition.cleanupPromise = Promise.resolve(transition.cleanup?.(transition.frozen)).catch(
        () => undefined,
      )
    } catch (_) {
      transition.cleanupPromise = Promise.resolve()
    }

    return transition.cleanupPromise
  }
}

function throwIfAborted(signal) {
  if (!signal?.aborted) return

  if (typeof signal.throwIfAborted === "function") {
    signal.throwIfAborted()
  }

  const error = new Error("Transition cancelled")
  error.name = "AbortError"
  throw error
}

function transitionError(code, detail) {
  const error = new Error(code)
  error.code = code
  error.detail = detail
  return error
}
