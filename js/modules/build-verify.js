// Re-hashes the running HTML and JS/CSS bundle against /build-manifest.json so the About
// dialog can prove the served code matches the published, reproducible build from official repo.

(function () {
    const MANIFEST_URL = '/build-manifest.json';
    let pending = null;

    async function sha256b64(buf) {
        const digest = await crypto.subtle.digest('SHA-256', buf);
        const bytes = new Uint8Array(digest);
        let bin = '';
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return 'sha256-' + btoa(bin);
    }

    async function run() {
        const res = await fetch(MANIFEST_URL, { cache: 'no-store' });
        if (!res.ok) throw new Error('manifest unavailable');
        const manifest = await res.json();
        const files = manifest.files || {};
        const paths = Object.keys(files);
        const mismatches = [];
        let verified = 0;
        let idx = 0;

        async function worker() {
            while (idx < paths.length) {
                const path = paths[idx++];
                try {
                    const cache = /\.(js|css)$/.test(path) ? 'force-cache' : 'no-store';
                    const r = await fetch(path, { cache });
                    if (!r.ok) throw new Error('http ' + r.status);
                    const got = await sha256b64(await r.arrayBuffer());
                    if (got === files[path]) verified++;
                    else mismatches.push(path);
                } catch (_) {
                    mismatches.push(path);
                }
            }
        }

        const lanes = Math.min(6, paths.length) || 1;
        await Promise.all(Array.from({ length: lanes }, worker));

        return {
            commit: manifest.commit || 'unknown',
            bundleHash: manifest.bundleHash || '',
            builtAt: manifest.builtAt || '',
            total: paths.length,
            verified,
            mismatches,
            ok: paths.length > 0 && mismatches.length === 0,
        };
    }

    window.verifyRunningBuild = function () {
        if (!pending) pending = run().catch((e) => { pending = null; throw e; });
        return pending;
    };
})();
