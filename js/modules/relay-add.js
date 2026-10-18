(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const POOL_MAX_UPSTREAMS = 64;
    const STORED_MAX = 128;
    const STORAGE_KEY = 'nym_added_relays';
    const SYNC_KEY = 'addedRelays';
    const CHECK_TIMEOUT_MS = 10000;
    const STATUS_WINDOW_MS = 20000;
    const MAX_URL = 512;
    const EXCLUDED = Object.freeze(['wss://relay.nosflare.com', 'wss://relay.nostraddress.com', 'wss://nostr-server-production.up.railway.app']);
    const LOCAL_SUFFIXES = ['.local', '.internal', '.lan', '.home.arpa', '.localdomain'];

    const MESSAGES = Object.freeze({
        empty: 'Enter a relay address.',
        format: "That isn't a valid relay address.",
        scheme: 'A relay address starts with wss://.',
        insecure: 'Only secure relays (wss://) can be added.',
        port: 'Relays can only be added on the standard port (443).',
        loopback: '{host} points back to this device. Only public relays can be added.',
        'link-local': '{host} is a link-local address. Only public relays can be added.',
        private: '{host} is a private network address. Only public relays can be added.',
        local: '{host} is a local network name. Only public relays can be added.',
        ip: "Enter the relay's domain name, like relay.example.com. IP addresses can't be added.",
        onion: "Tor and I2P relays can't be added.",
        excluded: "{relay} can't be added: Nymchat never connects to it.",
        default: '{relay} is already one of the default relays.',
        added: 'You already added {relay}.',
        blocked: '{relay} is on your blocked list. Unblock it to use it again.',
        cap: 'You can add up to {cap} relays: with the {defaults} default relays that is the most the relay pool connects to. Remove one to add another.',
        checkingPool: 'Checking {relay} through the relay pool…',
        checkingDirect: 'Checking {relay}…',
        reachable: '{relay} answered in {ms} ms.',
        refused: '{relay} refused the connection: {reason}',
        timeout: "{relay} didn't answer within {s} seconds.",
        unreachable: "Couldn't connect to {relay}.",
        poolDown: "Couldn't reach the relay pool to check {relay}.",
        done: 'Added {relay}.',
        unblocked: '{relay} is unblocked and back in use as a default relay.',
        restored: '{relay} is unblocked and back in use as one of your added relays.',
        restoredCap: '{relay} is unblocked and back with your added relays, but not in use yet.',
        keypair: "Relays you add aren't used while Keypair Mode makes a new keypair each session or message: the same relays on every key would link them.",
    });

    const RX_SCHEME = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//;
    const RX_LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
    const RX_PATH = /^(?:\/[A-Za-z0-9._~!$&'()*+,;=:@%-]*)*$/;
    const RX_TRIM = /^[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$/g;
    const RX_PRINTABLE = /^[\x21-\x7e]*$/;

    function asSet(v) {
        if (!v || typeof v === 'string' || typeof v[Symbol.iterator] !== 'function') return new Set();
        return new Set(v);
    }

    function refuse(reason, host) {
        return host ? { ok: false, reason, host } : { ok: false, reason };
    }

    function ipv4Parts(host) {
        const parts = host.split('.');
        if (parts.length !== 4) return null;
        const out = [];
        for (const p of parts) {
            if (!/^(0|[1-9][0-9]{0,2})$/.test(p)) return null;
            const n = parseInt(p, 10);
            if (n > 255) return null;
            out.push(n);
        }
        return out;
    }

    function ipv4Class(b) {
        const [a, c] = b;
        if (a === 127) return 'loopback';
        if (a === 169 && c === 254) return 'link-local';
        if (a === 0 || a === 10) return 'private';
        if (a === 172 && c >= 16 && c <= 31) return 'private';
        if (a === 192 && c === 168) return 'private';
        if (a === 100 && c >= 64 && c <= 127) return 'private';
        if (a >= 224) return 'private';
        return 'ip';
    }

    function ipv6Groups(text) {
        let s = text;
        let tail = [];
        const lastColon = s.lastIndexOf(':');
        if (s.indexOf('.') >= 0) {
            const v4 = ipv4Parts(s.slice(lastColon + 1));
            if (!v4) return null;
            tail = [(v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]];
            s = s.slice(0, lastColon + 1);
            if (!s.endsWith('::')) s = s.slice(0, -1);
        }
        const halves = s.split('::');
        if (halves.length > 2) return null;
        const parse = (h) => {
            if (h === '') return [];
            const out = [];
            for (const g of h.split(':')) {
                if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
                out.push(parseInt(g, 16));
            }
            return out;
        };
        const head = parse(halves[0]);
        if (!head) return null;
        if (halves.length === 1) {
            const all = head.concat(tail);
            return all.length === 8 ? all : null;
        }
        const back = parse(halves[1]);
        if (!back) return null;
        const have = head.length + back.length + tail.length;
        if (have > 7) return null;
        return head.concat(new Array(8 - have).fill(0), back, tail);
    }

    function ipv6Class(g) {
        if (g.every((x) => x === 0)) return 'private';
        if (g.slice(0, 7).every((x) => x === 0) && g[7] === 1) return 'loopback';
        const mapped = g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff;
        const compat = g.slice(0, 6).every((x) => x === 0);
        const nat64 = g[0] === 0x64 && g[1] === 0xff9b && g.slice(2, 6).every((x) => x === 0);
        if (mapped || compat || nat64) return ipv4Class([g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255]);
        if ((g[0] & 0xffc0) === 0xfe80) return 'link-local';
        if ((g[0] & 0xfe00) === 0xfc00) return 'private';
        if ((g[0] & 0xff00) === 0xff00) return 'private';
        if (g[0] === 0x2001 && g[1] === 0x0db8) return 'private';
        return 'ip';
    }

    function normalize(input) {
        if (typeof input !== 'string') return refuse('format');
        const s = input.replace(RX_TRIM, '');
        if (!s) return refuse('empty');
        if (s.length > MAX_URL) return refuse('format');
        if (!RX_PRINTABLE.test(s)) return refuse('format');
        let rest = s;
        const m = RX_SCHEME.exec(s);
        if (m) {
            const scheme = m[1].toLowerCase();
            if (scheme === 'ws') return refuse('insecure');
            if (scheme !== 'wss') return refuse('scheme');
            rest = s.slice(m[0].length);
        } else if (s.indexOf('://') >= 0) {
            return refuse('format');
        }
        if (/[?#]/.test(rest)) return refuse('format');
        const slash = rest.indexOf('/');
        const authority = slash >= 0 ? rest.slice(0, slash) : rest;
        const path = slash >= 0 ? rest.slice(slash) : '';
        if (!authority || authority.indexOf('@') >= 0) return refuse('format');
        let host = authority;
        let port = '';
        let v6 = false;
        if (authority.startsWith('[')) {
            const close = authority.indexOf(']');
            if (close < 0) return refuse('format');
            host = authority.slice(1, close);
            const after = authority.slice(close + 1);
            if (after) {
                if (!after.startsWith(':')) return refuse('format');
                port = after.slice(1);
            }
            v6 = true;
        } else {
            const colon = authority.lastIndexOf(':');
            if (colon >= 0) {
                host = authority.slice(0, colon);
                port = authority.slice(colon + 1);
            }
            if (host.indexOf(':') >= 0) return refuse('format');
        }
        if (port) {
            if (!/^[0-9]+$/.test(port)) return refuse('format');
            if (parseInt(port, 10) !== 443) return refuse('port');
        }
        host = host.toLowerCase();
        if (v6) {
            const groups = ipv6Groups(host);
            if (!groups) return refuse('format');
            return refuse(ipv6Class(groups), '[' + host + ']');
        }
        if (host.endsWith('.')) host = host.slice(0, -1);
        if (!host || host.length > 253) return refuse('format');
        const labels = host.split('.');
        if (!labels.every((l) => RX_LABEL.test(l))) return refuse('format');
        const last = labels[labels.length - 1];
        if (/^(0x[0-9a-f]*|[0-9]+)$/.test(last)) {
            const v4 = ipv4Parts(host);
            if (!v4) return refuse('format');
            return refuse(ipv4Class(v4), host);
        }
        if (host === 'localhost' || host.endsWith('.localhost')) return refuse('loopback', host);
        if (labels.length === 1 || LOCAL_SUFFIXES.some((x) => host.endsWith(x))) return refuse('local', host);
        if (host.endsWith('.onion') || host.endsWith('.i2p')) return refuse('onion');
        if (!RX_PATH.test(path)) return refuse('format');
        if (path.split('/').some((seg) => { const d = seg.replace(/%2e/gi, '.'); return d === '.' || d === '..'; })) return refuse('format');
        const url = 'wss://' + host + path.replace(/\/+$/, '');
        if (url.length > MAX_URL) return refuse('format');
        return { ok: true, url };
    }

    function canon(u) {
        const B = G.NymRelayBlock;
        return B && typeof B.canon === 'function' ? B.canon(u) : String(u || '').trim();
    }

    function canonSet(list) {
        const out = new Set();
        for (const u of Array.isArray(list) ? list : (list instanceof Set ? [...list] : [])) {
            if (typeof u === 'string' && u) out.add(canon(u));
        }
        return out;
    }

    function cap(defaults) {
        return Math.max(0, POOL_MAX_UPSTREAMS - canonSet(defaults).size);
    }

    function check(input, ctx) {
        const c = ctx || {};
        if (c.keypair) return { status: 'keypair' };
        const n = normalize(input);
        if (!n.ok) return n.host ? { status: n.reason, host: n.host } : { status: n.reason };
        const url = n.url;
        if (EXCLUDED.includes(url)) return { status: 'excluded', url };
        if (canonSet(c.blocked).has(url)) return { status: 'blocked', url };
        if (canonSet(c.defaults).has(url)) return { status: 'default', url };
        const shown = listed(c.added, c);
        if (shown.includes(url)) return { status: 'added', url };
        if (shown.length >= cap(c.defaults)) return { status: 'cap', url };
        return { status: 'ok', url };
    }

    function norm(raw, ctx) {
        const c = ctx || {};
        if (!Array.isArray(raw)) return [];
        const defaults = canonSet(c.defaults);
        const out = [];
        for (const item of raw) {
            if (out.length >= STORED_MAX) break;
            if (typeof item !== 'string') continue;
            const n = normalize(item);
            if (!n.ok) continue;
            if (EXCLUDED.includes(n.url) || defaults.has(n.url) || out.includes(n.url)) continue;
            out.push(n.url);
        }
        return out;
    }

    function listed(raw, ctx) {
        const blocked = canonSet((ctx || {}).blocked);
        return norm(raw, ctx).filter((u) => !blocked.has(u));
    }

    function inUse(raw, ctx) {
        return listed(raw, ctx).slice(0, cap((ctx || {}).defaults));
    }

    function add(list, url, ctx) {
        const current = norm(list, ctx);
        const r = check(url, Object.assign({}, ctx, { added: current }));
        if (r.status !== 'ok') return current;
        const blocked = canonSet((ctx || {}).blocked);
        const next = current.slice();
        while (next.length >= STORED_MAX) {
            const i = next.findIndex((u) => blocked.has(u));
            if (i < 0) return current;
            next.splice(i, 1);
        }
        return next.concat([r.url]);
    }

    function restore(list, urls, ctx) {
        const c = ctx || {};
        const stored = norm(list, c);
        const blocked = canonSet(c.blocked);
        const back = new Set();
        for (const u of Array.isArray(urls) ? urls : (urls instanceof Set ? [...urls] : [])) {
            if (typeof u !== 'string' || !u) continue;
            const n = normalize(u);
            back.add(n.ok ? n.url : canon(u));
        }
        const moved = stored.filter((u) => back.has(u) && !blocked.has(u));
        if (!moved.length) return stored;
        const rest = stored.filter((u) => !moved.includes(u));
        const others = rest.filter((u) => !blocked.has(u)).length;
        if (others + moved.length <= cap(c.defaults)) return stored;
        return rest.concat(moved);
    }

    function remove(list, url) {
        const n = normalize(url);
        const target = n.ok ? n.url : canon(url);
        return (Array.isArray(list) ? list : []).filter((u) => typeof u === 'string' && u !== target && canon(u) !== target);
    }

    function stripKeys(frame, keys) {
        const hidden = asSet(keys);
        if (!hidden.size || !Array.isArray(frame) || frame[0] !== 'REQ') return frame;
        let changed = false;
        const filters = [];
        for (const f of frame.slice(2)) {
            if (!f || typeof f !== 'object' || Array.isArray(f)) { filters.push(f); continue; }
            const out = Object.assign({}, f);
            let empty = false;
            for (const key of ['#p', 'authors']) {
                if (!Array.isArray(out[key])) continue;
                const kept = out[key].filter((pk) => !hidden.has(pk));
                if (kept.length === out[key].length) continue;
                changed = true;
                if (!kept.length) empty = true;
                out[key] = kept;
            }
            if (!empty) filters.push(out);
        }
        if (!changed) return frame;
        if (!filters.length) return null;
        return [frame[0], frame[1]].concat(filters);
    }

    function anonEvent(ev, keys, lane) {
        if (!ev || typeof ev !== 'object' || Array.isArray(ev)) return false;
        if (typeof ev.id === 'string' && asSet(lane).has(ev.id)) return true;
        const hidden = asSet(keys);
        if (!hidden.size) return false;
        if (typeof ev.pubkey === 'string' && hidden.has(ev.pubkey)) return true;
        return Array.isArray(ev.tags) && ev.tags.some((t) => Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string' && hidden.has(t[1]));
    }

    function status(s) {
        const o = s || {};
        const recent = (ms) => typeof ms === 'number' && ms < STATUS_WINDOW_MS;
        if (o.paused) return 'offline';
        if (o.overCap) return 'unused';
        if (o.connected) return 'connected';
        if (recent(o.addedAgoMs)) return 'connecting';
        if (o.proxy) {
            if (!o.shard || !o.shard.open) return 'connecting';
            return recent(o.shard.openedAgoMs) ? 'connecting' : 'offline';
        }
        return o.connecting ? 'connecting' : 'offline';
    }

    function message(code, vars) {
        const t = Object.prototype.hasOwnProperty.call(MESSAGES, code) ? MESSAGES[code] : '';
        return fill(t, vars);
    }

    function fill(template, vars) {
        const v = vars || {};
        return String(template || '').replace(/\{(\w+)\}/g, (all, k) => (Object.prototype.hasOwnProperty.call(v, k) ? String(v[k]) : all));
    }

    function shown(url) {
        return String(url || '').replace(/^wss?:\/\//i, '');
    }

    G.NymRelayAdd = Object.freeze({
        POOL_MAX_UPSTREAMS, STORED_MAX, STORAGE_KEY, SYNC_KEY, CHECK_TIMEOUT_MS, STATUS_WINDOW_MS, EXCLUDED, MESSAGES,
        normalize, check, norm, listed, inUse, cap, add, remove, restore, stripKeys, anonEvent, status, message, fill, shown,
    });
})();
