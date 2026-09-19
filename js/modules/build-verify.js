// Re-hashes the running HTML and JS/CSS bundle against /build-manifest.json, recomputes the
// bundleHash from those locally computed hashes, and anchors it to the official repo by looking
// up the digest of the canonical bundle-hash artifact in GitHub's signed build attestations, so
// the About dialog can prove the served code matches the published, reproducible build from the
// official repo rather than whatever the serving origin claims.

(function () {
    const MANIFEST_URL = '/build-manifest.json';
    const ATTESTATION_API = 'https://api.github.com/repos/Spl0itable/NYM/attestations/sha256:';
    const OFFICIAL_HOSTS = ['web.nymchat.app'];
    let pending = null;

    const EDGE_NONCE = "[A-Za-z0-9+/=_-]*";
    const EDGE_NONCE_ATTR = '(?: nonce="' + EDGE_NONCE + '")?';
    const EDGE_PLATFORM_PATH = '/cdn-cgi/challenge-platform/[A-Za-z0-9_./-]+';
    const EDGE_BOOTSTRAP = "<script\u00a7NONCEATTR\u00a7>(function(){function c(){var b=a.contentDocument||a.contentWindow.document;if(b){var d=b.createElement('script');d.innerHTML=\"window.__CF$cv$params={r:'\u00a7RAY\u00a7',t:'\u00a7TOKEN\u00a7'};var a=document.createElement('script');a.nonce='\u00a7NONCE\u00a7';a.src='\u00a7SRC\u00a7';document.getElementsByTagName('head')[0].appendChild(a);\";b.getElementsByTagName('head')[0].appendChild(d)}}if(document.body){var a=document.createElement('iframe');a.height=1;a.width=1;a.style.position='absolute';a.style.top=0;a.style.left=0;a.style.border='none';a.style.visibility='hidden';document.body.appendChild(a);if('loading'!==document.readyState)c();else if(window.addEventListener)document.addEventListener('DOMContentLoaded',c);else{var e=document.onreadystatechange||function(){};document.onreadystatechange=function(b){e(b);'loading'!==document.readyState&&(document.onreadystatechange=e,c())}}}})();</script>";

    function escapeRe(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    const EDGE_PATTERNS = [
        new RegExp('<script(?=[^<>]*\\ssrc="https://static\\.cloudflareinsights\\.com/beacon\\.min\\.js[^"<>]*")[^<>]*></script>', 'g'),
        new RegExp(escapeRe(EDGE_BOOTSTRAP)
            .replace('\u00a7NONCEATTR\u00a7', EDGE_NONCE_ATTR)
            .replace('\u00a7RAY\u00a7', '[0-9a-f]+')
            .replace('\u00a7TOKEN\u00a7', '[A-Za-z0-9+/=]+')
            .replace('\u00a7NONCE\u00a7', EDGE_NONCE)
            .replace('\u00a7SRC\u00a7', EDGE_PLATFORM_PATH), 'g'),
        new RegExp('<script(?=[^<>]*\\ssrc="' + EDGE_PLATFORM_PATH + '")[^<>]*></script>', 'g'),
    ];
    const META_NONCE = new RegExp('(<meta http-equiv="Content-Security-Policy" content="[^"]*?script-src) \'nonce-' + EDGE_NONCE + '\'');
    const INLINE_SCRIPT = /<script(?:\s[^<>]*)?>[\s\S]*?<\/script>/g;

    function stripEdgeInjection(html) {
        let removed = 0;
        for (const re of EDGE_PATTERNS) {
            html = html.replace(re, () => { removed++; return ''; });
        }
        html = html.replace(META_NONCE, '$1');
        return { html, removed };
    }

    function strayInlineScripts(html) {
        let count = 0;
        for (const m of html.matchAll(INLINE_SCRIPT)) {
            const open = m[0].slice(0, m[0].indexOf('>') + 1);
            if (/\ssrc=/.test(open) || /\stype="application\/ld\+json"/.test(open)) continue;
            count++;
        }
        return count;
    }

    async function servedBytes(path) {
        const cache = path !== '/sw.js' && /\.(js|css)$/.test(path) ? 'force-cache' : 'no-store';
        const r = await fetch(path, { cache });
        if (!r.ok) throw new Error('http ' + r.status);
        if (!/\.html$/.test(path)) return { buf: await r.arrayBuffer(), removed: 0, stray: 0 };
        const { html, removed } = stripEdgeInjection(await r.text());
        return { buf: new TextEncoder().encode(html), removed, stray: strayInlineScripts(html) };
    }

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
        let edgeInjected = 0;
        let strayScripts = 0;

        async function worker() {
            while (idx < paths.length) {
                const path = paths[idx++];
                try {
                    const { buf, removed, stray } = await servedBytes(path);
                    const got = await sha256b64(buf);
                    computed[path] = got;
                    edgeInjected += removed;
                    if (got === files[path]) verified++;
                    else { mismatches.push(path); strayScripts += stray; }
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
            edgeInjected,
            strayScripts,
            officialHost: OFFICIAL_HOSTS.indexOf(location.hostname) !== -1,
            ok: filesOk && anchored === true,
        };
    }

    window.stripEdgeInjection = stripEdgeInjection;

    window.verifyRunningBuild = function () {
        if (!pending) pending = run().catch((e) => { pending = null; throw e; });
        return pending;
    };

    // Hashes a named subset of the running bundle, in the manifest's own
    // format. Attestation enrollment probes a handful of paths the server
    // picks per challenge rather than the whole set, so this exists next to
    // run() instead of inside it: the About dialog wants all 87 assets, an
    // enrollment wants four and should not pay for the rest.
    window.hashRunningAssets = async function (paths) {
        const out = {};
        if (!Array.isArray(paths)) return out;
        for (const path of paths.slice(0, 12)) {
            if (typeof path !== 'string' || path[0] !== '/') continue;
            try {
                out[path] = await sha256b64((await servedBytes(path)).buf);
            } catch (_) { /* a path we cannot read is simply absent */ }
        }
        return out;
    };
})();
