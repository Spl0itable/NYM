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

    G.NymNotifyView = Object.freeze({ threadOpen, onScreen, sees, outcome, addressed });
})();
