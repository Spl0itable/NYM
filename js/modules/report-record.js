(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const HEX64 = /^[0-9a-f]{64}$/;
    const COORD = /^30030:[0-9a-f]{64}:[^\u0000-\u001f\u007f]{0,1024}$/;
    const KEY = /^(?:[ep]:[0-9a-f]{64}|a:30030:[0-9a-f]{64}:[^\u0000-\u001f\u007f]{0,1024})$/;
    const BYTES = 16384;
    const STORE_KEY = 'nym_reported_targets';
    const SYNC_FIELD = 'reportedTargets';
    const REFUSALS = Object.freeze({
        e: 'You already reported this message.',
        p: 'You already reported this user.',
        a: 'You already reported this emoji pack.',
    });

    function str(v) {
        return typeof v === 'string' ? v : '';
    }

    function vals(tags, name) {
        const out = [];
        for (const t of (Array.isArray(tags) ? tags : [])) {
            if (Array.isArray(t) && t[0] === name && typeof t[1] === 'string') out.push(t);
        }
        return out;
    }

    function keyOfTags(tags) {
        const ps = vals(tags, 'p');
        const es = vals(tags, 'e');
        const packs = vals(tags, 'a').filter((t) => t[1].startsWith('30030:'));
        if (packs.length) {
            const c = packs[0][1];
            if (!COORD.test(c)) return '';
            if (ps.length && ps[0][1].toLowerCase() !== c.slice(6, 70)) return '';
            return 'a:' + c;
        }
        const e = es.length ? es[0][1].toLowerCase() : '';
        if (HEX64.test(e)) return 'e:' + e;
        const p = ps.length ? ps[0][1].toLowerCase() : '';
        return HEX64.test(p) ? 'p:' + p : '';
    }

    function tagsFor(target) {
        const x = target || {};
        const type = str(x.type) || 'other';
        const coord = str(x.coord);
        if (coord) return COORD.test(coord) ? [['p', coord.slice(6, 70), type], ['a', coord, type]] : [];
        const pk = str(x.pubkey);
        if (!pk) return [];
        const out = [['p', pk, type]];
        if (x.includeMessage && str(x.messageId)) out.push(['e', str(x.messageId), type]);
        return out;
    }

    function keyFor(target) {
        return keyOfTags(tagsFor(target));
    }

    function cap() {
        const M = G.NymSyncMerge;
        return M && M.CAPS ? M.CAPS.reportedTargets : 0;
    }

    function clean(map) {
        const src = map && typeof map === 'object' && !Array.isArray(map) ? map : {};
        const out = {};
        for (const k of Object.keys(src)) if (KEY.test(k)) out[k] = src[k];
        return out;
    }

    function utf8Len(s) {
        let n = 0;
        for (let i = 0; i < s.length; i++) {
            const c = s.charCodeAt(i);
            const d = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
            if (c < 0x80) n += 1;
            else if (c < 0x800) n += 2;
            else if (c >= 0xd800 && c <= 0xdbff && d >= 0xdc00 && d <= 0xdfff) { n += 4; i++; }
            else n += 3;
        }
        return n;
    }

    function entryBytes(k, v) {
        let esc = 0;
        for (let i = 0; i < k.length; i++) {
            const c = k.charCodeAt(i);
            if (c === 34 || c === 92) esc++;
        }
        return utf8Len(k) + esc + String(v).length + 4;
    }

    function fit(map) {
        const rows = Object.keys(map).map((k) => [k, map[k]]);
        rows.sort((x, y) => (y[1] - x[1]) || (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
        const out = {};
        let used = 2;
        for (const [k, v] of rows) {
            used += entryBytes(k, v);
            if (used > BYTES) break;
            out[k] = v;
        }
        return out;
    }

    function merge(a, b) {
        const M = G.NymSyncMerge;
        if (!M || typeof M.tsMapMerge !== 'function') return {};
        return fit(M.tsMapMerge(clean(a), clean(b), cap()));
    }

    function add(map, key, at) {
        return KEY.test(str(key)) ? merge(map, { [key]: at }) : merge(map, {});
    }

    function refusal(key) {
        return REFUSALS[str(key).charAt(0)] || REFUSALS.p;
    }

    G.NymReportRecord = Object.freeze({ BYTES, STORE_KEY, SYNC_FIELD, REFUSALS, keyOfTags, tagsFor, keyFor, cap, clean, merge, add, refusal });
})();
