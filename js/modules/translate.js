// translate.js - Message and input translation (auto-detect, language selection)

const NYM_TRANSLATE_ICON_SVG = '<svg class="autotr-icon" viewBox="0 0 24 24" width="13" height="13" fill="currentColor" aria-hidden="true"><path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/></svg>';

// Mirrors and stays under the backend limits (TRANSLATE_BATCH_MAX / _BYTES in functions/api/proxy.js).
const NYM_TRANSLATE_BATCH_MAX = 25;
const NYM_TRANSLATE_BATCH_CHARS = 16000;

Object.assign(NYM.prototype, {

    _languageName(code) {
        if (!code) return '';
        return NYM_TRANSLATE_LANG_NAMES[String(code).toLowerCase()] || code;
    },

    _languageNative(code) {
        if (!code) return '';
        const key = String(code).toLowerCase();
        return NYM_TRANSLATE_LANG_NATIVE[key] || NYM_TRANSLATE_LANG_NAMES[key] || code;
    },

    _languageSubtitle(code) {
        const native = this._languageNative(code);
        const english = this._languageName(code);
        return native === english ? '' : english;
    },

    _languageSearchKey(code, name) {
        return `${name} ${this._languageNative(code)}`.toLowerCase();
    },

    _languageOptionLabel(l) {
        const sub = this._languageSubtitle(l.code);
        return sub ? `${this._languageNative(l.code)} — ${sub}` : l.name;
    },

    _getTranslateFavorites() {
        if (!this._translateFavorites) {
            let stored = [];
            try { stored = JSON.parse(localStorage.getItem('nym_translate_favorites') || '[]'); } catch (_) { }
            this._translateFavorites = Array.isArray(stored) ? stored : [];
        }
        return this._translateFavorites;
    },

    _toggleTranslateFavorite(code) {
        const favs = this._getTranslateFavorites();
        const idx = favs.indexOf(code);
        if (idx === -1) favs.push(code);
        else favs.splice(idx, 1);
        localStorage.setItem('nym_translate_favorites', JSON.stringify(favs));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _sortedTranslateLanguages() {
        const favs = this._getTranslateFavorites();
        const favSet = new Set(favs);
        const favList = favs
            .map(code => NYM_TRANSLATE_LANGUAGES.find(l => l.code === code))
            .filter(Boolean);
        const rest = NYM_TRANSLATE_LANGUAGES
            .filter(l => !favSet.has(l.code))
            .sort((a, b) => a.name.localeCompare(b.name));
        return favList.concat(rest);
    },

    // Falls back to the UI language, then English.
    _effectiveTranslateLanguage() {
        const saved = this.settings && this.settings.translateLanguage;
        if (saved) return saved;
        const ui = typeof this.getUiLanguage === 'function' ? this.getUiLanguage() : '';
        return ui || 'en';
    },

    // Manual translations by message id so re-renders can restore them; in-memory only.
    _manualTrCache() {
        return this._manualTranslations || (this._manualTranslations = new Map());
    },

    // Bounded LRU so a long session doesn't hold every translation.
    _recordManualTranslation(msgId, rec) {
        if (!msgId) return;
        const cache = this._manualTrCache();
        cache.delete(msgId);          // re-insert so eviction stays LRU
        cache.set(msgId, rec);
        while (cache.size > 500) cache.delete(cache.keys().next().value);
    },

    _forgetManualTranslation(msgId) {
        if (msgId && this._manualTranslations) this._manualTranslations.delete(msgId);
    },

    // Recomputed from the rebuilt element so an edited message doesn't get its old translation back.
    _manualTrSourceFor(messageEl) {
        const contentEl = messageEl && messageEl.querySelector('.message-content');
        if (!contentEl) return null;
        return this._manualTrPlainText(this._extractNonQuotedText(contentEl));
    },

    // Safe to call for every message on every render.
    _reapplyManualTranslation(messageEl) {
        if (!messageEl || !this._manualTranslations || !this._manualTranslations.size) return;
        const msgId = messageEl.getAttribute('data-message-id');
        if (!msgId) return;
        const rec = this._manualTranslations.get(msgId);
        if (!rec) return;
        if (messageEl.querySelector(':scope > .message-translation')) return;
        // The message was edited; drop the stale translation.
        const source = this._manualTrSourceFor(messageEl);
        if (source !== rec.source) { this._forgetManualTranslation(msgId); return; }
        this._manualTrElement(messageEl).innerHTML = rec.html;
        this._recordManualTranslation(msgId, rec);
    },

    _manualTrElement(msgEl) {
        let el = msgEl.querySelector('.message-translation');
        if (!el) {
            el = document.createElement('div');
            el.className = 'message-translation';
            const contentEl = msgEl.querySelector('.message-content') || msgEl;
            contentEl.after(el);
        }
        return el;
    },

    _manualTrPlainText(content) {
        // Drop quoted blocks so they don't skew Google's language detection.
        let plainText = String(content || '').replace(/<blockquote\b[^>]*>[\s\S]*?<\/blockquote>/gi, ' ');
        plainText = plainText.replace(/<[^>]+>/g, '');
        plainText = plainText.split('\n').filter(line => !line.trim().startsWith('>')).join('\n').trim();
        if (!plainText) return '';
        // Strip trailing timestamp (e.g. "12:34 PM", "3:05 AM", "23:59").
        return plainText.replace(/\s*\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();
    },

    async translateMessage(content, messageId) {
        const targetLang = this._effectiveTranslateLanguage();

        const plainText = this._manualTrPlainText(content);
        if (!plainText) {
            this.displaySystemMessage('No text to translate.');
            return;
        }
        if (typeof this.aiConsentEnsure === 'function' && !(await this.aiConsentEnsure('translate'))) {
            this.aiConsentBlocked('translate');
            return;
        }

        // Resolved fresh: a render during the request can replace the row.
        const rowFor = () => (messageId
            ? document.querySelector(`[data-message-id="${String(messageId).replace(/"/g, '\\"')}"]`)
            : null);

        // Loading state is recorded too so a mid-request rebuild shows "Translating...".
        const paint = (html) => {
            this._recordManualTranslation(messageId, { lang: targetLang, source: plainText, html });
            const row = rowFor();
            if (row) this._manualTrElement(row).innerHTML = html;
            return !!row;
        };

        const hadRow = paint('<span class="translation-loading">Translating...</span>');

        try {
            const { translatedText, detectedLanguage: detectedLang } =
                await this._translatePreservingMentions(plainText, targetLang);

            // Google returns the input unchanged (or empty) when already in the target language.
            const isNoop = !translatedText || !translatedText.trim() || translatedText.trim() === plainText.trim();

            if (hadRow || rowFor()) {
                if (isNoop) {
                    paint(`<span class="translation-icon">🌐</span> <span class="translation-error">Already in ${this.escapeHtml(this._languageName(targetLang))} (nothing to translate)</span>`);
                } else {
                    const langLabel = detectedLang !== 'auto' && detectedLang !== targetLang
                        ? `<span class="translation-lang">${this.escapeHtml(this._languageName(detectedLang))} → ${this.escapeHtml(this._languageName(targetLang))}</span>` : '';
                    paint(`<span class="translation-icon">🌐</span> ${this.escapeHtml(translatedText).replace(/\n/g, '<br>')} ${langLabel}`);
                }
            } else if (isNoop) {
                this._forgetManualTranslation(messageId);
                this.displaySystemMessage(`Nothing to translate (already in ${this._languageName(targetLang)}).`);
            } else {
                this._forgetManualTranslation(messageId);
                this.displaySystemMessage(`Translation: ${translatedText}`, 'system', { feed: true });
            }
        } catch (err) {
            // Failures aren't recorded so the user can ask again.
            this._forgetManualTranslation(messageId);
            const row = rowFor();
            const translationEl = row && row.querySelector('.message-translation');
            if (translationEl) translationEl.innerHTML = '<span class="translation-error">Translation failed</span>';
            this.displaySystemMessage('Translation failed: ' + (err.message || 'Unknown error'));
        }
    },

    // Returns { text, emojis } where text has placeholders and emojis restores them.
    _shieldEmojis(text) {
        const emojis = [];
        const shielded = text.replace(
            /(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)(?:[\u{E0020}-\u{E007E}]+\u{E007F})?/gu,
            (match) => {
                const idx = emojis.length;
                emojis.push(match);
                return `EMJ${idx}EMJ`;
            }
        );
        return { text: shielded, emojis };
    },

    _restoreEmojis(text, emojis) {
        return text.replace(/EMJ(\d+)EMJ/g, (_, idx) => emojis[parseInt(idx)] || '');
    },

    async _translatePreservingMentions(text, targetLang) {
        const { text: emojiShielded, emojis: savedEmojis } = this._shieldEmojis(text);

        // Even indices are non-mention text, odd indices are mentions.
        const parts = emojiShielded.split(/(@[^\s@]+)/);

        // Google Translate strips edge whitespace, so restore it per chunk.
        const translatable = [];
        parts.forEach((part, index) => {
            if (index % 2 !== 0 || !part.trim()) return;
            const m = part.match(/^(\s*)([\s\S]*?)(\s*)$/);
            translatable.push({ index, lead: m[1], content: m[2], trail: m[3] });
        });

        if (translatable.length === 0) {
            return { translatedText: text, detectedLanguage: 'auto' };
        }

        const results = await Promise.all(
            translatable.map(({ content }) => this._doTranslate(content, targetLang))
        );

        let detectedLanguage = 'auto';
        results.forEach((res, i) => {
            const { index, lead, trail } = translatable[i];
            parts[index] = lead + (res.translatedText || '') + trail;
            if (detectedLanguage === 'auto' && res.detectedLanguage && res.detectedLanguage !== 'auto') {
                detectedLanguage = res.detectedLanguage;
            }
        });

        const translatedText = this._restoreEmojis(parts.join(''), savedEmojis);
        return { translatedText, detectedLanguage };
    },

    async _doTranslate(text, targetLang) {
        const base = this._getProxyBaseUrl();
        if (!base) throw new Error('Translation is unavailable: no API host configured');
        const resp = await this._edgeFetch(`${base}?action=translate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, source: 'auto', target: targetLang }),
        });
        const contentType = (resp.headers.get('content-type') || '').toLowerCase();
        if (!contentType.includes('application/json')) {
            throw new Error(`Translation failed (${resp.status})`);
        }
        const data = await resp.json();
        if (data.error) throw new Error(data.error);
        const translatedText = data.translatedText || '';
        // An empty 200 body would replace the message with nothing.
        if (!translatedText.trim()) throw new Error('Translation failed: empty result');
        return {
            translatedText,
            detectedLanguage: data.detectedLanguage || 'auto',
        };
    },

    // Proxy takes `texts` and answers `translations` in order; not for message translation (not edge-cached).
    async _doTranslateBatch(texts, targetLang) {
        const base = this._getProxyBaseUrl();
        if (!base) throw new Error('Translation is unavailable: no API host configured');
        const resp = await this._edgeFetch(`${base}?action=translate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ texts, source: 'auto', target: targetLang }),
        });
        const contentType = (resp.headers.get('content-type') || '').toLowerCase();
        if (!contentType.includes('application/json')) {
            throw new Error(`Translation failed (${resp.status})`);
        }
        const data = await resp.json();
        if (data.error) throw new Error(data.error);
        if (!Array.isArray(data.translations)) throw new Error('Translation failed: not a batch');
        return data.translations;
    },

    // At most NYM_TRANSLATE_BATCH_MAX strings and NYM_TRANSLATE_BATCH_CHARS characters.
    _translateBatches(texts) {
        const out = [];
        let batch = [];
        let chars = 0;
        for (const text of texts) {
            const len = String(text || '').length;
            if (batch.length && (batch.length >= NYM_TRANSLATE_BATCH_MAX
                || chars + len > NYM_TRANSLATE_BATCH_CHARS)) {
                out.push(batch);
                batch = [];
                chars = 0;
            }
            batch.push(text);
            chars += len;
        }
        if (batch.length) out.push(batch);
        return out;
    },

    async translatePoll(pollId) {
        const poll = this.polls && this.polls.get && this.polls.get(pollId);
        if (!poll) return;
        if (typeof this.aiConsentEnsure === 'function' && !(await this.aiConsentEnsure('translate'))) {
            this.aiConsentBlocked('translate');
            return;
        }
        const targetLang = this._effectiveTranslateLanguage();

        const msgEl = document.querySelector(`[data-message-id="${pollId}"]`);
        let translationEl = msgEl && msgEl.querySelector('.message-translation');
        if (msgEl && !translationEl) {
            translationEl = document.createElement('div');
            translationEl.className = 'message-translation';
            const contentEl = msgEl.querySelector('.message-content') || msgEl;
            contentEl.after(translationEl);
        }
        if (translationEl) translationEl.innerHTML = '<span class="translation-loading">Translating...</span>';

        const segments = [poll.question, ...poll.options.map(o => o.text)];

        try {
            const results = await Promise.all(segments.map(s => this._translatePreservingMentions(s, targetLang)));
            const translated = results.map(r => r.translatedText || '');
            const detectedLang = (results.find(r => r.detectedLanguage && r.detectedLanguage !== 'auto') || {}).detectedLanguage || 'auto';

            const allNoop = translated.every((t, i) => !t || !t.trim() || t.trim() === segments[i].trim());
            if (translationEl) {
                if (allNoop) {
                    translationEl.innerHTML = `<span class="translation-icon">🌐</span> <span class="translation-error">Already in ${this.escapeHtml(this._languageName(targetLang))} (nothing to translate)</span>`;
                } else {
                    const tq = translated[0] || poll.question;
                    const optsHtml = poll.options.map((o, i) => {
                        const t = translated[i + 1] || o.text;
                        return `<div class="poll-translation-option">• ${this.escapeHtml(t)}</div>`;
                    }).join('');
                    const langLabel = detectedLang !== 'auto' && detectedLang !== targetLang
                        ? `<span class="translation-lang">${this.escapeHtml(this._languageName(detectedLang))} → ${this.escapeHtml(this._languageName(targetLang))}</span>` : '';
                    translationEl.innerHTML = `<span class="translation-icon">🌐</span> <div class="poll-translation"><div class="poll-translation-question">${this.escapeHtml(tq)}</div>${optsHtml}</div> ${langLabel}`;
                }
            }
        } catch (err) {
            if (translationEl) translationEl.innerHTML = '<span class="translation-error">Translation failed</span>';
            this.displaySystemMessage('Translation failed: ' + (err.message || 'Unknown error'));
        }
    },

    translateHoverMessage(btn) {
        const msgEl = btn.closest('[data-message-id]');
        if (!msgEl) return;
        const messageId = msgEl.getAttribute('data-message-id');
        if (msgEl.classList.contains('poll-message')) {
            const pollId = msgEl.dataset.pollId || messageId;
            if (typeof this.translatePoll === 'function') this.translatePoll(pollId);
            return;
        }
        const contentEl = msgEl.querySelector('.message-content');
        if (!contentEl) return;
        const content = this._extractNonQuotedText(contentEl);
        if (content) this.translateMessage(content, messageId);
    },

    _extractNonQuotedText(contentEl) {
        const clone = contentEl.cloneNode(true);
        clone.querySelectorAll('blockquote').forEach(bq => bq.remove());
        clone.querySelectorAll('.bubble-time-inner').forEach(bt => bt.remove());
        clone.querySelectorAll('.read-more-btn').forEach(btn => btn.remove());
        return clone.textContent.trim();
    },

    async translateInputText(targetLang) {
        const input = document.getElementById('messageInput');
        const text = input.value.trim();
        if (!text) return;
        if (typeof this.aiConsentEnsure === 'function' && !(await this.aiConsentEnsure('translate'))) {
            this.aiConsentBlocked('translate');
            return;
        }

        const btn = document.getElementById('translateInputBtn');
        if (btn) btn.classList.add('translating');

        try {
            const { translatedText } = await this._translatePreservingMentions(text, targetLang);
            // Don't clobber the input if the translation is empty or echoes the original.
            if (!translatedText || !translatedText.trim() || translatedText.trim() === text.trim()) {
                this.displaySystemMessage('Nothing to translate (text may already be in the target language).');
                return;
            }
            input.value = translatedText;
            this.autoResizeTextarea(input);
        } catch (err) {
            this.displaySystemMessage('Translation failed: ' + (err.message || 'Unknown error'));
        } finally {
            if (btn) btn.classList.remove('translating');
        }
    },

    populateTranslateLanguageSelect() {
        const select = document.getElementById('translateLanguageSelect');
        if (!select) return;
        const current = this.settings.translateLanguage || '';
        const sorted = NYM_TRANSLATE_LANGUAGES
            .slice()
            .sort((a, b) => a.name.localeCompare(b.name));
        select.innerHTML = `<option value="">Disabled</option>` +
            sorted.map(l => `<option value="${l.code}">${this.escapeHtml(this._languageOptionLabel(l))}</option>`).join('');
        select.value = current;
    },

    _renderTranslateDropdownList(filter = '') {
        const list = document.getElementById('translateDropdownList');
        if (!list) return;
        const favs = new Set(this._getTranslateFavorites());
        const q = filter.trim().toLowerCase();
        const langs = this._sortedTranslateLanguages()
            .filter(l => !q || this._languageSearchKey(l.code, l.name).includes(q));
        const starSvg = (filled) => `<svg viewBox="0 0 24 24" width="14" height="14" fill="${filled ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon></svg>`;
        list.innerHTML = langs.map(l => {
            const fav = favs.has(l.code);
            const sub = this._languageSubtitle(l.code);
            return `<div class="translate-dropdown-item" data-lang="${l.code}">
                <span class="translate-dropdown-name">${this.escapeHtml(this._languageNative(l.code))}${sub ? `<span class="translate-dropdown-sub">${this.escapeHtml(sub)}</span>` : ''}</span>
                <button class="translate-dropdown-star${fav ? ' favorited' : ''}" data-fav-lang="${l.code}" title="${fav ? 'Unfavorite' : 'Favorite'}" aria-label="Favorite ${this.escapeHtml(l.name)}">${starSvg(fav)}</button>
            </div>`;
        }).join('') || `<div class="translate-dropdown-empty">No languages found</div>`;
    },

    setupTranslateInput() {
        const btn = document.getElementById('translateInputBtn');
        const dropdown = document.getElementById('translateInputDropdown');
        if (!btn || !dropdown) return;

        dropdown.innerHTML = `
            <div class="translate-dropdown-search">
                <input type="text" id="translateDropdownSearch" placeholder="Search languages..." autocomplete="off">
            </div>
            <div class="translate-dropdown-list" id="translateDropdownList"></div>
        `;
        this._renderTranslateDropdownList();

        const searchInput = dropdown.querySelector('#translateDropdownSearch');

        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const willOpen = !dropdown.classList.contains('active');
            dropdown.classList.toggle('active');
            btn.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
            if (willOpen) {
                searchInput.value = '';
                this._renderTranslateDropdownList();
                this._placeTranslateDropdown(btn, dropdown);
            }
        });

        searchInput.addEventListener('input', () => {
            this._renderTranslateDropdownList(searchInput.value);
        });
        searchInput.addEventListener('click', (e) => e.stopPropagation());

        dropdown.addEventListener('click', (e) => {
            e.stopPropagation();
            const star = e.target.closest('.translate-dropdown-star');
            if (star) {
                const code = star.dataset.favLang;
                this._toggleTranslateFavorite(code);
                const nowFav = this._getTranslateFavorites().includes(code);
                star.classList.toggle('favorited', nowFav);
                star.title = nowFav ? 'Unfavorite' : 'Favorite';
                const svg = star.querySelector('svg');
                if (svg) svg.setAttribute('fill', nowFav ? 'currentColor' : 'none');
                return;
            }
            const item = e.target.closest('.translate-dropdown-item');
            if (item) {
                dropdown.classList.remove('active');
                btn.setAttribute('aria-expanded', 'false');
                this.translateInputText(item.dataset.lang);
            }
        });

        document.addEventListener('click', (e) => {
            if (!e.target.closest('#translateInputBtn') && !e.target.closest('#translateInputDropdown')) {
                dropdown.classList.remove('active');
            }
        });
    },

    _placeTranslateDropdown(btn, dropdown) {
        const row = dropdown.offsetParent;
        if (!row) return;
        const rr = row.getBoundingClientRect();
        const br = btn.getBoundingClientRect();
        const top = (btn.closest('.format-toolbar') || btn).getBoundingClientRect().top;
        const w = dropdown.offsetWidth || 230;
        const left = Math.max(8 - rr.left, Math.min(br.left - rr.left, window.innerWidth - 8 - w - rr.left));
        dropdown.style.right = 'auto';
        dropdown.style.left = Math.round(left) + 'px';
        dropdown.style.bottom = Math.ceil(rr.bottom - top + 4) + 'px';
    },

    // The first-contact PM is translated on render into the app language (not the translate language).
    _isBotWelcomePM(message) {
        return !!(message && message.isBot && typeof message.id === 'string'
            && message.id.startsWith('nymbot-welcome-'));
    },

    _maybeTranslateBotWelcomePM(messageEl, message) {
        try {
            if (!this._isBotWelcomePM(message) || !messageEl) return;
            if (typeof this.translateBotWelcomeBubble !== 'function') return;
            const contentEl = messageEl.querySelector('.message-content');
            if (!contentEl) return;
            const clone = contentEl.cloneNode(true);
            clone.querySelectorAll('.bubble-time-inner').forEach((n) => n.remove());
            const html = clone.innerHTML.trim();
            if (html) this.translateBotWelcomeBubble(messageEl, html);
        } catch (_) { }
    },

    retranslateVisibleMessages() {
        if (this._retranslateTimer) clearTimeout(this._retranslateTimer);
        this._retranslateTimer = setTimeout(() => {
            this._retranslateTimer = null;
            document.querySelectorAll('.message[data-message-id]')
                .forEach(el => this._reapplyManualTranslation(el));
        }, 150);
    },

    // The premium welcome bypasses displayMessage, so translate it here into the app language.

    async _translateHtmlSegment(segment, target) {
        if (!segment || !segment.trim()) return segment;
        const tokens = [];
        const stash = (m) => { tokens.push(m); return `PLH${tokens.length - 1}PLH`; };
        const shielded = String(segment)
            .replace(/<code>[\s\S]*?<\/code>/gi, stash)  // literal commands (keep as-is)
            .replace(/<\/?[a-z][^>]*>/gi, stash)         // other inline tags
            .replace(/&[a-z#0-9]+;/gi, stash);           // html entities
        if (!/\p{L}/u.test(shielded.replace(/PLH\d+PLH/g, ''))) return segment;
        let out;
        try {
            const res = await this._doTranslate(shielded, target);
            out = res && res.translatedText;
        } catch (_) { return segment; }
        if (!out || !out.trim()) return segment;
        return out.replace(/PLH(\d+)PLH/g, (_, i) => tokens[+i] != null ? tokens[+i] : '');
    },

    async _translateBotHtml(html, target) {
        const segments = String(html).split('<br>');
        const translated = await Promise.all(segments.map(seg => this._translateHtmlSegment(seg, target)));
        return translated.join('<br>');
    },

    translateBotWelcomeBubble(el, originalHtml) {
        try {
            const lang = (typeof this.getUiLanguage === 'function' && this.getUiLanguage()) || '';
            if (!lang || lang === 'en' || !el) return;
            this._renderBotWelcomeTranslation(el, originalHtml, lang).catch(() => { });
        } catch (_) { }
    },

    async _renderBotWelcomeTranslation(el, originalHtml, lang) {
        // Keyed by source too: two different welcomes share this cache.
        const cache = this._botWelcomeI18n || (this._botWelcomeI18n = new Map());
        const key = lang + '\u0000' + originalHtml;
        if (!cache.has(key)) cache.set(key, await this._translateBotHtml(originalHtml, lang));
        const translated = cache.get(key);
        if (!translated || translated.trim() === originalHtml.trim()) return;
        if (!el.isConnected || el._autoTr) return;
        const contentEl = el.querySelector('.message-content');
        if (!contentEl) return;
        const timeEl = contentEl.querySelector(':scope > .bubble-time-inner');

        const origWrap = document.createElement('span');
        origWrap.className = 'mt-original';
        origWrap.style.display = 'none';
        for (const n of Array.from(contentEl.childNodes)) {
            if (n === timeEl) continue;
            origWrap.appendChild(n);
        }
        const transWrap = document.createElement('span');
        transWrap.className = 'mt-translated';
        transWrap.innerHTML = translated;
        contentEl.insertBefore(transWrap, timeEl);
        contentEl.insertBefore(origWrap, timeEl);

        const footer = document.createElement('div');
        footer.className = 'message-autotr-footer';
        footer.innerHTML = `<button type="button" class="autotr-toggle">${NYM_TRANSLATE_ICON_SVG}`
            + `<span class="autotr-toggle-text">Show original</span></button>`;
        contentEl.after(footer);
        const btn = footer.querySelector('.autotr-toggle');
        const txt = footer.querySelector('.autotr-toggle-text');
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const showingTrans = transWrap.style.display !== 'none';
            transWrap.style.display = showingTrans ? 'none' : '';
            origWrap.style.display = showingTrans ? '' : 'none';
            txt.textContent = showingTrans ? 'Show translation' : 'Show original';
        });
        el.classList.add('has-auto-translation');
        el._autoTr = { lang, origWrap, transWrap, footer };
    },

    updateTranslateInputBtn() {
        const input = document.getElementById('messageInput');
        const btn = document.getElementById('translateInputBtn');
        if (!btn || !input) return;
        const hasText = input.value.trim().length > 0;
        btn.disabled = !hasText;
        if (!hasText) {
            const dropdown = document.getElementById('translateInputDropdown');
            if (dropdown) dropdown.classList.remove('active');
            btn.setAttribute('aria-expanded', 'false');
        }
    },

});
