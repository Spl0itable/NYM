(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const DTAG = 'nymchat-away';
    const PAYLOAD_KEY = 'awayStatus';
    const STORAGE_PREFIX = 'nym_away_state_';
    const SESSION_PREFIX = 'brb_universal_';
    const MESSAGE_MAX = 500;
    const AUTO_REPLY_TAG = '[Auto-Reply]';
    const DELAY_MIN_MS = 1000;
    const DELAY_SPAN_MS = 2000;
    const SKEW_SEC = 60;
    const RING_MS = 1500;
    const RING_RETRY_MS = 6000;
    const EDGES = /^\s+|\s+$/g;

    const trim = (s) => s.replace(EDGES, '');

    function normalize(raw) {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
        const u = raw.updatedAt;
        if (typeof u !== 'number' || !isFinite(u) || u < 0) return null;
        let message = typeof raw.message === 'string' ? trim(raw.message) : '';
        if (message.length > MESSAGE_MAX) message = trim(message.slice(0, MESSAGE_MAX));
        const enabled = raw.enabled === true && message.length > 0;
        return { enabled, message: enabled ? message : '', updatedAt: Math.floor(u) };
    }

    function merge(local, remote) {
        const a = normalize(local);
        const b = normalize(remote);
        if (!a) return b;
        if (!b) return a;
        if (b.updatedAt > a.updatedAt) return b;
        if (a.updatedAt > b.updatedAt) return a;
        if (a.enabled !== b.enabled) return a.enabled ? b : a;
        return a.message <= b.message ? a : b;
    }

    function next(prev, nowMs) {
        const p = normalize(prev);
        return p && p.updatedAt >= nowMs ? p.updatedAt + 1 : nowMs;
    }

    function enable(prev, message, nowMs) {
        return normalize({ enabled: true, message, updatedAt: next(prev, nowMs) });
    }

    function disable(prev, nowMs) {
        return { enabled: false, message: '', updatedAt: next(prev, nowMs) };
    }

    function encode(state) {
        const s = normalize(state);
        return s ? JSON.stringify(s) : null;
    }

    function decode(raw) {
        if (typeof raw !== 'string' || !raw) return null;
        try { return normalize(JSON.parse(raw)); } catch (_) { return null; }
    }

    function payload(state) {
        const s = normalize(state);
        return s ? { [PAYLOAD_KEY]: s } : null;
    }

    function fromPayload(p) {
        return p && typeof p === 'object' && !Array.isArray(p) ? normalize(p[PAYLOAD_KEY]) : null;
    }

    function presence(state) {
        const s = normalize(state);
        return s && s.enabled ? { status: 'away', message: s.message } : { status: 'online', message: '' };
    }

    function autoReplyText(nym, message) {
        return '@' + nym + ' ' + AUTO_REPLY_TAG + ' ' + message;
    }

    function delayMs(r) {
        let x = typeof r === 'number' && isFinite(r) ? r : 0;
        if (x < 0) x = 0;
        if (x > 1) x = 1;
        return DELAY_MIN_MS + Math.floor(x * DELAY_SPAN_MS);
    }

    function shouldAutoReply(i) {
        const o = i || {};
        const s = normalize(o.state);
        return !!(s && s.enabled && o.mentioned === true && o.historical !== true
            && typeof o.senderPubkey === 'string' && o.senderPubkey && o.senderPubkey !== o.selfPubkey);
    }

    function hasOwnAutoReply(messages, selfPubkey, nym, sinceSec) {
        if (!Array.isArray(messages)) return false;
        const prefix = '@' + nym + ' ' + AUTO_REPLY_TAG;
        return messages.some((m) => !!m && typeof m === 'object' && m.pubkey === selfPubkey
            && typeof m.content === 'string' && m.content.startsWith(prefix)
            && (typeof m.createdAt === 'number' ? m.createdAt : 0) >= sinceSec - SKEW_SEC);
    }

    function sinceSec(state) {
        const s = normalize(state);
        return s ? Math.floor(s.updatedAt / 1000) : 0;
    }

    function presenceRings(state, status, away, createdAtSec) {
        const s = normalize(state);
        const at = typeof createdAtSec === 'number' && isFinite(createdAtSec) ? createdAtSec : 0;
        if (s && at < sinceSec(s) - SKEW_SEC) return false;
        if (status === 'away') {
            if (!s || !s.enabled) return true;
            const msg = typeof away === 'string' ? trim(away) : '';
            return msg !== '' && msg !== s.message;
        }
        if (status === 'online') return !!(s && s.enabled);
        return false;
    }

    const storageKey = (pubkey) => STORAGE_PREFIX + pubkey;
    const sessionKey = (selfPubkey, nym) => SESSION_PREFIX + selfPubkey + '_' + nym;

    G.NymAwaySync = Object.freeze({
        DTAG, PAYLOAD_KEY, STORAGE_PREFIX, SESSION_PREFIX, MESSAGE_MAX, AUTO_REPLY_TAG,
        DELAY_MIN_MS, DELAY_SPAN_MS, SKEW_SEC, RING_MS, RING_RETRY_MS,
        normalize, merge, enable, disable, encode, decode, payload, fromPayload, presence,
        autoReplyText, delayMs, shouldAutoReply, hasOwnAutoReply, presenceRings, sinceSec, storageKey, sessionKey
    });
})();
