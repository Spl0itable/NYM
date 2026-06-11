// Re-hashes the running HTML and JS/CSS bundle against /build-manifest.json, recomputes the
// bundleHash from those locally computed hashes, and anchors it to the official repo by looking
// up the digest of the canonical bundle-hash artifact in GitHub's signed build attestations, so
// the About dialog can prove the served code matches the published, reproducible build from the
// official repo rather than whatever the serving origin claims.

(function () {
    const MANIFEST_URL = '/build-manifest.json';
    const ATTESTATION_API = 'https://api.github.com/repos/Spl0itable/NYM/attestations/sha256:';
    let pending = null;

    async function digest(buf) {
        return new Uint8Array(await crypto.subtle.digest('SHA-256', buf));
    }

    async function sha256b64(buf) {
        const bytes = await digest(buf);
        let bin = '';
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return 'sha256-' + btoa(bin);
    }

    async function sha256hex(buf) {
        const bytes = await digest(buf);
        let hex = '';
        for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
        return hex;
    }

    async function checkAttestation(bundleHash) {
        try {
            const subject = await sha256hex(new TextEncoder().encode(bundleHash + '\n'));
            const res = await fetch(ATTESTATION_API + subject, { cache: 'no-store' });
            if (res.status === 404) return false;
            if (!res.ok) return null;
            const data = await res.json();
            return Array.isArray(data.attestations) && data.attestations.length > 0;
        } catch (_) {
            return null;
        }
    }

    async function run() {
        const res = await fetch(MANIFEST_URL, { cache: 'no-store' });
        if (!res.ok) throw new Error('manifest unavailable');
        const manifest = await res.json();
        const files = manifest.files || {};
        const paths = Object.keys(files);
        const computed = {};
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
                    computed[path] = got;
                    if (got === files[path]) verified++;
                    else mismatches.push(path);
                } catch (_) {
                    mismatches.push(path);
                }
            }
        }

        const lanes = Math.min(6, paths.length) || 1;
        await Promise.all(Array.from({ length: lanes }, worker));

        const bundleHash = await sha256hex(new TextEncoder().encode(
            paths.slice().sort().map((p) => p + ':' + (computed[p] || '')).join('\n')
        ));
        const anchored = await checkAttestation(bundleHash);
        const filesOk = paths.length > 0 && mismatches.length === 0;

        return {
            commit: manifest.commit || 'unknown',
            bundleHash,
            builtAt: manifest.builtAt || '',
            total: paths.length,
            verified,
            mismatches,
            anchored,
            filesOk,
            ok: filesOk && anchored === true,
        };
    }

    window.verifyRunningBuild = function () {
        if (!pending) pending = run().catch((e) => { pending = null; throw e; });
        return pending;
    };
})();
