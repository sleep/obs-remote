/* Elgato Capture Remote — service worker for PWA / offline shell */
const CACHE = 'capture-remote-v2';
const SHELL = [
  '/',
  '/app.css',
  '/app.js',
  '/icon-180.png',
  '/icon-192.png',
  '/icon-512.png',
  'https://cdn.jsdelivr.net/npm/framework7@8/framework7-bundle.min.css',
  'https://cdn.jsdelivr.net/npm/framework7@8/framework7-bundle.min.js',
  'https://cdn.jsdelivr.net/npm/framework7-icons@5/css/framework7-icons.css',
];

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(
    caches.open(CACHE).then((c) =>
      Promise.allSettled(SHELL.map((u) => c.add(new Request(u, { cache: 'reload' }))))
    )
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Never cache the API or live preview — always go to the network.
  if (url.pathname.startsWith('/api/')) {
    e.respondWith(fetch(e.request).catch(() => new Response('{}', {
      headers: { 'Content-Type': 'application/json' }, status: 503,
    })));
    return;
  }

  // Stale-while-revalidate for the shell + CDN assets.
  e.respondWith(
    caches.match(e.request).then((cached) => {
      const network = fetch(e.request).then((res) => {
        if (res && res.status === 200 && (url.origin === location.origin || url.host.includes('jsdelivr'))) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(e.request, copy));
        }
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});
