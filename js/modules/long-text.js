(function (root) {
    'use strict';

    const BODY_MAX = 15000;
    const LONG_MAX = 4000000;
    const PARTS_MAX = 1000;
    const WAIT_MS = 90000;
    const BYTES_PER_TOKEN = 4;
    const KEEP_DONE = 500;

    function isHigh(c) { return c >= 0xD800 && c <= 0xDBFF; }
    function isLow(c) { return c >= 0xDC00 && c <= 0xDFFF; }

    function unitAt(s, i) {
        const c = s.charCodeAt(i);
        if (c === 0x22 || c === 0x5C) return [2, 1];
        if (c === 0x08 || c === 0x09 || c === 0x0A || c === 0x0C || c === 0x0D) return [2, 1];
        if (c < 0x20) return [6, 1];
        if (c < 0x80) return [1, 1];
        if (c < 0x800) return [2, 1];
        if (isHigh(c) && i + 1 < s.length && isLow(s.charCodeAt(i + 1))) return [4, 2];
        if (isHigh(c) || isLow(c)) return [6, 1];
        return [3, 1];
    }

    function bodyCost(text) {
        const s = String(text == null ? '' : text);
        let cost = 0;
        for (let i = 0; i < s.length;) {
            const u = unitAt(s, i);
            cost += u[0];
            i += u[1];
        }
        return cost;
    }

    function split(text, budget) {
        const whole = String(text == null ? '' : text);
        const max = Number(budget) > 0 ? Math.floor(Number(budget)) : BODY_MAX;
        const parts = [];
        let at = 0;
        while (at < whole.length) {
            let cost = 0;
            let end = at;
            while (end < whole.length) {
                const u = unitAt(whole, end);
                if (cost + u[0] > max) break;
                cost += u[0];
                end += u[1];
            }
            if (end >= whole.length) {
                parts.push(whole.slice(at));
                break;
            }
            if (end === at) end = at + unitAt(whole, at)[1];
            const len = end - at;
            const nl = whole.lastIndexOf('\n', end - 1);
            if (nl >= at && nl - at > len * 0.5) end = nl + 1;
            parts.push(whole.slice(at, end));
            at = end;
        }
        return parts.length ? parts : [''];
    }

    function head(text, max) {
        const s = String(text == null ? '' : text);
        const n = Math.max(0, Math.floor(Number(max) || 0));
        if (s.length <= n) return s;
        let end = n;
        if (end > 0 && isHigh(s.charCodeAt(end - 1)) && isLow(s.charCodeAt(end))) end -= 1;
        return s.slice(0, end);
    }

    function check(text) {
        const cost = bodyCost(text);
        if (cost > LONG_MAX) return { ok: false, reason: 'long', cost, max: LONG_MAX, parts: 0 };
        const parts = cost <= BODY_MAX ? 1 : split(text).length;
        if (parts > PARTS_MAX) return { ok: false, reason: 'parts', cost, max: LONG_MAX, parts };
        return { ok: true, reason: '', cost, max: LONG_MAX, parts };
    }

    function tokensFor(cost) {
        return Math.ceil(Math.max(0, Number(cost) || 0) / BYTES_PER_TOKEN);
    }

    function contextCheck(cost, context, maxOut) {
        const tokens = tokensFor(cost);
        const ctx = Math.floor(Number(context) || 0);
        if (!(ctx > 0)) return { ok: true, tokens, limit: 0, context: 0 };
        const out = Math.max(0, Math.floor(Number(maxOut) || 0));
        const limit = out > 0 && out < ctx ? ctx - out : Math.floor(ctx * 3 / 4);
        return { ok: tokens <= limit, tokens, limit, context: ctx };
    }

    function chunksFor(text, limitTokens) {
        const budget = Math.max(BODY_MAX, Math.floor(Math.max(0, Number(limitTokens) || 0) * BYTES_PER_TOKEN * 0.8));
        return split(text, budget);
    }

    function partOf(tags) {
        const list = Array.isArray(tags) ? tags : [];
        let x = null;
        let part = null;
        for (const t of list) {
            if (!Array.isArray(t)) continue;
            if (t[0] === 'x' && typeof t[1] === 'string' && x === null) x = t[1];
            if (t[0] === 'part' && part === null) {
                const index = parseInt(t[1], 10);
                const total = parseInt(t[2], 10);
                part = { index, total };
            }
        }
        if (!part) return null;
        return { x, index: part.index, total: part.total };
    }

    function assembler(options) {
        const waitMs = options && Number(options.waitMs) > 0 ? Number(options.waitMs) : WAIT_MS;
        const open = new Map();
        const done = new Map();

        function remember(key) {
            done.set(key, true);
            while (done.size > KEEP_DONE) done.delete(done.keys().next().value);
        }

        function missingOf(entry) {
            const out = [];
            for (let i = 1; i <= entry.total; i++) if (!entry.parts.has(i)) out.push(i);
            return out;
        }

        return {
            add(key, index, total, text, now) {
                const k = String(key || '');
                const at = now == null ? Date.now() : Number(now);
                const n = Number(index);
                const of = Number(total);
                if (!k || !Number.isInteger(n) || !Number.isInteger(of) || of < 1 || of > PARTS_MAX || n < 1 || n > of) {
                    return { state: 'bad' };
                }
                if (done.has(k)) return { state: 'dup' };
                let entry = open.get(k);
                if (!entry) {
                    entry = { total: of, parts: new Map(), cost: 0, first: at };
                    open.set(k, entry);
                }
                if (entry.total !== of) return { state: 'bad' };
                if (entry.parts.has(n)) return { state: 'dup' };
                const body = String(text == null ? '' : text);
                entry.cost += bodyCost(body);
                if (entry.cost > LONG_MAX) {
                    open.delete(k);
                    remember(k);
                    return { state: 'bad' };
                }
                entry.parts.set(n, body);
                if (entry.parts.size < entry.total) return { state: 'wait', have: entry.parts.size, total: entry.total };
                const pieces = [];
                for (let i = 1; i <= entry.total; i++) pieces.push(entry.parts.get(i));
                open.delete(k);
                remember(k);
                return { state: 'done', text: pieces.join(''), total: entry.total };
            },
            missing(key) {
                const entry = open.get(String(key || ''));
                return entry ? missingOf(entry) : [];
            },
            expired(now) {
                const at = now == null ? Date.now() : Number(now);
                const out = [];
                for (const [k, entry] of open) {
                    if (at - entry.first >= waitMs) out.push({ key: k, missing: missingOf(entry), have: entry.parts.size, total: entry.total });
                }
                return out;
            },
            drop(key) {
                open.delete(String(key || ''));
            },
            pending() {
                return open.size;
            }
        };
    }

    root.NymLongText = {
        BODY_MAX, LONG_MAX, PARTS_MAX, WAIT_MS, BYTES_PER_TOKEN,
        bodyCost, split, head, check, tokensFor, contextCheck, chunksFor, partOf, assembler
    };
})(typeof window !== 'undefined' ? window : globalThis);
