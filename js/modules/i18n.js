// User-generated subtrees that must never be machine translated, for text nodes and attributes alike.
const NYM_I18N_SKIP_SELECTOR = [
    '#messagesScroller', '#autocompleteDropdown', '#messageInput',
    '.channel-name', '.pm-name', '.group-name', '.channel-title', '.channel-title-line',
    '#currentChannel',
    '[class*="author"]', '[class*="nym-base"]', '[class*="-nym"]', '.nym-suffix',
    '.nym-bracket', '.nym-name', '.nym-display', '.nym-value', '.nym-identity',
    '.nym-sk-name', '.readers-modal-user',
    '.lp-nick', '.lp-bubble-nick', '.nm-mention', '.mention',
    '[class*="member-name"]', '.group-ctx-member', '.group-info-member',
    '[class*="reader"]', '[class*="reactor"]',
    // Transient status strings that interpolate nicknames inline.
    '#typingIndicator', '.typing-indicator', '.typing-indicator-text', '.cv-typing',
    '.notification-item-author', '.file-offer-name', '.shop-item-name',
    '.command-name', '.help-cmd-name', '.translate-dropdown-name',
    '.translate-lang-option', '.emoji-name', '.hashtag',
    // Language names are endonyms and must never be translated.
    '#translateLanguageSelect', '#uiLanguageSelect', '.translate-lang-grid',
    // The translate dropdown's star aria-labels interpolate language names.
    '.translate-dropdown-item',
    '.custom-emoji', 'code', 'pre', 'kbd', 'samp',
    '[data-no-i18n]', '.notranslate', '[translate="no"]', '[contenteditable="true"]',
].join(',');

const NYM_I18N_ATTRS = ['placeholder', 'data-placeholder', 'title', 'aria-label'];

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
        let obj = {};
        try {
            const raw = localStorage.getItem('nym_ui_i18n_' + lang);
            if (raw) { const p = JSON.parse(raw); if (p && typeof p === 'object') obj = p; }
        } catch (_) { }
        store[lang] = obj;
        return obj;
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
                let added = 0;
                for (const [key, translated] of Object.entries(pack)) {
                    if (typeof translated !== 'string' || !translated) continue;
                    if (typeof cache[key] === 'string') continue;
                    cache[key] = translated;
                    added++;
                }
                if (added) this._i18nSaveCache(lang);
            } catch (_) {
                delete inflight[lang];
            }
        })();
        inflight[lang] = done;
        return done;
    },

    _i18nSaveCache(lang) {
        if (this._i18nSaveTimer) clearTimeout(this._i18nSaveTimer);
        this._i18nSaveTimer = setTimeout(() => {
            this._i18nSaveTimer = null;
            const obj = this._i18nCacheStore()[lang];
            if (!obj) return;
            try { localStorage.setItem('nym_ui_i18n_' + lang, JSON.stringify(obj)); } catch (_) { }
        }, 800);
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
        return { key, tokens };
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
        for (const src of sources) {
            if (!src || cache[src] != null) continue;
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
        const q = this._i18nQueueState();
        const MAX = 6;
        while (this._i18nActive < MAX && (q.hi.length || q.lo.length)) {
            const src = q.hi.length ? q.hi.shift() : q.lo.shift();
            this._i18nActive++;
            this._i18nTranslateWithRetry(src, lang)
                .then((out) => {
                    if (out != null) this._i18nLoadCache(lang)[src] = out;
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

    uiText(text) {
        const lang = this.getUiLanguage();
        if (!lang || lang === 'en' || typeof text !== 'string') return text;
        const { key, tokens } = this._i18nMakeKey(text);
        const tpl = this._i18nLoadCache(lang)[key];
        if (tpl == null) {
            this._i18nEnqueue([key], 'hi', lang);
            return text;
        }
        const out = this._i18nFill(tpl, tokens);
        if (out !== text) {
            if (!this._i18nSources) this._i18nSources = new Map();
            this._i18nSources.delete(out);
            this._i18nSources.set(out, text);
            if (this._i18nSources.size > 200) this._i18nSources.delete(this._i18nSources.keys().next().value);
        }
        return out;
    },

    uiSourceOf(text) {
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
        const { key, tokens } = this._i18nMakeKey(m[2]);
        const tpl = cache[key];
        if (tpl == null) return;
        const translated = this._i18nFill(tpl, tokens);
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
        const { key, tokens } = this._i18nMakeKey(raw.trim());
        const tpl = cache[key];
        if (tpl == null) return;
        const translated = this._i18nFill(tpl, tokens);
        const store = el.__i18nAttrOrig || (el.__i18nAttrOrig = {});
        if (store[attr] == null) store[attr] = raw;
        if (el.getAttribute(attr) !== translated) el.setAttribute(attr, translated);
    },

    // Every read for keying or applying must use the original English, never the translated text.
    _i18nSourceText(node) {
        return node.__i18nOrig != null ? node.__i18nOrig : node.nodeValue;
    },
    _i18nSourceAttr(el, attr) {
        const kept = el.__i18nAttrOrig ? el.__i18nAttrOrig[attr] : null;
        return kept != null ? kept : el.getAttribute(attr);
    },

    _i18nNodeKey(node) { return this._i18nMakeKey(this._i18nSourceText(node).trim()).key; },
    _i18nAttrKey(el, attr) { return this._i18nMakeKey((this._i18nSourceAttr(el, attr) || '').trim()).key; },

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
            this._i18nUpdateIndicator();
            document.documentElement.setAttribute('lang', 'en');
            return;
        }

        if (this._i18nLang && this._i18nLang !== lang) this._i18nResetQueue();
        this._i18nLang = lang;

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
            for (const mut of mutations) {
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
            row = document.createElement('div');
            row.className = 'nym-i18n-bg-indicator';
            row.setAttribute('data-no-i18n', '');
            row.innerHTML = '<span class="nym-i18n-bg-spinner"></span><span class="nym-i18n-bg-text"></span>';
            const anchor = document.querySelector('.sidebar-header .status-indicator');
            if (anchor && anchor.parentNode) {
                anchor.insertAdjacentElement('afterend', row);
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

    // On first run, offer the language picker over the welcome modal once per device.
    _maybeFirstRunLanguagePicker() {
        try {
            if (this._uiLanguageChosen()) return;
            const setup = document.getElementById('setupModal');
            if (!setup || !setup.classList.contains('active')) return;
            setTimeout(() => {
                if (this._uiLanguageChosen()) return;
                this.showUiLanguagePicker({ dismissible: true })
                    .then(() => this._markUiLanguageChosen())
                    .catch(() => this._markUiLanguageChosen());
            }, 350);
        } catch (_) { }
    },

    _uiLanguageChosen() {
        try { return localStorage.getItem('nym_ui_language_chosen') === 'true'; } catch (_) { return false; }
    },

    _markUiLanguageChosen() {
        try { localStorage.setItem('nym_ui_language_chosen', 'true'); } catch (_) { }
    },

    // Returns the chosen code ('' for English) or null if dismissed.
    showUiLanguagePicker(opts = {}) {
        return new Promise((resolve) => {
            const languages = NYM_TRANSLATE_LANGUAGES
                .slice()
                .sort((a, b) => a.name.localeCompare(b.name));
            const current = this.getUiLanguage();

            const overlay = document.createElement('div');
            overlay.className = 'modal active';
            overlay.setAttribute('data-no-i18n', '');
            overlay.style.zIndex = '10004';
            overlay.innerHTML = `
                <div class="modal-content nm-tr-1">
                    <h3 class="nm-tr-2">${this.escapeHtml(opts.title || 'Choose Your Language')}</h3>
                    <p class="nm-tr-3">${this.escapeHtml(opts.subtitle || "Select the language you'd like the app displayed in. You can change this anytime in Settings.")}</p>
                    <input type="text" class="translate-lang-search nm-tr-4" placeholder="Search languages...">
                    <div class="translate-lang-grid nm-tr-5">
                        <button class="translate-lang-option nm-tr-6${!current ? ' selected' : ''}" data-lang="" data-name="english default">English</button>
                        ${languages.filter(l => l.code !== 'en').map(l => this._languageOptionButton(l, current)).join('')}
                    </div>
                </div>`;

            const finish = (code) => {
                overlay.remove();
                resolve(code);
            };

            const search = overlay.querySelector('.translate-lang-search');
            search.addEventListener('input', () => {
                const q = search.value.trim().toLowerCase();
                overlay.querySelectorAll('.translate-lang-option').forEach(btn => {
                    btn.style.display = (!q || btn.dataset.name.includes(q)) ? '' : 'none';
                });
            });

            overlay.querySelectorAll('.translate-lang-option').forEach(btn => {
                btn.addEventListener('click', () => {
                    const code = btn.dataset.lang || '';
                    const changed = code !== current;
                    finish(code);
                    // Adopt the translation target even when the UI language didn't change.
                    this._syncTranslateLanguageToUi(code);
                    if (changed) {
                        this.applyUiLanguage(code).catch(() => { });
                        const select = document.getElementById('uiLanguageSelect');
                        if (select) select.value = code;
                    }
                    if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
                });
            });

            if (opts.dismissible !== false) {
                overlay.addEventListener('click', (e) => { if (e.target === overlay) finish(null); });
            }

            document.body.appendChild(overlay);
            setTimeout(() => search.focus(), 50);
        });
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
