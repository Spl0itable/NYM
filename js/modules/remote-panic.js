(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const KIND = 30078;
    const D_TAG = 'nym-panic';
    const TTL_S = 90 * 86400;
    const FUTURE_SKEW_S = 600;
    const SETTING = 'remotePanic';
    const LOGIN_KEY = 'nym_panic_login_at';
    const CHECK_EVERY_MS = 5 * 60 * 1000;

    const isInt = (n) => typeof n === 'number' && Number.isInteger(n);
    const isHex = (s, n) => typeof s === 'string' && s.length === n && /^[0-9a-f]+$/.test(s);

    function template(at) {
        return { kind: KIND, created_at: at, tags: [['d', D_TAG]], content: '' };
    }

    function fromRow(pubkey, row) {
        if (!row || typeof row !== 'object' || !isHex(pubkey, 64)) return null;
        if (!isInt(row.at) || !isHex(row.id, 64) || !isHex(row.sig, 128)) return null;
        return clean({ ...template(row.at), pubkey, id: row.id, sig: row.sig });
    }

    function shapeOk(ev) {
        if (!ev || typeof ev !== 'object') return false;
        if (ev.kind !== KIND || ev.content !== '' || !isInt(ev.created_at) || ev.created_at <= 0) return false;
        if (!Array.isArray(ev.tags) || ev.tags.length !== 1) return false;
        const t = ev.tags[0];
        if (!Array.isArray(t) || t.length !== 2 || t[0] !== 'd' || t[1] !== D_TAG) return false;
        return isHex(ev.pubkey, 64) && isHex(ev.id, 64) && isHex(ev.sig, 128);
    }

    function clean(ev) {
        return {
            id: ev.id, pubkey: ev.pubkey, created_at: ev.created_at, kind: ev.kind,
            tags: [['d', D_TAG]], content: '', sig: ev.sig
        };
    }

    function markerValid(ev, pubkey, verify) {
        if (!shapeOk(ev) || ev.pubkey !== pubkey) return false;
        try { return !!verify(clean(ev)); } catch (e) { return false; }
    }

    function decide(input, verify) {
        const i = input || {};
        if (!i.enabled) return { action: 'ignore', reason: 'off' };
        const m = i.marker;
        if (!m) return { action: 'ignore', reason: 'none' };
        if (!shapeOk(m)) return { action: 'ignore', reason: 'shape' };
        if (m.pubkey !== i.pubkey) return { action: 'ignore', reason: 'pubkey' };
        if (!markerValid(m, i.pubkey, verify)) return { action: 'ignore', reason: 'sig' };
        if (!isInt(i.loginAt) || i.loginAt <= 0) return { action: 'ignore', reason: 'nologin' };
        if (m.created_at <= i.loginAt) return { action: 'ignore', reason: 'before-login' };
        if (isInt(i.now) && m.created_at > i.now + FUTURE_SKEW_S) return { action: 'ignore', reason: 'future' };
        if (isInt(i.now) && i.now - m.created_at > TTL_S) return { action: 'ignore', reason: 'expired' };
        return { action: 'wipe', reason: 'wipe' };
    }

    function rumor(marker) {
        return {
            kind: KIND, created_at: marker.created_at, tags: [['d', D_TAG]],
            content: JSON.stringify(clean(marker)), pubkey: marker.pubkey
        };
    }

    function isRumor(r) {
        if (!r || r.kind !== KIND || !Array.isArray(r.tags)) return false;
        return r.tags.some((t) => Array.isArray(t) && t[0] === 'd' && t[1] === D_TAG);
    }

    function markerFromRumor(r) {
        if (!isRumor(r) || typeof r.content !== 'string') return null;
        try {
            const ev = JSON.parse(r.content);
            if (!shapeOk(ev) || ev.pubkey !== r.pubkey) return null;
            return clean(ev);
        } catch (e) { return null; }
    }

    function shouldSend(enabled, canSign) {
        return !!enabled && !!canSign;
    }

    G.NymRemotePanic = {
        KIND, D_TAG, TTL_S, FUTURE_SKEW_S, SETTING, LOGIN_KEY, CHECK_EVERY_MS,
        template, fromRow, shapeOk, markerValid, decide, rumor, isRumor, markerFromRumor, shouldSend,
    };
})();
