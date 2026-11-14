(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const CAPS = Object.freeze({ threadLastRead: 500, rsvpEvents: 300, reminders: 300, reminderRemoved: 300, callLinks: 50, calls: 200, reportedTargets: 200 });

    const STAMPED = Object.freeze({
        spamFilter: Object.freeze(['spamFilterEnabled', 'spamFilterAggressive']),
        hidePreviews: Object.freeze(['hidePreviews']),
        colorfulMessages: Object.freeze(['colorfulMessages']),
        pubkeyFormat: Object.freeze(['pubkeyFormat']),
        voiceSpeed: Object.freeze(['voiceSpeed']),
        keepCallHistory: Object.freeze(['keepCallHistory']),
        largeTargets: Object.freeze(['largeTargets']),
        highContrast: Object.freeze(['highContrast']),
        sidebarChannelsMode: Object.freeze(['sidebarChannelsMode']),
        theme: Object.freeze(['theme']),
        colorMode: Object.freeze(['colorMode']),
        uiLanguage: Object.freeze(['uiLanguage']),
        chatLayout: Object.freeze(['chatLayout']),
        chatViewMode: Object.freeze(['chatViewMode']),
        columnsWallpaper: Object.freeze(['columnsWallpaper']),
        wallpaperType: Object.freeze(['wallpaperType', 'wallpaperCustomUrl']),
        transparencyEnabled: Object.freeze(['transparencyEnabled']),
        textSize: Object.freeze(['textSize']),
        showTimestamps: Object.freeze(['showTimestamps']),
        timeFormat: Object.freeze(['timeFormat']),
        dateFormat: Object.freeze(['dateFormat']),
        nickStyle: Object.freeze(['nickStyle']),
        sound: Object.freeze(['sound']),
        blurOthersImages: Object.freeze(['blurOthersImages']),
        autoscroll: Object.freeze(['autoscroll']),
        dmForwardSecrecyEnabled: Object.freeze(['dmForwardSecrecyEnabled']),
        dmTTLSeconds: Object.freeze(['dmTTLSeconds']),
        readReceiptsScope: Object.freeze(['readReceiptsScope', 'readReceiptsEnabled']),
        typingIndicatorsScope: Object.freeze(['typingIndicatorsScope', 'typingIndicatorsEnabled']),
        acceptPMs: Object.freeze(['acceptPMs']),
        acceptCalls: Object.freeze(['acceptCalls']),
        showStatus: Object.freeze(['showStatus']),
        channelCounts: Object.freeze(['channelCounts']),
        powDifficulty: Object.freeze(['powDifficulty']),
        appVerifiedFilter: Object.freeze(['appVerifiedFilter']),
        filterPacks: Object.freeze(['filterPacks']),
        remotePanic: Object.freeze(['remotePanic']),
        groupChatPMOnlyMode: Object.freeze(['groupChatPMOnlyMode']),
        threadsEnabled: Object.freeze(['threadsEnabled']),
        translateLanguage: Object.freeze(['translateLanguage']),
        gesturesEnabled: Object.freeze(['gesturesEnabled']),
        swipeLeftAction: Object.freeze(['swipeLeftAction']),
        swipeRightAction: Object.freeze(['swipeRightAction']),
        swipeThreshold: Object.freeze(['swipeThreshold']),
        hoverActions: Object.freeze(['hoverActions']),
        sortByProximity: Object.freeze(['sortByProximity']),
        pinnedLandingChannel: Object.freeze(['pinnedLandingChannel']),
        hideNonPinned: Object.freeze(['hideNonPinned']),
        lowDataMode: Object.freeze(['lowDataMode']),
        backgroundConnectivity: Object.freeze(['backgroundConnectivity', 'backgroundConnectivityChosen']),
        cachePMs: Object.freeze(['cachePMs']),
        addedRelays: Object.freeze(['addedRelays']),
        columnsLayout: Object.freeze(['columnsLayout']),
        notificationsEnabled: Object.freeze(['notificationsEnabled']),
        notifyFriendsOnly: Object.freeze(['notifyFriendsOnly']),
        groupNotifyMentionsOnly: Object.freeze(['groupNotifyMentionsOnly']),
        threadNotifyMentionsOnly: Object.freeze(['threadNotifyMentionsOnly']),
        eventToasts: Object.freeze(['eventToasts']),
        sidebarSectionOrder: Object.freeze(['sidebarSectionOrder']),
        lightningAddress: Object.freeze(['lightningAddress']),
        syncMLSHistory: Object.freeze(['syncMLSHistory']),
        encryptAtRestPreferred: Object.freeze(['encryptAtRestPreferred']),
        botMaxRuns: Object.freeze(['botMaxRuns']),
        botAnonEnabled: Object.freeze(['botAnonEnabled']),
        botProModel: Object.freeze(['botProModel']),
        streetDetail: Object.freeze(['streetDetail']),
    });

    const RX_EVENT = /^[0-9a-f]{16}$/;
    const RX_HEX64 = /^[0-9a-f]{64}$/;
    const RSVP = ['going', 'maybe', 'no'];
    const OFFSETS = [0, 10, 60, 1440];

    function int(v) {
        return typeof v === 'number' && isFinite(v) ? Math.floor(v) : 0;
    }

    function obj(v) {
        return v && typeof v === 'object' && !Array.isArray(v) ? v : {};
    }

    function cmpStr(a, b) {
        return a < b ? -1 : a > b ? 1 : 0;
    }

    function prefTake(localTs, remoteTs) {
        return int(remoteTs) >= int(localTs);
    }

    function fpCanon(v) {
        if (v === null || v === undefined) return 'null';
        if (typeof v === 'number') return isFinite(v) ? (Number.isInteger(v) ? String(v) : JSON.stringify(v)) : 'null';
        if (typeof v === 'boolean') return v ? 'true' : 'false';
        if (typeof v === 'string') return JSON.stringify(v);
        if (Array.isArray(v)) return '[' + v.map(fpCanon).join(',') + ']';
        if (typeof v === 'object') return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + fpCanon(v[k])).join(',') + '}';
        return 'null';
    }

    function prefFp(payload, keys) {
        const src = obj(payload);
        const text = fpCanon((Array.isArray(keys) ? keys : []).map((k) => src[k]));
        let h = 0x811c9dc5;
        const add = (b) => { h = Math.imul(h ^ b, 0x01000193) >>> 0; };
        for (const ch of text) {
            let c = ch.codePointAt(0);
            if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
            if (c < 0x80) add(c);
            else if (c < 0x800) { add(0xc0 | (c >> 6)); add(0x80 | (c & 63)); }
            else if (c < 0x10000) { add(0xe0 | (c >> 12)); add(0x80 | ((c >> 6) & 63)); add(0x80 | (c & 63)); }
            else { add(0xf0 | (c >> 18)); add(0x80 | ((c >> 12) & 63)); add(0x80 | ((c >> 6) & 63)); add(0x80 | (c & 63)); }
        }
        return h.toString(16).padStart(8, '0');
    }

    function prefRowStamp(payload, rowTs, stamped) {
        const out = Object.assign({}, obj(payload));
        const at = Math.max(0, int(rowTs));
        const map = obj(stamped || STAMPED);
        const own = (k) => Object.prototype.hasOwnProperty.call(out, k);
        for (const name of Object.keys(map)) {
            const keys = Array.isArray(map[name]) ? map[name] : [];
            if (!keys.some(own)) continue;
            const ts = name + 'Ts';
            const fp = name + 'Fp';
            if (own(ts) && (!own(fp) || out[fp] === prefFp(out, keys))) continue;
            if (!own(ts) && at <= 0) continue;
            out[ts] = at;
            delete out[fp];
        }
        return out;
    }

    function prefGate(payload, stamps, stamped, rowTs) {
        const src = prefRowStamp(payload, rowTs, stamped);
        const local = obj(stamps);
        const map = obj(stamped || STAMPED);
        const out = Object.assign({}, src);
        const take = {};
        let skipped = false;
        for (const name of Object.keys(map)) {
            const keys = Array.isArray(map[name]) ? map[name] : [];
            if (!keys.some((k) => Object.prototype.hasOwnProperty.call(src, k))) continue;
            const remote = src[name + 'Ts'];
            if (prefTake(local[name], remote)) {
                take[name] = int(remote);
                continue;
            }
            for (const k of keys) delete out[k];
            delete out[name + 'Ts'];
            delete out[name + 'Fp'];
            skipped = true;
        }
        return { payload: out, take, skipped };
    }

    function tsMapNorm(raw, cap) {
        const src = obj(raw);
        const rows = [];
        for (const k of Object.keys(src)) {
            const v = int(src[k]);
            if (k && v > 0) rows.push([k, v]);
        }
        rows.sort((x, y) => (y[1] - x[1]) || cmpStr(x[0], y[0]));
        const out = {};
        const lim = typeof cap === 'number' && isFinite(cap) ? Math.max(0, Math.floor(cap)) : rows.length;
        for (const [k, v] of rows.slice(0, lim)) out[k] = v;
        return out;
    }

    function tsMapMerge(a, b, cap) {
        const x = tsMapNorm(a);
        const y = tsMapNorm(b);
        const out = Object.assign({}, x);
        for (const k of Object.keys(y)) if (!(k in out) || y[k] > out[k]) out[k] = y[k];
        return tsMapNorm(out, cap);
    }

    function marksMerge(a, b) {
        const N = G.NymChatNav;
        const x = N.markStoreNorm(obj(a));
        const y = N.markStoreNorm(obj(b));
        const out = {};
        for (const k of new Set(Object.keys(x).concat(Object.keys(y)))) {
            if (!x[k]) { out[k] = y[k]; continue; }
            if (!y[k]) { out[k] = x[k]; continue; }
            const m = N.markMax(x[k], y[k]);
            out[k] = { at: m.at, ids: m.ids, t: Math.max(x[k].t, y[k].t) };
        }
        return N.markStoreNorm(out);
    }

    function rsvpNorm(raw) {
        const out = {};
        const src = obj(raw);
        for (const id of Object.keys(src)) {
            if (!RX_EVENT.test(id)) continue;
            const ev = obj(src[id]);
            const entries = {};
            for (const pk of Object.keys(ev)) {
                const e = obj(ev[pk]);
                const ts = int(e.ts);
                if (!RX_HEX64.test(pk) || RSVP.indexOf(e.s) < 0 || ts <= 0) continue;
                entries[pk] = { s: e.s, ts };
            }
            if (Object.keys(entries).length) out[id] = entries;
        }
        return out;
    }

    function rsvpNewest(ev) {
        let n = 0;
        for (const pk of Object.keys(ev)) n = Math.max(n, ev[pk].ts);
        return n;
    }

    function rsvpMerge(a, b) {
        const x = rsvpNorm(a);
        const y = rsvpNorm(b);
        const all = {};
        for (const src of [x, y]) {
            for (const id of Object.keys(src)) {
                const ev = all[id] || (all[id] = {});
                for (const pk of Object.keys(src[id])) {
                    const e = src[id][pk];
                    const cur = ev[pk];
                    if (!cur || e.ts > cur.ts || (e.ts === cur.ts && e.s > cur.s)) ev[pk] = { s: e.s, ts: e.ts };
                }
            }
        }
        const ids = Object.keys(all);
        ids.sort((p, q) => (rsvpNewest(all[q]) - rsvpNewest(all[p])) || cmpStr(p, q));
        const out = {};
        for (const id of ids.slice(0, CAPS.rsvpEvents)) out[id] = all[id];
        return out;
    }

    function reminderNorm(r) {
        const o = obj(r);
        const offset = int(o.offset);
        const start = int(o.start);
        if (typeof o.offset !== 'number' || OFFSETS.indexOf(offset) < 0 || start <= 0) return null;
        const out = {
            offset,
            start,
            title: typeof o.title === 'string' ? o.title : '',
            groupId: typeof o.groupId === 'string' ? o.groupId : '',
            fired: o.fired === true,
            t: Math.max(0, int(o.t)),
        };
        if (typeof o.by === 'string' && /^[0-9a-f]{64}$/i.test(o.by)) out.by = o.by.toLowerCase();
        return out;
    }

    function remindersNorm(raw) {
        const o = obj(raw);
        const items = {};
        const src = obj(o.items);
        for (const id of Object.keys(src)) {
            if (!RX_EVENT.test(id)) continue;
            const r = reminderNorm(src[id]);
            if (r) items[id] = r;
        }
        const removed = {};
        const rm = tsMapNorm(o.removed);
        for (const id of Object.keys(rm)) if (RX_EVENT.test(id)) removed[id] = rm[id];
        return { items, removed };
    }

    function remindersMerge(a, b) {
        const x = remindersNorm(a);
        const y = remindersNorm(b);
        const removed = tsMapMerge(x.removed, y.removed);
        const items = Object.assign({}, x.items);
        for (const id of Object.keys(y.items)) {
            const cur = items[id];
            const r = y.items[id];
            if (!cur || r.t > cur.t) items[id] = r;
            else if (r.t === cur.t && r.fired && !cur.fired) items[id] = Object.assign({}, cur, { fired: true });
        }
        for (const id of Object.keys(items)) {
            if (removed[id] === undefined) continue;
            if (removed[id] >= items[id].t) delete items[id];
            else delete removed[id];
        }
        const ids = Object.keys(items);
        ids.sort((p, q) => (items[q].t - items[p].t) || (items[q].start - items[p].start) || cmpStr(p, q));
        const outItems = {};
        for (const id of ids.slice(0, CAPS.reminders)) outItems[id] = items[id];
        return { items: outItems, removed: tsMapNorm(removed, CAPS.reminderRemoved) };
    }

    function callLinkNorm(l) {
        if (!l || typeof l !== 'object' || Array.isArray(l)) return null;
        if (typeof l.id !== 'string' || typeof l.host !== 'string' || typeof l.kind !== 'string') return null;
        if (typeof l.secret !== 'string') return null;
        const out = {
            id: l.id,
            host: l.host,
            kind: l.kind === 'video' ? 'video' : 'audio',
            exp: int(l.exp),
            secret: l.secret,
            name: l.name === undefined || l.name === null ? '' : String(l.name),
        };
        if (typeof l.groupId === 'string') out.groupId = l.groupId;
        if (l.revoked === true) out.revoked = true;
        const created = int(l.createdAt);
        if (created > 0) out.createdAt = created;
        return out;
    }

    function callLinksMerge(a, b) {
        const byId = new Map();
        for (const list of [a, b]) {
            if (!Array.isArray(list)) continue;
            for (const raw of list) {
                const l = callLinkNorm(raw);
                if (!l) continue;
                const cur = byId.get(l.id);
                if (!cur) byId.set(l.id, l);
                else if (l.revoked && !cur.revoked) byId.set(l.id, Object.assign({}, cur, { revoked: true }));
            }
        }
        const out = [...byId.values()];
        out.sort((p, q) => ((q.createdAt || 0) - (p.createdAt || 0)) || cmpStr(p.id, q.id));
        return out.slice(0, CAPS.callLinks);
    }

    function callPick(x, y) {
        if (x.missed !== y.missed) return x.missed ? y : x;
        if (x.dur !== y.dur) return x.dur > y.dur ? x : y;
        if (x.at !== y.at) return x.at > y.at ? x : y;
        return x;
    }

    function callsNorm(raw) {
        const o = obj(raw);
        const H = G.NymCallHistory;
        const items = Array.isArray(o.items) ? o.items.map((r) => H.normalize(r)).filter(Boolean) : [];
        return { clearedAt: Math.max(0, int(o.clearedAt)), seen: Math.max(0, int(o.seen)), items };
    }

    function callsMerge(a, b) {
        const x = callsNorm(a);
        const y = callsNorm(b);
        const clearedAt = Math.max(x.clearedAt, y.clearedAt);
        const byId = new Map();
        for (const r of x.items.concat(y.items)) {
            const cur = byId.get(r.id);
            byId.set(r.id, cur ? callPick(cur, r) : r);
        }
        const items = [...byId.values()].filter((r) => r.at > clearedAt);
        items.sort((p, q) => (q.at - p.at) || cmpStr(p.id, q.id));
        return { clearedAt, seen: Math.max(x.seen, y.seen), items: items.slice(0, CAPS.calls) };
    }

    function callsRowAction(keep, keepTs, row) {
        const present = !!row && typeof row === 'object' && !Array.isArray(row);
        if (keep) return present ? 'apply' : 'none';
        if (!present) return 'clear';
        return int(row.keepTs) > Math.max(0, int(keepTs)) ? 'wait' : 'delete';
    }

    const SETS = Object.freeze({
        blockedUsers: '', friends: '', blockedKeywords: '', blockedChannels: '', hiddenChannels: '', pinnedChannels: '',
        userJoinedChannels: '', translateFavoriteLanguages: '', emojiPackFavorites: '', emojiCategoryFavorites: '',
        favoriteGifs: 'url', blockedEmojiPacks: 'coord',
    });
    const SET_SUFFIX = 'Set';
    const SET_SEED = 1;
    const SET_TOMBSTONE_MS = 90 * 86400000;
    const SET_REMOVED_CAP = 100;

    function setKeyOf(name, el) {
        const field = SETS[name];
        if (field) {
            const v = el && typeof el === 'object' && !Array.isArray(el) ? el[field] : '';
            return typeof v === 'string' ? v : '';
        }
        return typeof el === 'string' ? el : '';
    }

    function setKeys(name, list) {
        const out = [];
        const seen = new Set();
        for (const el of Array.isArray(list) ? list : []) {
            const k = setKeyOf(name, el);
            if (!k || seen.has(k)) continue;
            seen.add(k);
            out.push(k);
        }
        return out;
    }

    function setSettle(a, r, now) {
        for (const k of Object.keys(a)) {
            if (r[k] === undefined) continue;
            if (r[k] >= a[k]) delete a[k];
            else delete r[k];
        }
        const floor = int(now) - SET_TOMBSTONE_MS;
        for (const k of Object.keys(r)) if (r[k] < floor) delete r[k];
        return { a: tsMapNorm(a), r: tsMapNorm(r, SET_REMOVED_CAP) };
    }

    function setState(raw, now) {
        const o = obj(raw);
        return setSettle(tsMapNorm(o.a), tsMapNorm(o.r), now);
    }

    function setObserve(raw, name, list, now) {
        const keys = setKeys(name, list);
        if (raw === null || raw === undefined) {
            const a = {};
            for (const k of keys) a[k] = SET_SEED;
            return setSettle(a, {}, now);
        }
        const s = setState(raw, now);
        const t = Math.max(1, int(now));
        const has = new Set(keys);
        for (const k of keys) {
            if (s.a[k] !== undefined) continue;
            s.a[k] = Math.max(t, int(s.r[k]) + 1);
            delete s.r[k];
        }
        for (const k of Object.keys(s.a)) {
            if (has.has(k)) continue;
            s.r[k] = Math.max(t, s.a[k] + 1);
            delete s.a[k];
        }
        return setSettle(s.a, s.r, now);
    }

    function setAdopt(raw, name, list, now) {
        const s = setState(raw, now);
        const keys = setKeys(name, list);
        const a = {};
        const r = Object.assign({}, s.r);
        for (const k of keys) {
            a[k] = s.a[k] !== undefined ? s.a[k] : SET_SEED;
            delete r[k];
        }
        return setSettle(a, r, now);
    }

    function setFp(name, list) {
        return prefFp({ [name]: Array.isArray(list) ? list : [] }, [name]);
    }

    function setWire(raw, name, list) {
        const s = obj(raw);
        const a = obj(s.a);
        const l = Array.isArray(list) ? list : [];
        return {
            f: setFp(name, l),
            a: l.map((el) => { const t = int(a[setKeyOf(name, el)]); return t > 0 ? t : SET_SEED; }),
            r: tsMapNorm(s.r, SET_REMOVED_CAP),
        };
    }

    function setWireValid(name, list, wire) {
        const w = obj(wire);
        const l = Array.isArray(list) ? list : [];
        return typeof w.f === 'string' && w.f === setFp(name, l) && Array.isArray(w.a) && w.a.length === l.length;
    }

    function setRowStamp(payload, rowTs) {
        const out = Object.assign({}, obj(payload));
        const at = Math.max(0, int(rowTs));
        if (at <= 0) return out;
        for (const name of Object.keys(SETS)) {
            const wk = name + SET_SUFFIX;
            if (!Array.isArray(out[name])) continue;
            if (setWireValid(name, out[name], out[wk])) continue;
            out[wk] = { f: setFp(name, out[name]), a: out[name].map(() => at), r: tsMapNorm(obj(out[wk]).r, SET_REMOVED_CAP), w: at };
        }
        return out;
    }

    function setRemote(name, list, wire, now) {
        const w = obj(wire);
        const l = Array.isArray(list) ? list : [];
        const r = tsMapNorm(w.r);
        const a = {};
        if (setWireValid(name, l, w)) {
            l.forEach((el, i) => {
                const k = setKeyOf(name, el);
                const t = Math.max(SET_SEED, int(w.a[i]));
                if (k && !(a[k] >= t)) a[k] = t;
            });
            return { a, r, w: Math.max(0, int(w.w)) };
        }
        const at = Math.max(1, int(now));
        for (const k of setKeys(name, l)) a[k] = at;
        return { a, r, w: at };
    }

    function setMerge(local, remote, now) {
        const x = obj(local);
        const y = obj(remote);
        const a = Object.assign({}, tsMapNorm(x.a));
        const r = Object.assign({}, tsMapNorm(x.r));
        const ya = tsMapNorm(y.a);
        const yr = tsMapNorm(y.r);
        for (const k of Object.keys(ya)) if (!(a[k] >= ya[k])) a[k] = ya[k];
        for (const k of Object.keys(yr)) if (!(r[k] >= yr[k])) r[k] = yr[k];
        const w = Math.max(0, int(y.w));
        if (w > 0) {
            for (const k of Object.keys(a)) {
                if (ya[k] !== undefined || a[k] > w) continue;
                if (!(r[k] >= w)) r[k] = w;
            }
        }
        return setSettle(a, r, now);
    }

    function setList(name, state, remoteList, localList) {
        const live = obj(obj(state).a);
        const out = [];
        const seen = new Set();
        for (const src of [remoteList, localList]) {
            for (const el of Array.isArray(src) ? src : []) {
                const k = setKeyOf(name, el);
                if (!k || seen.has(k) || live[k] === undefined) continue;
                seen.add(k);
                out.push(el);
            }
        }
        return out;
    }

    function setGate(payload, states, lists, now) {
        const out = Object.assign({}, obj(payload));
        const local = obj(states);
        const mine = obj(lists);
        const next = {};
        let behind = false;
        for (const name of Object.keys(SETS)) {
            const wk = name + SET_SUFFIX;
            const hasWire = !!out[wk] && typeof out[wk] === 'object' && !Array.isArray(out[wk]);
            if (!Array.isArray(out[name]) && !hasWire) continue;
            const list = Array.isArray(out[name]) ? out[name] : [];
            const own = Array.isArray(mine[name]) ? mine[name] : [];
            const merged = setMerge(setObserve(local[name], name, own, now), setRemote(name, list, out[wk], now), now);
            const result = setList(name, merged, list, own);
            const got = setKeys(name, result);
            const want = new Set(setKeys(name, list));
            if (got.length !== want.size || got.some((k) => !want.has(k))) behind = true;
            out[name] = result;
            delete out[wk];
            next[name] = merged;
        }
        return { payload: out, states: next, behind };
    }

    function setWires(payload, states) {
        const out = {};
        const src = obj(payload);
        const st = obj(states);
        for (const name of Object.keys(SETS)) {
            if (!(name in src) && st[name] === undefined) continue;
            out[name + SET_SUFFIX] = setWire(st[name], name, Array.isArray(src[name]) ? src[name] : []);
        }
        return out;
    }

    function setShed(p) {
        let best = '';
        let most = 0;
        for (const name of Object.keys(SETS)) {
            const w = p[name + SET_SUFFIX];
            const n = w && typeof w === 'object' ? Object.keys(obj(w.r)).length : 0;
            if (n > most) { best = name; most = n; }
        }
        if (best) {
            const w = p[best + SET_SUFFIX];
            const r = tsMapNorm(w.r);
            const keys = Object.keys(r);
            const kept = {};
            for (const k of keys.slice(0, keys.length - Math.max(1, Math.floor(keys.length / 4)))) kept[k] = r[k];
            p[best + SET_SUFFIX] = Object.assign({}, w, { r: kept });
            return true;
        }
        let big = '';
        let size = -1;
        for (const name of Object.keys(SETS)) {
            const w = p[name + SET_SUFFIX];
            if (!w || typeof w !== 'object') continue;
            const n = Array.isArray(w.a) ? w.a.length : 0;
            if (n > size) { big = name; size = n; }
        }
        if (!big) return false;
        delete p[big + SET_SUFFIX];
        return true;
    }

    function setRealign(before, after) {
        const out = Object.assign({}, obj(after));
        const b = obj(before);
        for (const name of Object.keys(SETS)) {
            const wk = name + SET_SUFFIX;
            if (!out[wk] || typeof out[wk] !== 'object') continue;
            const list = Array.isArray(out[name]) ? out[name] : [];
            if (setWireValid(name, list, out[wk])) continue;
            const bl = Array.isArray(b[name]) ? b[name] : [];
            const bw = obj(b[wk]);
            const a = {};
            if (setWireValid(name, bl, bw)) bl.forEach((el, i) => { const k = setKeyOf(name, el); if (k) a[k] = int(bw.a[i]); });
            out[wk] = setWire({ a, r: obj(out[wk]).r }, name, list);
        }
        return out;
    }

    const COL = 'columnsLayout';
    const COL_WIRE = 'columnsLayoutSet';

    function colKey(d) {
        if (!d || typeof d !== 'object' || Array.isArray(d)) return '';
        const str = (v) => (typeof v === 'string' ? v : '');
        const low = (s) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());
        if (d.type === 'channel') { const id = str(d.geohash) || str(d.channel); return id ? 'channel:' + low(id) : ''; }
        if (d.type === 'pm') { const pk = str(d.pubkey); return pk ? 'pm:' + low(pk) : ''; }
        if (d.type === 'group') { const g = str(d.groupId); return g ? 'group:' + g : ''; }
        return '';
    }

    function colItems(list) {
        const out = new Map();
        for (const d of Array.isArray(list) ? list : []) {
            const k = colKey(d);
            if (k && !out.has(k)) out.set(k, d);
        }
        return out;
    }

    function colForm(d) {
        const str = (v) => (typeof v === 'string' ? v : '');
        return setFp(COL, [str(d.type), str(d.channel), str(d.geohash), str(d.pubkey), str(d.nym), str(d.groupId)]);
    }

    function colForms(items, a) {
        const h = {};
        for (const [k, d] of items) if (a[k] !== undefined) h[k] = colForm(d);
        return h;
    }

    function colKeyList(raw) {
        const out = [];
        for (const k of Array.isArray(raw) ? raw : []) if (typeof k === 'string' && k && !out.includes(k)) out.push(k);
        return out;
    }

    function colSettle(a, r, w, o, k, now) {
        const wipe = Math.max(0, int(w));
        for (const key of Object.keys(a)) {
            if (r[key] !== undefined && r[key] >= a[key]) { delete a[key]; continue; }
            delete r[key];
            if (a[key] < wipe) delete a[key];
        }
        const floor = int(now) - SET_TOMBSTONE_MS;
        for (const key of Object.keys(r)) if (r[key] < floor) delete r[key];
        const an = tsMapNorm(a);
        return { a: an, r: tsMapNorm(r, SET_REMOVED_CAP), w: wipe, o: Math.max(0, int(o)), k: colKeyList(k).filter((x) => an[x] !== undefined) };
    }

    function colState(raw, now) {
        const o = obj(raw);
        return colSettle(Object.assign({}, tsMapNorm(o.a)), Object.assign({}, tsMapNorm(o.r)), o.w, o.o, o.k, now);
    }

    function colOrder(st) {
        const out = [];
        const seen = new Set();
        for (const k of st.k) {
            if (st.a[k] === undefined || st.a[k] > st.o || seen.has(k)) continue;
            seen.add(k);
            out.push(k);
        }
        const rest = Object.keys(st.a).filter((k) => !seen.has(k)).sort((x, y) => (st.a[x] - st.a[y]) || cmpStr(x, y));
        return out.concat(rest);
    }

    function colObserve(raw, list, now, resetAt, stamp) {
        const items = colItems(list);
        const keys = [...items.keys()];
        const t = Math.max(1, int(now));
        const fresh = !raw || typeof raw !== 'object' || Array.isArray(raw);
        const s = fresh ? null : colState(raw, now);
        const was = fresh ? {} : obj(raw.h);
        const w = Math.max(fresh ? Math.max(0, int(stamp)) : s.w, Math.max(0, int(resetAt)));
        const a = fresh ? {} : Object.assign({}, s.a);
        const r = fresh ? {} : Object.assign({}, s.r);
        for (const k of keys) {
            if (fresh) { a[k] = Math.max(SET_SEED, w); continue; }
            if (a[k] !== undefined && a[k] >= w) {
                if (typeof was[k] === 'string' && was[k] !== colForm(items.get(k))) a[k] = Math.max(t, a[k] + 1);
                continue;
            }
            a[k] = Math.max(t, (r[k] || 0) + 1, w);
            delete r[k];
        }
        if (!fresh) {
            for (const k of Object.keys(a)) {
                if (items.has(k)) continue;
                r[k] = Math.max(t, a[k] + 1);
                delete a[k];
            }
        }
        const st = colSettle(a, r, w, fresh ? (keys.length ? Math.max(1, int(stamp)) : 0) : s.o, fresh ? keys : s.k, now);
        if (colOrder(st).join('\n') !== keys.join('\n')) { st.o = t; st.k = keys; }
        st.h = colForms(items, st.a);
        return st;
    }

    function colWire(st, list, ts) {
        const s = obj(st);
        const a = obj(s.a);
        const l = Array.isArray(list) ? list : [];
        return {
            f: setFp(COL, l),
            t: Math.max(0, int(ts)),
            a: l.map((el) => { const v = int(a[colKey(el)]); return v > 0 ? v : SET_SEED; }),
            r: tsMapNorm(s.r, SET_REMOVED_CAP),
            w: Math.max(0, int(s.w)),
            o: Math.max(0, int(s.o)),
            k: colKeyList(s.k),
        };
    }

    function colWireValid(list, wire, ts) {
        const w = obj(wire);
        return typeof w.f === 'string' && w.f === setFp(COL, list) && typeof w.t === 'number' && int(w.t) === ts
            && Array.isArray(w.a) && w.a.length === list.length;
    }

    function colRemote(list, wire, now) {
        const a = {};
        list.forEach((el, i) => {
            const k = colKey(el);
            const v = Math.max(SET_SEED, int(wire.a[i]));
            if (k && (a[k] === undefined || a[k] < v)) a[k] = v;
        });
        return colSettle(a, Object.assign({}, tsMapNorm(wire.r)), wire.w, wire.o, wire.k, now);
    }

    function colMerge(L, li, R, ri, now) {
        const a = Object.assign({}, L.a);
        const r = Object.assign({}, L.r);
        for (const k of Object.keys(R.a)) if (a[k] === undefined || a[k] < R.a[k]) a[k] = R.a[k];
        for (const k of Object.keys(R.r)) if (r[k] === undefined || r[k] < R.r[k]) r[k] = R.r[k];
        const win = R.o > L.o || (R.o === L.o && cmpStr(R.k.join('\n'), L.k.join('\n')) > 0) ? R : L;
        const st = colSettle(a, r, Math.max(L.w, R.w), win.o, win.k, now);
        const list = [];
        for (const k of colOrder(st)) {
            const dl = li.get(k);
            const dr = ri.get(k);
            const la = L.a[k] || 0;
            const ra = R.a[k] || 0;
            const d = dr !== undefined && (dl === undefined || ra > la || (ra === la && cmpStr(fpCanon(dr), fpCanon(dl)) > 0)) ? dr : dl;
            if (d !== undefined) list.push(d);
        }
        return { state: st, list };
    }

    const colSame = (x, y) => fpCanon({ a: x.a, w: x.w, o: x.o, k: x.k }) === fpCanon({ a: y.a, w: y.w, o: y.o, k: y.k });

    function colGate(payload, raw, localList, stamp, resetAt, rowTs, now) {
        const out = Object.assign({}, prefRowStamp(payload, rowTs, { [COL]: [COL] }));
        const wire = out[COL_WIRE];
        delete out[COL_WIRE];
        const list = out[COL];
        if (!Array.isArray(list)) return { payload: out, state: null, list: null, stamp: 0, behind: false };
        const ts = Math.max(0, int(out[COL + 'Ts']));
        delete out[COL];
        delete out[COL + 'Ts'];
        delete out[COL + 'Fp'];
        const mine = Array.isArray(localList) ? localList : [];
        const L = colObserve(raw, mine, now, resetAt, stamp);
        const li = colItems(mine);
        const ri = colItems(list);
        let R;
        if (colWireValid(list, wire, ts)) R = colRemote(list, obj(wire), now);
        else if (!prefTake(stamp, ts)) return { payload: out, state: L, list: null, stamp: 0, behind: true };
        else if (fpCanon(list) === fpCanon(mine)) R = L;
        else {
            const a = {};
            for (const k of ri.keys()) a[k] = Math.max(SET_SEED, ts);
            R = colSettle(a, {}, ts, Math.max(1, ts), [...ri.keys()], now);
        }
        const m = colMerge(L, li, R, ri, now);
        m.state.h = colForms(colItems(m.list), m.state.a);
        const at = Math.max(int(stamp), ts);
        out[COL] = m.list;
        out[COL + 'Ts'] = at;
        const behind = fpCanon(m.list) !== fpCanon(list) || !colSame(m.state, R);
        return { payload: out, state: m.state, list: m.list, stamp: at, behind };
    }

    G.NymSyncMerge = Object.freeze({
        COL_WIRE, colKey, colObserve, colWire, colGate,
        CAPS, STAMPED, prefTake, prefFp, prefRowStamp, prefGate, tsMapNorm, tsMapMerge, marksMerge, rsvpNorm, rsvpMerge,
        remindersNorm, remindersMerge, callLinkNorm, callLinksMerge, callsNorm, callsMerge, callsRowAction,
        SETS, SET_SUFFIX, SET_SEED, SET_TOMBSTONE_MS, SET_REMOVED_CAP, setKeyOf, setKeys, setObserve, setAdopt, setWire, setRowStamp,
        setRemote, setMerge, setList, setGate, setWires, setShed, setRealign,
    });
})();
