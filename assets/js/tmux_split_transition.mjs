import {paneRectToPixels} from "./terminal_capture.mjs"
import {normalizeConfirmedProjection} from "./tmux_layout_transition.mjs"

export const SPLIT_TRANSITION_MS = 190
/** Short opacity-only settle under prefers-reduced-motion (issue #734). */
export const SPLIT_REDUCED_TRANSITION_MS = 100

export function splitAnimationTargets(before, confirmed, layoutRect) {
  const after = normalizeConfirmedProjection(confirmed)
  const confirmedById = new Map(after.panes.map((pane) => [pane.id, pane]))

  return (before.panes || []).map((pane) => {
    const from = paneRectToPixels(pane, before.bounds, layoutRect)
    const confirmedPane = confirmedById.get(pane.id)

    return {
      id: pane.id,
      source: pane.id === before.activePaneId,
      from,
      to: confirmedPane ? paneRectToPixels(confirmedPane, after.bounds, layoutRect) : from,
    }
  })
}

// The confirmed terminal is already live underneath the frozen frame. Clipping
// the old source pane toward its tmux-confirmed rectangle exposes the new pane
// from the shared divider without ever scaling terminal glyphs. A short final
// crossfade removes the remaining frozen chrome after geometry settles.
export async function animateSplitTransition({frozen, before, confirmed, signal}) {
  if (!frozen?.panes?.size || typeof Element === "undefined") return

  const targets = splitAnimationTargets(before, confirmed, frozen.layoutRect)
  const animations = []
  const reduced = reducedMotion()

  for (const target of targets) {
    const entry = frozen.panes.get(target.id)
    if (!entry?.el || typeof entry.el.animate !== "function") continue

    entry.el.style.zIndex = target.source ? "2" : "1"

    // Reduced: opacity fade only — a geometry jump with no transition is worse
    // for motion-sensitive users than a brief settle (issue #734).
    if (reduced) {
      entry.el.style.willChange = "opacity"
      const animation = entry.el.animate([{opacity: 1}, {opacity: 0}], {
        duration: SPLIT_REDUCED_TRANSITION_MS,
        easing: "ease-out",
        fill: "forwards",
      })
      const cancel = () => animation.cancel()
      signal?.addEventListener("abort", cancel, {once: true})
      animations.push(
        animation.finished.finally(() => {
          signal?.removeEventListener("abort", cancel)
          entry.el.style.willChange = ""
        }),
      )
      continue
    }

    entry.el.style.willChange = "left, top, width, height, opacity"

    const animation = entry.el.animate(
      [
        {...frameForRect(target.from, 1), offset: 0},
        {...frameForRect(target.to, 1), offset: 0.74},
        {...frameForRect(target.to, 0), offset: 1},
      ],
      {
        duration: SPLIT_TRANSITION_MS,
        easing: "cubic-bezier(0.4, 0, 0.2, 1)",
        fill: "forwards",
      },
    )

    const cancel = () => animation.cancel()
    signal?.addEventListener("abort", cancel, {once: true})

    animations.push(
      animation.finished.finally(() => {
        signal?.removeEventListener("abort", cancel)
        entry.el.style.willChange = ""
      }),
    )
  }

  await Promise.all(animations)
}

function frameForRect(rect, opacity) {
  return {
    left: `${rect.left}px`,
    top: `${rect.top}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
    opacity,
  }
}

function reducedMotion() {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  )
}
