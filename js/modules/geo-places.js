(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const MAGIC = 'NYP1';
    const LO_ZV = 6;
    const HI_ZV = 11;
    const DOT_MAX_ZV = 12;
    const MARGIN_PX = 32;
    const MAX_CANDIDATES = 200;
    const MAX_LABELS = 60;
    const HALO_PX = 3;
    const ZV_EPS = 1e-6;
    const GRID_W = 360;
    const GRID_H = 180;
    const URLS = Object.freeze(['/data/geo-places-lo.nyp.gz', '/data/geo-places-hi.nyp.gz']);
    const CREDITS = Object.freeze([
        'Streets: © OpenStreetMap contributors (ODbL 1.0), via Protomaps',
        'Places: GeoNames (geonames.org), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/), filtered.',
        'Natural Earth',
    ]);
    const STYLES = Object.freeze([
        Object.freeze({ px: 12, weight: 600, italic: false, color: 'cityLabel' }),
        Object.freeze({ px: 12, weight: 600, italic: false, color: 'cityLabel' }),
        Object.freeze({ px: 11, weight: 500, italic: false, color: 'cityLabel' }),
        Object.freeze({ px: 10, weight: 500, italic: false, color: 'cityLabel' }),
        Object.freeze({ px: 10, weight: 500, italic: true, color: 'adminLabel' }),
    ]);

    function zvOf(pxPerDeg) {
        return Math.log2(pxPerDeg * 360 / 256);
    }

    function wantedPacks(zv) {
        return zv >= HI_ZV ? 2 : zv >= LO_ZV ? 1 : 0;
    }

    function styleFor(kind) {
        return STYLES[kind >= 0 && kind < STYLES.length ? kind : 3];
    }

    function hasDot(kind, zv) {
        return kind <= 2 && zv < DOT_MAX_ZV;
    }

    function gridX(deg) {
        const x = Math.floor(deg + 180);
        return x < 0 ? 0 : x >= GRID_W ? GRID_W - 1 : x;
    }

    function gridY(deg) {
        const y = Math.floor(deg + 90);
        return y < 0 ? 0 : y >= GRID_H ? GRID_H - 1 : y;
    }

    function decode(buffer) {
        const b = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
        if (b.length < 24) throw new Error('places: short header');
        if (String.fromCharCode(b[0], b[1], b[2], b[3]) !== MAGIC) throw new Error('places: bad magic');
        const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
        const count = dv.getUint32(4, true), latBytes = dv.getUint32(8, true), lngBytes = dv.getUint32(12, true);
        const nameBytes = dv.getUint32(16, true), scale = dv.getUint32(20, true);
        if (!scale || 24 + latBytes + lngBytes + 2 * count + nameBytes !== b.length) throw new Error('places: bad lengths');
        let pos = 24;
        const column = (end) => {
            const out = new Int32Array(count);
            let prev = 0;
            for (let i = 0; i < count; i++) {
                let v = 0, shift = 0, byte;
                do {
                    if (pos >= end) throw new Error('places: truncated column');
                    byte = b[pos++];
                    if (shift < 28) v |= (byte & 127) << shift;
                    else v += (byte & 127) * 2 ** shift;
                    shift += 7;
                } while (byte & 128);
                prev += (v & 1) ? -(v + 1) / 2 : v / 2;
                out[i] = prev;
            }
            if (pos !== end) throw new Error('places: column length');
            return out;
        };
        const lat = column(24 + latBytes);
        const lng = column(24 + latBytes + lngBytes);
        const meta = b.slice(pos, pos + 2 * count);
        pos += 2 * count;
        const nameEnd = pos + nameBytes;
        const nameOff = new Uint32Array(count + 1);
        const names = new Uint8Array(nameBytes);
        let w = 0;
        for (let i = 0; i < count; i++) {
            let len = 0, shift = 0, byte;
            do {
                if (pos >= nameEnd) throw new Error('places: truncated names');
                byte = b[pos++];
                if (shift < 28) len |= (byte & 127) << shift;
                else len += (byte & 127) * 2 ** shift;
                shift += 7;
            } while (byte & 128);
            if (pos + len > nameEnd) throw new Error('places: truncated names');
            nameOff[i] = w;
            for (let e = pos + len; pos < e;) names[w++] = b[pos++];
        }
        nameOff[count] = w;
        if (pos !== nameEnd) throw new Error('places: names length');
        const cellStart = new Uint32Array(GRID_W * GRID_H + 1);
        const cellOf = new Uint32Array(count);
        for (let i = 0; i < count; i++) {
            const c = gridY(lat[i] / scale) * GRID_W + gridX(lng[i] / scale);
            cellOf[i] = c;
            cellStart[c + 1]++;
        }
        for (let c = 0; c < GRID_W * GRID_H; c++) cellStart[c + 1] += cellStart[c];
        const fill = cellStart.slice(0, GRID_W * GRID_H);
        const cellItems = new Uint32Array(count);
        for (let i = 0; i < count; i++) cellItems[fill[cellOf[i]]++] = i;
        return { count, scale, lat, lng, meta, names, nameOff, cellStart, cellItems };
    }

    function transferList(pack) {
        return [pack.lat.buffer, pack.lng.buffer, pack.meta.buffer, pack.names.buffer, pack.nameOff.buffer, pack.cellStart.buffer, pack.cellItems.buffer];
    }

    let utf8 = null;
    const nameCache = new WeakMap();
    function nameOf(pack, i) {
        let m = nameCache.get(pack);
        if (!m) { m = new Map(); nameCache.set(pack, m); }
        let s = m.get(i);
        if (s === undefined) {
            if (!utf8) utf8 = new TextDecoder('utf-8');
            if (m.size > 4000) m.clear();
            s = utf8.decode(pack.names.subarray(pack.nameOff[i], pack.nameOff[i + 1]));
            m.set(i, s);
        }
        return s;
    }

    let lastSelect = null;

    function sameSelect(m, packs, v) {
        if (!m || m.cx !== v.cx || m.cy !== v.cy || m.pxPerDeg !== v.pxPerDeg || m.width !== v.width || m.height !== v.height) return false;
        if (m.packs.length !== packs.length) return false;
        for (let p = 0; p < packs.length; p++) if (m.packs[p] !== packs[p]) return false;
        return true;
    }

    function select(packs, v) {
        if (sameSelect(lastSelect, packs, v)) return lastSelect.out;
        const zv = zvOf(v.pxPerDeg);
        const lim = zv * 2 + ZV_EPS;
        const hw = (v.width / 2 + MARGIN_PX) / v.pxPerDeg;
        const hh = (v.height / 2 + MARGIN_PX) / v.pxPerDeg;
        const x0 = gridX(v.cx - hw), x1 = gridX(v.cx + hw), y0 = gridY(v.cy - hh), y1 = gridY(v.cy + hh);
        const hits = [];
        for (let p = 0; p < packs.length; p++) {
            const pk = packs[p];
            if (!pk) continue;
            const { meta, lat, lng, scale, cellStart, cellItems } = pk;
            for (let gy = y0; gy <= y1; gy++) {
                for (let gx = x0; gx <= x1; gx++) {
                    const c = gy * GRID_W + gx;
                    for (let k = cellStart[c], e = cellStart[c + 1]; k < e; k++) {
                        const i = cellItems[k];
                        if (meta[2 * i] > lim) break;
                        if (Math.abs(lng[i] / scale - v.cx) > hw || Math.abs(lat[i] / scale - v.cy) > hh) continue;
                        hits.push(p, i);
                    }
                }
            }
        }
        const n = hits.length / 2;
        const idx = new Array(n);
        for (let j = 0; j < n; j++) idx[j] = j;
        const key = (j, o) => packs[hits[2 * j]].meta[2 * hits[2 * j + 1] + o];
        idx.sort((a, b) => {
            const za = key(a, 0), zb = key(b, 0);
            if (za !== zb) return za - zb;
            const ma = key(a, 1), mb = key(b, 1);
            if ((ma >> 5) !== (mb >> 5)) return (ma >> 5) - (mb >> 5);
            if ((ma & 31) !== (mb & 31)) return (mb & 31) - (ma & 31);
            return (hits[2 * a] - hits[2 * b]) || (hits[2 * a + 1] - hits[2 * b + 1]);
        });
        const out = [];
        for (let j = 0; j < n && out.length < MAX_CANDIDATES; j++) {
            const p = hits[2 * idx[j]], i = hits[2 * idx[j] + 1], pk = packs[p];
            const m = pk.meta[2 * i + 1];
            out.push({ pack: p, i, lat: pk.lat[i] / pk.scale, lng: pk.lng[i] / pk.scale, zv: pk.meta[2 * i] / 2, kind: m >> 5, pc: m & 31, name: nameOf(pk, i) });
        }
        Object.freeze(out);
        lastSelect = { packs: packs.slice(), cx: v.cx, cy: v.cy, pxPerDeg: v.pxPerDeg, width: v.width, height: v.height, out };
        return out;
    }

    async function gunzip(bytes) {
        if (bytes.length < 2 || bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
        if (typeof DecompressionStream !== 'function') throw new Error('places: no gzip');
        const ds = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
        return new Uint8Array(await new Response(ds).arrayBuffer());
    }

    async function fetchPack(url) {
        const resp = await fetch(url, { cache: 'force-cache', credentials: 'omit' });
        if (!resp || !resp.ok) throw new Error('places: http ' + (resp ? resp.status : 0));
        const bytes = await gunzip(new Uint8Array(await resp.arrayBuffer()));
        return decode(bytes.buffer.byteLength === bytes.byteLength ? bytes.buffer : bytes.slice().buffer);
    }

    G.NymGeoPlaces = Object.freeze({
        LO_ZV, HI_ZV, DOT_MAX_ZV, MARGIN_PX, MAX_CANDIDATES, MAX_LABELS, HALO_PX, URLS, CREDITS,
        zvOf, wantedPacks, styleFor, hasDot, decode, transferList, nameOf, select, fetchPack,
    });
})();
