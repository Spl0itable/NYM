(function (root) {
    const DAY = 86400;

    const LIMITS = Object.freeze({
        pendingMax: 20,
        inviteMaxAge: 30 * DAY,
        holdPerGroup: 50,
        holdTotal: 200,
        holdBytes: 512 * 1024,
        declinedTtl: 60 * DAY,
        acceptedTtl: 7 * DAY,
        decisionsMax: 100,
        perInviterBanner: 3600,
        globalBannersPerHour: 5,
        globalWindow: 3600,
        liveWindow: 30,
        nameMax: 40,
        wrapLimitPq2: 16384,
        wrapLimitClassic: 28672,
        reserve: 1024,
        rumorOverhead: 256,
        itemMaxBytes: 28672,
        rosterMax: 100,
        storeMaxBytes: 262144,
        archivePerHour: 20,
    });

    const KEYS = Object.freeze({
        dTag: 'nymchat-group-invites',
        payload: 'groupInvites',
        section: 'groupInvites',
        local: 'nym_group_invites_',
        probe: 'nym_group_invites_probe',
        notifyPrefix: 'group-invite-',
    });

    const STRINGS = Object.freeze({
        title: 'Group invites',
        rowLabel: 'Group invites, {n} waiting',
        invitedBy: 'Invited by {nym}',
        addedBy: '{nym} added you',
        members: '{n}/{max} members',
        leftBefore: 'You left this group before.',
        accept: 'Accept',
        decline: 'Decline',
        more: 'More options',
        declineBlock: 'Decline and block {nym}',
        acceptLabel: 'Accept invite to {group}',
        declineLabel: 'Decline invite to {group}',
        notifyTitle: 'Group invite: {name}',
        notifyInvite: '{nym} invited you. Open Group invites to accept or decline.',
        notifyAdd: '{nym} added you. Open Group invites to accept or decline.',
        joined: 'Joined "{name}".',
        declined: 'Invite declined.',
        declinedBlocked: 'Invite declined. {nym} is blocked.',
        stale: 'This invite is no longer available.',
        empty: 'No group invites.',
        close: 'Close',
        group: 'Group',
    });

    const VERDICTS = Object.freeze(['route', 'pending-new', 'pending-update', 'hold', 'drop']);
    const RANK = Object.freeze({ d: 1, a: 2 });
    const GID = /^[0-9A-Za-z_-]{1,128}$/;

    const int = (x) => {
        const n = Math.floor(Number(x));
        return Number.isFinite(n) && n > 0 ? n : 0;
    };
    const str = (x) => (typeof x === 'string' ? x : '');
    const cmpStr = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

    function fill(text, vars) {
        return String(text).replace(/\{(\w+)\}/g, (m, k) => (vars && vars[k] !== undefined && vars[k] !== null ? String(vars[k]) : m));
    }

    function clampName(name) {
        const s = str(name).replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
        return Array.from(s).slice(0, LIMITS.nameMax).join('').trim();
    }

    function notifyId(gid) {
        return KEYS.notifyPrefix + str(gid);
    }

    function inviteTime(createdAt, now) {
        return Math.min(int(createdAt), int(now));
    }

    function isLive(it, now, backlog) {
        return !backlog && int(now) - int(it) <= LIMITS.liveWindow;
    }

    function tagVals(tags, k, max) {
        const out = [];
        for (const t of tags) {
            if (max && out.length >= max) break;
            if (Array.isArray(t) && t[0] === k && typeof t[1] === 'string' && t[1] && out.indexOf(t[1]) < 0) out.push(t[1]);
        }
        return out;
    }

    function rumorBytes(rumor) {
        if (!rumor || typeof rumor !== 'object') return 0;
        try { return new TextEncoder().encode(JSON.stringify(rumor)).length; } catch (_) { return LIMITS.itemMaxBytes + 1; }
    }

    function tagVal(tags, k) {
        const v = tagVals(tags, k);
        return v.length ? v[0] : null;
    }

    function rosterOf(rumor) {
        const tags = rumor && Array.isArray(rumor.tags) ? rumor.tags : [];
        const ai = tags.find((t) => Array.isArray(t) && t[0] === 'allow_invites');
        return {
            members: tagVals(tags, 'p', LIMITS.rosterMax),
            admins: tagVals(tags, 'admin', LIMITS.rosterMax),
            mods: tagVals(tags, 'mod', LIMITS.rosterMax),
            owner: tagVal(tags, 'owner'),
            gowner: tagVal(tags, 'gowner'),
            ai: ai ? ai[1] !== '0' : true,
        };
    }

    function roleOf(item, pk) {
        if (!item || !pk) return null;
        if (item.owner === pk) return 'owner';
        if (Array.isArray(item.admins) && item.admins.indexOf(pk) >= 0) return 'admin';
        if (Array.isArray(item.mods) && item.mods.indexOf(pk) >= 0) return 'mod';
        if (Array.isArray(item.members) && item.members.indexOf(pk) >= 0) return 'member';
        return null;
    }

    const drop = (r) => ({ v: 'drop', r });

    function gate(x) {
        if (x.anon) return drop('anon');
        if (x.own) return { v: 'route', r: 'own' };
        if (x.joined) return { v: 'route', r: 'joined' };
        if (x.started) return { v: 'route', r: 'started' };
        if (x.blocked) return drop('blocked');
        if (x.hidden) return drop('hidden');
        if (x.accept === 'disabled') return drop('pms-off');
        if (x.accept === 'friends' && !x.friend) return drop('friends-only');
        const inv = x.type === 'group-invite';
        const add = x.type === 'group-add-member';
        const pending = x.pending || null;
        if (!inv && !add) return pending ? { v: 'hold', r: 'held' } : drop('unknown-group');
        if (x.genesis === false) return drop('genesis');
        let boot = false;
        if (inv) {
            if (x.genesis === true && x.sender !== x.gowner) return drop('not-owner');
            if (pending && pending.owner && pending.owner !== x.sender) return drop('not-owner');
            boot = true;
        } else {
            const claimed = !!x.owner && x.owner === x.sender && (x.genesis !== true || x.owner === x.gowner);
            if (pending) {
                const role = roleOf(pending, x.sender);
                const ok = role === 'owner' || role === 'admin' || role === 'mod' || (role === 'member' && pending.ai !== false);
                if (!ok) return drop('no-role');
                boot = claimed && role === 'owner';
            } else {
                if (!claimed) return drop('not-owner');
                boot = true;
            }
        }
        if (Number(x.bytes) > LIMITS.itemMaxBytes) return drop('too-big');
        const now = int(x.now);
        const it = int(x.it);
        if (now - it > LIMITS.inviteMaxAge) return drop('expired');
        if (x.decision && it <= int(x.decision.dt)) return drop('decided');
        if (x.left && it <= int(x.leftAt)) return drop('left');
        const left = !!x.left;
        if (pending) {
            if (it > int(pending.it)) return { v: 'pending-update', r: 'newer', boot, left };
            return drop('older');
        }
        return { v: 'pending-new', r: 'new', boot, left };
    }

    function itemFrom(x) {
        const r = rosterOf(x.rumor);
        const tags = x.rumor && Array.isArray(x.rumor.tags) ? x.rumor.tags : [];
        const via = x.type === 'group-add-member' ? 'add' : 'invite';
        return {
            gid: str(x.gid),
            it: int(x.it),
            by: str(x.sender),
            via,
            n: clampName(tagVal(tags, 'subject') || ''),
            m: r.members.length,
            owner: via === 'invite' ? str(x.sender) : str(r.owner || x.sender),
            admins: r.admins,
            mods: r.mods,
            members: r.members,
            ai: r.ai,
            at: int(x.now),
            nt: 0,
            left: !!x.left,
            rumor: x.rumor || null,
            wrapId: str(x.wrapId),
            b: rumorBytes(x.rumor),
        };
    }

    function storeBytes(list) {
        let t = 0;
        for (const i of list) t += int(i.b);
        return t;
    }

    function sortItems(list) {
        return list.sort((a, b) => (b.it - a.it) || cmpStr(a.gid, b.gid));
    }

    function capPending(list, friends) {
        const out = list.slice();
        const fr = Array.isArray(friends) ? friends : [];
        const evicted = [];
        while (out.length > LIMITS.pendingMax || (out.length > 1 && storeBytes(out) > LIMITS.storeMaxBytes)) {
            const pool = out.filter((i) => fr.indexOf(i.by) < 0);
            const from = pool.length ? pool : out;
            let v = from[0];
            for (const i of from) if (i.it < v.it || (i.it === v.it && cmpStr(i.gid, v.gid) < 0)) v = i;
            out.splice(out.indexOf(v), 1);
            evicted.push(v.gid);
        }
        return { list: sortItems(out), evicted };
    }

    function pendingApply(list, verdict, item, friends) {
        const cur = Array.isArray(list) ? list.slice() : [];
        const at = cur.findIndex((i) => i.gid === item.gid);
        if (verdict.v === 'pending-new') {
            if (at >= 0) return { list: sortItems(cur), evicted: [], changed: false };
            cur.push(item);
        } else if (verdict.v === 'pending-update') {
            if (at < 0) return { list: sortItems(cur), evicted: [], changed: false };
            const old = cur[at];
            const next = Object.assign({}, item, { at: old.at, nt: old.nt, left: !!(old.left || item.left) });
            if (!verdict.boot) {
                next.owner = old.owner;
                next.rumor = old.rumor;
                next.wrapId = old.wrapId;
                next.b = int(old.b);
                next.admins = old.admins;
                next.mods = old.mods;
                next.ai = old.ai;
            }
            cur[at] = next;
        } else {
            return { list: sortItems(cur), evicted: [], changed: false };
        }
        const c = capPending(cur, friends);
        return { list: c.list, evicted: c.evicted, changed: true };
    }

    function pendingRemove(list, gid) {
        const cur = Array.isArray(list) ? list : [];
        return cur.filter((i) => i.gid !== gid);
    }

    function notifyState(s, now) {
        const last = {};
        const src = s && s.last && typeof s.last === 'object' ? s.last : {};
        for (const k of Object.keys(src).sort()) {
            const t = int(src[k]);
            if (t && now - t < LIMITS.perInviterBanner) last[k] = t;
        }
        const recent = (s && Array.isArray(s.recent) ? s.recent : []).map(int).filter((t) => t && now - t < LIMITS.globalWindow).sort((a, b) => a - b);
        return { last, recent };
    }

    function notifyDecision(s, x) {
        const now = int(x.now);
        const st = notifyState(s, now);
        const bell = x.verdict === 'pending-new';
        let reason = 'banner';
        if (!bell) reason = 'not-new';
        else if (!x.live) reason = 'historical';
        else if (!x.toast) reason = 'toast-off';
        else if (st.last[x.by] !== undefined) reason = 'inviter-recent';
        else if (st.recent.length >= LIMITS.globalBannersPerHour) reason = 'global-cap';
        const banner = reason === 'banner';
        if (banner) {
            st.last[x.by] = now;
            st.recent.push(now);
        }
        return { banner, bell, reason, state: st };
    }

    function cleanDecision(e) {
        if (!e || typeof e !== 'object' || !RANK[e.s]) return null;
        const it = int(e.it);
        const dt = int(e.dt);
        if (!it || !dt) return null;
        return { s: e.s, it, dt };
    }

    function cmpDecision(a, b) {
        return (a.it - b.it) || (RANK[a.s] - RANK[b.s]) || (a.dt - b.dt);
    }

    function expired(e, now) {
        const ttl = e.s === 'a' ? LIMITS.acceptedTtl : LIMITS.declinedTtl;
        return int(now) - e.dt > ttl;
    }

    function capDecisions(entries) {
        if (entries.length <= LIMITS.decisionsMax) return entries;
        return entries.slice().sort((x, y) => cmpDecision(y[1], x[1]) || cmpStr(x[0], y[0])).slice(0, LIMITS.decisionsMax);
    }

    function normalizeDecisions(d, now) {
        const src = d && typeof d === 'object' && !Array.isArray(d) ? d : {};
        let entries = [];
        for (const gid of Object.keys(src)) {
            if (!GID.test(gid)) continue;
            const e = cleanDecision(src[gid]);
            if (!e || expired(e, now)) continue;
            entries.push([gid, e]);
        }
        entries = capDecisions(entries);
        entries.sort((x, y) => cmpStr(x[0], y[0]));
        const out = {};
        for (const [gid, e] of entries) out[gid] = e;
        return out;
    }

    function mergeDecisions(a, b, now) {
        const A = normalizeDecisions(a, now);
        const B = normalizeDecisions(b, now);
        const out = Object.assign({}, A);
        for (const gid of Object.keys(B)) {
            if (!out[gid] || cmpDecision(B[gid], out[gid]) > 0) out[gid] = B[gid];
        }
        return normalizeDecisions(out, now);
    }

    function decide(d, gid, s, it, now) {
        return mergeDecisions(d, { [gid]: { s, it: int(it), dt: int(now) } }, now);
    }

    function publishable(d) {
        return { v: 1, d: d && typeof d === 'object' ? d : {} };
    }

    function fromPayload(p) {
        if (!p || typeof p !== 'object' || Array.isArray(p)) return {};
        return p.d && typeof p.d === 'object' && !Array.isArray(p.d) ? p.d : {};
    }

    function rowBytes(payload) {
        return new TextEncoder().encode(JSON.stringify(JSON.stringify(payload))).length + LIMITS.rumorOverhead;
    }

    function fitsRow(payload, pq2) {
        const lim = (pq2 === false ? LIMITS.wrapLimitClassic : LIMITS.wrapLimitPq2) - LIMITS.reserve;
        return rowBytes(payload) <= lim;
    }

    function trimPayload(payload) {
        const g = payload && payload[KEYS.payload];
        const d = g && g.d;
        if (!d || typeof d !== 'object') return false;
        const keys = Object.keys(d);
        if (!keys.length) return false;
        let lo = keys[0];
        for (const k of keys) {
            const e = cleanDecision(d[k]);
            const l = cleanDecision(d[lo]);
            if (!e) { lo = k; break; }
            if (!l || cmpDecision(e, l) < 0 || (cmpDecision(e, l) === 0 && cmpStr(k, lo) < 0)) lo = k;
        }
        delete d[lo];
        return true;
    }

    function holdNew() {
        return { g: {} };
    }

    function holdTotals(h) {
        let n = 0;
        let b = 0;
        for (const gid of Object.keys(h.g)) for (const e of h.g[gid]) { n++; b += e.b; }
        return { n, b };
    }

    function holdOldest(h, onlyGid) {
        let best = null;
        for (const gid of Object.keys(h.g)) {
            if (onlyGid && gid !== onlyGid) continue;
            for (const e of h.g[gid]) {
                if (!best || e.ts < best.e.ts || (e.ts === best.e.ts && cmpStr(e.id, best.e.id) < 0)) best = { gid, e };
            }
        }
        return best;
    }

    function holdDrop(h, gid, id) {
        const list = h.g[gid] || [];
        const i = list.findIndex((e) => e.id === id);
        if (i >= 0) list.splice(i, 1);
        if (!list.length) delete h.g[gid];
    }

    function holdAdd(state, x) {
        const h = { g: {} };
        const src = state && state.g ? state.g : {};
        for (const gid of Object.keys(src)) h.g[gid] = src[gid].map((e) => ({ id: e.id, ts: e.ts, b: e.b }));
        const e = { id: str(x.id), ts: int(x.ts), b: int(x.b) };
        if (!e.id || e.b > LIMITS.holdBytes) return { state: h, accepted: false, dropped: [] };
        if ((h.g[x.gid] || []).some((y) => y.id === e.id)) return { state: h, accepted: false, dropped: [] };
        (h.g[x.gid] = h.g[x.gid] || []).push(e);
        const dropped = [];
        while ((h.g[x.gid] || []).length > LIMITS.holdPerGroup) {
            const o = holdOldest(h, x.gid);
            holdDrop(h, o.gid, o.e.id);
            dropped.push({ gid: o.gid, id: o.e.id });
        }
        for (let t = holdTotals(h); t.n > LIMITS.holdTotal || t.b > LIMITS.holdBytes; t = holdTotals(h)) {
            const o = holdOldest(h, null);
            holdDrop(h, o.gid, o.e.id);
            dropped.push({ gid: o.gid, id: o.e.id });
        }
        const accepted = !dropped.some((d) => d.gid === x.gid && d.id === e.id);
        for (const gid of Object.keys(h.g)) h.g[gid].sort((a, b) => (a.ts - b.ts) || cmpStr(a.id, b.id));
        return { state: h, accepted, dropped };
    }

    function holdTake(state, gid) {
        const list = state && state.g && state.g[gid] ? state.g[gid].slice() : [];
        const h = { g: {} };
        for (const k of Object.keys((state && state.g) || {})) if (k !== gid) h.g[k] = state.g[k].slice();
        return { state: h, ids: list.sort((a, b) => (a.ts - b.ts) || cmpStr(a.id, b.id)).map((e) => e.id) };
    }

    function archiveDecision(s, x) {
        const now = int(x.now);
        const st = notifyState(s, now);
        const v = x.verdict;
        let reason = 'archive';
        if (v !== 'pending-new' && !(v === 'pending-update' && x.boot)) reason = 'not-new';
        else if (!x.kept) reason = 'evicted';
        else if (x.by && st.last[x.by]) reason = 'per-inviter';
        else if (st.recent.length >= LIMITS.archivePerHour) reason = 'global';
        const archive = reason === 'archive';
        if (archive) {
            if (x.by) st.last[x.by] = now;
            st.recent.push(now);
        }
        return { archive, reason, state: st };
    }

    function normalizeItems(list, now) {
        const out = [];
        const seen = new Set();
        const cap = (a) => (Array.isArray(a) ? a.slice(0, LIMITS.rosterMax) : []);
        for (const i of Array.isArray(list) ? list : []) {
            if (!i || typeof i !== 'object' || !GID.test(str(i.gid)) || seen.has(i.gid)) continue;
            if (int(now) - int(i.it) > LIMITS.inviteMaxAge) continue;
            if (!i.rumor || typeof i.rumor !== 'object') continue;
            const b = rumorBytes(i.rumor);
            if (b > LIMITS.itemMaxBytes) continue;
            seen.add(i.gid);
            out.push(Object.assign({}, i, { members: cap(i.members), admins: cap(i.admins), mods: cap(i.mods), m: Math.min(int(i.m), LIMITS.rosterMax), b }));
        }
        const kept = [];
        let total = 0;
        for (const i of sortItems(out)) {
            if (kept.length >= LIMITS.pendingMax) break;
            if (kept.length && total + i.b > LIMITS.storeMaxBytes) continue;
            total += i.b;
            kept.push(i);
        }
        return kept;
    }

    function uniqKeys(list, skip) {
        const out = [];
        const seen = new Set(skip || []);
        for (const k of Array.isArray(list) ? list : []) {
            if (typeof k !== 'string' || !k || seen.has(k)) continue;
            seen.add(k);
            out.push(k);
        }
        return out;
    }

    function settleSelf(local, synced, settle, max) {
        const cap = Math.max(0, int(max));
        const sc = synced && typeof synced.current === 'string' ? synced.current : '';
        const lc = local && typeof local.current === 'string' ? local.current : '';
        if (!lc) return sc ? { current: sc, prev: uniqKeys(synced.prev, [sc]).slice(0, cap), adopted: true } : null;
        let current = lc;
        let prev = uniqKeys(local.prev, [lc]);
        let adopted = false;
        if (sc && sc !== lc && settle && sc < lc) {
            prev = [lc].concat(prev.filter((k) => k !== sc));
            current = sc;
            adopted = true;
        }
        if (sc) prev = prev.concat(uniqKeys([sc].concat(Array.isArray(synced.prev) ? synced.prev : []), [current].concat(prev)));
        return { current, prev: prev.slice(0, cap), adopted };
    }

    function settleRepair(row, minted, current) {
        if (typeof minted !== 'string' || !minted) return false;
        const pks = row && typeof row.current === 'string' ? [row.current].concat(Array.isArray(row.prev) ? row.prev : []) : [];
        return !pks.includes(minted) || !pks.includes(current);
    }

    const SETTLE = Object.freeze({ windowSec: 600 });

    const LEFT = Object.freeze({ rolesMax: 9, groupsMax: 100, syncMax: 8 });
    const PKX = /^[0-9a-f]{64}$/;

    function leftRoles(m, gids) {
        const src = m && typeof m === 'object' && !Array.isArray(m) ? m : {};
        const only = Array.isArray(gids) ? new Set(gids) : null;
        const out = {};
        let n = 0;
        for (const k of Object.keys(src).sort(cmpStr)) {
            if (n >= LEFT.groupsMax) break;
            if (!GID.test(k) || (only && !only.has(k))) continue;
            const v = uniqKeys(src[k]);
            if (!v.length || v.length > LEFT.rolesMax || !v.every((p) => PKX.test(p))) continue;
            out[k] = v;
            n++;
        }
        return out;
    }

    function leftRolesNote(m, gid, owner, mods, gids) {
        const g = str(gid);
        const out = Object.assign({}, leftRoles(m, gids));
        delete out[g];
        const list = uniqKeys([str(owner)].concat(Array.isArray(mods) ? mods : []));
        if (GID.test(g) && PKX.test(str(owner)) && list.length <= LEFT.rolesMax && list.every((p) => PKX.test(p))) out[g] = list;
        return leftRoles(out, null);
    }

    function leftRolesSync(m, gids, times) {
        const all = leftRoles(m, Array.isArray(gids) ? gids : []);
        const t = times && typeof times === 'object' && !Array.isArray(times) ? times : {};
        const at = (k) => { const v = Math.floor(Number(t[k])); return Number.isFinite(v) && v > 0 ? v : 0; };
        const keep = Object.keys(all).sort((a, b) => (at(b) - at(a)) || cmpStr(a, b)).slice(0, LEFT.syncMax);
        const out = {};
        for (const k of keep.sort(cmpStr)) out[k] = all[k];
        return out;
    }

    function leftRolesMerge(m, incoming, gids) {
        const out = Object.assign({}, leftRoles(m, null));
        const add = leftRoles(incoming, Array.isArray(gids) ? gids : []);
        for (const k of Object.keys(add)) if (!out[k]) out[k] = add[k];
        return leftRoles(out, null);
    }

    function leftRole(m, gid, sender) {
        const v = leftRoles(m, null)[str(gid)];
        return v ? v.includes(str(sender)) : null;
    }

    function settleOpen(m, now) {
        const at = int(m && m.at);
        const t = int(now);
        return at > 0 && t - at < SETTLE.windowSec && at - t < SETTLE.windowSec;
    }

    function settleDue(m, row, minted, current, now) {
        return settleOpen(m, now) && !(m && m.repaired) && settleRepair(row, minted, current);
    }

    function settleKeep(m, now) {
        if (!m || typeof m !== 'object' || typeof m.pk !== 'string' || !m.pk || !settleOpen(m, now)) return null;
        return { pk: m.pk, at: int(m.at), repaired: m.repaired === true };
    }

    function probe(x) {
        const now = int(x.now);
        const counted = uniqKeys(x.counted).sort(cmpStr);
        const out = (v, r, extra) => Object.assign({ v, r, count: v === 'count', notify: false, counted, ns: notifyState(x.ns, now) }, extra || {});
        const g = gate(x);
        if (g.v === 'route') return out('route', g.r);
        if (g.v !== 'pending-new') return out('none', g.r);
        const gid = str(x.gid);
        if (counted.includes(gid)) return out('none', 'counted');
        if (int(x.stored) + counted.length >= LIMITS.pendingMax) return out('none', 'cap');
        const nd = notifyDecision(x.ns, { verdict: 'pending-new', now, live: isLive(int(x.it), now, !x.live), toast: true, by: x.sender });
        return out('count', nd.reason, { notify: nd.banner && x.readable !== false, counted: counted.concat([gid]).sort(cmpStr), ns: nd.state });
    }

    function probeState(s, now, skip) {
        const t0 = int(now);
        const drop = new Set(Array.isArray(skip) ? skip : []);
        const src = s && s.c && typeof s.c === 'object' && !Array.isArray(s.c) ? s.c : {};
        const kept = Object.keys(src).map((k) => [k, int(src[k])])
            .filter(([k, t]) => GID.test(k) && !drop.has(k) && t && t0 - t < LIMITS.inviteMaxAge && t - t0 < LIMITS.inviteMaxAge)
            .sort((p, q) => (q[1] - p[1]) || cmpStr(p[0], q[0]))
            .slice(0, LIMITS.pendingMax)
            .sort((p, q) => cmpStr(p[0], q[0]));
        const c = {};
        for (const [k, t] of kept) c[k] = t;
        return { c, ns: notifyState(s && s.ns, t0) };
    }

    function probeKeep(st, r, gid, now) {
        const base = probeState(st, now);
        if (!r || r.v !== 'count' || !GID.test(str(gid))) return base;
        return probeState({ c: Object.assign({}, base.c, { [str(gid)]: int(now) }), ns: r.ns }, now);
    }

    function unbanState(s, now) {
        const src = s && s.last && typeof s.last === 'object' ? s.last : {};
        const kept = Object.keys(src).map((k) => [k, int(src[k])])
            .filter(([k, t]) => GID.test(k) && t && now - t < LIMITS.perInviterBanner)
            .sort((p, q) => (q[1] - p[1]) || cmpStr(p[0], q[0]))
            .slice(0, LIMITS.decisionsMax)
            .sort((p, q) => cmpStr(p[0], q[0]));
        const last = {};
        for (const [k, t] of kept) last[k] = t;
        return { last };
    }

    function unbanNotice(s, x) {
        const now = int(x.now);
        const state = unbanState(s, now);
        const no = (r) => ({ notice: false, archive: false, r, state });
        if (x.blocked) return no('blocked');
        if (x.hidden) return no('hidden');
        if (x.accept === 'disabled') return no('pms-off');
        if (x.accept === 'friends' && !x.friend) return no('friends-only');
        if (int(x.it) <= int(x.leftAt)) return no('left');
        if (x.role === false || (x.known && x.role !== true)) return no('role');
        const gid = str(x.gid);
        if (state.last[gid] !== undefined) return no('gid-recent');
        state.last[gid] = now;
        return { notice: true, archive: !!x.known, generic: !x.known, r: 'notice', state: unbanState(state, now) };
    }

    root.NymGroupInvites = Object.freeze({
        LIMITS, KEYS, STRINGS, VERDICTS, SETTLE, LEFT,
        fill, clampName, notifyId, inviteTime, isLive, rosterOf, roleOf, rumorBytes, storeBytes,
        gate, itemFrom, capPending, pendingApply, pendingRemove, normalizeItems,
        notifyState, notifyDecision, archiveDecision,
        normalizeDecisions, mergeDecisions, decide, cmpDecision, publishable, fromPayload, rowBytes, fitsRow, trimPayload,
        holdNew, holdAdd, holdTake,
        settleSelf, settleRepair, settleOpen, settleDue, settleKeep, probe, probeState, probeKeep, unbanState, unbanNotice, leftRoles, leftRolesNote, leftRole, leftRolesSync, leftRolesMerge,
    });
})(typeof self !== 'undefined' ? self : this);
