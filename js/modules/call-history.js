(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const CAP = 200;
    const PEER_RE = /^[0-9a-f]{64}$/;

    function empty(owner) {
        return { v: 1, owner: typeof owner === 'string' ? owner : '', seen: 0, items: [] };
    }

    function normalize(r) {
        if (!r || typeof r !== 'object' || Array.isArray(r)) return null;
        const id = typeof r.id === 'string' ? r.id : '';
        if (!id || id.length > 96) return null;
        const peer = typeof r.peer === 'string' ? r.peer : '';
        if (peer && !PEER_RE.test(peer)) return null;
        const group = typeof r.group === 'string' ? r.group : '';
        if (group.length > 128) return null;
        if (!peer && !group) return null;
        if (typeof r.at !== 'number' || !isFinite(r.at)) return null;
        const at = Math.floor(r.at);
        if (at <= 0) return null;
        const dir = r.dir === 'in' ? 'in' : 'out';
        const missed = dir === 'in' && r.missed === true;
        const rawDur = typeof r.dur === 'number' && isFinite(r.dur) ? Math.floor(r.dur) : 0;
        const dur = missed ? 0 : Math.max(0, rawDur);
        return { id, peer, group, kind: r.kind === 'video' ? 'video' : 'audio', dir, at, dur, missed };
    }

    function tidy(list) {
        const seen = new Set();
        const out = [];
        const sorted = list.slice().sort((a, b) => b.at - a.at);
        for (const r of sorted) {
            if (seen.has(r.id)) continue;
            seen.add(r.id);
            out.push(r);
            if (out.length >= CAP) break;
        }
        return out;
    }

    function decode(raw, owner) {
        const base = empty(owner);
        if (typeof raw !== 'string' || !raw) return base;
        let j;
        try { j = JSON.parse(raw); } catch (_) { return base; }
        if (!j || typeof j !== 'object' || j.owner !== base.owner || !base.owner) return base;
        const items = Array.isArray(j.items) ? j.items.map(normalize).filter(Boolean) : [];
        const seen = typeof j.seen === 'number' && isFinite(j.seen) && j.seen > 0 ? Math.floor(j.seen) : 0;
        return { v: 1, owner: base.owner, seen, items: tidy(items) };
    }

    function encode(store) {
        const s = store || empty('');
        return JSON.stringify({ v: 1, owner: s.owner, seen: s.seen, items: s.items });
    }

    function upsert(store, rec) {
        const s = store || empty('');
        const r = normalize(rec);
        const items = (s.items || []).slice();
        if (!r) return { v: 1, owner: s.owner, seen: s.seen, items };
        const rest = items.filter((x) => x.id !== r.id);
        return { v: 1, owner: s.owner, seen: s.seen, items: tidy([r].concat(rest)) };
    }

    function visible(store, hidden) {
        const s = store || empty('');
        const items = (s.items || []).slice();
        return typeof hidden === 'function' ? items.filter((r) => !hidden(r)) : items;
    }

    function missedCount(store, hidden) {
        const s = store || empty('');
        let n = 0;
        for (const r of visible(s, hidden)) if (r.missed && r.at > s.seen) n++;
        return n;
    }

    function markSeen(store, nowMs) {
        const s = store || empty('');
        return { v: 1, owner: s.owner, seen: Math.max(s.seen || 0, Math.floor(nowMs) || 0), items: (s.items || []).slice() };
    }

    function label(r) {
        if (r && r.missed) return 'missed';
        return r && r.dir === 'in' ? 'incoming' : 'outgoing';
    }

    function duration(sec) {
        const t = Math.max(0, Math.floor(Number(sec) || 0));
        if (!t) return '';
        const h = Math.floor(t / 3600);
        const m = Math.floor((t % 3600) / 60);
        const s = t % 60;
        const ss = String(s).padStart(2, '0');
        return h ? h + ':' + String(m).padStart(2, '0') + ':' + ss : m + ':' + ss;
    }

    G.NymCallHistory = Object.freeze({ CAP, empty, normalize, decode, encode, upsert, visible, missedCount, markSeen, label, duration });
})();
