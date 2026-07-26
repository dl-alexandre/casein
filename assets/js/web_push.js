// Web Push registration for the installed PWA.
//
// Inert unless VAPID keys are configured (data-vapid-key present) and the user
// has already granted notification permission. When both hold, it subscribes
// via the service worker's pushManager and POSTs the PushSubscription to the
// server, which stores it against the current workspace so the phone gets an
// "agent needs you" push while the app is backgrounded or closed.
//
// Permission itself is requested by the existing notification opt-in button in
// app.js; on grant it dispatches `casein:notification-permission-granted`, which
// we listen for so subscription happens right after the user opts in.

export const WebPush = {
  mounted() {
    this._onGranted = () => this._subscribe()
    window.addEventListener("casein:notification-permission-granted", this._onGranted)
    // Re-register on load for a device that granted permission in a past session.
    this._subscribe()
  },

  destroyed() {
    window.removeEventListener("casein:notification-permission-granted", this._onGranted)
  },

  async _subscribe() {
    try {
      const vapidKey = this.el.dataset.vapidKey
      const workspaceId = this.el.dataset.workspaceId
      if (!vapidKey || !workspaceId) return
      if (typeof Notification === "undefined" || Notification.permission !== "granted") return
      if (!("serviceWorker" in navigator) || !window.isSecureContext) return

      const registration = await navigator.serviceWorker.ready
      if (!registration.pushManager) return

      let subscription = await registration.pushManager.getSubscription()
      if (!subscription) {
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(vapidKey)
        })
      }

      await fetch("/api/push/subscribe", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken()
        },
        body: JSON.stringify({
          subscription: subscription.toJSON(),
          workspace_id: workspaceId
        })
      })
    } catch (_error) {
      // Best-effort: a denied permission, missing SW, or offline POST is fine —
      // we retry on the next mount / permission grant.
    }
  }
}

function csrfToken() {
  return (
    document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
  )
}

// VAPID keys are base64url; the Push API wants a Uint8Array of the raw bytes.
function urlBase64ToUint8Array(base64) {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4)
  const normalized = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(normalized)
  const output = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i += 1) output[i] = raw.charCodeAt(i)
  return output
}
