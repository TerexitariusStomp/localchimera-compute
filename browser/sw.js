const CACHE = 'playnet-v25-dev';

// ── the lists ───────────────────────────────────────────────────────────────
// Four lists say what this worker handles, and three of them are written by
// tools/sw-stamp.sh from the tree being served, so they equal the tree:
//
//   CORE   what app.html's own tags load (its scripts, styles, icons)
//   SHELL  the dial's module graph: app/ and lib/ modules, the root scripts,
//          the stylesheets
//   ROOTS  the tree's top-level directories and files — where a static file
//          can live. A server route (/tiles/…, /audit/…) is no directory of
//          the tree, so it is never under a root.
//
// PRECACHE is the hand-kept remainder: what the dial needs offline that no tag
// names. PASS is the sub-apps and APIs this worker leaves alone; sw-stamp.sh
// reads it from this line to keep them out of the fingerprint too.
//
// The REPL page (index.html, repl.wasm, xterm) and the large lazy files
// (day-boot.wasm, the ONNX runtime) are cached when first fetched, so a dial
// visitor's install does not wait on them.
const PASS = ['/radicle/', '/boards/', '/api/', '/raw/', '/docs/'];
const CORE = [];
const SHELL = [];
const ROOTS = [];

const PRECACHE = [
  '/',
  '/app.html',
  '/data/geo/land-110m.json',
  '/data/geo/land-50m.json',
  '/assets/fonts/inter-400.woff2',
  '/assets/fonts/inter-600.woff2',
  // shown by a notification, which arrives with the page closed
  '/assets/icons/icon-192.png',
  // the notices the signup gate links to. Precached deliberately: a member is
  // asked to accept them on a page that works offline, so they must be readable
  // offline too — "I couldn't open it" is not a defensible way to take consent.
  // (entry-points.json is NOT precached; legal-operator.js degrades to the
  // inline placeholder rather than risk pinning a stale gateway sref.)
  '/terms.html',
  '/privacy.html',
];

// A cache-filling fetch revalidates with the server. The static files carry
// max-age=3600, and a build's cache holds that build's bytes only when the
// HTTP cache cannot answer with the previous build's copy.
const fresh = (req) => new Request(req, { cache: 'no-cache' });

// A put that fails (quota, a body that errors mid-stream) leaves the response
// served and the cache without that entry.
const keep = (c, req, resp) => c.put(req, resp).catch(() => {});

// A static file of the build: under one of the tree's own roots.
const underRoot = (pathname) =>
  ROOTS.some((r) => (r.endsWith('/') ? pathname.startsWith(r) : pathname === r));

// PRECACHE and CORE are all-or-nothing: without them the dial does not boot.
// SHELL is added entry by entry: one that fails leaves the others in place
// and is fetched on first use.
self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then(async (c) => {
      await c.addAll([...new Set([...PRECACHE, ...CORE])].map(fresh));
      await Promise.all(SHELL.map((u) => c.add(fresh(u)).catch(() => {})));
    })
  );
});

// A new worker waits while a page runs the build before it, and that build's
// cache stays whole. The page sends this when it is ready to move
// (app/pwa.ts applyUpdate), and reloads on the controllerchange that follows.
self.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'skip-waiting') self.skipWaiting();
});

// The worker owns the `playnet-` caches and clears the builds before its own.
// Every other cache on the origin (the speech model's `transformers-cache`)
// belongs to its writer and outlives a deploy.
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k.startsWith('playnet-') && k !== CACHE)
                      .map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Live config + KERI endpoints: the network answers, always. The gateway's
// sref in entry-points.json changes when the gateway reissues its OCapN
// identity; KERI OOBIs and signed KELs are time-sensitive; UC / identity /
// scope payloads track live state. The last good answer is kept for one
// purpose: with the network gone, it is what the page gets.
const LIVE = [
  '/entry-points.json',
  '/universal-commune.json',
  '/playnet-identity.json',
  '/scopes',
  '/route',   // live routing — a cached route is yesterday's road
];
const LIVE_UNDER = ['/oobi/', '/.well-known/keri/', '/.well-known/did/', '/scope/'];

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  const path = url.pathname;

  // WebSocket upgrades, cross-origin requests and writes go straight to the
  // network.
  if (e.request.headers.get('upgrade') === 'websocket' ||
      url.origin !== self.location.origin ||
      e.request.method !== 'GET') {
    return;
  }

  // Self-contained sub-apps and APIs. They ship content-hashed assets and
  // live data, and the boards load inside an iframe; this worker's document
  // handler intercepting them broke the iframe load. Straight to the network.
  if (PASS.some((p) => path.startsWith(p))) return;

  if (LIVE.includes(path) || LIVE_UNDER.some((p) => path.startsWith(p))) {
    e.respondWith(
      fetch(e.request).then((resp) => {
        if (resp.ok) { const copy = resp.clone(); caches.open(CACHE).then((c) => keep(c, e.request, copy)); }
        return resp;
      }).catch(() => caches.match(e.request).then((cached) => cached || Response.error()))
    );
    return;
  }

  // Documents: network-first, cache as offline fallback — cache-first here
  // would pin live-edited pages (app.html) until the next CACHE stamp.
  // The network gets 3.5 s (Tor links are the normal case, not the edge
  // case): past that, serve the cached copy immediately while the same
  // in-flight fetch keeps going as the no-cache last resort.
  if (e.request.mode === 'navigate') {
    e.respondWith((async () => {
      const inflight = fetch(e.request).then((resp) => {
        if (resp.ok) { const copy = resp.clone(); caches.open(CACHE).then((c) => keep(c, e.request, copy)); }
        return resp;
      });
      try {
        return await Promise.race([
          inflight,
          new Promise((_, rej) => setTimeout(() => rej(new Error('slow')), 3500)),
        ]);
      } catch (_) {
        // ignoreSearch: /app.html?turn=week must find the cached /app.html
        return (await caches.match(e.request, { ignoreSearch: true })) || inflight;
      }
    })());
    return;
  }

  // WASM + vendor JS: stale-while-revalidate (fast load, update in background)
  if (path.endsWith('.wasm') || path.startsWith('/vendor/')) {
    e.respondWith(
      caches.open(CACHE).then((c) =>
        c.match(e.request).then((cached) => {
          const fetched = fetch(fresh(e.request)).then((resp) => {
            if (resp.ok) keep(c, e.request, resp.clone());
            return resp;
          }).catch(() => cached);
          return cached || fetched;
        })
      )
    );
    return;
  }

  // Everything else: cache-first. A file of the build fetched on a miss joins
  // the build's cache, so the dial an online visit loaded is the dial an
  // offline one finds. A path outside the tree's roots is a server route; it
  // is served from the network and left there.
  e.respondWith(
    caches.open(CACHE).then((c) =>
      c.match(e.request).then((cached) => {
        if (cached) return cached;
        if (!underRoot(path)) return fetch(e.request);
        return fetch(fresh(e.request)).then((resp) => {
          if (resp.ok) keep(c, e.request, resp.clone());
          return resp;
        });
      })
    )
  );
});

self.addEventListener('push', (e) => {
  e.waitUntil((async () => {
    try {
      const p = e.data?.json() ?? {};
      const n = p.notification ?? {};
      await self.registration.showNotification(n.title || 'playnet', {
        body: n.body || '', icon: n.icon || '/assets/icons/icon-192.png',
        tag: n.tag, data: n.data || {}
      });
    } catch (_) {
      await self.registration.showNotification('playnet', {
        body: 'New activity — tap to view', icon: '/assets/icons/icon-192.png'
      });
    }
  })());
});

// The browser replaced the push subscription. The gateway learns a
// subscription from the page, over the session it holds (register-push), so
// the worker renews it and tells every open page; a page that is closed
// registers the new one when it next opens.
self.addEventListener('pushsubscriptionchange', (e) => {
  e.waitUntil(
    self.registration.pushManager.subscribe(e.oldSubscription?.options ?? { userVisibleOnly: true })
      .then((sub) => clients.matchAll({ type: 'window' }).then((wins) =>
        wins.forEach((w) => w.postMessage({ type: 'push-subscription', subscription: sub.toJSON() }))))
      .catch(() => {})
  );
});

// A tap opens what the notification is about: an open window goes there and
// takes focus, and with none open a new one is.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || '/', self.location.origin).href;
  e.waitUntil(
    clients.matchAll({ type: 'window' }).then(async (wins) => {
      const w = wins.find((c) => new URL(c.url).origin === self.location.origin);
      if (!w) return clients.openWindow(url);
      if (e.notification.data?.url && w.url !== url) await w.navigate(url).catch(() => {});
      return w.focus();
    })
  );
});
