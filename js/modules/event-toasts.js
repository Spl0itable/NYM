(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const CONFIG = Object.freeze({
        maxVisible: 3,
        durationMs: 5000,
        bodyChars: 120,
        backlogQuietMs: 4000,
        backlogMaxMs: 12000,
        swipeDismissPx: 60,
    });

    const PLACEMENT = Object.freeze({
        desktopMinWidth: 1025,
        gutterPx: 16,
        desktopGapPx: 12,
        phoneGapPx: 12,
        composerGapPx: 8,
        desktopMaxWidthPx: 360,
        phoneMaxWidthPx: 480,
    });

    const TYPES = Object.freeze(['pm', 'mention', 'everyone', 'group', 'reaction', 'zap', 'invite', 'thread']);

    const FOREGROUND_MODES = Object.freeze(['both', 'toast', 'system']);

    const DEFAULTS = Object.freeze({
        enabled: true,
        foreground: 'both',
        types: Object.freeze({
            pm: true, mention: true, everyone: true, group: true,
            reaction: true, zap: true, invite: true, thread: true,
        }),
        chosen: Object.freeze([]),
    });

    const CHOSEN_ONLY = Object.freeze(['reaction']);

    const MESSAGE_TYPES = Object.freeze(['pm', 'mention', 'everyone', 'group', 'thread']);

    const LABELS = Object.freeze({
        pm: 'PM',
        mention: 'Mention',
        everyone: '@everyone',
        group: 'Group message',
        reaction: 'Reaction',
        zap: 'Zap',
        invite: 'Invite',
        thread: 'Thread reply',
    });

    const SETTING_LABELS = Object.freeze({
        pm: 'PMs',
        mention: 'Mentions',
        everyone: '@here and @everyone',
        group: 'Group messages',
        reaction: 'Reactions to your messages',
        zap: 'Zaps',
        invite: 'Group invites and join requests',
        thread: 'Replies in your threads',
    });

    const FOREGROUND_LABELS = Object.freeze({
        both: 'Banner and system notification',
        toast: 'Banner only',
        system: 'System notification only',
    });

    const STRINGS = Object.freeze({
        newMessage: 'New message',
        countMessages: '{count} new messages',
        countMessagesIn: '{count} new messages in {chat}',
        countMessagesFrom: '{count} new messages from {name}',
        countNotificationsIn: '{count} new notifications in {chat}',
        countNotificationsFrom: '{count} new notifications from {name}',
        countNotifications: '{count} new notifications',
        viewOnce: 'View-once media',
        master: 'Show in-app banners',
        whileOpen: 'While Nymchat is open',
        typesHeading: 'Show banners for',
    });

    const TOPICS = Object.freeze({
        reminder: Object.freeze({ prefix: 'event-reminder-', title: 'Event reminder', template: 'Reminder: {title}' }),
        callLink: Object.freeze({ prefix: 'call-link-', title: 'Call link', template: 'Call link: {name}' }),
    });

    const LEGACY_ID_PREFIX = 'gt-';

    const CALL_STRINGS = Object.freeze({
        call: 'Call',
        missed: 'Missed {kind} call',
        inGroup: ' in {group}',
        audio: 'audio',
        video: 'video',
    });

    const ONCE_LABELS = Object.freeze(['View-once photo', 'View-once video', 'View-once voice message']);

    function fill(s, params) {
        let out = String(s);
        if (params) {
            for (const k of Object.keys(params)) out = out.split('{' + k + '}').join(String(params[k]));
        }
        return out;
    }

    function plainTr(s, params) {
        return fill(s, params);
    }

    function normalizeSettings(raw) {
        const r = raw && typeof raw === 'object' ? raw : {};
        const t = r.types && typeof r.types === 'object' ? r.types : {};
        const picked = Array.isArray(r.chosen) ? r.chosen : [];
        const chosen = TYPES.filter((k) => picked.includes(k));
        const types = {};
        for (const k of TYPES) {
            const counts = typeof t[k] === 'boolean' && (!CHOSEN_ONLY.includes(k) || chosen.includes(k));
            types[k] = counts ? t[k] : DEFAULTS.types[k];
        }
        return {
            enabled: r.enabled !== false,
            foreground: FOREGROUND_MODES.includes(r.foreground) ? r.foreground : DEFAULTS.foreground,
            types,
            chosen,
        };
    }

    function patchSettings(current, patch) {
        const cur = normalizeSettings(current);
        const p = patch && typeof patch === 'object' ? patch : {};
        const next = Object.assign({}, cur);
        if (typeof p.enabled === 'boolean') next.enabled = p.enabled;
        if (typeof p.foreground === 'string') next.foreground = p.foreground;
        if (p.types && typeof p.types === 'object') {
            next.types = Object.assign({}, cur.types, p.types);
            next.chosen = cur.chosen.concat(Object.keys(p.types));
        }
        return normalizeSettings(next);
    }

    function category(ev) {
        const e = ev || {};
        if (e.kind === 'reaction' || e.kind === 'zap' || e.kind === 'invite') return e.kind;
        if (e.everyone) return 'everyone';
        if (e.mention) return 'mention';
        if (e.thread) return 'thread';
        if (e.kind === 'pm') return 'pm';
        if (e.kind === 'group') return 'group';
        return 'mention';
    }

    function decide(ev, view, settings) {
        const s = normalizeSettings(settings);
        const v = view || {};
        const e = ev || {};
        const cat = category(e);
        const out = (toast, system, reason) => ({ toast, system, reason, category: cat });
        const live = !e.backlog;
        if (v.identity && e.identity && v.identity !== e.identity) return out('none', false, 'identity');
        if (!v.foreground) return out('none', live, 'background');
        if (!s.enabled || !s.types[cat]) return out('none', live, 'disabled');
        if (s.foreground === 'system') return out('none', live, 'system-only');
        const system = live && s.foreground !== 'toast';
        if (e.seen) return out('none', system, 'in-view');
        if (e.backlog) return out('hold', false, 'backlog');
        if (v.call) return out('hold', system, 'call');
        if (v.sheet) return out('hold', system, 'sheet');
        return out('show', system, 'show');
    }

    function clip(text) {
        const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
        if (s.length <= CONFIG.bodyChars) return s;
        return s.slice(0, CONFIG.bodyChars).trimEnd() + '…';
    }

    function preview(ev, prefs) {
        if (!ev || ev.locked) return '';
        if (ev.viewOnce) return STRINGS.viewOnce;
        if (prefs && prefs.hidePreviews) return '';
        return String(ev.body == null ? '' : ev.body);
    }

    function bodyOf(ev, prefs) {
        return clip(preview(ev, prefs));
    }

    function metaLine(ev, T) {
        const label = T(LABELS[category(ev)]);
        const chat = String((ev && ev.chat) || '');
        return chat ? label + ' · ' + chat : label;
    }

    function systemBody(ev, prefs, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        if (!ev) return '';
        if (ev.locked) return T(STRINGS.newMessage);
        const shown = preview(ev, prefs);
        if (shown === STRINGS.viewOnce) return T(shown);
        if (shown || !(prefs && prefs.hidePreviews)) return shown;
        return metaLine(ev, T);
    }

    function topicOf(eventId) {
        const id = String(eventId == null ? '' : eventId);
        for (const k of Object.keys(TOPICS)) if (id.indexOf(TOPICS[k].prefix) === 0) return k;
        return '';
    }

    function systemTitle(ev, prefs, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        if (!ev) return '';
        const title = String(ev.title == null ? '' : ev.title);
        const known = typeof ev.topic === 'string' && Object.prototype.hasOwnProperty.call(TOPICS, ev.topic);
        if (!known || ev.locked || !(prefs && prefs.hidePreviews)) return title;
        return T(TOPICS[ev.topic].title);
    }

    const WORD_CHAR = /[\p{L}\p{N}]/u;

    function onceLabelOf(body, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        const s = String(body == null ? '' : body).trim();
        let best = '';
        for (const l of ONCE_LABELS) {
            for (const f of [l, String(T(l) || '')]) {
                if (!f || f.length <= best.length || s.indexOf(f) !== 0) continue;
                if (s.length > f.length && WORD_CHAR.test(s.charAt(f.length))) continue;
                best = f;
            }
        }
        return best;
    }

    function isViewOnce(body, tr) {
        return onceLabelOf(body, tr) !== '';
    }

    function listBody(ev, prefs, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        if (!ev || ev.locked) return '';
        const body = String(ev.body == null ? '' : ev.body);
        if (!(prefs && prefs.hidePreviews) || ev.system) return body;
        if (ev.viewOnce) return onceLabelOf(body, T) || T(STRINGS.viewOnce);
        return '';
    }

    function fitsTemplate(text, template) {
        const m = /\{[A-Za-z]+\}/.exec(template);
        if (!m) return false;
        const pre = template.slice(0, m.index);
        const post = template.slice(m.index + m[0].length);
        if (!pre.trim() && !post.trim()) return false;
        return text.length >= pre.length + post.length && text.indexOf(pre) === 0 && text.slice(text.length - post.length) === post;
    }

    function entryTopic(eventId, title, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        const byId = topicOf(eventId);
        if (byId) return byId;
        const id = String(eventId == null ? '' : eventId);
        if (id.indexOf(LEGACY_ID_PREFIX) !== 0) return '';
        const t = String(title == null ? '' : title);
        for (const k of Object.keys(TOPICS)) {
            const tpl = TOPICS[k].template;
            if (fitsTemplate(t, tpl) || fitsTemplate(t, String(T(tpl) || ''))) return k;
        }
        return '';
    }

    function callLabel(c, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        const e = c || {};
        if (e.topic === 'callLink') return T(TOPICS.callLink.title);
        if (!e.missed) return T(CALL_STRINGS.call);
        const base = T(CALL_STRINGS.missed, { kind: T(e.video ? CALL_STRINGS.video : CALL_STRINGS.audio) });
        return e.chat ? base + T(CALL_STRINGS.inGroup, { group: e.chat }) : base;
    }

    function callIsVideo(body, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        const s = String(body == null ? '' : body).trim();
        if (!s) return false;
        const forms = [plainTr(CALL_STRINGS.missed, { kind: CALL_STRINGS.video }), T(CALL_STRINGS.missed, { kind: T(CALL_STRINGS.video) })];
        return forms.some((f) => !!f && s.indexOf(f) === 0);
    }

    function isPmKey(key) {
        return typeof key === 'string' && key.indexOf('pm:') === 0;
    }

    function present(toast, prefs, tr) {
        const T = typeof tr === 'function' ? tr : plainTr;
        const p = prefs || {};
        if (!toast) return { title: '', meta: '', body: '', target: 'panel' };
        if (toast.kind === 'summary') {
            return { title: T(STRINGS.countNotifications, { count: toast.count }), meta: '', body: '', target: 'panel' };
        }
        const ev = toast.last || {};
        const locked = !!toast.locked;
        if (toast.count <= 1) {
            if (locked) return { title: T(STRINGS.newMessage), meta: '', body: '', target: 'conversation' };
            const cat = category(ev);
            const label = T(LABELS[cat]);
            const chat = String(ev.chat || '');
            const title = String(ev.sender || '') || chat || label;
            const meta = chat && chat !== title ? metaLine(ev, T) : label;
            const body = bodyOf(ev, p);
            return { title, meta, body: body === STRINGS.viewOnce ? T(body) : body, target: 'conversation' };
        }
        if (locked) return { title: T(STRINGS.countMessages, { count: toast.count }), meta: '', body: '', target: 'conversation' };
        const allMessages = (toast.cats || []).every((c) => MESSAGE_TYPES.includes(c));
        const pm = isPmKey(toast.key);
        const name = String(ev.sender || '');
        const chat = String(ev.chat || '') || name;
        let title;
        if (pm) title = T(allMessages ? STRINGS.countMessagesFrom : STRINGS.countNotificationsFrom, { count: toast.count, name: name || chat });
        else title = T(allMessages ? STRINGS.countMessagesIn : STRINGS.countNotificationsIn, { count: toast.count, chat });
        const body = bodyOf(ev, p);
        const shown = body === STRINGS.viewOnce ? T(body) : body;
        return { title, meta: '', body: shown ? (name && !pm ? name + ': ' + shown : shown) : '', target: 'conversation' };
    }

    function emptyState() {
        return { toasts: [], seq: 0 };
    }

    function slim(ev) {
        const e = ev || {};
        const out = {};
        for (const k of ['kind', 'key', 'sender', 'chat', 'body', 'mention', 'everyone', 'thread', 'locked', 'viewOnce', 'eventId']) {
            if (e[k] !== undefined && e[k] !== null && e[k] !== false && e[k] !== '') out[k] = e[k];
        }
        return out;
    }

    function rearm(t, now) {
        return t.paused
            ? Object.assign({}, t, { remaining: CONFIG.durationMs })
            : Object.assign({}, t, { expiresAt: now + CONFIG.durationMs });
    }

    function foldOverflow(toasts, seq, now) {
        let list = toasts.slice();
        let nextSeq = seq;
        const removed = [];
        while (list.length > CONFIG.maxVisible) {
            let si = list.findIndex((t) => t.kind === 'summary');
            const gi = list.findIndex((t) => t.kind !== 'summary');
            if (gi < 0) break;
            const g = list[gi];
            if (si < 0) {
                nextSeq += 1;
                list.unshift({ id: nextSeq, kind: 'summary', key: '', count: 0, events: [], keys: [], cats: [], locked: false, last: null, expiresAt: now + CONFIG.durationMs, paused: false, remaining: 0 });
                si = 0;
            }
            const s = list[si];
            list = list.filter((t) => t !== g);
            removed.push(g.id);
            const merged = rearm(Object.assign({}, s, {
                count: s.count + g.count,
                events: s.events.concat(g.events),
                keys: s.keys.includes(g.key) ? s.keys : s.keys.concat([g.key]),
            }), now);
            list = list.map((t) => (t === s ? merged : t));
        }
        return { toasts: list, seq: nextSeq, removed };
    }

    function add(state, ev, now) {
        const st = state || emptyState();
        const e = slim(ev);
        const cat = category(e);
        const idx = st.toasts.findIndex((t) => t.kind === 'group' && t.key === e.key);
        if (idx >= 0) {
            const g = st.toasts[idx];
            const next = rearm(Object.assign({}, g, {
                count: g.count + 1,
                events: g.events.concat([e.eventId || '']),
                cats: g.cats.includes(cat) ? g.cats : g.cats.concat([cat]),
                locked: g.locked || !!e.locked,
                last: e,
            }), now);
            const toasts = st.toasts.map((t, i) => (i === idx ? next : t));
            return { state: { toasts, seq: st.seq }, id: g.id, updated: [g.id], removed: [] };
        }
        const seq = st.seq + 1;
        const toast = {
            id: seq, kind: 'group', key: e.key || '', count: 1, events: [e.eventId || ''], keys: [e.key || ''],
            cats: [cat], locked: !!e.locked, last: e, expiresAt: now + CONFIG.durationMs, paused: false, remaining: 0,
        };
        const f = foldOverflow(st.toasts.concat([toast]), seq, now);
        const summary = f.toasts.find((t) => t.kind === 'summary');
        const updated = f.removed.length && summary ? [summary.id] : [];
        return { state: { toasts: f.toasts, seq: f.seq }, id: f.removed.includes(seq) ? (summary ? summary.id : null) : seq, updated, removed: f.removed };
    }

    function addMany(state, events, now) {
        const st = state || emptyState();
        const list = (events || []).map(slim);
        if (!list.length) return { state: st, id: null, updated: [], removed: [] };
        const keys = [];
        for (const e of list) if (!keys.includes(e.key)) keys.push(e.key);
        if (keys.length === 1) {
            let r = { state: st, id: null, updated: [], removed: [] };
            const updated = [];
            const removed = [];
            for (const e of list) {
                r = add(r.state, e, now);
                for (const u of r.updated) if (!updated.includes(u)) updated.push(u);
                for (const x of r.removed) if (!removed.includes(x)) removed.push(x);
            }
            return { state: r.state, id: r.id, updated: updated.filter((u) => !removed.includes(u)), removed };
        }
        let toasts = st.toasts.slice();
        let seq = st.seq;
        let si = toasts.findIndex((t) => t.kind === 'summary');
        let created = false;
        if (si < 0) {
            seq += 1;
            toasts.unshift({ id: seq, kind: 'summary', key: '', count: 0, events: [], keys: [], cats: [], locked: false, last: null, expiresAt: now + CONFIG.durationMs, paused: false, remaining: 0 });
            si = 0;
            created = true;
        }
        const s = toasts[si];
        const allKeys = s.keys.slice();
        for (const k of keys) if (!allKeys.includes(k)) allKeys.push(k);
        const merged = rearm(Object.assign({}, s, {
            count: s.count + list.length,
            events: s.events.concat(list.map((e) => e.eventId || '')),
            keys: allKeys,
        }), now);
        toasts = toasts.map((t) => (t === s ? merged : t));
        const f = foldOverflow(toasts, seq, now);
        return { state: { toasts: f.toasts, seq: f.seq }, id: merged.id, updated: created ? [] : [merged.id], removed: f.removed };
    }

    function dismiss(state, id) {
        return Object.assign({}, state, { toasts: state.toasts.filter((t) => t.id !== id) });
    }

    function pause(state, id, now) {
        return Object.assign({}, state, {
            toasts: state.toasts.map((t) => (t.id === id && !t.paused
                ? Object.assign({}, t, { paused: true, remaining: Math.max(0, t.expiresAt - now) })
                : t)),
        });
    }

    function resume(state, id, now) {
        return Object.assign({}, state, {
            toasts: state.toasts.map((t) => (t.id === id && t.paused
                ? Object.assign({}, t, { paused: false, expiresAt: now + t.remaining, remaining: 0 })
                : t)),
        });
    }

    function expire(state, now) {
        const gone = state.toasts.filter((t) => !t.paused && t.expiresAt <= now).map((t) => t.id);
        if (!gone.length) return { state, expired: [] };
        return { state: Object.assign({}, state, { toasts: state.toasts.filter((t) => !gone.includes(t.id)) }), expired: gone };
    }

    function nextExpiry(state) {
        let next = null;
        for (const t of state.toasts) {
            if (t.paused) continue;
            if (next === null || t.expiresAt < next) next = t.expiresAt;
        }
        return next;
    }

    function place(m) {
        const P = PLACEMENT;
        const n = (v, d) => (typeof v === 'number' && isFinite(v) ? v : d);
        const vw = Math.max(0, n(m && m.vw, 0));
        const vh = Math.max(0, n(m && m.vh, 0));
        const desktop = vw >= P.desktopMinWidth;
        const safeTop = Math.max(0, n(m && m.safeTop, 0));
        const headerBottom = Math.max(0, n(m && m.headerBottom, 0));
        const top = Math.round(Math.max(headerBottom, safeTop) + (desktop ? P.desktopGapPx : P.phoneGapPx));
        const composerTop = n(m && m.composerTop, vh);
        const floor = Math.min(vh - P.gutterPx, composerTop - P.composerGapPx);
        const maxHeight = Math.max(0, Math.round(floor - top));
        const minLeft = Math.max(P.gutterPx, n(m && m.safeLeft, 0));
        const maxRight = vw - Math.max(P.gutterPx, n(m && m.safeRight, 0));
        if (desktop) {
            const chatLeft = Math.max(0, n(m && m.chatLeft, 0));
            const chatRight = Math.min(vw, n(m && m.chatRight, vw));
            const right = Math.min(chatRight - P.gutterPx, maxRight);
            const width = Math.max(0, Math.min(P.desktopMaxWidthPx, right - Math.max(chatLeft + P.gutterPx, minLeft)));
            return { top, left: Math.round(right - width), width: Math.round(width), maxHeight, align: 'end' };
        }
        const room = Math.max(0, maxRight - minLeft);
        const width = Math.min(P.phoneMaxWidthPx, room);
        return { top, left: Math.round(minLeft + (room - width) / 2), width: Math.round(width), maxHeight, align: 'center' };
    }

    G.NymEventToasts = Object.freeze({
        CONFIG, PLACEMENT, TYPES, FOREGROUND_MODES, DEFAULTS, LABELS, SETTING_LABELS, FOREGROUND_LABELS, STRINGS, TOPICS, ONCE_LABELS, CALL_STRINGS,
        fill, normalizeSettings, patchSettings, category, decide, clip, present, systemBody, systemTitle, topicOf, entryTopic, isViewOnce, listBody, callLabel, callIsVideo, place,
        emptyState, add, addMany, dismiss, pause, resume, expire, nextExpiry,
    });
})();
