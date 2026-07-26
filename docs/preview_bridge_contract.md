# Preview Bridge Contract

Status: draft v0.1

This contract defines the centralized LiveView-aware preview bridge. The goal is
to make Casein's preview host understand Phoenix LiveView pages without adding
preview-specific code to each LiveView.

## Principles

- LiveViews remain normal application views. They do not branch on preview mode.
- Preview-specific behavior is centralized in Casein's preview host, browser
  boundary, and a single dev-only client signaling layer.
- The controlled browser path is preferred for LiveView previews because native
  browser networking handles websocket upgrades and long-lived channels.
- The iframe/proxy path remains a compatibility fallback, not the primary
  LiveView hosting model.

## Activation

The signaling layer is passive unless a page is clearly in preview context:

- the page is embedded (`window.parent !== window`) in a development bundle,
- the URL contains `devide_preview=1`, or
- the URL contains the legacy `preview_superadmin=1` marker during migration.

Production-style bundles require an explicit preview marker. This prevents
ordinary embedded production pages from emitting Casein-specific signals by
accident.

Activation must never require changes inside individual LiveViews.

## Message Transport

Preview pages emit browser-native messages:

```javascript
window.parent.postMessage(
  {
    source: "casein-preview",
    version: 1,
    type: "devide:preview:live_socket_connected",
    payload: {
      url: window.location.href,
      pathname: window.location.pathname,
      timestamp: Date.now(),
      request_id: "..."
    }
  },
  "*"
)
```

The same payload is also dispatched on the page as a `CustomEvent` named
`devide:preview:signal` so a controlled browser backend can observe or inject
listeners without relying on iframe parent messaging.

## Event Types

| Event | Meaning |
|-------|---------|
| `devide:preview:bridge_ready` | The centralized bridge script is active. |
| `devide:preview:dom_loaded` | The document reached DOM ready. |
| `devide:preview:page_loading_start` | LiveView or browser navigation/loading began. |
| `devide:preview:page_loading_stop` | LiveView or browser navigation/loading ended. |
| `devide:preview:live_socket_connected` | Phoenix LiveView client state appears connected. |
| `devide:preview:live_socket_disconnected` | Phoenix LiveView client state appears disconnected. |
| `devide:preview:client_error` | Browser JS error or unhandled promise rejection occurred. |

## Payload Shape

All events share the base payload:

```json
{
  "source": "casein-preview",
  "version": 1,
  "type": "devide:preview:dom_loaded",
  "payload": {
    "url": "http://127.0.0.1:4000/superadmin",
    "pathname": "/superadmin",
    "timestamp": 1782287000000,
    "request_id": "pv-abc123"
  }
}
```

Events may add fields:

- loading events: `kind`
- connection events: `connected`
- error events: `message`, `filename`, `lineno`, `colno`, `reason`

## Health State Machine

Preview hosts should model health using these states:

| State | Description |
|-------|-------------|
| `browser_started` | Browser runtime is alive. |
| `navigation_started` | A navigation has been requested. |
| `dom_loaded` | The document emitted DOM ready. |
| `live_socket_connected` | The LiveView client appears connected. |
| `liveview_stable` | DOM ready and LiveSocket connected have both held briefly. |
| `degraded` | Page loaded, but LiveView connection is absent or repeatedly disconnecting. |
| `crashed` | Browser process crashed or the sidecar reported a hard failure. |

Repair logic should avoid reloading during normal initial LiveView startup. Repair
is appropriate only for browser crash, hard navigation failure, repeated websocket
failure, or missing heartbeat after the configured grace period.

## Auth Bootstrap

The long-term preview auth path should not rely on `preview_superadmin=1`.
Instead:

1. Casein creates a short-lived dev-only preview token for a workspace/session.
2. The controlled browser supplies that token as a header or exchanges it for a
   short-lived same-site cookie before navigation.
3. One central plug validates the token/cookie and establishes the desired dev
   preview scope.
4. Reloads continue to work because the controlled browser owns the cookie/header
   setup.

This auth bootstrap is deliberately separate from the signaling layer so it can
be introduced without changing LiveViews.

## Browser Boundary Responsibilities

`CaseinPreviewBrowser` should eventually expose these observations:

- lifecycle events from the browser runtime,
- console messages,
- client errors from this contract,
- LiveView connection state,
- screenshot artifacts,
- CDP command results.

Unsupported browser interactions should return explicit errors until implemented;
they should not silently degrade to iframe heuristics.

## Sidecar Event Delivery

External browser sidecars forward bridge signals over the JSON-line event stream:

```json
{
  "type": "event",
  "browser_id": "browser-1",
  "event": [
    "preview_signal",
    "devide:preview:live_socket_connected",
    {"request_id": "pv-abc123", "connected": true},
    {"state": "liveview_stable", "dom_loaded": true, "live_socket_connected": true}
  ]
}
```

Elixir normalizes that into:

```elixir
{:preview_browser, browser_id,
 {:preview_signal, "devide:preview:live_socket_connected", payload, health}}
```

where `health` is a `CaseinPreviewBrowser.Health` snapshot. `observe/1` also
includes the latest health snapshot when the backend supplies one.
