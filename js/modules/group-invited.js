(function (root) {
    const DAY = 86400;

    const LIMITS = Object.freeze({
        expiry: 30 * DAY,
        skew: 600,
        max: 100,
        showExpired: true,
    });

    const KEYS = Object.freeze({
        field: 'invited',
    });

    const STRINGS = Object.freeze({
        invited: 'Invited',
        invitedLabel: '{nym}, invited, has not joined yet',
        expired: 'Invite expired',
        expiredLabel: '{nym}, invite expired, never joined',
        count: '{n} invited',
    });

    const STATUS = Object.freeze(['member', 'invited', 'expired']);
    const PK = /^[0-9a-f]{64}$/;

    const int = (x) => {
        const n = Math.floor(Number(x));
        return Number.isFinite(n) && n > 0 ? n : 0;
    };
    const obj = (x) => (x && typeof x === 'object' && !Array.isArray(x) ? x : {});
    const cmpStr = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

    function cap(map) {
        const keys = Object.keys(map);
        if (keys.length <= LIMITS.max) return map;
        keys.sort((a, b) => (map[b] - map[a]) || cmpStr(a, b));
        const out = {};
        for (const k of keys.slice(0, LIMITS.max).sort()) out[k] = map[k];
        return out;
    }

    function normalize(inv, members, self) {
        const src = obj(inv);
        const keep = Array.isArray(members) ? new Set(members) : null;
        const me = typeof self === 'string' ? self : '';
        const out = {};
        for (const pk of Object.keys(src).sort()) {
            const it = int(src[pk]);
            if (!it || !PK.test(pk) || pk === me) continue;
            if (keep && !keep.has(pk)) continue;
            out[pk] = it;
        }
        return cap(out);
    }

    function mark(inv, pks, it, self) {
        const out = Object.assign({}, normalize(inv, null, self));
        const t = int(it);
        if (t) {
            for (const pk of Array.isArray(pks) ? pks : []) {
                if (typeof pk !== 'string' || !PK.test(pk)) continue;
                if (!(out[pk] >= t)) out[pk] = t;
            }
        }
        return normalize(out, null, self);
    }

    function merge(a, b) {
        const out = Object.assign({}, normalize(a));
        const nb = normalize(b);
        for (const pk of Object.keys(nb)) if (!(out[pk] >= nb[pk])) out[pk] = nb[pk];
        return normalize(out);
    }

    function same(a, b) {
        return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
    }

    function status(x) {
        const s = obj(x);
        const it = int(s.it);
        if (!it) return 'member';
        const kt = int(s.keyTs);
        if (kt && kt > int(s.removedAt) && kt + LIMITS.skew >= it) return 'member';
        return int(s.now) - it > LIMITS.expiry ? 'expired' : 'invited';
    }

    function view(x) {
        const s = obj(x);
        const self = typeof s.self === 'string' ? s.self : '';
        const members = (Array.isArray(s.members) ? s.members : [])
            .filter((pk, i, a) => typeof pk === 'string' && pk && a.indexOf(pk) === i);
        const inv = normalize(s.invited, members, self);
        const keyTs = obj(s.keyTs);
        const removedAt = obj(s.removedAt);
        const out = { accepted: [], invited: [], expired: [], keep: {}, count: 0, waiting: 0, shown: [] };
        for (const pk of members) {
            const st = pk === self ? 'member' : status({ it: inv[pk], keyTs: keyTs[pk], removedAt: removedAt[pk], now: s.now });
            if (st === 'member') {
                out.accepted.push(pk);
                continue;
            }
            out[st].push(pk);
            out.keep[pk] = inv[pk];
        }
        out.count = out.accepted.length;
        out.waiting = out.invited.length + out.expired.length;
        out.shown = out.accepted.concat(out.invited, LIMITS.showExpired ? out.expired : []);
        return out;
    }

    function statusOf(v, pk) {
        if (!v || typeof pk !== 'string') return 'member';
        if (v.invited.indexOf(pk) >= 0) return 'invited';
        if (v.expired.indexOf(pk) >= 0) return 'expired';
        return 'member';
    }

    function trimKeyTs(keyTs, inv) {
        const src = {};
        for (const [k, v] of Object.entries(obj(keyTs))) {
            const t = int(v);
            if (t) src[k] = t;
        }
        const marks = normalize(inv);
        const dead = Object.keys(src).filter((pk) => marks[pk] && src[pk] + LIMITS.skew < marks[pk]);
        const order = Object.keys(src).sort((a, b) => (src[a] - src[b]) || cmpStr(a, b));
        const drop = new Set(dead.length ? dead : order.slice(0, Math.max(1, Math.ceil(order.length * 0.25))));
        const out = {};
        for (const pk of Object.keys(src).sort(cmpStr)) if (!drop.has(pk)) out[pk] = src[pk];
        return out;
    }

    root.NymGroupInvited = Object.freeze({
        LIMITS, KEYS, STRINGS, STATUS,
        normalize, mark, merge, same, status, view, statusOf, trimKeyTs,
    });
})(typeof self !== 'undefined' ? self : this);
