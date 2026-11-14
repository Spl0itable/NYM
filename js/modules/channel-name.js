(function () {
    const G = (typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis));

    const RX_NAME = /^[\p{L}\p{N}]+$/u;
    const RX_CASED = /[\p{Lu}\p{Lt}]/u;

    function isChannelName(s) {
        return typeof s === 'string' && RX_NAME.test(s);
    }

    function lowerChannelName(name) {
        if (!/[^\x00-\x7f]/.test(name)) return name.toLowerCase();
        let out = '';
        for (const ch of name) out += ch === '\u0130' ? 'i' : ch.toLowerCase();
        return out;
    }

    function sanitizeChannelName(name) {
        if (typeof name !== 'string' || !name) return '';
        const lower = lowerChannelName(name);
        return isChannelName(lower) && !RX_CASED.test(lower) ? lower : '';
    }

    const api = Object.freeze({ isChannelName, lowerChannelName, sanitizeChannelName });
    G.NymChannelName = api;
    if (typeof module !== 'undefined' && module && typeof module === 'object') module.exports = api;
})();
