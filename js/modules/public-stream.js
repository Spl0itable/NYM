(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const FIRST = 20;
    const STEP = 50;
    const MAX = 500;
    const CLIP = 240;
    const MEDIA_MAX = 4;
    const WINDOW_SEC = 86400;
    const DEFAULT_CHANNEL = 'nymchat';
    const SETTING = 'sidebarChannelsMode';
    const LOCAL_KEY = 'nym_sidebar_channels_mode';
    const MODES = Object.freeze(['list', 'stream']);
    const HIDE_FLAGS = Object.freeze(['deleted', 'pendingDeletion', 'gated', 'contentHidden', 'blocked', 'expired', 'threadReply', 'botThreadForeign']);
    const LABELS = Object.freeze({
        text: '{time}, {channel}, {nym}: {text}',
        bare: '{time}, {channel}, {nym}',
    });
    const RX_TOKEN = /(https?:\/\/[^\s<>"]+\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(?:\?[^\s<>"]*)?)|(https?:\/\/[^\s<>"]+)|:([a-zA-Z0-9_]+):|(@[^\s]+)/gi;
    const VIDEO_EXT = Object.freeze(['mp4', 'webm', 'ogg', 'mov']);

    function isMode(v) {
        return v === 'list' || v === 'stream';
    }

    function normalizeMode(v) {
        return v === 'stream' ? 'stream' : 'list';
    }

    function asSet(v) {
        if (v instanceof Set) return v;
        return new Set(Array.isArray(v) ? v : []);
    }

    function streamKeys(o) {
        const x = o || {};
        if (x.pmOnly === true) return [];
        const blocked = asSet(x.blocked);
        const hidden = asSet(x.hidden);
        const pinned = asSet(x.pinned);
        const locked = asSet(x.locked);
        const hideNonPinned = x.hideNonPinned === true;
        const out = [];
        const seen = new Set();
        const list = Array.isArray(x.channels) ? x.channels : [];
        const all = list.includes(DEFAULT_CHANNEL) ? list : [DEFAULT_CHANNEL].concat(list);
        for (const raw of all) {
            if (typeof raw !== 'string' || !raw) continue;
            const key = raw;
            if (seen.has(key)) continue;
            seen.add(key);
            if (blocked.has(key)) continue;
            if (key !== DEFAULT_CHANNEL) {
                if (hidden.has(key)) continue;
                if (hideNonPinned && !pinned.has(key)) continue;
            }
            if (locked.has(key)) continue;
            out.push(key);
        }
        return out;
    }

    function flagsVisible(flags) {
        const f = flags || {};
        for (const k of HIDE_FLAGS) if (f[k] === true) return false;
        return true;
    }

    let seg = null;
    function graphemes(s) {
        if (seg === null) {
            try { seg = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter('en', { granularity: 'grapheme' }) : false; } catch (_) { seg = false; }
        }
        return seg ? Array.from(seg.segment(s), (x) => x.segment) : Array.from(s);
    }

    function has(set, k) {
        if (!set) return false;
        if (typeof set.has === 'function') return set.has(k);
        if (Array.isArray(set)) return set.includes(k);
        return Object.prototype.hasOwnProperty.call(set, k);
    }

    function lookup(map, k) {
        if (!map) return null;
        const v = typeof map.get === 'function' ? map.get(k) : (Object.prototype.hasOwnProperty.call(map, k) ? map[k] : null);
        return typeof v === 'string' && v ? v : null;
    }

    function tokenize(flat, o) {
        const toks = [];
        let at = 0;
        RX_TOKEN.lastIndex = 0;
        let mt;
        while ((mt = RX_TOKEN.exec(flat)) !== null) {
            if (mt.index > at) toks.push({ k: 'text', s: flat.slice(at, mt.index) });
            if (mt[1]) toks.push({ k: VIDEO_EXT.includes(mt[2].toLowerCase()) ? 'v' : 'i', s: mt[1] });
            else if (mt[3]) toks.push({ k: 'atom', s: mt[3] });
            else if (mt[4] !== undefined) {
                const code = mt[4];
                const std = lookup(o.builtin, code.toLowerCase());
                if (std) toks.push({ k: 'std', s: std });
                else if (has(o.emoji, code)) toks.push({ k: 'e', s: code });
                else toks.push({ k: 'atom', s: mt[0] });
            } else toks.push({ k: 'atom', s: mt[5] });
            at = mt.index + mt[0].length;
        }
        if (at < flat.length) toks.push({ k: 'text', s: flat.slice(at) });
        return toks;
    }

    function parts(s, opts) {
        const o = opts || {};
        const flat = String(typeof s === 'string' ? s : '').replace(/\s+/g, ' ').trim();
        const out = [];
        const media = [];
        let left = CLIP;
        let clipped = false;
        let gap = false;
        const pushText = (t) => {
            gap = false;
            if (!t) return;
            const last = out[out.length - 1];
            if (last && last[0] === 't') last[1] += t;
            else out.push(['t', t]);
        };
        const lead = (t) => {
            const last = out[out.length - 1];
            return gap && t.startsWith(' ') && (!last || (last[0] === 't' && last[1].endsWith(' '))) ? t.slice(1) : t;
        };
        for (const tk of tokenize(flat, o)) {
            if (tk.k === 'i' || tk.k === 'v') {
                if (media.length < MEDIA_MAX) media.push([tk.k, tk.s]);
                gap = true;
                continue;
            }
            if (clipped) continue;
            if (tk.k === 'text') {
                const t = lead(tk.s);
                const g = graphemes(t);
                if (g.length <= left) { pushText(t); left -= g.length; continue; }
                pushText(g.slice(0, left).join(''));
                left = 0;
                clipped = true;
                continue;
            }
            const n = tk.k === 'e' || tk.k === 'std' ? 1 : graphemes(tk.s).length;
            if (n > left) { clipped = true; continue; }
            left -= n;
            if (tk.k === 'e') { out.push(['e', tk.s]); gap = false; } else pushText(tk.s);
        }
        if (out.length && out[0][0] === 't') {
            out[0][1] = out[0][1].replace(/^ +/, '');
            if (!out[0][1]) out.shift();
        }
        const tail = out[out.length - 1];
        if (!clipped && tail && tail[0] === 't') {
            tail[1] = tail[1].replace(/ +$/, '');
            if (!tail[1]) out.pop();
        }
        if (clipped) pushText('…');
        return { parts: out, media, clipped };
    }

    function partsText(p) {
        const list = p && Array.isArray(p.parts) ? p.parts : [];
        return list.map((x) => (x[0] === 'e' ? ':' + x[1] + ':' : x[1])).join('');
    }

    function clip(s) {
        return partsText(parts(s, {}));
    }

    const defAt = (m) => (m && typeof m.t === 'number' ? m.t : 0);
    const defMs = (m) => (m && typeof m.ms === 'number' ? m.ms : 0);
    const defId = (m) => (m && typeof m.id === 'string' ? m.id : '');
    const defVisible = (m) => !(m && m.hide === true);

    function compareNewest(a, b) {
        if (a.t !== b.t) return b.t - a.t;
        if (a.ms > a.t * 1000 && b.ms > b.t * 1000 && a.ms !== b.ms) return b.ms - a.ms;
        if (a.key !== b.key) return a.key < b.key ? -1 : 1;
        return 0;
    }

    function stamp(m, key, acc) {
        return { t: acc.at(m), ms: acc.ms(m), key, id: acc.id(m) };
    }

    function walk(lists, o, visit) {
        const acc = { at: o.at || defAt, ms: o.ms || defMs, id: o.id || defId, visible: o.visible || defVisible };
        const floor = typeof o.floorSec === 'number' ? o.floorSec : -Infinity;
        const cur = [];
        for (const l of (Array.isArray(lists) ? lists : [])) {
            if (!l || typeof l.key !== 'string' || !Array.isArray(l.msgs) || !l.msgs.length) continue;
            cur.push({ key: l.key, msgs: l.msgs, i: l.msgs.length - 1, head: null });
        }
        const advance = (c) => {
            while (c.i >= 0) {
                const m = c.msgs[c.i];
                const s = m ? stamp(m, c.key, acc) : null;
                if (s && s.t < floor) { c.i = -1; break; }
                c.i--;
                if (s && acc.visible(m, c.key)) { c.head = { s, m }; return; }
            }
            c.head = null;
        };
        cur.forEach(advance);
        let live = cur.filter((c) => c.head);
        while (live.length) {
            let best = live[0];
            for (let j = 1; j < live.length; j++) if (compareNewest(live[j].head.s, best.head.s) < 0) best = live[j];
            const h = best.head;
            if (visit(h.s, h.m) === false) return;
            advance(best);
            if (!best.head) live = live.filter((c) => c.head);
        }
    }

    function page(lists, st, o) {
        const opt = o || {};
        const state = st || {};
        const max = typeof opt.max === 'number' ? opt.max : MAX;
        const shown = Math.max(1, Math.min(max, typeof state.shown === 'number' ? state.shown : FIRST));
        const cap = Math.min(max, shown + STEP);
        const anchor = state.anchor || null;
        const tail = state.tail || null;
        const frozen = asSet(state.frozen);
        const held = !!anchor;
        const nowSec = typeof opt.nowSec === 'number' ? opt.nowSec : Math.floor(Date.now() / 1000);
        const rows = [];
        const pendingIds = [];
        let eligible = 0;
        let pastTail = false;
        walk(lists, {
            floorSec: nowSec - WINDOW_SEC, at: opt.at, ms: opt.ms, id: opt.id, visible: opt.visible,
        }, (s, m) => {
            if (held && !frozen.has(s.id)) {
                const older = pastTail || (tail ? compareNewest(s, tail) > 0 : false);
                if (!older) { pendingIds.push(s.id); return true; }
            }
            if (tail && s.id === tail.id) pastTail = true;
            if (eligible >= cap) return false;
            eligible++;
            if (rows.length < shown) rows.push({ key: s.key, id: s.id, t: s.t, ms: s.ms, m });
            return true;
        });
        const remaining = Math.max(0, Math.min(eligible, cap) - rows.length);
        return { rows, pending: pendingIds.length, pendingIds, remaining, shown, held, button: moreButton(shown, remaining, max) };
    }

    function moreButton(shown, remaining, max) {
        const cap = typeof max === 'number' ? max : MAX;
        if (remaining > 0 && shown <= FIRST) return { kind: 'view', n: remaining, next: Math.min(cap, FIRST + STEP) };
        if (remaining > 0) return { kind: 'show', n: Math.min(remaining, STEP), next: Math.min(cap, shown + STEP) };
        if (shown > FIRST) return { kind: 'less', n: 0, next: FIRST };
        return null;
    }

    function hold(rows, cur) {
        const list = Array.isArray(rows) ? rows : [];
        if (!list.length) return { anchor: null, tail: null, frozen: [] };
        const pick = (r) => ({ t: r.t, ms: typeof r.ms === 'number' ? r.ms : 0, key: r.key, id: r.id });
        const prev = cur && cur.anchor ? cur.anchor : null;
        return { anchor: prev || pick(list[0]), tail: pick(list[list.length - 1]), frozen: list.map((r) => r.id) };
    }

    function isHeld(o) {
        const x = o || {};
        if (x.pointerDown === true) return true;
        if (typeof x.headTop !== 'number' || typeof x.viewTop !== 'number') return false;
        return x.headTop < x.viewTop - 1;
    }

    function rowLabel(o) {
        const x = o || {};
        const bare = x.hide === true || !x.text;
        const template = bare ? LABELS.bare : LABELS.text;
        const vars = { time: String(x.time || ''), channel: String(x.channel || ''), nym: String(x.nym || '') };
        if (!bare) vars.text = String(x.text);
        return { template, vars };
    }

    function pillLabel(n) {
        const c = Math.max(0, Math.floor(Number(n) || 0));
        if (c <= 0) return null;
        return c === 1 ? { template: '1 new message', vars: {} } : { template: '{n} new messages', vars: { n: c } };
    }

    function tagLabel(key) {
        const k = String(key || '');
        return k.startsWith('#') ? k : '#' + k;
    }

    G.NymPublicStream = Object.freeze({
        FIRST, STEP, MAX, CLIP, MEDIA_MAX, WINDOW_SEC, DEFAULT_CHANNEL, SETTING, LOCAL_KEY, MODES, HIDE_FLAGS, LABELS,
        isMode, normalizeMode, streamKeys, flagsVisible, graphemes, parts, partsText, clip, compareNewest, walk, page, moreButton, hold, isHeld,
        rowLabel, pillLabel, tagLabel,
    });
})();
