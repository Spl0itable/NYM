(function (root) {
    const KIND = 20001;
    const FUTURE_SKEW_SEC = 600;
    const SINCE_WINDOW_SEC = 120;
    const MAX_SEND_PRECISION = 5;
    const FIRST_DELAY_MS = [2000, 5000];
    const LOOP_DELAY_MS = [40000, 80000];
    const TAIL_DELAY_MS = [5000, 120000];
    const CHANNEL_CAP = 500;
    const NAMED_BUSY_THRESHOLD = 50;
    const NAMED_MAX_LOOP_MS = 240000;
    const ANON_SPACING_MS = 5000;
    const WINNING_STATUSES = ['away', 'hidden', 'offline'];
    const LISTING_STATUSES = ['online', 'active'];
    const GEOHASH_RE = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
    const HEX64_RE = /^[0-9a-f]{64}$/;
    const NAME_RE = /^[\p{L}\p{N}]+$/u;
    const UPPER_OR_TITLE_RE = /[\p{Lu}\p{Lt}]/u;
    const asciiLower = (v) => v.replace(/[A-Z]/g, (c) => c.toLowerCase());

    function config() {
        return {
            kind: KIND,
            futureSkewSec: FUTURE_SKEW_SEC,
            sinceWindowSec: SINCE_WINDOW_SEC,
            maxSendPrecision: MAX_SEND_PRECISION,
            firstDelayMs: FIRST_DELAY_MS.slice(),
            loopDelayMs: LOOP_DELAY_MS.slice(),
            tailDelayMs: TAIL_DELAY_MS.slice(),
            channelCap: CHANNEL_CAP,
            winningStatuses: WINNING_STATUSES.slice(),
            namedBusyThreshold: NAMED_BUSY_THRESHOLD,
            namedMaxLoopMs: NAMED_MAX_LOOP_MS,
            anonSpacingMs: ANON_SPACING_MS,
        };
    }

    function isGeohash(g) {
        return typeof g === 'string' && GEOHASH_RE.test(g);
    }

    function isChannelName(name) {
        if (typeof name !== 'string' || !name) return false;
        const lower = name.toLowerCase();
        return NAME_RE.test(lower) && !isGeohash(lower);
    }

    function firstTag(tags, name) {
        if (!Array.isArray(tags)) return null;
        for (const t of tags) {
            if (Array.isArray(t) && t[0] === name) return t;
        }
        return null;
    }

    const refuse = (reason) => ({ ok: false, reason, atMs: 0 });

    function accept(ev, ctx) {
        const c = ctx || {};
        if (!ev || typeof ev !== 'object' || ev.kind !== KIND) return refuse('kind');
        if (typeof ev.pubkey !== 'string' || !HEX64_RE.test(ev.pubkey)) return refuse('pubkey');
        if (c.verified !== true) return refuse('sig');
        if (typeof ev.content !== 'string' || ev.content.trim() !== '') return refuse('content');
        const g = firstTag(ev.tags, 'g');
        const d = firstTag(ev.tags, 'd');
        if (!g === !d) return refuse('tags');
        const channel = typeof c.channel === 'string' ? c.channel.toLowerCase() : '';
        if (c.type === 'named') {
            const dv = d && typeof d[1] === 'string' ? d[1].toLowerCase() : '';
            if (!isChannelName(dv) || dv !== channel) return refuse('name');
        } else {
            const gv = g && typeof g[1] === 'string' ? g[1].toLowerCase() : '';
            if (!isGeohash(gv) || gv !== channel) return refuse('geohash');
        }
        const at = ev.created_at;
        if (typeof at !== 'number' || !Number.isInteger(at) || at <= 0) return refuse('time');
        const nowMs = typeof c.nowMs === 'number' ? c.nowMs : Date.now();
        const nowSec = Math.floor(nowMs / 1000);
        if (at > nowSec + FUTURE_SKEW_SEC) return refuse('future');
        if (Array.isArray(c.own) && c.own.includes(ev.pubkey)) return refuse('own');
        if (Array.isArray(c.excluded) && c.excluded.includes(ev.pubkey)) return refuse('excluded');
        return { ok: true, reason: 'ok', atMs: Math.min(at * 1000, nowMs) };
    }

    const num = (v) => (typeof v === 'number' && Number.isFinite(v) && v > 0) ? v : 0;

    function activity(input) {
        const o = input || {};
        const nowMs = num(o.nowMs);
        const prev = Math.min(num(o.prevSeenMs), nowMs);
        const at = Math.min(num(o.geoAtMs), nowMs);
        const hidden = o.status === 'hidden';
        const shown = (seen) => (hidden ? 0 : seen);
        if (at <= 0) return { counts: false, seenMs: prev, shownSeenMs: shown(prev) };
        if (WINNING_STATUSES.includes(o.status) && num(o.statusAtMs) >= at) {
            return { counts: false, seenMs: prev, shownSeenMs: shown(prev) };
        }
        const seen = Math.max(prev, at);
        return { counts: true, seenMs: seen, shownSeenMs: shown(seen) };
    }

    function listsFromPresence(known, status) {
        return known === true || LISTING_STATUSES.includes(status);
    }

    function sendPlan(input) {
        const o = input || {};
        const no = (reason) => ({ send: false, reason, key: null });
        if (o.type === 'named') {
            if (!isChannelName(o.name)) return no('not-named');
        } else if (o.type === 'geohash') {
            if (!isGeohash(o.geohash)) return no('not-geohash');
            if (o.geohash.length > MAX_SEND_PRECISION) return no('precision');
        } else {
            return no('not-channel');
        }
        if (o.onScreen !== true) return no('not-on-screen');
        if (o.locked === true) return no('locked');
        if (o.rotatingKey === true) return no('rotating-key');
        if (o.foreground !== true || o.focused !== true || o.idle !== false) return no('inactive');
        if (o.presence !== true || o.status !== 'online') return no('status');
        if (o.showInCounts !== true) return no('counts-off');
        if (o.connected !== true || o.meshOnly === true) return no('offline');
        return { send: true, reason: 'ok', key: o.key === 'anonymous' ? 'anonymous' : 'identity' };
    }

    function spacedAtMs(atMs, others) {
        let t = num(atMs);
        const list = (Array.isArray(others) ? others : []).map(num).filter((x) => x > 0).sort((a, b) => a - b);
        for (const o of list) {
            if (Math.abs(t - o) < ANON_SPACING_MS) t = o + ANON_SPACING_MS;
        }
        return t;
    }

    function anonTick(input) {
        const o = input || {};
        const act = (action, reason, atMs) => ({ action, reason, atMs: atMs || 0 });
        if (typeof o.pubkey !== 'string' || !o.pubkey || o.pubkey !== o.newest) return act('stop', 'superseded');
        if (o.signedIn !== true) return act('stop', 'signed-out');
        if (o.foreground !== true) return act('stop', 'background');
        if (o.presence !== true) return act('stop', 'presence-off');
        if (o.showInCounts !== true) return act('stop', 'counts-off');
        const nowMs = num(o.nowMs);
        const stopAt = num(o.stopAtMs);
        if (stopAt > 0 && nowMs >= stopAt) return act('stop', 'left');
        const gate = Object.assign({}, o, { key: 'anonymous' });
        if (stopAt > 0) Object.assign(gate, { onScreen: true, focused: true, idle: false });
        const plan = sendPlan(gate);
        if (!plan.send) return act('skip', plan.reason);
        const at = spacedAtMs(nowMs, o.identityMs);
        if (at > nowMs) return act('defer', 'spacing', at);
        return act('send', 'ok');
    }

    function publishRoute(key) {
        return key === 'anonymous' ? { lane: 'anonymous', userRelays: false } : { lane: 'identity', userRelays: true };
    }

    function delayMs(phase, r) {
        const span = phase === 'loop' ? LOOP_DELAY_MS : (phase === 'tail' ? TAIL_DELAY_MS : FIRST_DELAY_MS);
        let x = typeof r === 'number' && r >= 0 ? r : 0;
        if (x >= 1) x = 0.999999;
        return Math.floor(span[0] + x * (span[1] - span[0]));
    }

    function loopMs(type, online, r) {
        const base = delayMs('loop', r);
        const n = typeof online === 'number' && Number.isFinite(online) ? online : 0;
        if (type !== 'named' || n <= NAMED_BUSY_THRESHOLD) return base;
        return Math.min(NAMED_MAX_LOOP_MS, base * Math.ceil(n / NAMED_BUSY_THRESHOLD));
    }

    function namedTemplate(name, createdAt) {
        if (!isChannelName(name)) return null;
        return { kind: KIND, created_at: createdAt, content: '', tags: [['d', name.toLowerCase()]] };
    }

    function namedFilter(name, nowSec) {
        if (!isChannelName(name)) return null;
        return { kinds: [KIND], since: nowSec - SINCE_WINDOW_SEC, '#d': [name.toLowerCase()] };
    }

    function template(geohash, createdAt) {
        if (!isGeohash(geohash) || geohash.length > MAX_SEND_PRECISION) return null;
        return { kind: KIND, created_at: createdAt, content: '', tags: [['g', geohash]] };
    }

    function filter(geohash, nowSec) {
        if (!isGeohash(geohash)) return null;
        return { kinds: [KIND], since: nowSec - SINCE_WINDOW_SEC, '#g': [geohash] };
    }

    function admits(count, known) {
        return known === true || count < CHANNEL_CAP;
    }


    const WIDE = {
        sinceWindowSec: SINCE_WINDOW_SEC,
        futureSkewSec: 120,
        maxAgeSec: 300,
        decayMs: 300000,
        maxPrecision: MAX_SEND_PRECISION,
        maxNameLength: 64,
        ratePerMin: 6,
        channelCap: CHANNEL_CAP,
        maxChannels: 1000,
        maxEntries: 20000,
        dedupeMax: 4096,
        rateKeysMax: 20000,
        sweepMs: 60000,
        uiFlushMs: 2000,
    };

    function wideConfig() {
        return Object.assign({}, WIDE);
    }

    function wideFilter(nowSec) {
        return { kinds: [KIND], since: nowSec - WIDE.sinceWindowSec };
    }

    const shapeRefuse = (reason) => ({ ok: false, reason, type: null, channel: null, atMs: 0 });

    function shape(ev, ctx) {
        const c = ctx || {};
        if (!ev || typeof ev !== 'object' || ev.kind !== KIND) return shapeRefuse('kind');
        if (typeof ev.pubkey !== 'string' || !HEX64_RE.test(ev.pubkey)) return shapeRefuse('pubkey');
        if (typeof ev.id !== 'string' || !HEX64_RE.test(ev.id)) return shapeRefuse('id');
        if (c.verified !== true) return shapeRefuse('sig');
        if (ev.content !== '') return shapeRefuse('content');
        const tags = ev.tags;
        if (!Array.isArray(tags) || tags.length !== 1) return shapeRefuse('tags');
        const t = tags[0];
        if (!Array.isArray(t) || t.length !== 2 || (t[0] !== 'g' && t[0] !== 'd') || typeof t[1] !== 'string') return shapeRefuse('tags');
        const value = asciiLower(t[1]);
        const cased = UPPER_OR_TITLE_RE.test(value);
        let type;
        if (t[0] === 'g') {
            if (cased || !isGeohash(value)) return shapeRefuse('geohash');
            if (value.length > WIDE.maxPrecision) return shapeRefuse('precision');
            type = 'geohash';
        } else {
            if (cased || !isChannelName(value) || value.length > WIDE.maxNameLength) return shapeRefuse('name');
            type = 'named';
        }
        const at = ev.created_at;
        if (typeof at !== 'number' || !Number.isInteger(at) || at <= 0) return shapeRefuse('time');
        const nowMs = typeof c.nowMs === 'number' ? c.nowMs : Date.now();
        const nowSec = Math.floor(nowMs / 1000);
        if (at > nowSec + WIDE.futureSkewSec) return shapeRefuse('future');
        if (at < nowSec - WIDE.maxAgeSec) return shapeRefuse('stale');
        if (Array.isArray(c.own) && c.own.includes(ev.pubkey)) return shapeRefuse('own');
        if (Array.isArray(c.excluded) && c.excluded.includes(ev.pubkey)) return shapeRefuse('excluded');
        return { ok: true, reason: 'ok', type, channel: value, atMs: Math.min(at * 1000, nowMs) };
    }

    function createTracker() {
        const seen = new Map();
        const rate = new Map();
        const chans = new Map();
        let entries = 0;
        let lastSweep = 0;
        const dropOld = (members, nowMs) => {
            for (const [pk, at] of members) {
                if (nowMs - at >= WIDE.decayMs) { members.delete(pk); entries--; }
            }
        };
        const sweep = (nowMs) => {
            for (const [ch, m] of chans) {
                dropOld(m, nowMs);
                if (!m.size) chans.delete(ch);
            }
            for (const [pk, list] of rate) {
                if (!list.length || nowMs - list[list.length - 1] >= 60000) rate.delete(pk);
            }
            lastSweep = nowMs;
        };
        function ingest(ev, ctx) {
            const v = shape(ev, ctx);
            if (!v.ok) return v;
            const nowMs = typeof (ctx || {}).nowMs === 'number' ? ctx.nowMs : Date.now();
            if (seen.has(ev.id)) return shapeRefuse('dup');
            seen.set(ev.id, 1);
            if (seen.size > WIDE.dedupeMax) seen.delete(seen.keys().next().value);
            if (nowMs - lastSweep >= WIDE.sweepMs) sweep(nowMs);
            const pk = ev.pubkey;
            const list = (rate.get(pk) || []).filter((x) => nowMs - x < 60000);
            rate.delete(pk);
            if (list.length >= WIDE.ratePerMin) {
                rate.set(pk, list);
                return shapeRefuse('rate');
            }
            list.push(nowMs);
            rate.set(pk, list);
            if (rate.size > WIDE.rateKeysMax) rate.delete(rate.keys().next().value);
            let members = chans.get(v.channel);
            if (members) {
                chans.delete(v.channel);
                dropOld(members, nowMs);
            } else {
                members = new Map();
            }
            chans.set(v.channel, members);
            const prev = members.get(pk);
            if (prev === undefined && members.size >= WIDE.channelCap) return shapeRefuse('cap');
            if (prev === undefined) entries++;
            members.set(pk, Math.max(prev || 0, v.atMs));
            while (chans.size > WIDE.maxChannels || entries > WIDE.maxEntries) {
                const [ch, m] = chans.entries().next().value;
                if (ch === v.channel) break;
                chans.delete(ch);
                entries -= m.size;
            }
            return v;
        }
        function active(channel, nowMs, excluded) {
            const m = chans.get(String(channel || '').toLowerCase());
            const out = [];
            if (!m) return out;
            const skip = Array.isArray(excluded) ? excluded : [];
            for (const [pk, at] of m) {
                if (nowMs - at < WIDE.decayMs && !skip.includes(pk)) out.push(pk);
            }
            return out.sort();
        }
        function count(channel, nowMs, excluded) {
            return active(channel, nowMs, excluded).length;
        }
        function stats() {
            return { channels: chans.size, entries, seen: seen.size, rateKeys: rate.size };
        }
        return { ingest, active, count, stats, sweep };
    }

    root.NymGeoPresence = {
        KIND, FUTURE_SKEW_SEC, SINCE_WINDOW_SEC, MAX_SEND_PRECISION, CHANNEL_CAP, ANON_SPACING_MS,
        config, isGeohash, isChannelName, accept, activity, listsFromPresence, sendPlan, spacedAtMs, anonTick, publishRoute,
        delayMs, loopMs, template, filter, namedTemplate, namedFilter, admits,
        wideConfig, wideFilter, shape, createTracker,
    };
})(typeof self !== 'undefined' ? self : globalThis);
