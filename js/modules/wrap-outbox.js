(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const TIER = Object.freeze({ critical: 0, normal: 1, bulk: 2 });

    const CRITICAL_TYPES = Object.freeze([
        'group-invite',
        'group-join-request',
        'group-join-declined',
        'group-join-pending',
        'group-join-waiting',
        'group-join-resolved',
        'group-roster',
        'group-roster-req',
        'group-history',
        'group-remove-member',
        'group-transfer-owner',
    ]);

    const BULK_TYPES = Object.freeze([
        'group-metadata',
    ]);

    const RELAY_BUCKET = Object.freeze({ capacity: 160, perMinute: 100 });
    const DEPOSIT_BUCKET = Object.freeze({ capacity: 100, perMinute: 480 });

    function wrapTier(info) {
        const i = info || {};
        if (i.toNew === true) return TIER.critical;
        const kind = Number(i.kind);
        if (kind !== 14 && kind !== 15) return TIER.bulk;
        const type = typeof i.type === 'string' && i.type ? i.type : null;
        if (type === 'key-resync') return i.resyncReq === true ? TIER.bulk : TIER.critical;
        if (type && CRITICAL_TYPES.includes(type)) return TIER.critical;
        if (type && BULK_TYPES.includes(type)) return TIER.bulk;
        if (type) return TIER.normal;
        return Number(i.fanout) > 1 ? TIER.normal : TIER.critical;
    }

    function bucketTake(state, nowMs, units, cfg, force) {
        const cap = Number(cfg && cfg.capacity) || 0;
        const perMinute = Number(cfg && cfg.perMinute) || 0;
        const n = Number(units) > 0 ? Number(units) : 0;
        const now = Number(nowMs) || 0;
        const prev = state && Number.isFinite(state.tokens) ? state : { tokens: cap, at: now };
        const elapsed = Math.max(0, now - (Number(prev.at) || 0));
        const tokens = Math.min(cap, prev.tokens + elapsed * perMinute / 60000);
        if (tokens >= n || force === true) {
            return { ok: true, waitMs: 0, state: { tokens: tokens - n, at: now } };
        }
        const waitMs = perMinute > 0 ? Math.ceil((n - tokens) * 60000 / perMinute) : 60000;
        return { ok: false, waitMs, state: { tokens, at: now } };
    }

    function bucketAvailable(state, nowMs, cfg) {
        const r = bucketTake(state, nowMs, 0, cfg);
        return Math.max(0, Math.floor(r.state.tokens));
    }

    function _valid(entries) {
        return (Array.isArray(entries) ? entries : []).filter(e => e && typeof e.id === 'string' && e.id);
    }

    function _tierOf(e) {
        const t = Number(e.tier);
        return t === 0 || t === 1 || t === 2 ? t : TIER.normal;
    }

    function _bySeq(a, b) {
        return (Number(a.seq) || 0) - (Number(b.seq) || 0);
    }

    function queueEvict(entries, cap) {
        const list = _valid(entries);
        const over = list.length - Math.max(0, Math.floor(Number(cap) || 0));
        if (over <= 0) return { keep: list.map(e => e.id), evicted: [] };
        const order = list.slice().sort((a, b) => (_tierOf(b) - _tierOf(a)) || _bySeq(a, b));
        const gone = new Set();
        const evicted = [];
        for (let i = 0; i < over; i++) {
            gone.add(order[i]);
            evicted.push(order[i].id);
        }
        return { keep: list.filter(e => !gone.has(e)).map(e => e.id), evicted };
    }

    function tierOrder(entries, rand) {
        const list = _valid(entries).slice().sort((a, b) => (_tierOf(a) - _tierOf(b)) || _bySeq(a, b));
        const r = Array.isArray(rand) ? rand.filter(x => Number.isInteger(x) && x >= 0) : [];
        if (!r.length) return list.map(e => e.id);
        let k = 0;
        let start = 0;
        while (start < list.length) {
            let end = start;
            const t = _tierOf(list[start]);
            while (end < list.length && _tierOf(list[end]) === t) end++;
            for (let i = end - 1; i > start; i--) {
                const j = start + (r[k % r.length] % (i - start + 1));
                k++;
                const tmp = list[i];
                list[i] = list[j];
                list[j] = tmp;
            }
            start = end;
        }
        return list.map(e => e.id);
    }

    G.NymWrapOutbox = Object.freeze({
        TIER,
        CRITICAL_TYPES,
        BULK_TYPES,
        RELAY_BUCKET,
        DEPOSIT_BUCKET,
        wrapTier,
        bucketTake,
        bucketAvailable,
        queueEvict,
        tierOrder,
    });
})();
