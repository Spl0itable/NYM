(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const LIMITS = Object.freeze({
        questionMax: 280,
        optionMax: 100,
        optionsMin: 2,
        optionsMax: 6,
        historyMax: 8,
        pollsMax: 300,
        futureSkewSec: 300,
    });

    const TYPES = Object.freeze({
        vote: 'nym-poll-vote',
        close: 'nym-poll-close',
    });

    const PREFIX = 'nympoll:';

    const STRINGS = Object.freeze({
        header: 'Poll',
        previewPrefix: 'Poll: ',
        voteContent: 'Poll vote: {option}',
        closeContent: 'Poll closed: {question}',
        oneVote: '1 vote',
        manyVotes: '{n} votes',
        closed: 'Closed',
        closePoll: 'Close poll',
        closedNotice: 'This poll is closed.',
        botRefused: "Polls aren't available in the Nymbot chat.",
        sendFailed: "Couldn't send the poll. Try again.",
    });

    const RX_ID = /^[0-9a-f]{64}$/;
    const RX_LINE = /(?:^|\n)nympoll:([A-Za-z0-9_.~%=;-]+)[ \t]*$/;

    function utf8Bytes(s) {
        return Array.from(new TextEncoder().encode(String(s)));
    }

    function pctEncode(s) {
        let out = '';
        for (const b of utf8Bytes(s)) {
            const ch = String.fromCharCode(b);
            if (b < 0x80 && /[A-Za-z0-9_.~-]/.test(ch)) out += ch;
            else out += '%' + (b < 16 ? '0' : '') + b.toString(16).toUpperCase();
        }
        return out;
    }

    function pctDecode(s) {
        const str = String(s || '');
        if (!/^(?:[A-Za-z0-9_.~-]|%[0-9A-Fa-f]{2})*$/.test(str)) throw new Error('pct');
        const bytes = [];
        for (let i = 0; i < str.length;) {
            if (str[i] === '%') { bytes.push(parseInt(str.slice(i + 1, i + 3), 16)); i += 3; }
            else { bytes.push(str.charCodeAt(i)); i++; }
        }
        return new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(bytes));
    }

    function cleanText(s, max) {
        const flat = String(s == null ? '' : s).replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim();
        return Array.from(flat).slice(0, max).join('').trim();
    }

    function cleanPoll(question, options) {
        const q = cleanText(question, LIMITS.questionMax);
        const opts = (Array.isArray(options) ? options : []).map((o) => cleanText(o, LIMITS.optionMax)).filter(Boolean);
        if (!q || opts.length < LIMITS.optionsMin || opts.length > LIMITS.optionsMax) return null;
        return { question: q, options: opts };
    }

    function fill(tpl, vars) {
        let s = tpl;
        for (const k of Object.keys(vars || {})) s = s.split('{' + k + '}').join(String(vars[k]));
        return s;
    }

    function buildPollContent(question, options) {
        const p = cleanPoll(question, options);
        if (!p) return null;
        const lines = ['📊 ' + STRINGS.previewPrefix + p.question];
        p.options.forEach((o, i) => lines.push((i + 1) + '. ' + o));
        lines.push(PREFIX + 'v=1;q=' + pctEncode(p.question) + p.options.map((o) => ';o=' + pctEncode(o)).join(''));
        return lines.join('\n');
    }

    function parsePoll(content) {
        if (typeof content !== 'string' || content.indexOf(PREFIX) < 0) return null;
        const m = RX_LINE.exec(content);
        if (!m) return null;
        let v = null;
        let q = null;
        const opts = [];
        for (const part of m[1].split(';')) {
            const i = part.indexOf('=');
            if (i <= 0) return null;
            const k = part.slice(0, i);
            const val = part.slice(i + 1);
            if (k === 'v') { if (v != null) return null; v = val; }
            else if (k === 'q') { if (q != null) return null; q = val; }
            else if (k === 'o') opts.push(val);
        }
        if (v !== '1' || q == null) return null;
        let question;
        let options;
        try {
            question = pctDecode(q);
            options = opts.map(pctDecode);
        } catch (_) { return null; }
        if (options.length > LIMITS.optionsMax) return null;
        const p = cleanPoll(question, options);
        if (!p || p.options.length !== options.length) return null;
        return p;
    }

    function previewText(content) {
        const p = parsePoll(content);
        return p ? '📊 ' + STRINGS.previewPrefix + p.question : content;
    }

    function voteTags(pollId, optionIndex) {
        return [['type', TYPES.vote], ['e', pollId], ['response', String(optionIndex)]];
    }

    function voteContent(optionText) {
        return fill(STRINGS.voteContent, { option: cleanText(optionText, LIMITS.optionMax) });
    }

    function closeTags(pollId) {
        return [['type', TYPES.close], ['e', pollId]];
    }

    function closeContent(question) {
        return fill(STRINGS.closeContent, { question: cleanText(question, LIMITS.questionMax) });
    }

    function clampTs(ts, now) {
        const t = Math.floor(Number(ts) || 0);
        if (t <= 0) return 0;
        const n = Math.floor(Number(now) || 0);
        return n > 0 ? Math.min(t, n + LIMITS.futureSkewSec) : t;
    }

    function tagValue(tags, name) {
        const t = (Array.isArray(tags) ? tags : []).find((x) => Array.isArray(x) && x[0] === name && typeof x[1] === 'string');
        return t ? t[1] : null;
    }

    function parseControl(rumor, now) {
        if (!rumor || rumor.kind !== 14 || !Array.isArray(rumor.tags)) return null;
        const type = tagValue(rumor.tags, 'type');
        if (type !== TYPES.vote && type !== TYPES.close) return null;
        const pollId = tagValue(rumor.tags, 'e');
        const ts = clampTs(rumor.created_at, now);
        const pubkey = String(rumor.pubkey || '');
        const base = { type: type === TYPES.vote ? 'vote' : 'close', valid: false, pollId: pollId || '', pubkey, ts };
        if (!pollId || !RX_ID.test(pollId) || !RX_ID.test(pubkey) || ts <= 0) return base;
        if (type === TYPES.close) return Object.assign(base, { valid: true });
        const resp = tagValue(rumor.tags, 'response');
        if (resp == null || !/^\d{1,2}$/.test(resp)) return base;
        const option = parseInt(resp, 10);
        if (option >= LIMITS.optionsMax) return base;
        return Object.assign(base, { valid: true, option });
    }

    function emptyEntry() {
        return { v: {}, c: {} };
    }

    function copyEntry(entry) {
        const e = entry && typeof entry === 'object' ? entry : emptyEntry();
        const v = {};
        for (const pk of Object.keys(e.v || {})) v[pk] = (e.v[pk] || []).map((r) => ({ o: r.o, ts: r.ts }));
        return { v, c: Object.assign({}, e.c || {}) };
    }

    function applyVote(entry, voter, option, ts) {
        const out = copyEntry(entry);
        const t = Math.floor(Number(ts) || 0);
        const o = Number(option);
        if (!RX_ID.test(String(voter || '')) || t <= 0 || !Number.isInteger(o) || o < 0 || o >= LIMITS.optionsMax) return { entry: out, changed: false };
        const list = out.v[voter] || [];
        if (list.some((r) => r.ts === t && r.o === o)) return { entry: out, changed: false };
        list.push({ o, ts: t });
        list.sort((a, b) => (a.ts - b.ts) || (a.o - b.o));
        out.v[voter] = list.slice(-LIMITS.historyMax);
        return { entry: out, changed: out.v[voter].some((r) => r.ts === t && r.o === o) };
    }

    function applyClose(entry, pubkey, ts) {
        const out = copyEntry(entry);
        const t = Math.floor(Number(ts) || 0);
        if (!RX_ID.test(String(pubkey || '')) || t <= 0) return { entry: out, changed: false };
        const cur = out.c[pubkey];
        if (cur && cur <= t) return { entry: out, changed: false };
        out.c[pubkey] = t;
        return { entry: out, changed: true };
    }

    function closedAt(entry, author) {
        const c = (entry && entry.c) || {};
        return author && c[author] ? c[author] : 0;
    }

    function tally(entry, ctx) {
        const c = ctx || {};
        const n = Math.max(0, Math.floor(Number(c.options) || 0));
        const allowed = Array.isArray(c.allowed) ? c.allowed : null;
        const closed = closedAt(entry, c.author);
        const counts = new Array(n).fill(0);
        const picks = [];
        const votes = (entry && entry.v) || {};
        for (const pk of Object.keys(votes)) {
            if (allowed && allowed.indexOf(pk) < 0) continue;
            let best = null;
            for (const r of votes[pk] || []) {
                if (!r || !Number.isInteger(r.o) || r.o < 0 || r.o >= n) continue;
                if (closed && r.ts > closed) continue;
                if (!best || r.ts > best.ts || (r.ts === best.ts && r.o > best.o)) best = r;
            }
            if (best) picks.push({ pk, o: best.o, ts: best.ts });
        }
        picks.sort((a, b) => (a.ts - b.ts) || (a.pk < b.pk ? -1 : a.pk > b.pk ? 1 : 0));
        const choices = {};
        const order = [];
        for (const p of picks) {
            counts[p.o]++;
            choices[p.pk] = p.o;
            order.push(p.pk);
        }
        return { counts, total: picks.length, choices, order, closed: !!closed, closedAt: closed };
    }

    function percent(count, total) {
        return total > 0 ? Math.round((count / total) * 100) : 0;
    }

    function nextVoteTs(entry, voter, now) {
        const n = Math.floor(Number(now) || 0);
        const list = (entry && entry.v && entry.v[voter]) || [];
        const last = list.reduce((m, r) => Math.max(m, r.ts || 0), 0);
        return Math.max(n, last + 1);
    }

    function votesLabel(total) {
        return total === 1 ? STRINGS.oneVote : fill(STRINGS.manyVotes, { n: total });
    }

    function prune(store, keep) {
        const out = Object.assign({}, store || {});
        const ids = Object.keys(out);
        const max = keep || LIMITS.pollsMax;
        if (ids.length > max) for (const id of ids.slice(0, ids.length - max)) delete out[id];
        return out;
    }

    G.NymDmPolls = {
        LIMITS, TYPES, STRINGS, PREFIX,
        pctEncode, pctDecode, cleanText, cleanPoll, buildPollContent, parsePoll, previewText,
        voteTags, voteContent, closeTags, closeContent, clampTs, parseControl,
        emptyEntry, applyVote, applyClose, closedAt, tally, percent, nextVoteTs, votesLabel, prune,
    };
})();
