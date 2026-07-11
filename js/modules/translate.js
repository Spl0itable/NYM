// translate.js - Message and input translation (auto-detect, language selection)

// Material "translate" glyph (same icon as the composer translate button),
// used for the auto-translation footer to match the native app.
const NYM_TRANSLATE_ICON_SVG = '<svg class="autotr-icon" viewBox="0 0 24 24" width="13" height="13" fill="currentColor" aria-hidden="true"><path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/></svg>';

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
                <div class="modal-content nm-tr-1">
                    <h3 class="nm-tr-2">Select Your Language</h3>
                    <p class="nm-tr-3">Choose the language you'd like messages translated into. This will be saved to your settings.</p>
                    <input type="text" class="translate-lang-search nm-tr-4" placeholder="Search languages...">
                    <div class="translate-lang-grid nm-tr-5">
                        ${languages.map(l => `<button class="translate-lang-option nm-tr-6" data-lang="${l.code}" data-name="${l.name.toLowerCase()}">${l.name}</button>`).join('')}
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

    async translatePoll(pollId) {
        const poll = this.polls && this.polls.get && this.polls.get(pollId);
        if (!poll) return;
        let targetLang = this.settings.translateLanguage;
        if (!targetLang) {
            targetLang = await this._promptTranslateLanguage();
            if (!targetLang) return;
        }

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
                // Update the clicked star in place for instant feedback —
                // the list order updates the next time the dropdown opens.
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

    // Automatically translate on-screen messages that aren't already in the
    // user's translation language. Gated by a master switch plus per-type
    // (channel / PM / group) toggles, mirroring the native app.

    // Strip HTML, quoted replies and trailing timestamps from raw message
    // content so language detection sees only the author's own text.
    _plainTextForTranslate(content) {
        if (!content) return '';
        let t = String(content).replace(/<blockquote\b[^>]*>[\s\S]*?<\/blockquote>/gi, ' ');
        t = t.replace(/<[^>]+>/g, '');
        t = t.split('\n').filter(line => !line.trim().startsWith('>')).join('\n').trim();
        t = t.replace(/\s*\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();
        return t;
    },

    _autoTranslateAppliesTo(message) {
        const s = this.settings;
        if (!s || !s.autoTranslate) return false;
        if (!s.translateLanguage) return false;
        if (!message || message.isOwn) return false;
        if (message.isPM) {
            return message.isGroup ? (s.autoTranslateGroups !== false) : (s.autoTranslatePMs !== false);
        }
        return s.autoTranslateChannels !== false;
    },

    _maybeAutoTranslate(messageEl, message) {
        try {
            if (!this._autoTranslateAppliesTo(message)) return;
            if (!messageEl || messageEl.classList.contains('system-message')) return;
            // During a bulk/historical render (e.g. opening a conversation) don't
            // queue every message — coalesce into a single bounded pass over the
            // most recent on-screen messages once the render settles.
            if (this._bulkAppending || message.isHistorical) {
                this.retranslateVisibleMessages();
                return;
            }
            const msgId = messageEl.getAttribute('data-message-id') || message.id;
            if (!msgId) return;
            const source = this._plainTextForTranslate(message.content);
            if (!source || source.length < 2) return;
            const target = this.settings.translateLanguage;

            const cache = this._autoTranslateCache || (this._autoTranslateCache = new Map());
            const prev = cache.get(msgId);
            if (prev && prev.lang === target && prev.source === source) {
                // Already handled for this language/content — just re-attach the
                // rendered translation if the row was re-created.
                if (prev.status === 'ready' && messageEl.isConnected) this._renderAutoTranslation(messageEl, prev);
                return;
            }
            const q = this._autoTranslateQueue || (this._autoTranslateQueue = []);
            q.push({ el: messageEl, msgId, source, target });
            this._pumpAutoTranslate();
        } catch (_) { }
    },

    _pumpAutoTranslate() {
        const q = this._autoTranslateQueue || (this._autoTranslateQueue = []);
        if (this._autoTranslateActive == null) this._autoTranslateActive = 0;
        const MAX = 4;
        while (this._autoTranslateActive < MAX && q.length) {
            const job = q.shift();
            this._autoTranslateActive++;
            this._runAutoTranslateJob(job).catch(() => { }).then(() => {
                this._autoTranslateActive--;
                this._pumpAutoTranslate();
            });
        }
    },

    async _runAutoTranslateJob(job) {
        const { el, msgId, source, target } = job;
        // Bail if the language changed or the row is gone.
        if (!el || !el.isConnected) return;
        if (this.settings.translateLanguage !== target) return;
        const cache = this._autoTranslateCache || (this._autoTranslateCache = new Map());
        const existing = cache.get(msgId);
        if (existing && existing.lang === target && existing.source === source && existing.status !== 'loading') {
            if (existing.status === 'ready') this._renderAutoTranslation(el, existing);
            return;
        }
        cache.set(msgId, { lang: target, source, status: 'loading' });
        try {
            const { translatedText, detectedLanguage } = await this._translatePreservingMentions(source, target);
            // Silent no-op when the message is already in the target language:
            // no icon, no error, no footer — just leave the original.
            const noop = !translatedText || !translatedText.trim()
                || translatedText.trim() === source.trim()
                || (detectedLanguage && detectedLanguage !== 'auto' && detectedLanguage === target);
            const entry = {
                lang: target, source,
                status: noop ? 'noop' : 'ready',
                translated: translatedText,
                detected: detectedLanguage || 'auto',
            };
            cache.set(msgId, entry);
            if (!noop && el.isConnected) this._renderAutoTranslation(el, entry);
        } catch (_) {
            cache.set(msgId, { lang: target, source, status: 'error' });
        }
    },

    // Replace the message text in place with the translation (keeping media,
    // quotes, timestamp and hover buttons), and add a "Show original" toggle —
    // matching the native app, rather than showing a separate manual-style row.
    _renderAutoTranslation(messageEl, entry) {
        const contentEl = messageEl.querySelector('.message-content');
        if (!contentEl) return;
        // Don't touch a message the user manually translated.
        if (messageEl.querySelector(':scope > .message-translation:not(.auto)')) return;

        // Already showing an auto-translation: refresh only if the DOM was
        // rebuilt or the target language changed.
        if (messageEl._autoTr) {
            const st = messageEl._autoTr;
            if (st.transWrap && st.transWrap.isConnected && st.lang === entry.lang) return;
            this._restoreAutoTranslation(messageEl);
        }

        // Posted media, link previews, file offers and quotes are KEPT in place
        // exactly as rendered — re-rendering them from the (machine-translated)
        // text would break image/video loading, mangle media URLs, and drop the
        // async-unfurled rich-link previews. Only the message TEXT is swapped.
        const MEDIA_SEL = 'img.msg-img, img.message-image, video, .video-container,'
            + ' audio, .link-preview-container, .link-preview, .file-offer, .media-container';
        const KEEP = 'blockquote, ' + MEDIA_SEL;
        const timeEl = contentEl.querySelector(':scope > .bubble-time-inner');
        const hoverEl = contentEl.querySelector(':scope > .msg-hover-buttons');

        // If the reply was truncated ("Read more"), unwrap it first so any media
        // nested inside the truncation wrapper becomes a direct child again and
        // is kept in place. We re-apply the same truncation to the translated
        // text below, so the translated view is truncated just like the original.
        const wasTruncated = contentEl.classList.contains('has-truncation')
            || !!contentEl.querySelector(':scope > .truncated-inner');
        contentEl.querySelectorAll(':scope > .truncated-inner').forEach(inner => {
            while (inner.firstChild) contentEl.insertBefore(inner.firstChild, inner);
            inner.remove();
        });
        contentEl.querySelectorAll(':scope > .read-more-btn').forEach(b => b.remove());
        contentEl.classList.remove('has-truncation');

        // Move the original body's text (everything except timestamp, hover
        // buttons and kept media/quotes) into a hidden wrapper we can restore.
        const origWrap = document.createElement('span');
        origWrap.className = 'mt-original';
        origWrap.style.display = 'none';
        for (const n of Array.from(contentEl.childNodes)) {
            if (n === timeEl || n === hoverEl) continue;
            if (n.nodeType === 1 && n.matches && n.matches(KEEP)) continue; // keep in place
            origWrap.appendChild(n); // moves the node out of the flow
        }

        const transWrap = document.createElement('span');
        transWrap.className = 'mt-translated';
        // Render the translation through the message formatter so links stay
        // clickable, @mentions keep their chips, and emoji/markdown render —
        // falling back to escaped text if formatting fails.
        let translatedHtml;
        try {
            translatedHtml = (typeof this.formatMessage === 'function')
                ? this.formatMessage(entry.translated)
                : this.escapeHtml(entry.translated).replace(/\n/g, '<br>');
        } catch (_) {
            translatedHtml = this.escapeHtml(entry.translated).replace(/\n/g, '<br>');
        }
        transWrap.innerHTML = translatedHtml;
        // Strip any media the formatter embedded from the translated text — the
        // originals are kept above, so this avoids duplicates and broken URLs.
        transWrap.querySelectorAll(MEDIA_SEL).forEach(el => el.remove());

        const before = timeEl || hoverEl || null;
        contentEl.insertBefore(transWrap, before);
        contentEl.insertBefore(origWrap, before); // hidden; kept for exact restore

        // Mirror the original's "Read more" truncation on the translated text so
        // both languages collapse the same way.
        if (wasTruncated) this._truncateTranslated(transWrap);

        // Footer BELOW the message: translate icon + "Show original" toggle, and
        // a revealed "Original (Language): …" block. Matches the native app.
        const detected = entry.detected;
        const srcLang = (detected && detected !== 'auto') ? this._languageName(detected) : '';
        const origLabel = srcLang ? `Original (${srcLang}):` : 'Original:';
        const footer = document.createElement('div');
        footer.className = 'message-autotr-footer';
        // Collapsed by default (the .autotr-original block is hidden via CSS
        // until the toggle adds .expanded).
        footer.innerHTML =
            `<button type="button" class="autotr-toggle">${NYM_TRANSLATE_ICON_SVG}`
            + `<span class="autotr-toggle-text">Show original</span></button>`
            + `<div class="autotr-original">`
            + `<span class="autotr-original-label">${this.escapeHtml(origLabel)}</span> `
            + `<span class="autotr-original-text">${this.escapeHtml(entry.source).replace(/\n/g, '<br>')}</span></div>`;
        contentEl.after(footer);

        const btn = footer.querySelector('.autotr-toggle');
        const txt = footer.querySelector('.autotr-toggle-text');
        const orig = footer.querySelector('.autotr-original');
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const show = !orig.classList.contains('expanded');
            orig.classList.toggle('expanded', show);
            txt.textContent = show ? 'Hide original' : 'Show original';
        });

        messageEl.classList.add('has-auto-translation');
        messageEl._autoTr = { lang: entry.lang, origWrap, transWrap, footer };
    },

    // Wrap the translated text in a collapsible "Read more" block, mirroring
    // the reply-truncation in _finalizeMessageContent so a long translation
    // collapses just like the long original did.
    _truncateTranslated(wrap) {
        try {
            const inner = document.createElement('span');
            inner.className = 'truncated-inner';
            while (wrap.firstChild) inner.appendChild(wrap.firstChild);
            wrap.appendChild(inner);
            const btn = document.createElement('button');
            btn.className = 'read-more-btn';
            btn.textContent = 'Read more';
            btn.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                const expanded = inner.classList.toggle('truncated-expanded');
                btn.textContent = expanded ? 'Show less' : 'Read more';
            });
            wrap.appendChild(btn);
            wrap.classList.add('has-truncation');
            // Height-based (same as the original): if it already fits, drop the
            // toggle and leave it expanded.
            if (inner.clientHeight > 0 && inner.scrollHeight <= inner.clientHeight + 2) {
                btn.remove();
                wrap.classList.remove('has-truncation');
                inner.classList.add('truncated-expanded');
            }
        } catch (_) { }
    },

    // Undo an in-place auto-translation, moving the original text back.
    _restoreAutoTranslation(messageEl) {
        const st = messageEl._autoTr;
        if (!st) return;
        const contentEl = messageEl.querySelector('.message-content');
        if (contentEl && st.origWrap && st.origWrap.parentNode === contentEl) {
            while (st.origWrap.firstChild) contentEl.insertBefore(st.origWrap.firstChild, st.origWrap);
        }
        if (st.origWrap) st.origWrap.remove();
        if (st.transWrap) st.transWrap.remove();
        if (st.footer) st.footer.remove();
        messageEl.classList.remove('has-auto-translation');
        messageEl._autoTr = null;
    },

    // Re-run (or clear) auto-translation across the currently rendered messages.
    // Called when the auto-translate settings change. Conversation type is
    // inferred from the active view since all visible rows share it.
    retranslateVisibleMessages() {
        if (this._retranslateTimer) clearTimeout(this._retranslateTimer);
        this._retranslateTimer = setTimeout(() => {
            this._retranslateTimer = null;
            const s = this.settings || {};
            const on = !!(s.autoTranslate && s.translateLanguage);
            const els = document.querySelectorAll('[data-message-id]');
            if (!on) {
                els.forEach(el => {
                    if (el._autoTr) this._restoreAutoTranslation(el);
                    const auto = el.querySelector('.message-translation.auto');
                    if (auto) auto.remove(); // legacy row form
                });
                return;
            }
            const type = this.inPMMode ? (this.currentGroup ? 'group' : 'pm') : 'channel';
            // Bound the batch so switching this on in a long backlog doesn't
            // fire hundreds of requests at once.
            const list = Array.prototype.slice.call(els, -40);
            list.forEach(el => {
                const msg = {
                    id: el.getAttribute('data-message-id'),
                    isOwn: el.classList.contains('self'),
                    isPM: type !== 'channel',
                    isGroup: type === 'group',
                    content: el.dataset.rawContent || '',
                };
                this._maybeAutoTranslate(el, msg);
            });
        }, 150);
    },

    // The Nymbot premium welcome is a local HTML bubble (not routed through
    // displayMessage), so translate it into the user's chosen APP language —
    // independent of the message auto-translate toggle — preserving formatting
    // and literal <code> commands, with a Show original toggle.

    // Translate one <br>-joined HTML line, shielding tags and literal commands.
    async _translateHtmlSegment(segment, target) {
        if (!segment || !segment.trim()) return segment;
        const tokens = [];
        const stash = (m) => { tokens.push(m); return `PLH${tokens.length - 1}PLH`; };
        const shielded = String(segment)
            .replace(/<code>[\s\S]*?<\/code>/gi, stash)  // literal commands (keep as-is)
            .replace(/<\/?[a-z][^>]*>/gi, stash)         // other inline tags
            .replace(/&[a-z#0-9]+;/gi, stash);           // html entities
        if (!/\p{L}/u.test(shielded.replace(/PLH\d+PLH/g, ''))) return segment; // nothing to translate
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

    // Public: translate a Nymbot welcome bubble in place (with a toggle) into
    // the user's app language. No-op for English.
    translateBotWelcomeBubble(el, originalHtml) {
        try {
            const lang = (typeof this.getUiLanguage === 'function' && this.getUiLanguage()) || '';
            if (!lang || lang === 'en' || !el) return;
            this._renderBotWelcomeTranslation(el, originalHtml, lang).catch(() => { });
        } catch (_) { }
    },

    async _renderBotWelcomeTranslation(el, originalHtml, lang) {
        const cache = this._botWelcomeI18n || (this._botWelcomeI18n = {});
        if (cache[lang] == null) cache[lang] = await this._translateBotHtml(originalHtml, lang);
        const translated = cache[lang];
        if (!translated || translated.trim() === originalHtml.trim()) return;
        if (!el.isConnected || el._autoTr) return;
        const contentEl = el.querySelector('.message-content');
        if (!contentEl) return;
        const timeEl = contentEl.querySelector(':scope > .bubble-time-inner');

        // Hide the original body (keep the timestamp), show the translation.
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

    // Reflect the current auto-translate settings into the Settings-modal
    // controls (used after a cross-device settings sync).
    _syncAutoTranslateSettingsUI() {
        const s = this.settings || {};
        const set = (id, val) => { const el = document.getElementById(id); if (el) el.value = val; };
        set('autoTranslateSelect', s.autoTranslate ? 'true' : 'false');
        set('autoTranslateChannelsSelect', s.autoTranslateChannels !== false ? 'true' : 'false');
        set('autoTranslatePMsSelect', s.autoTranslatePMs !== false ? 'true' : 'false');
        set('autoTranslateGroupsSelect', s.autoTranslateGroups !== false ? 'true' : 'false');
        const sub = document.getElementById('autoTranslateSubOptions');
        if (sub) sub.style.display = s.autoTranslate ? '' : 'none';
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
