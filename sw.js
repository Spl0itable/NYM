const CACHE = 'nym-' + '__CACHE_VERSION__';
const ASSET_RE = /\/(js|css)\//;

self.addEventListener('install', (e) => {
    e.waitUntil((async () => {
        try {
            const c = await caches.open(CACHE);
            await c.add(new Request('/', { cache: 'reload' }));
        } catch (_) { }
        self.skipWaiting();
    })());
});

self.addEventListener('activate', (e) => {
    e.waitUntil((async () => {
        const keys = await caches.keys();
        await Promise.all(keys.filter((k) => k.startsWith('nym-') && k !== CACHE).map((k) => caches.delete(k)));
        await self.clients.claim();
    })());
});

self.addEventListener('fetch', (e) => {
    const req = e.request;
    if (req.method !== 'GET') return;
    const url = new URL(req.url);
    if (url.origin !== self.location.origin) return;

    if (req.mode === 'navigate') {
        e.respondWith((async () => {
            try {
                return await fetch(req);
            } catch (_) {
                return (await caches.match(req)) || (await caches.match('/')) || Response.error();
            }
        })());
        return;
    }

    if (ASSET_RE.test(url.pathname)) {
        e.respondWith((async () => {
            const cached = await caches.match(req);
            if (cached) return cached;
            const resp = await fetch(req);
            if (resp && resp.ok) {
                const cache = await caches.open(CACHE);
                cache.put(req, resp.clone());
            }
            return resp;
        })());
    }
});
