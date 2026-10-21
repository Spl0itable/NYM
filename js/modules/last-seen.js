(function (root) {
    const ACTIVE_THRESHOLD_MS = 300000;

    const valid = (v) => (typeof v === 'number' && Number.isFinite(v) && v > 0) ? v : 0;

    function merge(prevMs, eventMs, nowMs) {
        const best = Math.max(valid(prevMs), valid(eventMs));
        return best > nowMs ? nowMs : best;
    }

    function isActive(atMs, nowMs) {
        const at = valid(atMs);
        return at > 0 && nowMs - at < ACTIVE_THRESHOLD_MS;
    }

    const ACTIVITY_STATUSES = ['online', 'active'];

    function presenceActivityMs(status, eventMs) {
        return ACTIVITY_STATUSES.includes(status) ? valid(eventMs) : 0;
    }

    function mergePresence(prevMs, status, eventMs, nowMs) {
        return merge(prevMs, presenceActivityMs(status, eventMs), nowMs);
    }

    function view(input) {
        const o = input || {};
        if (o.bot) return { state: 'bot', atMs: 0 };
        if (o.hidden) return { state: 'hidden', atMs: 0 };
        const nowMs = o.nowMs;
        let at = 0;
        for (const v of (o.seenMs || [])) at = merge(at, v, nowMs);
        if (o.away) return { state: 'away', atMs: at };
        if (isActive(at, nowMs)) return { state: 'active', atMs: at };
        if (at > 0) return { state: 'seen', atMs: at };
        return { state: 'unknown', atMs: 0 };
    }

    root.NymLastSeen = { ACTIVE_THRESHOLD_MS, isActive, merge, view, presenceActivityMs, mergePresence };
})(typeof self !== 'undefined' ? self : globalThis);
