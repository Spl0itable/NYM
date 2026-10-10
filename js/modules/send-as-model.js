(function () {
    'use strict';
    const G = (typeof self !== 'undefined' ? self : window);

    const STRINGS = Object.freeze({
        header: 'Send as…',
        rowLabel: 'Send as {nym}',
        sending: 'Sending as {nym}…',
        sentAs: 'Sent as {nym}',
        failed: "Couldn't send as {nym}. Your message is back in the composer.",
        failedShort: "Couldn't send as {nym}.",
        putBack: 'Back to composer',
        locked: 'Locked. Switch to this identity to unlock it.',
        extension: 'Signs with a browser extension. Switch to it to send.',
        bunker: 'Signs with a remote signer. Switch to it to send.',
        offline: "You're offline.",
        nymbot: "Nymbot isn't turned on for this identity.",
        removed: 'That identity is no longer on this device.',
        quote: 'Wait until the quoted message is sent.',
    });

    const METHODS = Object.freeze(['nsec', 'ephemeral', 'extension', 'nip46']);
    const HEX = /^[0-9a-f]{64}$/;
    const NYM_MAX = 20;
    const PROBE_KEYS = Object.freeze([
        'nym_nostr_login_nsec', 'nym_session_nsec', 'nym_dev_nsec', 'nym_vault_enabled',
        'nym_keypair_mode', 'nym_random_keypair_per_session', 'nym_ai_consent',
        'nym_nostr_login_profile', 'nym_auto_ephemeral_nick',
    ]);

    function str(v) {
        return typeof v === 'string' ? v : '';
    }

    function canSendAs(ctx) {
        const c = ctx || {};
        return !!c.loggedIn && !c.anonymousActive && (c.surface || 'channel') === 'channel'
            && !c.editing && !c.mesh && !c.command;
    }

    function stateOf(a, input) {
        const signer = str(a.signer) || 'none';
        if (signer === 'locked') return 'locked';
        if (signer === 'extension') return 'extension';
        if (signer === 'bunker') return 'bunker';
        if (input.quotePending) return 'quote';
        if (!input.online) return 'offline';
        if (input.needsNymbot && str(a.aiConsent) !== 'allowed') return 'nymbot';
        return 'ready';
    }

    function listed(a, activeId, activePubkey) {
        if (!a || a.id === activeId) return false;
        const pk = str(a.pubkey);
        if (!HEX.test(pk) || pk === activePubkey) return false;
        const m = str(a.method);
        if (!METHODS.includes(m)) return false;
        if (m === 'ephemeral' && (a.keypairMode === 'random' || a.keypairMode === 'hardcore')) return false;
        return (str(a.signer) || 'none') !== 'none';
    }

    function rows(input) {
        const i = input || {};
        const accounts = Array.isArray(i.accounts) ? i.accounts.filter(Boolean) : [];
        const active = accounts.find((a) => a.id === i.activeId);
        const activePubkey = str(i.activePubkey) || (active ? str(active.pubkey) : '');
        const out = [];
        for (const a of accounts) {
            if (!listed(a, i.activeId, activePubkey)) continue;
            const raw = stateOf(a, i);
            const state = raw === 'extension' || raw === 'bunker' ? 'signer' : raw;
            out.push({
                id: 'as:' + a.id,
                account: a.id,
                nym: str(a.nym) || 'nym',
                suffix: a.pubkey.slice(-4),
                state,
                enabled: state === 'ready',
                reason: state === 'ready' ? '' : STRINGS[raw],
            });
        }
        return out;
    }

    function section(ctx, input) {
        const list = canSendAs(ctx) ? rows(input) : [];
        return { show: list.length > 0, count: list.length, rows: list };
    }

    function text(template, nym) {
        return str(template).split('{nym}').join(str(nym));
    }

    function secretNames(method) {
        if (method === 'nsec') return ['nym_nostr_login_nsec'];
        if (method === 'ephemeral') return ['nym_session_nsec', 'nym_dev_nsec'];
        return [];
    }

    function signerState(method, get) {
        const g = typeof get === 'function' ? get : () => null;
        if (method === 'extension') return 'extension';
        if (method === 'nip46') return 'bunker';
        const names = secretNames(method);
        if (!names.length) return 'none';
        const values = names.map((n) => str(g(n)));
        if (g('nym_vault_enabled') === '1' || values.some((v) => v.startsWith('enc:v1:'))) return 'locked';
        return values.some((v) => !!v) ? 'key' : 'none';
    }

    function keypairMode(get) {
        const g = typeof get === 'function' ? get : () => null;
        const m = str(g('nym_keypair_mode'));
        if (m) return m;
        return g('nym_random_keypair_per_session') === 'true' ? 'random' : '';
    }

    function nymFrom(get, method, fallback) {
        const g = typeof get === 'function' ? get : () => null;
        let nym = '';
        if (method === 'nsec' || method === 'extension' || method === 'nip46') {
            try {
                const p = JSON.parse(str(g('nym_nostr_login_profile')) || '{}');
                if (p && typeof p.name === 'string') nym = p.name;
            } catch (_) { nym = ''; }
        } else {
            nym = str(g('nym_auto_ephemeral_nick'));
        }
        nym = nym.replace(/#[0-9a-f]{4}$/i, '').trim();
        if (!nym) nym = str(fallback).replace(/#[0-9a-f]{4}$/i, '').trim();
        return (nym || 'nym').substring(0, NYM_MAX);
    }

    function difficulty(raw, floor) {
        const n = parseInt(raw, 10);
        const f = Number(floor) > 0 ? Number(floor) : 0;
        if (!Number.isFinite(n) || n <= 0) return f;
        return Math.max(n, f);
    }

    G.NymSendAs = Object.freeze({
        STRINGS, METHODS, PROBE_KEYS,
        canSendAs, rows, section, text, secretNames, signerState, keypairMode, nymFrom, difficulty,
    });
})();
