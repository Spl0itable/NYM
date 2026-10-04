(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const LIMITS = Object.freeze({
        pinMax: 10,
        pinHardMax: 50,
        pinRemovedMax: 300,
        pinRemovedTtlMs: 180 * 24 * 60 * 60 * 1000,
        mentionChatsMax: 200,
        mentionPerChatMax: 100,
        mentionSeenMax: 300,
        scheduleMinLeadSec: 60,
        scheduleMaxAheadSec: 30 * 24 * 60 * 60,
        scheduleMaxPending: 50,
        scheduleMaxEvents: 260,
        scheduleMaxEventBytes: 70000,
        scheduleMaxItemBytes: 1000000,
        scheduleMaxUserBytes: 5000000,
        scheduleMaxRelays: 16,
        scheduleNoteMax: 16000,
        scheduleTextMax: 8000,
        scheduleAttempts: 4,
        scheduleRetrySec: 60,
        scheduleKeepDoneSec: 7 * 24 * 60 * 60,
        wrapJitterSec: 7200,
    });

    const KEYS = Object.freeze({
        pinnedDTag: 'nymchat-pinned',
        pinned: 'nym_pinned_chats',
        pinnedPending: 'nym_pinned_pending',
        mentions: 'nym_unread_mentions',
        scheduled: 'nym_scheduled_cache',
        seenMarks: 'nym_seen_marks',
    });

    const STRINGS = Object.freeze({
        newMessages: 'New messages',
        jumpFirst: 'Jump to first unread',
        nNew: '{n} new',
        mentions: 'Unread mentions',
        pin: 'Pin',
        unpin: 'Unpin',
        moveUp: 'Move up',
        moveDown: 'Move down',
        pinCap: 'You can pin up to {n} chats. Unpin one first.',
        pinned: 'Pinned',
        sendLater: 'Send later',
        scheduled: 'Scheduled',
        held: 'Held by Nymchat until it sends',
        heldDetail: 'Nymchat holds a copy that is already signed and, for DMs and groups, already encrypted. It cannot read or change it.',
        meshBlocked: "Send later needs the internet. This chat is on the Bluetooth mesh only.",
        offlineBlocked: "Send later needs the internet. You're offline.",
        signerBlocked: 'Send later in DMs and groups needs your key on this device.',
        serverBlocked: "Send later isn't available without the Nymchat server.",
        past: 'Pick a time in the future.',
        soon: 'Pick a time at least a minute from now.',
        far: 'You can schedule up to 30 days ahead.',
        full: 'You have too many scheduled messages. Cancel one first.',
        tooBig: 'This message is too large to schedule.',
        pending: 'Scheduled',
        sending: 'Sending',
        sent: 'Sent',
        failed: 'Failed',
        cancelled: 'Cancelled',
        sendNow: 'Send now',
        editTime: 'Edit time',
        cancel: 'Cancel',
    });

    const STATUSES = ['pending', 'sending', 'sent', 'failed', 'cancelled'];
    const RX_HEX64 = /^[0-9a-f]{64}$/;
    const RX_GROUP = /^[0-9a-f]{16,64}$/;
    const RX_CHANNEL = /^[\p{L}\p{N}]{1,64}$/u;

    function num(v) {
        const n = Number(v);
        return isFinite(n) ? n : 0;
    }

    function fill(s, vars) {
        let out = String(s);
        if (vars) for (const k of Object.keys(vars)) out = out.split('{' + k + '}').join(String(vars[k]));
        return out;
    }

    function cmpStr(a, b) {
        return a < b ? -1 : a > b ? 1 : 0;
    }

    function firstUnread(list, lastRead, opts) {
        const o = opts || {};
        const floor = num(lastRead);
        if (!(floor > 0) || !Array.isArray(list)) return null;
        const before = num(o.before);
        let index = -1;
        for (let i = 0; i < list.length; i++) {
            const m = list[i] || {};
            if (m.own || m.sys) continue;
            const at = num(m.at);
            if (at <= floor) continue;
            if (before > 0 && at > before) continue;
            index = i;
            break;
        }
        if (index < 0) return null;
        let count = 0;
        for (let i = index; i < list.length; i++) {
            const m = list[i] || {};
            if (m.own || m.sys) continue;
            if (num(m.at) > floor) count++;
        }
        const beyond = index === 0 && !!o.olderMayExist;
        if (beyond) count = Math.max(count, Math.floor(num(o.badge)));
        return { id: String(list[index].id || ''), index, count, beyond };
    }

    function landOnDivider(info) {
        return !!(info && info.id && !info.beyond);
    }

    function jumpLabel(info, t) {
        if (!info) return '';
        const tr = (s) => (typeof t === 'function' ? t(s) : s);
        if (info.beyond) return tr(STRINGS.jumpFirst);
        return fill(tr(STRINGS.nNew), { n: info.count });
    }

    function showJump(info, dividerAbove, dismissed) {
        return !!(info && info.id && dividerAbove && !dismissed);
    }

    const JUMP = Object.freeze({ bottomPx: 48, landPx: 8, markMax: 200, storeMax: 300, storeIds: 50 });
    const FABS = Object.freeze({ order: Object.freeze(['mention', 'jump', 'bottom']), gap: 8, right: 24, rightPhone: 16, rightColumn: 16, phoneMax: 768 });

    function markIndex(bottoms, viewTop, viewBottom, count) {
        const get = typeof bottoms === 'function' ? bottoms : (i) => num(bottoms[i]);
        const n = typeof bottoms === 'function' ? Math.max(0, Math.floor(num(count))) : (Array.isArray(bottoms) ? bottoms.length : 0);
        const vt = num(viewTop), vb = num(viewBottom);
        if (!(vb > vt) || n <= 0) return -1;
        let lo = 0, hi = n - 1, hit = -1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            if (get(mid) <= vb) { hit = mid; lo = mid + 1; } else hi = mid - 1;
        }
        return hit >= 0 && get(hit) > vt ? hit : -1;
    }

    function effectiveAt(createdAt, seenAt) {
        const c = Math.floor(num(createdAt));
        const s = Math.floor(num(seenAt));
        return s > 0 && s < c ? s : c;
    }

    function atBottom(distance) {
        return Math.abs(num(distance)) <= JUMP.bottomPx;
    }

    function jumpDir(o) {
        const r = o && typeof o === 'object' ? o : {};
        if (r.top !== undefined && r.top !== null && Number.isFinite(Number(r.top))) {
            return num(r.top) - num(r.viewTop) - JUMP.landPx > 0 ? 'down' : 'up';
        }
        return num(r.at) < num(r.firstAt) ? 'up' : 'down';
    }

    function fabRow(visible) {
        const v = visible || {};
        return FABS.order.filter((k) => !!v[k]);
    }

    function fabRight(width, column) {
        if (column) return FABS.rightColumn;
        return num(width) > 0 && num(width) <= FABS.phoneMax ? FABS.rightPhone : FABS.right;
    }

    function markNorm(raw) {
        const r = raw && typeof raw === 'object' ? raw : {};
        const at = Math.max(0, Math.floor(num(r.at)));
        const ids = [];
        if (at > 0) for (const id of (Array.isArray(r.ids) ? r.ids : [])) if (typeof id === 'string' && id && ids.indexOf(id) < 0) ids.push(id);
        return { at, ids: ids.length > JUMP.markMax ? ids.slice(ids.length - JUMP.markMax) : ids };
    }

    function markFloor(sec) {
        const s = Math.floor(num(sec));
        return s > 0 ? { at: s + 1, ids: [] } : { at: 0, ids: [] };
    }

    function markUnder(mark, at, id) {
        const m = mark && typeof mark === 'object' ? mark : {};
        const ma = Math.floor(num(m.at));
        if (!(ma > 0)) return false;
        const a = Math.floor(num(at));
        if (a < ma) return true;
        return a === ma && Array.isArray(m.ids) && m.ids.indexOf(id) >= 0;
    }

    function markAdvance(mark, at, ids) {
        const m = markNorm(mark);
        const a = Math.floor(num(at));
        if (!(a > 0) || a < m.at) return m;
        if (a > m.at) {
            m.at = a;
            m.ids = [];
        }
        for (const id of (Array.isArray(ids) ? ids : [])) if (typeof id === 'string' && id && m.ids.indexOf(id) < 0) m.ids.push(id);
        if (m.ids.length > JUMP.markMax) m.ids = m.ids.slice(m.ids.length - JUMP.markMax);
        return m;
    }

    function markMax(a, b) {
        const x = markNorm(a), y = markNorm(b);
        if (x.at !== y.at) return x.at > y.at ? x : y;
        return markAdvance(x, y.at, y.ids);
    }

    function unseenRows(list, mark) {
        const out = [];
        const m = markNorm(mark);
        if (!(m.at > 0) || !Array.isArray(list)) return out;
        for (const r of list) {
            if (!r || r.own || r.sys || !r.id) continue;
            if (markUnder(m, r.at, String(r.id))) continue;
            out.push(String(r.id));
        }
        return out;
    }

    function unseenCount(list, mark) {
        return unseenRows(list, mark).length;
    }

    function unseenFirst(list, mark) {
        const rows = unseenRows(list, mark);
        return rows.length ? rows[0] : null;
    }

    function jumpText(count, t) {
        const n = Math.max(0, Math.floor(num(count)));
        if (n <= 0) return '';
        const tr = (x) => (typeof t === 'function' ? t(x) : x);
        return fill(tr(STRINGS.nNew), { n });
    }

    function markStoreNorm(raw) {
        const out = {};
        if (!raw || typeof raw !== 'object') return out;
        const keys = Object.keys(raw).filter((k) => k && raw[k] && typeof raw[k] === 'object');
        keys.sort((a, b) => (num(raw[b].t) - num(raw[a].t)) || cmpStr(a, b));
        for (const k of keys.slice(0, JUMP.storeMax)) {
            const m = markNorm(raw[k]);
            if (!(m.at > 0)) continue;
            out[k] = { at: m.at, ids: m.ids.slice(-JUMP.storeIds), t: Math.max(0, Math.floor(num(raw[k].t))) };
        }
        return out;
    }

    function emptyMentions() {
        return { v: 1, chats: {} };
    }

    function normMentionChat(c) {
        const ids = [];
        const seenIds = new Set();
        if (c && Array.isArray(c.ids)) {
            for (const e of c.ids) {
                if (!e || typeof e.id !== 'string' || !e.id || seenIds.has(e.id)) continue;
                seenIds.add(e.id);
                ids.push({ id: e.id, at: Math.max(0, Math.floor(num(e.at))) });
            }
        }
        const seen = [];
        if (c && Array.isArray(c.seen)) {
            for (const s of c.seen) if (typeof s === 'string' && s && seen.indexOf(s) < 0) seen.push(s);
        }
        ids.sort((a, b) => (a.at - b.at) || cmpStr(a.id, b.id));
        return { ids, seen: seen.slice(-LIMITS.mentionSeenMax), t: Math.max(0, num(c && c.t)) };
    }

    function normalizeMentions(raw) {
        const out = emptyMentions();
        if (!raw || typeof raw !== 'object' || !raw.chats || typeof raw.chats !== 'object') return out;
        for (const k of Object.keys(raw.chats)) {
            if (!k) continue;
            out.chats[k] = normMentionChat(raw.chats[k]);
        }
        return out;
    }

    function pruneMentions(state) {
        const keys = Object.keys(state.chats);
        if (keys.length <= LIMITS.mentionChatsMax) return state;
        keys.sort((a, b) => (state.chats[b].t - state.chats[a].t) || cmpStr(a, b));
        const keep = {};
        for (const k of keys.slice(0, LIMITS.mentionChatsMax)) keep[k] = state.chats[k];
        state.chats = keep;
        return state;
    }

    function mentionAdd(state, key, items, nowMs) {
        const s = normalizeMentions(state);
        if (!key || !Array.isArray(items) || !items.length) return s;
        const c = s.chats[key] || normMentionChat(null);
        const have = new Set(c.ids.map((e) => e.id));
        const seen = new Set(c.seen);
        let changed = false;
        for (const it of items) {
            if (!it || typeof it.id !== 'string' || !it.id) continue;
            if (have.has(it.id) || seen.has(it.id)) continue;
            have.add(it.id);
            c.ids.push({ id: it.id, at: Math.max(0, Math.floor(num(it.at))) });
            changed = true;
        }
        if (!changed) return s;
        c.ids.sort((a, b) => (a.at - b.at) || cmpStr(a.id, b.id));
        if (c.ids.length > LIMITS.mentionPerChatMax) c.ids = c.ids.slice(c.ids.length - LIMITS.mentionPerChatMax);
        c.t = num(nowMs);
        s.chats[key] = c;
        return pruneMentions(s);
    }

    function markSeen(c, ids) {
        for (const id of ids) {
            const i = c.seen.indexOf(id);
            if (i >= 0) c.seen.splice(i, 1);
            c.seen.push(id);
        }
        if (c.seen.length > LIMITS.mentionSeenMax) c.seen = c.seen.slice(c.seen.length - LIMITS.mentionSeenMax);
    }

    function mentionSeen(state, key, id, nowMs) {
        const s = normalizeMentions(state);
        const c = s.chats[key];
        if (!c || !id) return s;
        c.ids = c.ids.filter((e) => e.id !== id);
        markSeen(c, [id]);
        c.t = num(nowMs);
        return s;
    }

    function mentionMark(state, key, mark, nowMs) {
        const s = normalizeMentions(state);
        const c = s.chats[key];
        if (!c || !c.ids.length) return s;
        const m = markNorm(mark);
        const drop = c.ids.filter((e) => markUnder(m, e.at, e.id)).map((e) => e.id);
        if (!drop.length) return s;
        c.ids = c.ids.filter((e) => drop.indexOf(e.id) < 0);
        markSeen(c, drop);
        c.t = num(nowMs);
        return s;
    }

    function mentionClear(state, key, nowMs) {
        const s = normalizeMentions(state);
        const c = s.chats[key];
        if (!c || !c.ids.length) return s;
        markSeen(c, c.ids.map((e) => e.id));
        c.ids = [];
        c.t = num(nowMs);
        return s;
    }

    function mentionPrune(state, key, floorSec) {
        const s = normalizeMentions(state);
        const c = s.chats[key];
        const f = num(floorSec);
        if (!c || !(f > 0)) return s;
        const drop = c.ids.filter((e) => e.at <= f).map((e) => e.id);
        if (!drop.length) return s;
        c.ids = c.ids.filter((e) => e.at > f);
        markSeen(c, drop);
        return s;
    }

    function mentionDrop(state, key, ids) {
        const s = normalizeMentions(state);
        const c = s.chats[key];
        if (!c || !Array.isArray(ids) || !ids.length) return s;
        const gone = new Set(ids);
        c.ids = c.ids.filter((e) => !gone.has(e.id));
        return s;
    }

    function mentionNext(state, key) {
        const s = normalizeMentions(state);
        const c = s.chats[key];
        return c && c.ids.length ? c.ids[0].id : null;
    }

    function mentionCount(state, key) {
        if (!key || !state || typeof state !== 'object' || !state.chats || typeof state.chats !== 'object') return 0;
        if (!Object.prototype.propertyIsEnumerable.call(state.chats, key)) return 0;
        return normMentionChat(state.chats[key]).ids.length;
    }

    function mentionScan(list, floorSec, beforeSec) {
        const out = [];
        const f = num(floorSec);
        const b = num(beforeSec);
        if (!Array.isArray(list)) return out;
        for (const m of list) {
            if (!m || !m.mention || m.own || m.sys || !m.id) continue;
            const at = num(m.at);
            if (at <= f) continue;
            if (b > 0 && at > b) continue;
            out.push({ id: String(m.id), at: Math.floor(at) });
        }
        return out;
    }

    function pinKey(kind, id) {
        const raw = String(id == null ? '' : id).trim();
        if (kind === 'dm') {
            const pk = raw.toLowerCase();
            return RX_HEX64.test(pk) ? 'd:' + pk : '';
        }
        if (kind === 'group') {
            const g = raw.toLowerCase();
            return RX_GROUP.test(g) ? 'g:' + g : '';
        }
        if (kind === 'channel') {
            const c = raw.replace(/^#/, '').toLowerCase();
            return RX_CHANNEL.test(c) ? 'c:' + c : '';
        }
        return '';
    }

    function pinParse(k) {
        const s = String(k || '');
        if (s.indexOf('d:') === 0 && RX_HEX64.test(s.slice(2))) return { kind: 'dm', id: s.slice(2) };
        if (s.indexOf('g:') === 0 && RX_GROUP.test(s.slice(2))) return { kind: 'group', id: s.slice(2) };
        if (s.indexOf('c:') === 0 && RX_CHANNEL.test(s.slice(2))) return { kind: 'channel', id: s.slice(2) };
        return null;
    }

    function pinKeyForChat(chatKey) {
        const k = String(chatKey || '');
        if (k.indexOf('pm-') === 0) return pinKey('dm', k.slice(3));
        if (k.indexOf('group-') === 0) return pinKey('group', k.slice(6));
        return pinKey('channel', k);
    }

    function emptyPins() {
        return { v: 1, order: [], ot: 0, items: {}, removed: {} };
    }

    function normalizePins(raw) {
        const out = emptyPins();
        if (!raw || typeof raw !== 'object') return out;
        if (raw.items && typeof raw.items === 'object' && !Array.isArray(raw.items)) {
            for (const [k, v] of Object.entries(raw.items)) {
                const at = num(v);
                if (pinParse(k) && at > 0) out.items[k] = Math.floor(at);
            }
        }
        if (raw.removed && typeof raw.removed === 'object' && !Array.isArray(raw.removed)) {
            for (const [k, v] of Object.entries(raw.removed)) {
                const at = num(v);
                if (pinParse(k) && at > 0) out.removed[k] = Math.floor(at);
            }
        }
        if (Array.isArray(raw.order)) {
            for (const k of raw.order) if (typeof k === 'string' && pinParse(k) && out.order.indexOf(k) < 0) out.order.push(k);
        }
        out.ot = Math.max(0, Math.floor(num(raw.ot)));
        return finishPins(out, 0);
    }

    function pinnedSet(s) {
        const set = new Set();
        for (const [k, at] of Object.entries(s.items)) if (!(s.removed[k] >= at)) set.add(k);
        return set;
    }

    function finishPins(s, nowMs) {
        const live = pinnedSet(s);
        const items = {};
        for (const k of live) items[k] = s.items[k];
        let order = s.order.filter((k) => live.has(k));
        const rest = [...live].filter((k) => order.indexOf(k) < 0)
            .sort((a, b) => (items[b] - items[a]) || cmpStr(a, b));
        order = order.concat(rest);
        if (order.length > LIMITS.pinHardMax) {
            for (const k of order.slice(LIMITS.pinHardMax)) delete items[k];
            order = order.slice(0, LIMITS.pinHardMax);
        }
        const removed = {};
        const cutoff = num(nowMs) > 0 ? num(nowMs) - LIMITS.pinRemovedTtlMs : 0;
        for (const [k, at] of Object.entries(s.removed)) {
            if (items[k] !== undefined) continue;
            if (cutoff > 0 && at < cutoff) continue;
            removed[k] = at;
        }
        const rk = Object.keys(removed);
        if (rk.length > LIMITS.pinRemovedMax) {
            rk.sort((a, b) => (removed[b] - removed[a]) || cmpStr(a, b));
            for (const k of rk.slice(LIMITS.pinRemovedMax)) delete removed[k];
        }
        return { v: 1, order, ot: s.ot, items, removed };
    }

    function pinList(state) {
        return normalizePins(state).order.slice();
    }

    function isPinned(state, k) {
        return normalizePins(state).order.indexOf(k) >= 0;
    }

    function pinAdd(state, k, nowMs, opts) {
        const s = normalizePins(state);
        if (!pinParse(k)) return { state: s, error: 'invalid' };
        if (s.order.indexOf(k) >= 0) return { state: s, error: null };
        const cap = opts && num(opts.cap) > 0 ? num(opts.cap) : LIMITS.pinMax;
        if (s.order.length >= cap) return { state: s, error: 'cap' };
        const at = Math.max(num(nowMs), (s.removed[k] || 0) + 1, (s.items[k] || 0) + 1);
        s.items[k] = at;
        delete s.removed[k];
        s.order = [k].concat(s.order);
        s.ot = Math.max(num(nowMs), s.ot + 1);
        return { state: finishPins(s, nowMs), error: null };
    }

    function pinRemove(state, k, nowMs) {
        const s = normalizePins(state);
        if (s.order.indexOf(k) < 0) return s;
        s.removed[k] = Math.max(num(nowMs), (s.items[k] || 0) + 1);
        s.order = s.order.filter((x) => x !== k);
        s.ot = Math.max(num(nowMs), s.ot + 1);
        return finishPins(s, nowMs);
    }

    function pinMove(state, k, toIndex, nowMs) {
        const s = normalizePins(state);
        const from = s.order.indexOf(k);
        if (from < 0) return s;
        const to = Math.max(0, Math.min(s.order.length - 1, Math.floor(num(toIndex))));
        if (to === from) return s;
        s.order.splice(from, 1);
        s.order.splice(to, 0, k);
        s.ot = Math.max(num(nowMs), s.ot + 1);
        return finishPins(s, nowMs);
    }

    function pinReorderWithin(state, subset, nowMs) {
        const s = normalizePins(state);
        const want = (Array.isArray(subset) ? subset : []).filter((k) => s.order.indexOf(k) >= 0);
        if (want.length < 2) return s;
        const slots = [];
        s.order.forEach((k, i) => { if (want.indexOf(k) >= 0) slots.push(i); });
        const next = s.order.slice();
        slots.forEach((slot, i) => { next[slot] = want[i]; });
        if (next.join('\n') === s.order.join('\n')) return s;
        s.order = next;
        s.ot = Math.max(num(nowMs), s.ot + 1);
        return finishPins(s, nowMs);
    }

    function mergePins(a, b, nowMs) {
        const x = normalizePins(a);
        const y = normalizePins(b);
        const items = Object.assign({}, x.items);
        for (const [k, at] of Object.entries(y.items)) if (!(items[k] >= at)) items[k] = at;
        const removed = Object.assign({}, x.removed);
        for (const [k, at] of Object.entries(y.removed)) if (!(removed[k] >= at)) removed[k] = at;
        let base;
        if (x.ot !== y.ot) base = x.ot > y.ot ? x : y;
        else base = JSON.stringify(x.order) >= JSON.stringify(y.order) ? x : y;
        return finishPins({ v: 1, order: base.order.slice(), ot: Math.max(x.ot, y.ot), items, removed }, nowMs);
    }

    function pinImportLegacy(state, channels, nowMs) {
        const s = normalizePins(state);
        let changed = false;
        for (const c of (Array.isArray(channels) ? channels : [])) {
            const k = pinKey('channel', c);
            if (!k || k === 'c:nymchat') continue;
            if (s.items[k] !== undefined || s.removed[k] !== undefined) continue;
            s.items[k] = 1;
            s.order.push(k);
            changed = true;
        }
        return changed ? finishPins(s, nowMs) : s;
    }

    function pinChannels(state) {
        const out = [];
        for (const k of normalizePins(state).order) {
            const p = pinParse(k);
            if (p && p.kind === 'channel') out.push(p.id);
        }
        return out;
    }

    function pinSort(keys, state) {
        const order = normalizePins(state).order;
        const pos = new Map(order.map((k, i) => [k, i]));
        const list = (Array.isArray(keys) ? keys : []).map((k, i) => ({ k, i, p: pos.has(pinKeyForChat(k)) ? pos.get(pinKeyForChat(k)) : -1 }));
        list.sort((a, b) => {
            if (a.p >= 0 && b.p >= 0) return a.p - b.p;
            if (a.p >= 0) return -1;
            if (b.p >= 0) return 1;
            return a.i - b.i;
        });
        return list.map((e) => e.k);
    }

    function trimPinnedPayload(p) {
        const s = p && p.pinnedChats;
        if (!s || typeof s !== 'object') return false;
        const rk = s.removed ? Object.keys(s.removed) : [];
        if (rk.length > 20) {
            rk.sort((a, b) => s.removed[a] - s.removed[b]);
            for (const k of rk.slice(0, Math.ceil(rk.length / 4))) delete s.removed[k];
            return true;
        }
        if (Array.isArray(s.order) && s.order.length > LIMITS.pinMax) {
            const drop = s.order.slice(LIMITS.pinMax);
            s.order = s.order.slice(0, LIMITS.pinMax);
            for (const k of drop) if (s.items) delete s.items[k];
            return true;
        }
        return false;
    }

    function scheduleCheck(atSec, nowSec) {
        const at = num(atSec);
        const now = num(nowSec);
        if (!(at > 0) || at <= now) return 'past';
        if (at < now + LIMITS.scheduleMinLeadSec) return 'soon';
        if (at > now + LIMITS.scheduleMaxAheadSec) return 'far';
        return null;
    }

    function scheduleErrorText(code, t) {
        const tr = (s) => (typeof t === 'function' ? t(s) : s);
        const map = { past: STRINGS.past, soon: STRINGS.soon, far: STRINGS.far, full: STRINGS.full, big: STRINGS.tooBig };
        return map[code] ? tr(map[code]) : '';
    }

    function localParts(ms, offsetMin) {
        const d = new Date(num(ms) + num(offsetMin) * 60000);
        return { y: d.getUTCFullYear(), mo: d.getUTCMonth(), d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), wd: d.getUTCDay() };
    }

    function localToSec(y, mo, d, h, mi, offsetMin) {
        return Math.floor((Date.UTC(y, mo, d, h, mi, 0) - num(offsetMin) * 60000) / 1000);
    }

    function schedulePresets(nowMs, offsetMin) {
        const nowSec = Math.floor(num(nowMs) / 1000);
        const p = localParts(nowMs, offsetMin);
        const out = [];
        const hour = Math.ceil((nowSec + 3600) / 60) * 60;
        out.push({ id: 'hour', at: hour });
        const tonight = localToSec(p.y, p.mo, p.d, 21, 0, offsetMin);
        if (scheduleCheck(tonight, nowSec) === null && tonight > hour) out.push({ id: 'tonight', at: tonight });
        const tomorrow = localToSec(p.y, p.mo, p.d + 1, 9, 0, offsetMin);
        out.push({ id: 'tomorrow', at: tomorrow });
        const ahead = ((1 - p.wd) + 7) % 7 || 7;
        const monday = localToSec(p.y, p.mo, p.d + ahead, 9, 0, offsetMin);
        if (monday !== tomorrow) out.push({ id: 'monday', at: monday });
        return out;
    }

    function scheduleInputValue(atSec, offsetMin) {
        const p = localParts(num(atSec) * 1000, offsetMin);
        const pad = (n) => String(n).padStart(2, '0');
        return `${p.y}-${pad(p.mo + 1)}-${pad(p.d)}T${pad(p.h)}:${pad(p.mi)}`;
    }

    function scheduleParseInput(value, offsetMin) {
        const m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})$/.exec(String(value || '').trim());
        if (!m) return 0;
        const y = +m[1], mo = +m[2] - 1, d = +m[3], h = +m[4], mi = +m[5];
        if (mo < 0 || mo > 11 || d < 1 || d > 31 || h > 23 || mi > 59) return 0;
        return localToSec(y, mo, d, h, mi, offsetMin);
    }

    function wrapTime(atSec, r) {
        const f = Math.min(Math.max(num(r), 0), 0.999999);
        return Math.round(num(atSec) - f * LIMITS.wrapJitterSec);
    }

    function scheduleRelays(list) {
        const out = [];
        for (const raw of (Array.isArray(list) ? list : [])) {
            if (typeof raw !== 'string') continue;
            let u;
            try { u = new URL(raw.trim()); } catch (_) { continue; }
            if (u.protocol !== 'wss:') continue;
            const s = 'wss://' + u.host.toLowerCase() + (u.pathname && u.pathname !== '/' ? u.pathname.replace(/\/+$/, '') : '');
            if (out.indexOf(s) < 0) out.push(s);
            if (out.length >= LIMITS.scheduleMaxRelays) break;
        }
        return out;
    }

    function scheduleSizeError(events, noteLen) {
        const list = Array.isArray(events) ? events : [];
        if (!list.length) return 'empty';
        if (list.length > LIMITS.scheduleMaxEvents) return 'big';
        let total = 0;
        for (const e of list) {
            const n = JSON.stringify(e && e.e ? e.e : e).length;
            if (n > LIMITS.scheduleMaxEventBytes) return 'big';
            total += n;
        }
        total += num(noteLen);
        if (total > LIMITS.scheduleMaxItemBytes) return 'big';
        return null;
    }

    function scheduleNoteJson(text, chat) {
        const c = chat || {};
        return JSON.stringify({ v: 1, text: String(text || '').slice(0, LIMITS.scheduleTextMax), chat: { t: String(c.t || ''), k: String(c.k || '') } });
    }

    function scheduleNoteParse(json) {
        try {
            const o = JSON.parse(json);
            if (!o || o.v !== 1 || typeof o.text !== 'string') return null;
            const c = o.chat && typeof o.chat === 'object' ? o.chat : {};
            return { text: o.text, chat: { t: String(c.t || ''), k: String(c.k || '') } };
        } catch (_) { return null; }
    }

    function scheduleChatKey(chat) {
        const c = chat || {};
        if (c.t === 'dm') return 'pm-' + String(c.k || '').toLowerCase();
        if (c.t === 'group') return 'group-' + String(c.k || '');
        if (c.t === 'channel') return '#' + String(c.k || '').replace(/^#/, '').toLowerCase();
        return '';
    }

    function scheduleChatOf(chatKey) {
        const k = String(chatKey || '');
        if (k.indexOf('pm-') === 0) return { t: 'dm', k: k.slice(3).toLowerCase() };
        if (k.indexOf('group-') === 0) return { t: 'group', k: k.slice(6) };
        return { t: 'channel', k: k.replace(/^#/, '').toLowerCase() };
    }

    function scheduleNormalize(items) {
        const out = [];
        for (const it of (Array.isArray(items) ? items : [])) {
            if (!it || typeof it.id !== 'string' || !it.id) continue;
            const status = STATUSES.indexOf(it.status) >= 0 ? it.status : 'pending';
            out.push({
                id: it.id,
                at: Math.floor(num(it.at)),
                chat: { t: String((it.chat && it.chat.t) || ''), k: String((it.chat && it.chat.k) || '') },
                status,
                attempts: Math.floor(num(it.attempts)),
                error: typeof it.error === 'string' ? it.error : '',
                sentAt: Math.floor(num(it.sentAt)),
                note: typeof it.note === 'string' ? it.note : '',
            });
        }
        out.sort((a, b) => (a.at - b.at) || cmpStr(a.id, b.id));
        return out;
    }

    function scheduleForChat(items, chatKey) {
        return scheduleNormalize(items).filter((it) => scheduleChatKey(it.chat) === chatKey && it.status !== 'cancelled');
    }

    function scheduleOpenCount(items, chatKey) {
        return scheduleForChat(items, chatKey).filter((it) => it.status === 'pending' || it.status === 'sending' || it.status === 'failed').length;
    }

    function scheduleStatusText(status, t) {
        const tr = (s) => (typeof t === 'function' ? t(s) : s);
        const map = { pending: STRINGS.pending, sending: STRINGS.sending, sent: STRINGS.sent, failed: STRINGS.failed, cancelled: STRINGS.cancelled };
        return tr(map[status] || STRINGS.pending);
    }

    function scheduleBlockReason(ctx) {
        const c = ctx || {};
        if (c.meshOnly) return STRINGS.meshBlocked;
        if (!c.server) return STRINGS.serverBlocked;
        if (!c.online) return STRINGS.offlineBlocked;
        if ((c.kind === 'dm' || c.kind === 'group') && !c.localKey) return STRINGS.signerBlocked;
        return null;
    }

    const PIN_GESTURE = Object.freeze({ armMs: 350, slop: 10, edgePx: 48, maxStep: 14 });

    function pinGestureIdle() {
        return { phase: 'idle', key: '', x0: 0, y0: 0, x: 0, y: 0 };
    }

    function pinGestureLocks(st) {
        return !!st && (st.phase === 'armed' || st.phase === 'dragging');
    }

    function pinGestureStep(st, ev) {
        const s = Object.assign(pinGestureIdle(), st || {});
        const e = ev || {};
        const fx = [];
        const idle = () => pinGestureIdle();
        const far = () => Math.abs(num(e.x) - s.x0) > PIN_GESTURE.slop || Math.abs(num(e.y) - s.y0) > PIN_GESTURE.slop;
        if (e.t === 'down') {
            if (e.pointer === 'mouse' || !e.key) return { state: idle(), fx };
            fx.push({ t: 'wait', ms: PIN_GESTURE.armMs });
            return { state: { phase: 'pending', key: String(e.key), x0: num(e.x), y0: num(e.y), x: num(e.x), y: num(e.y) }, fx };
        }
        if (s.phase === 'idle') return { state: s, fx };
        if (e.t === 'cancel') {
            if (s.phase !== 'pending') fx.push({ t: 'abort', key: s.key });
            return { state: idle(), fx };
        }
        if (e.t === 'arm') {
            if (s.phase !== 'pending') return { state: s, fx };
            fx.push({ t: 'armed', key: s.key });
            return { state: Object.assign(s, { phase: 'armed' }), fx };
        }
        if (e.t === 'move') {
            if (s.phase === 'pending') return far() ? { state: idle(), fx } : { state: s, fx };
            s.x = num(e.x);
            s.y = num(e.y);
            if (s.phase === 'armed') {
                if (!far()) return { state: s, fx };
                s.phase = 'dragging';
                fx.push({ t: 'start', key: s.key });
            }
            fx.push({ t: 'over', key: s.key, x: s.x, y: s.y, dy: s.y - s.y0 });
            return { state: s, fx };
        }
        if (e.t === 'up') {
            if (s.phase === 'armed') fx.push({ t: 'menu', key: s.key, x: s.x0, y: s.y0 });
            if (s.phase === 'dragging') fx.push({ t: 'drop', key: s.key, x: num(e.x), y: num(e.y) });
            return { state: idle(), fx };
        }
        return { state: s, fx };
    }

    function pinAutoScroll(y, top, bottom) {
        const edge = PIN_GESTURE.edgePx;
        const up = num(y) - num(top);
        const down = num(bottom) - num(y);
        if (up < edge) return -Math.ceil(PIN_GESTURE.maxStep * (edge - Math.max(0, up)) / edge);
        if (down < edge) return Math.ceil(PIN_GESTURE.maxStep * (edge - Math.max(0, down)) / edge);
        return 0;
    }

    function groupSubjectTags(name) {
        return typeof name === 'string' && name.length ? [['subject', name]] : [];
    }

    function scheduleId(bytes) {
        const b = bytes || [];
        let s = '';
        for (let i = 0; i < b.length && i < 16; i++) s += (b[i] & 255).toString(16).padStart(2, '0');
        return s;
    }

    G.NymChatNav = {
        LIMITS, KEYS, STRINGS, STATUSES,
        firstUnread, landOnDivider, jumpLabel, showJump,
        JUMP, FABS, markIndex, effectiveAt, atBottom, jumpDir, fabRow, fabRight, markNorm, markFloor, markUnder, markAdvance, markMax,
        unseenRows, unseenCount, unseenFirst, jumpText, markStoreNorm,
        emptyMentions, normalizeMentions, mentionAdd, mentionSeen, mentionMark, mentionClear, mentionPrune, mentionDrop,
        mentionNext, mentionCount, mentionScan,
        pinKey, pinParse, pinKeyForChat, emptyPins, normalizePins, pinList, isPinned, pinAdd, pinRemove,
        pinMove, pinReorderWithin, mergePins, pinImportLegacy, pinChannels, pinSort, trimPinnedPayload,
        scheduleCheck, scheduleErrorText, schedulePresets, scheduleInputValue, scheduleParseInput, wrapTime,
        scheduleRelays, scheduleSizeError, scheduleNoteJson, scheduleNoteParse, scheduleChatKey, scheduleChatOf,
        scheduleNormalize, scheduleForChat, scheduleOpenCount, scheduleStatusText, scheduleBlockReason, scheduleId, groupSubjectTags,
        PIN_GESTURE, pinGestureIdle, pinGestureLocks, pinGestureStep, pinAutoScroll,
    };
})();
