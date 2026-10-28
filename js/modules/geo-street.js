(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const CELL_RE = /^[0-9b-hjkmnp-z]{5}$/;
    const DB_NAME = 'nym-map';
    const MINUTE = 60000;
    const EMPTY = Object.freeze({ empty: true, n: 0, bytes: 0 });
    const config = { cacheBytes: 50331648, memoryBytes: 16777216, blockBytes: 33554432, maxCells: 12, forceMainRaster: false };
    const session = { sent: [], pausedUntil: 0, stopped: false, neg: new Map() };

    function parseBundle(input, expect) {
        const b = input instanceof Uint8Array ? input : new Uint8Array(input);
        const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
        const ascii = (s, e) => String.fromCharCode.apply(null, Array.from(b.subarray(s, e)));
        if (b.length < 32 || ascii(0, 4) !== 'NMT1') throw new Error('bad-magic');
        if (b[4] !== 1) throw new Error('bad-version');
        const n = dv.getUint16(14, true), payload = dv.getUint32(20, true), base = 32 + 16 * n;
        if (n > 512) throw new Error('too-many-tiles');
        if (b.length < base) throw new Error('truncated-index');
        if (b.length !== base + payload) throw new Error('bad-length');
        const h = { version: b[4], level: b[5], zmin: b[6], zmax: b[7], cell: ascii(8, 13), flags: b[13], count: n, build: dv.getUint32(16, true), payload, layers: dv.getUint32(24, true) };
        if (!CELL_RE.test(h.cell)) throw new Error('bad-cell');
        const tiles = [];
        for (let i = 0; i < n; i++) {
            const o = 32 + i * 16;
            const t = { z: b[o], flags: b[o + 1], x: dv.getUint16(o + 2, true), y: dv.getUint16(o + 4, true), off: dv.getUint32(o + 8, true), len: dv.getUint32(o + 12, true) };
            if (t.z < h.zmin || t.z > h.zmax || t.x >= 2 ** t.z || t.y >= 2 ** t.z) throw new Error('bad-entry');
            if (t.off + t.len > payload) throw new Error('bad-range');
            tiles.push(t);
        }
        if (expect && h.cell !== expect) throw new Error('cell-mismatch');
        return { h, tiles, base };
    }

    const tileBytes = (u8, b, t) => u8.subarray(b.base + t.off, b.base + t.off + t.len);

    async function gunzip(u8) {
        const stream = new Blob([u8]).stream().pipeThrough(new DecompressionStream('gzip'));
        return new Uint8Array(await new Response(stream).arrayBuffer());
    }

    function availableZooms(b) {
        const set = new Set();
        for (const t of b.tiles) set.add(t.z);
        return [...set].sort((x, y) => x - y);
    }

    function nextFetches(o) {
        const S = G.NymGeoExplore.STREET;
        const recent = o.sent.filter((t) => o.now - t < MINUTE).sort((a, b) => a - b);
        const slots = Math.max(0, Math.min(S.concurrent - o.inflight, S.cellsPerMinute - recent.length));
        const order = o.missing.slice().sort();
        const start = order.slice(0, slots);
        const capped = order.length > start.length && recent.length >= S.cellsPerMinute;
        return { start, waitMs: capped ? recent[0] + MINUTE - o.now : 0 };
    }

    function statusAction(status) {
        const S = G.NymGeoExplore.STREET;
        if (status === 200) return { kind: 'ok' };
        if (status === 413) return { kind: 'negative', ms: S.tooLargeRetryMs };
        if (status === 0 || status === 429 || status >= 500) return { kind: 'pause', ms: S.unavailableRetryMs };
        return { kind: 'stop' };
    }

    const cellUrl = (cell) => (typeof cell === 'string' && CELL_RE.test(cell) ? '/api/map/v1/' + cell : null);

    function evictionList(meta, cap) {
        const live = meta.filter((m) => m && !m.status && typeof m.size === 'number').sort((a, b) => a.usedAt - b.usedAt);
        let total = live.reduce((a, m) => a + m.size, 0);
        const out = [];
        for (const m of live) {
            if (total <= cap) break;
            out.push(m.cell);
            total -= m.size;
        }
        return out;
    }

    const expired = (m, now) => now - m.savedAt > G.NymGeoExplore.STREET.cacheTtlMs;
    const bucketExp = (pxPerDeg) => Math.round(2 * Math.log2(pxPerDeg));
    const bucketScale = (e) => 2 ** (e / 2);
    const tileLat = (y, z) => (2 * Math.atan(Math.exp(Math.PI * (1 - 2 * y / 2 ** z))) - Math.PI / 2) * 180 / Math.PI;
    const isQuota = (e) => !!e && (e.name === 'QuotaExceededError' || e.code === 22);

    const rq = (r) => new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
    const txDone = (tx) => new Promise((res, rej) => { tx.oncomplete = () => res(); tx.onerror = () => rej(tx.error); tx.onabort = () => rej(tx.error); });

    let dbPromise = null;
    function openDb() {
        if (dbPromise) return dbPromise;
        dbPromise = new Promise((resolve) => {
            let req;
            try { req = indexedDB.open(DB_NAME, 1); } catch (_) { resolve(null); return; }
            req.onupgradeneeded = () => {
                const db = req.result;
                if (!db.objectStoreNames.contains('cells')) db.createObjectStore('cells', { keyPath: 'cell' });
                if (!db.objectStoreNames.contains('meta')) db.createObjectStore('meta', { keyPath: 'cell' });
            };
            req.onsuccess = () => {
                const db = req.result;
                db.onversionchange = () => { try { db.close(); } catch (_) { } dbPromise = null; };
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
        for (const c of evictionList([...mem.values()].map((v) => v.meta), config.memoryBytes)) mem.delete(c);
    };
    const memPut = (cell, meta, bytes) => { storeMode = 'memory'; mem.set(cell, { meta, bytes }); memEvict(); };

    const store = {
        async get(cell, now) {
            const m = mem.get(cell);
            if (m) {
                if (m.meta.status) return m.meta.until > now ? { neg: m.meta } : null;
                if (expired(m.meta, now)) { mem.delete(cell); return null; }
                m.meta.usedAt = now;
                return { bytes: m.bytes, meta: m.meta };
            }
            const db = await openDb();
            if (!db) return null;
            try {
                const tx = db.transaction(['meta', 'cells'], 'readonly');
                const meta = await rq(tx.objectStore('meta').get(cell));
                if (!meta) return null;
                if (meta.status) return meta.until > now ? { neg: meta } : null;
                if (expired(meta, now)) { store.del(cell); return null; }
                const ent = await rq(tx.objectStore('cells').get(cell));
                if (!ent || !ent.bytes) return null;
                store.touch(cell, now);
                return { bytes: new Uint8Array(ent.bytes), meta };
            } catch (_) { return null; }
        },
        async put(cell, bytes, h, now) {
            const meta = { cell, build: h.build, level: h.level, size: bytes.byteLength, savedAt: now, usedAt: now };
            const db = await openDb();
            if (!db) { memPut(cell, meta, bytes); return; }
            const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            const write = async () => {
                const tx = db.transaction(['meta', 'cells'], 'readwrite');
                tx.objectStore('cells').put(Object.assign({ bytes: ab }, meta));
                tx.objectStore('meta').put(meta);
                await txDone(tx);
            };
            try { await write(); }
            catch (e) {
                if (!isQuota(e)) { memPut(cell, meta, bytes); return; }
                await store.evict(Math.floor(config.cacheBytes / 2));
                try { await write(); } catch (_) { memPut(cell, meta, bytes); return; }
            }
            await store.evict(config.cacheBytes);
        },
        async putNeg(cell, status, until) {
            const meta = { cell, status, until };
            const db = await openDb();
            if (!db) { mem.set(cell, { meta, bytes: null }); return; }
            try {
                const tx = db.transaction(['meta', 'cells'], 'readwrite');
                tx.objectStore('meta').put(meta);
                tx.objectStore('cells').delete(cell);
                await txDone(tx);
            } catch (_) { mem.set(cell, { meta, bytes: null }); }
        },
        async touch(cell, now) {
            const db = await openDb();
            if (!db) return;
            try {
                const tx = db.transaction(['meta'], 'readwrite');
                const os = tx.objectStore('meta');
                const m = await rq(os.get(cell));
                if (m && !m.status) { m.usedAt = now; os.put(m); }
                await txDone(tx);
            } catch (_) { }
        },
        async del(cell) {
            mem.delete(cell);
            const db = await openDb();
            if (!db) return;
            try {
                const tx = db.transaction(['meta', 'cells'], 'readwrite');
                tx.objectStore('meta').delete(cell);
                tx.objectStore('cells').delete(cell);
                await txDone(tx);
            } catch (_) { }
        },
        async evict(cap) {
            const db = await openDb();
            if (!db) return;
            try {
                const tx = db.transaction(['meta', 'cells'], 'readwrite');
                const metas = await rq(tx.objectStore('meta').getAll());
                const now = Date.now();
                const old = metas.filter((m) => m && !m.status && expired(m, now));
                const drop = evictionList(metas.filter((m) => !old.includes(m)), cap).concat(old.map((m) => m.cell));
                for (const m of metas) if (m.status && m.until <= now) drop.push(m.cell);
                for (const c of drop) { tx.objectStore('meta').delete(c); tx.objectStore('cells').delete(c); }
                await txDone(tx);
            } catch (_) { }
        },
        async list() {
            const db = await openDb();
            if (!db) return [...mem.values()].map((v) => v.meta);
            try { return await rq(db.transaction(['meta'], 'readonly').objectStore('meta').getAll()); } catch (_) { return []; }
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

    function createLayer(host) {
        const X = G.NymGeoExplore;
        const S = X.STREET;
        let enabled = !!host.enabled;
        let destroyed = false;
        const cells = new Map();
        const owner = new Map();
        const inflight = new Map();
        let queue = [];
        let pumpTimer = 0, settleTimer = 0, labelTimer = 0, idleTimer = 0;
        let plan = { zv: 0, draw: false, fetch: false, cells: [] };
        let viewKey = '', changedAt = 0;
        let worker = null, workerRaster = null, nextId = 1, gen = 0;
        const pending = new Map();
        const blocks = new Map();
        let blockBytes = 0;
        const rasterWant = new Set();
        let labels = [], labelsAt = 0, labelSeq = 0, shown = [];
        let attr = false;
        const textW = new Map();
        const stats = { blit: [], raster: [], decode: [], tilesDrawn: 0, blocksDrawn: 0, requests: [], cacheHits: 0 };
        const push = (arr, v) => { arr.push(v); if (arr.length > 600) arr.shift(); };
        store.evict(config.cacheBytes);

        const setAttr = (on) => { if (on !== attr) { attr = on; host.setAttribution(on); } };

        const tileInfo = (t) => {
            const N = 2 ** t.z;
            return Object.assign({}, t, { key: t.z + '/' + t.x + '/' + t.y, lngW: t.x / N * 360 - 180, lngE: (t.x + 1) / N * 360 - 180, latN: tileLat(t.y, t.z), latS: tileLat(t.y + 1, t.z) });
        };
        const overlaps = (a, lngW, lngE, latS, latN) => !(a.lngE <= lngW || a.lngW >= lngE || a.latS >= latN || a.latN <= latS);

        const postCell = (c) => {
            if (!worker) return;
            const tiles = [], transfer = [];
            for (const t of c.tiles) {
                if (!t.len || owner.get(t.key) !== c.cell) continue;
                const gz = c.bytes.slice(c.base + t.off, c.base + t.off + t.len).buffer;
                tiles.push({ key: t.key, z: t.z, x: t.x, y: t.y, level: c.level, gz });
                transfer.push(gz);
            }
            if (tiles.length) worker.postMessage({ op: 'add', tiles }, transfer);
        };

        const closeBlock = (b) => { if (b && b.img && typeof b.img.close === 'function') { try { b.img.close(); } catch (_) { } } };
        const deleteBlock = (k) => { const b = blocks.get(k); if (!b) return; blockBytes -= b.bytes; closeBlock(b); blocks.delete(k); };
        const clearBlocks = () => { for (const k of [...blocks.keys()]) deleteBlock(k); gen++; rasterWant.clear(); };
        const invalidateArea = (lngW, lngE, latS, latN) => {
            for (const [k, b] of [...blocks.entries()]) if (overlaps(b, lngW, lngE, latS, latN)) deleteBlock(k);
            gen++;
            rasterWant.clear();
        };
        const storeBlock = (k, img, bytes, n, spec) => {
            deleteBlock(k);
            blocks.set(k, { img, bytes, n, lngW: spec.lngW, lngE: spec.lngW + spec.deg, latN: spec.latN, latS: spec.latN - spec.deg });
            blockBytes += bytes;
            for (const key of blocks.keys()) {
                if (blockBytes <= config.blockBytes) break;
                if (key !== k) deleteBlock(key);
            }
        };

        const paintMain = async (w, tiles) => {
            const D = await loadDecodeLib();
            if (!D || destroyed || w.gen !== gen) return;
            try {
                const canvas = document.createElement('canvas');
                canvas.width = canvas.height = w.size;
                const c2 = canvas.getContext('2d');
                const n = D.paintBlock(c2, tiles, w.req);
                storeBlock(w.key, canvas, w.size * w.size * 4, n, w.spec);
            } catch (_) { deleteBlock(w.key); blocks.set(w.key, EMPTY); }
            host.requestDraw();
        };

        const onWorker = (e) => {
            const d = e.data || {};
            if (d.op === 'ready') { workerRaster = !!d.raster; return; }
            const w = pending.get(d.id);
            pending.delete(d.id);
            if (d.op === 'labels') { if (w && w.labels) w.labels(d.items || []); return; }
            if (!w) { if (d.bitmap) d.bitmap.close(); return; }
            rasterWant.delete(w.key);
            if (typeof d.decodeMs === 'number') push(stats.decode, d.decodeMs);
            if (destroyed || w.gen !== gen) { if (d.bitmap) d.bitmap.close(); if (!destroyed) host.requestDraw(); return; }
            if (d.op === 'block' && !d.bitmap) { deleteBlock(w.key); blocks.set(w.key, EMPTY); }
            else if (d.op === 'block') {
                push(stats.raster, d.ms);
                storeBlock(w.key, d.bitmap, w.size * w.size * 4, d.n, w.spec);
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
            for (const c of cells.values()) postCell(c);
        };
        const stopWorker = () => {
            if (worker) { try { worker.terminate(); } catch (_) { } }
            worker = null;
            workerRaster = null;
            pending.clear();
            rasterWant.clear();
        };

        const dropCell = (c) => {
            const e = cells.get(c);
            if (!e) return;
            cells.delete(c);
            const drop = [];
            for (const t of e.tiles) {
                if (owner.get(t.key) !== c) continue;
                owner.delete(t.key);
                let alt = null;
                for (const o of cells.values()) if (o.tiles.some((x) => x.key === t.key && x.len) && (!alt || o.level < alt.level)) alt = o;
                if (alt) owner.set(t.key, alt.cell);
                else drop.push(t.key);
            }
            if (worker && drop.length) worker.postMessage({ op: 'drop', keys: drop });
            invalidateArea(e.lngW, e.lngE, e.latS, e.latN);
        };

        const trimCells = (keep) => {
            const k = new Set(keep || []);
            while (cells.size > config.maxCells) {
                let old = null;
                for (const c of cells.values()) if (!k.has(c.cell) && (!old || c.usedAt < old.usedAt)) old = c;
                if (!old) break;
                dropCell(old.cell);
            }
        };

        const addCell = (cell, bytes, b) => {
            if (destroyed || !enabled) return;
            if (cells.has(cell)) dropCell(cell);
            const tiles = b.tiles.map(tileInfo);
            const e = { cell, level: b.h.level, build: b.h.build, zooms: availableZooms(b), tiles, bytes, base: b.base, usedAt: Date.now(),
                lngW: Infinity, lngE: -Infinity, latS: Infinity, latN: -Infinity };
            for (const t of tiles) { e.lngW = Math.min(e.lngW, t.lngW); e.lngE = Math.max(e.lngE, t.lngE); e.latS = Math.min(e.latS, t.latS); e.latN = Math.max(e.latN, t.latN); }
            cells.set(cell, e);
            for (const t of tiles) {
                if (!t.len) continue;
                const o = owner.get(t.key);
                if (!o || !cells.has(o) || cells.get(o).level > e.level) owner.set(t.key, cell);
            }
            postCell(e);
            if (tiles.length) invalidateArea(e.lngW, e.lngE, e.latS, e.latN);
            trimCells(plan.cells);
            host.requestDraw();
            placeLabels();
        };

        const negative = (cell, ms, status) => {
            const until = Date.now() + ms;
            session.neg.set(cell, until);
            store.putNeg(cell, status, until);
        };
        const negActive = (cell, now) => (session.neg.get(cell) || 0) > now;

        const abortAll = () => {
            for (const ac of inflight.values()) { try { ac.abort(); } catch (_) { } }
            inflight.clear();
            queue = [];
            clearTimeout(pumpTimer);
        };

        const settledLongEnough = () => performance.now() - changedAt >= S.settleMs - 5;

        const pump = () => {
            clearTimeout(pumpTimer);
            if (destroyed || !enabled || session.stopped || Date.now() < session.pausedUntil || (typeof document !== 'undefined' && document.hidden)) { queue = []; return; }
            if (!plan.fetch) { queue = []; return; }
            if (!settledLongEnough()) return;
            const want = new Set(plan.cells);
            queue = queue.filter((c) => want.has(c) && !cells.has(c) && !inflight.has(c));
            const now = Date.now();
            session.sent = session.sent.filter((t) => now - t < MINUTE);
            const r = nextFetches({ missing: queue, inflight: inflight.size, sent: session.sent, now });
            for (const c of r.start) { queue = queue.filter((x) => x !== c); fetchCell(c); }
            if (r.waitMs && queue.length) pumpTimer = setTimeout(pump, r.waitMs);
        };

        const fetchCell = async (cell) => {
            const url = cellUrl(cell);
            if (!url) return;
            session.sent.push(Date.now());
            const ac = new AbortController();
            inflight.set(cell, ac);
            push(stats.requests, url);
            let status = 0, bytes = null;
            try {
                const resp = await fetch(url, { credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer', signal: ac.signal });
                status = resp.status;
                if (status === 200) bytes = new Uint8Array(await resp.arrayBuffer());
            } catch (_) {
                if (ac.signal.aborted) { if (inflight.get(cell) === ac) inflight.delete(cell); return; }
                status = 0;
            }
            if (inflight.get(cell) === ac) inflight.delete(cell);
            if (destroyed || ac.signal.aborted) return;
            const act = statusAction(status);
            if (act.kind === 'ok') {
                let b = null;
                try { b = parseBundle(bytes, cell); } catch (_) { b = null; }
                if (!b) negative(cell, S.tooLargeRetryMs, 422);
                else { addCell(cell, bytes, b); store.put(cell, bytes, b.h, Date.now()); }
            } else if (act.kind === 'negative') negative(cell, act.ms, status);
            else if (act.kind === 'pause') { session.pausedUntil = Date.now() + act.ms; queue = []; }
            else if (act.kind === 'stop') { session.stopped = true; queue = []; }
            pump();
        };

        const fromDevice = async (cell, now) => {
            const r = await store.get(cell, now);
            if (!r || destroyed) return;
            if (r.neg) { session.neg.set(cell, r.neg.until); return; }
            let b = null;
            try { b = parseBundle(r.bytes, cell); } catch (_) { store.del(cell); return; }
            stats.cacheHits++;
            addCell(cell, r.bytes, b);
        };

        const settle = async () => {
            settleTimer = 0;
            if (destroyed || !enabled) return;
            const p = X.planCells(host.view());
            if (!p.draw) return;
            const now = Date.now();
            for (const c of p.cells) { const e = cells.get(c); if (e) e.usedAt = now; }
            await Promise.all(p.cells.filter((c) => !cells.has(c) && !negActive(c, now)).map((c) => fromDevice(c, now)));
            if (destroyed || !enabled) return;
            if (p.fetch) {
                const t = Date.now();
                queue = p.cells.filter((c) => !cells.has(c) && !inflight.has(c) && !negActive(c, t));
                pump();
            }
            placeLabels();
        };
        const armSettle = () => { clearTimeout(settleTimer); settleTimer = setTimeout(settle, S.settleMs); };

        const blockSpec = (e, bx, by) => {
            const bs = bucketScale(e), deg = 256 / bs, lngW = -180 + bx * deg, latN = 90 - by * deg, lngE = lngW + deg, latS = latN - deg;
            const zv = X.zvOf(bs), keys = [], seen = new Set();
            for (const c of cells.values()) {
                if (!overlaps(c, lngW, lngE, latS, latN)) continue;
                const tz = X.tileZoomFor(zv, c.zooms);
                for (const t of c.tiles) {
                    if (t.z !== tz || !t.len || owner.get(t.key) !== c.cell || seen.has(t.key)) continue;
                    if (!overlaps(t, lngW, lngE, latS, latN)) continue;
                    seen.add(t.key);
                    keys.push(t.key);
                }
            }
            return { keys, lngW, latN, deg, zv };
        };

        const requestRaster = (k, spec, theme) => {
            const dprC = host.dpr();
            const size = Math.max(1, Math.round(256 * dprC));
            const id = nextId++;
            const req = { op: 'raster', id, keys: spec.keys, lngW: spec.lngW, latN: spec.latN, size, k: size / spec.deg, dpr: size / 256, zv: spec.zv, theme, edge: spec.zv >= 16.5, noRaster: !!config.forceMainRaster };
            pending.set(id, { key: k, size, gen, spec, req });
            rasterWant.add(k);
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
            plan = enabled ? X.planCells(v) : { zv: X.zvOf(v.pxPerDeg), draw: false, fetch: false, cells: [] };
            track(v);
            stats.tilesDrawn = 0;
            stats.blocksDrawn = 0;
            stats.standIn = 0;
            if (!plan.draw) { setAttr(false); return false; }
            startWorker();
            if (!cells.size || !worker) { setAttr(false); return false; }
            const e = bucketExp(v.pxPerDeg), theme = host.light() ? 'light' : 'dark';
            const r = blockRange(v, e);
            const missing = [];
            ctx.save();
            ctx.imageSmoothingEnabled = true;
            for (let by = r.by0; by <= r.by1; by++) for (let bx = r.bx0; bx <= r.bx1; bx++) if (!blocks.has(theme + '|' + e + '|' + bx + '|' + by)) missing.push([bx, by]);
            if (missing.length) {
                for (const alt of [e - 2, e + 2, e - 1, e + 1]) {
                    const ar = blockRange(v, alt);
                    for (let by = ar.by0; by <= ar.by1; by++) for (let bx = ar.bx0; bx <= ar.bx1; bx++) {
                        const b = blocks.get(theme + '|' + alt + '|' + bx + '|' + by);
                        if (!b || b.empty) continue;
                        blit(ctx, v, b.img, b.lngW, b.latN, ar.deg);
                        stats.standIn += b.n;
                    }
                }
            }
            let tiles = 0;
            for (let by = r.by0; by <= r.by1; by++) for (let bx = r.bx0; bx <= r.bx1; bx++) {
                const k = theme + '|' + e + '|' + bx + '|' + by;
                const b = blocks.get(k);
                if (!b || b.empty) continue;
                blocks.delete(k);
                blocks.set(k, b);
                blit(ctx, v, b.img, b.lngW, b.latN, r.deg);
                tiles += b.n;
                stats.blocksDrawn++;
            }
            ctx.restore();
            const gesture = performance.now() - changedAt < 150;
            let budget = gesture ? 2 : 8;
            const cx = (r.bx0 + r.bx1) / 2, cy = (r.by0 + r.by1) / 2;
            missing.sort((a, b) => ((a[0] - cx) ** 2 + (a[1] - cy) ** 2) - ((b[0] - cx) ** 2 + (b[1] - cy) ** 2));
            let left = 0;
            for (const [bx, by] of missing) {
                const k = theme + '|' + e + '|' + bx + '|' + by;
                if (rasterWant.has(k)) continue;
                if (budget <= 0 || rasterWant.size >= 6) { left++; continue; }
                const spec = blockSpec(e, bx, by);
                if (!spec.keys.length) { blocks.set(k, EMPTY); continue; }
                requestRaster(k, spec, theme);
                budget--;
            }
            if (left && gesture) { clearTimeout(idleTimer); idleTimer = setTimeout(() => host.requestDraw(), 160); }
            stats.tilesDrawn = tiles;
            push(stats.blit, performance.now() - t0);
            setAttr(tiles + stats.standIn > 0);
            return tiles > 0;
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
            const p = X.planCells(v0);
            if (!p.draw) { labels = []; return; }
            const zv = X.zvOf(v0.pxPerDeg), s0 = v0.pxPerDeg;
            const lngLo = v0.cx - v0.width / 2 / s0, lngHi = v0.cx + v0.width / 2 / s0, latLo = v0.cy - v0.height / 2 / s0, latHi = v0.cy + v0.height / 2 / s0;
            const keys = [], seen = new Set();
            for (const c of cells.values()) {
                if (!overlaps(c, lngLo, lngHi, latLo, latHi)) continue;
                const tz = X.tileZoomFor(zv, c.zooms);
                for (const t of c.tiles) if (t.z === tz && t.len && owner.get(t.key) === c.cell && !seen.has(t.key) && overlaps(t, lngLo, lngHi, latLo, latHi)) { seen.add(t.key); keys.push(t.key); }
            }
            const seq = ++labelSeq;
            const id = nextId++;
            const items = keys.length ? await new Promise((res) => { pending.set(id, { labels: res }); worker.postMessage({ op: 'labels', id, keys }); }) : [];
            if (seq !== labelSeq || destroyed || !enabled) return;
            const v = host.view(), s = v.pxPerDeg, zl = X.zvOf(s);
            const fontPx = zl >= 16 ? 12 : 11, textH = fontPx + 3;
            const cands = [];
            for (const it of items) {
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
            const acc = X.placeLineLabels(cands, host.blocked(), 2);
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

        const onVis = () => { if (typeof document !== 'undefined' && !document.hidden && enabled) armSettle(); };
        if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVis);

        const setEnabled = (on) => {
            enabled = !!on;
            if (!enabled) {
                abortAll();
                clearTimeout(settleTimer);
                clearTimeout(labelTimer);
                clearBlocks();
                labels = [];
                shown = [];
                for (const c of [...cells.keys()]) cells.delete(c);
                owner.clear();
                stopWorker();
                setAttr(false);
            } else {
                viewKey = '';
            }
            host.requestDraw();
        };

        const destroy = () => {
            destroyed = true;
            abortAll();
            clearTimeout(settleTimer);
            clearTimeout(labelTimer);
            clearTimeout(idleTimer);
            clearBlocks();
            stopWorker();
            cells.clear();
            owner.clear();
            if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVis);
        };

        const debug = () => {
            const now = Date.now();
            return {
                enabled, zv: plan.zv, draw: plan.draw, fetch: plan.fetch, plan: plan.cells.slice(), visible: plan.visible || 0,
                loaded: [...cells.keys()].sort(), levels: [...cells.values()].map((c) => [c.cell, c.level]),
                inflight: [...inflight.keys()], queued: queue.slice(), requests: stats.requests.slice(),
                sentLastMinute: session.sent.filter((t) => now - t < MINUTE).length,
                paused: session.pausedUntil > now, stopped: session.stopped,
                negative: [...session.neg.entries()].filter((x) => x[1] > now).map((x) => x[0]).sort(),
                blocks: blocks.size, blockBytes, blocksDrawn: stats.blocksDrawn, tilesDrawn: stats.tilesDrawn, standIn: stats.standIn || 0, attribution: attr,
                labels: shown.slice(), blit: stats.blit.slice(), raster: stats.raster.slice(), decode: stats.decode.slice(),
                worker: !!worker, workerRaster, cacheHits: stats.cacheHits, cache: storeMode,
            };
        };

        return {
            frame, drawLabels, setEnabled, destroy, debug,
            active: () => enabled && X.zvOf(host.view().pxPerDeg) >= S.drawZv,
            themeChanged: () => { clearBlocks(); host.requestDraw(); },
            get enabled() { return enabled; },
        };
    }

    G.NymGeoStreet = Object.freeze({
        config, parseBundle, tileBytes, gunzip, availableZooms, nextFetches, statusAction, cellUrl, evictionList, expired,
        bucketExp, bucketScale, createLayer, cacheList: () => store.list(), DB_NAME,
    });
})();
