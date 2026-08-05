const CACHE_PREFIX = "casein-pwa";
const CACHE_VERSION = "v1";
const STATIC_CACHE = `${CACHE_PREFIX}-${CACHE_VERSION}:static`;
const OFFLINE_URL = "/offline.html";

const PRECACHE_URLS = [
  OFFLINE_URL,
  "/favicon.ico",
  "/images/favicon.svg",
  "/images/apple-touch-icon.png",
  "/images/pwa-icon-192.png",
  "/images/pwa-icon-512.png",
  "/images/pwa-maskable-512.png",
  "/site.webmanifest"
];

const BYPASS_PREFIXES = [
  "/api/",
  "/live",
  "/socket",
  "/preview-proxy/",
  "/phoenix/"
];

const STATIC_PREFIXES = [
  "/assets/",
  "/fonts/",
  "/images/"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(STATIC_CACHE)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key.startsWith(CACHE_PREFIX) && !key.startsWith(`${CACHE_PREFIX}-${CACHE_VERSION}`))
            .map((key) => caches.delete(key))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "SKIP_WAITING") {
    self.skipWaiting();
  }
});

self.addEventListener("fetch", (event) => {
  const { request } = event;

  if (!shouldHandle(request)) return;

  const url = new URL(request.url);

  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(() => caches.match(OFFLINE_URL)));
    return;
  }

  if (isStaticAsset(url.pathname) || PRECACHE_URLS.includes(url.pathname)) {
    event.respondWith(networkFirstStatic(request));
  }
});

self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_error) {
    data = {};
  }

  const title = data.title || "Casein";
  const options = {
    body: data.body || "",
    icon: "/images/pwa-icon-192.png",
    badge: "/images/pwa-icon-192.png",
    tag: data.tag || "casein",
    renotify: true,
    data: { url: data.url || "/", ...data }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const data = event.notification.data || {};
  const targetUrl = data.url || "/";

  event.waitUntil(openNotificationTarget(targetUrl, data));
});

function shouldHandle(request) {
  if (request.method !== "GET") return false;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return false;

  return !BYPASS_PREFIXES.some((prefix) => url.pathname.startsWith(prefix));
}

function isStaticAsset(pathname) {
  return STATIC_PREFIXES.some((prefix) => pathname.startsWith(prefix));
}

async function networkFirstStatic(request) {
  const cache = await caches.open(STATIC_CACHE);

  try {
    const response = await fetch(request);

    if (response && response.ok && response.type === "basic") {
      cache.put(request, response.clone());
    }

    return response;
  } catch (_error) {
    const cached = await cache.match(request);
    if (cached) return cached;
    throw _error;
  }
}

// Click routing, in order of preference:
//
//   1. a window already on the notification's workspace  -> focus it, attach in place
//   2. any other window of ours (an installed app window) -> focus + navigate it
//   3. nothing open                                       -> open a new window
//
// Step 2 matters most on desktop: the old code focused an arbitrary same-origin
// client and never navigated it, and every miss fell through to openWindow("/"),
// which lands on the scratch workspace in a plain browser tab rather than the
// installed app window the operator already had running.
async function openNotificationTarget(targetUrl, detail) {
  const target = new URL(targetUrl, self.location.origin);

  const allClients = await clients.matchAll({
    type: "window",
    includeUncontrolled: true
  });

  const ourClients = allClients.filter((client) => {
    try {
      return new URL(client.url).origin === target.origin;
    } catch (_error) {
      return false;
    }
  });

  const message = { type: "CASEIN_AGENT_QUIET_OPEN", detail };
  const targetWorkspace = workspacePath(target);

  const onWorkspace = ourClients.filter(
    (client) => workspacePath(clientUrl(client)) === targetWorkspace
  );

  if (onWorkspace.length > 0) {
    const client = preferredClient(onWorkspace);
    await focusClient(client);
    client.postMessage(message);
    return;
  }

  const elsewhere = preferredClient(ourClients);
  if (elsewhere) {
    // A target that names no workspace (a bare "/") is not worth pulling a
    // window off the workspace it is showing — "/" is the scratch mount.
    if (targetWorkspace === "/") {
      await focusClient(elsewhere);
      elsewhere.postMessage(message);
      return;
    }

    // navigate() is only allowed on clients this worker controls; a window from
    // before the worker activated throws, and openWindow is the honest fallback.
    const navigated = await elsewhere.navigate(target.href).catch(() => null);
    if (navigated) {
      await focusClient(navigated);
      return;
    }
  }

  const opened = await clients.openWindow(target.href);
  if (opened) opened.postMessage(message);
}

// Workspace identity of a URL, so "same workspace, different session/tab" still
// counts as a window we should reuse. Everything outside /workspaces/:id (the
// dashboard, the scratch root) shares the "/" bucket.
function workspacePath(url) {
  if (!url) return null;
  const match = url.pathname.match(/^\/workspaces\/[^/]+/);
  return match ? match[0] : "/";
}

function clientUrl(client) {
  try {
    return new URL(client.url);
  } catch (_error) {
    return null;
  }
}

// A visible window is the one the operator is looking at; prefer it over a
// window buried on another desktop or minimized.
function preferredClient(candidates) {
  if (candidates.length === 0) return null;
  return (
    candidates.find((client) => client.focused) ||
    candidates.find((client) => client.visibilityState === "visible") ||
    candidates[0]
  );
}

async function focusClient(client) {
  if (typeof client.focus !== "function") return client;
  return client.focus().catch(() => client);
}
