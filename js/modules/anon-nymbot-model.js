(function () {
    'use strict';
    const G = (typeof self !== 'undefined' ? self : window);

    const STRINGS = Object.freeze({
        mesh: "Nymbot wasn't asked: it needs the internet, and this channel is on the mesh only.",
        unavailable: "Nymbot wasn't asked: it isn't available on this host.",
        rateLimited: "Nymbot wasn't asked: too many requests right now. Try again in a minute.",
        failed: "Nymbot couldn't be reached, so it didn't answer.",
    });

    const COMMAND = /^\?\S/;
    const MENTION = /(^|[^A-Za-z0-9_])@nymbot(?:#[0-9a-f]{4})?(?![A-Za-z0-9_])/i;
    const BOT_AUTHOR = /^nymbot(?:#[0-9a-f]{4})?$/i;

    function str(v) {
        return typeof v === 'string' ? v : '';
    }

    function triggers(input) {
        const i = input || {};
        const body = str(i.body).trim();
        if (COMMAND.test(body) || MENTION.test(body)) return true;
        if (!body) return false;
        if (BOT_AUTHOR.test(str(i.quoteAuthor).trim())) return true;
        return !!i.threadBot;
    }

    function blocker(ctx) {
        const c = ctx || {};
        if (c.mesh) return 'mesh';
        if (!c.apiHost || c.validChannel === false) return 'unavailable';
        return null;
    }

    function outcome(status, hasEvent) {
        const s = Number(status) || 0;
        if (s === 429) return 'rateLimited';
        if (s === 403) return 'unavailable';
        if (s >= 200 && s < 300) return hasEvent ? null : 'failed';
        if (s >= 400 && s < 500) return null;
        return 'failed';
    }

    function notice(reason) {
        return Object.prototype.hasOwnProperty.call(STRINGS, reason) ? STRINGS[reason] : '';
    }

    function senderNym(nym, pubkey) {
        const base = str(nym).replace(/#[0-9a-f]{4}$/i, '').trim() || 'nym';
        return base + '#' + str(pubkey).slice(-4);
    }

    function scrubContext(input) {
        const i = input || {};
        const mine = new Set((Array.isArray(i.self) ? i.self : []).map((p) => str(p).toLowerCase()).filter(Boolean));
        const messages = (Array.isArray(i.messages) ? i.messages : [])
            .filter((m) => m && !m.pending)
            .map((m) => {
                const out = Object.assign({}, m, { pubkey: '' });
                delete out.pending;
                return out;
            });
        const users = (Array.isArray(i.users) ? i.users : [])
            .filter((u) => u && !mine.has(str(u.pubkey).toLowerCase()))
            .map((u) => Object.assign({}, u, { pubkey: '' }));
        return { messages, users };
    }

    function settleKeys(local, incoming, max) {
        const cap = max > 0 ? max : 4;
        const norm = (side) => {
            const cur = str(side && side.current).toLowerCase();
            const prev = (Array.isArray(side && side.prev) ? side.prev : []).map((p) => str(p).toLowerCase()).filter(Boolean);
            const at = Number(side && side.createdAt);
            return { current: cur || null, prev, at: at > 0 ? at : 0 };
        };
        const uniq = (list, skip) => {
            const out = [];
            for (const pk of list) if (pk && pk !== skip && out.indexOf(pk) < 0) out.push(pk);
            return out.slice(0, cap);
        };
        const L = norm(local);
        const I = norm(incoming);
        if (!I.current) return { current: L.current, prev: uniq(L.prev, L.current), loser: null, rule: 'keep' };
        if (!L.current) return { current: I.current, prev: uniq(I.prev, I.current), loser: null, rule: 'adopt' };
        if (L.current === I.current) return { current: L.current, prev: uniq(L.prev.concat(I.prev), L.current), loser: null, rule: 'same' };
        const iNext = I.prev.indexOf(L.current) >= 0;
        const lNext = L.prev.indexOf(I.current) >= 0;
        const aged = iNext && lNext && I.at > 0 && L.at > 0 && I.at !== L.at;
        const takeIncoming = iNext !== lNext ? iNext : (aged ? I.at > L.at : I.current < L.current);
        const W = takeIncoming ? I : L;
        const X = takeIncoming ? L : I;
        return { current: W.current, prev: uniq([X.current].concat(W.prev, X.prev), W.current), loser: X.current, rule: iNext !== lNext ? 'next' : (iNext ? 'newer' : 'lower') };
    }

    G.NymAnonNymbot = Object.freeze({
        STRINGS, triggers, blocker, outcome, notice, senderNym, scrubContext, settleKeys,
    });
})();
