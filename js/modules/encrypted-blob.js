(function () {
    const G = (typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis));

    const CHANNEL_KINDS = Object.freeze([20000, 23333]);
    const RX_PREFIX = /^v\d{1,2}:/;
    const RX_STANDARD = /^[A-Za-z0-9+/]+={0,2}$/;
    const RX_URL_SAFE = /^[A-Za-z0-9_-]+={0,2}$/;
    const RX_HEX = /^[0-9a-f]+$/i;
    const MAX_SEGMENTS = 8;
    const IV_BYTES = Object.freeze([12, 16]);
    const MIN_PAYLOAD_BYTES = 16;

    function segmentBytes(seg) {
        if (!seg || !(RX_STANDARD.test(seg) || RX_URL_SAFE.test(seg))) return -1;
        const body = seg.replace(/=+$/, '').length;
        if (body !== seg.length && seg.length % 4 !== 0) return -1;
        if (body % 4 === 1) return -1;
        return Math.floor(body * 3 / 4);
    }

    function isEncryptedBlobContent(content) {
        if (typeof content !== 'string' || !content) return false;
        const segs = content.trim().replace(RX_PREFIX, '').split(':');
        if (segs.length < 2 || segs.length > MAX_SEGMENTS) return false;
        if (RX_HEX.test(segs[segs.length - 1])) return false;
        const sizes = segs.map(segmentBytes);
        if (sizes.some((n) => n < 0)) return false;
        if (sizes[sizes.length - 1] < MIN_PAYLOAD_BYTES) return false;
        return sizes.slice(0, -1).some((n) => IV_BYTES.includes(n));
    }

    function isEncryptedBlobChannelEvent(ev) {
        return !!ev && typeof ev === 'object' && CHANNEL_KINDS.includes(ev.kind) && isEncryptedBlobContent(ev.content);
    }

    const api = Object.freeze({ CHANNEL_KINDS, isEncryptedBlobContent, isEncryptedBlobChannelEvent });
    G.NymEncryptedBlob = api;
    if (typeof module !== 'undefined' && module && typeof module === 'object') module.exports = api;
})();
