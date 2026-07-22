import {paneRectToPixels} from "./terminal_capture.mjs"
import {normalizeConfirmedProjection} from "./tmux_layout_transition.mjs"

export const ZOOM_TRANSITION_MS = 180

export function zoomAnimationTargets(before, confirmed, layoutRect) {
  const after = normalizeConfirmedProjection(confirmed)
  const confirmedById = new Map(after.panes.map((pane) => [pane.id, pane]))
  const center = {x: layoutRect.width / 2, y: layoutRect.height / 2}

  return (before.panes || []).map((pane) => {
    const from = paneRectToPixels(pane, before.bounds, layoutRect)
    const confirmedPane = confirmedById.get(pane.id)
    const active = pane.id === after.activePaneId

    if (confirmedPane) {
      return {
        id: pane.id,
        active,
        from,
        to: paneRectToPixels(confirmedPane, after.bounds, layoutRect),
        opacity: 0,
      }
    }

    const paneCenter = {x: from.left + from.width / 2, y: from.top + from.height / 2}
    const dx = paneCenter.x < center.x ? -6 : 6
    const dy = paneCenter.y < center.y ? -6 : 6

    return {
      id: pane.id,
      active,
      from,
      to: {...from, left: from.left + dx, top: from.top + dy},
      opacity: 0,
    }
  })
}

export async function animateZoomTransition({frozen, before, confirmed, signal}) {
  if (!frozen?.panes?.size || reducedMotion() || typeof Element === "undefined") return

  const targets = zoomAnimationTargets(before, confirmed, frozen.layoutRect)
  const animations = []

  for (const target of targets) {
    const entry = frozen.panes.get(target.id)
    if (!entry?.el || typeof entry.el.animate !== "function") continue

    entry.el.style.willChange = "left, top, width, height, opacity"

    const animation = entry.el.animate(
      [frameForRect(target.from, 1), frameForRect(target.to, target.opacity)],
      {
        duration: ZOOM_TRANSITION_MS,
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
