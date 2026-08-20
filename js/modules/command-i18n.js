// command-i18n.js - Localized aliases for the / and ? command vocabularies.

const NYM_CMD_SOURCE = {
    '/pm': 'private message',
    '/nick': 'nickname',
    '/me': 'action',
    '/brb': 'be right back',
    '/addmember': 'add member',
    '/groupinfo': 'group info',
    '/addmod': 'add moderator',
    '/removemod': 'remove moderator',
    '/transferowner': 'transfer owner',
    '?wordplay': 'word play',
    '?changelog': 'change log',
    '?8ball': null,
    '?btc': null,
    '?git': null,
    '?nostr': null,
};

Object.assign(NYM.prototype, {

    _cmdI18nTables() {
        return [this.commands || {}, this.botCommands || {}, this.botPMCommands || {}];
    },

    // Canonical tokens worth translating: multi-character, non-alias entries.
    _cmdI18nCanonical() {
        const out = [];
        const seen = new Set();
        for (const table of this._cmdI18nTables()) {
            for (const [cmd, info] of Object.entries(table)) {
                if (info && info.aliasOf) continue;
                if (cmd.length <= 2) continue; // "/b", "/i" — single-letter aliases stay English
                if (seen.has(cmd)) continue;
                seen.add(cmd);
                out.push(cmd);
            }
        }
        return out;
    },

    _cmdI18nSource(cmd) {
        if (Object.prototype.hasOwnProperty.call(NYM_CMD_SOURCE, cmd)) return NYM_CMD_SOURCE[cmd];
        return cmd.slice(1);
    },

    // Fold a translated phrase into something typeable as a single token.
    _cmdI18nSlug(text) {
        if (!text) return '';
        let s = String(text).trim().toLocaleLowerCase();
        s = s.replace(/[^\p{L}\p{N}_-]+/gu, '');
        return s;
    },

    _cmdI18nDeaccent(token) {
        try { return token.normalize('NFD').replace(/\p{M}+/gu, ''); } catch (_) { return token; }
    },

    // cache 
    _cmdI18nCacheKey(lang) { return 'nym_cmd_i18n_' + lang; },

    _cmdI18nCache(lang) {
        const store = this._cmdI18nStore || (this._cmdI18nStore = {});
        if (store[lang]) return store[lang];
        let obj = {};
        try {
            const raw = localStorage.getItem(this._cmdI18nCacheKey(lang));
            if (raw) { const p = JSON.parse(raw); if (p && typeof p === 'object') obj = p; }
        } catch (_) { }
        store[lang] = obj;
        return obj;
    },

    _cmdI18nSaveCache(lang) {
        if (this._cmdI18nSaveTimer) clearTimeout(this._cmdI18nSaveTimer);
        this._cmdI18nSaveTimer = setTimeout(() => {
            this._cmdI18nSaveTimer = null;
            const obj = (this._cmdI18nStore || {})[lang];
            if (!obj) return;
            try { localStorage.setItem(this._cmdI18nCacheKey(lang), JSON.stringify(obj)); } catch (_) { }
        }, 800);
    },

    // alias map 
    // { local: Map(canonical -> localized token), lookup: Map(typed token -> canonical) }
    _cmdI18nMaps() {
        const lang = this.getUiLanguage ? this.getUiLanguage() : '';
        if (!lang || lang === 'en') return null;
        if (this._cmdI18nMapLang === lang && this._cmdI18nMapRev === this._cmdI18nCacheRev) {
            return this._cmdI18nMapCache;
        }
        const cache = this._cmdI18nCache(lang);
        const local = new Map();
        const lookup = new Map();
        // Never let an alias shadow a real English token.
        const reserved = new Set();
        for (const table of this._cmdI18nTables()) {
            for (const cmd of Object.keys(table)) reserved.add(cmd);
        }
        const claim = (token, canonical) => {
            if (!token || token.length < 2) return;
            const full = canonical[0] + token;
            if (reserved.has(full) || lookup.has(full)) return;
            lookup.set(full, canonical);
            const bare = canonical[0] + this._cmdI18nDeaccent(token);
            if (bare !== full && !reserved.has(bare) && !lookup.has(bare)) lookup.set(bare, canonical);
        };
        for (const cmd of this._cmdI18nCanonical()) {
            const translated = cache[cmd];
            if (!translated) continue;
            const slug = this._cmdI18nSlug(translated);
            if (!slug || slug === cmd.slice(1)) continue;
            local.set(cmd, cmd[0] + slug);
            claim(slug, cmd);
            // A multi-word translation also answers to its first word.
            const first = this._cmdI18nSlug(String(translated).trim().split(/\s+/)[0]);
            if (first && first !== slug) claim(first, cmd);
        }
        this._cmdI18nMapLang = lang;
        this._cmdI18nMapRev = this._cmdI18nCacheRev;
        this._cmdI18nMapCache = { local, lookup };
        return this._cmdI18nMapCache;
    },

    // translation 
    // Fetch any missing command translations for the active language. Safe to
    // call repeatedly; work happens once per language.
    cmdI18nEnsure() {
        const lang = this.getUiLanguage ? this.getUiLanguage() : '';
        if (!lang || lang === 'en') return;
        if (this._cmdI18nBusy === lang) return;
        const cache = this._cmdI18nCache(lang);
        const pending = this._cmdI18nCanonical().filter((cmd) => {
            if (cache[cmd] != null) return false;
            return this._cmdI18nSource(cmd) != null;
        });
        if (!pending.length) return;
        this._cmdI18nBusy = lang;
        const run = async () => {
            let landed = 0;
            for (const cmd of pending) {
                if ((this.getUiLanguage ? this.getUiLanguage() : '') !== lang) break;
                const source = this._cmdI18nSource(cmd);
                try {
                    const res = await this._doTranslate(source, lang);
                    const out = res && res.translatedText;
                    if (out && out.trim()) { cache[cmd] = out.trim(); landed++; }
                } catch (_) { /* retried on the next call */ }
            }
            if (landed) {
                this._cmdI18nSaveCache(lang);
                this._cmdI18nCacheRev = (this._cmdI18nCacheRev || 0) + 1;
            }
            this._cmdI18nBusy = null;
        };
        run();
    },

    // public helpers 
    // Localized display token for a canonical command, or the canonical one.
    localizeCommandToken(cmd) {
        const maps = this._cmdI18nMaps();
        if (!maps) return cmd;
        return maps.local.get(cmd) || cmd;
    },

    // Canonical token for something the user typed, or null when unknown.
    resolveCommandToken(token) {
        if (!token) return null;
        const t = token.toLocaleLowerCase();
        for (const table of this._cmdI18nTables()) {
            if (Object.prototype.hasOwnProperty.call(table, t)) return t;
        }
        const maps = this._cmdI18nMaps();
        if (!maps) return null;
        return maps.lookup.get(t) || maps.lookup.get(this._cmdI18nDeaccent(t)) || null;
    },

    // Rewrite a leading localized command token in raw input to its canonical
    // form, leaving the arguments untouched.
    canonicalizeCommandInput(text) {
        if (!text) return text;
        const m = /^([/?])(\S+)/.exec(text);
        if (!m) return text;
        const canonical = this.resolveCommandToken(m[1] + m[2]);
        if (!canonical || canonical === (m[1] + m[2]).toLocaleLowerCase()) return text;
        return canonical + text.slice(m[0].length);
    },

    // { typed, canonical } when raw input opens with a localized command, so a
    // server-side parser can normalize the same text. Null otherwise.
    commandAliasHint(text) {
        if (!text) return null;
        const m = /^\s*([/?]\S+)/.exec(text);
        if (!m) return null;
        const typed = m[1];
        const canonical = this.resolveCommandToken(typed);
        if (!canonical || canonical === typed.toLocaleLowerCase()) return null;
        return { typed, canonical };
    },

    // Rewrite canonical tokens inside rendered text (Nymbot help, system
    // messages) so the names shown match what the app accepts.
    localizeCommandTokensIn(text) {
        const maps = this._cmdI18nMaps();
        if (!maps || !text) return text;
        return String(text).replace(/(^|[\s(<>`*_;])([/?])([a-z0-9]{3,})\b/gi, (whole, lead, prefix, name) => {
            const local = maps.local.get(prefix + name.toLowerCase());
            return local ? lead + local : whole;
        });
    },
});
