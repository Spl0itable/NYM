// User-generated subtrees that must never be machine translated, for text nodes and attributes alike.
const NYM_I18N_CATALOG = '00000000';

const NYM_I18N_SKIP_SELECTOR = [
    '#messagesScroller', '#autocompleteDropdown', '#messageInput',
    '.channel-name', '.pm-name', '.group-name', '.channel-title', '.channel-title-line',
    '#currentChannel', '.uh-title', '.geohash-info-title',
    '[class*="author"]', '[class*="nym-base"]', '[class*="-nym"]', '.nym-suffix',
    '.nym-bracket', '.nym-name', '.nym-display', '.nym-value', '.nym-identity',
    '.nym-sk-name', '.readers-modal-user',
    '.lp-nick', '.lp-bubble-nick', '.nm-mention', '.mention',
    '[class*="member-name"]', '.group-ctx-member', '.group-info-member',
    '[class*="reader"]', '[class*="reactor"]',
    // Transient status strings that interpolate nicknames inline.
    '#typingIndicator', '.typing-indicator', '.typing-indicator-text', '.cv-typing',
    '.notification-item-author', '.file-offer-name', '.shop-item-name',
    '.messages-container', '.messages-list', '.message[data-message-id]',
    '.cv-col-title', '.cv-tab-title', '.cv-picker-row-label',
    '.row-preview-name', '.row-preview-body', '.blocked-item > span:first-child',
    '#messageAnnouncer', '.nym-toast-title', '.nym-toast-meta', '.nym-toast-body',
    '.quote-preview-text', '.us-row', '.message-content',
    '.gx-peek-list', '.gx-step', '.gx-row', '.gx-result',
    '.sl-preview', '.sl-time', '.ct-version-time', '.ct-saved-chat', '.ct-saved-time',
    '.gt-inv-name', '.gt-inv-desc',
    '.notif-group-title', '.notification-item-body', '.notification-item-context',
    '.context-menu-bio', '.share-preview-from', '.share-preview-title', '.nearby-card-title',
    '.command-name', '.help-cmd-name', '.translate-dropdown-name',
    '.translate-lang-option', '.emoji-name', '.emoji-option', '.hashtag',
    // Language names are endonyms and must never be translated.
    '#translateLanguageSelect', '#uiLanguageSelect', '.translate-lang-grid',
    // The translate dropdown's star aria-labels interpolate language names.
    '.translate-dropdown-item',
    '.custom-emoji', 'code', 'pre', 'kbd', 'samp',
    '[data-no-i18n]', '.notranslate', '[translate="no"]', '[contenteditable="true"]',
    'script', 'style', 'noscript', 'template', 'textarea', '[data-peer-id]',
].join(',');

const NYM_I18N_ATTRS = ['placeholder', 'data-placeholder', 'title', 'aria-label', 'aria-description'];

const NYM_I18N_USER_DATA_RE = [
    /https?:\/\/|www\./i,
    /[\w.+-]+@[\w-]+\.[a-z]{2,}/i,
    /\b(?:npub|nsec|note|nevent|nprofile|naddr|lnurl|lnbc)1[02-9ac-hj-np-z]{8,}/i,
    /\b[0-9a-f]{12,}\b/i,
    /[\p{L}\p{N}_]#[0-9a-f]{4}\b/iu,
    /\b[\w-]+\.(?:jpe?g|png|gif|webp|heic|heif|avif|mp4|mov|m4v|webm|mkv|pdf|zip|rar|7z|txt|csv|json|docx?|xlsx?|pptx?|mp3|m4a|aac|wav|ogg|opus|flac|apk|ipa|dmg|exe)\b/i,
];

// One regex in a single pass so sentinels aren't re-tokenized; i18n/strings.mjs must match it.
const NYM_I18N_TOKEN_RE = /\{[^}]+\}|\d[\d.,:/%+-]*/g;

Object.assign(NYM.prototype, {

    getUiLanguage() {
        if (this.settings && typeof this.settings.uiLanguage === 'string') return this.settings.uiLanguage;
        try { return localStorage.getItem('nym_ui_language') || ''; } catch (_) { return ''; }
    },

    _i18nCacheStore() {
        return this._i18nCache || (this._i18nCache = {});
    },

    _i18nLoadCache(lang) {
        const store = this._i18nCacheStore();
        if (store[lang]) return store[lang];
        const obj = {};
        try {
            const raw = localStorage.getItem('nym_ui_i18n_' + lang);
            if (raw) {
                const p = JSON.parse(raw);
                if (p && typeof p === 'object' && p.v === this._i18nCacheVersion() && p.m && typeof p.m === 'object') {
                    for (const [k, v] of Object.entries(p.m)) if (typeof v === 'string') obj[k] = v;
                } else {
                    localStorage.removeItem('nym_ui_i18n_' + lang);
                }
            }
        } catch (_) { }
        store[lang] = obj;
        return obj;
    },

    _i18nCacheVersion() {
        return 'c' + NYM_I18N_CATALOG + (typeof NYMCHAT_BUILD === 'number' ? '.b' + NYMCHAT_BUILD : '');
    },

    // Concurrent callers share one fetch; a failed fetch is not memoized so a later switch retries.
    _i18nPrimeFromPack(lang) {
        if (!lang || lang === 'en') return Promise.resolve();
        const inflight = this._i18nPackFetches || (this._i18nPackFetches = {});
        if (inflight[lang]) return inflight[lang];
        const done = (async () => {
            try {
                const res = await fetch(`/i18n/${encodeURIComponent(lang)}.json`, { cache: 'force-cache' });
                // A build without a pack is not an error, and not worth asking for again this session.
                if (!res.ok) return;
                const pack = await res.json();
                if (!pack || typeof pack !== 'object') return;
                const cache = this._i18nLoadCache(lang);
                (this._i18nPackKeys || (this._i18nPackKeys = {}))[lang] = new Set(Object.keys(pack));
                let added = 0;
                for (const [key, translated] of Object.entries(pack)) {
                    if (typeof translated !== 'string' || !translated) continue;
                    if (cache[key] === translated) continue;
                    cache[key] = translated;
                    added++;
                }
                if (added) this._i18nSaveCache(lang);
            } catch (_) {
                delete inflight[lang];
            } finally {
                (this._i18nPackTried || (this._i18nPackTried = {}))[lang] = true;
            }
        })();
        inflight[lang] = done;
        return done;
    },

    _i18nSaveCache(lang) {
        const timers = this._i18nSaveTimers || (this._i18nSaveTimers = {});
        if (timers[lang]) clearTimeout(timers[lang]);
        timers[lang] = setTimeout(() => {
            delete timers[lang];
            this._i18nWriteCache(lang);
        }, 800);
        if (this._i18nFlushHooked || typeof window === 'undefined' || !window.addEventListener) return;
        this._i18nFlushHooked = true;
        const flush = () => {
            for (const l of Object.keys(timers)) {
                clearTimeout(timers[l]);
                delete timers[l];
                this._i18nWriteCache(l);
            }
        };
        window.addEventListener('pagehide', flush);
        if (typeof document !== 'undefined') {
            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'hidden') flush();
            });
        }
    },

    _i18nPruneOtherCaches(keep) {
        const prefixes = ['nym_ui_i18n_', 'nym_cmd_i18n_'];
        const drop = [];
        try {
            for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i);
                if (!k) continue;
                const p = prefixes.find((x) => k.startsWith(x));
                if (p && k.slice(p.length) !== keep) drop.push(k);
            }
        } catch (_) { return; }
        for (const k of drop) { try { localStorage.removeItem(k); } catch (_) { } }
        for (const store of [this._i18nCache, this._cmdI18nStore]) {
            if (!store) continue;
            for (const l of Object.keys(store)) if (l !== keep) delete store[l];
        }
    },

    I18N_RUNTIME_MAX: 1000,

    _i18nTrimRuntime(lang, obj) {
        const pack = this._i18nPackKeys && this._i18nPackKeys[lang];
        if (!pack) return;
        const extra = [];
        for (const k of Object.keys(obj)) if (!pack.has(k)) extra.push(k);
        for (let i = 0; i < extra.length - this.I18N_RUNTIME_MAX; i++) delete obj[extra[i]];
    },

    _i18nWriteCache(lang) {
        const obj = this._i18nCacheStore()[lang];
        if (!obj) return;
        this._i18nTrimRuntime(lang, obj);
        try { localStorage.setItem('nym_ui_i18n_' + lang, JSON.stringify({ v: this._i18nCacheVersion(), m: obj })); } catch (_) { }
    },

    i18nSendable(text) {
        const s = String(text == null ? '' : text);
        return !NYM_I18N_USER_DATA_RE.some((re) => re.test(s));
    },

    _i18nElSkipped(el) {
        if (!el || el.nodeType !== 1) return true;
        try { if (el.closest(NYM_I18N_SKIP_SELECTOR)) return true; } catch (_) { }
        for (let cur = el; cur && cur.nodeType === 1; cur = cur.parentElement) {
            if (cur.namespaceURI === 'http://www.w3.org/2000/svg') return true;
        }
        return false;
    },

    _i18nTextTranslatable(node) {
        const t = node.nodeValue;
        if (!t || t.trim().length < 2) return false;
        if (!/\p{L}/u.test(t)) return false;
        const parent = node.parentElement;
        if (this._i18nElSkipped(parent)) return false;
        // A bare text node beside a `.nym-suffix` span is a nickname and must never be translated.
        if (parent && parent.querySelector && parent.querySelector(':scope > .nym-suffix')) return false;
        return true;
    },

    _i18nCollect(root, textNodes, attrTargets) {
        if (!root) return;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (node) => this._i18nTextTranslatable(node)
                ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
        });
        let n;
        while ((n = walker.nextNode())) textNodes.push(n);

        const scan = (el) => {
            if (this._i18nElSkipped(el)) return;
            for (const attr of NYM_I18N_ATTRS) {
                if (!el.hasAttribute(attr)) continue;
                const v = el.getAttribute(attr);
                if (v && v.trim().length >= 2 && /\p{L}/u.test(v)) {
                    attrTargets.push({ el, attr });
                }
            }
        };
        if (root.nodeType === 1) scan(root);
        if (root.querySelectorAll) {
            const sel = NYM_I18N_ATTRS.map(a => '[' + a + ']').join(',');
            root.querySelectorAll(sel).forEach(scan);
        }
    },

    // Cache key with {placeholders} and numbers replaced by sentinels so counts share one translation.
    _i18nMakeKey(core) {
        const tokens = [];
        const key = String(core).replace(/\s+/g, ' ').trim().replace(NYM_I18N_TOKEN_RE, (m) => {
            tokens.push(m);
            return `PLH${tokens.length - 1}PLH`;
        });
        if (!this.i18nSendable(core)) (this._i18nHeld || (this._i18nHeld = new Set())).add(key);
        return { key, tokens };
    },

    _i18nSubst(text, args) {
        return String(text).replace(/\{(\w+)\}/g, (m, k) =>
            Object.prototype.hasOwnProperty.call(args, k) && args[k] != null ? String(args[k]) : m);
    },

    _i18nRemember(out, text, args, en) {
        const map = this._i18nTemplated || (this._i18nTemplated = new Map());
        const info = { text, args, en };
        for (const k of new Set([out, en])) {
            map.delete(k);
            map.set(k, info);
        }
        while (map.size > 2000) map.delete(map.keys().next().value);
    },

    _i18nResolve(core) {
        const t = this._i18nTemplated && this._i18nTemplated.get(core);
        const { key, tokens } = this._i18nMakeKey(t ? t.text : core);
        return {
            key,
            render: (tpl) => {
                const filled = this._i18nFill(tpl, tokens);
                return t ? this._i18nSubst(filled, t.args) : filled;
            },
        };
    },

    // Callers holding source strings key through here so they match the DOM sweep's lookups.
    _i18nKeyOf(text) { return this._i18nMakeKey(text).key; },

    _i18nFill(template, tokens) {
        if (!tokens.length) return template;
        return template.replace(/PLH(\d+)PLH/g, (_, i) => tokens[+i] != null ? tokens[+i] : '');
    },

    // The returned value keeps PLH sentinels so token values can be filled back per instance.
    async _i18nTranslateOne(key, lang) {
        const { translatedText } = await this._doTranslate(key, lang);
        if (!translatedText || !translatedText.trim()) return key;
        return translatedText;
    },

    // Background translation: on-screen strings go first at high priority, the rest fills in behind.

    _i18nQueueState() {
        if (!this._i18nQueue) {
            this._i18nQueue = { hi: [], lo: [] };
            this._i18nQueued = new Set();
            this._i18nFailed = new Set();
            this._i18nRetryRounds = 0;
            this._i18nActive = 0;
        }
        return this._i18nQueue;
    },

    _i18nResetQueue() {
        if (!(this._i18nActive >= 0)) this._i18nActive = 0;
        this._i18nQueue = { hi: [], lo: [] };
        this._i18nQueued = new Set();
        this._i18nFailed = new Set();
        this._i18nRetryRounds = 0;
        if (this._i18nRetryTimer) { clearTimeout(this._i18nRetryTimer); this._i18nRetryTimer = null; }
    },

    _i18nEnqueue(sources, priority, lang) {
        lang = lang || this.getUiLanguage();
        if (!lang || lang === 'en' || !sources) return;
        const cache = this._i18nLoadCache(lang);
        const q = this._i18nQueueState();
        const seen = this._i18nQueued;
        const held = this._i18nHeld;
        for (const src of sources) {
            if (!src || cache[src] != null || (held && held.has(src))) continue;
            if (priority === 'hi') {
                if (seen.has(src)) {
                    const i = q.lo.indexOf(src);
                    if (i !== -1) q.lo.splice(i, 1);
                    else continue;
                }
                seen.add(src);
                q.hi.push(src);
            } else {
                if (seen.has(src)) continue;
                seen.add(src);
                q.lo.push(src);
            }
        }
        this._i18nPump(lang);
        this._i18nUpdateIndicator();
    },

    // Returns null on final failure so the cache isn't poisoned with untranslated English.
    async _i18nTranslateWithRetry(source, lang, attempts = 3) {
        for (let i = 0; i < attempts; i++) {
            try {
                return await this._i18nTranslateOne(source, lang);
            } catch (_) {
                if (this.getUiLanguage() !== lang) return null;
                if (i < attempts - 1) {
                    await new Promise(r => setTimeout(r, 500 * (i + 1)));
                }
            }
        }
        return null;
    },

    _i18nNoteFailed(src) {
        (this._i18nFailed || (this._i18nFailed = new Set())).add(src);
        if (this._i18nQueued) this._i18nQueued.delete(src);
    },

    // After the queue drains, retry failed strings for a bounded number of rounds.
    _i18nMaybeScheduleRetry(lang) {
        if (this._i18nRemaining() > 0) return;
        const failed = this._i18nFailed;
        if (!failed || !failed.size) return;
        if ((this._i18nRetryRounds || 0) >= 3) return;
        if (this._i18nRetryTimer) return;
        this._i18nRetryTimer = setTimeout(() => {
            this._i18nRetryTimer = null;
            if (this.getUiLanguage() !== lang) return;
            this._i18nRetryRounds = (this._i18nRetryRounds || 0) + 1;
            const retry = [...this._i18nFailed];
            this._i18nFailed = new Set();
            this._i18nEnqueue(retry, 'lo', lang);
        }, 5000);
    },

    _i18nPump(lang) {
        lang = lang || this.getUiLanguage();
        if (lang && lang !== 'en' && !(this._i18nPackTried && this._i18nPackTried[lang])) {
            this._i18nPrimeFromPack(lang).then(() => this._i18nPump(lang));
            return;
        }
        const q = this._i18nQueueState();
        const cache = this._i18nLoadCache(lang);
        const MAX = 6;
        while (this._i18nActive < MAX && (q.hi.length || q.lo.length)) {
            const src = q.hi.length ? q.hi.shift() : q.lo.shift();
            if (cache[src] != null) continue;
            this._i18nActive++;
            this._i18nTranslateWithRetry(src, lang)
                .then((out) => {
                    const into = this._i18nLoadCache(lang);
                    if (out != null) { if (into[src] == null) into[src] = out; }
                    else this._i18nNoteFailed(src);
                })
                .catch(() => { this._i18nNoteFailed(src); })
                .then(() => {
                    this._i18nActive--;
                    this._i18nSaveCache(lang);
                    this._i18nScheduleApply(lang);
                    this._i18nUpdateIndicator();
                    this._i18nPump(lang);
                    this._i18nMaybeScheduleRetry(lang);
                });
        }
    },

    _i18nRemaining() {
        const q = this._i18nQueue;
        return (q ? q.hi.length + q.lo.length : 0) + (this._i18nActive || 0);
    },

    _i18nScheduleApply(lang) {
        if (this._i18nApplyTimer) return;
        this._i18nApplyTimer = setTimeout(() => {
            this._i18nApplyTimer = null;
            this._i18nApplyVisible(lang || this.getUiLanguage());
        }, 250);
    },

    _i18nApplyVisible(lang) {
        if (!lang || lang === 'en') return;
        // Skip jobs from a previous language, or they paint it back over the new one.
        if (lang !== this.getUiLanguage()) return;
        const textNodes = [];
        const attrTargets = [];
        this._i18nCollect(document.body, textNodes, attrTargets);
        for (const node of textNodes) this._i18nApplyTextNode(node, lang);
        for (const t of attrTargets) this._i18nApplyAttr(t, lang);
        this._i18nApplyBound(lang, false);
    },

    i18nBindAttr(el, attr, value) {
        if (!el || !attr || typeof value !== 'string') return;
        const map = this._i18nBound || (this._i18nBound = new Map());
        const entry = map.get(el) || {};
        const written = el.__i18nAttrWritten && el.__i18nAttrWritten[attr];
        entry[attr] = entry[attr] != null && written != null && value === written ? entry[attr] : this.uiSourceOf(value);
        map.set(el, entry);
        this._i18nWriteBound(el, attr, entry[attr], this.getUiLanguage(), true);
    },

    _i18nWriteBound(el, attr, source, lang, enqueue) {
        let value = source;
        if (lang && lang !== 'en') {
            const r = this._i18nResolve(source.trim());
            const tpl = this._i18nLoadCache(lang)[r.key];
            if (tpl != null) value = r.render(tpl);
            else if (enqueue) this._i18nEnqueue([r.key], 'hi', lang);
        }
        (el.__i18nAttrWritten || (el.__i18nAttrWritten = {}))[attr] = value;
        if (el.getAttribute(attr) !== value) el.setAttribute(attr, value);
    },

    _i18nApplyBound(lang, enqueue) {
        if (!this._i18nBound) return;
        for (const [el, entry] of this._i18nBound) {
            if (!el.isConnected) { this._i18nBound.delete(el); continue; }
            for (const attr of Object.keys(entry)) {
                const cur = el.getAttribute(attr);
                const written = el.__i18nAttrWritten && el.__i18nAttrWritten[attr];
                if (cur != null && written != null && cur !== written) entry[attr] = this.uiSourceOf(cur);
                this._i18nWriteBound(el, attr, entry[attr], lang, enqueue);
            }
        }
    },

    // Apply cached translations to a subtree now and enqueue misses at high priority.
    i18nApplyNow(root) {
        const lang = this.getUiLanguage();
        if (!lang || lang === 'en') return;
        const textNodes = [];
        const attrTargets = [];
        this._i18nCollect(root || document.body, textNodes, attrTargets);
        const cache = this._i18nLoadCache(lang);
        const missing = new Set();
        for (const node of textNodes) {
            const key = this._i18nNodeKey(node);
            this._i18nApplyTextNode(node, lang);
            if (cache[key] == null) missing.add(key);
        }
        for (const t of attrTargets) {
            const key = this._i18nAttrKey(t.el, t.attr);
            this._i18nApplyAttr(t, lang);
            if (key && cache[key] == null) missing.add(key);
        }
        if (missing.size) this._i18nEnqueue([...missing], 'hi', lang);
    },

    uiText(text, args) {
        if (typeof text !== 'string') return text;
        const withArgs = !!args && typeof args === 'object';
        const lang = this.getUiLanguage();
        if (!lang || lang === 'en') return withArgs ? this._i18nSubst(text, args) : text;
        const { key, tokens } = this._i18nMakeKey(text);
        const tpl = this._i18nLoadCache(lang)[key];
        if (tpl == null) {
            this._i18nEnqueue([key], 'hi', lang);
            if (!withArgs) return text;
            const en = this._i18nSubst(text, args);
            this._i18nRemember(en, text, args, en);
            return en;
        }
        const filled = this._i18nFill(tpl, tokens);
        if (withArgs) {
            const out = this._i18nSubst(filled, args);
            this._i18nRemember(out, text, args, this._i18nSubst(text, args));
            return out;
        }
        const out = filled;
        if (out !== text) {
            if (!this._i18nSources) this._i18nSources = new Map();
            this._i18nSources.delete(out);
            this._i18nSources.set(out, text);
            if (this._i18nSources.size > 200) this._i18nSources.delete(this._i18nSources.keys().next().value);
        }
        return out;
    },

    uiSourceOf(text) {
        const t = this._i18nTemplated && this._i18nTemplated.get(text);
        if (t) return t.en;
        const s = this._i18nSources && this._i18nSources.get(text);
        return s == null ? text : s;
    },

    // Pre-translate source strings at high priority so they're ready as they appear.
    i18nPrioritize(sources) {
        const lang = this.getUiLanguage();
        if (!lang || lang === 'en' || !Array.isArray(sources)) return;
        this._i18nEnqueue(sources.map(s => this._i18nKeyOf(s)), 'hi', lang);
    },

    _i18nApplyTextNode(node, lang) {
        const cache = this._i18nCacheStore()[lang];
        if (!cache) return;
        const raw = this._i18nSourceText(node);
        const m = raw.match(/^(\s*)([\s\S]*?)(\s*)$/);
        const r = this._i18nResolve(m[2]);
        const tpl = cache[r.key];
        if (tpl == null) return;
        const translated = r.render(tpl);
        if (node.__i18nOrig == null) node.__i18nOrig = raw;
        const next = m[1] + translated + m[3];
        if (node.nodeValue !== next) {
            // Mark our own write so the characterData observer doesn't re-translate in a loop.
            if (this._i18nSelfWrites) this._i18nSelfWrites.add(node);
            node.nodeValue = next;
        }
    },

    _i18nApplyAttr(target, lang) {
        const cache = this._i18nCacheStore()[lang];
        if (!cache) return;
        const { el, attr } = target;
        const raw = this._i18nSourceAttr(el, attr);
        if (raw == null) return;
        const r = this._i18nResolve(raw.trim());
        const tpl = cache[r.key];
        if (tpl == null) return;
        const translated = r.render(tpl);
        const store = el.__i18nAttrOrig || (el.__i18nAttrOrig = {});
        if (store[attr] == null) store[attr] = raw;
        (el.__i18nAttrWritten || (el.__i18nAttrWritten = {}))[attr] = translated;
        if (el.getAttribute(attr) !== translated) el.setAttribute(attr, translated);
    },

    // Every read for keying or applying must use the original English, never the translated text.
    _i18nSourceText(node) {
        return node.__i18nOrig != null ? node.__i18nOrig : this.uiSourceOf(node.nodeValue);
    },
    _i18nSourceAttr(el, attr) {
        const kept = el.__i18nAttrOrig ? el.__i18nAttrOrig[attr] : null;
        if (kept != null) return kept;
        const v = el.getAttribute(attr);
        return v == null ? v : this.uiSourceOf(v);
    },

    _i18nNodeKey(node) { return this._i18nResolve(this._i18nSourceText(node).trim()).key; },
    _i18nAttrKey(el, attr) { return this._i18nResolve((this._i18nSourceAttr(el, attr) || '').trim()).key; },

    // lang '' or 'en' restores English; misses translate in the background.
    async applyUiLanguage(lang, opts = {}) {
        lang = (lang || '').trim();
        const isEnglish = !lang || lang === 'en';

        this.settings.uiLanguage = isEnglish ? '' : lang;
        try { localStorage.setItem('nym_ui_language', this.settings.uiLanguage); } catch (_) { }

        if (isEnglish) {
            this._i18nStopObserver();
            this._i18nResetQueue();
            this._i18nRestoreAll();
            this._i18nApplyBound('', false);
            this._i18nUpdateIndicator();
            document.documentElement.setAttribute('lang', 'en');
            return;
        }

        if (this._i18nLang && this._i18nLang !== lang) this._i18nResetQueue();
        this._i18nLang = lang;
        this._i18nPruneOtherCaches(lang);

        document.documentElement.setAttribute('lang', lang);
        this._i18nLoadCache(lang);
        // Prime the pack before collecting so the sweep hits the cache.
        await this._i18nPrimeFromPack(lang);
        this.cmdI18nEnsure();
        // Start the observer first so UI rendered meanwhile is captured and prioritized.
        this._i18nStartObserver();

        const textNodes = [];
        const attrTargets = [];
        this._i18nCollect(document.body, textNodes, attrTargets);

        const cache = this._i18nCacheStore()[lang];
        const missing = new Set();
        for (const node of textNodes) {
            // Compute the key before applying, since applying mutates the node's text.
            const key = this._i18nNodeKey(node);
            this._i18nApplyTextNode(node, lang);
            if (cache[key] == null) missing.add(key);
        }
        for (const t of attrTargets) {
            const key = this._i18nAttrKey(t.el, t.attr);
            this._i18nApplyAttr(t, lang);
            if (key && cache[key] == null) missing.add(key);
        }
        this._i18nApplyBound(lang, true);

        // On-screen modals first, then the tutorial, then the rest of the app.
        document.querySelectorAll('.modal.active').forEach((m) => {
            if (!this._i18nElSkipped(m)) this.i18nApplyNow(m);
        });

        try {
            let seen = false;
            try { seen = localStorage.getItem('nym_tutorial_seen') === 'true'; } catch (_) { }
            if (!seen && typeof window.nymTutorialStrings === 'function') {
                const tutorialStrings = window.nymTutorialStrings();
                if (tutorialStrings && tutorialStrings.length) {
                    this._i18nEnqueue(tutorialStrings.map(s => this._i18nKeyOf(s)), 'hi', lang);
                }
            }
        } catch (_) { }

        if (missing.size) this._i18nEnqueue([...missing], 'lo', lang);
    },

    _i18nRestoreAll() {
        try {
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            let n;
            while ((n = walker.nextNode())) {
                if (n.__i18nOrig != null) { n.nodeValue = n.__i18nOrig; n.__i18nOrig = null; }
            }
            document.querySelectorAll('*').forEach((el) => {
                if (el.__i18nAttrOrig) {
                    for (const [attr, val] of Object.entries(el.__i18nAttrOrig)) {
                        if (val != null) el.setAttribute(attr, val);
                    }
                    el.__i18nAttrOrig = null;
                }
            });
        } catch (_) { }
    },

    _i18nStartObserver() {
        if (this._i18nObserver) return;
        this._i18nSelfWrites = new WeakSet();
        this._i18nObserver = new MutationObserver((mutations) => {
            const lang = this.getUiLanguage();
            if (!lang || lang === 'en') return;
            const roots = new Set();
            const attrs = [];
            for (const mut of mutations) {
                if (mut.type === 'attributes') {
                    const el = mut.target;
                    const attr = mut.attributeName;
                    const cur = el.getAttribute(attr);
                    const written = el.__i18nAttrWritten && el.__i18nAttrWritten[attr];
                    if (cur == null || (written != null && cur === written)) continue;
                    if (this._i18nElSkipped(el)) continue;
                    if (el.__i18nAttrOrig) delete el.__i18nAttrOrig[attr];
                    attrs.push({ el, attr });
                    continue;
                }
                if (mut.type === 'characterData') {
                    const node = mut.target;
                    if (this._i18nSelfWrites && this._i18nSelfWrites.has(node)) {
                        this._i18nSelfWrites.delete(node);
                        continue;
                    }
                    const parent = node.parentElement;
                    if (parent && !this._i18nElSkipped(parent)) {
                        node.__i18nOrig = null;
                        roots.add(parent);
                    }
                    continue;
                }
                for (const node of mut.addedNodes) {
                    if (node.nodeType === 1) {
                        if (!this._i18nElSkipped(node)) roots.add(node);
                    } else if (node.nodeType === 3 && node.parentElement &&
                        !this._i18nElSkipped(node.parentElement)) {
                        roots.add(node.parentElement);
                    }
                }
            }
            if (attrs.length) {
                const cache = this._i18nLoadCache(lang);
                const missing = new Set();
                for (const t of attrs) {
                    if (!t.el.isConnected) continue;
                    const key = this._i18nAttrKey(t.el, t.attr);
                    this._i18nApplyAttr(t, lang);
                    if (key && cache[key] == null) missing.add(key);
                }
                if (missing.size) this._i18nEnqueue([...missing], 'hi', lang);
            }
            if (!roots.size) return;
            // Apply cached translations synchronously before paint so re-rendered strings never flash English.
            const list = [...roots].filter(r => r.isConnected);
            for (const r of list) {
                if (list.some(o => o !== r && o.contains(r))) continue;
                this._i18nApplyCachedAndEnqueue(r, lang);
            }
        });
        this._i18nObserver.observe(document.body, {
            childList: true, subtree: true, characterData: true,
            attributes: true, attributeFilter: NYM_I18N_ATTRS,
        });
    },

    _i18nApplyCachedAndEnqueue(root, lang) {
        const textNodes = [];
        const attrTargets = [];
        this._i18nCollect(root, textNodes, attrTargets);
        if (!textNodes.length && !attrTargets.length) return;
        const cache = this._i18nLoadCache(lang);
        const missing = new Set();
        for (const node of textNodes) {
            const key = this._i18nNodeKey(node);
            this._i18nApplyTextNode(node, lang);
            if (cache[key] == null) missing.add(key);
        }
        for (const t of attrTargets) {
            const key = this._i18nAttrKey(t.el, t.attr);
            this._i18nApplyAttr(t, lang);
            if (key && cache[key] == null) missing.add(key);
        }
        if (missing.size) this._i18nEnqueue([...missing], 'hi', lang);
    },

    _i18nStopObserver() {
        if (this._i18nObserver) { this._i18nObserver.disconnect(); this._i18nObserver = null; }
        if (this._i18nApplyTimer) { clearTimeout(this._i18nApplyTimer); this._i18nApplyTimer = null; }
    },

    // The indicator's own label, in the target language.
    _i18nIndicatorLabel() {
        const en = 'Translating…';
        try {
            const lang = this.getUiLanguage && this.getUiLanguage();
            if (!lang || lang === 'en') return en;
            const cache = this._i18nLoadCache(lang);
            const hit = cache && (cache[en] || cache['Translating...']);
            return (typeof hit === 'string' && hit.trim()) ? hit : en;
        } catch (_) {
            return en;
        }
    },

    _i18nUpdateIndicator() {
        const remaining = this._i18nRemaining();
        let row = this._i18nIndicator;
        if (remaining <= 0) {
            if (row) { row.remove(); this._i18nIndicator = null; }
            return;
        }
        if (!row || !row.isConnected) {
            row = document.createElement('span');
            row.className = 'nym-i18n-bg-indicator';
            row.setAttribute('data-no-i18n', '');
            row.innerHTML = '<span class="nym-i18n-bg-spinner"></span><span class="nym-i18n-bg-text"></span>';
            const anchor = document.querySelector('#sidebar .status-indicator');
            if (anchor) {
                anchor.appendChild(row);
            } else {
                document.body.appendChild(row);
            }
            this._i18nIndicator = row;
        }
        const text = row.querySelector('.nym-i18n-bg-text');
        if (text) text.textContent = this._i18nIndicatorLabel();
        row.classList.add('visible');
    },

    setupUiLanguage() {
        const lang = this.getUiLanguage();
        if (this.settings) this.settings.uiLanguage = lang || '';
        if (lang && lang !== 'en') {
            this.applyUiLanguage(lang).catch(() => { });
        }
    },

    _maybeFirstRunLanguagePicker() {
        const picker = window.NymFirstLang;
        if (picker) picker.onChoose((code) => this._applyFirstRunLanguage(code));
        else document.documentElement.classList.remove('nym-first-lang');
    },

    _applyFirstRunLanguage(code) {
        const current = this.getUiLanguage();
        this._syncTranslateLanguageToUi(code);
        if (code !== current) {
            this.applyUiLanguage(code).catch(() => { });
            const select = document.getElementById('uiLanguageSelect');
            if (select) select.value = code;
        }
        this._markUiLanguageChosen();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _markUiLanguageChosen() {
        try { localStorage.setItem('nym_ui_language_chosen', 'true'); } catch (_) { }
    },

    // Adopt the UI language as the message translation language; English UI maps to 'en'.
    _syncTranslateLanguageToUi(code) {
        const target = (!code || code === 'en') ? 'en' : code;
        if (this.settings) this.settings.translateLanguage = target;
        try { localStorage.setItem('nym_translate_language', target); } catch (_) { }
        if (typeof this.populateTranslateLanguageSelect === 'function') this.populateTranslateLanguageSelect();
        const sel = document.getElementById('translateLanguageSelect');
        if (sel) sel.value = target;
        if (typeof this.retranslateVisibleMessages === 'function') this.retranslateVisibleMessages();
    },

    populateUiLanguageSelect() {
        const select = document.getElementById('uiLanguageSelect');
        if (!select) return;
        const current = this.getUiLanguage();
        const sorted = NYM_TRANSLATE_LANGUAGES
            .slice()
            .filter(l => l.code !== 'en')
            .sort((a, b) => a.name.localeCompare(b.name));
        select.innerHTML = `<option value="">English (default)</option>` +
            sorted.map(l => `<option value="${l.code}">${this.escapeHtml(this._languageOptionLabel(l))}</option>`).join('');
        select.value = current || '';
    },

});
