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

    G.NymAnonNymbot = Object.freeze({
        STRINGS, triggers, blocker, outcome, notice, senderNym, scrubContext,
    });
})();
