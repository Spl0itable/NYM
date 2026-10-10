(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const APP_RELAY = 'wss://relay.nymchat.app';
    const TOMBSTONE_MS = 90 * 86400000;
    const CAPS = Object.freeze({ items: 500, removed: 500 });
    const RX_URL = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)/;

    function parse(url) {
        if (typeof url !== 'string') return null;
        const m = RX_URL.exec(url.trim());
        if (!m) return null;
        const scheme = m[1].toLowerCase();
        if (scheme !== 'wss' && scheme !== 'ws') return null;
        let auth = m[2];
        const at = auth.lastIndexOf('@');
        if (at >= 0) auth = auth.slice(at + 1);
        let host = auth;
        let port = '';
        const close = auth.lastIndexOf(']');
        const colon = auth.lastIndexOf(':');
        if (colon > close) {
            host = auth.slice(0, colon);
            port = auth.slice(colon + 1);
        }
        if (!host) return null;
        if (port) {
            if (!/^\d{1,5}$/.test(port)) return null;
            const n = parseInt(port, 10);
            if (n > 65535) return null;
            port = ((scheme === 'wss' && n === 443) || (scheme === 'ws' && n === 80)) ? '' : String(n);
        }
        const path = m[3].replace(/\/+$/, '');
        return scheme + '://' + host.toLowerCase() + (port ? ':' + port : '') + path;
    }

    function canon(url) {
        if (typeof url !== 'string') return url;
        const c = parse(url);
        return c === null ? url.trim() : c;
    }

    function blockable(url) {
        const c = parse(url);
        return c !== null && c.startsWith('wss://') && c !== APP_RELAY;
    }

    function shown(url) {
        return String(url || '').replace(/^wss?:\/\//i, '');
    }

    function searchMatch(url, query) {
        const q = shown(String(query || '').trim()).toLowerCase();
        if (!q) return true;
        return shown(url).toLowerCase().includes(q);
    }

    function int(v) {
        if (typeof v !== 'number' || !isFinite(v) || Math.abs(v) > Number.MAX_SAFE_INTEGER) return 0;
        return Math.floor(v);
    }

    function obj(v) {
        return v && typeof v === 'object' && !Array.isArray(v) ? v : {};
    }

    function cmpStr(a, b) {
        return a < b ? -1 : a > b ? 1 : 0;
    }

    function tsMap(raw) {
        const src = obj(raw);
        const out = {};
        for (const k of Object.keys(src)) {
            const v = int(src[k]);
            if (v <= 0 || !blockable(k)) continue;
            const c = canon(k);
            if (!(c in out) || v > out[c]) out[c] = v;
        }
        return out;
    }

    function capped(map, cap) {
        const rows = Object.keys(map).map((k) => [k, map[k]]);
        rows.sort((x, y) => (y[1] - x[1]) || cmpStr(x[0], y[0]));
        const out = {};
        for (const [k, v] of rows.slice(0, cap)) out[k] = v;
        return out;
    }

    function settle(items, removed, now) {
        for (const k of Object.keys(items)) {
            if (removed[k] === undefined) continue;
            if (removed[k] >= items[k]) delete items[k];
            else delete removed[k];
        }
        const floor = int(now) - TOMBSTONE_MS;
        for (const k of Object.keys(removed)) if (removed[k] < floor) delete removed[k];
        return { items: capped(items, CAPS.items), removed: capped(removed, CAPS.removed) };
    }

    function norm(raw, now) {
        const o = obj(raw);
        return settle(tsMap(o.items), tsMap(o.removed), now);
    }

    function newest(a, b) {
        const out = Object.assign({}, a);
        for (const k of Object.keys(b)) if (!(k in out) || b[k] > out[k]) out[k] = b[k];
        return out;
    }

    function merge(a, b, now) {
        const x = obj(a);
        const y = obj(b);
        return settle(newest(tsMap(x.items), tsMap(y.items)), newest(tsMap(x.removed), tsMap(y.removed)), now);
    }

    function block(state, url, now) {
        const s = norm(state, now);
        if (!blockable(url)) return s;
        const c = canon(url);
        s.items[c] = int(now);
        delete s.removed[c];
        return settle(s.items, s.removed, now);
    }

    function unblock(state, url, now) {
        const s = norm(state, now);
        const c = canon(url);
        if (typeof c !== 'string' || !c) return s;
        delete s.items[c];
        if (blockable(c)) s.removed[c] = int(now);
        return settle(s.items, s.removed, now);
    }

    function list(state) {
        const items = obj(obj(state).items);
        const urls = Object.keys(items).filter((k) => blockable(k)).map(canon);
        return [...new Set(urls)].sort((x, y) => cmpStr(shown(x), shown(y)));
    }

    function toSet(urls) {
        const out = new Set();
        for (const u of urls || []) {
            if (typeof u !== 'string') continue;
            const c = canon(u);
            if (c && c !== APP_RELAY) out.add(c);
        }
        return out;
    }

    function isBlocked(set, url) {
        if (!set || !set.size || typeof url !== 'string') return false;
        const c = canon(url);
        return c !== APP_RELAY && set.has(c);
    }

    function filterShards(shards, blocked) {
        const set = blocked instanceof Set ? blocked : toSet(blocked);
        if (!set.size) return shards;
        const out = [];
        for (const s of shards || []) {
            const relays = (s.relays || []).filter((u) => !isBlocked(set, u));
            const dmRelays = (s.dmRelays || []).filter((u) => !isBlocked(set, u));
            if ((s.relays || []).length > 0 && relays.length === 0) continue;
            if (relays.length === (s.relays || []).length && dmRelays.length === (s.dmRelays || []).length) {
                out.push(s);
                continue;
            }
            out.push(Object.assign({}, s, { relays, dmRelays }));
        }
        return out;
    }

    function guard(url, ctx) {
        const c = ctx || {};
        const target = canon(url);
        if (target === APP_RELAY) return 'required';
        if (!blockable(url)) return 'invalid';
        const set = c.blocked instanceof Set ? c.blocked : toSet(c.blocked);
        if (set.has(target)) return 'already';
        const writeOnly = toSet(c.writeOnly);
        const readers = [...toSet(c.defaults)].filter((u) => !writeOnly.has(u));
        if (readers.includes(target) && readers.every((u) => u === target || set.has(u))) return 'last-default';
        if (c.signer && canon(c.signer) === target) return 'signer';
        return 'ok';
    }

    function keepReader(state, ctx, now) {
        const s = norm(state, now);
        const c = ctx || {};
        const writeOnly = toSet(c.writeOnly);
        const readers = [...toSet(c.defaults)].filter((u) => !writeOnly.has(u));
        if (!readers.length || readers.some((u) => s.items[u] === undefined)) return s;
        readers.sort((x, y) => (s.items[y] - s.items[x]) || cmpStr(x, y));
        const top = readers[0];
        s.removed[top] = Math.max(int(now), s.items[top] + 1);
        delete s.items[top];
        return settle(s.items, s.removed, now);
    }

    function usable(urls, blocked) {
        const set = blocked instanceof Set ? blocked : toSet(blocked);
        const list = (Array.isArray(urls) ? urls : []).filter((u) => typeof u === 'string' && u);
        const kept = list.filter((u) => !isBlocked(set, u));
        return kept.length || !list.length ? kept : [list[0]];
    }

    function geoAllBlocked(nearest, blocked) {
        const set = blocked instanceof Set ? blocked : toSet(blocked);
        const urls = (nearest || []).filter((u) => typeof u === 'string' && u);
        return urls.length > 0 && urls.every((u) => isBlocked(set, u));
    }

    G.NymRelayBlock = Object.freeze({
        APP_RELAY, TOMBSTONE_MS, CAPS, canon, blockable, shown, searchMatch, norm, merge, block, unblock,
        list, toSet, isBlocked, filterShards, guard, keepReader, usable, geoAllBlocked,
    });
})();
