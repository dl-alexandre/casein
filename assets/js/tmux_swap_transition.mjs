import {paneRectToPixels} from "./terminal_capture.mjs"
import {normalizeConfirmedProjection} from "./tmux_layout_transition.mjs"

export const SWAP_TRANSITION_MS = 180
/** Short opacity-only settle under prefers-reduced-motion (issue #734). */
export const SWAP_REDUCED_TRANSITION_MS = 100

export function swapAnimationTargets(before, confirmed, layoutRect) {
  const after = normalizeConfirmedProjection(confirmed)
  const confirmedById = new Map(after.panes.map((pane) => [pane.id, pane]))

  return (before.panes || []).map((pane) => {
    const from = paneRectToPixels(pane, before.bounds, layoutRect)
    const confirmedPane = confirmedById.get(pane.id)

    return {
      id: pane.id,
      active: pane.id === after.activePaneId,
      from,
      to: confirmedPane ? paneRectToPixels(confirmedPane, after.bounds, layoutRect) : from,
      opacity: 0,
    }
  })
}

export async function animateSwapTransition({frozen, before, confirmed, signal}) {
  if (!frozen?.panes?.size || typeof Element === "undefined") return

  const targets = swapAnimationTargets(before, confirmed, frozen.layoutRect)
  const animations = []
  const reduced = reducedMotion()

  for (const target of targets) {
    const entry = frozen.panes.get(target.id)
    if (!entry?.el || typeof entry.el.animate !== "function") continue

    entry.el.style.zIndex = target.active ? "2" : "1"

    // Reduced: opacity fade only — a geometry jump with no transition is worse
    // for motion-sensitive users than a brief settle (issue #734).
    if (reduced) {
      entry.el.style.willChange = "opacity"
      const animation = entry.el.animate([{opacity: 1}, {opacity: target.opacity}], {
        duration: SWAP_REDUCED_TRANSITION_MS,
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
      [frameForRect(target.from, 1), frameForRect(target.to, target.opacity)],
      {
        duration: SWAP_TRANSITION_MS,
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
