(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const OVERLAP_MS = 120000;
    const MAX_PAGES = 5;
    const PAGE_LIMIT = 200;
    const INBOX_CHUNK = 200;
    const HOLD_MS = 86400000;
    const COALESCE_MS = 10000;
    const CURSOR_RE = /^\d{1,16}(:[0-9a-f]{64})?$/;
    const HEAD_RE = /^\d{1,16}$/;

    function parse(c) {
        if (typeof c !== 'string' || !CURSOR_RE.test(c)) return null;
        const at = c.indexOf(':');
        const s = Number(at < 0 ? c : c.slice(0, at));
        if (!Number.isSafeInteger(s)) return null;
        return { s, id: at < 0 ? '' : c.slice(at + 1) };
    }

    function valid(c) {
        return parse(c) !== null;
    }

    function format(s, id) {
        if (!Number.isSafeInteger(s) || s < 0) return null;
        return id ? s + ':' + id : String(s);
    }

    function compare(a, b) {
        const pa = parse(a);
        const pb = parse(b);
        if (!pa || !pb) return pa ? 1 : (pb ? -1 : 0);
        if (pa.s !== pb.s) return pa.s < pb.s ? -1 : 1;
        if (pa.id === pb.id) return 0;
        return pa.id < pb.id ? -1 : 1;
    }

    function newer(a, b) {
        const va = valid(a);
        const vb = valid(b);
        if (!va && !vb) return null;
        if (!va) return b;
        if (!vb) return a;
        return compare(a, b) >= 0 ? a : b;
    }

    function older(a, b) {
        const va = valid(a);
        const vb = valid(b);
        if (!va && !vb) return null;
        if (!va) return b;
        if (!vb) return a;
        return compare(a, b) <= 0 ? a : b;
    }

    function startAfter(c) {
        const p = parse(c);
        if (!p) return null;
        return String(Math.max(0, p.s - OVERLAP_MS));
    }

    function fromHead(h) {
        if (typeof h !== 'string' || !HEAD_RE.test(h)) return null;
        return Number.isSafeInteger(Number(h)) ? h : null;
    }

    function step(page, after, xCursor, xHasMore) {
        if (!valid(xCursor)) return { serverOk: false, cursor: null, next: null };
        const more = xHasMore === '1' && page + 1 < MAX_PAGES && xCursor !== after;
        return { serverOk: true, cursor: xCursor, next: more ? xCursor : null };
    }

    function uniqueKeys(keys) {
        const out = [];
        const seen = new Set();
        for (const k of Array.isArray(keys) ? keys : []) {
            if (typeof k !== 'string' || !k || seen.has(k)) continue;
            seen.add(k);
            out.push(k);
        }
        return out;
    }

    function inboxPlan(keys, cursors) {
        const map = cursors && typeof cursors === 'object' ? cursors : {};
        const list = uniqueKeys(keys);
        const without = [];
        const withCur = [];
        for (const k of list) {
            const p = parse(map[k]);
            if (p) withCur.push({ k, s: p.s });
            else without.push(k);
        }
        withCur.sort((x, y) => (x.s - y.s) || (x.k < y.k ? -1 : x.k > y.k ? 1 : 0));
        const legacy = [];
        for (let i = 0; i < without.length; i += INBOX_CHUNK) legacy.push(without.slice(i, i + INBOX_CHUNK));
        const cursor = [];
        for (let i = 0; i < withCur.length; i += INBOX_CHUNK) {
            const chunk = withCur.slice(i, i + INBOX_CHUNK);
            cursor.push({ keys: chunk.map((e) => e.k), after: String(Math.max(0, chunk[0].s - OVERLAP_MS)) });
        }
        return { legacy, cursor };
    }

    function inboxStore(cursors, chunkKeys, result, liveKeys) {
        const out = {};
        const live = Array.isArray(liveKeys) ? new Set(liveKeys) : null;
        const src = cursors && typeof cursors === 'object' ? cursors : {};
        for (const k of Object.keys(src)) {
            if (live && !live.has(k)) continue;
            if (valid(src[k])) out[k] = src[k];
        }
        if (valid(result)) {
            for (const k of uniqueKeys(chunkKeys)) {
                if (live && !live.has(k)) continue;
                out[k] = newer(out[k], result);
            }
        }
        return out;
    }

    function persistable(candidate, holds, now) {
        const active = (Array.isArray(holds) ? holds : []).filter((h) => h && Number.isFinite(h.since) && now - h.since < HOLD_MS);
        if (!active.length) return valid(candidate) ? candidate : null;
        let out = valid(candidate) ? candidate : null;
        for (const h of active) {
            if (!valid(h.after)) return null;
            out = out === null ? h.after : older(out, h.after);
        }
        return out;
    }

    function coalesce(lastEndedAt, now) {
        return Number.isFinite(lastEndedAt) && lastEndedAt > 0 && now - lastEndedAt < COALESCE_MS;
    }

    G.NymD1Cursor = Object.freeze({
        OVERLAP_MS, MAX_PAGES, PAGE_LIMIT, INBOX_CHUNK, HOLD_MS, COALESCE_MS,
        parse, valid, format, compare, newer, older, startAfter, fromHead, step,
        inboxPlan, inboxStore, persistable, coalesce,
    });
})();
