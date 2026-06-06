const CACHE = 'nym-' + '__CACHE_VERSION__';
const ASSET_RE = /\/(js|css)\//;
let PRECACHE = [];
try { PRECACHE = JSON.parse('__PRECACHE_ASSETS__'); } catch (_) { }

self.addEventListener('install', (e) => {
    e.waitUntil((async () => {
        try {
            const c = await caches.open(CACHE);
            // Entry document plus the critical JS/CSS bundle.
            await c.add(new Request('/', { cache: 'reload' }));
            if (PRECACHE.length) {
                await Promise.all(PRECACHE.map((u) =>
                    c.add(new Request(u, { cache: 'reload' })).catch(() => { })
                ));
            }
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
            const cache = await caches.open(CACHE);
            const cached = (await cache.match(req)) || (await cache.match('/'));
            const network = fetch(req).then((resp) => {
                if (resp && resp.ok) cache.put('/', resp.clone());
                return resp;
            }).catch(() => null);
            return cached || (await network) || Response.error();
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
