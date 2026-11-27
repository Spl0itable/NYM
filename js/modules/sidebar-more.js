(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const FIRST = 20;
    const STEP = 50;

    function count(v, fallback) {
        const n = Math.floor(Number(v));
        return Number.isFinite(n) ? Math.max(0, n) : fallback;
    }

    function window(total, shown, o) {
        const n = count(total, 0);
        const want = Math.max(FIRST, count(shown, FIRST));
        if (n <= FIRST) return { shown: FIRST, visible: n, hidden: 0, buttons: [] };
        if (o && o.searching === true) return { shown: want, visible: n, hidden: 0, buttons: [] };
        const visible = Math.min(want, n);
        const hidden = n - visible;
        const buttons = [];
        if (hidden > 0) buttons.push({ kind: want <= FIRST ? 'view' : 'show', n: Math.min(STEP, hidden), next: want + STEP });
        if (want > FIRST) buttons.push({ kind: 'less', n: 0, next: FIRST });
        return { shown: want, visible, hidden, buttons };
    }

    function press(win, kind) {
        const list = win && Array.isArray(win.buttons) ? win.buttons : [];
        const less = kind === 'less';
        const b = list.find((x) => x && (x.kind === 'less') === less);
        return b ? b.next : null;
    }

    function store(shown) {
        const s = count(shown, FIRST);
        return s > FIRST ? s : 0;
    }

    G.NymSidebarMore = Object.freeze({ FIRST, STEP, window, press, store });
})();
