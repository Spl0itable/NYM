const NAME_MAX = 20;
const RUN_MAX = 3;
const HEX4 = /^[0-9a-f]{4}$/i;
const TAG_STOP = /[0-9A-Za-z_]/;
const WORDY = /[\p{L}\p{N}\p{M}_]/u;
const SPACE = /\s/;
const BREAKS = /\r\n|[\r\n\u000b\u000c\u0085\u2028\u2029]/g;
const SKIP = /```[\s\S]*?```|```[\s\S]+$|`[^`]+?`|https?:\/\/\S+/gi;
const TRIGGER = /(?:^|\s)@([^\s]*)$/;
const SEG = typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function' ? Intl.Segmenter : null;
let segmenter = null;

function str(v) {
    return v == null ? '' : String(v);
}

function countUpTo(s, cap) {
    let n = 0;
    if (SEG) {
        if (!segmenter) segmenter = new SEG(undefined, { granularity: 'grapheme' });
        for (const _ of segmenter.segment(s)) if (++n >= cap) break;
        return n;
    }
    for (const _ of s) if (++n >= cap) break;
    return n;
}

function isWs(c) {
    return c === 32 || (c >= 9 && c <= 13) || c === 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a)
        || c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000 || c === 0xfeff;
}

function isHard(c) {
    return c === 10 || c === 13 || c === 1 || (c >= 0xfdd0 && c <= 0xfdef);
}

function isDelim(c) {
    return c === 42 || c === 95 || c === 124 || c === 126;
}

function isTag(s, j) {
    if (s.charCodeAt(j) !== 35 || !HEX4.test(s.substr(j + 1, 4))) return false;
    return !(j + 5 < s.length && TAG_STOP.test(s.charAt(j + 5)));
}

function charBefore(s, at) {
    if (at <= 0) return '';
    const c = s.charCodeAt(at - 1);
    if (c >= 0xdc00 && c <= 0xdfff && at >= 2) {
        const h = s.charCodeAt(at - 2);
        if (h >= 0xd800 && h <= 0xdbff) return s.slice(at - 2, at);
    }
    return s.charAt(at - 1);
}

function charAfter(s, at) {
    if (at >= s.length) return '';
    const c = s.charCodeAt(at);
    if (c >= 0xd800 && c <= 0xdbff && at + 1 < s.length) return s.slice(at, at + 2);
    return s.charAt(at);
}

function wordyBefore(s, at) {
    return at > 0 && WORDY.test(charBefore(s, at));
}

function wordyAt(s, at) {
    return at < s.length && WORDY.test(charAfter(s, at));
}

function canStart(s, at) {
    if (!wordyBefore(s, at)) return true;
    if (s.charCodeAt(at - 1) !== 95) return false;
    let k = at - 1;
    while (k > 0 && isDelim(s.charCodeAt(k - 1))) k--;
    return !wordyBefore(s, k);
}

function skipRanges(s) {
    const out = [];
    SKIP.lastIndex = 0;
    let m;
    while ((m = SKIP.exec(s)) !== null) {
        out.push([m.index, m.index + m[0].length]);
        if (m[0].length === 0) SKIP.lastIndex++;
    }
    return out;
}

function scanner(s) {
    return { s, tag: -1, tagFrom: -1, hard: -1, hardFrom: -1, wsAt: -1, wsAtFrom: -1, ascii: null, line: 0, lineTo: 0, nl: -2, runs: new Map() };
}

function nextTag(sc, from) {
    if (sc.tagFrom >= 0 && sc.tagFrom <= from && (sc.tag < 0 || sc.tag >= from)) return sc.tag;
    const s = sc.s;
    let j = s.indexOf('#', from);
    while (j >= 0 && !isTag(s, j)) j = s.indexOf('#', j + 1);
    sc.tagFrom = from;
    sc.tag = j;
    return j;
}

function nextHard(sc, from) {
    if (sc.hardFrom >= 0 && sc.hardFrom <= from && (sc.hard < 0 || sc.hard >= from)) return sc.hard;
    const s = sc.s;
    let j = from;
    while (j < s.length && !isHard(s.charCodeAt(j))) j++;
    sc.hardFrom = from;
    sc.hard = j < s.length ? j : -1;
    return sc.hard;
}

function nextWsAt(sc, from) {
    if (sc.wsAtFrom >= 0 && sc.wsAtFrom <= from && (sc.wsAt < 0 || sc.wsAt >= from)) return sc.wsAt;
    const s = sc.s;
    let a = s.indexOf('@', from + 1);
    while (a >= 0 && !isWs(s.charCodeAt(a - 1))) a = s.indexOf('@', a + 1);
    sc.wsAtFrom = from;
    sc.wsAt = a >= 0 ? a - 1 : -1;
    return sc.wsAt;
}

function asciiIn(sc, a, j) {
    if (!sc.ascii) {
        const s = sc.s;
        const p = new Uint32Array(s.length + 1);
        for (let i = 0; i < s.length; i++) p[i + 1] = p[i] + (s.charCodeAt(i) < 0x80 ? 1 : 0);
        sc.ascii = p;
    }
    return sc.ascii[j] - sc.ascii[a];
}

function lineStart(sc, at) {
    const s = sc.s;
    if (at < sc.lineTo) return at <= 0 ? 0 : s.lastIndexOf('\n', at - 1) + 1;
    for (;;) {
        if (sc.nl === -2) sc.nl = s.indexOf('\n', sc.lineTo);
        if (sc.nl < 0 || sc.nl >= at) break;
        sc.line = sc.nl + 1;
        sc.lineTo = sc.nl + 1;
        sc.nl = -2;
    }
    sc.lineTo = at;
    return sc.line;
}

function opened(sc, at, run) {
    if (run.length > RUN_MAX) return false;
    const from = lineStart(sc, at);
    const want = run.split('').reverse().join('');
    const hit = sc.runs.get(want);
    let idx;
    if (hit && hit.from <= from && (hit.idx < 0 || hit.idx >= from)) idx = hit.idx;
    else {
        idx = sc.s.indexOf(want, from);
        sc.runs.set(want, { from, idx });
    }
    return idx >= 0 && idx + want.length <= at;
}

function validName(sc, a, j) {
    const s = sc.s;
    if (j <= a || isWs(s.charCodeAt(a)) || isWs(s.charCodeAt(j - 1))) return false;
    const hard = nextHard(sc, a);
    if (hard >= 0 && hard < j) return false;
    const wa = nextWsAt(sc, a);
    if (wa >= 0 && wa + 1 < j) return false;
    const len = j - a;
    if (len <= NAME_MAX) return true;
    const asc = asciiIn(sc, a, j);
    if (asc > NAME_MAX || asc === len) return false;
    return countUpTo(s.slice(a, j), NAME_MAX + 1) <= NAME_MAX;
}

function suffixedAt(sc, at, stop) {
    const s = sc.s;
    const a = at + 1;
    if (a >= stop || isWs(s.charCodeAt(a))) return null;
    const j = nextTag(sc, a);
    if (j < 0 || j + 5 > stop || !validName(sc, a, j)) return null;
    const suffix = s.slice(j + 1, j + 5);
    let end = j + 5;
    if (end + 5 <= stop && isTag(s, end) && s.slice(end + 1, end + 5).toLowerCase() === suffix.toLowerCase()) end += 5;
    return { start: at, end, name: s.slice(a, j), suffix };
}

function bareAt(sc, at, stop) {
    const s = sc.s;
    let j = at + 1;
    while (j < stop) {
        const c = s.charCodeAt(j);
        if (c === 64 || isWs(c) || isHard(c)) break;
        j++;
    }
    if (j === at + 1) return null;
    let e = j;
    if (!isDelim(s.charCodeAt(at + 1))) {
        while (isDelim(s.charCodeAt(e - 1))) e--;
        if (e < j && !opened(sc, at, s.slice(e, j))) e = j;
    }
    return { start: at, end: e, name: s.slice(at + 1, e), suffix: null };
}

function mentions(text, known) {
    const s = str(text);
    const out = [];
    if (s.indexOf('@') < 0) return out;
    const sc = scanner(s);
    const skip = skipRanges(s);
    let k = 0;
    let i = 0;
    while (i < s.length) {
        const at = s.indexOf('@', i);
        if (at < 0) break;
        while (k < skip.length && skip[k][1] <= at) k++;
        if (k < skip.length && skip[k][0] <= at) { i = skip[k][1]; continue; }
        if (!canStart(s, at)) { i = at + 1; continue; }
        const stop = k < skip.length ? skip[k][0] : s.length;
        let m = suffixedAt(sc, at, stop);
        if (m && typeof known === 'function' && SPACE.test(m.name) && !known(m.name, m.suffix)) m = null;
        if (!m) m = bareAt(sc, at, stop);
        if (m) { out.push(m); i = m.end; } else i = at + 1;
    }
    return out;
}

function headerName(author) {
    return str(author).replace(BREAKS, ' ');
}

function mentionName(base) {
    return headerName(base).trim();
}

function keyOf(name) {
    return mentionName(name).toLowerCase();
}

function quoteHeader(line) {
    let s = str(line);
    if (s.charAt(0) === '>') s = s.slice(1);
    s = s.replace(/^\s+/, '');
    if (s.charAt(0) !== '@') return null;
    let lead = 1;
    while (lead < s.length && isWs(s.charCodeAt(lead))) lead++;
    let cand = null;
    let first = -1;
    for (let j = s.indexOf('#', 1); j >= 0; j = s.indexOf('#', j + 1)) {
        if (!isTag(s, j)) continue;
        if (first < 0) first = j;
        if (j < 2 || j <= lead) continue;
        const suffix = s.slice(j + 1, j + 5);
        let end = j + 5;
        if (s.charAt(end) !== ':' && isTag(s, end) && s.slice(end + 1, end + 5).toLowerCase() === suffix.toLowerCase()) end += 5;
        if (s.charAt(end) === ':') { cand = { author: s.slice(1, j), suffix, body: s.slice(end + 1).replace(/^\s+/, '') }; break; }
    }
    const colon = s.indexOf(':');
    const fb = colon > lead && (first < 0 || first >= colon)
        ? { author: s.slice(1, colon), suffix: '', body: s.slice(colon + 1).replace(/^\s+/, '') }
        : null;
    if (cand && fb) {
        const a = cand.author;
        if (isWs(a.charCodeAt(a.length - 1)) || countUpTo(a.trim(), NAME_MAX + 1) > NAME_MAX) return fb;
    }
    return cand || fb;
}

function quoteLabel(line) {
    const h = quoteHeader(line);
    return h ? h.author + (h.suffix ? '#' + h.suffix : '') : null;
}

function quoteAuthors(text) {
    const out = [];
    for (const line of str(text).split('\n')) {
        if (!/^>/.test(line)) continue;
        const l = quoteLabel(line);
        if (l !== null) out.push(l);
    }
    return out;
}

function tailOf(pubkey) {
    const p = str(pubkey).toLowerCase();
    return /^[0-9a-f]{64}$/.test(p) ? p.slice(-4) : (/[0-9a-f]{4}$/.test(p) ? p.slice(-4) : '');
}

function baseOf(u) {
    const n = str(u && u.nym);
    const t = tailOf(u && u.pubkey);
    return t && n.toLowerCase().endsWith('#' + t) ? n.slice(0, -5) : n;
}

function list(users) {
    if (!users) return [];
    if (Array.isArray(users)) return users;
    if (typeof users.forEach === 'function' && typeof users.get === 'function') {
        const out = [];
        users.forEach((u, pk) => out.push({ pubkey: (u && u.pubkey) || pk, nym: u && u.nym }));
        return out;
    }
    return Array.from(users);
}

function pick(hits, name) {
    if (!hits.size) return null;
    const all = Array.from(hits.values());
    if (all.length === 1) return { pubkey: all[0].pubkey, nym: all[0].nym };
    return { ambiguous: all, name };
}

function resolveMention(name, suffix, users) {
    const want = keyOf(name);
    if (!want) return null;
    const sfx = str(suffix).toLowerCase();
    const hits = new Map();
    for (const u of list(users)) {
        const pk = str(u && u.pubkey).toLowerCase();
        if (!pk || hits.has(pk)) continue;
        if (sfx && !pk.endsWith(sfx)) continue;
        if (keyOf(baseOf(u)) === want) hits.set(pk, { pubkey: pk, nym: baseOf(u) });
    }
    return pick(hits, mentionName(name));
}

function resolveTarget(input, users) {
    const s = str(input).trim();
    if (!s) return null;
    if (/^[0-9a-f]{64}$/i.test(s)) return { pubkey: s.toLowerCase(), nym: '' };
    const tries = [s];
    if (s.charAt(0) === '@' && s.length > 1) tries.push(s.slice(1));
    const queries = [];
    for (const t of tries) {
        const m = /^([\s\S]+)#([0-9a-f]{1,4})$/i.exec(t);
        if (m) queries.push({ key: keyOf(m[1]), sfx: m[2].toLowerCase(), name: m[1] });
        queries.push({ key: keyOf(t), sfx: '', name: t });
    }
    const hits = new Map();
    let named = '';
    for (const u of list(users)) {
        const pk = str(u && u.pubkey).toLowerCase();
        if (!pk || hits.has(pk)) continue;
        const k = keyOf(baseOf(u));
        for (const q of queries) {
            if (!q.key || k !== q.key || (q.sfx && !pk.endsWith(q.sfx))) continue;
            hits.set(pk, { pubkey: pk, nym: baseOf(u) });
            if (!named) named = q.name;
            break;
        }
    }
    return pick(hits, mentionName(named || tries[tries.length - 1]));
}

function channelTarget(input) {
    const s = str(input).trim();
    if (s.charAt(0) !== '#') return '';
    const name = s.slice(1);
    if (!/^[\p{L}\p{N}]+$/u.test(name)) return '';
    let out = '';
    for (const ch of name) out += ch === 'İ' ? 'i' : ch.toLowerCase();
    return out;
}

function blockTarget(input, users) {
    const hit = resolveTarget(input, users);
    if (hit) return hit;
    const ch = channelTarget(input);
    return ch ? { channel: ch } : null;
}

function selfMention(content, base, pubkey, known) {
    const own = mentionName(base);
    const none = { mentioned: false, quoted: false };
    const s = str(content);
    if (!own || !s) return none;
    const sfx = tailOf(pubkey);
    const want = own.toLowerCase();
    let quoted = false;
    const kept = [];
    for (const line of s.split('\n')) {
        const t = line.replace(/^\s+/, '');
        if (t.charAt(0) !== '>') { kept.push(line); continue; }
        if (quoted || !sfx) continue;
        const inner = t.slice(1).replace(/^\s+/, '');
        if (inner.charAt(0) === '>') continue;
        const h = quoteHeader(inner);
        if (h && h.suffix && h.suffix.toLowerCase() === sfx && keyOf(h.author) === want) quoted = true;
    }
    const text = kept.join('\n');
    if (text.indexOf('@') < 0) return { mentioned: false, quoted };
    const ms = mentions(text, known);
    for (const m of ms) {
        if (m.suffix && sfx && m.suffix.toLowerCase() === sfx && keyOf(m.name) === want) return { mentioned: true, quoted };
    }
    const held = ms.filter((m) => m.suffix).map((m) => [m.start, m.end]);
    const skip = skipRanges(text);
    const taken = [];
    for (let x = 0, y = 0; x < held.length || y < skip.length;) {
        if (y >= skip.length || (x < held.length && held[x][0] < skip[y][0])) taken.push(held[x++]);
        else taken.push(skip[y++]);
    }
    const sc = scanner(text);
    let r = 0;
    let at = text.indexOf('@');
    while (at >= 0) {
        while (r < taken.length && taken[r][1] <= at) r++;
        if (r < taken.length && taken[r][0] <= at) { at = text.indexOf('@', taken[r][1]); continue; }
        if (canStart(text, at)) {
            const end = at + 1 + own.length;
            if (text.slice(at + 1, end).toLowerCase() === want && endsBare(sc, text, at, end)) return { mentioned: true, quoted };
        }
        at = text.indexOf('@', at + 1);
    }
    return { mentioned: false, quoted };
}

function endsBare(sc, s, at, end) {
    if (!wordyAt(s, end)) return true;
    let e = end;
    while (e < s.length && isDelim(s.charCodeAt(e))) e++;
    if (e === end || wordyAt(s, e)) return false;
    return opened(sc, at, s.slice(end, e));
}

function groupArgs(args) {
    const s = str(args);
    const members = [];
    const words = [];
    const take = (part) => {
        for (const w of part.split(/\s+/)) {
            if (!w) continue;
            if (/^[0-9a-f]{64}$/i.test(w) || /^npub1[0-9a-z]+$/i.test(w)) members.push(w);
            else if (w.charAt(0) !== '#' && /[^#]#[0-9a-f]{4}$/i.test(w) && isTag(w, w.length - 5)) members.push(w);
            else words.push(w);
        }
    };
    let at = 0;
    for (const m of mentions(s)) {
        take(s.slice(at, m.start));
        members.push(s.slice(m.start, m.end));
        at = m.end;
    }
    take(s.slice(at));
    return { members, name: words.join(' ') };
}

function stripEnvelope(text) {
    let s = str(text);
    const m = mentions(s)[0];
    if (m && m.start === 0) {
        let e = m.end;
        while (s.charAt(e) === ' ' || s.charAt(e) === '\t') e++;
        if (e > m.end) s = s.slice(e);
    }
    return s.replace(/^[ \t]*⚡.*$/gm, '');
}

function shield(text) {
    const s = str(text);
    return mentions(s).map((m) => s.slice(m.start, m.end));
}

function splitMentions(text) {
    const s = str(text);
    const out = [];
    let at = 0;
    for (const m of mentions(s)) {
        out.push(s.slice(at, m.start), s.slice(m.start, m.end));
        at = m.end;
    }
    out.push(s.slice(at));
    return out;
}

function mentionText(nym, pubkey) {
    const t = tailOf(pubkey);
    const base = baseOf({ nym, pubkey });
    return '@' + mentionName(base) + (t ? '#' + t : '');
}

function insertMention(value, caret, nym, pubkey) {
    const v = str(value);
    const c = caret == null || caret < 0 || caret > v.length ? v.length : caret;
    const m = TRIGGER.exec(v.slice(0, c));
    if (!m) return null;
    const start = c - m[1].length - 1;
    const ins = mentionText(nym, pubkey) + ' ';
    return { value: v.slice(0, start) + ins + v.slice(c), caret: start + ins.length, start };
}

export { NAME_MAX, isTag, mentions, splitMentions, quoteHeader, quoteLabel, quoteAuthors, headerName, mentionName, mentionText, resolveMention, resolveTarget, blockTarget, channelTarget, selfMention, groupArgs, stripEnvelope, shield, insertMention, tailOf, baseOf };
