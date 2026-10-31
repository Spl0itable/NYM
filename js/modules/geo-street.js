(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const DB_NAME = 'nym-map';
    const DB_VERSION = 2;
    const META_PATH = '/api/map/v2/meta';
    const META_KEY = 'meta';
    const MERC = 85.0511287798;
    const TILE_COUNT_MAX = 512;
    const EDGE = 1e-9;
    const config = { cacheBytes: 50331648, memoryBytes: 16777216, gzipBytes: 16777216, blockBytes: 33554432, forceMainRaster: false };
    const session = { sent: [], pausedUntil: 0, stopped: false, neg: new Map(), build: 0, metaAt: 0 };
    const P = () => G.NymGeoExplore.STREET2;

    function nextTileFetches(o) {
        const S = P();
        const recent = o.sent.filter((t) => o.now - t < S.windowMs).sort((a, b) => a - b);
        const slots = Math.max(0, Math.min(S.concurrent - o.inflight, S.maxPer10s - recent.length));
        const start = o.queue.slice(0, slots);
        const capped = o.queue.length > start.length && recent.length >= S.maxPer10s;
        return { start, waitMs: capped ? recent[0] + S.windowMs - o.now : 0 };
    }

    function cancelSet(inflight, wanted) {
        const W = new Set(wanted);
        return inflight.filter((k) => !W.has(k));
    }

    function statusAction(status, body) {
        const S = P();
        if (status === 200) return { kind: 'ok', ms: 0 };
        if (status === 404) {
            try {
                const j = JSON.parse(body || '');
                if (j && j.error === 'build' && Number.isInteger(j.build) && j.build > 0) return { kind: 'rebuild', ms: 0, build: j.build };
            } catch (_) { }
            return { kind: 'stop', ms: 0 };
        }
        if (status === 413) return { kind: 'negative', ms: S.tooLargeRetryMs };
        if (status === 422) return { kind: 'negative', ms: S.malformedRetryMs };
        if (status === 0 || status === 429 || status >= 500) return { kind: 'pause', ms: S.unavailableRetryMs };
        return { kind: 'stop', ms: 0 };
    }

    function bodyKind(u8) {
        if (!u8 || !u8.length) return 'empty';
        if (u8.length > P().maxBodyBytes) return 'bad';
        return u8[0] === 0x1f && u8[1] === 0x8b ? 'gzip' : 'bad';
    }

    function evictionList(meta, cap) {
        const live = meta.filter((m) => m && !m.status && typeof m.size === 'number').sort((a, b) => a.usedAt - b.usedAt);
        let total = live.reduce((a, m) => a + m.size, 0);
        const out = [];
        for (const m of live) {
            if (total <= cap) break;
            out.push(m.key);
            total -= m.size;
        }
        return out;
    }

    const otherBuild = (meta, build) => meta.filter((m) => m && m.key !== META_KEY && !String(m.key).startsWith(build + '/')).map((m) => m.key);
    const expired = (m, now) => now - m.savedAt > P().cacheTtlMs;
    const bucketExp = (pxPerDeg) => Math.round(2 * Math.log2(pxPerDeg));
    const bucketScale = (e) => 2 ** (e / 2);
    const tileLat = (y, z) => (2 * Math.atan(Math.exp(Math.PI * (1 - 2 * y / 2 ** z))) - Math.PI / 2) * 180 / Math.PI;
    const mercY = (lat) => { const r = lat * Math.PI / 180; return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2; };
    const isQuota = (e) => !!e && (e.name === 'QuotaExceededError' || e.code === 22);

    const rq = (r) => new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
    const txDone = (tx) => new Promise((res, rej) => { tx.oncomplete = () => res(); tx.onerror = () => rej(tx.error); tx.onabort = () => rej(tx.error); });

    let dbPromise = null;
    let halted = false;
    const layers = new Set();
    function openDb() {
        if (halted) return Promise.resolve(null);
        if (dbPromise) return dbPromise;
        dbPromise = new Promise((resolve) => {
            let req;
            try { req = indexedDB.open(DB_NAME, DB_VERSION); } catch (_) { resolve(null); return; }
            req.onupgradeneeded = () => {
                const db = req.result;
                for (const n of ['cells', 'meta']) if (db.objectStoreNames.contains(n)) db.deleteObjectStore(n);
                if (!db.objectStoreNames.contains('tiles')) db.createObjectStore('tiles', { keyPath: 'key' });
                if (!db.objectStoreNames.contains('tmeta')) db.createObjectStore('tmeta', { keyPath: 'key' });
            };
            req.onsuccess = () => {
                const db = req.result;
                db.onversionchange = (e) => { try { db.close(); } catch (_) { } dbPromise = null; if (e && e.newVersion === null) halted = true; };
                resolve(db);
            };
            req.onerror = () => resolve(null);
            req.onblocked = () => resolve(null);
        });
        return dbPromise;
    }

    const mem = new Map();
    let storeMode = 'idb';
    const memEvict = () => {
        for (const k of evictionList([...mem.values()].map((v) => v.meta), config.memoryBytes)) mem.delete(k);
    };
    const memPut = (key, meta, bytes) => { if (halted) return; storeMode = 'memory'; mem.set(key, { meta, bytes }); memEvict(); };

    const store = {
        async get(key, now) {
            const m = mem.get(key);
            if (m) {
                if (m.meta.status) return m.meta.until > now ? { neg: m.meta } : null;
                if (expired(m.meta, now)) { mem.delete(key); return null; }
                m.meta.usedAt = now;
                return { bytes: m.bytes, meta: m.meta };
            }
            const db = await openDb();
            if (!db) return null;
            try {
                const tx = db.transaction(['tmeta', 'tiles'], 'readonly');
                const meta = await rq(tx.objectStore('tmeta').get(key));
                if (!meta) return null;
                if (meta.status) return meta.until > now ? { neg: meta } : null;
                if (expired(meta, now)) { store.del(key); return null; }
                const ent = await rq(tx.objectStore('tiles').get(key));
                if (!ent || !ent.bytes) return null;
                store.touch(key, now);
                return { bytes: new Uint8Array(ent.bytes), meta };
            } catch (_) { return null; }
        },
        async put(key, build, bytes, now) {
            const meta = { key, build, size: bytes.byteLength, savedAt: now, usedAt: now };
            const db = await openDb();
            if (!db) { memPut(key, meta, bytes); return; }
            const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            const write = async () => {
                const tx = db.transaction(['tmeta', 'tiles'], 'readwrite');
                tx.objectStore('tiles').put({ key, bytes: ab });
                tx.objectStore('tmeta').put(meta);
                await txDone(tx);
            };
            try { await write(); }
            catch (e) {
                if (!isQuota(e)) { memPut(key, meta, bytes); return; }
                await store.evict(Math.floor(config.cacheBytes / 2));
                try { await write(); } catch (_) { memPut(key, meta, bytes); return; }
            }
            await store.evict(config.cacheBytes);
        },
        async putNeg(key, status, until) {
            const meta = { key, status, until };
            const db = await openDb();
            if (!db) { if (!halted) mem.set(key, { meta, bytes: null }); return; }
            try {
                const tx = db.transaction(['tmeta', 'tiles'], 'readwrite');
                tx.objectStore('tmeta').put(meta);
                tx.objectStore('tiles').delete(key);
                await txDone(tx);
            } catch (_) { mem.set(key, { meta, bytes: null }); }
        },
        async touch(key, now) {
            const db = await openDb();
            if (!db) return;
            try {
                const tx = db.transaction(['tmeta'], 'readwrite');
                const os = tx.objectStore('tmeta');
                const m = await rq(os.get(key));
                if (m && !m.status && m.key !== META_KEY) { m.usedAt = now; os.put(m); }
                await txDone(tx);
            } catch (_) { }
        },
        async del(key) {
            mem.delete(key);
            const db = await openDb();
            if (!db) return;
            try {
                const tx = db.transaction(['tmeta', 'tiles'], 'readwrite');
                tx.objectStore('tmeta').delete(key);
                tx.objectStore('tiles').delete(key);
                await txDone(tx);
            } catch (_) { }
        },
        async evict(cap, build) {
            if (build) for (const k of otherBuild([...mem.values()].map((v) => v.meta), build)) mem.delete(k);
            const db = await openDb();
            if (!db) return;
            try {
                const tx = db.transaction(['tmeta', 'tiles'], 'readwrite');
                const metas = (await rq(tx.objectStore('tmeta').getAll())).filter((m) => m && m.key !== META_KEY);
                const now = Date.now();
                const gone = new Set(build ? otherBuild(metas, build) : []);
                for (const m of metas) {
                    if (m.status ? m.until <= now : expired(m, now)) gone.add(m.key);
                }
                for (const k of evictionList(metas.filter((m) => !gone.has(m.key)), cap)) gone.add(k);
                for (const k of gone) { tx.objectStore('tmeta').delete(k); tx.objectStore('tiles').delete(k); }
                await txDone(tx);
            } catch (_) { }
        },
        async getMeta() {
            const m = mem.get(META_KEY);
            if (m) return m.meta;
            const db = await openDb();
            if (!db) return null;
            try { return (await rq(db.transaction(['tmeta'], 'readonly').objectStore('tmeta').get(META_KEY))) || null; } catch (_) { return null; }
        },
        async setMeta(build, fetchedAt) {
            const meta = { key: META_KEY, build, fetchedAt };
            const db = await openDb();
            if (!db) { if (!halted) mem.set(META_KEY, { meta, bytes: null }); return; }
            try {
                const tx = db.transaction(['tmeta'], 'readwrite');
                tx.objectStore('tmeta').put(meta);
                await txDone(tx);
            } catch (_) { mem.set(META_KEY, { meta, bytes: null }); }
        },
        async list() {
            const db = await openDb();
            if (!db) return [...mem.values()].map((v) => v.meta);
            try { return await rq(db.transaction(['tmeta'], 'readonly').objectStore('tmeta').getAll()); } catch (_) { return []; }
        },
    };

    let decodeLib = null;
    const loadDecodeLib = () => decodeLib || (decodeLib = new Promise((res) => {
        if (G.NymStreetDecode) { res(G.NymStreetDecode); return; }
        const s = document.createElement('script');
        s.src = '/js/geo-street-worker.js';
        s.onload = () => res(G.NymStreetDecode || null);
        s.onerror = () => res(null);
        document.head.appendChild(s);
    }));

    function halt() {
        halted = true;
        for (const stop of layers) { try { stop(); } catch (_) { } }
        mem.clear();
        const p = dbPromise;
        dbPromise = null;
        if (p) p.then((db) => { try { if (db) db.close(); } catch (_) { } });
    }

    const EMPTY_BLOCK = (ver) => ({ empty: true, n: 0, bytes: 0, ver });
    const fetchOpts = (signal) => ({ credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer', signal });

    function createLayer(host) {
        const X = G.NymGeoExplore;
        const S = X.STREET2;
        let enabled = !!host.enabled;
        let destroyed = false;
        const tiles = new Map();
        let memBytes = 0;
        const inflight = new Map();
        let queue = [];
        let wanted = [];
        let pumpTimer = 0, settleTimer = 0, labelTimer = 0, idleTimer = 0, settleSeq = 0;
        let plan = { zv: 0, bucketExp: 0, bucketZv: 0, tz: null, draw: false, visible: 0, tiles: [] };
        let viewKey = '', changedAt = 0;
        let worker = null, workerRaster = null, nextId = 1, gen = 0, ver = 0;
        let metaPromise = null;
        const pending = new Map();
        const blocks = new Map();
        const dirty = new Map();
        const bucketTz = new Map();
        let blockBytes = 0;
        const rasterWant = new Map();
        let labels = [], labelsAt = 0, labelSeq = 0, shown = [];
        let attr = false;
        const textW = new Map();
        const stats = { blit: [], raster: [], decode: [], tilesDrawn: 0, blocksDrawn: 0, standIn: 0, provisional: 0, requests: [], cancelled: [], cacheHits: 0 };
        const push = (arr, v) => { arr.push(v); if (arr.length > 600) arr.shift(); };
        store.evict(config.cacheBytes, session.build);

        const setAttr = (on) => { if (on !== attr) { attr = on; host.setAttribution(on); } };

        const tileInfo = (z, x, y) => {
            const N = 2 ** z;
            return { z, x, y, key: z + '/' + x + '/' + y, lngW: x / N * 360 - 180, lngE: (x + 1) / N * 360 - 180, latN: tileLat(y, z), latS: tileLat(y + 1, z) };
        };
        const overlaps = (a, lngW, lngE, latS, latN) => !(a.lngE <= lngW || a.lngW >= lngE || a.latS >= latN || a.latN <= latS);
        const cacheKeyOf = (key, build) => build + '/' + key;
        const hasDrawable = () => { for (const t of tiles.values()) if (!t.empty) return true; return false; };

        const postTile = (t) => {
            if (!worker || t.empty) return;
            const gz = t.bytes.slice().buffer;
            worker.postMessage({ op: 'add', tiles: [{ key: t.key, z: t.z, x: t.x, y: t.y, level: 0, gz }] }, [gz]);
        };

        const closeBlock = (b) => { if (b && b.img && typeof b.img.close === 'function') { try { b.img.close(); } catch (_) { } } };
        const deleteBlock = (k) => { const b = blocks.get(k); if (!b) return; blockBytes -= b.bytes; closeBlock(b); blocks.delete(k); dirty.delete(k); };
        const clearBlocks = () => { for (const k of [...blocks.keys()]) deleteBlock(k); dirty.clear(); gen++; rasterWant.clear(); };
        const invalidateArea = (a) => {
            ver++;
            for (const [k, b] of blocks) if (overlaps(b, a.lngW, a.lngE, a.latS, a.latN)) dirty.set(k, ver);
            for (const w of pending.values()) if (w.spec && overlaps(w.spec, a.lngW, a.lngE, a.latS, a.latN)) dirty.set(w.key, ver);
        };
        const newer = (k, v) => { const b = blocks.get(k); return !b || b.ver <= v; };
        const storeBlock = (k, img, bytes, n, spec, v) => {
            const old = blocks.get(k);
            if (old && old.ver > v) { closeBlock({ img }); return; }
            if (old) { blockBytes -= old.bytes; closeBlock(old); blocks.delete(k); }
            blocks.set(k, { img, bytes, n, ver: v, missing: spec.missing, lngW: spec.lngW, lngE: spec.lngE, latN: spec.latN, latS: spec.latS });
            if ((dirty.get(k) || 0) <= v) dirty.delete(k);
            blockBytes += bytes;
            for (const key of blocks.keys()) {
                if (blockBytes <= config.blockBytes) break;
                if (key !== k) deleteBlock(key);
            }
        };
        const stale = (k) => { const b = blocks.get(k); return !b || (dirty.get(k) || 0) > b.ver; };

        const paintMain = async (w, list) => {
            const D = await loadDecodeLib();
            if (!D || destroyed || w.gen !== gen) return;
            try {
                const canvas = document.createElement('canvas');
                canvas.width = canvas.height = w.size;
                const c2 = canvas.getContext('2d');
                const n = D.paintBlock(c2, list, w.req);
                storeBlock(w.key, canvas, w.size * w.size * 4, n, w.spec, w.ver);
            } catch (_) { if (newer(w.key, w.ver)) { deleteBlock(w.key); blocks.set(w.key, EMPTY_BLOCK(w.ver)); } }
            host.requestDraw();
        };

        const negative = (key, build, ms, status) => {
            const ck = cacheKeyOf(key, build), until = Date.now() + ms;
            session.neg.set(ck, until);
            store.putNeg(ck, status, until);
        };
        const negActive = (key, now) => (session.neg.get(cacheKeyOf(key, session.build)) || 0) > now;

        const dropTile = (key) => {
            const t = tiles.get(key);
            if (!t) return;
            tiles.delete(key);
            memBytes -= t.size;
            if (worker && !t.empty) worker.postMessage({ op: 'drop', keys: [key] });
        };

        const onWorker = (e) => {
            const d = e.data || {};
            if (d.op === 'ready') { workerRaster = !!d.raster; return; }
            if (d.op === 'bad') {
                const t = tiles.get(d.key);
                if (t) { dropTile(d.key); negative(d.key, t.build, S.malformedRetryMs, 422); invalidateArea(t); host.requestDraw(); }
                return;
            }
            const w = pending.get(d.id);
            pending.delete(d.id);
            if (d.op === 'labels') { if (w && w.labels) w.labels(d.items || []); return; }
            if (!w) { if (d.bitmap) d.bitmap.close(); return; }
            if (rasterWant.get(w.key) === w.ver) rasterWant.delete(w.key);
            if (typeof d.decodeMs === 'number') push(stats.decode, d.decodeMs);
            if (destroyed || w.gen !== gen) { if (d.bitmap) d.bitmap.close(); if (!destroyed) host.requestDraw(); return; }
            if (d.op === 'block' && !d.bitmap) { if (newer(w.key, w.ver)) { deleteBlock(w.key); blocks.set(w.key, EMPTY_BLOCK(w.ver)); } }
            else if (d.op === 'block') {
                push(stats.raster, d.ms);
                storeBlock(w.key, d.bitmap, w.size * w.size * 4, d.n, w.spec, w.ver);
                host.requestDraw();
            } else if (d.op === 'geom') {
                paintMain(w, d.tiles || []);
            }
        };

        const startWorker = () => {
            if (worker || destroyed) return;
            try { worker = new Worker('/js/geo-street-worker.js'); } catch (_) { worker = null; return; }
            worker.onmessage = onWorker;
            worker.postMessage({ op: 'init', noRaster: !!config.forceMainRaster });
            for (const t of tiles.values()) postTile(t);
        };
        const stopWorker = () => {
            if (worker) { try { worker.terminate(); } catch (_) { } }
            worker = null;
            workerRaster = null;
            pending.clear();
            rasterWant.clear();
        };

        const trimTiles = () => {
            const keep = new Set(wanted);
            while (memBytes > config.gzipBytes || tiles.size > TILE_COUNT_MAX) {
                let old = null;
                for (const t of tiles.values()) if (!keep.has(t.key) && (!old || t.usedAt < old.usedAt)) old = t;
                if (!old) break;
                dropTile(old.key);
            }
        };

        const addTile = (key, build, bytes) => {
            if (destroyed || !enabled || build !== session.build) return;
            const [z, x, y] = key.split('/').map(Number);
            if (tiles.has(key)) dropTile(key);
            const t = Object.assign(tileInfo(z, x, y), { build, bytes: bytes.length ? bytes : null, size: bytes.length, empty: !bytes.length, usedAt: Date.now() });
            tiles.set(key, t);
            memBytes += t.size;
            postTile(t);
            invalidateArea(t);
            trimTiles();
            host.requestDraw();
            placeLabels();
        };

        const abortAll = () => {
            for (const ac of inflight.values()) { try { ac.abort(); } catch (_) { } }
            inflight.clear();
            queue = [];
            clearTimeout(pumpTimer);
        };

        const setBuild = (build) => {
            if (!build || build === session.build) return;
            const had = session.build;
            session.build = build;
            if (had) {
                abortAll();
                for (const k of [...tiles.keys()]) dropTile(k);
                if (worker) worker.postMessage({ op: 'clear' });
                clearBlocks();
                labels = [];
            }
            store.evict(config.cacheBytes, build);
        };

        const ensureMeta = () => {
            if (session.build && Date.now() - session.metaAt < S.metaTtlMs) return Promise.resolve(session.build);
            if (metaPromise) return metaPromise;
            metaPromise = (async () => {
                if (!session.build) {
                    const m = await store.getMeta();
                    if (m && Number.isInteger(m.build) && m.build > 0) { session.build = m.build; session.metaAt = typeof m.fetchedAt === 'number' ? m.fetchedAt : 0; }
                }
                const now = Date.now();
                if (session.build && now - session.metaAt < S.metaTtlMs) return session.build;
                if (halted || destroyed || !enabled || session.stopped || now < session.pausedUntil) return session.build;
                let status = 0;
                try {
                    const resp = await fetch(META_PATH, fetchOpts());
                    status = resp.status;
                    if (status === 200) {
                        const j = await resp.json();
                        if (j && j.v === 2 && Number.isInteger(j.build) && j.build > 0) {
                            setBuild(j.build);
                            session.metaAt = Date.now();
                            store.setMeta(j.build, session.metaAt);
                            return session.build;
                        }
                        status = 422;
                    }
                } catch (_) { status = status || 0; }
                const act = statusAction(status, '');
                if (act.kind === 'stop' || act.kind === 'negative') session.stopped = true;
                else session.pausedUntil = Date.now() + S.unavailableRetryMs;
                return session.build;
            })().finally(() => { metaPromise = null; });
            return metaPromise;
        };

        const settledLongEnough = () => performance.now() - changedAt >= S.settleMs - 5;
        const blockedNow = () => halted || destroyed || !enabled || session.stopped || Date.now() < session.pausedUntil || (typeof document !== 'undefined' && document.hidden);

        const pump = () => {
            clearTimeout(pumpTimer);
            if (blockedNow() || !session.build) { queue = []; return; }
            if (!plan.draw) { queue = []; return; }
            if (!settledLongEnough()) return;
            const want = new Set(wanted);
            queue = queue.filter((k) => want.has(k) && !tiles.has(k) && !inflight.has(k));
            const now = Date.now();
            session.sent = session.sent.filter((t) => now - t < S.windowMs);
            const r = nextTileFetches({ queue, inflight: inflight.size, sent: session.sent, now });
            for (const k of r.start) { queue = queue.filter((x) => x !== k); fetchTile(k); }
            if (r.waitMs && queue.length) pumpTimer = setTimeout(pump, r.waitMs);
        };

        const fetchTile = async (key) => {
            const build = session.build;
            const [z, x, y] = key.split('/').map(Number);
            const url = X.tilePath(build, z, x, y);
            const ac = new AbortController();
            inflight.set(key, ac);
            push(stats.requests, url);
            let status = 0, bytes = null, body = '';
            try {
                const started = fetch(url, fetchOpts(ac.signal));
                session.sent.push(Date.now());
                const resp = await started;
                status = resp.status;
                if (status === 200) bytes = new Uint8Array(await resp.arrayBuffer());
                else if (status === 404) body = await resp.text().catch(() => '');
            } catch (_) {
                if (ac.signal.aborted) { if (inflight.get(key) === ac) inflight.delete(key); return; }
                status = 0;
            }
            if (inflight.get(key) === ac) inflight.delete(key);
            if (halted || destroyed || ac.signal.aborted) return;
            if (build !== session.build) { pump(); return; }
            const act = statusAction(status, body);
            if (act.kind === 'ok') {
                if (bodyKind(bytes) === 'bad') negative(key, build, S.malformedRetryMs, 422);
                else { addTile(key, build, bytes); store.put(cacheKeyOf(key, build), build, bytes, Date.now()); }
            } else if (act.kind === 'negative') negative(key, build, act.ms, status);
            else if (act.kind === 'pause') { session.pausedUntil = Date.now() + act.ms; queue = []; }
            else if (act.kind === 'stop') { session.stopped = true; queue = []; }
            else if (act.kind === 'rebuild') {
                setBuild(act.build);
                session.metaAt = Date.now();
                store.setMeta(act.build, session.metaAt);
                armSettle();
                return;
            }
            pump();
        };

        const fromDevice = async (key, build, now) => {
            const ck = cacheKeyOf(key, build);
            const r = await store.get(ck, now);
            if (!r || destroyed) return;
            if (r.neg) { session.neg.set(ck, r.neg.until); return; }
            if (bodyKind(r.bytes) === 'bad') { store.del(ck); return; }
            stats.cacheHits++;
            addTile(key, build, r.bytes);
        };

        const settle = async () => {
            settleTimer = 0;
            if (halted || destroyed || !enabled) return;
            const seq = ++settleSeq;
            const p = X.planTiles(host.view());
            const want = p.draw ? p.tiles.map((t) => t.join('/')) : [];
            wanted = want;
            for (const k of cancelSet([...inflight.keys()], want)) {
                const ac = inflight.get(k);
                inflight.delete(k);
                try { ac.abort(); } catch (_) { }
                push(stats.cancelled, k);
            }
            queue = queue.filter((k) => want.includes(k));
            if (!p.draw) return;
            const now = Date.now();
            for (const k of want) { const t = tiles.get(k); if (t) t.usedAt = now; }
            const build = await ensureMeta();
            if (seq !== settleSeq || destroyed || !enabled || !build) return;
            await Promise.all(want.filter((k) => !tiles.has(k) && !inflight.has(k) && !negActive(k, now)).map((k) => fromDevice(k, build, now)));
            if (seq !== settleSeq || destroyed || !enabled || build !== session.build) return;
            const t = Date.now();
            queue = want.filter((k) => !tiles.has(k) && !inflight.has(k) && !negActive(k, t));
            pump();
            placeLabels();
        };
        const armSettle = () => { clearTimeout(settleTimer); settleTimer = setTimeout(settle, S.settleMs); };

        const blockSpec = (e, tz, bx, by) => {
            const bs = bucketScale(e), deg = 256 / bs, lngW = -180 + bx * deg, latN = 90 - by * deg, lngE = lngW + deg, latS = latN - deg;
            const spec = { keys: [], clips: [], missing: [], lngW, lngE, latN, latS, deg, zv: X.bucketZvOf(e) };
            if (latS >= MERC || latN <= -MERC) return spec;
            const N = 2 ** tz;
            const x0 = Math.max(0, Math.floor((lngW + 180) / 360 * N + EDGE)), x1 = Math.min(N - 1, Math.ceil((lngE + 180) / 360 * N - EDGE) - 1);
            const y0 = Math.max(0, Math.floor(mercY(Math.min(latN, MERC)) * N + EDGE)), y1 = Math.min(N - 1, Math.ceil(mercY(Math.max(latS, -MERC)) * N - EDGE) - 1);
            const have = new Set(tiles.keys());
            const seen = new Set();
            for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
                const want = [tz, x, y];
                const f = X.fallbackFor(want, have);
                if (!f.length) { spec.missing.push(want.join('/')); continue; }
                const self = f.length === 1 && f[0][0] === tz;
                const up = f.length === 1 && f[0][0] < tz;
                if (!self) spec.missing.push(want.join('/'));
                for (const q of f) {
                    const k = q.join('/');
                    const t = tiles.get(k);
                    if (!t || t.empty) continue;
                    t.usedAt = Date.now();
                    if (up) {
                        const w = tileInfo(tz, x, y);
                        spec.keys.push(k);
                        spec.clips.push([w.lngW, w.latN, w.lngE, w.latS]);
                    } else if (!seen.has(k)) {
                        seen.add(k);
                        spec.keys.push(k);
                        spec.clips.push(null);
                    }
                }
            }
            return spec;
        };

        const requestRaster = (k, spec, theme) => {
            const dprC = host.dpr();
            const size = Math.max(1, Math.round(256 * dprC));
            const id = nextId++;
            const req = { op: 'raster', id, keys: spec.keys, clips: spec.clips, lngW: spec.lngW, latN: spec.latN, size, k: size / spec.deg, dpr: size / 256, zv: spec.zv, theme, edge: spec.zv >= 16.5, noRaster: !!config.forceMainRaster };
            pending.set(id, { key: k, size, gen, ver, spec, req });
            rasterWant.set(k, ver);
            worker.postMessage(req);
        };

        const blockRange = (v, e) => {
            const deg = 256 / bucketScale(e), s = v.pxPerDeg;
            const lngLo = Math.max(-180, v.cx - v.width / 2 / s), lngHi = Math.min(180, v.cx + v.width / 2 / s);
            const latLo = Math.max(-90, v.cy - v.height / 2 / s), latHi = Math.min(90, v.cy + v.height / 2 / s);
            return { bx0: Math.floor((lngLo + 180) / deg), bx1: Math.floor((lngHi + 180) / deg - 1e-12), by0: Math.floor((90 - latHi) / deg), by1: Math.floor((90 - latLo) / deg - 1e-12), deg };
        };

        const blit = (ctx, v, img, lngW, latN, deg) => {
            const s = v.pxPerDeg, dpr = host.dpr();
            const x0 = v.width / 2 + (lngW - v.cx) * s, y0 = v.height / 2 + (v.cy - latN) * s;
            const rx0 = Math.round(x0 * dpr) / dpr, ry0 = Math.round(y0 * dpr) / dpr;
            const rx1 = Math.round((x0 + deg * s) * dpr) / dpr, ry1 = Math.round((y0 + deg * s) * dpr) / dpr;
            ctx.drawImage(img, rx0, ry0, rx1 - rx0, ry1 - ry0);
        };

        const track = (v) => {
            const k = v.cx + '|' + v.cy + '|' + v.pxPerDeg + '|' + v.width + '|' + v.height;
            if (k === viewKey) return;
            viewKey = k;
            changedAt = performance.now();
            if (enabled) armSettle();
        };

        const frame = (ctx) => {
            const t0 = performance.now();
            const v = host.view();
            plan = X.planTiles(enabled ? v : Object.assign({}, v, { on: false }));
            track(v);
            stats.tilesDrawn = 0;
            stats.blocksDrawn = 0;
            stats.standIn = 0;
            stats.provisional = 0;
            if (!plan.draw) { setAttr(false); return false; }
            startWorker();
            if (!worker || !hasDrawable()) { setAttr(false); return false; }
            const e = plan.bucketExp, tz = plan.tz, theme = host.light() ? 'light' : 'dark';
            bucketTz.set(e, tz);
            const bk = (ee, tt, bx, by) => theme + '|' + ee + '|' + tt + '|' + bx + '|' + by;
            const r = blockRange(v, e);
            const need = [];
            let absent = false;
            for (let by = r.by0; by <= r.by1; by++) for (let bx = r.bx0; bx <= r.bx1; bx++) {
                const k = bk(e, tz, bx, by);
                if (!blocks.has(k)) absent = true;
                if (stale(k)) need.push([bx, by]);
            }
            ctx.save();
            ctx.imageSmoothingEnabled = true;
            const drawAlt = (alt) => {
                const atz = bucketTz.get(alt);
                if (atz === undefined) return;
                const ar = blockRange(v, alt);
                for (let by = ar.by0; by <= ar.by1; by++) for (let bx = ar.bx0; bx <= ar.bx1; bx++) {
                    const b = blocks.get(bk(alt, atz, bx, by));
                    if (!b || b.empty) continue;
                    blit(ctx, v, b.img, b.lngW, b.latN, ar.deg);
                    stats.standIn += b.n;
                }
            };
            if (absent) {
                for (const alt of [e - 2, e + 2, e - 1, e + 1]) drawAlt(alt);
                for (let alt = e - 3; stats.standIn === 0 && alt >= e - 12; alt--) drawAlt(alt);
            }
            let n = 0;
            const planned = new Set(plan.tiles.map((t) => t.join('/')));
            for (let by = r.by0; by <= r.by1; by++) for (let bx = r.bx0; bx <= r.bx1; bx++) {
                const k = bk(e, tz, bx, by);
                const b = blocks.get(k);
                if (!b || b.empty) continue;
                blocks.delete(k);
                blocks.set(k, b);
                blit(ctx, v, b.img, b.lngW, b.latN, r.deg);
                n += b.n;
                stats.blocksDrawn++;
                if (b.missing && b.missing.some((q) => planned.has(q))) stats.provisional++;
            }
            ctx.restore();
            const gesture = performance.now() - changedAt < 150;
            let budget = gesture ? 2 : 8;
            const cx = (r.bx0 + r.bx1) / 2, cy = (r.by0 + r.by1) / 2;
            need.sort((a, b) => ((a[0] - cx) ** 2 + (a[1] - cy) ** 2) - ((b[0] - cx) ** 2 + (b[1] - cy) ** 2));
            let left = 0;
            for (const [bx, by] of need) {
                const k = bk(e, tz, bx, by);
                const want = dirty.get(k) || 0;
                if (rasterWant.has(k) && rasterWant.get(k) >= want) continue;
                if (budget <= 0 || rasterWant.size >= 6) { left++; continue; }
                const spec = blockSpec(e, tz, bx, by);
                if (!spec.keys.length) { deleteBlock(k); blocks.set(k, Object.assign(EMPTY_BLOCK(ver), { lngW: spec.lngW, lngE: spec.lngE, latN: spec.latN, latS: spec.latS })); continue; }
                requestRaster(k, spec, theme);
                budget--;
            }
            if (left) { clearTimeout(idleTimer); idleTimer = setTimeout(() => host.requestDraw(), gesture ? 160 : 16); }
            stats.tilesDrawn = n;
            push(stats.blit, performance.now() - t0);
            setAttr(n + stats.standIn > 0);
            return n > 0;
        };

        const labelFont = (zv, water) => (water ? 'italic ' : '') + '500 ' + (zv >= 16 ? 12 : 11) + 'px system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
        const measure = (font, text) => {
            const k = font + '\u0000' + text;
            let w = textW.get(k);
            if (w === undefined) { w = host.measure(font, text); textW.set(k, w); if (textW.size > 4000) textW.clear(); }
            return w;
        };

        const placeNow = async () => {
            labelTimer = 0;
            if (!worker || destroyed || !enabled) return;
            const v0 = host.view();
            const p = X.planTiles(v0);
            if (!p.draw) { labels = []; return; }
            const bz = p.bucketZv;
            const keys = p.tiles.map((t) => t.join('/')).filter((k) => { const t = tiles.get(k); return t && !t.empty; });
            const seq = ++labelSeq;
            const id = nextId++;
            const items = keys.length ? await new Promise((res) => { pending.set(id, { labels: res }); worker.postMessage({ op: 'labels', id, keys }); }) : [];
            if (seq !== labelSeq || destroyed || !enabled) return;
            const v = host.view(), s = v.pxPerDeg, zl = X.zvOf(s);
            const fontPx = zl >= 16 ? 12 : 11, textH = fontPx + 3;
            const cands = [];
            for (const it of items) {
                if (!X.labelAllowed(it.cls, bz) || !X.roadDrawn(it.mz, bz)) continue;
                const water = it.rank >= 5;
                const tw = measure(labelFont(zl, water), it.name);
                const ox = v.width / 2 + (it.lngW - v.cx) * s, oy = v.height / 2 + (v.cy - it.latN) * s;
                if (it.kind === 'point') {
                    const x = ox + it.pts[0] * s, y = oy + it.pts[1] * s;
                    if (x - tw / 2 < 4 || x + tw / 2 > v.width - 4 || y - textH / 2 < 4 || y + textH / 2 > v.height - 4) continue;
                    cands.push({ name: it.name, rank: it.rank, water, len: 0, x, y, angle: 0, boxes: [{ x0: x - tw / 2, y0: y - textH / 2, x1: x + tw / 2, y1: y + textH / 2 }] });
                    continue;
                }
                const sp = new Array(it.pts.length);
                for (let i = 0; i < it.pts.length; i += 2) { sp[i] = ox + it.pts[i] * s; sp[i + 1] = oy + it.pts[i + 1] * s; }
                const ll = X.lineLabel(sp, tw, textH, { width: v.width, height: v.height });
                if (ll) cands.push({ name: it.name, rank: it.rank, water, len: ll.len, x: ll.x, y: ll.y, angle: ll.angle, boxes: ll.boxes });
            }
            cands.sort((a, b) => a.rank - b.rank || b.len - a.len);
            const acc = X.placeLineLabels(cands, host.blocked(), 2, X.maxStreetLabels(bz));
            labels = acc.map((i) => {
                const c = cands[i];
                return { name: c.name, water: c.water, angle: c.angle, lng: v.cx + (c.x - v.width / 2) / s, lat: v.cy - (c.y - v.height / 2) / s, x: c.x, y: c.y, boxes: c.boxes };
            });
            labelsAt = s;
            host.requestDraw();
        };
        const placeLabels = () => { clearTimeout(labelTimer); labelTimer = setTimeout(placeNow, 30); };

        const drawLabels = (ctx) => {
            shown = [];
            if (!enabled || !plan.draw || !labels.length || !stats.tilesDrawn) return;
            const v = host.view(), s = v.pxPerDeg;
            if (Math.abs(s - labelsAt) > 1e-9 * labelsAt) return;
            const st = host.labelStyle();
            const zl = X.zvOf(s);
            ctx.save();
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.lineJoin = 'round';
            ctx.lineWidth = 3;
            ctx.strokeStyle = st.stroke;
            for (const l of labels) {
                const x = v.width / 2 + (l.lng - v.cx) * s, y = v.height / 2 + (v.cy - l.lat) * s;
                const dx = x - l.x, dy = y - l.y;
                ctx.save();
                ctx.font = labelFont(zl, l.water);
                ctx.fillStyle = l.water ? st.water : st.fill;
                ctx.translate(x, y);
                ctx.rotate(l.angle);
                ctx.strokeText(l.name, 0, 0);
                ctx.fillText(l.name, 0, 0);
                ctx.restore();
                shown.push({ name: l.name, x, y, angle: l.angle, water: l.water, boxes: l.boxes.map((b) => ({ x0: b.x0 + dx, y0: b.y0 + dy, x1: b.x1 + dx, y1: b.y1 + dy })) });
            }
            ctx.restore();
        };

        const onVis = () => {
            if (typeof document === 'undefined' || !enabled) return;
            if (document.hidden) abortAll();
            else armSettle();
        };
        if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVis);
        const stopAll = () => { abortAll(); clearTimeout(settleTimer); clearTimeout(labelTimer); clearTimeout(idleTimer); };
        layers.add(stopAll);

        const setEnabled = (on) => {
            enabled = !!on;
            if (!enabled) {
                abortAll();
                clearTimeout(settleTimer);
                clearTimeout(labelTimer);
                clearBlocks();
                labels = [];
                shown = [];
                wanted = [];
                tiles.clear();
                memBytes = 0;
                stopWorker();
                setAttr(false);
            } else {
                viewKey = '';
            }
            host.requestDraw();
        };

        const destroy = () => {
            destroyed = true;
            layers.delete(stopAll);
            abortAll();
            clearTimeout(settleTimer);
            clearTimeout(labelTimer);
            clearTimeout(idleTimer);
            clearBlocks();
            stopWorker();
            tiles.clear();
            memBytes = 0;
            if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVis);
        };

        const debug = () => {
            const now = Date.now();
            return {
                enabled, zv: plan.zv, bucketZv: plan.bucketZv, tz: plan.tz, draw: plan.draw, fetch: plan.draw && !!session.build && !session.stopped && session.pausedUntil <= now,
                plan: plan.tiles.map((t) => t.join('/')), wanted: wanted.slice(), visible: plan.visible || 0, build: session.build,
                loaded: [...tiles.keys()], memBytes,
                inflight: [...inflight.keys()], queued: queue.slice(), requests: stats.requests.slice(), cancelled: stats.cancelled.slice(),
                sentLast10s: session.sent.filter((t) => now - t < S.windowMs).length,
                paused: session.pausedUntil > now, stopped: session.stopped,
                negative: [...session.neg.entries()].filter((x) => x[1] > now).map((x) => x[0]).sort(),
                blocks: blocks.size, blockBytes, blocksDrawn: stats.blocksDrawn, provisional: stats.provisional, tilesDrawn: stats.tilesDrawn, standIn: stats.standIn, attribution: attr,
                labels: shown.slice(), blit: stats.blit.slice(), raster: stats.raster.slice(), decode: stats.decode.slice(),
                worker: !!worker, workerRaster, cacheHits: stats.cacheHits, cache: storeMode,
            };
        };

        return {
            frame, drawLabels, setEnabled, destroy, debug,
            active: () => enabled && X.baseTileZoom(host.view().pxPerDeg) !== null,
            themeChanged: () => { clearBlocks(); host.requestDraw(); },
            get enabled() { return enabled; },
        };
    }

    G.NymGeoStreet = Object.freeze({
        config, session, nextTileFetches, cancelSet, statusAction, bodyKind, evictionList, otherBuild, expired,
        bucketExp, bucketScale, createLayer, halt, cacheList: () => store.list(), DB_NAME, META_PATH,
    });
})();
