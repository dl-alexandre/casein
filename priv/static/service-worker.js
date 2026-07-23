const CACHE_PREFIX = "devide-pwa";
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

  const title = data.title || "DevIDE";
  const options = {
    body: data.body || "",
    icon: "/images/pwa-icon-192.png",
    badge: "/images/pwa-icon-192.png",
    tag: data.tag || "devide",
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

async function openNotificationTarget(targetUrl, detail) {
  const allClients = await clients.matchAll({
    type: "window",
    includeUncontrolled: true
  });

  const targetOrigin = new URL(targetUrl, self.location.origin).origin;
  const sameOriginClients = allClients.filter((client) => {
    try {
      return new URL(client.url).origin === targetOrigin;
    } catch (_error) {
      return false;
    }
  });

  const message = {
    type: "DEVIDE_AGENT_QUIET_OPEN",
    detail
  };

  if (sameOriginClients.length > 0) {
    const client = sameOriginClients[0];
    await client.focus();
    client.postMessage(message);
    return;
  }

  const opened = await clients.openWindow(targetUrl);
  if (opened) opened.postMessage(message);
}
