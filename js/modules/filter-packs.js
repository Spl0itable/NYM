(function () {
    const PACK_IDS = ['profanity', 'scams', 'crypto', 'politics'];

    // Literal paths: the build only rewrites '/data/...' references written out in full.
    const PACK_URLS = {
        profanity: '/data/filter-packs/profanity.json',
        scams: '/data/filter-packs/scams.json',
        crypto: '/data/filter-packs/crypto.json',
        politics: '/data/filter-packs/politics.json'
    };

    const compiled = new Map();
    const loading = new Map();

    // Only the first this many characters are scanned.
    const SCAN_LIMIT = 8000;

    // Characters that look like ASCII letters; the fullwidth forms come free from NFKD.
    const HOMOGLYPHS = {
        'а': 'a', 'ӓ': 'a', 'ɑ': 'a', 'α': 'a', 'ａ': 'a',
        'ь': 'b', 'β': 'b', 'Ь': 'b',
        'с': 'c', 'ϲ': 'c', 'ⅽ': 'c',
        'ԁ': 'd', 'ⅾ': 'd',
        'е': 'e', 'ё': 'e', 'ε': 'e', 'ҽ': 'e',
        'ɡ': 'g', 'ģ': 'g',
        'һ': 'h', 'ℎ': 'h',
        'і': 'i', 'ı': 'i', 'ι': 'i', 'ⅰ': 'i', 'ɩ': 'i',
        'ј': 'j', 'ϳ': 'j',
        'κ': 'k', 'ⲕ': 'k',
        'ⅼ': 'l', 'ӏ': 'l', 'ℓ': 'l',
        'м': 'm', 'ⅿ': 'm', 'μ': 'm',
        'п': 'n', 'ή': 'n', 'ո': 'n',
        'о': 'o', 'ο': 'o', 'σ': 'o', 'ø': 'o', 'θ': 'o', 'ⲟ': 'o',
        'р': 'p', 'ρ': 'p', 'ρ': 'p',
        'ԛ': 'q',
        'г': 'r', 'ɾ': 'r',
        'ѕ': 's', 'ș': 's',
        'т': 't', 'τ': 't', 'ţ': 't',
        'υ': 'u', 'ս': 'u', 'μ': 'u',
        'ν': 'v', 'ѵ': 'v', 'ⅴ': 'v',
        'ԝ': 'w', 'ѡ': 'w', 'ω': 'w',
        'х': 'x', 'χ': 'x', 'ⅹ': 'x',
        'у': 'y', 'γ': 'y', 'ү': 'y',
        'ᴢ': 'z', 'ζ': 'z'
    };

    // Applied as alternatives in the compiled term, never as a text rewrite, so numbers stay intact.
    const LEET = {
        a: 'a@4', b: 'b8', c: 'c', d: 'd', e: 'e3', f: 'f', g: 'g69',
        h: 'h', i: 'i1!|', j: 'j', k: 'k', l: 'l1|', m: 'm', n: 'n',
        o: 'o0', p: 'p', q: 'q', r: 'r', s: 's5$', t: 't7', u: 'u',
        v: 'v', w: 'w', x: 'x', y: 'y', z: 'z2'
    };

    // Converted in the text: @ $ next to a letter (not a digit), ! | only between two letters.
    const AT_DOLLAR_RE = /(?<=\p{L})[@$]|[@$](?=\p{L})/gu;
    const BANG_PIPE_RE = /(?<=\p{L})[!|]+(?=\p{L})/gu;

    // Deleted only between two alphanumerics, catching "f.u.c.k" without joining sentences.
    const MIDWORD_STRIP = /(?<=[\p{L}\p{N}])[.\-_*'’`~^+]+(?=[\p{L}\p{N}])/gu;
    const INVISIBLE = /[­​-‏‪-‮⁠-⁯﻿]/g;

    function escapeRe(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    Object.assign(NYM.prototype, {

        FILTER_PACK_IDS: PACK_IDS,

        // Folds text to `[a-z0-9 ]`; returns { norm, joined } where joined rejoins runs of 3+ single chars.
        normalizeForFilter(text) {
            if (typeof text !== 'string' || !text) return { norm: '', joined: '' };
            let s = text.length > SCAN_LIMIT ? text.slice(0, SCAN_LIMIT) : text;
            s = s.toLowerCase().replace(INVISIBLE, '');
            // NFKC then an NFD round trip; plain NFKD would shatter Hangul and split Japanese dakuten.
            try {
                s = s.normalize('NFKC').normalize('NFD')
                    .replace(/[̀-ͯ]/g, '').normalize('NFC');
            } catch (_) { }
            let out = '';
            for (const ch of s) out += HOMOGLYPHS[ch] || ch;
            s = out;
            try {
                s = s.replace(AT_DOLLAR_RE, (m) => (m === '@' ? 'a' : 's'))
                     .replace(BANG_PIPE_RE, 'i');
            } catch (_) { }
            try { s = s.replace(MIDWORD_STRIP, ''); } catch (_) { }
            s = s.replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
            // Three or more, so ordinary short words aren't welded together.
            const joined = s.replace(
                /(?:^| )((?:[\p{L}\p{N}] ){2,}[\p{L}\p{N}])(?= |$)/gu,
                (m, run) => ' ' + run.replace(/ /g, '')
            );
            return { norm: s, joined: joined === s ? '' : joined };
        },

        // Scripts without spaces between words; their terms match as substrings.
        _isUnspacedScript(term) {
            return /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u0e00-\u0e7f\u0e80-\u0eff\u1780-\u17ff\u1000-\u109f]/.test(term);
        },

        // One term -> one whole-word regex that accepts leet stand-ins and repeated letters.
        _compileFilterTerm(term) {
            const body = this._compileTermBody(term);
            return body ? `(?:^| )${body}(?:$| )` : null;
        },

        // Packs compile to a few alternation regexes rather than one per term, for per-message cost.
        _compileFilterPack(pack) {
            const terms = [];
            const seen = new Set();
            const langs = pack && pack.terms && typeof pack.terms === 'object' ? pack.terms : {};
            for (const list of Object.values(langs)) {
                if (!Array.isArray(list)) continue;
                for (const t of list) {
                    const term = String(t || '').toLowerCase().trim();
                    if (!term || seen.has(term)) continue;
                    seen.add(term);
                    terms.push(term);
                }
            }
            const bodies = [];
            const loose = [];
            for (const t of terms) {
                const body = this._compileTermBody(t);
                if (!body) continue;
                (this._isUnspacedScript(t) ? loose : bodies).push(body);
            }
            // Chunked so no single regex grows past what engines optimize well.
            const CHUNK = 120;
            const matchers = [];
            for (let i = 0; i < bodies.length; i += CHUNK) {
                matchers.push(new RegExp(`(?:^| )(?:${bodies.slice(i, i + CHUNK).join('|')})(?:$| )`, 'u'));
            }
            for (let i = 0; i < loose.length; i += CHUNK) {
                matchers.push(new RegExp(`(?:${loose.slice(i, i + CHUNK).join('|')})`, 'u'));
            }
            const patterns = [];
            for (const p of (Array.isArray(pack.patterns) ? pack.patterns : [])) {
                if (!p || typeof p.re !== 'string') continue;
                try { patterns.push(new RegExp(p.re, p.flags || 'i')); } catch (_) { }
            }
            const allow = [];
            for (const a of (Array.isArray(pack.allow) ? pack.allow : [])) {
                const body = this._compileTermBody(String(a || '').toLowerCase().trim(), false);
                if (body) allow.push(body);
            }
            const allowRe = allow.length
                ? new RegExp(`(?:^| )(?:${allow.join('|')})(?:$| )`, 'gu')
                : null;
            // Nym terms match as substrings, safe only for terms that can't occur in real names; the allow list runs first.
            const nymBodies = [];
            for (const t of (Array.isArray(pack.nymTerms) ? pack.nymTerms : [])) {
                const body = this._compileTermBody(String(t || '').toLowerCase().trim());
                if (body) nymBodies.push(body);
            }
            const nymRe = nymBodies.length ? new RegExp(nymBodies.join('|'), 'u') : null;
            return { id: pack.id, matchers, patterns, allowRe, nymRe, termCount: terms.length };
        },

        // Terms go through the same normalizer as text; allow-list entries use repeat=false so they can't match slurs.
        _compileTermBody(term, repeat) {
            const norm = this.normalizeForFilter(String(term || '')).norm;
            if (!norm) return null;
            const rep = repeat === false ? '{1}' : '+';
            let body = '';
            for (const ch of Array.from(norm)) {
                if (ch === ' ') { body += ' +'; continue; }
                const cls = LEET[ch];
                body += cls ? `[${escapeRe(cls)}]${rep}` : `${escapeRe(ch)}${rep}`;
            }
            return body || null;
        },

        activeFilterPacks() {
            const raw = Array.isArray(this.filterPacks) ? this.filterPacks : [];
            return raw.filter((id) => PACK_IDS.includes(id));
        },

        // A pack that fails to load does not filter; a failed fetch must never swallow a channel.
        async loadFilterPack(id) {
            if (!PACK_URLS[id]) return null;
            if (compiled.has(id)) return compiled.get(id);
            if (loading.has(id)) return loading.get(id);
            const p = (async () => {
                try {
                    const res = await fetch(PACK_URLS[id], { cache: 'force-cache' });
                    if (!res.ok) throw new Error('http ' + res.status);
                    const pack = await res.json();
                    const built = this._compileFilterPack(pack);
                    compiled.set(id, built);
                    return built;
                } catch (_) {
                    return null;
                } finally {
                    loading.delete(id);
                }
            })();
            loading.set(id, p);
            return p;
        },

        // Called on setting change and at boot so the first message after reload is filtered.
        async ensureFilterPacksLoaded() {
            const ids = this.activeFilterPacks();
            if (ids.length === 0) return;
            await Promise.all(ids.map((id) => this.loadFilterPack(id)));
        },

        // Returns the matching pack id, or '', so the UI can say which pack hid a message.
        filterPackMatch(text, nickname) {
            const ids = this.activeFilterPacks();
            if (ids.length === 0) return '';
            const body = typeof text === 'string' ? text : '';
            const nick = nickname && typeof this.parseNymFromDisplay === 'function'
                ? this.parseNymFromDisplay(nickname) : (nickname || '');
            const subject = nick ? `${nick} ${body}` : body;
            if (!subject) return '';

            const { norm, joined } = this.normalizeForFilter(subject);
            if (!norm) return '';
            const nymNorm = nick ? this.normalizeForFilter(nick).norm : '';

            for (const id of ids) {
                const pack = compiled.get(id);
                if (!pack) continue;
                // The allow list is subtracted from the haystack before the terms run.
                let hay = norm;
                let hay2 = joined;
                if (pack.allowRe) {
                    hay = hay.replace(pack.allowRe, ' ');
                    if (hay2) hay2 = hay2.replace(pack.allowRe, ' ');
                }
                for (const re of pack.matchers) {
                    if (re.test(hay) || (hay2 && re.test(hay2))) return id;
                }
                if (pack.nymRe && nymNorm) {
                    const nymHay = pack.allowRe ? nymNorm.replace(pack.allowRe, ' ') : nymNorm;
                    if (pack.nymRe.test(nymHay)) return id;
                }
                // Structural patterns run on the original text, which normalization would destroy.
                for (const re of pack.patterns) {
                    re.lastIndex = 0;
                    if (re.test(body)) return id;
                }
            }
            return '';
        },

        hasFilterPackMatch(text, nickname) {
            return this.filterPackMatch(text, nickname) !== '';
        },

        // Loading starts here so enabling a pack takes effect on the next message.
        setFilterPacks(ids) {
            const next = (Array.isArray(ids) ? ids : []).filter((id) => PACK_IDS.includes(id));
            this.filterPacks = next;
            try { localStorage.setItem('nym_filter_packs', JSON.stringify(next)); } catch (_) { }
            const changed = () => { if (typeof this._contentFiltersChanged === 'function') this._contentFiltersChanged(); };
            changed();
            Promise.resolve(this.ensureFilterPacksLoaded()).then(changed, changed);
        }
    });
})();
