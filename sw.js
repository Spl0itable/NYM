const CACHE = 'nym-' + '__CACHE_VERSION__';
const ASSET_RE = /\/(js|css|data|images)\//;
let PRECACHE = [];
try { PRECACHE = JSON.parse('__PRECACHE_ASSETS__'); } catch (_) { }

// Proxied media (avatars, banners, inline chat images, custom emoji) is served
// from /api/proxy. It lives in its own cache that survives deploys so reloads
// and cold webview launches reuse images instead of refetching every one.
const MEDIA_CACHE = 'nym-media-v1';
const MEDIA_MAX_ENTRIES = 600;
const MEDIA_MAX_BYTES = 100 * 1024 * 1024;
const MEDIA_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const MEDIA_STAMP = 'x-nym-cached-at';
const MEDIA_SIZE = 'x-nym-size';

function mediaStamp(resp) {
    const t = Number(resp && resp.headers && resp.headers.get(MEDIA_STAMP));
    return Number.isFinite(t) && t > 0 ? t : 0;
}

function mediaFresh(resp, now) {
    const t = mediaStamp(resp);
    return t > 0 && t <= now + 60000 && now - t < MEDIA_MAX_AGE_MS;
}

let mediaPruning = null;
let mediaPruneAgain = false;

async function pruneMediaCache() {
    const cache = await caches.open(MEDIA_CACHE);
    const keys = await cache.keys();
    const now = Date.now();
    const live = [];
    const drop = [];
    for (const k of keys) {
        const r = await cache.match(k);
        if (!r || !mediaFresh(r, now)) { drop.push(k); continue; }
        const size = Number(r.headers.get(MEDIA_SIZE)) || 0;
        live.push({ k, t: mediaStamp(r), size });
    }
    live.sort((a, b) => a.t - b.t);
    let bytes = live.reduce((n, x) => n + x.size, 0);
    let count = live.length;
    for (const x of live) {
        if (count <= MEDIA_MAX_ENTRIES && bytes <= MEDIA_MAX_BYTES) break;
        drop.push(x.k);
        count--;
        bytes -= x.size;
    }
    await Promise.all(drop.map((k) => cache.delete(k)));
}

function trimMediaCache() {
    if (mediaPruning) { mediaPruneAgain = true; return mediaPruning; }
    mediaPruning = (async () => {
        try {
            do {
                mediaPruneAgain = false;
                await pruneMediaCache();
            } while (mediaPruneAgain);
        } catch (_) { }
        mediaPruning = null;
    })();
    return mediaPruning;
}

async function storeMedia(cache, req, resp) {
    try {
        const body = await resp.blob();
        if (body.size > MEDIA_MAX_BYTES) return;
        const headers = new Headers(resp.headers);
        headers.set(MEDIA_STAMP, String(Date.now()));
        headers.set(MEDIA_SIZE, String(body.size));
        await cache.put(req, new Response(body, { status: resp.status, statusText: resp.statusText, headers }));
        await trimMediaCache();
    } catch (_) { }
}

let mediaStartupPruned = false;

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
        await Promise.all(keys.filter((k) => k.startsWith('nym-') && k !== CACHE && k !== MEDIA_CACHE).map((k) => caches.delete(k)));
        mediaStartupPruned = true;
        await trimMediaCache();
        await self.clients.claim();
    })());
});

self.addEventListener('fetch', (e) => {
    const req = e.request;
    if (req.method !== 'GET') return;
    const url = new URL(req.url);

    // Brand icons/images live on the marketing origin; cache-first so cold
    // starts and offline launches don't refetch them on every load.
    if (url.origin === 'https://nymchat.app' && url.pathname.startsWith('/images/')) {
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
        return;
    }

    if (url.origin !== self.location.origin) return;

    // Proxied media keyed by its source URL is effectively immutable, so serve
    // cache-first and only refetch images the device hasn't seen. Range requests
    // (video seeking) and non-image responses are passed through uncached.
    if (url.pathname === '/api/proxy' && url.searchParams.has('url') && !req.headers.has('range')) {
        if (!mediaStartupPruned) {
            mediaStartupPruned = true;
            const startup = trimMediaCache();
            if (e.waitUntil) e.waitUntil(startup);
        }
        e.respondWith((async () => {
            const cache = await caches.open(MEDIA_CACHE);
            const cached = await cache.match(req);
            if (cached) {
                if (mediaFresh(cached, Date.now())) return cached;
                await cache.delete(req);
            }
            const resp = await fetch(req);
            const type = resp && resp.headers.get('content-type') || '';
            if (resp && resp.ok && type.indexOf('image/') === 0) {
                const stored = storeMedia(cache, req, resp.clone());
                if (e.waitUntil) e.waitUntil(stored);
            }
            return resp;
        })());
        return;
    }

    if (req.mode === 'navigate') {
        e.respondWith((async () => {
            const cache = await caches.open(CACHE);
            try {
                const resp = await fetch(req);
                if (resp && resp.ok && (url.pathname === '/' || url.pathname === '/index.html')
                    && (resp.headers.get('content-type') || '').indexOf('text/html') === 0) cache.put('/', resp.clone());
                return resp;
            } catch (_) {
                const cached = (await cache.match(req)) || (await cache.match('/'));
                return cached || Response.error();
            }
        })());
        return;
    }

    // Pre-translated UI packs (/i18n/<lang>.json). Unhashed, so served from
    // cache first and refreshed in the background: a language already used once
    // keeps working offline, and a newer pack lands on the next switch.
    if (url.origin === self.location.origin && url.pathname.startsWith('/i18n/')) {
        e.respondWith((async () => {
            const cache = await caches.open(CACHE);
            const cached = await cache.match(req);
            const network = fetch(req).then((resp) => {
                if (resp && resp.ok) cache.put(req, resp.clone());
                return resp;
            }).catch(() => cached || Response.error());
            return cached || network;
        })());
        return;
    }

    // Hashed assets are immutable, and the cache name rotates per build.
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
