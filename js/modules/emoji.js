// emoji.js - NIP-30 custom emoji: pack discovery, storage, rendering

const _RX_EMOJI_SHORTCODE = /^[a-zA-Z0-9_]+$/;
const _RX_EMOJI_URL = /^https?:\/\//i;

Object.assign(NYM.prototype, {

    _loadCustomEmojiCache() {
        // Loose shortcode→url map: covers emoji seen via message `emoji` tags
        // that aren't part of any saved pack, so old messages still render
        // their custom emoji after a reload.
        try {
            const map = JSON.parse(localStorage.getItem('nym_custom_emojis') || '[]');
            if (Array.isArray(map)) {
                for (const entry of map) {
                    if (Array.isArray(entry)) this.registerCustomEmoji(entry[0], entry[1]);
                }
            }
        } catch (_) { }
        try {
            const cached = JSON.parse(localStorage.getItem('nym_custom_emoji_packs') || '[]');
            for (const pack of cached) this._storeEmojiPack(pack, false);
        } catch (_) { }
    },

    _saveCustomEmojiCache() {
        if (this._emojiCacheSaveTimer) clearTimeout(this._emojiCacheSaveTimer);
        this._emojiCacheSaveTimer = setTimeout(() => {
            this._emojiCacheSaveTimer = null;
            const write = () => {
                try {
                    const packs = Array.from(this.customEmojiPacks.values())
                        .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))
                        .slice(0, 200);
                    localStorage.setItem('nym_custom_emoji_packs', JSON.stringify(packs));
                } catch (err) {
                    if (err && err.name === 'QuotaExceededError') {
                        try {
                            const trimmed = Array.from(this.customEmojiPacks.values())
                                .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))
                                .slice(0, 80);
                            localStorage.setItem('nym_custom_emoji_packs', JSON.stringify(trimmed));
                        } catch (_) { }
                    }
                }
            };
            if (typeof requestIdleCallback === 'function') requestIdleCallback(write, { timeout: 10000 });
            else write();
        }, 2000);
    },

    _prefetchCustomEmojiImages() {
        if (this._emojiPrefetchTimer) return;
        if (this.settings && this.settings.lowDataMode) return;
        this._emojiPrefetchTimer = setTimeout(() => {
            this._emojiPrefetchTimer = null;
            const run = () => this._runEmojiPrefetch();
            if (typeof requestIdleCallback === 'function') requestIdleCallback(run, { timeout: 5000 });
            else run();
        }, 3000);
    },

    // Warm only images the user is likely to see first (recents, then
    // favorited/own/subscribed packs); everything else loads lazily on open.
    _runEmojiPrefetch() {
        if (!this.customEmojis || this.customEmojis.size === 0) return;
        if (!this._prefetchedEmojiUrls) this._prefetchedEmojiUrls = new Set();
        const urls = [];
        for (const e of (this.recentEmojis || [])) {
            const m = typeof e === 'string' && e.match(/^:([a-zA-Z0-9_]+):$/);
            if (m && this.customEmojis.has(m[1])) urls.push(this.customEmojis.get(m[1]));
        }
        if (this.customEmojiPacks) {
            for (const pack of this.customEmojiPacks.values()) {
                if (!this.isEmojiPackFavorite(pack) && !this.isEmojiPackOwn(pack) &&
                    !this.isEmojiPackSubscribed(pack)) continue;
                for (const e of pack.emojis) {
                    const url = this.customEmojis.get(e.shortcode);
                    if (url) urls.push(url);
                }
            }
        }
        let budget = 60;
        for (const url of urls) {
            if (budget <= 0) break;
            if (this._prefetchedEmojiUrls.has(url)) continue;
            this._prefetchedEmojiUrls.add(url);
            budget--;
            try {
                const img = new Image();
                img.decoding = 'async';
                img.loading = 'eager';
                img.referrerPolicy = 'no-referrer';
                img.src = this.getProxiedEmojiUrl(url);
            } catch (_) { }
        }
    },

    _saveCustomEmojiMap() {
        if (this._emojiMapSaveTimer) clearTimeout(this._emojiMapSaveTimer);
        this._emojiMapSaveTimer = setTimeout(() => {
            this._emojiMapSaveTimer = null;
            try {
                const entries = Array.from(this.customEmojis.entries()).slice(-5000);
                localStorage.setItem('nym_custom_emojis', JSON.stringify(entries));
            } catch (err) {
                if (err && err.name === 'QuotaExceededError') {
                    try {
                        const trimmed = Array.from(this.customEmojis.entries()).slice(-800);
                        localStorage.setItem('nym_custom_emojis', JSON.stringify(trimmed));
                    } catch (_) { }
                }
            }
        }, 2000);
    },

    registerCustomEmoji(shortcode, url) {
        if (!shortcode || !url || !this.customEmojis) return;
        if (!_RX_EMOJI_SHORTCODE.test(shortcode) || !_RX_EMOJI_URL.test(url)) return;
        // Don't let custom emoji shadow built-in unicode shortcodes
        if (this.emojiMap && this.emojiMap[shortcode.toLowerCase()]) return;
        if (this.customEmojis.get(shortcode) === url) return;
        this.customEmojis.set(shortcode, url);
        if (!this._pendingEmojiRefreshCodes) this._pendingEmojiRefreshCodes = new Set();
        this._pendingEmojiRefreshCodes.add(shortcode);
        this._emojiPickerDirty = true;
        this._saveCustomEmojiMap();
        this._scheduleEmojiDomRefresh();
        this._prefetchCustomEmojiImages();
    },

    // A custom emoji can register after messages have already rendered (packs
    // and emoji lists arrive from relays asynchronously). Re-scan rendered
    // message text so newly-known :shortcode: tokens become inline images.
    _scheduleEmojiDomRefresh() {
        if (this._emojiDomRefreshTimer) return;
        this._emojiDomRefreshTimer = setTimeout(() => {
            this._emojiDomRefreshTimer = null;
            this._refreshCustomEmojiInDom();
        }, 300);
    },

    _refreshCustomEmojiInDom() {
        if (!this.customEmojis || this.customEmojis.size === 0) return;
        // Only shortcodes learned since the last refresh can turn rendered text
        // into images; everything older was handled at message render time.
        const pending = this._pendingEmojiRefreshCodes;
        if (!pending || pending.size === 0) return;
        this._pendingEmojiRefreshCodes = new Set();
        const roots = document.querySelectorAll('.message-content, .notification-item-body');
        if (roots.length === 0) return;
        const skip = (node, root) => {
            let p = node.parentNode;
            while (p && p !== root) {
                const tag = p.tagName;
                if (tag === 'A' || tag === 'CODE' || tag === 'PRE') return true;
                if (p.classList && (p.classList.contains('bubble-time') ||
                    p.classList.contains('bubble-time-inner') ||
                    p.classList.contains('message-time'))) return true;
                p = p.parentNode;
            }
            return false;
        };
        for (const root of roots) {
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            const textNodes = [];
            let tn;
            while ((tn = walker.nextNode())) {
                if (tn.nodeValue && tn.nodeValue.indexOf(':') !== -1 && !skip(tn, root)) {
                    textNodes.push(tn);
                }
            }
            for (const node of textNodes) {
                const text = node.nodeValue;
                const matches = [...text.matchAll(/:([a-zA-Z0-9_]+):/g)]
                    .filter(mm => pending.has(mm[1]) && this.customEmojis.has(mm[1]));
                if (matches.length === 0) continue;
                const frag = document.createDocumentFragment();
                let last = 0;
                for (const mm of matches) {
                    if (mm.index > last) {
                        frag.appendChild(document.createTextNode(text.slice(last, mm.index)));
                    }
                    const tmp = document.createElement('span');
                    tmp.innerHTML = this.renderCustomEmojiImg(mm[1]) || '';
                    frag.appendChild(tmp.firstChild || document.createTextNode(mm[0]));
                    last = mm.index + mm[0].length;
                }
                if (last < text.length) {
                    frag.appendChild(document.createTextNode(text.slice(last)));
                }
                if (node.parentNode) node.parentNode.replaceChild(frag, node);
            }
        }
    },

    // Ingest NIP-30 "emoji" tags from any incoming event
    ingestEmojiTags(tags) {
        if (!Array.isArray(tags)) return;
        for (const t of tags) {
            if (Array.isArray(t) && t[0] === 'emoji' && t[1] && t[2]) {
                this.registerCustomEmoji(t[1], t[2]);
            }
        }
    },

    _storeEmojiPack(pack, persist = true) {
        if (!pack || !pack.pubkey || !Array.isArray(pack.emojis) || pack.emojis.length === 0) return;
        const key = `${pack.pubkey}:${pack.identifier || ''}`;
        const existing = this.customEmojiPacks.get(key);
        if (existing && (existing.created_at || 0) >= (pack.created_at || 0)) return;
        this.customEmojiPacks.set(key, pack);
        this._emojiPickerDirty = true;
        for (const e of pack.emojis) this.registerCustomEmoji(e.shortcode, e.url);
        if (persist) this._saveCustomEmojiCache();
        this._prefetchCustomEmojiImages();
    },

    // kind 30030 - emoji set
    handleEmojiPackEvent(event) {
        if (!event || !Array.isArray(event.tags)) return;
        const dTag = event.tags.find(t => t[0] === 'd');
        const titleTag = event.tags.find(t => t[0] === 'title');
        const emojis = [];
        const seen = new Set();
        for (const t of event.tags) {
            if (t[0] === 'emoji' && t[1] && t[2] &&
                _RX_EMOJI_SHORTCODE.test(t[1]) && _RX_EMOJI_URL.test(t[2]) && !seen.has(t[1])) {
                seen.add(t[1]);
                emojis.push({ shortcode: t[1], url: t[2] });
                if (emojis.length >= 120) break;
            }
        }
        if (emojis.length === 0) return;
        const identifier = dTag ? dTag[1] : '';
        this._storeEmojiPack({
            pubkey: event.pubkey,
            identifier,
            title: (titleTag && titleTag[1]) || identifier || 'Emoji pack',
            created_at: event.created_at || 0,
            emojis
        }, true);
    },

    // kind 10030 - user emoji list
    handleUserEmojiListEvent(event) {
        if (!event || event.pubkey !== this.pubkey || !Array.isArray(event.tags)) return;
        if (this._userEmojiListTs && (event.created_at || 0) < this._userEmojiListTs) return;
        this._userEmojiListTs = event.created_at || 0;
        this.userEmojiPackRefs = new Set();
        this._emojiPickerDirty = true;
        for (const t of event.tags) {
            if (t[0] === 'a' && typeof t[1] === 'string' && t[1].startsWith('30030:')) {
                this.userEmojiPackRefs.add(t[1]);
            } else if (t[0] === 'emoji' && t[1] && t[2]) {
                this.registerCustomEmoji(t[1], t[2]);
            }
        }
    },

    isEmojiPackSubscribed(pack) {
        return !!(this.userEmojiPackRefs &&
            this.userEmojiPackRefs.has(`30030:${pack.pubkey}:${pack.identifier || ''}`));
    },

    isEmojiPackOwn(pack) {
        return !!(pack && this.pubkey && pack.pubkey === this.pubkey);
    },

    customEmojiUrl(shortcode) {
        return this.customEmojis ? this.customEmojis.get(shortcode) : null;
    },

    // HTML for an inline custom emoji image, or null when the shortcode is unknown
    renderCustomEmojiImg(shortcode, extraClass = '') {
        const url = this.customEmojiUrl(shortcode);
        if (!url) return null;
        const safeUrl = this.escapeHtml(this.getProxiedEmojiUrl(url));
        const safeCode = this.escapeHtml(shortcode);
        const cls = 'custom-emoji' + (extraClass ? ' ' + extraClass : '');
        return `<img class="${cls}" src="${safeUrl}" alt=":${safeCode}:" title=":${safeCode}:" data-emoji-code="${safeCode}" width="30" height="30" decoding="async" loading="lazy" draggable="false">`;
    },

    // Build NIP-30 emoji tags for every known custom shortcode used in content
    customEmojiTagsForContent(content) {
        const tags = [];
        if (!content || !this.customEmojis || this.customEmojis.size === 0) return tags;
        const seen = new Set();
        const re = /:([a-zA-Z0-9_]+):/g;
        let m;
        while ((m = re.exec(content)) !== null) {
            const code = m[1];
            if (seen.has(code)) continue;
            const url = this.customEmojis.get(code);
            if (url) {
                seen.add(code);
                tags.push(['emoji', code, url]);
            }
        }
        return tags;
    },

    // True when content is solely 1-6 custom emoji tokens (and at least one)
    isCustomEmojiOnly(content) {
        if (!content || !this.customEmojis) return false;
        const tokens = content.trim().split(/\s+/);
        if (tokens.length === 0 || tokens.length > 6) return false;
        return tokens.every(tok => {
            const m = tok.match(/^:([a-zA-Z0-9_]+):$/);
            return m && this.customEmojis.has(m[1]);
        });
    },

    // Render a reaction's content (unicode emoji or :customshortcode:) as HTML
    renderReactionEmoji(emoji) {
        if (typeof emoji === 'string') {
            const m = emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (m) {
                const img = this.renderCustomEmojiImg(m[1], 'custom-emoji-reaction');
                if (img) return img;
            }
        }
        return this.escapeHtml(emoji);
    },

    // HTML for one emoji-picker option button (handles unicode and custom emoji)
    emojiOptionHtml(emoji, emojiToNames, btnClass = 'emoji-option') {
        if (typeof emoji === 'string') {
            const m = emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (m && this.customEmojis && this.customEmojis.has(m[1])) {
                const img = this.renderCustomEmojiImg(m[1]);
                const code = this.escapeHtml(m[1]);
                return `<button class="${btnClass} custom-emoji-option" data-emoji=":${code}:" data-names="${code}" title=":${code}:">${img}</button>`;
            }
        }
        const names = (emojiToNames && emojiToNames[emoji]) || [];
        return `<button class="${btnClass}" data-emoji="${this.escapeHtml(emoji)}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
    },

    // Build the custom-emoji sections for an emoji modal, grouped by pack
    _emojiPackKey(pack) {
        if (!pack || !pack.pubkey) return '';
        return `${pack.pubkey}:${pack.identifier || ''}`;
    },

    _getEmojiPackFavorites() {
        if (!this._emojiPackFavorites) {
            let stored = [];
            try { stored = JSON.parse(localStorage.getItem('nym_emoji_pack_favorites') || '[]'); } catch (_) { }
            this._emojiPackFavorites = Array.isArray(stored) ? stored : [];
        }
        return this._emojiPackFavorites;
    },

    _getDefaultCategoryFavorites() {
        if (!this._defaultCategoryFavorites) {
            let stored = [];
            try { stored = JSON.parse(localStorage.getItem('nym_emoji_category_favorites') || '[]'); } catch (_) { }
            this._defaultCategoryFavorites = Array.isArray(stored) ? stored : [];
        }
        return this._defaultCategoryFavorites;
    },

    isEmojiCategoryFavorite(category) {
        return !!category && this._getDefaultCategoryFavorites().includes(category);
    },

    toggleEmojiCategoryFavorite(category) {
        if (!category) return;
        const favs = this._getDefaultCategoryFavorites();
        const idx = favs.indexOf(category);
        const nowFav = idx === -1;
        if (nowFav) favs.push(category);
        else favs.splice(idx, 1);
        localStorage.setItem('nym_emoji_category_favorites', JSON.stringify(favs));
        this._emojiPickerDirty = true;
        if (typeof nostrSettingsSave === 'function') {
            try { nostrSettingsSave(); } catch (_) { }
        }
        // Reorder default-category sections in any open emoji surface so the
        // newly-favorited category moves to the top of the default block.
        const desiredOrder = this._getOrderedDefaultEmojiEntries().map(([c]) => c);
        const reorderIn = (root) => {
            if (!root) return;
            const sections = Array.from(root.querySelectorAll('.emoji-section, .emoji-picker-section'))
                .filter(el => desiredOrder.includes(el.getAttribute('data-category')));
            if (sections.length < 2) return;
            const parent = sections[0].parentNode;
            const anchor = sections[sections.length - 1].nextSibling;
            desiredOrder.forEach(cat => {
                const el = sections.find(s => s.getAttribute('data-category') === cat);
                if (el) parent.insertBefore(el, anchor);
            });
            root.querySelectorAll('.emoji-category-fav-btn').forEach(btn => {
                const cat = btn.dataset.category;
                const isFav = this.isEmojiCategoryFavorite(cat);
                btn.classList.toggle('active', isFav);
                btn.title = isFav ? 'Unfavorite category' : 'Favorite category';
                btn.setAttribute('aria-label', btn.title);
            });
        };
        reorderIn(this.enhancedEmojiModal);
        reorderIn(document.getElementById('emojiPicker'));
    },

    // Sort default emoji categories: favorited first (in fav-list order),
    // then the remainder in their declared order.
    _getOrderedDefaultEmojiEntries() {
        const favs = this._getDefaultCategoryFavorites();
        const entries = Object.entries(this.allEmojis);
        const favSet = new Set(favs);
        const favored = favs
            .map(cat => entries.find(([c]) => c === cat))
            .filter(Boolean);
        const rest = entries.filter(([c]) => !favSet.has(c));
        return favored.concat(rest);
    },

    _emojiCategoryFavButtonHtml(category) {
        const isFav = this.isEmojiCategoryFavorite(category);
        const label = isFav ? 'Unfavorite category' : 'Favorite category';
        return `<button type="button" class="emoji-category-fav-btn${isFav ? ' active' : ''}" data-action="toggleEmojiCategoryFavorite" data-category="${this.escapeHtml(category)}" title="${label}" aria-label="${label}"><svg viewBox="0 0 24 24" width="14" height="14"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg></button>`;
    },

    isEmojiPackFavorite(pack) {
        const key = this._emojiPackKey(pack);
        return !!key && this._getEmojiPackFavorites().includes(key);
    },

    toggleEmojiPackFavorite(key) {
        if (!key) return;
        const favs = this._getEmojiPackFavorites();
        const idx = favs.indexOf(key);
        const nowFav = idx === -1;
        if (nowFav) favs.push(key);
        else favs.splice(idx, 1);
        localStorage.setItem('nym_emoji_pack_favorites', JSON.stringify(favs));
        this._emojiPickerDirty = true;
        if (typeof nostrSettingsSave === 'function') {
            try { nostrSettingsSave(); } catch (_) { }
        }
        if (this.enhancedEmojiModal) {
            this.enhancedEmojiModal.querySelectorAll('.emoji-pack-fav-btn').forEach(btn => {
                if (btn.dataset && btn.dataset.packKey === key) {
                    btn.classList.toggle('active', nowFav);
                    btn.title = nowFav ? 'Unfavorite this pack' : 'Favorite this pack';
                    btn.setAttribute('aria-label', btn.title);
                }
            });
        }
    },

    buildCustomEmojiSectionsHtml(opts = {}) {
        if (!this.customEmojiPacks || this.customEmojiPacks.size === 0) return '';
        const sectionClass = opts.sectionClass || 'emoji-section';
        const titleClass = opts.titleClass || 'emoji-section-title';
        const gridClass = opts.gridClass || 'emoji-grid';
        const btnClass = opts.btnClass || 'emoji-option';

        const rank = (p) => this.isEmojiPackFavorite(p) ? 0
            : this.isEmojiPackOwn(p) ? 1
            : (this.isEmojiPackSubscribed(p) ? 2 : 3);
        const packs = Array.from(this.customEmojiPacks.values()).sort((a, b) => {
            const ra = rank(a);
            const rb = rank(b);
            if (ra !== rb) return ra - rb;
            return (b.created_at || 0) - (a.created_at || 0);
        });

        let html = '';
        let shown = 0;
        for (const pack of packs) {
            if (shown >= 50) break;
            const emojis = pack.emojis
                .filter(e => this.customEmojis.has(e.shortcode))
                .slice(0, 120);
            if (emojis.length === 0) continue;
            shown++;
            const labelSuffix = (this.isEmojiPackOwn(pack) || this.isEmojiPackSubscribed(pack)) ? ' ★' : '';
            const title = this.escapeHtml(pack.title || 'Emoji pack') + labelSuffix;
            const key = this._emojiPackKey(pack);
            const isFav = this.isEmojiPackFavorite(pack);
            const favBtn = key
                ? `<button type="button" class="emoji-pack-fav-btn${isFav ? ' active' : ''}" data-action="toggleEmojiPackFavorite" data-pack-key="${this.escapeHtml(key)}" title="${isFav ? 'Unfavorite' : 'Favorite'} this pack" aria-label="${isFav ? 'Unfavorite' : 'Favorite'} this pack"><svg viewBox="0 0 24 24" width="14" height="14"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg></button>`
                : '';
            html += `<div class="${sectionClass}" data-category="custom">` +
                `<div class="${titleClass} emoji-pack-title">${title}${favBtn}</div><div class="${gridClass}">` +
                emojis.map(e => this.emojiOptionHtml(`:${e.shortcode}:`, null, btnClass)).join('') +
                `</div></div>`;
        }
        return html;
    },

    _getEmojiToNames() {
        if (!this._emojiToNames) {
            const map = {};
            for (const [name, emoji] of Object.entries(this.emojiMap)) {
                (map[emoji] || (map[emoji] = [])).push(name);
            }
            this._emojiToNames = map;
        }
        return this._emojiToNames;
    },

    // Shared section markup for every emoji picker surface: recents, then
    // custom packs, then default categories.
    _emojiSectionsHtml(opts = {}) {
        const sectionClass = opts.sectionClass || 'emoji-section';
        const titleClass = opts.titleClass || 'emoji-section-title';
        const gridClass = opts.gridClass || 'emoji-grid';
        const btnClass = opts.btnClass || 'emoji-option';
        const emojiToNames = this._getEmojiToNames();
        let html = '';
        const recents = this._recentEmojisForPicker();
        if (recents.length > 0) {
            html += `<div class="${sectionClass}" data-category="recent">` +
                `<div class="${titleClass}">Recently Used</div><div class="${gridClass}">` +
                recents.map(e => this.emojiOptionHtml(e, emojiToNames, btnClass)).join('') +
                `</div></div>`;
        }
        html += this.buildCustomEmojiSectionsHtml(opts);
        for (const [category, emojis] of this._getOrderedDefaultEmojiEntries()) {
            html += `<div class="${sectionClass}" data-category="${category}">` +
                `<div class="${titleClass} emoji-default-cat-title">${category.charAt(0).toUpperCase() + category.slice(1)}${this._emojiCategoryFavButtonHtml(category)}</div>` +
                `<div class="${gridClass}">` +
                emojis.map(e => this.emojiOptionHtml(e, emojiToNames, btnClass)).join('') +
                `</div></div>`;
        }
        return html;
    },

    // Replace :shortcode: tokens in already-HTML-escaped text with custom emoji
    renderCustomEmojiInEscapedText(escapedText) {
        if (!escapedText || !this.customEmojis || this.customEmojis.size === 0) return escapedText;
        return escapedText.replace(/:([a-zA-Z0-9_]+):/g, (match, code) => {
            if (this.customEmojis.has(code)) {
                return this.renderCustomEmojiImg(code) || match;
            }
            return match;
        });
    },

});
