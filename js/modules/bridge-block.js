(function () {
    const G = (typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis));

    const NICK = 'radio-bridge';
    const CLIENT_MARK = 'meshtastic';
    const PROXY_PROTOCOL = 'meshtastic';
    const RX_NICK_SUFFIX = /#[0-9a-f]{4}$/;
    const RX_UPPER = /[A-Z]+/g;

    function asciiLower(s) {
        return s.replace(RX_UPPER, (m) => m.toLowerCase());
    }

    function isBridgeNick(v) {
        return typeof v === 'string' && asciiLower(v.trim()).replace(RX_NICK_SUFFIX, '') === NICK;
    }

    function isBridgeTag(tag) {
        if (!Array.isArray(tag)) return false;
        switch (tag[0]) {
            case 'n': return isBridgeNick(tag[1]);
            case 'client': return typeof tag[1] === 'string' && asciiLower(tag[1]).includes(CLIENT_MARK);
            case 'proxy': return typeof tag[2] === 'string' && asciiLower(tag[2].trim()) === PROXY_PROTOCOL;
            default: return false;
        }
    }

    function isBridgeBlockedTags(tags) {
        return Array.isArray(tags) && tags.some(isBridgeTag);
    }

    function isBridgeBlockedEvent(ev) {
        return !!ev && typeof ev === 'object' && isBridgeBlockedTags(ev.tags);
    }

    const api = Object.freeze({ NICK, CLIENT_MARK, PROXY_PROTOCOL, isBridgeNick, isBridgeTag, isBridgeBlockedTags, isBridgeBlockedEvent });
    G.NymBridgeBlock = api;
    if (typeof module !== 'undefined' && module && typeof module === 'object') module.exports = api;
})();
