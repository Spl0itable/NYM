// filter-packs.js — opt-in keyword packs

(function () {
    const PACK_IDS = ['profanity', 'scams', 'crypto', 'politics'];

    // Literal paths: the build rewrites '/data/...' references to their hashed
    // names, and only sees them when they are written out in full.
    const PACK_URLS = {
        profanity: '/data/filter-packs/profanity.json',
        scams: '/data/filter-packs/scams.json',
        crypto: '/data/filter-packs/crypto.json',
        politics: '/data/filter-packs/politics.json'
    };

    // Compiled packs live for the session; the JSON is immutable per build and
    // the browser cache holds it across reloads.
    const compiled = new Map();
    const loading = new Map();

    /// Only the first this many characters are scanned. A pasted wall of text
    /// is not worth a linear scan per term, and a term that only appears past
    /// 8k is not what the pack is for.
    const SCAN_LIMIT = 8000;

    // Characters that look like ASCII letters to a reader and are not. Cyrillic
    // and Greek lookalikes are the common evasion; the fullwidth forms come
    // free from NFKD.
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

    // Digits and symbols that stand in for a letter. Applied as ALTERNATIVES in
    // the compiled term, never as a rewrite of the text: turning every '1' into
    // an 'i' would corrupt ordinary numbers, and every '!' into an 'i' would
    // turn "yes!!!" into "yesiii".
    const LEET = {
        a: 'a@4', b: 'b8', c: 'c', d: 'd', e: 'e3', f: 'f', g: 'g69',
        h: 'h', i: 'i1!|', j: 'j', k: 'k', l: 'l1|', m: 'm', n: 'n',
        o: 'o0', p: 'p', q: 'q', r: 'r', s: 's5$', t: 't7', u: 'u',
        v: 'v', w: 'w', x: 'x', y: 'y', z: 'z2'
    };

    // Symbols that stand in for a letter, applied to the TEXT (unlike the digit
    // stand-ins, which are alternatives inside the term). Two rules, because
    // the symbols are not interchangeable:
    //
    //   @ $   convert next to a LETTER, on either side: "$hit", "a$$hole",
    //         "@sshole". A digit neighbor is left alone so a price of "$20"
    //         stays a price.
    //   ! |   convert only BETWEEN two letters: "b!tch". Converting a trailing
    //         one would turn "World!" into "worldi" and, worse, "fuck!" into
    //         "fucki" — which the term would then miss. An exclamation mark at
    //         the end of a sentence is punctuation, not evasion.
    const AT_DOLLAR_RE = /(?<=\p{L})[@$]|[@$](?=\p{L})/gu;
    const BANG_PIPE_RE = /(?<=\p{L})[!|]+(?=\p{L})/gu;

    // Deleted when they sit BETWEEN two alphanumerics, which is the shape of
    // "f.u.c.k" and "s-h-i-t" and nothing a reader writes by accident. Outside
    // a word they stay separators, so "end. Start" does not become one word.
    const MIDWORD_STRIP = /(?<=[\p{L}\p{N}])[.\-_*'’`~^+]+(?=[\p{L}\p{N}])/gu;
    // Zero-width and directionality marks: invisible, and pure evasion.
    const INVISIBLE = /[­​-‏‪-‮⁠-⁯﻿]/g;

    function escapeRe(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    Object.assign(NYM.prototype, {

        FILTER_PACK_IDS: PACK_IDS,

        /// Folds a message down to `[a-z0-9 ]` so one term can match every way
        /// the word might have been written. Returns { norm, joined }: the
        /// second has runs of three or more single characters rejoined, which
        /// is what makes "f u c k" reachable without letting a term match
        /// across two ordinary words.
        normalizeForFilter(text) {
            if (typeof text !== 'string' || !text) return { norm: '', joined: '' };
            let s = text.length > SCAN_LIMIT ? text.slice(0, SCAN_LIMIT) : text;
            s = s.toLowerCase().replace(INVISIBLE, '');
            // NFKC folds the fullwidth and circled forms; the NFD round trip
            // then strips Latin accents and puts everything else back. Going
            // straight to NFKD would shatter Hangul into jamo and split the
            // Japanese dakuten off its kana, so a term and the text it should
            // match would normalize to two different strings.
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
            // Everything that is not a letter or digit becomes one space, so
            // word boundaries are simply spaces from here on.
            s = s.replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
            // "f u c k" -> "fuck". Three or more, so ordinary short words ("a
            // b test", "I R S") are not welded into something else.
            const joined = s.replace(
                /(?:^| )((?:[\p{L}\p{N}] ){2,}[\p{L}\p{N}])(?= |$)/gu,
                (m, run) => ' ' + run.replace(/ /g, '')
            );
            return { norm: s, joined: joined === s ? '' : joined };
        },

        /// Scripts that do not put spaces between words. A whole-word match
        /// is meaningless there — Chinese runs together, so the normalizer
        /// hands the matcher one enormous "word" and every term misses. Terms
        /// in these scripts match as substrings instead, which is how every
        /// CJK filter works and why their term lists have to be short and
        /// distinctive rather than long and general.
        _isUnspacedScript(term) {
            return /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u0e00-\u0e7f\u0e80-\u0eff\u1780-\u17ff\u1000-\u109f]/.test(term);
        },

        /// One term -> one whole-word regex. Letters accept their leet
        /// stand-ins and any number of repeats, so "fuuuck" and "fu9k" are the
        /// same term; the boundaries are what keep it out of "classic".
        _compileFilterTerm(term) {
            const body = this._compileTermBody(term);
            return body ? `(?:^| )${body}(?:$| )` : null;
        },

        /// Packs are compiled to a handful of alternation regexes rather than
        /// one regex per term: a busy channel runs this on every message, and
        /// 400 separate `test()` calls per message is not the same cost as six.
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
            // A nym is one run-together token — "fuckbot" is not four words —
            // so whole-word matching never reaches inside it. These match as
            // substrings, which is only safe for terms that essentially cannot
            // occur inside a real name; the allow list still runs first, so
            // "Shiitake" and "Penistone" survive.
            const nymBodies = [];
            for (const t of (Array.isArray(pack.nymTerms) ? pack.nymTerms : [])) {
                const body = this._compileTermBody(String(t || '').toLowerCase().trim());
                if (body) nymBodies.push(body);
            }
            const nymRe = nymBodies.length ? new RegExp(nymBodies.join('|'), 'u') : null;
            return { id: pack.id, matchers, patterns, allowRe, nymRe, termCount: terms.length };
        },

        /// A term is normalized by the SAME pipeline as the text before it is
        /// compiled. Without this the homoglyph fold silently breaks every
        /// non-Latin list: "хуй" becomes "xyй" in the message and stays "хуй"
        /// in the pack, and the two never meet.
        ///
        /// [repeat] false compiles the letters exactly once. Allow-list entries
        /// use it because with repetition "niger" matches "nigger", and an
        /// allow list that swallows the slur it was never meant to cover is
        /// worse than no allow list at all.
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

        /// The packs the user turned on, normalized against the known ids.
        activeFilterPacks() {
            const raw = Array.isArray(this.filterPacks) ? this.filterPacks : [];
            return raw.filter((id) => PACK_IDS.includes(id));
        },

        /// Loads and compiles a pack once. A pack that will not load simply
        /// does not filter — a failed fetch must never swallow a channel.
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

        /// Warms every enabled pack. Called when the setting changes and at
        /// boot, so the first message after a reload is filtered like the rest.
        async ensureFilterPacksLoaded() {
            const ids = this.activeFilterPacks();
            if (ids.length === 0) return;
            await Promise.all(ids.map((id) => this.loadFilterPack(id)));
        },

        /// The pack that matched, or '' — the id is returned rather than a
        /// boolean so the UI can say WHICH pack hid a message.
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
                // The allow list is subtracted from the haystack before the
                // terms run, so "Scunthorpe" cannot be reached by the term
                // inside it — cheaper and more predictable than matching the
                // term and then re-checking its surroundings.
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
                // Structural patterns run on the ORIGINAL text: a wallet
                // address or an invite link is destroyed by normalization.
                for (const re of pack.patterns) {
                    re.lastIndex = 0;
                    if (re.test(body)) return id;
                }
            }
            return '';
        },

        /// True when any enabled pack matches. The name mirrors
        /// `hasBlockedKeyword`, which this sits beside in every filter site.
        hasFilterPackMatch(text, nickname) {
            return this.filterPackMatch(text, nickname) !== '';
        },

        /// Turns a pack on or off and persists it. Loading is kicked off here
        /// so enabling a pack takes effect on the next message, not the next
        /// reload.
        setFilterPacks(ids) {
            const next = (Array.isArray(ids) ? ids : []).filter((id) => PACK_IDS.includes(id));
            this.filterPacks = next;
            try { localStorage.setItem('nym_filter_packs', JSON.stringify(next)); } catch (_) { }
            this.ensureFilterPacksLoaded();
        }
    });
})();
