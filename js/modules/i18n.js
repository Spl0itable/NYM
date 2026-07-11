// i18n.js - App-wide runtime UI localization.

// Subtrees whose text is user-generated or otherwise must never be machine
// translated. Any element matching this (or having such an ancestor) is skipped
// for both text-node and attribute translation.
const NYM_I18N_SKIP_SELECTOR = [
    '#messagesScroller', '#autocompleteDropdown', '#messageInput',
    // Channel / conversation identifiers (user-defined, never translate)
    '.channel-name', '.pm-name', '.group-name', '.channel-title', '.channel-title-line',
    '#currentChannel',
    // Nicknames / nyms — matched broadly since they surface in many places
    // (messages, active-users list, headers, context menus, member lists,
    // reactor/reader tooltips, mentions, calls, columns, commands).
    '[class*="author"]', '[class*="nym-base"]', '[class*="-nym"]', '.nym-suffix',
    '.nym-bracket', '.nym-name', '.nym-display', '.nym-value', '.nym-identity',
    '.nym-sk-name', '.readers-modal-user',
    '.lp-nick', '.lp-bubble-nick', '.nm-mention', '.mention',
    '[class*="member-name"]', '.group-ctx-member', '.group-info-member',
    '[class*="reader"]', '[class*="reactor"]',
    // Transient status strings that interpolate nicknames inline (e.g.
    // "Alice is typing") — skipped wholesale so a name is never translated.
    '#typingIndicator', '.typing-indicator', '.typing-indicator-text', '.cv-typing',
    // Other user-generated / literal content
    '.notification-item-author', '.file-offer-name', '.shop-item-name',
    '.command-name', '.help-cmd-name', '.translate-dropdown-name',
    '.translate-lang-option', '.emoji-name', '.hashtag',
    '.custom-emoji', 'code', 'pre', 'kbd', 'samp',
    '[data-no-i18n]', '.notranslate', '[translate="no"]', '[contenteditable="true"]',
].join(',');

// Attributes carrying visible UI text worth translating.
const NYM_I18N_ATTRS = ['placeholder', 'data-placeholder', 'title', 'aria-label'];

Object.assign(NYM.prototype, {

    // ---- language + cache state -------------------------------------------

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

    _i18nSaveCache(lang) {
        if (this._i18nSaveTimer) clearTimeout(this._i18nSaveTimer);
        this._i18nSaveTimer = setTimeout(() => {
            this._i18nSaveTimer = null;
            const obj = this._i18nCacheStore()[lang];
            if (!obj) return;
            try { localStorage.setItem('nym_ui_i18n_' + lang, JSON.stringify(obj)); } catch (_) { }
        }, 800);
    },

    // ---- skip / collection ------------------------------------------------

    _i18nElSkipped(el) {
        if (!el || el.nodeType !== 1) return true;
        try { if (el.closest(NYM_I18N_SKIP_SELECTOR)) return true; } catch (_) { }
        for (let cur = el; cur && cur.nodeType === 1; cur = cur.parentElement) {
            if (cur.namespaceURI === 'http://www.w3.org/2000/svg') return true;
        }
        return false;
    },

    // A text node is translatable if it holds real words and lives outside any
    // skipped subtree.
    _i18nTextTranslatable(node) {
        const t = node.nodeValue;
        if (!t || t.trim().length < 2) return false;
        if (!/\p{L}/u.test(t)) return false; // pure numbers / emoji / symbols
        const parent = node.parentElement;
        if (this._i18nElSkipped(parent)) return false;
        // Generic nym guard: a base nickname is rendered as a bare text node
        // immediately alongside a `.nym-suffix` span (e.g. Alice<span
        // class="nym-suffix">#1a2b</span>). Never translate such text, wherever
        // it appears (context menus, headers, member lists, etc.).
        if (parent && parent.querySelector && parent.querySelector(':scope > .nym-suffix')) return false;
        return true;
    },

    // Walk a root, pushing {node} text targets and {el, attr} attribute targets
    // into the supplied arrays.
    _i18nCollect(root, textNodes, attrTargets) {
        if (!root) return;
        // Text nodes
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (node) => this._i18nTextTranslatable(node)
                ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
        });
        let n;
        while ((n = walker.nextNode())) textNodes.push(n);

        // Attributes on the root and its descendants
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

    // ---- translation ------------------------------------------------------

    // Normalize a string into a stable cache KEY by replacing volatile tokens
    // ({placeholders} and embedded numbers) with sentinels, returning the token
    // values so they can be substituted back after translation. This makes
    // frequently-updated strings like "42 active nyms" / "43 active nyms" share
    // a single cached translation, so re-renders don't flip between the English
    // and translated forms while a new count is fetched.
    _i18nMakeKey(core) {
        const tokens = [];
        const key = core
            .replace(/\{[^}]+\}/g, (m) => { tokens.push(m); return `PLH${tokens.length - 1}PLH`; })
            .replace(/\d[\d.,:/%+-]*/g, (m) => { tokens.push(m); return `PLH${tokens.length - 1}PLH`; });
        return { key, tokens };
    },

    _i18nFill(template, tokens) {
        if (!tokens.length) return template;
        return template.replace(/PLH(\d+)PLH/g, (_, i) => tokens[+i] != null ? tokens[+i] : '');
    },

    // Translate a templated key string; the returned value keeps the PLH
    // sentinels so token values can be filled back in per instance.
    async _i18nTranslateOne(key, lang) {
        const { translatedText } = await this._doTranslate(key, lang);
        if (!translatedText || !translatedText.trim()) return key;
        return translatedText;
    },

    // ---- background translation queue -------------------------------------
    // Translation runs as a non-blocking background process so the app is
    // usable immediately after a language is chosen. On-screen and dynamically
    // rendered strings (e.g. the tutorial) are enqueued at high priority and
    // translated first; the rest of the UI fills in progressively behind them.

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
        // in-flight jobs will simply finish and populate the cache
    },

    // Add uncached source strings to the translation queue. priority 'hi' jumps
    // ahead of the bulk backlog.
    _i18nEnqueue(sources, priority, lang) {
        lang = lang || this.getUiLanguage();
        if (!lang || lang === 'en' || !sources) return;
        const cache = this._i18nLoadCache(lang);
        const q = this._i18nQueueState();
        const seen = this._i18nQueued;
        for (const src of sources) {
            if (!src || cache[src] != null) continue;
            if (priority === 'hi') {
                // Promote: ensure it runs ASAP even if already queued at low prio.
                if (seen.has(src)) {
                    const i = q.lo.indexOf(src);
                    if (i !== -1) q.lo.splice(i, 1);
                    else continue; // already hi / in-flight
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

    // Translate one string, retrying transient failures with backoff. Returns
    // null on final failure so the caller can retry later rather than poisoning
    // the cache with the untranslated English text.
    async _i18nTranslateWithRetry(source, lang, attempts = 3) {
        for (let i = 0; i < attempts; i++) {
            try {
                return await this._i18nTranslateOne(source, lang);
            } catch (_) {
                if (this.getUiLanguage() !== lang) return null; // user switched away
                if (i < attempts - 1) {
                    await new Promise(r => setTimeout(r, 500 * (i + 1)));
                }
            }
        }
        return null;
    },

    _i18nNoteFailed(src) {
        (this._i18nFailed || (this._i18nFailed = new Set())).add(src);
        // Allow it to be re-enqueued on the next retry round / re-apply.
        if (this._i18nQueued) this._i18nQueued.delete(src);
    },

    // Once the queue drains, retry any strings that failed all attempts, up to a
    // bounded number of rounds (a relay/network hiccup shouldn't leave the UI
    // half-translated forever).
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

    // Throttled re-apply so translated strings swap in progressively as batches
    // land, rather than all at once at the end.
    _i18nScheduleApply(lang) {
        if (this._i18nApplyTimer) return;
        this._i18nApplyTimer = setTimeout(() => {
            this._i18nApplyTimer = null;
            this._i18nApplyVisible(lang || this.getUiLanguage());
        }, 250);
    },

    // Apply whatever is currently cached to the live DOM (no network).
    _i18nApplyVisible(lang) {
        if (!lang || lang === 'en') return;
        const textNodes = [];
        const attrTargets = [];
        this._i18nCollect(document.body, textNodes, attrTargets);
        for (const node of textNodes) this._i18nApplyTextNode(node, lang);
        for (const t of attrTargets) this._i18nApplyAttr(t, lang);
    },

    // Public: apply cached translations to a subtree right now and enqueue any
    // misses at high priority. Used by the tutorial for instant per-step text.
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

    // Public: pre-translate a set of source strings at high priority (e.g. the
    // full tutorial script) so they're ready before/as they appear on screen.
    i18nPrioritize(sources) {
        const lang = this.getUiLanguage();
        if (!lang || lang === 'en' || !Array.isArray(sources)) return;
        this._i18nEnqueue(sources, 'hi', lang);
    },

    _i18nApplyTextNode(node, lang) {
        const cache = this._i18nCacheStore()[lang];
        if (!cache) return;
        const raw = node.nodeValue;
        const m = raw.match(/^(\s*)([\s\S]*?)(\s*)$/);
        const { key, tokens } = this._i18nMakeKey(m[2]);
        const tpl = cache[key];
        if (tpl == null) return;
        const translated = this._i18nFill(tpl, tokens);
        if (node.__i18nOrig == null) node.__i18nOrig = raw;
        const next = m[1] + translated + m[3];
        if (node.nodeValue !== next) {
            // Mark this as our own write so the characterData observer doesn't
            // treat it as new external content and re-translate in a loop.
            if (this._i18nSelfWrites) this._i18nSelfWrites.add(node);
            node.nodeValue = next;
        }
    },

    _i18nApplyAttr(target, lang) {
        const cache = this._i18nCacheStore()[lang];
        if (!cache) return;
        const { el, attr } = target;
        const raw = el.getAttribute(attr);
        if (raw == null) return;
        const { key, tokens } = this._i18nMakeKey(raw.trim());
        const tpl = cache[key];
        if (tpl == null) return;
        const translated = this._i18nFill(tpl, tokens);
        const store = el.__i18nAttrOrig || (el.__i18nAttrOrig = {});
        if (store[attr] == null) store[attr] = raw;
        if (raw !== translated) el.setAttribute(attr, translated);
    },

    // Key of a text node's trimmed core (for missing-detection).
    _i18nNodeKey(node) { return this._i18nMakeKey(node.nodeValue.trim()).key; },
    _i18nAttrKey(el, attr) { return this._i18nMakeKey((el.getAttribute(attr) || '').trim()).key; },

    // ---- public entry points ----------------------------------------------

    // Switch the UI language. lang '' or 'en' restores English. This is
    // non-blocking: cached strings swap in instantly and any misses are
    // translated in the background (with a small unobtrusive indicator), so the
    // app is usable immediately. On-screen/dynamic strings translate first.
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

        // Switching between two non-English languages: drop the old backlog.
        if (this._i18nLang && this._i18nLang !== lang) this._i18nResetQueue();
        this._i18nLang = lang;

        document.documentElement.setAttribute('lang', lang);
        this._i18nLoadCache(lang);
        // Start the observer first so any UI rendered while we translate (e.g.
        // the tutorial) is captured and prioritized.
        this._i18nStartObserver();

        const textNodes = [];
        const attrTargets = [];
        this._i18nCollect(document.body, textNodes, attrTargets);

        const cache = this._i18nCacheStore()[lang];
        const missing = new Set();
        for (const node of textNodes) {
            // Compute the key BEFORE applying — applying mutates the node's text,
            // and reading the key afterwards would enqueue the translated string.
            const key = this._i18nNodeKey(node);
            this._i18nApplyTextNode(node, lang); // instant for already-cached
            if (cache[key] == null) missing.add(key);
        }
        for (const t of attrTargets) {
            const key = this._i18nAttrKey(t.el, t.attr);
            this._i18nApplyAttr(t, lang);
            if (key && cache[key] == null) missing.add(key);
        }

        // Prioritize on-screen modals (e.g. the welcome/setup modal shown when
        // the language is first picked) so they translate FIRST, ahead of the
        // rest of the app. i18nApplyNow enqueues their misses at high priority.
        document.querySelectorAll('.modal.active').forEach((m) => {
            if (!this._i18nElSkipped(m)) this.i18nApplyNow(m);
        });

        // Then the tutorial: pre-translate the whole tour at high priority now,
        // even though it's lazy-rendered later — so it's ready before the rest
        // of the app fills in. Ordering: welcome modal -> tutorial -> the rest.
        try {
            let seen = false;
            try { seen = localStorage.getItem('nym_tutorial_seen') === 'true'; } catch (_) { }
            if (!seen && typeof window.nymTutorialStrings === 'function') {
                const tutorialStrings = window.nymTutorialStrings();
                if (tutorialStrings && tutorialStrings.length) this._i18nEnqueue(tutorialStrings, 'hi', lang);
            }
        } catch (_) { }

        // Everything else is background/low priority (dedup keeps the modal +
        // tutorial strings above at high priority).
        if (missing.size) this._i18nEnqueue([...missing], 'lo', lang);
    },

    // Restore every translated node/attribute back to its captured English text.
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

    // ---- dynamic UI (MutationObserver) ------------------------------------

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
                        // External content replaced this node's text — re-capture.
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
            // Apply cached translations SYNCHRONOUSLY here (before the browser
            // paints) so a re-rendered string that's already translated never
            // flashes back to English. Only genuinely new strings are enqueued
            // for background translation.
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

    // Synchronously apply any cached translations within a subtree, and enqueue
    // uncached strings at high priority.
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

    // ---- background indicator ---------------------------------------------

    // Small, non-blocking pill shown while background translation is in flight.
    _i18nUpdateIndicator() {
        const remaining = this._i18nRemaining();
        let pill = this._i18nIndicator;
        if (remaining <= 0) {
            if (pill) { pill.classList.remove('visible'); }
            return;
        }
        if (!pill) {
            pill = document.createElement('div');
            pill.className = 'nym-i18n-bg-indicator';
            pill.setAttribute('data-no-i18n', '');
            pill.innerHTML = '<span class="nym-i18n-bg-spinner"></span><span class="nym-i18n-bg-text">Translating…</span>';
            document.body.appendChild(pill);
            this._i18nIndicator = pill;
        }
        pill.classList.add('visible');
    },

    // ---- init + boot -------------------------------------------------------

    // Called during app init: if a non-English UI language is stored, apply it
    // from cache immediately and translate any misses in the background.
    setupUiLanguage() {
        const lang = this.getUiLanguage();
        if (this.settings) this.settings.uiLanguage = lang || '';
        if (lang && lang !== 'en') {
            // Non-blocking: cached strings swap instantly, misses fill in.
            this.applyUiLanguage(lang).catch(() => { });
        }
    },

    // On true first run the welcome/setup modal is showing before login. Offer
    // the language picker on top of it (once per device) so the welcome modal
    // itself — and everything after — is translated from the start.
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

    // Whether the first-run UI-language picker has already been shown on this
    // device (device-local, matching the native app).
    _uiLanguageChosen() {
        try { return localStorage.getItem('nym_ui_language_chosen') === 'true'; } catch (_) { return false; }
    },

    _markUiLanguageChosen() {
        try { localStorage.setItem('nym_ui_language_chosen', 'true'); } catch (_) { }
    },

    // First-run / settings language chooser. Returns the chosen code ('' for
    // English) or null if dismissed without choosing.
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
                        ${languages.filter(l => l.code !== 'en').map(l => `<button class="translate-lang-option nm-tr-6${current === l.code ? ' selected' : ''}" data-lang="${l.code}" data-name="${l.name.toLowerCase()}">${this.escapeHtml(l.name)}</button>`).join('')}
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
                    // Close immediately and translate in the background — the app
                    // (and the tutorial) stay usable while strings fill in.
                    finish(code);
                    if (changed) {
                        this.applyUiLanguage(code).catch(() => { });
                        this._syncTranslateLanguageToUi(code);
                        const select = document.getElementById('uiLanguageSelect');
                        if (select) select.value = code;
                        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
                    }
                });
            });

            if (opts.dismissible !== false) {
                overlay.addEventListener('click', (e) => { if (e.target === overlay) finish(null); });
            }

            document.body.appendChild(overlay);
            setTimeout(() => search.focus(), 50);
        });
    },

    // When the user picks an app (UI) language, adopt it as the message
    // "Translation Language" too, so message translation / auto-translate is
    // ready to go in the same language. English UI ('') maps to 'en'.
    _syncTranslateLanguageToUi(code) {
        const target = (!code || code === 'en') ? 'en' : code;
        if (this.settings) this.settings.translateLanguage = target;
        try { localStorage.setItem('nym_translate_language', target); } catch (_) { }
        if (typeof this.populateTranslateLanguageSelect === 'function') this.populateTranslateLanguageSelect();
        const sel = document.getElementById('translateLanguageSelect');
        if (sel) sel.value = target;
        // If auto-translate is on, re-run it against the new target language.
        if (typeof this.retranslateVisibleMessages === 'function') this.retranslateVisibleMessages();
    },

    // Populate the Settings-modal UI-language <select>.
    populateUiLanguageSelect() {
        const select = document.getElementById('uiLanguageSelect');
        if (!select) return;
        const current = this.getUiLanguage();
        const sorted = NYM_TRANSLATE_LANGUAGES
            .slice()
            .filter(l => l.code !== 'en')
            .sort((a, b) => a.name.localeCompare(b.name));
        select.innerHTML = `<option value="">English (default)</option>` +
            sorted.map(l => `<option value="${l.code}">${this.escapeHtml(l.name)}</option>`).join('');
        select.value = current || '';
    },

});
