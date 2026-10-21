(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const IDLE_MS = 120000;
    const THROTTLE_MS = 60000;
    const ACTIVITY = Object.freeze(['pointer', 'key', 'wheel', 'focus', 'visible', 'open-chat', 'react', 'type', 'send']);
    const EVALUATE_ONLY = Object.freeze(['connect']);

    function countsAsActivity(kind) {
        return typeof kind === 'string' && ACTIVITY.includes(kind);
    }

    function evaluates(kind) {
        return countsAsActivity(kind) || (typeof kind === 'string' && EVALUATE_ONLY.includes(kind));
    }

    function decide(s) {
        const now = Number(s && s.now) || 0;
        const lastInput = Number(s && s.lastInputMs) || 0;
        const lastBroadcast = Number(s && s.lastBroadcastMs) || 0;
        if (!s || !s.hasIdentity || s.mode === 'disabled') return 'off';
        if (s.away) return 'away';
        if (!s.visible || !s.focused) return 'background';
        const sinceInput = now - lastInput;
        if (lastInput <= 0 || sinceInput < 0 || sinceInput >= IDLE_MS) return 'idle';
        const sinceBroadcast = now - lastBroadcast;
        if (lastBroadcast > 0 && sinceBroadcast >= 0 && sinceBroadcast < THROTTLE_MS) return 'throttled';
        return s.mode === 'friends' ? 'friends' : 'publish';
    }

    G.NymPresenceActivity = Object.freeze({ IDLE_MS, THROTTLE_MS, ACTIVITY, EVALUATE_ONLY, countsAsActivity, evaluates, decide });
})();
