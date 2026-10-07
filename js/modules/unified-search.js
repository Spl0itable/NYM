(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const CONFIG = Object.freeze({
        debounceMs: 150,
        minMessageChars: 2,
        pages: Object.freeze({ channels: 5, nyms: 5, messages: 20 }),
        steps: Object.freeze({ channels: 10, nyms: 10, messages: 50 }),
        snippetBefore: 40,
        snippetMax: 160,
    });

    const STRINGS = Object.freeze({
        title: 'Search',
        placeholder: 'Search messages, channels and nyms',
        empty: 'Search messages, channels and nyms',
        emptyHint: 'Only this device is searched. Nothing you type leaves it.',
        noResults: 'No results for "{q}"',
        channels: 'Channels and groups',
        nyms: 'Nyms',
        messages: 'Messages',
        showMore: 'Show more',
        joinChannel: 'Join #{name}',
        joinGeohash: 'Join geohash #{name}',
        group: 'Group',
        joined: 'Joined',
        notJoined: 'Not joined',
        friend: 'Friend',
        scopeAll: 'Everywhere',
        scopeChat: 'In {chat}',
        shortMessages: 'Type at least 2 characters to search messages',
        close: 'Close search',
        dm: 'PM with {name}',
        resultCount: '{n} results',
    });

    const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
    const FOLD_GROUPS = [
        ['àáâãäåāăą', 'a'], ['çćĉċč', 'c'], ['ďđð', 'd'], ['èéêëēĕėęě', 'e'], ['ĝğġģ', 'g'], ['ĥħ', 'h'],
        ['ìíîïĩīĭįı', 'i'], ['ĵ', 'j'], ['ķ', 'k'], ['ĺļľŀł', 'l'], ['ñńņňŉ', 'n'], ['òóôõöøōŏő', 'o'],
        ['ŕŗř', 'r'], ['śŝşšș', 's'], ['ţťŧț', 't'], ['ùúûüũūŭůűų', 'u'], ['ŵ', 'w'], ['ýÿŷ', 'y'],
        ['źżž', 'z'], ['ß', 'ss'], ['æ', 'ae'], ['œ', 'oe'], ['þ', 'th'],
    ];
    const FOLD = new Map();
    for (const [chars, to] of FOLD_GROUPS) for (const ch of chars) FOLD.set(ch, to);
    FOLD.set('ς', 'σ');
    FOLD.set('\u0307', '');

    const ASCII = /^[\x00-\x7f]*$/;
    const NAME_CHARS = /^[\p{L}\p{N}]+$/u;
    const WORD_CHAR = /[\p{L}\p{N}]/u;
    const HEX_KEY = /^[0-9a-f]{8,64}$/;
    const HEX_SUFFIX = /^[0-9a-f]{4}$/;

    function cmp(a, b) { return a < b ? -1 : (a > b ? 1 : 0); }

    function foldMap(s) {
        const src = typeof s === 'string' ? s : '';
        if (ASCII.test(src)) return { text: src.toLowerCase(), from: null, to: null };
        let text = '';
        const from = [];
        const to = [];
        let i = 0;
        while (i < src.length) {
            const cp = src.codePointAt(i);
            const w = cp > 0xffff ? 2 : 1;
            const ch = src.slice(i, i + w);
            const lc = ch.toLowerCase();
            let out = '';
            for (const c of lc) {
                const f = FOLD.get(c);
                out += f === undefined ? c : f;
            }
            for (let k = 0; k < out.length; k++) { from.push(i); to.push(i + w); }
            text += out;
            i += w;
        }
        return { text, from, to };
    }

    const NON_ASCII = /[^\x00-\x7f]/g;

    function fold(s) {
        const lower = (typeof s === 'string' ? s : '').toLowerCase();
        if (ASCII.test(lower)) return lower;
        return lower.replace(NON_ASCII, (c) => {
            const f = FOLD.get(c);
            return f === undefined ? c : f;
        });
    }

    function parseQuery(raw) {
        const text = fold(String(raw == null ? '' : raw)).replace(/\s+/g, ' ').trim();
        let mode = 'all';
        let bare = text;
        if (bare.startsWith('#')) { mode = 'channel'; bare = bare.replace(/^#+/, ''); }
        else if (bare.startsWith('@')) { mode = 'nym'; bare = bare.replace(/^@+/, ''); }
        bare = bare.trim();
        return {
            text,
            bare,
            mode,
            tokens: text ? text.split(' ').filter(Boolean) : [],
            nameTokens: bare ? bare.split(' ').filter(Boolean) : [],
        };
    }

    function isGeohash(s) {
        if (!s || s.length > 12) return false;
        for (const ch of s) if (BASE32.indexOf(ch) < 0) return false;
        return true;
    }

    function nameScore(name, bare, tokens) {
        if (!bare) return 0;
        const n = fold(name);
        if (!n) return 0;
        if (n === bare) return 100;
        if (n.startsWith(bare)) return 80;
        let at = n.indexOf(bare, 1);
        let inside = at >= 0;
        while (at > 0) {
            if (!WORD_CHAR.test(n[at - 1])) return 60;
            at = n.indexOf(bare, at + 1);
        }
        if (inside) return 40;
        const parts = tokens && tokens.length ? tokens : [bare];
        if (parts.length > 1 && parts.every((t) => n.includes(t))) return 20;
        return 0;
    }

    function rankChannels(q, items) {
        if (!q.bare || q.mode === 'nym') return [];
        const out = [];
        for (const it of items || []) {
            if (!it || !it.key) continue;
            const s = nameScore(it.name || it.key, q.bare, q.nameTokens);
            if (s > 0) out.push({ it, s });
        }
        out.sort((a, b) => (b.s - a.s)
            || ((b.it.joined ? 1 : 0) - (a.it.joined ? 1 : 0))
            || ((b.it.at || 0) - (a.it.at || 0))
            || cmp(fold(a.it.name || a.it.key), fold(b.it.name || b.it.key))
            || cmp(a.it.key, b.it.key)
            || cmp(String(a.it.kind || ''), String(b.it.kind || '')));
        return out.map((x) => x.it);
    }

    function joinSuggestion(q, items) {
        if (q.mode === 'nym' || q.nameTokens.length !== 1) return null;
        const name = q.bare;
        if (name.length < 2 || !NAME_CHARS.test(name) || name.startsWith('npub1') || HEX_KEY.test(name)) return null;
        for (const it of items || []) {
            if (it && it.kind !== 'group' && String(it.key).toLowerCase() === name) return null;
        }
        return { key: name, geohash: isGeohash(name) };
    }

    function nymScore(q, it) {
        const bare = q.bare;
        if (!bare) return 0;
        const pk = String(it.pubkey || '').toLowerCase();
        const suffix = pk.slice(-4);
        if (bare.startsWith('npub1')) return String(it.npub || '').toLowerCase().startsWith(bare) ? 90 : 0;
        let best = 0;
        if (HEX_KEY.test(bare) && pk.startsWith(bare)) best = 90;
        const hash = bare.lastIndexOf('#');
        if (hash >= 0) {
            const np = bare.slice(0, hash).trim();
            const sp = bare.slice(hash + 1).trim();
            if (sp && !suffix.startsWith(sp)) return best;
            if (!np) return Math.max(best, sp ? 60 : 0);
            const s = nameScore(it.nym || '', np, [np]);
            if (s === 0) return best;
            return Math.max(best, s === 100 && sp.length === 4 ? 100 : s);
        }
        let s = nameScore(it.nym || '', bare, q.nameTokens);
        if (HEX_SUFFIX.test(bare) && suffix === bare) s = Math.max(s, 70);
        return Math.max(best, s);
    }

    function rankNyms(q, items) {
        if (!q.bare || q.mode === 'channel') return [];
        const out = [];
        for (const it of items || []) {
            if (!it || !it.pubkey) continue;
            const s = nymScore(q, it);
            if (s > 0) out.push({ it, s });
        }
        out.sort((a, b) => (b.s - a.s)
            || ((b.it.friend ? 1 : 0) - (a.it.friend ? 1 : 0))
            || ((b.it.at || 0) - (a.it.at || 0))
            || cmp(fold(a.it.nym || ''), fold(b.it.nym || ''))
            || cmp(a.it.pubkey, b.it.pubkey));
        return out.map((x) => x.it);
    }

    function messageOrder(a, b) {
        return ((b.at || 0) - (a.at || 0)) || cmp(String(a.id), String(b.id)) || cmp(String(a.key), String(b.key));
    }

    function matchMessages(q, items, opts) {
        const o = opts || {};
        const limit = Math.max(0, o.limit == null ? CONFIG.pages.messages : o.limit);
        if (q.text.length < CONFIG.minMessageChars || !q.tokens.length) return { items: [], total: 0 };
        const lower = typeof o.lower === 'function' ? o.lower : (it) => fold(it.text);
        const visible = typeof o.visible === 'function' ? o.visible : null;
        const scope = o.scope || '';
        const tokens = q.tokens;
        const keep = [];
        const cap = Math.max(64, limit * 2);
        let total = 0;
        const each = (it) => {
            if (!it || (scope && it.key !== scope)) return;
            const t = lower(it);
            if (!t) return;
            for (let i = 0; i < tokens.length; i++) if (t.indexOf(tokens[i]) < 0) return;
            if (visible && !visible(it)) return;
            total++;
            if (limit === 0) return;
            keep.push(it);
            if (keep.length > cap + limit) {
                keep.sort(messageOrder);
                keep.length = limit;
            }
        };
        if (typeof items === 'function') items(each);
        else for (const it of items || []) each(it);
        keep.sort(messageOrder);
        if (keep.length > limit) keep.length = limit;
        return { items: keep, total };
    }

    function highlight(text, tokens) {
        const src = typeof text === 'string' ? text : '';
        if (!src || !tokens || !tokens.length) return [];
        const m = foldMap(src);
        const ranges = [];
        for (const tok of tokens) {
            if (!tok) continue;
            let at = m.text.indexOf(tok);
            while (at >= 0) {
                const end = at + tok.length;
                ranges.push(m.from ? [m.from[at], m.to[end - 1]] : [at, end]);
                at = m.text.indexOf(tok, end);
            }
        }
        ranges.sort((a, b) => (a[0] - b[0]) || (a[1] - b[1]));
        const out = [];
        for (const r of ranges) {
            const last = out[out.length - 1];
            if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
            else out.push([r[0], r[1]]);
        }
        return out;
    }

    function isHigh(c) { return c >= 0xd800 && c <= 0xdbff; }
    function isLow(c) { return c >= 0xdc00 && c <= 0xdfff; }

    function snippet(text, tokens, opts) {
        const o = opts || {};
        const before = o.before == null ? CONFIG.snippetBefore : o.before;
        const max = o.max == null ? CONFIG.snippetMax : o.max;
        const flat = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
        const ranges = highlight(flat, tokens);
        if (flat.length <= max) return { text: flat, ranges };
        const first = ranges.length ? ranges[0][0] : 0;
        let start = Math.max(0, first - before);
        if (start + max > flat.length) start = Math.max(0, flat.length - max);
        if (start > 0 && isLow(flat.charCodeAt(start))) start--;
        let end = Math.min(flat.length, start + max);
        if (end < flat.length && isHigh(flat.charCodeAt(end - 1))) end--;
        const pre = start > 0 ? '…' : '';
        const post = end < flat.length ? '…' : '';
        const shift = pre.length - start;
        const out = [];
        for (const r of ranges) {
            const s = Math.max(r[0], start);
            const e = Math.min(r[1], end);
            if (e > s) out.push([s + shift, e + shift]);
        }
        return { text: pre + flat.slice(start, end) + post, ranges: out };
    }

    function search(raw, corpus, opts) {
        const o = opts || {};
        const c = corpus || {};
        const limits = Object.assign({}, CONFIG.pages, o.limits || {});
        const q = parseQuery(raw);
        const scope = o.scope || '';
        const channels = scope ? [] : rankChannels(q, c.channels);
        const nyms = scope ? [] : rankNyms(q, c.nyms);
        const join = scope ? null : joinSuggestion(q, c.channels);
        const messages = matchMessages(q, c.messages, { limit: limits.messages, scope, lower: o.lower, visible: o.visible });
        return {
            query: q,
            channels: { items: channels.slice(0, limits.channels), total: channels.length },
            join,
            nyms: { items: nyms.slice(0, limits.nyms), total: nyms.length },
            messages,
        };
    }

    G.NymUnifiedSearch = {
        CONFIG, STRINGS,
        fold, foldMap, parseQuery, isGeohash, nameScore, rankChannels, joinSuggestion, nymScore, rankNyms,
        matchMessages, highlight, snippet, search,
    };
})();
