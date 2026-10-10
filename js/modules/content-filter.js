(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const SUFFIX = /#[0-9a-f]{4}$/i;
    const QUOTE_HEAD = /^>\s*@([^:\n]+):/;

    function str(v) {
        return typeof v === 'string' ? v : '';
    }

    function list(set) {
        if (!set) return [];
        if (Array.isArray(set)) return set;
        if (typeof set[Symbol.iterator] === 'function') return Array.from(set);
        return [];
    }

    function has(set, v) {
        if (!set || !v) return false;
        if (typeof set.has === 'function') return set.has(v);
        if (Array.isArray(set)) return set.indexOf(v) !== -1;
        return false;
    }

    function baseNym(nym) {
        return str(nym).trim().replace(SUFFIX, '').trim();
    }

    function nymSuffix(nym) {
        const m = str(nym).trim().match(/#([0-9a-f]{4})$/i);
        return m ? m[1].toLowerCase() : '';
    }

    function keywordHit(keywords, text, nym) {
        const t = str(text).toLowerCase();
        const n = baseNym(nym).toLowerCase();
        for (const raw of list(keywords)) {
            const k = str(raw).trim().toLowerCase();
            if (!k) continue;
            if (t.includes(k) || (n && n.includes(k))) return true;
        }
        return false;
    }

    function exempt(ctx, pubkey) {
        const pk = str(pubkey);
        if (!pk) return false;
        if (str(ctx.self) && pk === ctx.self) return true;
        if (typeof ctx.friend === 'function' && ctx.friend(pk)) return true;
        if (typeof ctx.bot === 'function' && ctx.bot(pk)) return true;
        return false;
    }

    function textBlocked(ctx, text, nym, pubkey) {
        const c = ctx || {};
        if (keywordHit(c.keywords, text, nym)) return true;
        if (typeof c.pack !== 'function' || exempt(c, pubkey)) return false;
        return c.pack(str(text), str(nym)) === true;
    }

    function quoteAuthors(text) {
        const out = [];
        for (const line of str(text).split('\n')) {
            const m = line.match(QUOTE_HEAD);
            if (m) out.push(m[1].trim());
        }
        return out;
    }

    function userBlocked(ctx, pubkey) {
        return has(ctx && ctx.blockedUsers, str(pubkey));
    }

    function personHidden(ctx, pubkey, nym) {
        const c = ctx || {};
        const pk = str(pubkey);
        if (pk && str(c.self) && pk === c.self) return false;
        if (pk && has(c.blockedUsers, pk)) return true;
        if (pk && typeof c.muted === 'function' && c.muted(pk)) return true;
        return textBlocked(c, '', str(nym), pk);
    }

    function quoteBlocked(ctx, author) {
        const sfx = nymSuffix(author);
        if (!sfx) return false;
        for (const pk of list(ctx && ctx.blockedUsers)) {
            const p = str(pk);
            if (p.length >= 4 && p.slice(-4).toLowerCase() === sfx) return true;
        }
        return false;
    }

    function stripBlockedQuotes(ctx, text) {
        const s = str(text);
        if (s.indexOf('>') === -1) return s;
        const out = [];
        let skipping = false;
        let removed = false;
        for (const line of s.split('\n')) {
            const m = line.match(QUOTE_HEAD);
            if (m) {
                skipping = quoteBlocked(ctx, m[1].trim());
                if (skipping) {
                    removed = true;
                    continue;
                }
                out.push(line);
                continue;
            }
            if (skipping && line.startsWith('>')) continue;
            skipping = false;
            out.push(line);
        }
        if (!removed) return s;
        while (out.length && out[0].trim() === '') out.shift();
        return out.join('\n');
    }

    function onlyBlockedQuotes(ctx, text) {
        const s = str(text);
        if (s.indexOf('>') === -1) return false;
        const out = stripBlockedQuotes(ctx, s);
        return out !== s && out.trim() === '';
    }

    function channelKey(key) {
        return str(key).trim().replace(/^#/, '').toLowerCase();
    }

    function inChannels(set, key) {
        const k = channelKey(key);
        if (!k) return false;
        for (const v of list(set)) {
            if (channelKey(v) === k) return true;
        }
        return false;
    }

    function channelBlocked(ctx, key) {
        return inChannels(ctx && ctx.blockedChannels, key);
    }

    function channelHidden(ctx, key) {
        return channelBlocked(ctx, key) || inChannels(ctx && ctx.hiddenChannels, key);
    }

    function view(m) {
        const x = m && typeof m === 'object' ? m : {};
        return {
            pubkey: str(x.pubkey),
            content: str(x.content),
            nym: str(x.nym),
            own: x.own === true,
            system: x.system === true,
            mesh: x.mesh === true
        };
    }

    function isOwn(ctx, m) {
        return m.own || (!!str(ctx.self) && m.pubkey === ctx.self);
    }

    function hidden(ctx, msg, ref) {
        const c = ctx || {};
        const m = view(msg);
        const r = ref === undefined ? msg : ref;
        if (m.system) return false;
        if (typeof c.deleted === 'function' && c.deleted(r)) return true;
        const own = isOwn(c, m);
        if (!own && has(c.blockedUsers, m.pubkey)) return true;
        if (!own && typeof c.muted === 'function' && c.muted(m.pubkey)) return true;
        if (textBlocked(c, m.content, own ? '' : m.nym, m.pubkey)) return true;
        if (onlyBlockedQuotes(c, m.content)) return true;
        if (own || m.mesh) return false;
        if (typeof c.quiet === 'function' && c.quiet(r)) return true;
        if (typeof c.spam === 'function' && c.spam(r)) return true;
        if (typeof c.gated === 'function' && c.gated(r)) return true;
        return false;
    }

    function countsUnread(ctx, msg, ref) {
        const c = ctx || {};
        const m = view(msg);
        if (m.system || isOwn(c, m)) return false;
        return !hidden(c, msg, ref);
    }

    function lastVisible(ctx, items, toView) {
        if (!Array.isArray(items)) return -1;
        for (let i = items.length - 1; i >= 0; i--) {
            const raw = items[i];
            if (!raw) continue;
            const m = typeof toView === 'function' ? toView(raw) : raw;
            if (!m || typeof m.content !== 'string' || m.system === true) continue;
            if (hidden(ctx, m, raw)) continue;
            return i;
        }
        return -1;
    }

    function entryHidden(ctx, entry) {
        const c = ctx || {};
        const e = entry && typeof entry === 'object' ? entry : {};
        const sender = str(e.sender);
        const self = !!sender && sender === str(c.self);
        if (sender && !self && has(c.blockedUsers, sender)) return true;
        if (sender && !self && typeof c.muted === 'function' && c.muted(sender)) return true;
        if (sender && !self && c.friendsOnly === true &&
            !(typeof c.friend === 'function' && c.friend(sender)) &&
            !(typeof c.bot === 'function' && c.bot(sender))) return true;
        if (str(e.channel) && channelHidden(c, e.channel)) return true;
        if (textBlocked(c, str(e.body), self ? '' : str(e.nym), sender)) return true;
        if (onlyBlockedQuotes(c, e.body)) return true;
        if (str(e.subject) && textBlocked(c, str(e.subject), '', sender)) return true;
        return false;
    }

    function zapper(claimed, publisher, verified) {
        const pub = str(publisher);
        const want = str(claimed).toLowerCase();
        if (!want) return pub;
        if (verified === true || want === pub.toLowerCase()) return want;
        return pub;
    }

    const BLOCKED_GROUP_CONTROL = Object.freeze([
        'group-add-member', 'group-remove-member', 'group-promote-mod', 'group-revoke-mod', 'group-promote-admin',
        'group-revoke-admin', 'group-roster-req', 'group-roster', 'group-transfer-owner', 'group-metadata',
        'group-delete-message', 'group-leave', 'group-unban', 'key-resync', 'group-join-pending', 'group-join-waiting',
        'group-join-declined', 'group-join-resolved'
    ]);

    function keepsBlockedGroupControl(type) {
        const t = str(type);
        return !!t && BLOCKED_GROUP_CONTROL.indexOf(t) !== -1;
    }

    function activeFilters(ctx) {
        const c = ctx || {};
        if (list(c.blockedUsers).length) return true;
        if (list(c.keywords).some((k) => str(k).trim())) return true;
        return c.packs === true;
    }

    G.NymContentFilter = Object.freeze({
        baseNym, nymSuffix, keywordHit, textBlocked, quoteAuthors, userBlocked, personHidden, quoteBlocked,
        stripBlockedQuotes, onlyBlockedQuotes, channelKey, channelBlocked, channelHidden, hidden, countsUnread,
        lastVisible, entryHidden, activeFilters, zapper, keepsBlockedGroupControl
    });
})();
