// Verifies the served bundle against /build-manifest.json and the repo's signed build attestations.

(function () {
    const MANIFEST_URL = '/build-manifest.json';
    const ATTESTATION_API = 'https://api.github.com/repos/Spl0itable/NYM/attestations/sha256:';
    const OFFICIAL_HOSTS = ['web.nymchat.app'];
    let pending = null;

    const EDGE_NONCE = "[A-Za-z0-9+/=_-]*";
    const EDGE_NONCE_ATTR = '(?: nonce="' + EDGE_NONCE + '")?';
    const EDGE_PLATFORM_PATH = '/cdn-cgi/challenge-platform(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+';
    const EDGE_RAY_QUERY = '(?:\\?ray=[0-9a-f]+)?';
    const EDGE_BOOTSTRAP = "<script\u00a7NONCEATTR\u00a7>window.__CF$cv$params={r:'\u00a7RAY\u00a7',t:'\u00a7TOKEN\u00a7'\u00a7SESSION\u00a7};(function(){if(!document.body)return;var s=document.createElement('script');s.nonce='\u00a7NONCE\u00a7';s.src='\u00a7SRC\u00a7';document.head.appendChild(s);})();</script>";
    const EDGE_BOOTSTRAP_LEGACY = "<script\u00a7NONCEATTR\u00a7>(function(){function c(){var b=a.contentDocument||a.contentWindow.document;if(b){var d=b.createElement('script');d.innerHTML=\"window.__CF$cv$params={r:'\u00a7RAY\u00a7',t:'\u00a7TOKEN\u00a7'};var a=document.createElement('script');a.nonce='\u00a7NONCE\u00a7';a.src='\u00a7SRC\u00a7';document.getElementsByTagName('head')[0].appendChild(a);\";b.getElementsByTagName('head')[0].appendChild(d)}}if(document.body){var a=document.createElement('iframe');a.height=1;a.width=1;a.style.position='absolute';a.style.top=0;a.style.left=0;a.style.border='none';a.style.visibility='hidden';document.body.appendChild(a);if('loading'!==document.readyState)c();else if(window.addEventListener)document.addEventListener('DOMContentLoaded',c);else{var e=document.onreadystatechange||function(){};document.onreadystatechange=function(b){e(b);'loading'!==document.readyState&&(document.onreadystatechange=e,c())}}}})();</script>";
    const EDGE_BOOTSTRAP_ORIGIN = "<script\u00a7NONCEATTR\u00a7>window.__CF$cv$params={r:'\u00a7RAY\u00a7',t:'\u00a7TOKEN\u00a7'\u00a7SESSION\u00a7};(function(){if(!document.body)return;var l=window.location,o;try{o=new URL(l.origin).origin}catch(e){try{o=new URL(new URL(l.href).origin).origin}catch(e){o=''}}var u='\u00a7SRC\u00a7\u00a7RAYQUERY\u00a7',s=document.createElement('script');s.nonce='\u00a7NONCE\u00a7';s.src=o?new URL(u,o).href:u;document.head.appendChild(s);})();</script>";

    function escapeRe(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    function bootstrapRe(template) {
        return new RegExp(escapeRe(template)
            .replace('\u00a7NONCEATTR\u00a7', EDGE_NONCE_ATTR)
            .replace('\u00a7RAY\u00a7', '(?<ray>[0-9a-f]+)')
            .replace('\u00a7TOKEN\u00a7', '[A-Za-z0-9+/=]+')
            .replace('\u00a7SESSION\u00a7', "(?:,u:'[0-9a-f]+')?(?:,ut:'[A-Za-z0-9._-]+')?(?:,i:[0-9]+)?")
            .replace('\u00a7NONCE\u00a7', EDGE_NONCE)
            .replace('\u00a7SRC\u00a7', EDGE_PLATFORM_PATH)
            .replace('\u00a7RAYQUERY\u00a7', '(?:\\?ray=\\k<ray>)?'));
    }

    const EDGE_TAG = /<script((?:[\t\n\f\r ]+[a-z-]+(?:="[^"<>]*"|='[^'<>]*')?)+)><\/script>/g;
    const EDGE_TAG_ATTR = /[\t\n\f\r ]+([a-z-]+)(?:="([^"<>]*)"|='([^'<>]*)')?/g;
    const EDGE_TAG_EXTRA = ['nonce', 'defer', 'async', 'integrity', 'crossorigin', 'data-cf-beacon', 'data-cf-settings'];
    const EDGE_BEACON_SRC = /^https:\/\/static\.cloudflareinsights\.com\/beacon\.min\.js[^"<>]*$/;
    const EDGE_PLATFORM_SRC = new RegExp('^' + EDGE_PLATFORM_PATH + EDGE_RAY_QUERY + '$');
    const ROCKET_LOADER_SRC = /^\/cdn-cgi\/scripts\/[0-9a-f]+\/cloudflare-static\/rocket-loader\.min\.js$/;
    const ROCKET_LOADER_SETTINGS = /^([0-9a-f]+)-[^"<>]*$/;

    function edgeTag(attrs, src) {
        const seen = new Map();
        for (const [, name, dq, sq] of attrs.matchAll(EDGE_TAG_ATTR)) {
            const value = dq ?? sq ?? null;
            if (seen.has(name)) return null;
            if (name === 'type' ? value !== 'module' : name !== 'src' && !EDGE_TAG_EXTRA.includes(name)) return null;
            seen.set(name, value);
        }
        return src.test(seen.get('src') ?? '') ? seen : null;
    }

    const EDGE_PATTERNS = [
        [EDGE_TAG, EDGE_BEACON_SRC],
        [bootstrapRe(EDGE_BOOTSTRAP)],
        [bootstrapRe(EDGE_BOOTSTRAP_LEGACY)],
        [bootstrapRe(EDGE_BOOTSTRAP_ORIGIN)],
        [EDGE_TAG, EDGE_PLATFORM_SRC],
    ];
    const META_NONCE = new RegExp('(<meta http-equiv="Content-Security-Policy" content="[^"]*?script-src) \\\'nonce-' + EDGE_NONCE + '\\\'');
    const INLINE_SCRIPT = /<script(?:\s[^<>]*)?>[\s\S]*?<\/script>/g;

    function stripEdgeInjection(html) {
        let removed = 0;
        let marker = '';
        html = html.replace(EDGE_TAG, (tag, attrs) => {
            const loader = !marker && edgeTag(attrs, ROCKET_LOADER_SRC);
            const settings = loader && ROCKET_LOADER_SETTINGS.exec(loader.get('data-cf-settings') ?? '');
            if (!settings) return tag;
            marker = ' type="' + settings[1] + '-text/javascript"';
            removed++;
            return '';
        });
        if (marker) html = html.replace(/<script\s[^<>]*>/g, (tag) => tag.split(marker).join(''));
        for (const [re, src] of EDGE_PATTERNS) {
            html = html.replace(re, (tag, attrs) => {
                if (src && !edgeTag(attrs, src)) return tag;
                removed++;
                return '';
            });
        }
        html = html.replace(META_NONCE, '$1');
        return { html, removed };
    }

    function strayInlineScripts(html) {
        const out = [];
        for (const m of html.matchAll(INLINE_SCRIPT)) {
            const open = m[0].slice(0, m[0].indexOf('>') + 1);
            if (/\ssrc=/.test(open) || /\stype="application\/ld\+json"/.test(open)) continue;
            out.push(m[0]);
        }
        return out;
    }

    async function servedBytes(path) {
        const cache = path !== '/sw.js' && /\.(js|css)$/.test(path) ? 'force-cache' : 'no-store';
        const r = await fetch(path, { cache });
        if (!r.ok) throw new Error('http ' + r.status);
        if (!/\.html$/.test(path)) return { buf: await r.arrayBuffer(), removed: 0, stray: [] };
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
                    else {
                        mismatches.push(path);
                        strayScripts += stray.length;
                        for (const text of stray) console.warn('[NYM] Unrecognised inline script in ' + path + ':\n' + text);
                    }
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

    // Hashes only a named subset of the bundle, for attestation enrollment challenges.
    window.hashRunningAssets = async function (paths) {
        const out = {};
        if (!Array.isArray(paths)) return out;
        for (const path of paths.slice(0, 12)) {
            if (typeof path !== 'string' || path[0] !== '/') continue;
            try {
                out[path] = await sha256b64((await servedBytes(path)).buf);
            } catch (_) { }
        }
        return out;
    };
})();
