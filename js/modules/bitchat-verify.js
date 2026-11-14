(function () {
    const G = (typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis));

    const CHANNEL_KINDS = Object.freeze([20000, 23333]);
    const LABEL = 'bitchat verification link';
    const WS = '\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff';
    const RX_TRIM = new RegExp('^[' + WS + ']+|[' + WS + ']+$', 'g');
    const RX_TOKEN = new RegExp('[^' + WS + ']+', 'g');
    const RX_PREFIX = /^bitchat:(?:\/\/verify\/?|\/\/\/verify|verify)\?/i;
    const RX_QUERY_BAD = new RegExp('[' + WS + '#]');
    const RX_LEAD = /^[(\["'<*_~|]+/;
    const RX_TRAIL = /[.,;:!?)\]"'*_~|>\u2026\u3002]+$/;
    const RX_RUN_START = /^bitchat:/i;
    const MAX_LENGTH = 2048;
    const REQUIRED = Object.freeze(['v', 'noise', 'sign', 'nick', 'ts', 'nonce', 'sig']);
    const FIELDS = Object.freeze({
        v: /^[1-9][0-9]?$/,
        noise: /^[0-9A-Fa-f]{64}$/,
        sign: /^[0-9A-Fa-f]{64}$/,
        nick: /^(?:[^\u0000-\u001f\u007f&#%<>"`]|%[0-9A-Fa-f]{2}){0,1024}$/,
        ts: /^[0-9]{1,19}$/,
        nonce: /^[A-Za-z0-9_-]{22}$/,
        sig: /^[0-9A-Fa-f]{128}$/,
        npub: /^npub1[02-9ac-hj-np-z]{58}$/,
    });

    function isLink(s) {
        if (!s || s.length > MAX_LENGTH) return false;
        const m = RX_PREFIX.exec(s);
        if (!m) return false;
        const query = s.slice(m[0].length);
        if (!query || RX_QUERY_BAD.test(query)) return false;
        const seen = new Set();
        for (const part of query.split('&')) {
            const eq = part.indexOf('=');
            if (eq < 0) return false;
            const name = part.slice(0, eq);
            if (!Object.prototype.hasOwnProperty.call(FIELDS, name) || seen.has(name)) return false;
            if (!FIELDS[name].test(part.slice(eq + 1))) return false;
            seen.add(name);
        }
        return REQUIRED.every((name) => seen.has(name));
    }

    function isBitchatVerifyContent(content) {
        if (typeof content !== 'string') return false;
        return isLink(content.replace(RX_TRIM, ''));
    }

    function isBitchatVerifyChannelEvent(ev) {
        return !!ev && typeof ev === 'object' && CHANNEL_KINDS.includes(ev.kind) && isBitchatVerifyContent(ev.content);
    }

    function findBitchatVerifyLinks(text) {
        const out = [];
        if (typeof text !== 'string' || text.toLowerCase().indexOf('bitchat:') === -1) return out;
        for (const m of text.matchAll(RX_TOKEN)) {
            const lead = m[0].length - m[0].replace(RX_LEAD, '').length;
            const run = m[0].slice(lead);
            if (!RX_RUN_START.test(run)) continue;
            const tail = RX_TRAIL.exec(run);
            const last = Math.min(run.length, MAX_LENGTH);
            for (let end = tail ? tail.index : run.length; end <= last; end++) {
                if (isLink(run.slice(0, end))) {
                    out.push({ start: m.index + lead, end: m.index + lead + end });
                    break;
                }
            }
        }
        return out;
    }

    function labelBitchatVerifyLinks(text, label) {
        const spans = findBitchatVerifyLinks(text);
        if (!spans.length) return text;
        let out = '';
        let last = 0;
        for (const s of spans) {
            out += text.slice(last, s.start) + label;
            last = s.end;
        }
        return out + text.slice(last);
    }

    const api = Object.freeze({ CHANNEL_KINDS, LABEL, isBitchatVerifyContent, isBitchatVerifyChannelEvent, findBitchatVerifyLinks, labelBitchatVerifyLinks });
    G.NymBitchatVerify = api;
    if (typeof module !== 'undefined' && module && typeof module === 'object') module.exports = api;
})();
