(function () {
    const G = self;
    const td = new TextDecoder();
    const GREEN = new Set(['park', 'forest', 'wood', 'grass', 'garden', 'cemetery', 'golf_course', 'nature_reserve', 'playground', 'pitch', 'recreation_ground', 'village_green', 'meadow', 'scrub', 'allotments']);
    const ROAD_CLASS = { highway: 'hw', major_road: 'major', path: 'path', rail: 'rail' };
    const LABEL_RANK = { hw: 0, major: 1, minor: 2, service: 3, path: 4, river: 5, stream: 5 };
    const DECODED_MAX = 96;
    const WIDTH_ZV = [6, 8, 10, 12, 14, 16, 18];
    const WIDTHS = {
        hw: [0.6, 0.9, 1.2, 1.6, 2, 5, 10], major: [0.4, 0.5, 0.7, 1.1, 1.6, 4, 8], minor: [0.3, 0.3, 0.4, 0.5, 0.8, 2.6, 5], service: [0.3, 0.3, 0.3, 0.4, 0.5, 1.4, 3],
        path: [0.3, 0.3, 0.3, 0.4, 0.5, 1, 1.5], rail: [0.4, 0.5, 0.6, 0.7, 0.8, 1.2, 1.5], river: [0.5, 0.6, 0.8, 0.9, 1, 2.5, 4], stream: [0.3, 0.3, 0.4, 0.4, 0.5, 1, 1.5],
    };
    const LABEL_FROM = { hw: 7.99, major: 11.49, minor: 14.49, service: 14.49, path: 14.49, river: 9.99, stream: 12.99, wlabel: 5.99 };
    const LOW_LIGHT = { hw: '#e8c58a', major: '#f0d9a8' };
    const LOW_FILL_BELOW = 12.99;
    const TILE_BIAS = 0.5;
    const PALETTE = {
        light: {
            land: '#eef2f4', water: '#d6e8f1', river: 'rgba(90,150,190,0.7)', green: '#dcebd9', landuse: '#e8ecef',
            bld: '#dfe4e9', bldEdge: '#cfd6dd', casing: '#c3cdd6', hw: '#f2dcae', major: '#fbf3dd', minor: '#ffffff',
            service: '#fafbfc', path: '#b9c4cd', rail: '#a6b1bb',
        },
        dark: {
            land: '#1c2a39', water: '#0a131e', river: 'rgba(70,120,160,0.55)', green: '#1d3a33', landuse: '#223244',
            bld: '#26374a', bldEdge: '#2e4258', casing: '#16222f', hw: '#55708c', major: '#3e5873', minor: '#2f4458',
            service: '#2a3c50', path: '#2a3c50', rail: '#4a5b6d',
        },
    };
    const FILL_ORDER = ['path', 'rail', 'service', 'minor', 'major', 'hw'];
    const CASED = ['minor', 'major', 'hw'];

    function rv(b, p) { let v = 0, m = 1, x; do { x = b[p.i++]; v += (x & 0x7f) * m; m *= 128; } while (x & 0x80); return v; }
    function len(b, p) { const n = rv(b, p); if (p.i + n > b.length) throw new Error('truncated'); return n; }
    function skip(b, p, wt) {
        if (wt === 0) rv(b, p);
        else if (wt === 1) p.i += 8;
        else if (wt === 2) { const n = len(b, p); p.i += n; }
        else if (wt === 5) p.i += 4;
        else throw new Error('wt' + wt);
    }
    function packed(b, p) { const n = len(b, p), end = p.i + n, out = []; while (p.i < end) out.push(rv(b, p)); return out; }
    function value(b, s, e) {
        const p = { i: s };
        let v = null;
        while (p.i < e) {
            const k = rv(b, p), f = k >> 3, wt = k & 7;
            if (f === 1) { const n = len(b, p); v = td.decode(b.subarray(p.i, p.i + n)); p.i += n; }
            else if (f === 2) { v = new DataView(b.buffer, b.byteOffset + p.i, 4).getFloat32(0, true); p.i += 4; }
            else if (f === 3) { v = new DataView(b.buffer, b.byteOffset + p.i, 8).getFloat64(0, true); p.i += 8; }
            else if (f === 4) {
                let q = 0n, sh = 0n, x;
                do { x = b[p.i++]; q |= BigInt(x & 0x7f) << sh; sh += 7n; } while (x & 0x80);
                v = Number(BigInt.asIntN(64, q));
            }
            else if (f === 5) v = rv(b, p);
            else if (f === 6) { const z = rv(b, p); v = (z % 2) ? -(z + 1) / 2 : z / 2; }
            else if (f === 7) v = rv(b, p) !== 0;
            else skip(b, p, wt);
        }
        return v;
    }

    function rings(cmds) {
        const parts = [];
        let cur = null, x = 0, y = 0, i = 0;
        while (i < cmds.length) {
            const c = cmds[i++], id = c & 7, n = c >> 3;
            if (id === 7) { cur = null; continue; }
            if (i + 2 * n > cmds.length) break;
            for (let k = 0; k < n; k++) {
                const dx = cmds[i++], dy = cmds[i++];
                x += (dx >>> 1) ^ -(dx & 1);
                y += (dy >>> 1) ^ -(dy & 1);
                if (id === 1 || !cur) { cur = []; parts.push(cur); }
                cur.push(x, y);
            }
        }
        return parts;
    }

    function ringArea(r) {
        let a = 0;
        const n = r.length / 2;
        for (let i = 0; i < n; i++) {
            const j = (i + 1) % n;
            a += r[2 * i] * r[2 * j + 1] - r[2 * j] * r[2 * i + 1];
        }
        return a / 2;
    }

    function polygons(parts) {
        const polys = [];
        for (const r of parts) {
            const a = ringArea(r);
            if (a === 0 || r.length < 6) continue;
            if (a > 0 || !polys.length) polys.push([r]);
            else polys[polys.length - 1].push(r);
        }
        return polys;
    }

    const pairs = (r) => { const out = []; for (let i = 0; i < r.length; i += 2) out.push([r[i], r[i + 1]]); return out; };

    function decodeGeometry(type, cmds) {
        const parts = rings(cmds);
        if (type === 1) { const out = []; for (const p of parts) for (const q of pairs(p)) out.push(q); return out; }
        if (type === 2) return parts.filter((p) => p.length >= 4).map(pairs);
        return polygons(parts).map((poly) => poly.map(pairs));
    }

    function decodeTile(b, opts) {
        const withGeometry = !opts || opts.geometry !== false;
        const p = { i: 0 }, layers = [];
        while (p.i < b.length) {
            const k = rv(b, p);
            if ((k >> 3) !== 3 || (k & 7) !== 2) { skip(b, p, k & 7); continue; }
            const n = len(b, p), end = p.i + n;
            const L = { name: '', version: 1, extent: 4096, keys: [], values: [], features: [] };
            while (p.i < end) {
                const t = rv(b, p), f = t >> 3, wt = t & 7;
                if (f === 1) { const m = len(b, p); L.name = td.decode(b.subarray(p.i, p.i + m)); p.i += m; }
                else if (f === 2) {
                    const m = len(b, p), fe = p.i + m, F = { id: null, type: 0, tags: [], cmds: [] };
                    while (p.i < fe) {
                        const q = rv(b, p), ff = q >> 3;
                        if (ff === 1) F.id = rv(b, p);
                        else if (ff === 2) F.tags = packed(b, p);
                        else if (ff === 3) F.type = rv(b, p);
                        else if (ff === 4) F.cmds = packed(b, p);
                        else skip(b, p, q & 7);
                    }
                    L.features.push(F);
                }
                else if (f === 3) { const m = len(b, p); L.keys.push(td.decode(b.subarray(p.i, p.i + m))); p.i += m; }
                else if (f === 4) { const m = len(b, p); L.values.push(value(b, p.i, p.i + m)); p.i += m; }
                else if (f === 5) L.extent = rv(b, p);
                else if (f === 15) L.version = rv(b, p);
                else skip(b, p, wt);
            }
            L.features = L.features.map((F) => {
                const props = {};
                for (let j = 0; j + 1 < F.tags.length; j += 2) props[L.keys[F.tags[j]]] = L.values[F.tags[j + 1]];
                const out = { id: F.id, type: F.type, props };
                if (withGeometry) out.geometry = decodeGeometry(F.type, F.cmds);
                else out.cmds = F.cmds;
                return out;
            });
            delete L.keys;
            delete L.values;
            layers.push(L);
        }
        return layers;
    }

    function tileLat(y, z) { return (2 * Math.atan(Math.exp(Math.PI * (1 - 2 * y / 2 ** z))) - Math.PI / 2) * 180 / Math.PI; }

    function reproject(z, x, y, px, py, ext) {
        const N = 2 ** z, lng = (x + px / ext) / N * 360 - 180, lat = tileLat(y + py / ext, z);
        const latN = tileLat(y, z), latS = tileLat(y + 1, z);
        return { lng, lat, u: px / ext, w: (latN - lat) / (latN - latS) };
    }

    function tileLocal(z, y, px, py, ext) {
        return [(px / ext) * 360 / 2 ** z, tileLat(y, z) - tileLat(y + py / ext, z)];
    }

    function classify(layer, props, type) {
        const p = props || {};
        if (layer === 'earth') return type === 3 ? 'land' : null;
        if (layer === 'water') {
            if (type === 3) return 'water';
            if (type === 2) return p.kind === 'river' || p.kind === 'canal' ? 'river' : 'stream';
            if (type === 1) return p.name ? 'wlabel' : null;
            return null;
        }
        if (layer === 'landuse') return type === 3 ? (GREEN.has(p.kind) ? 'green' : 'landuse') : null;
        if (layer === 'buildings') return type === 3 ? 'bld' : null;
        if (layer === 'roads') {
            if (type !== 2) return null;
            if (p.kind === 'minor_road') return p.kind_detail === 'service' ? 'service' : 'minor';
            return ROAD_CLASS[p.kind] || null;
        }
        return null;
    }

    const roadDrawn = (mz, bz) => !(typeof mz === 'number' && mz > bz - TILE_BIAS);
    const labelAllowed = (cls, bz) => LABEL_FROM[cls] !== undefined && bz >= LABEL_FROM[cls];
    function labelText(cls, p) {
        if (cls === 'hw' || cls === 'major') return p.name || p.ref || null;
        if (cls === 'rail' || cls === 'land' || cls === 'water' || cls === 'green' || cls === 'landuse' || cls === 'bld') return null;
        return p.name || null;
    }

    function tileStats(raw, bz) {
        const classes = {}, labelCandidates = {};
        for (const L of decodeTile(raw, { geometry: false })) {
            for (const F of L.features) {
                const cls = classify(L.name, F.props, F.type);
                if (!cls) continue;
                if (L.name === 'roads' && !roadDrawn(F.props.min_zoom, bz)) continue;
                classes[cls] = (classes[cls] || 0) + 1;
                if (labelText(cls, F.props) && labelAllowed(cls, bz)) labelCandidates[cls] = (labelCandidates[cls] || 0) + 1;
            }
        }
        return { classes, labelCandidates };
    }

    function buildTile(raw, z, x, y) {
        const N = 2 ** z, w = 360 / N, latN = tileLat(y, z), h = latN - tileLat(y + 1, z);
        const groups = new Map(), labels = [];
        const yCache = new Map();
        let lastExt = -1;
        const Y = (py, ext) => {
            if (ext !== lastExt) { yCache.clear(); lastExt = ext; }
            let v = yCache.get(py);
            if (v === undefined) { v = latN - tileLat(y + py / ext, z); yCache.set(py, v); }
            return v;
        };
        const groupFor = (cls, st, mz, poly) => {
            const key = cls + '|' + st + '|' + mz;
            let g = groups.get(key);
            if (!g) { g = { cls, st, mz, poly, pts: [], parts: [] }; groups.set(key, g); }
            return g;
        };
        const toLocal = (r, ext) => {
            const out = new Float32Array(r.length), sx = w / ext;
            for (let i = 0; i < r.length; i += 2) { out[i] = r[i] * sx; out[i + 1] = Y(r[i + 1], ext); }
            return out;
        };
        for (const L of decodeTile(raw, { geometry: false })) {
            const ext = L.extent || 4096;
            for (const F of L.features) {
                const cls = classify(L.name, F.props, F.type);
                if (!cls) continue;
                const parts = rings(F.cmds);
                if (cls === 'wlabel') {
                    for (const r of parts) labels.push({ name: String(F.props.name), rank: 6, cls, mz: 0, kind: 'point', pts: toLocal(r.slice(0, 2), ext) });
                    continue;
                }
                const road = L.name === 'roads';
                const st = road ? (F.props.is_tunnel ? 1 : (F.props.is_bridge ? 2 : 0)) : 0;
                const mz = road && typeof F.props.min_zoom === 'number' ? F.props.min_zoom : 0;
                const text = labelText(cls, F.props);
                const poly = F.type === 3;
                const g = groupFor(cls, st, mz, poly);
                const use = poly ? polygons(parts).flat() : parts.filter((r) => r.length >= 4);
                for (const r of use) {
                    g.parts.push(g.pts.length / 2);
                    const loc = toLocal(r, ext);
                    for (let i = 0; i < loc.length; i++) g.pts.push(loc[i]);
                    if (!poly && LABEL_RANK[cls] !== undefined && text) labels.push({ name: String(text), rank: LABEL_RANK[cls], cls, mz, kind: 'line', pts: loc });
                }
            }
        }
        const out = [];
        for (const g of groups.values()) {
            if (!g.parts.length) continue;
            g.parts.push(g.pts.length / 2);
            out.push({ cls: g.cls, st: g.st, mz: g.mz, poly: g.poly, pts: new Float32Array(g.pts), parts: new Uint32Array(g.parts) });
        }
        return { z, x, y, w, h, lngW: x / N * 360 - 180, latN, groups: out, labels };
    }

    function widthAt(cls, zv) {
        const w = WIDTHS[cls], a = WIDTH_ZV;
        if (!w) return 1;
        if (zv <= a[0]) return w[0];
        for (let i = 1; i < a.length; i++) if (zv <= a[i]) return w[i - 1] + (w[i] - w[i - 1]) * (zv - a[i - 1]) / (a[i] - a[i - 1]);
        return w[w.length - 1];
    }

    function roadFill(theme, cls, bz) {
        const P = PALETTE[theme] || PALETTE.dark;
        if (theme === 'light' && bz < LOW_FILL_BELOW && LOW_LIGHT[cls]) return LOW_LIGHT[cls];
        return P[cls];
    }

    function pathOf(g) {
        if (g.path) return g.path;
        const P = new Path2D();
        for (let k = 0; k + 1 < g.parts.length; k++) {
            const a = g.parts[k], b = g.parts[k + 1];
            if (b - a < 2) continue;
            P.moveTo(g.pts[2 * a], g.pts[2 * a + 1]);
            for (let i = a + 1; i < b; i++) P.lineTo(g.pts[2 * i], g.pts[2 * i + 1]);
            if (g.poly) P.closePath();
        }
        g.path = P;
        return P;
    }

    function paintBlock(ctx, tiles, o) {
        const P = PALETTE[o.theme] || PALETTE.dark;
        const k = o.k, unit = o.dpr / k, zv = o.zv;
        const clips = o.clips || [];
        const list = [];
        tiles.forEach((t, i) => { if (t) list.push({ t, clip: clips[i] || null }); });
        const road = (g) => g.cls === 'hw' || g.cls === 'major' || g.cls === 'minor' || g.cls === 'service' || g.cls === 'path' || g.cls === 'rail';
        const keep = (g) => !road(g) || roadDrawn(g.mz, zv);
        const each = (fn) => {
            for (const { t, clip } of list) {
                if (clip) {
                    ctx.save();
                    ctx.setTransform(1, 0, 0, 1, 0, 0);
                    ctx.beginPath();
                    ctx.rect((clip[0] - o.lngW) * k, (o.latN - clip[1]) * k, (clip[2] - clip[0]) * k, (clip[1] - clip[3]) * k);
                    ctx.clip();
                }
                ctx.setTransform(k, 0, 0, k, (t.lngW - o.lngW) * k, (o.latN - t.latN) * k);
                for (const g of t.groups) if (keep(g)) fn(g);
                if (clip) ctx.restore();
            }
        };
        ctx.lineJoin = 'round';
        ctx.lineCap = 'round';
        for (const cls of ['land', 'landuse', 'green', 'water']) {
            ctx.fillStyle = P[cls];
            each((g) => { if (g.cls === cls && g.poly) ctx.fill(pathOf(g)); });
        }
        ctx.strokeStyle = P.river;
        for (const cls of ['river', 'stream']) {
            ctx.lineWidth = widthAt(cls, zv) * unit;
            each((g) => { if (g.cls === cls && !g.poly) ctx.stroke(pathOf(g)); });
        }
        ctx.fillStyle = P.bld;
        each((g) => { if (g.cls === 'bld') ctx.fill(pathOf(g)); });
        if (o.edge) {
            ctx.strokeStyle = P.bldEdge;
            ctx.lineWidth = 0.5 * unit;
            each((g) => { if (g.cls === 'bld') ctx.stroke(pathOf(g)); });
        }
        const strokeRoads = (st, casing, alpha) => {
            ctx.globalAlpha = alpha;
            const order = casing ? CASED : FILL_ORDER;
            for (const cls of order) {
                ctx.strokeStyle = casing ? P.casing : roadFill(o.theme, cls, zv);
                ctx.lineWidth = (widthAt(cls, zv) + (casing ? 1.5 : 0)) * unit;
                each((g) => { if (g.cls === cls && g.st === st && !g.poly) ctx.stroke(pathOf(g)); });
            }
            ctx.globalAlpha = 1;
        };
        strokeRoads(1, false, 0.5);
        if (zv >= 15) strokeRoads(0, true, 1);
        strokeRoads(0, false, 1);
        strokeRoads(2, true, 1);
        strokeRoads(2, false, 1);
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        return list.length;
    }

    async function gunzip(u8) {
        const stream = new Blob([u8]).stream().pipeThrough(new DecompressionStream('gzip'));
        return new Uint8Array(await new Response(stream).arrayBuffer());
    }

    G.NymStreetDecode = Object.freeze({ decodeTile, decodeGeometry, tileLat, reproject, tileLocal, classify, buildTile, tileStats, paintBlock, widthAt, roadDrawn, roadFill, labelText, gunzip, PALETTE, WIDTHS });

    if (typeof WorkerGlobalScope === 'undefined' || !(G instanceof WorkerGlobalScope)) return;

    const canRaster = typeof OffscreenCanvas !== 'undefined' && typeof Path2D !== 'undefined';
    const raw = new Map();
    const decoded = new Map();

    async function tileFor(key) {
        let t = decoded.get(key);
        if (t) { decoded.delete(key); decoded.set(key, t); return t; }
        const r = raw.get(key);
        if (!r) return null;
        try { t = buildTile(await gunzip(r.gz), r.z, r.x, r.y); } catch (_) { t = null; }
        if (!t) { raw.delete(key); G.postMessage({ op: 'bad', key }); return null; }
        decoded.set(key, t);
        while (decoded.size > DECODED_MAX) decoded.delete(decoded.keys().next().value);
        return t;
    }

    const copyGroups = (t) => t.groups.map((g) => ({ cls: g.cls, st: g.st, mz: g.mz, poly: g.poly, pts: g.pts.slice(), parts: g.parts.slice() }));

    let chain = Promise.resolve();
    const serial = (fn) => { chain = chain.then(fn, fn); return chain; };

    G.onmessage = (e) => {
        const d = e.data || {};
        if (d.op === 'init') { G.postMessage({ op: 'ready', raster: canRaster && !d.noRaster }); return; }
        if (d.op === 'add') {
            for (const t of d.tiles || []) {
                const cur = raw.get(t.key);
                if (cur && cur.level <= t.level) continue;
                raw.set(t.key, { z: t.z, x: t.x, y: t.y, level: t.level, gz: new Uint8Array(t.gz) });
                decoded.delete(t.key);
            }
            return;
        }
        if (d.op === 'drop') { for (const k of d.keys || []) { raw.delete(k); decoded.delete(k); } return; }
        if (d.op === 'clear') { raw.clear(); decoded.clear(); return; }
        if (d.op === 'raster') {
            serial(async () => {
                try {
                    const t0 = performance.now();
                    const tiles = [];
                    for (const k of d.keys) tiles.push(await tileFor(k));
                    const decodeMs = performance.now() - t0;
                    if (!canRaster || d.noRaster) {
                        const out = [], transfer = [];
                        tiles.forEach((t, i) => {
                            if (!t) { out.push(null); return; }
                            const groups = copyGroups(t);
                            for (const g of groups) transfer.push(g.pts.buffer, g.parts.buffer);
                            out.push({ key: d.keys[i], lngW: t.lngW, latN: t.latN, w: t.w, h: t.h, groups });
                        });
                        G.postMessage({ op: 'geom', id: d.id, tiles: out, decodeMs }, transfer);
                        return;
                    }
                    const canvas = new OffscreenCanvas(d.size, d.size);
                    const ctx = canvas.getContext('2d');
                    const n = paintBlock(ctx, tiles, d);
                    const bitmap = canvas.transferToImageBitmap();
                    G.postMessage({ op: 'block', id: d.id, bitmap, n, decodeMs, ms: performance.now() - t0 }, [bitmap]);
                } catch (_) { G.postMessage({ op: 'block', id: d.id, bitmap: null, n: 0 }); }
            });
            return;
        }
        if (d.op === 'labels') {
            serial(async () => {
                const items = [];
                try {
                    for (const k of d.keys) {
                        const t = await tileFor(k);
                        if (!t) continue;
                        for (const l of t.labels) items.push({ key: k, lngW: t.lngW, latN: t.latN, name: l.name, rank: l.rank, cls: l.cls, mz: l.mz, kind: l.kind, pts: l.pts.slice() });
                    }
                } catch (_) { items.length = 0; }
                G.postMessage({ op: 'labels', id: d.id, items });
            });
        }
    };
})();
