// Placeholder replaced with this build's hashed asset paths by vite.config.ts.
const PRECACHE_ASSETS = self.__PRECACHE_MANIFEST || [];
const BUILD_ID = self.__BUILD_ID || "development";
const SHELL_CACHE = `hausklar-shell-${BUILD_ID}`;
const RUNTIME_CACHE = `hausklar-runtime-${BUILD_ID}`;
const OWNED_CACHE_PATTERN = /^hausklar-(?:shell|runtime)-/;
const PREVIOUS_CACHE_ENTRIES_TO_KEEP = 4;
const SHELL = ["/", "/manifest.webmanifest", "/icons/hausklar-192.png"];
const NETWORK_TIMEOUT_MS = 3500;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(SHELL_CACHE).then((cache) => cache.addAll([...SHELL, ...PRECACHE_ASSETS])));
  // Do not take over an already-open tab mid-deploy. Its older lazy chunks
  // remain paired with the worker and runtime cache that loaded that tab.
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    const current = new Set([SHELL_CACHE, RUNTIME_CACHE]);
    const previous = keys.filter((key) => OWNED_CACHE_PATTERN.test(key) && !current.has(key));
    const stale = previous.slice(0, Math.max(0, previous.length - PREVIOUS_CACHE_ENTRIES_TO_KEEP));
    await Promise.all(stale.map((key) => caches.delete(key)));
    await self.clients.claim();
  })());
});

// Vite emits content-hashed files under /assets/, so a cached copy can never
// be stale — serve those cache-first and only touch the network once each.
async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok) {
    const cache = await caches.open(RUNTIME_CACHE);
    cache.put(request, response.clone());
  }
  return response;
}

async function networkFirst(request) {
  const cache = await caches.open(SHELL_CACHE);
  const cacheKey = request.mode === "navigate" ? "/" : request;
  const network = fetch(request).then((response) => {
    if (response.ok) cache.put(cacheKey, response.clone());
    return response;
  });
  network.catch(() => {});
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), NETWORK_TIMEOUT_MS));
  try {
    const response = await Promise.race([network, timeout]);
    if (response) return response;
  } catch {
    // fall through to the cached copy
  }
  const cached = await cache.match(cacheKey);
  if (cached) return cached;
  if (request.mode === "navigate") {
    const shell = await cache.match("/");
    if (shell) return shell;
  }
  return network;
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (
    request.method !== "GET"
    || url.origin !== self.location.origin
    || url.pathname.startsWith("/api/")
  ) {
    return;
  }
  if (url.pathname.startsWith("/assets/")) {
    event.respondWith(cacheFirst(request));
    return;
  }
  event.respondWith(networkFirst(request));
});

self.addEventListener("push", (event) => {
  let data = { title: "HausKlar update could not be shown", body: "Open HausKlar to check the update.", url: "/?view=today", tag: "hausklar-reminder" };
  try { data = { ...data, ...event.data.json() }; } catch { /* retain privacy-safe fallback */ }
  event.waitUntil(self.registration.showNotification(data.title, {
    body: data.body,
    icon: "/icons/hausklar-192.png",
    badge: "/icons/hausklar-192.png",
    tag: data.tag,
    data: { url: data.url },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || "/?view=today", self.location.origin).href;
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
    const existing = clients[0];
    if (existing) return existing.navigate(target).then(() => existing.focus());
    return self.clients.openWindow(target);
  }));
});
