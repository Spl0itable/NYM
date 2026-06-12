// Fetches the warrant canary from GitHub and, when it is a signed Nostr event, verifies the
// developer signature so the About dialog can flag a current, overdue, removed, or forged canary.

(function () {
    const CANARY_URL = 'https://raw.githubusercontent.com/Spl0itable/NYM/main/canary.json';
    const CANARY_PUBKEY = 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';
    let pending = null;

    function verifySig(doc) {
        if (!doc || !doc.sig || !doc.pubkey || !doc.id) return 'unsigned';
        const NT = window.NostrTools;
        if (!NT || typeof NT.verifyEvent !== 'function') return 'unverifiable';
        try {
            return (NT.verifyEvent(doc) && doc.pubkey === CANARY_PUBKEY) ? 'valid' : 'invalid';
        } catch (_) {
            return 'unverifiable';
        }
    }

    async function run() {
        const res = await fetch(CANARY_URL, { cache: 'no-store' });
        if (res.status === 404) return { state: 'gone' };
        if (!res.ok) throw new Error('http ' + res.status);
        const doc = await res.json();
        const signed = doc && typeof doc.content === 'string' && doc.sig;
        const sig = signed ? verifySig(doc) : 'unsigned';
        const c = signed ? JSON.parse(doc.content) : doc;
        const updatedAt = c.updatedAt ? Date.parse(c.updatedAt) : NaN;
        const dueBy = c.nextUpdateBy ? Date.parse(c.nextUpdateBy) : NaN;
        const overdue = Number.isFinite(dueBy) && Date.now() > dueBy;
        const sigOk = sig === 'valid';
        const clear = c.allClear !== false && !overdue && sigOk;
        return {
            state: sig === 'invalid' ? 'forged' : (clear ? 'ok' : 'stale'),
            sig,
            statement: c.statement || '',
            updatedAt: Number.isFinite(updatedAt) ? updatedAt : null,
            dueBy: Number.isFinite(dueBy) ? dueBy : null,
            overdue,
            btcBlock: c.btcBlock || null,
            id: doc.id || '',
            pubkey: doc.pubkey || '',
        };
    }

    window.checkWarrantCanary = function () {
        if (!pending) pending = run().catch((e) => { pending = null; throw e; });
        return pending;
    };
})();
