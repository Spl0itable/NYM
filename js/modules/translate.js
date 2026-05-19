// translate.js - Message and input translation (auto-detect, language selection)

// Full set of languages supported by Google Translate.
const NYM_TRANSLATE_LANGUAGES = [
    { code: 'af', name: 'Afrikaans' }, { code: 'sq', name: 'Albanian' },
    { code: 'am', name: 'Amharic' }, { code: 'ar', name: 'Arabic' },
    { code: 'hy', name: 'Armenian' }, { code: 'as', name: 'Assamese' },
    { code: 'ay', name: 'Aymara' }, { code: 'az', name: 'Azerbaijani' },
    { code: 'bm', name: 'Bambara' }, { code: 'eu', name: 'Basque' },
    { code: 'be', name: 'Belarusian' }, { code: 'bn', name: 'Bengali' },
    { code: 'bho', name: 'Bhojpuri' }, { code: 'bs', name: 'Bosnian' },
    { code: 'bg', name: 'Bulgarian' }, { code: 'ca', name: 'Catalan' },
    { code: 'ceb', name: 'Cebuano' }, { code: 'ny', name: 'Chichewa' },
    { code: 'zh', name: 'Chinese (Simplified)' }, { code: 'zh-TW', name: 'Chinese (Traditional)' },
    { code: 'co', name: 'Corsican' }, { code: 'hr', name: 'Croatian' },
    { code: 'cs', name: 'Czech' }, { code: 'da', name: 'Danish' },
    { code: 'dv', name: 'Dhivehi' }, { code: 'doi', name: 'Dogri' },
    { code: 'nl', name: 'Dutch' }, { code: 'en', name: 'English' },
    { code: 'eo', name: 'Esperanto' }, { code: 'et', name: 'Estonian' },
    { code: 'ee', name: 'Ewe' }, { code: 'fil', name: 'Filipino' },
    { code: 'fi', name: 'Finnish' }, { code: 'fr', name: 'French' },
    { code: 'fy', name: 'Frisian' }, { code: 'gl', name: 'Galician' },
    { code: 'ka', name: 'Georgian' }, { code: 'de', name: 'German' },
    { code: 'el', name: 'Greek' }, { code: 'gn', name: 'Guarani' },
    { code: 'gu', name: 'Gujarati' }, { code: 'ht', name: 'Haitian Creole' },
    { code: 'ha', name: 'Hausa' }, { code: 'haw', name: 'Hawaiian' },
    { code: 'he', name: 'Hebrew' }, { code: 'hi', name: 'Hindi' },
    { code: 'hmn', name: 'Hmong' }, { code: 'hu', name: 'Hungarian' },
    { code: 'is', name: 'Icelandic' }, { code: 'ig', name: 'Igbo' },
    { code: 'ilo', name: 'Ilocano' }, { code: 'id', name: 'Indonesian' },
    { code: 'ga', name: 'Irish' }, { code: 'it', name: 'Italian' },
    { code: 'ja', name: 'Japanese' }, { code: 'jv', name: 'Javanese' },
    { code: 'kn', name: 'Kannada' }, { code: 'kk', name: 'Kazakh' },
    { code: 'km', name: 'Khmer' }, { code: 'rw', name: 'Kinyarwanda' },
    { code: 'gom', name: 'Konkani' }, { code: 'ko', name: 'Korean' },
    { code: 'kri', name: 'Krio' }, { code: 'ku', name: 'Kurdish (Kurmanji)' },
    { code: 'ckb', name: 'Kurdish (Sorani)' }, { code: 'ky', name: 'Kyrgyz' },
    { code: 'lo', name: 'Lao' }, { code: 'la', name: 'Latin' },
    { code: 'lv', name: 'Latvian' }, { code: 'ln', name: 'Lingala' },
    { code: 'lt', name: 'Lithuanian' }, { code: 'lg', name: 'Luganda' },
    { code: 'lb', name: 'Luxembourgish' }, { code: 'mk', name: 'Macedonian' },
    { code: 'mai', name: 'Maithili' }, { code: 'mg', name: 'Malagasy' },
    { code: 'ms', name: 'Malay' }, { code: 'ml', name: 'Malayalam' },
    { code: 'mt', name: 'Maltese' }, { code: 'mi', name: 'Maori' },
    { code: 'mr', name: 'Marathi' }, { code: 'mni-Mtei', name: 'Meiteilon (Manipuri)' },
    { code: 'lus', name: 'Mizo' }, { code: 'mn', name: 'Mongolian' },
    { code: 'my', name: 'Myanmar (Burmese)' }, { code: 'ne', name: 'Nepali' },
    { code: 'no', name: 'Norwegian' }, { code: 'or', name: 'Odia (Oriya)' },
    { code: 'om', name: 'Oromo' }, { code: 'ps', name: 'Pashto' },
    { code: 'fa', name: 'Persian' }, { code: 'pl', name: 'Polish' },
    { code: 'pt', name: 'Portuguese' }, { code: 'pa', name: 'Punjabi' },
    { code: 'qu', name: 'Quechua' }, { code: 'ro', name: 'Romanian' },
    { code: 'ru', name: 'Russian' }, { code: 'sm', name: 'Samoan' },
    { code: 'sa', name: 'Sanskrit' }, { code: 'gd', name: 'Scots Gaelic' },
    { code: 'nso', name: 'Sepedi' }, { code: 'sr', name: 'Serbian' },
    { code: 'st', name: 'Sesotho' }, { code: 'sn', name: 'Shona' },
    { code: 'sd', name: 'Sindhi' }, { code: 'si', name: 'Sinhala' },
    { code: 'sk', name: 'Slovak' }, { code: 'sl', name: 'Slovenian' },
    { code: 'so', name: 'Somali' }, { code: 'es', name: 'Spanish' },
    { code: 'su', name: 'Sundanese' }, { code: 'sw', name: 'Swahili' },
    { code: 'sv', name: 'Swedish' }, { code: 'tg', name: 'Tajik' },
    { code: 'ta', name: 'Tamil' }, { code: 'tt', name: 'Tatar' },
    { code: 'te', name: 'Telugu' }, { code: 'th', name: 'Thai' },
    { code: 'ti', name: 'Tigrinya' }, { code: 'ts', name: 'Tsonga' },
    { code: 'tr', name: 'Turkish' }, { code: 'tk', name: 'Turkmen' },
    { code: 'ak', name: 'Twi' }, { code: 'uk', name: 'Ukrainian' },
    { code: 'ur', name: 'Urdu' }, { code: 'ug', name: 'Uyghur' },
    { code: 'uz', name: 'Uzbek' }, { code: 'vi', name: 'Vietnamese' },
    { code: 'cy', name: 'Welsh' }, { code: 'xh', name: 'Xhosa' },
    { code: 'yi', name: 'Yiddish' }, { code: 'yo', name: 'Yoruba' },
    { code: 'zu', name: 'Zulu' },
];

// Lookup from language code (case-insensitive) to display name.
const NYM_TRANSLATE_LANG_NAMES = (() => {
    const map = {};
    for (const l of NYM_TRANSLATE_LANGUAGES) map[l.code.toLowerCase()] = l.name;
    map['zh-cn'] = 'Chinese (Simplified)';
    map['iw'] = 'Hebrew';
    map['jw'] = 'Javanese';
    return map;
})();

Object.assign(NYM.prototype, {

    // Resolve a language code (e.g. "en", "zh-CN") to its full display name.
    _languageName(code) {
        if (!code) return '';
        return NYM_TRANSLATE_LANG_NAMES[String(code).toLowerCase()] || code;
    },

    // Favorite languages are kept at the top of the translate input dropdown.
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

    // Languages sorted with favorites first, the rest alphabetically.
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

    // Show a language-picker popup when the user tries to translate without a language set.
    // Returns the chosen language code, or '' if cancelled.
    _promptTranslateLanguage() {
        return new Promise((resolve) => {
            const languages = NYM_TRANSLATE_LANGUAGES
                .slice()
                .sort((a, b) => a.name.localeCompare(b.name));

            const overlay = document.createElement('div');
            overlay.className = 'modal active';
            overlay.style.zIndex = '10003';
            overlay.innerHTML = `
                <div class="modal-content" style="max-width:360px;padding:24px;">
                    <h3 style="margin:0 0 6px;font-size:1.1em;color:var(--text-bright);">Select Your Language</h3>
                    <p style="margin:0 0 12px;font-size:0.85em;color:var(--text-dim);">Choose the language you'd like messages translated into. This will be saved to your settings.</p>
                    <input type="text" class="translate-lang-search" placeholder="Search languages..." style="
                        width:100%;box-sizing:border-box;margin:0 0 12px;padding:9px 12px;border-radius:var(--radius-sm);
                        border:1px solid var(--glass-border);background:rgba(255,255,255,0.05);color:var(--text);
                        font-size:0.9em;outline:none;">
                    <div class="translate-lang-grid" style="display:grid;grid-template-columns:1fr 1fr;gap:6px;max-height:320px;overflow-y:auto;padding-right:4px;">
                        ${languages.map(l => `<button class="translate-lang-option" data-lang="${l.code}" data-name="${l.name.toLowerCase()}" style="
                            padding:10px 12px;border-radius:var(--radius-sm);border:1px solid var(--glass-border);
                            background:rgba(255,255,255,0.04);color:var(--text);cursor:pointer;font-size:0.9em;
                            transition:background 0.12s,border-color 0.12s;text-align:left;
                        ">${l.name}</button>`).join('')}
                    </div>
                </div>
            `;

            const cleanup = (langCode) => {
                overlay.remove();
                resolve(langCode);
            };

            // Filter the grid as the user types
            const search = overlay.querySelector('.translate-lang-search');
            search.addEventListener('input', () => {
                const q = search.value.trim().toLowerCase();
                overlay.querySelectorAll('.translate-lang-option').forEach(btn => {
                    btn.style.display = (!q || btn.dataset.name.includes(q)) ? '' : 'none';
                });
            });

            // Click on a language option
            overlay.querySelectorAll('.translate-lang-option').forEach(btn => {
                btn.addEventListener('click', () => {
                    const code = btn.dataset.lang;
                    // Save to settings and localStorage
                    this.settings.translateLanguage = code;
                    localStorage.setItem('nym_translate_language', code);
                    // Sync the settings modal select if it exists
                    const select = document.getElementById('translateLanguageSelect');
                    if (select) select.value = code;
                    // Persist to relay so it survives reload
                    if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
                    cleanup(code);
                });
                btn.addEventListener('mouseenter', () => {
                    btn.style.background = 'rgba(255,255,255,0.1)';
                    btn.style.borderColor = 'var(--primary)';
                });
                btn.addEventListener('mouseleave', () => {
                    btn.style.background = 'rgba(255,255,255,0.04)';
                    btn.style.borderColor = 'var(--glass-border)';
                });
            });

            // Click on backdrop to cancel
            overlay.addEventListener('click', (e) => {
                if (e.target === overlay) cleanup('');
            });

            document.body.appendChild(overlay);
            setTimeout(() => search.focus(), 50);
        });
    },

    // Translate a message and show the result inline below the original message.
    // Uses the CF proxy when available, falls back to calling Google Translate directly.
    async translateMessage(content, messageId) {
        let targetLang = this.settings.translateLanguage;
        if (!targetLang) {
            targetLang = await this._promptTranslateLanguage();
            if (!targetLang) return; // user cancelled
        }

        // Strip HTML blockquote tags entirely (with their contents) so the
        // quoted reply doesn't pollute language detection. The quote may be in
        // the user's own language while the new reply is in another, and Google
        // would otherwise detect the dominant language and skip the reply.
        let plainText = content.replace(/<blockquote\b[^>]*>[\s\S]*?<\/blockquote>/gi, ' ');
        // Strip remaining HTML tags
        plainText = plainText.replace(/<[^>]+>/g, '');
        // Strip plain-text quote lines ("> ..." style) for the same reason
        plainText = plainText.split('\n').filter(line => !line.trim().startsWith('>')).join('\n').trim();

        if (!plainText) {
            this.displaySystemMessage('No text to translate.');
            return;
        }

        // Strip trailing timestamp (e.g. "12:34 PM", "3:05 AM", "23:59")
        plainText = plainText.replace(/\s*\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();

        // Find the message element to append translation
        const msgEl = messageId ? document.querySelector(`[data-message-id="${messageId}"]`) : null;

        // Show loading state
        if (msgEl) {
            let translationEl = msgEl.querySelector('.message-translation');
            if (!translationEl) {
                translationEl = document.createElement('div');
                translationEl.className = 'message-translation';
                const contentEl = msgEl.querySelector('.message-content') || msgEl;
                contentEl.after(translationEl);
            }
            translationEl.innerHTML = '<span class="translation-loading">Translating...</span>';
        }

        try {
            const { translatedText, detectedLanguage: detectedLang } =
                await this._translatePreservingMentions(plainText, targetLang);

            // Google returns the input unchanged (or empty) when the detected
            // language already matches the target.
            const isNoop = !translatedText || !translatedText.trim() || translatedText.trim() === plainText.trim();

            if (msgEl) {
                let translationEl = msgEl.querySelector('.message-translation');
                if (!translationEl) {
                    translationEl = document.createElement('div');
                    translationEl.className = 'message-translation';
                    const contentEl = msgEl.querySelector('.message-content') || msgEl;
                    contentEl.after(translationEl);
                }
                if (isNoop) {
                    translationEl.innerHTML = `<span class="translation-icon">🌐</span> <span class="translation-error">Already in ${this.escapeHtml(this._languageName(targetLang))} (nothing to translate)</span>`;
                } else {
                    const langLabel = detectedLang !== 'auto' && detectedLang !== targetLang
                        ? `<span class="translation-lang">${this.escapeHtml(this._languageName(detectedLang))} → ${this.escapeHtml(this._languageName(targetLang))}</span>` : '';
                    translationEl.innerHTML = `<span class="translation-icon">🌐</span> ${this.escapeHtml(translatedText).replace(/\n/g, '<br>')} ${langLabel}`;
                }
            } else if (isNoop) {
                this.displaySystemMessage(`Nothing to translate (already in ${this._languageName(targetLang)}).`);
            } else {
                this.displaySystemMessage(`Translation: ${translatedText}`);
            }
        } catch (err) {
            if (msgEl) {
                const translationEl = msgEl.querySelector('.message-translation');
                if (translationEl) translationEl.innerHTML = '<span class="translation-error">Translation failed</span>';
            }
            this.displaySystemMessage('Translation failed: ' + (err.message || 'Unknown error'));
        }
    },

    // Protect emoji from being stripped by translation APIs.
    // Returns { text, emojis } where text has placeholders and emojis is the map to restore them.
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

    // Translate text while keeping @mentions intact in their original positions
    async _translatePreservingMentions(text, targetLang) {
        const { text: emojiShielded, emojis: savedEmojis } = this._shieldEmojis(text);

        // split() with a capturing group keeps the matches in the array.
        // Even indices are non-mention text, odd indices are mentions.
        const parts = emojiShielded.split(/(@[^\s@]+)/);

        // Capture leading/trailing whitespace per chunk so we can restore it
        // after translation — Google Translate strips edge whitespace.
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

    // Single translation call that picks the proxy when available and falls
    // back to a direct Google Translate request on proxy failure.
    async _doTranslate(text, targetLang) {
        const base = this._getProxyBaseUrl();
        if (base) {
            try {
                const resp = await fetch(`${base}?action=translate`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ text, source: 'auto', target: targetLang }),
                });
                const contentType = (resp.headers.get('content-type') || '').toLowerCase();
                if (!contentType.includes('application/json')) {
                    throw new Error(`Proxy returned non-JSON response (${resp.status})`);
                }
                const data = await resp.json();
                if (data.error) throw new Error(data.error);
                return {
                    translatedText: data.translatedText || '',
                    detectedLanguage: data.detectedLanguage || 'auto',
                };
            } catch (proxyErr) {
                // Translate proxy failed for this request — try direct.
                // Don't treat as a global API outage: translate can fail per-request
                // (rate limit, upstream error) without the proxy being down.
                return this._translateDirect(text, targetLang);
            }
        }
        return this._translateDirect(text, targetLang);
    },

    translateHoverMessage(btn) {
        const msgEl = btn.closest('[data-message-id]');
        if (!msgEl) return;
        const messageId = msgEl.getAttribute('data-message-id');
        const contentEl = msgEl.querySelector('.message-content');
        if (!contentEl) return;
        // Extract only the non-quoted text (skip blockquote content)
        const content = this._extractNonQuotedText(contentEl);
        if (content) this.translateMessage(content, messageId);
    },

    // Extract only the user's own reply text from a message element,
    // excluding any quoted/blockquoted content.
    _extractNonQuotedText(contentEl) {
        const clone = contentEl.cloneNode(true);
        // Remove all blockquote elements (quoted replies)
        clone.querySelectorAll('blockquote').forEach(bq => bq.remove());
        // Remove bubble-time-inner elements (timestamp inside bubble)
        clone.querySelectorAll('.bubble-time-inner').forEach(bt => bt.remove());
        // Remove "Read more" / "Show less" toggle buttons
        clone.querySelectorAll('.read-more-btn').forEach(btn => btn.remove());
        return clone.textContent.trim();
    },

    async _translateDirect(text, targetLang) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 8000);
        try {
            const params = new URLSearchParams({
                client: 'gtx',
                sl: 'auto',
                tl: targetLang,
                dt: 't',
                q: text.slice(0, 5000),
            });
            const resp = await fetch(`https://translate.googleapis.com/translate_a/single?${params}`, {
                signal: controller.signal,
            });
            clearTimeout(timer);
            if (!resp.ok) throw new Error(`Google Translate returned ${resp.status}`);
            const data = await resp.json();
            let translatedText = '';
            if (Array.isArray(data[0])) {
                translatedText = data[0].map(seg => seg[0] || '').join('');
            }
            return {
                translatedText,
                detectedLanguage: data[2] || 'auto',
            };
        } catch (err) {
            clearTimeout(timer);
            throw new Error('Translation failed: ' + (err.name === 'AbortError' ? 'timeout' : err.message));
        }
    },

    // Translate text from the message input and replace it with the translation.
    async translateInputText(targetLang) {
        const input = document.getElementById('messageInput');
        const text = input.value.trim();
        if (!text) return;

        const btn = document.getElementById('translateInputBtn');
        if (btn) btn.classList.add('translating');

        try {
            const { translatedText } = await this._translatePreservingMentions(text, targetLang);
            // Don't clobber the input if Google returned nothing or echoed the
            // original (e.g. detected language already matches the target).
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

    // Populate the settings-modal translation language select with the full list.
    populateTranslateLanguageSelect() {
        const select = document.getElementById('translateLanguageSelect');
        if (!select) return;
        const current = this.settings.translateLanguage || '';
        const sorted = NYM_TRANSLATE_LANGUAGES
            .slice()
            .sort((a, b) => a.name.localeCompare(b.name));
        select.innerHTML = `<option value="">Disabled</option>` +
            sorted.map(l => `<option value="${l.code}">${this.escapeHtml(l.name)}</option>`).join('');
        select.value = current;
    },

    // Render the language list inside the translate input dropdown, applying
    // the search filter and keeping favorites pinned to the top.
    _renderTranslateDropdownList(filter = '') {
        const list = document.getElementById('translateDropdownList');
        if (!list) return;
        const favs = new Set(this._getTranslateFavorites());
        const q = filter.trim().toLowerCase();
        const langs = this._sortedTranslateLanguages()
            .filter(l => !q || l.name.toLowerCase().includes(q));
        const starSvg = (filled) => `<svg viewBox="0 0 24 24" width="14" height="14" fill="${filled ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon></svg>`;
        list.innerHTML = langs.map(l => {
            const fav = favs.has(l.code);
            return `<div class="translate-dropdown-item" data-lang="${l.code}">
                <span class="translate-dropdown-name">${this.escapeHtml(l.name)}</span>
                <button class="translate-dropdown-star${fav ? ' favorited' : ''}" data-fav-lang="${l.code}" title="${fav ? 'Unfavorite' : 'Favorite'}" aria-label="Favorite ${this.escapeHtml(l.name)}">${starSvg(fav)}</button>
            </div>`;
        }).join('') || `<div class="translate-dropdown-empty">No languages found</div>`;
    },

    // Set up the translate input button and dropdown in the message input area.
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
            if (willOpen) {
                searchInput.value = '';
                this._renderTranslateDropdownList();
                setTimeout(() => searchInput.focus(), 30);
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
                this._toggleTranslateFavorite(star.dataset.favLang);
                this._renderTranslateDropdownList(searchInput.value);
                return;
            }
            const item = e.target.closest('.translate-dropdown-item');
            if (item) {
                dropdown.classList.remove('active');
                this.translateInputText(item.dataset.lang);
            }
        });

        // Close dropdown when clicking outside
        document.addEventListener('click', (e) => {
            if (!e.target.closest('#translateInputBtn') && !e.target.closest('#translateInputDropdown')) {
                dropdown.classList.remove('active');
            }
        });
    },

    // Show/hide the translate input button based on whether the input has text.
    updateTranslateInputBtn() {
        const input = document.getElementById('messageInput');
        const btn = document.getElementById('translateInputBtn');
        if (!btn || !input) return;
        const hasText = input.value.trim().length > 0;
        btn.style.display = hasText ? 'flex' : 'none';
        input.style.paddingRight = hasText ? '38px' : '';
        // Hide dropdown when button hides
        if (!hasText) {
            const dropdown = document.getElementById('translateInputDropdown');
            if (dropdown) dropdown.classList.remove('active');
        }
    },

});
