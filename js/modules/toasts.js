(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const CONFIG = Object.freeze({
        maxVisible: 3,
        dedupeMs: 2000,
        baseMs: Object.freeze({ info: 3500, success: 3500, error: 6000 }),
        capMs: Object.freeze({ info: 8000, success: 8000, error: 10000 }),
        readableChars: 80,
        msPerExtraChar: 40,
        swipeDismissPx: 60,
        undoMs: 5000,
    });

    const KINDS = Object.freeze(['info', 'success', 'error']);

    const ERROR_WORDS = [
        'failed', 'fail', 'could not', "couldn't", 'cannot', "can't", 'unable', 'error', 'invalid',
        'not found', 'not available', 'unavailable', 'not supported', 'rejected', 'denied',
        'too many', 'slow down', 'too large', 'too long', 'not connected', 'lost', 'no longer',
        'not allowed', 'disabled for', 'expired', 'only the', 'must be', 'you must',
        'unknown', 'is blocked', 'require', 'requires',
    ];

    const SUCCESS_WORDS = [
        'copied', 'saved', 'success', 'successfully', 'added', 'enabled', 'activated', 'applied',
        'sent', 'created', 'updated', 'restored', 'uploaded', 'joined', 'transferred', 'granted',
        'cleared', 'deleted', 'removed', 'unblocked', 'blocked', 'complete', 'completed',
        'downloaded', 'renamed', 'revoked', 'received',
    ];

    const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const wordsRe = (words) => new RegExp('(^|[^a-z0-9])(' + words.map(escapeRe).join('|') + ')(?![a-z0-9])');
    const ERROR_RE = wordsRe(ERROR_WORDS);
    const SUCCESS_RE = wordsRe(SUCCESS_WORDS);

    function normalize(text) {
        return String(text == null ? '' : text).replace(/[‘’]/g, "'").replace(/\s+/g, ' ').trim();
    }

    function classify(text) {
        const s = normalize(text);
        if (s.startsWith('❌')) return 'error';
        if (s.startsWith('✅')) return 'success';
        const low = s.toLowerCase();
        if (ERROR_RE.test(low)) return 'error';
        if (SUCCESS_RE.test(low)) return 'success';
        return 'info';
    }

    function kindOf(kind) {
        return KINDS.includes(kind) ? kind : 'info';
    }

    function durationFor(text, kind) {
        const k = kindOf(kind);
        const extra = Math.max(0, normalize(text).length - CONFIG.readableChars) * CONFIG.msPerExtraChar;
        return Math.min(CONFIG.capMs[k], CONFIG.baseMs[k] + extra);
    }

    function keyOf(text, kind) {
        return kindOf(kind) + '\u0000' + normalize(text);
    }

    function emptyQueue() {
        return { toasts: [], recent: {}, seq: 0 };
    }

    function prune(recent, now) {
        const out = {};
        for (const k of Object.keys(recent)) {
            if (now - recent[k] < CONFIG.dedupeMs) out[k] = recent[k];
        }
        return out;
    }

    function push(state, text, kind, now, action) {
        const k = kindOf(kind || classify(text));
        const label = typeof action === 'string' && action.trim() ? action.trim() : null;
        const key = label ? k + '\u0001' + (state.seq + 1) : keyOf(text, k);
        const recent = prune(state.recent, now);
        const live = state.toasts.find((t) => t.key === key);
        if (live) {
            const duration = durationFor(text, k);
            const toasts = state.toasts.map((t) => (t === live
                ? Object.assign({}, t, t.paused ? { remaining: duration } : { expiresAt: now + duration })
                : t));
            recent[key] = now;
            return { state: { toasts, recent, seq: state.seq }, id: live.id, deduped: true, evicted: [] };
        }
        if (recent[key] !== undefined) {
            return { state: { toasts: state.toasts, recent, seq: state.seq }, id: null, deduped: true, evicted: [] };
        }
        const seq = state.seq + 1;
        const toast = {
            id: seq,
            key,
            text: normalize(text),
            kind: k,
            expiresAt: now + (label ? CONFIG.undoMs : durationFor(text, k)),
            paused: false,
            remaining: 0,
        };
        if (label) toast.action = label;
        let toasts = state.toasts.concat([toast]);
        const evicted = [];
        while (toasts.length > CONFIG.maxVisible) {
            evicted.push(toasts[0].id);
            toasts = toasts.slice(1);
        }
        recent[key] = now;
        return { state: { toasts, recent, seq }, id: seq, deduped: false, evicted };
    }

    function dismiss(state, id) {
        return Object.assign({}, state, { toasts: state.toasts.filter((t) => t.id !== id) });
    }

    function pause(state, id, now) {
        return Object.assign({}, state, {
            toasts: state.toasts.map((t) => (t.id === id && !t.paused
                ? Object.assign({}, t, { paused: true, remaining: Math.max(0, t.expiresAt - now) })
                : t)),
        });
    }

    function resume(state, id, now) {
        return Object.assign({}, state, {
            toasts: state.toasts.map((t) => (t.id === id && t.paused
                ? Object.assign({}, t, { paused: false, expiresAt: now + t.remaining, remaining: 0 })
                : t)),
        });
    }

    function expire(state, now) {
        const gone = state.toasts.filter((t) => !t.paused && t.expiresAt <= now).map((t) => t.id);
        if (!gone.length) return { state, expired: [] };
        return {
            state: Object.assign({}, state, { toasts: state.toasts.filter((t) => !gone.includes(t.id)) }),
            expired: gone,
        };
    }

    function nextExpiry(state) {
        let next = null;
        for (const t of state.toasts) {
            if (t.paused) continue;
            if (next === null || t.expiresAt < next) next = t.expiresAt;
        }
        return next;
    }

    G.NymToasts = Object.freeze({
        CONFIG, KINDS, ERROR_WORDS, SUCCESS_WORDS,
        normalize, classify, durationFor, emptyQueue, push, dismiss, pause, resume, expire, nextExpiry,
    });
})();
