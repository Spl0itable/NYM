(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const FIRST = 20;
    const STEP = 50;

    function count(v, fallback) {
        const n = Math.floor(Number(v));
        return Number.isFinite(n) ? Math.max(0, n) : fallback;
    }

    function keepSet(keep, total) {
        const out = new Set();
        if (!Array.isArray(keep)) return out;
        for (const raw of keep) {
            const i = Number(raw);
            if (Number.isInteger(i) && i >= 0 && i < total) out.add(i);
        }
        return out;
    }

    function keptPast(ks, from) {
        let n = 0;
        for (const i of ks) if (i >= from) n++;
        return n;
    }

    function window(total, shown, keep, o) {
        const n = count(total, 0);
        const want = Math.max(FIRST, count(shown, FIRST));
        if (n <= FIRST) return { shown: FIRST, visible: n, hidden: 0, buttons: [] };
        if (o && o.searching === true) return { shown: want, visible: n, hidden: 0, buttons: [] };
        const ks = keepSet(keep, n);
        const visible = Math.min(want, n) + keptPast(ks, want);
        const hidden = n - visible;
        const buttons = [];
        if (hidden > 0) {
            const step = Math.min(STEP, hidden);
            let seen = 0;
            let i = want;
            while (seen < step) {
                if (!ks.has(i)) seen++;
                i++;
            }
            buttons.push({ kind: want <= FIRST ? 'view' : 'show', n: step, next: Math.max(i, want + STEP) });
        }
        if (want > FIRST && n - (FIRST + keptPast(ks, FIRST)) > 0) buttons.push({ kind: 'less', n: 0, next: FIRST });
        return { shown: want, visible, hidden, buttons };
    }

    function hiddenRows(total, shown, keep, o) {
        const n = count(total, 0);
        const want = Math.max(FIRST, count(shown, FIRST));
        if (n <= FIRST || (o && o.searching === true)) return [];
        const ks = keepSet(keep, n);
        const out = [];
        for (let i = want; i < n; i++) if (!ks.has(i)) out.push(i);
        return out;
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

    G.NymSidebarMore = Object.freeze({ FIRST, STEP, window, hiddenRows, press, store });
})();
