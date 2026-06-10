// Fetches the signed warrant canary from GitHub so the About dialog can flag whether the
// statement is current, overdue (possible silenced request), or removed entirely.

(function () {
    const CANARY_URL = 'https://raw.githubusercontent.com/Spl0itable/NYM/main/canary.json';
    let pending = null;

    async function run() {
        const res = await fetch(CANARY_URL, { cache: 'no-store' });
        if (res.status === 404) return { state: 'gone' };
        if (!res.ok) throw new Error('http ' + res.status);
        const c = await res.json();
        const updatedAt = c.updatedAt ? Date.parse(c.updatedAt) : NaN;
        const dueBy = c.nextUpdateBy ? Date.parse(c.nextUpdateBy) : NaN;
        const overdue = Number.isFinite(dueBy) && Date.now() > dueBy;
        const clear = c.allClear !== false && !overdue;
        return {
            state: clear ? 'ok' : 'stale',
            statement: c.statement || '',
            updatedAt: Number.isFinite(updatedAt) ? updatedAt : null,
            dueBy: Number.isFinite(dueBy) ? dueBy : null,
            overdue,
        };
    }

    window.checkWarrantCanary = function () {
        if (!pending) pending = run().catch((e) => { pending = null; throw e; });
        return pending;
    };
})();
