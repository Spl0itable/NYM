(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const CAPS = Object.freeze({ threadLastRead: 500, rsvpEvents: 300, reminders: 300, reminderRemoved: 300, callLinks: 50, calls: 200 });

    const STAMPED = Object.freeze({
        spamFilter: Object.freeze(['spamFilterEnabled', 'spamFilterAggressive']),
        hidePreviews: Object.freeze(['hidePreviews']),
        colorfulMessages: Object.freeze(['colorfulMessages']),
        pubkeyFormat: Object.freeze(['pubkeyFormat']),
        voiceSpeed: Object.freeze(['voiceSpeed']),
        keepCallHistory: Object.freeze(['keepCallHistory']),
        largeTargets: Object.freeze(['largeTargets']),
        highContrast: Object.freeze(['highContrast']),
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
        return {
            offset,
            start,
            title: typeof o.title === 'string' ? o.title : '',
            groupId: typeof o.groupId === 'string' ? o.groupId : '',
            fired: o.fired === true,
            t: Math.max(0, int(o.t)),
        };
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

    G.NymSyncMerge = Object.freeze({
        CAPS, STAMPED, prefTake, tsMapNorm, tsMapMerge, marksMerge, rsvpNorm, rsvpMerge,
        remindersNorm, remindersMerge, callLinkNorm, callLinksMerge, callsNorm, callsMerge, callsRowAction,
    });
})();
