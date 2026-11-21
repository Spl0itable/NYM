(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const CONFIG = Object.freeze({
        keep: 50,
        show: 10,
        suggest: 3,
        minChars: 2,
        maxChars: 200,
        version: 1,
    });

    const STRINGS = Object.freeze({
        recent: 'Recent',
        recentRow: '{q}, recent search',
        remove: 'Remove {q} from recent searches',
        removeShort: 'Remove',
        clearAll: 'Clear recent searches',
        removed: 'Removed from recent searches',
        cleared: 'Recent searches cleared',
        settingLabel: 'Remember searches',
        settingHint: 'Keep a list of your recent searches on this device so they can be suggested again. The list stays on this device, is separate for each identity, and is never sent anywhere. Turning this off clears it.',
    });

    const KEYS = Object.freeze({
        state: 'nym_search_history:',
        setting: 'nym_remember_searches',
        off: 'off',
    });

    function fold(s) {
        const U = G.NymUnifiedSearch;
        return U && typeof U.fold === 'function' ? U.fold(s) : String(s == null ? '' : s).toLowerCase();
    }

    function collapse(raw) {
        return String(raw == null ? '' : raw).replace(/\s+/g, ' ').trim();
    }

    function normalize(raw) {
        const q = collapse(raw);
        const n = Array.from(q).length;
        if (n < CONFIG.minChars || n > CONFIG.maxChars) return null;
        return { q, key: fold(q) };
    }

    function stamp(at) {
        const n = Number(at);
        if (!isFinite(n) || n <= 0) return 0;
        return Math.floor(n);
    }

    function list(items) {
        return Array.isArray(items) ? items : [];
    }

    function add(items, raw, now) {
        const n = normalize(raw);
        if (!n) return items;
        const out = [{ q: n.q, at: stamp(now) }];
        for (const e of list(items)) {
            if (!e || fold(e.q) === n.key) continue;
            out.push({ q: e.q, at: e.at });
            if (out.length >= CONFIG.keep) break;
        }
        return out;
    }

    function remove(items, raw) {
        const n = normalize(raw);
        if (!n) return items;
        const src = list(items);
        const out = src.filter((e) => e && fold(e.q) !== n.key);
        return out.length === src.length ? items : out;
    }

    function clear() {
        return [];
    }

    function recent(items) {
        return list(items).slice(0, CONFIG.show);
    }

    function suggest(items, typedRaw) {
        const t = fold(collapse(typedRaw));
        if (!t) return [];
        const first = [];
        const rest = [];
        for (const e of list(items)) {
            if (!e) continue;
            const k = fold(e.q);
            if (k === t) continue;
            if (k.startsWith(t)) first.push(e);
            else if (k.includes(t)) rest.push(e);
        }
        return first.concat(rest).slice(0, CONFIG.suggest);
    }

    function decode(json) {
        let rec = null;
        try { rec = typeof json === 'string' ? JSON.parse(json) : null; } catch (_) { return []; }
        if (!rec || typeof rec !== 'object' || Array.isArray(rec) || rec.v !== CONFIG.version || !Array.isArray(rec.items)) return [];
        const out = [];
        const seen = new Set();
        for (const it of rec.items) {
            if (!it || typeof it !== 'object' || typeof it.q !== 'string') continue;
            const n = normalize(it.q);
            if (!n || seen.has(n.key)) continue;
            seen.add(n.key);
            out.push({ q: n.q, at: stamp(it.at) });
            if (out.length >= CONFIG.keep) break;
        }
        return out;
    }

    function encode(items) {
        return JSON.stringify({ v: CONFIG.version, items: list(items).filter(Boolean).map((e) => ({ q: e.q, at: e.at })) });
    }

    G.NymSearchHistory = { CONFIG, STRINGS, KEYS, normalize, add, remove, clear, recent, suggest, decode, encode };
})();
