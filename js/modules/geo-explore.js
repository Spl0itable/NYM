(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
    const WINDOW_OPTIONS = Object.freeze([1, 24, 168]);
    const CLUSTER_CELL_PX = 48;
    const CLUSTER_GRID_ZOOM = 4;
    const CLUSTER_SEED_PX = 6;
    const CLUSTER_GAP_PX = 2;
    const CLUSTER_ZOOM_STEPS = 4;
    const MAX_ZOOM = 32768;
    const GRID_AUTO_PX_PER_DEG = 400;
    const GRID_LABEL_DX = 6;
    const GRID_LABEL_DY = 5;
    const PULSE_WINDOW_MS = 300000;
    const ONLINE_WINDOW_SEC = 300;
    const SEARCH_MIN_CHARS = 2;
    const SEARCH_LIMIT = 8;
    const MIN_TOUCH_PX = 44;
    const PEEK_CONTENT_MAX = 140;
    const PEEK_FETCH_CAP = 500;
    const PRECISION_LABELS = Object.freeze([
        'Subcontinent', 'Large region', 'Region', 'Metro area', 'Town or district', 'Neighborhood',
        'Street block', 'Building', 'Room', 'Spot', 'Pinpoint', 'Pinpoint',
    ]);
    const KIND_PRECISION = Object.freeze({ country: 2, admin1: 3, city: 4 });
    const KIND_ORDER = { country: 0, admin1: 1, city: 2 };

    const FOLD_GROUPS = [
        ['àáâãäåāăą', 'a'], ['çćĉċč', 'c'], ['ďđð', 'd'], ['èéêëēĕėęě', 'e'], ['ĝğġģ', 'g'], ['ĥħ', 'h'],
        ['ìíîïĩīĭįı', 'i'], ['ĵ', 'j'], ['ķ', 'k'], ['ĺļľŀł', 'l'], ['ñńņňŉ', 'n'], ['òóôõöøōŏő', 'o'],
        ['ŕŗř', 'r'], ['śŝşšș', 's'], ['ţťŧț', 't'], ['ùúûüũūŭůűų', 'u'], ['ŵ', 'w'], ['ýÿŷ', 'y'],
        ['źżž', 'z'], ['ß', 'ss'], ['æ', 'ae'], ['œ', 'oe'], ['þ', 'th'],
    ];
    const FOLD = new Map();
    for (const [chars, to] of FOLD_GROUPS) for (const ch of chars) FOLD.set(ch, to);

    function cmp(a, b) { return a < b ? -1 : (a > b ? 1 : 0); }

    function foldText(s) {
        if (typeof s !== 'string') return '';
        let out = '';
        for (const ch of s.toLowerCase()) {
            const f = FOLD.get(ch);
            out += f === undefined ? ch : f;
        }
        return out.replace(/['’`]/g, '').replace(/\s+/g, ' ').trim();
    }

    function normalizeQuery(raw) {
        return foldText(raw).replace(/^#+/, '').trim();
    }

    function isBase32(s) {
        for (const ch of s) if (BASE32.indexOf(ch) < 0) return false;
        return true;
    }

    function isValidGeohash(s) {
        return typeof s === 'string' && s.length >= 1 && s.length <= 12 && isBase32(s.toLowerCase());
    }

    function classifyQuery(raw) {
        const q = normalizeQuery(raw);
        if (!q) return { type: 'empty' };
        if (!/^[0-9a-z]+$/.test(q)) return { type: 'place' };
        const chars = isBase32(q);
        const valid = chars && q.length <= 12;
        if (/[0-9]/.test(q)) {
            if (valid) return { type: 'geohash', geohash: q };
            return { type: 'invalid', reason: chars ? 'length' : 'chars' };
        }
        return valid ? { type: 'maybe', geohash: q } : { type: 'place' };
    }

    function encodeGeohash(lat, lng, precision) {
        let latLo = -90, latHi = 90, lngLo = -180, lngHi = 180;
        let isEven = true, bit = 0, ch = 0, out = '';
        while (out.length < precision) {
            if (isEven) {
                const mid = (lngLo + lngHi) / 2;
                if (lng >= mid) { ch = (ch << 1) + 1; lngLo = mid; } else { ch = ch << 1; lngHi = mid; }
            } else {
                const mid = (latLo + latHi) / 2;
                if (lat >= mid) { ch = (ch << 1) + 1; latLo = mid; } else { ch = ch << 1; latHi = mid; }
            }
            isEven = !isEven;
            if (++bit === 5) { out += BASE32[ch]; bit = 0; ch = 0; }
        }
        return out;
    }

    function cellBounds(geohash) {
        if (!isValidGeohash(geohash)) return null;
        let latLo = -90, latHi = 90, lngLo = -180, lngHi = 180, isEven = true;
        for (const c of geohash.toLowerCase()) {
            const cd = BASE32.indexOf(c);
            for (let j = 4; j >= 0; j--) {
                const on = (cd >> j) & 1;
                if (isEven) {
                    const mid = (lngLo + lngHi) / 2;
                    if (on) lngLo = mid; else lngHi = mid;
                } else {
                    const mid = (latLo + latHi) / 2;
                    if (on) latLo = mid; else latHi = mid;
                }
                isEven = !isEven;
            }
        }
        return { latLo, latHi, lngLo, lngHi };
    }

    function placeGeohash(place) {
        const p = KIND_PRECISION[place && place.kind] || 4;
        return encodeGeohash(place.lat, place.lng, p);
    }

    function wordsOf(s) {
        return s.split(/[\s\-.,()/]+/).filter(Boolean);
    }

    function matchTier(keys, q) {
        let best = -1;
        for (const k of keys) {
            let t = -1;
            if (k === q) t = 0;
            else if (k.startsWith(q)) t = 1;
            else if (wordsOf(k).some((w) => w.startsWith(q))) t = 2;
            else if (q.length >= 3 && k.includes(q)) t = 3;
            if (t >= 0 && (best < 0 || t < best)) best = t;
        }
        return best;
    }

    function rankPlaces(places, raw, limit) {
        const q = normalizeQuery(raw);
        const parts = q.split(',');
        const main = parts[0].trim();
        const qual = parts.slice(1).join(',').trim();
        if (main.length < SEARCH_MIN_CHARS || !Array.isArray(places)) return [];
        const out = [];
        for (const p of places) {
            if (!p || !p.name) continue;
            const keys = [];
            for (const k of [foldText(p.name), foldText(p.alt || '')]) if (k && !keys.includes(k)) keys.push(k);
            const tier = matchTier(keys, main);
            if (tier < 0) continue;
            if (qual) {
                const okQual = foldText(p.country || '').startsWith(qual)
                    || foldText(p.region || '').startsWith(qual)
                    || (p.code && p.code === qual);
                if (!okQual) continue;
            }
            out.push({
                kind: p.kind, name: p.name, country: p.country || '', region: p.region || '', code: p.code || '',
                lat: p.lat, lng: p.lng, size: p.size || 0, tier, _key: foldText(p.name),
            });
        }
        out.sort((a, b) => (a.tier - b.tier)
            || ((KIND_ORDER[a.kind] ?? 3) - (KIND_ORDER[b.kind] ?? 3))
            || (b.size - a.size)
            || cmp(a._key, b._key)
            || cmp(a.country, b.country)
            || (a.lat - b.lat)
            || (a.lng - b.lng));
        const n = typeof limit === 'number' && limit > 0 ? limit : SEARCH_LIMIT;
        return out.slice(0, n).map((r) => {
            const { _key, ...rest } = r;
            return rest;
        });
    }

    function buildSearchResults(places, raw, limit) {
        const n = typeof limit === 'number' && limit > 0 ? limit : SEARCH_LIMIT;
        const c = classifyQuery(raw);
        if (c.type === 'empty') return [];
        const matches = rankPlaces(places, raw, n).map((m) => ({
            type: 'place', kind: m.kind, name: m.name, country: m.country, region: m.region,
            tier: m.tier, geohash: placeGeohash(m),
        }));
        let out;
        if (c.type === 'geohash' || c.type === 'maybe') {
            out = [{ type: 'geohash', geohash: c.geohash, precision: c.geohash.length }].concat(matches);
        } else if (c.type === 'invalid') out = [{ type: 'invalid', reason: c.reason }].concat(matches);
        else out = matches;
        return out.slice(0, n);
    }

    function roomPlaceLabel(places, geohash) {
        const b = cellBounds(geohash);
        if (!b || geohash.length < 3 || !Array.isArray(places)) return '';
        const lat = (b.latLo + b.latHi) / 2;
        const lng = (b.lngLo + b.lngHi) / 2;
        const maxKm = Math.max(25, haversineKm(lat, lng, b.latHi, b.lngHi));
        let best = null, bestKm = Infinity;
        for (const p of places) {
            if (!p || p.kind !== 'city' || !p.name) continue;
            const km = haversineKm(lat, lng, p.lat, p.lng);
            if (km < bestKm || (km === bestKm && best && ((p.size || 0) > (best.size || 0)
                || ((p.size || 0) === (best.size || 0) && cmp(p.name, best.name) < 0)))) {
                best = p; bestKm = km;
            }
        }
        if (!best || bestKm > maxKm) return '';
        return best.country ? `${best.name}, ${best.country}` : best.name;
    }

    function num(v) { return typeof v === 'number' && isFinite(v) ? v : null; }

    function isoCode(v) {
        const s = typeof v === 'string' ? v.toLowerCase() : '';
        return /^[a-z]{2}$/.test(s) ? s : '';
    }

    function buildPlaceIndex(src) {
        const out = [];
        const cities = src && src.cities && Array.isArray(src.cities.features) ? src.cities.features : [];
        for (const f of cities) {
            const p = (f && f.properties) || {};
            const coords = f && f.geometry && Array.isArray(f.geometry.coordinates) ? f.geometry.coordinates : [];
            const lat = num(p.latitude) ?? num(coords[1]);
            const lng = num(p.longitude) ?? num(coords[0]);
            const name = typeof p.name === 'string' ? p.name : '';
            if (!name || lat === null || lng === null) continue;
            out.push({
                kind: 'city', name, alt: typeof p.nameascii === 'string' ? p.nameascii : '',
                country: typeof p.adm0name === 'string' ? p.adm0name : '',
                region: typeof p.adm1name === 'string' ? p.adm1name : '',
                code: isoCode(p.iso_a2), lat, lng, size: num(p.pop_max) || 0,
            });
        }
        const admin1 = src && src.admin1 && Array.isArray(src.admin1.features) ? src.admin1.features : [];
        for (const f of admin1) {
            const p = (f && f.properties) || {};
            const lat = num(p.latitude);
            const lng = num(p.longitude);
            const name = typeof p.name === 'string' ? p.name : '';
            if (!name || lat === null || lng === null) continue;
            out.push({
                kind: 'admin1', name, alt: '', country: typeof p.admin === 'string' ? p.admin : '', region: '',
                code: isoCode(p.iso_a2), lat, lng, size: num(p.area_sqkm) || 0,
            });
        }
        const countries = src && Array.isArray(src.countries) ? src.countries : [];
        for (const f of countries) {
            const c = f && f.centroid;
            if (!f || !f.name || !Array.isArray(c) || num(c[0]) === null || num(c[1]) === null) continue;
            out.push({
                kind: 'country', name: f.name, alt: '', country: '', region: '', code: '',
                lat: c[1], lng: c[0], size: num(f.area) || 0,
            });
        }
        return out;
    }

    function formatLength(m) {
        if (m >= 10000) return `${Math.round(m / 1000)} km`;
        if (m >= 1000) return `${(m / 1000).toFixed(1)} km`;
        if (m >= 10) return `${Math.round(m)} m`;
        if (m >= 1) return `${m.toFixed(1)} m`;
        return `${Math.round(m * 100)} cm`;
    }

    function cellSizeMeters(geohash) {
        const b = cellBounds(geohash);
        if (!b) return null;
        const latC = (b.latLo + b.latHi) / 2;
        return {
            w: (b.lngHi - b.lngLo) * 111320 * Math.cos(latC * Math.PI / 180),
            h: (b.latHi - b.latLo) * 110574,
        };
    }

    function precisionSteps(geohash) {
        if (!isValidGeohash(geohash)) return [];
        const gh = geohash.toLowerCase();
        const out = [];
        for (let i = 1; i <= gh.length; i++) {
            const prefix = gh.slice(0, i);
            const s = cellSizeMeters(prefix);
            out.push({
                geohash: prefix, length: i, label: PRECISION_LABELS[i - 1],
                size: `${formatLength(s.w)} × ${formatLength(s.h)}`,
            });
        }
        return out;
    }

    function haversineKm(lat1, lon1, lat2, lon2) {
        const R = 6371;
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
            + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180)
            * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        return R * (2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)));
    }

    function formatDistanceKm(km) {
        if (km < 0.9995) return `${Math.round(km * 1000)} m`;
        if (km < 9.95) return `${km.toFixed(1)} km`;
        return `${Math.round(km)} km`;
    }

    function rankActive(channels) {
        return (Array.isArray(channels) ? channels.slice() : [])
            .sort((a, b) => (b.messages - a.messages) || cmp(a.geohash, b.geohash));
    }

    function rankNearby(channels, loc) {
        if (!loc || num(loc.lat) === null || num(loc.lng) === null || !Array.isArray(channels)) return [];
        return channels
            .map((c) => Object.assign({}, c, { distanceKm: haversineKm(loc.lat, loc.lng, c.lat, c.lng) }))
            .sort((a, b) => (a.distanceKm - b.distanceKm) || (b.messages - a.messages) || cmp(a.geohash, b.geohash));
    }

    function clusterRadius(count) {
        if (count < 2) return 4;
        let bits = 0;
        for (let n = count; n > 1; n = Math.floor(n / 2)) bits++;
        return 12 + Math.min(6, 2 * bits);
    }

    function clusterZoomStep(zoom) {
        const z = typeof zoom === 'number' && zoom > 0 ? Math.min(zoom, MAX_ZOOM) : 1;
        if (z < CLUSTER_GRID_ZOOM) return Math.max(1, Math.floor(z * CLUSTER_ZOOM_STEPS) / CLUSTER_ZOOM_STEPS);
        let base = CLUSTER_GRID_ZOOM;
        while (base * 2 <= z) base *= 2;
        const q = base / CLUSTER_ZOOM_STEPS;
        return base + Math.floor((z - base) / q) * q;
    }

    function stepAt(i) {
        const below = (CLUSTER_GRID_ZOOM - 1) * CLUSTER_ZOOM_STEPS;
        if (i < below) return 1 + i / CLUSTER_ZOOM_STEPS;
        const j = i - below;
        return CLUSTER_GRID_ZOOM * Math.pow(2, Math.floor(j / CLUSTER_ZOOM_STEPS)) * (1 + (j % CLUSTER_ZOOM_STEPS) / CLUSTER_ZOOM_STEPS);
    }

    function stepIndex(zq) {
        let i = 0;
        while (stepAt(i) < zq) i++;
        return i;
    }

    function clusterSplitZoom(points, zoom, viewport) {
        const splits = (z) => clusterChannels(points, z, viewport).length > 1;
        if (!splits(MAX_ZOOM)) return null;
        let lo = stepIndex(clusterZoomStep(zoom));
        if (splits(stepAt(lo))) return stepAt(lo);
        let hi = stepIndex(MAX_ZOOM);
        while (hi - lo > 1) {
            const mid = Math.floor((lo + hi) / 2);
            if (splits(stepAt(mid))) hi = mid; else lo = mid;
        }
        return stepAt(hi);
    }

    function deepGrid(pxPerDeg) {
        return typeof pxPerDeg === 'number' && pxPerDeg >= GRID_AUTO_PX_PER_DEG;
    }

    function gridCornerLabel(cell, textW, lineH, o) {
        const opts = o || {};
        const x = Math.max(cell.x0, 0) + GRID_LABEL_DX;
        const y = Math.max(cell.y0, 0) + GRID_LABEL_DY;
        if (x + textW > opts.width || y + lineH > opts.height) return null;
        if (x + textW > cell.x1 || y + lineH > cell.y1) return null;
        if (cell.y0 < 0 && cell.y1 + GRID_LABEL_DY - y < 2 * lineH) return null;
        if (cell.x0 < 0 && cell.x1 + GRID_LABEL_DX - (x + textW) < lineH) return null;
        const x1 = x + textW, y1 = y + lineH;
        for (const b of opts.blocked || []) {
            if (x < b.x1 && x1 > b.x0 && y < b.y1 && y1 > b.y0) return null;
        }
        return { x, y };
    }

    function clusterChannels(points, zoom, viewport) {
        const w = viewport && viewport.width > 0 ? viewport.width : 1;
        const h = viewport && viewport.height > 0 ? viewport.height : 1;
        const zq = clusterZoomStep(zoom);
        const s = Math.max(w / 360, h / 180) * zq;
        const cell = CLUSTER_CELL_PX;
        const seed = zq < CLUSTER_GRID_ZOOM ? CLUSTER_CELL_PX : CLUSTER_SEED_PX;
        const make = (members) => {
            const m = members.slice().sort((a, b) => cmp(a.id, b.id));
            let sLat = 0, sLng = 0, msgs = 0;
            for (const p of m) { sLat += p.lat; sLng += p.lng; msgs += p.messages || 0; }
            const lat = sLat / m.length, lng = sLng / m.length;
            return { members: m, key: m[0].id, lat, lng, wx: (lng + 180) * s, wy: (90 - lat) * s, r: clusterRadius(m.length), messages: msgs };
        };
        const groups = new Map();
        for (const p of (Array.isArray(points) ? points : [])) {
            if (!p || !Number.isFinite(p.lat) || !Number.isFinite(p.lng) || typeof p.id !== 'string') continue;
            const key = Math.floor((p.lng + 180) * s / seed) + ',' + Math.floor((90 - p.lat) * s / seed);
            let g = groups.get(key);
            if (!g) { g = []; groups.set(key, g); }
            g.push(p);
        }
        let list = [...groups.values()].map(make);
        const bucketOf = (k) => Math.floor(k.wx / cell) + ',' + Math.floor(k.wy / cell);
        const buckets = new Map();
        const put = (k) => {
            const key = bucketOf(k);
            let b = buckets.get(key);
            if (!b) { b = new Set(); buckets.set(key, b); }
            b.add(k);
        };
        const near = (k) => {
            const out = [];
            const bx = Math.floor(k.wx / cell), by = Math.floor(k.wy / cell);
            for (let ox = -1; ox <= 1; ox++) for (let oy = -1; oy <= 1; oy++) {
                const b = buckets.get((bx + ox) + ',' + (by + oy));
                if (!b) continue;
                for (const o of b) {
                    if (o === k) continue;
                    const lo = cmp(k.key, o.key) < 0 ? k : o, hi = lo === k ? o : k;
                    const dx = hi.wx - lo.wx, dy = hi.wy - lo.wy;
                    const lim = lo.r + hi.r + CLUSTER_GAP_PX;
                    const d = dx * dx + dy * dy;
                    if (d < lim * lim) out.push({ a: lo, b: hi, d });
                }
            }
            return out;
        };
        list.forEach(put);
        let pairs = [];
        for (const k of list) for (const p of near(k)) if (p.a === k) pairs.push(p);
        while (pairs.length) {
            pairs.sort((x, y) => (x.d - y.d) || cmp(x.a.key, y.a.key) || cmp(x.b.key, y.b.key));
            const used = new Set();
            const merged = [];
            for (const p of pairs) {
                if (used.has(p.a) || used.has(p.b)) continue;
                used.add(p.a); used.add(p.b);
                merged.push(make(p.a.members.concat(p.b.members)));
            }
            for (const k of used) buckets.get(bucketOf(k)).delete(k);
            pairs = pairs.filter((p) => !used.has(p.a) && !used.has(p.b));
            merged.forEach(put);
            const fresh = new Set(merged);
            for (const m of merged) {
                for (const p of near(m)) {
                    const o = p.a === m ? p.b : p.a;
                    if (fresh.has(o) && p.a !== m) continue;
                    pairs.push(p);
                }
            }
            list = list.filter((k) => !used.has(k)).concat(merged);
        }
        list.sort((a, b) => cmp(a.key, b.key));
        return list.map((k) => ({
            ids: k.members.map((p) => p.id), lat: k.lat, lng: k.lng, count: k.members.length, messages: k.messages, r: k.r,
        }));
    }

    function isRecent(lastMs, nowMs) {
        return lastMs > 0 && nowMs - lastMs <= PULSE_WINDOW_MS;
    }

    function normalizeWindowHours(h) {
        return WINDOW_OPTIONS.includes(h) ? h : 24;
    }

    function tagValue(tags, name) {
        if (!Array.isArray(tags)) return null;
        for (const t of tags) if (Array.isArray(t) && t[0] === name && typeof t[1] === 'string') return t[1];
        return null;
    }

    function clip(s) {
        const flat = s.replace(/\s+/g, ' ').trim();
        const cps = Array.from(flat);
        return cps.length > PEEK_CONTENT_MAX ? cps.slice(0, PEEK_CONTENT_MAX).join('') + '…' : flat;
    }

    function summarizePeek(events, opts) {
        const o = opts || {};
        const gh = String(o.geohash || '').toLowerCase();
        const blocked = new Set(Array.isArray(o.blocked) ? o.blocked : []);
        const nowSec = typeof o.nowSec === 'number' ? o.nowSec : Math.floor(Date.now() / 1000);
        const limit = typeof o.limit === 'number' && o.limit > 0 ? o.limit : 5;
        const seen = new Set();
        const valid = [];
        for (const e of (Array.isArray(events) ? events : [])) {
            if (!e || typeof e !== 'object' || e.kind !== 20000 || typeof e.id !== 'string') continue;
            if (seen.has(e.id)) continue;
            const g = tagValue(e.tags, 'g');
            if (!g || g.toLowerCase() !== gh) continue;
            if (tagValue(e.tags, 'edit') !== null) continue;
            if (typeof e.pubkey !== 'string' || blocked.has(e.pubkey)) continue;
            if (typeof e.content !== 'string' || !e.content.trim()) continue;
            if (typeof e.created_at !== 'number') continue;
            seen.add(e.id);
            valid.push(e);
        }
        const online = new Set();
        for (const pk of (Array.isArray(o.localOnline) ? o.localOnline : [])) {
            if (typeof pk === 'string' && !blocked.has(pk)) online.add(pk);
        }
        for (const e of valid) if (e.created_at >= nowSec - ONLINE_WINDOW_SEC) online.add(e.pubkey);
        const newest = valid.slice().sort((a, b) => (b.created_at - a.created_at) || cmp(a.id, b.id)).slice(0, limit);
        const messages = newest.reverse().map((e) => ({
            id: e.id, pubkey: e.pubkey, nym: tagValue(e.tags, 'n') || '', content: clip(e.content), createdAt: e.created_at,
        }));
        return { messages, online: online.size, total: valid.length, capped: o.capped === true };
    }

    function peekCapped(events) {
        if (!Array.isArray(events)) return false;
        let n = 0;
        for (const e of events) if (e && typeof e === 'object' && e.kind !== 9735) n++;
        return n >= PEEK_FETCH_CAP;
    }

    function peekCountLabel(summary) {
        if (!summary || typeof summary.total !== 'number') return '';
        return String(summary.total) + (summary.capped ? '+' : '');
    }

    const MAX_DPR = 2;
    const TIER_PX_PER_DEG = Object.freeze([7, 40]);
    const LABEL_PAD = 3;

    function capDpr(dpr) {
        return (typeof dpr === 'number' && isFinite(dpr) && dpr > 0) ? Math.min(dpr, MAX_DPR) : 1;
    }

    function tierFor(pxPerDeg) {
        let t = 0;
        for (const th of TIER_PX_PER_DEG) if (pxPerDeg >= th) t++;
        return t;
    }

    function cityRankCutoff(zoom) {
        return zoom < 3 ? 2 : zoom < 4 ? 4 : zoom < 6 ? 6 : zoom < 8 ? 8 : 10;
    }

    function placeLabels(boxes, pad, blocked) {
        const pd = typeof pad === 'number' ? pad : LABEL_PAD;
        const cell = 64;
        const grid = new Map();
        const out = [];
        const list = Array.isArray(boxes) ? boxes : [];
        const fixed = Array.isArray(blocked) ? blocked : [];
        const all = fixed.concat(list);
        const occupy = (j) => {
            const b = all[j];
            const gx0 = Math.floor((b.x0 - pd) / cell), gx1 = Math.floor((b.x1 + pd) / cell);
            const gy0 = Math.floor((b.y0 - pd) / cell), gy1 = Math.floor((b.y1 + pd) / cell);
            for (let gx = gx0; gx <= gx1; gx++) {
                for (let gy = gy0; gy <= gy1; gy++) {
                    const k = gx + ',' + gy;
                    const bucket = grid.get(k);
                    if (bucket) bucket.push(j); else grid.set(k, [j]);
                }
            }
        };
        for (let j = 0; j < fixed.length; j++) occupy(j);
        for (let i = 0; i < list.length; i++) {
            const b = list[i];
            const gx0 = Math.floor((b.x0 - pd) / cell), gx1 = Math.floor((b.x1 + pd) / cell);
            const gy0 = Math.floor((b.y0 - pd) / cell), gy1 = Math.floor((b.y1 + pd) / cell);
            let free = true;
            for (let gx = gx0; gx <= gx1 && free; gx++) {
                for (let gy = gy0; gy <= gy1 && free; gy++) {
                    const bucket = grid.get(gx + ',' + gy);
                    if (!bucket) continue;
                    for (const j of bucket) {
                        const o = all[j];
                        if (b.x0 - pd < o.x1 && o.x0 < b.x1 + pd && b.y0 - pd < o.y1 && o.y0 < b.y1 + pd) { free = false; break; }
                    }
                }
            }
            if (!free) continue;
            out.push(i);
            occupy(fixed.length + i);
        }
        return out;
    }

    function fitLabelBox(box, o) {
        const pd = typeof o.pad === 'number' ? o.pad : LABEL_PAD;
        const lo = pd, hiX = o.width - pd, hiY = o.height - pd;
        let x0 = box.x0, y0 = box.y0, x1 = box.x1, y1 = box.y1;
        const bw = x1 - x0, bh = y1 - y0;
        if (bw > hiX - lo || bh > hiY - lo) return null;
        let flipped = false;
        if (o.side) {
            if (o.anchorX - 2.5 < lo || o.anchorX + 2.5 > hiX) return null;
            if (x1 > hiX) { x1 = o.anchorX + 2.5; x0 = x1 - bw; flipped = true; }
            if (x0 < lo) return null;
            const dy = y0 < lo ? lo - y0 : (y1 > hiY ? hiY - y1 : 0);
            if (Math.abs(dy) > bh / 2) return null;
            y0 += dy; y1 += dy;
        } else {
            const dx = x0 < lo ? lo - x0 : (x1 > hiX ? hiX - x1 : 0);
            const dy = y0 < lo ? lo - y0 : (y1 > hiY ? hiY - y1 : 0);
            x0 += dx; x1 += dx; y0 += dy; y1 += dy;
        }
        return { x0, y0, x1, y1, flipped };
    }

    G.NymGeoExplore = Object.freeze({
        BASE32, WINDOW_OPTIONS, CLUSTER_CELL_PX, CLUSTER_GRID_ZOOM, CLUSTER_SEED_PX, CLUSTER_GAP_PX, CLUSTER_ZOOM_STEPS, MAX_ZOOM, GRID_AUTO_PX_PER_DEG,
        PULSE_WINDOW_MS, ONLINE_WINDOW_SEC, clusterZoomStep, clusterSplitZoom, deepGrid, GRID_LABEL_DX, GRID_LABEL_DY, gridCornerLabel,
        SEARCH_MIN_CHARS, SEARCH_LIMIT, MIN_TOUCH_PX, PRECISION_LABELS, KIND_PRECISION,
        foldText, normalizeQuery, classifyQuery, isValidGeohash, encodeGeohash, cellBounds, placeGeohash,
        rankPlaces, buildPlaceIndex, buildSearchResults, roomPlaceLabel, formatLength, cellSizeMeters, precisionSteps, haversineKm, formatDistanceKm,
        rankActive, rankNearby, clusterChannels, clusterRadius, isRecent, normalizeWindowHours, summarizePeek, peekCapped, peekCountLabel, PEEK_FETCH_CAP,
        MAX_DPR, TIER_PX_PER_DEG, LABEL_PAD, capDpr, tierFor, cityRankCutoff, placeLabels, fitLabelBox,
    });
})();
