// emoji.js - NIP-30 custom emoji: pack discovery, storage, rendering

const _RX_EMOJI_SHORTCODE = /^[a-zA-Z0-9_]+$/;
const _RX_EMOJI_URL = /^https?:\/\//i;

Object.assign(NYM.prototype, {

    initCustomEmojis() {
        if (!this.customEmojis) this.customEmojis = new Map();
        if (!this.customEmojiPacks) this.customEmojiPacks = new Map();
        if (!this.userEmojiPackRefs) this.userEmojiPackRefs = new Set();
        this._loadCustomEmojiCache();
    },

    _loadCustomEmojiCache() {
        try {
            const cached = JSON.parse(localStorage.getItem('nym_custom_emoji_packs') || '[]');
            for (const pack of cached) this._storeEmojiPack(pack, false);
        } catch (_) { }
    },

    _saveCustomEmojiCache() {
        if (this._emojiCacheSaveTimer) clearTimeout(this._emojiCacheSaveTimer);
        this._emojiCacheSaveTimer = setTimeout(() => {
            this._emojiCacheSaveTimer = null;
            try {
                const packs = Array.from(this.customEmojiPacks.values())
                    .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))
                    .slice(0, 80);
                localStorage.setItem('nym_custom_emoji_packs', JSON.stringify(packs));
            } catch (_) { }
        }, 2000);
    },

    registerCustomEmoji(shortcode, url) {
        if (!shortcode || !url || !this.customEmojis) return;
        if (!_RX_EMOJI_SHORTCODE.test(shortcode) || !_RX_EMOJI_URL.test(url)) return;
        // Don't let custom emoji shadow built-in unicode shortcodes
        if (this.emojiMap && this.emojiMap[shortcode.toLowerCase()]) return;
        this.customEmojis.set(shortcode, url);
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
        for (const e of pack.emojis) this.registerCustomEmoji(e.shortcode, e.url);
        if (persist) this._saveCustomEmojiCache();
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
        const safeUrl = this.escapeHtml(this.getProxiedMediaUrl(url));
        const safeCode = this.escapeHtml(shortcode);
        const cls = 'custom-emoji' + (extraClass ? ' ' + extraClass : '');
        return `<img class="${cls}" src="${safeUrl}" alt=":${safeCode}:" title=":${safeCode}:" loading="lazy" draggable="false">`;
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

    // Build the custom-emoji sections for an emoji modal, grouped by pack.
    // sectionClass/titleClass/gridClass/btnClass let it match either modal style.
    buildCustomEmojiSectionsHtml(opts = {}) {
        if (!this.customEmojiPacks || this.customEmojiPacks.size === 0) return '';
        const sectionClass = opts.sectionClass || 'emoji-section';
        const titleClass = opts.titleClass || 'emoji-section-title';
        const gridClass = opts.gridClass || 'emoji-grid';
        const btnClass = opts.btnClass || 'emoji-option';

        const rank = (p) => this.isEmojiPackOwn(p) ? 0 : (this.isEmojiPackSubscribed(p) ? 1 : 2);
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
            const title = this.escapeHtml(pack.title || 'Emoji pack') +
                ((this.isEmojiPackOwn(pack) || this.isEmojiPackSubscribed(pack)) ? ' ★' : '');
            html += `<div class="${sectionClass}" data-category="custom">` +
                `<div class="${titleClass}">${title}</div><div class="${gridClass}">` +
                emojis.map(e => this.emojiOptionHtml(`:${e.shortcode}:`, null, btnClass)).join('') +
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
