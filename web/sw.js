// Service worker: caches the app shell so Vox opens offline. API calls always go to the network.
const VERSION = 'vox-web-v1';
const SHELL = [
  './', 'index.html', 'manifest.webmanifest', 'css/app.css', 'worklet.js',
  'js/app.js', 'js/util.js', 'js/store.js', 'js/settings.js', 'js/llm.js', 'js/stt.js', 'js/ai.js',
  'js/processing.js', 'js/recorder.js', 'js/omi.js', 'js/markdown.js', 'proxy-worker.js',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET') return;
  const sameOrigin = url.origin === self.location.origin;
  const cdn = url.hostname === 'cdn.jsdelivr.net';
  if (!sameOrigin && !cdn) return;
  // Network first (fresh code after updates), cache fallback (offline).
  // `no-cache` revalidates with the server, so a new version is picked up right away
  // (GitHub Pages otherwise lets the browser reuse files for 10 minutes).
  const fresh = sameOrigin ? fetch(url.href, { cache: 'no-cache', credentials: 'same-origin' }) : fetch(e.request);
  e.respondWith(
    fresh
      .then(res => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(VERSION).then(c => c.put(e.request, copy));
        }
        return res;
      })
      .catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match('index.html')))
  );
});
