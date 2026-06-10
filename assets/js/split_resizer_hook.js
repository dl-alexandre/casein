// SplitResizer hook
// Provides smooth, low-latency resizing of split panes.
//
// Strategy (best practice for LiveView):
// - While dragging: mutate DOM styles directly for instant visual feedback (no server round-trips).
// - On pointerup: compute the final ratio and push a single "resize_split" event so the
//   server becomes the source of truth (persists across reconnects, works with LV diffs, etc.).
//
// The server still owns the authoritative ratios in the layout tree and re-renders them
// when the hook pushes the final value.

export const SplitResizer = {
  mounted() {
    const el = this.el
    const dir = el.dataset.direction // "horizontal" | "vertical"
    const leftId = el.dataset.left
    const rightId = el.dataset.right

    let dragging = false
    let containerRect = null
    let leftPaneEl = null
    let rightPaneEl = null

    // Single source of truth for the usability floor used by drag + final commit.
    // When the container is smaller than 2×MIN_PX the floor is mathematically relaxed
    // (via the min(0.45, ...) cap) so both panes remain visible; this is intentional.
    const MIN_PX = 120

    const getSiblings = () => {
      // Structure inside the split container: [paneWrapper, resizer, paneWrapper, ...]
      leftPaneEl = el.previousElementSibling
      rightPaneEl = el.nextElementSibling
    }

    const onPointerMove = (e) => {
      if (!dragging || !containerRect || !leftPaneEl || !rightPaneEl) return

      const clientPos = dir === "horizontal" ? e.clientX : e.clientY
      const totalSize = dir === "horizontal" ? containerRect.width : containerRect.height
      const offset = clientPos - (dir === "horizontal" ? containerRect.left : containerRect.top)

      // Enforce a minimum pixel size for usability instead of pure 10% ratio.
      // (See top-of-mounted const for the relaxation rule when container < 2×MIN_PX.)
      const minRatio = Math.min(0.45, MIN_PX / totalSize)
      const maxRatio = 1 - minRatio
      let ratio = offset / totalSize
      ratio = Math.min(maxRatio, Math.max(minRatio, ratio))

      // Match the server template format exactly (`flex: 0 0 X.XX%;`,
      // 2-decimal rounding) so the inline `style` attribute string the hook
      // produces during drag is byte-identical to what LiveView will render
      // back after the final resize_split. Without this, morphdom sees a
      // "different" style attribute on the post-commit diff and rewrites it,
      // causing the visible "snap back" on pointerup.
      const lp = Math.round(ratio * 10000) / 100
      const rp = Math.round((1 - ratio) * 10000) / 100
      leftPaneEl.style.flex = `0 0 ${lp.toFixed(2)}%`
      rightPaneEl.style.flex = `0 0 ${rp.toFixed(2)}%`
    }

    const onPointerUp = () => {
      if (!dragging) return
      dragging = false

      document.removeEventListener("pointermove", onPointerMove)
      document.removeEventListener("pointerup", onPointerUp)
      document.removeEventListener("pointercancel", onPointerUp)

      // Restore default hover styling
      el.style.backgroundColor = ""

      // Compute final ratio from current DOM state (more reliable than storing floats)
      // Use a *fresh* container rect at commit time (not the one captured on pointerdown)
      // so that any outer resize (e.g. Aerospace WM snapping the browser window) or
      // layout settling produces an accurate ratio. Prevents "jumping" on re-render.
      if (leftPaneEl) {
        const freshContainer = leftPaneEl.parentElement
        const freshRect = freshContainer ? freshContainer.getBoundingClientRect() : containerRect
        const total = dir === "horizontal" ? freshRect.width : freshRect.height
        const leftSize = dir === "horizontal"
          ? leftPaneEl.getBoundingClientRect().width
          : leftPaneEl.getBoundingClientRect().height

        const minR = total > 0 ? Math.min(0.45, MIN_PX / total) : 0.1
        const maxR = 1 - minR
        const finalRatio = total > 0 ? Math.min(maxR, Math.max(minR, leftSize / total)) : 0.5

        // One final authoritative update to the server
        this.pushEvent("resize_split", {
          left: leftId,
          right: rightId,
          ratio: finalRatio
        })
      }
    }

    el.addEventListener("pointerdown", (e) => {
      e.preventDefault()
      dragging = true

      getSiblings()
      containerRect = el.parentElement.getBoundingClientRect()

      // Make the bar more prominent while active
      el.style.backgroundColor = "#10b981"

      document.addEventListener("pointermove", onPointerMove)
      document.addEventListener("pointerup", onPointerUp)
      document.addEventListener("pointercancel", onPointerUp)
    })

    // Double-click any resizer to reset that specific split to equal (50/50) ratios.
    // Works for nested splits too because each resizer carries the adjacent pane ids.
    el.addEventListener("dblclick", (e) => {
      e.preventDefault()
      this.pushEvent("resize_split", { left: leftId, right: rightId, ratio: 0.5 })
    })

    // Keyboard nudge support on the resizer (make it focusable via tabindex in the template).
    // Nudges relative to the *current* rendered ratio (read from live DOM styles).
    el.addEventListener("keydown", (e) => {
      if (e.key === "ArrowLeft" || e.key === "ArrowRight" || e.key === "ArrowUp" || e.key === "ArrowDown") {
        e.preventDefault()
        getSiblings()
        let current = 0.5
        if (leftPaneEl && leftPaneEl.style.flexBasis) {
          const pct = parseFloat(leftPaneEl.style.flexBasis)
          if (!Number.isNaN(pct)) current = pct / 100
        }
        const delta = (e.key === "ArrowLeft" || e.key === "ArrowUp") ? -0.05 : 0.05
        const newRatio = Math.min(0.9, Math.max(0.1, current + delta))
        this.pushEvent("resize_split", { left: leftId, right: rightId, ratio: newRatio })
      }
    })
  }
}

// PaneLayoutPersistence hook — mounted on the raw/governed *utility bar only*
// (never a parent/ancestor of the GhosttyTerminal components). This is the
// architectural fix for the "no prompt in raw shell" mount-order race.
//
// The hook NEVER pushes restore on its own mounted(). The server drives
// "request_saved_layout" at safe moments (after set_mode raw, after initial
// mount for default-raw). The reply is deferred with requestAnimationFrame so
// the sibling/inner Ghostty hooks have run their `fit`, `terminal_ready`,
// PTY feed etc.
//
// Debug surface: sets window.__devidePaneDebug[wsId] and dispatches
// `phx:persistence:*` CustomEvents that Tidewave, console, and devtools can
// observe to answer "what is the tree right now?", "did restore happen?"
// Persistence fully moved to global listeners in app.js (Option B).
// No PaneLayoutPersistence hook is mounted on the raw terminal view anymore.