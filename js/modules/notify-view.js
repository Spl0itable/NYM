(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    function str(v) {
        return typeof v === 'string' ? v : '';
    }

    function normView(view) {
        const v = view && typeof view === 'object' ? view : {};
        const keys = Array.isArray(v.keys) ? v.keys.filter((k) => typeof k === 'string' && k) : [];
        const t = v.thread && typeof v.thread === 'object' ? v.thread : null;
        const thread = t && str(t.key) && str(t.root) ? { key: t.key, root: t.root } : null;
        return { focused: v.focused === true, keys, thread };
    }

    function normEvent(ev) {
        const e = ev && typeof ev === 'object' ? ev : {};
        return { key: str(e.key), root: str(e.root), notify: e.notify === true };
    }

    function threadOpen(view, ev) {
        const v = normView(view);
        const e = normEvent(ev);
        if (!e.key || !e.root || !v.thread) return false;
        return v.thread.key === e.key && v.thread.root === e.root;
    }

    function onScreen(view, ev) {
        const v = normView(view);
        const e = normEvent(ev);
        if (!e.key) return false;
        if (e.root) return threadOpen(v, e);
        return v.keys.includes(e.key);
    }

    function sees(view, ev) {
        return normView(view).focused && onScreen(view, ev);
    }

    function outcome(view, ev) {
        const v = normView(view);
        const e = normEvent(ev);
        const seen = sees(v, e);
        const alert = e.notify && !seen;
        return { badge: alert, sound: alert, read: seen, toast: alert && v.focused };
    }

    function addressed(input) {
        const i = input && typeof input === 'object' ? input : {};
        const kind = i.kind === 'pm' || i.kind === 'group' ? i.kind : 'channel';
        const mention = i.mention === true;
        if (i.thread === true) {
            if (i.threadMentionsOnly === true) return mention;
            if (mention || i.ownRoot === true || i.ownReply === true) return true;
            return kind === 'pm';
        }
        if (kind === 'channel') return mention;
        if (kind === 'group') return mention || i.groupMentionsOnly !== true;
        return true;
    }

    function num(v) {
        return typeof v === 'number' && isFinite(v) ? v : 0;
    }

    function readTs(ts, receivedAt, live) {
        const t = num(ts);
        const r = num(receivedAt);
        return live === true && r > t ? r : t;
    }

    function sameAlert(a, b) {
        const x = a && typeof a === 'object' ? a : {};
        const y = b && typeof b === 'object' ? b : {};
        const xi = str(x.eventId);
        const yi = str(y.eventId);
        if (xi && yi) return xi === yi;
        if ((x.exact === true && xi) || (y.exact === true && yi)) return false;
        return str(x.title) === str(y.title) && str(x.body) === str(y.body) &&
            str(x.sender) === str(y.sender) && Math.abs(num(x.ts) - num(y.ts)) < 60000;
    }

    function samePm(a, b) {
        const x = a && typeof a === 'object' ? a : {};
        const y = b && typeof b === 'object' ? b : {};
        if (str(x.pubkey) !== str(y.pubkey)) return false;
        const xi = str(x.nymId);
        const yi = str(y.nymId);
        if (xi && yi) return xi === yi;
        if (str(x.content) !== str(y.content)) return false;
        if (Math.abs(num(x.createdAt) - num(y.createdAt)) >= 5) return false;
        return !str(x.replyTo) || str(x.replyTo) === str(y.replyTo);
    }

    G.NymNotifyView = Object.freeze({ threadOpen, onScreen, sees, outcome, addressed, readTs, sameAlert, samePm });
})();
