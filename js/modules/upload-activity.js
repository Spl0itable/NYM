(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const KINDS = Object.freeze(['photo', 'video', 'file', 'voice', 'recording-voice', 'recording-video']);
    const REFRESH_MS = 12000;
    const TTL_SEC = 15;
    const DEFAULT_EXPIRY_SEC = 15;
    const MAX_EXPIRY_SEC = 30;

    const ONE = {
        photo: '{nym} is sending a photo',
        video: '{nym} is sending a video',
        file: '{nym} is sending a file',
        voice: '{nym} is sending a voice message',
        'recording-voice': '{nym} is recording a voice message',
        'recording-video': '{nym} is recording a video message',
    };
    const TWO = {
        photo: '{nym} and {other} are sending photos',
        video: '{nym} and {other} are sending videos',
        file: '{nym} and {other} are sending files',
        voice: '{nym} and {other} are sending voice messages',
        'recording-voice': '{nym} and {other} are recording voice messages',
        'recording-video': '{nym} and {other} are recording video messages',
    };
    const MANY = {
        photo: '{n} people are sending photos',
        video: '{n} people are sending videos',
        file: '{n} people are sending files',
        voice: '{n} people are sending voice messages',
        'recording-voice': '{n} people are recording voice messages',
        'recording-video': '{n} people are recording video messages',
    };

    function isKind(k) {
        return typeof k === 'string' && KINDS.indexOf(k) >= 0;
    }

    function encode(status, activity, ttlSec) {
        const tags = [['typing', status]];
        if (status !== 'start') return tags;
        if (isKind(activity)) tags.push(['activity', activity]);
        const ttl = Math.floor(Number(ttlSec) || 0);
        if (ttl > 0) tags.push(['ttl', String(ttl)]);
        return tags;
    }

    function channelTags(status, activity, wireTag, channel, nym) {
        const tags = [['typing', status]];
        if (status === 'start' && isKind(activity)) tags.push(['activity', activity]);
        tags.push([wireTag, channel]);
        tags.push(['n', nym]);
        return tags;
    }

    function decode(tags) {
        if (!Array.isArray(tags)) return null;
        let status = null;
        let activity = null;
        let ttl = 0;
        for (const t of tags) {
            if (!Array.isArray(t) || t.length < 2) continue;
            if (t[0] === 'typing' && typeof t[1] === 'string') status = t[1];
            else if (t[0] === 'activity') activity = t[1];
            else if (t[0] === 'ttl') {
                const n = parseInt(t[1], 10);
                ttl = n > 0 ? n : 0;
            }
        }
        if (!status) return null;
        return { status, activity: status === 'start' && isKind(activity) ? activity : null, ttl };
    }

    function kindForMime(mime) {
        const m = String(mime || '').toLowerCase();
        if (m.startsWith('image/')) return 'photo';
        if (m.startsWith('video/')) return 'video';
        return 'file';
    }

    function kindForNote(kind) {
        if (kind === 'voice') return 'voice';
        if (kind === 'round') return 'video';
        return 'file';
    }

    function expiryMs(ttlSec) {
        const ttl = Math.floor(Number(ttlSec) || 0);
        return (ttl > 0 ? Math.min(ttl, MAX_EXPIRY_SEC) : DEFAULT_EXPIRY_SEC) * 1000;
    }

    function isStale(ageSec, ttlSec) {
        return Number(ageSec) * 1000 > expiryMs(ttlSec);
    }

    function label(typers) {
        const list = Array.isArray(typers) ? typers : [];
        if (!list.length) return '';
        const acts = list.map((t) => (t && isKind(t.activity) ? t.activity : null));
        const shared = acts[0] && acts.every((a) => a === acts[0]) ? acts[0] : null;
        if (list.length === 1) {
            if (shared) return ONE[shared];
            return list[0] && list[0].bot ? '{nym} is thinking' : '{nym} is typing';
        }
        if (list.length === 2) return shared ? TWO[shared] : '{nym} and {other} are typing';
        return shared ? MANY[shared] : '{n} people are typing';
    }

    G.NymUploadActivity = Object.freeze({
        KINDS, REFRESH_MS, TTL_SEC, isKind, encode, channelTags, decode, kindForMime, kindForNote, expiryMs, isStale, label,
    });
})();
