// translate.js - Message and input translation (auto-detect, language selection)

Object.assign(NYM.prototype, {

    // Show a language-picker popup when the user tries to translate without a language set.
    // Returns the chosen language code, or '' if cancelled.
    _promptTranslateLanguage() {
        return new Promise((resolve) => {
            const languages = [
                { code: 'en', name: 'English' },
                { code: 'es', name: 'Spanish' },
                { code: 'fr', name: 'French' },
                { code: 'de', name: 'German' },
                { code: 'it', name: 'Italian' },
                { code: 'pt', name: 'Portuguese' },
                { code: 'ru', name: 'Russian' },
                { code: 'zh', name: 'Chinese' },
                { code: 'ja', name: 'Japanese' },
                { code: 'ko', name: 'Korean' },
                { code: 'ar', name: 'Arabic' },
                { code: 'hi', name: 'Hindi' },
                { code: 'tr', name: 'Turkish' },
                { code: 'nl', name: 'Dutch' },
                { code: 'pl', name: 'Polish' },
                { code: 'uk', name: 'Ukrainian' },
                { code: 'vi', name: 'Vietnamese' },
                { code: 'th', name: 'Thai' },
                { code: 'id', name: 'Indonesian' },
                { code: 'sv', name: 'Swedish' },
                { code: 'af', name: 'Afrikaans' },
                { code: 'bg', name: 'Bulgarian' },
                { code: 'bn', name: 'Bengali' },
                { code: 'ca', name: 'Catalan' },
                { code: 'cs', name: 'Czech' },
                { code: 'da', name: 'Danish' },
                { code: 'el', name: 'Greek' },
                { code: 'et', name: 'Estonian' },
                { code: 'fa', name: 'Persian' },
                { code: 'fi', name: 'Finnish' },
                { code: 'fil', name: 'Filipino' },
                { code: 'he', name: 'Hebrew' },
                { code: 'hr', name: 'Croatian' },
                { code: 'hu', name: 'Hungarian' },
                { code: 'lt', name: 'Lithuanian' },
                { code: 'lv', name: 'Latvian' },
                { code: 'ms', name: 'Malay' },
                { code: 'no', name: 'Norwegian' },
                { code: 'ro', name: 'Romanian' },
                { code: 'sk', name: 'Slovak' },
                { code: 'sl', name: 'Slovenian' },
                { code: 'sr', name: 'Serbian' },
                { code: 'sw', name: 'Swahili' },
                { code: 'ta', name: 'Tamil' },
                { code: 'te', name: 'Telugu' },
                { code: 'ur', name: 'Urdu' },
            ];

            const overlay = document.createElement('div');
            overlay.className = 'modal active';
            overlay.style.zIndex = '10003';
            overlay.innerHTML = `
                <div class="modal-content" style="max-width:360px;padding:24px;">
                    <h3 style="margin:0 0 6px;font-size:1.1em;color:var(--text-bright);">Select Your Language</h3>
                    <p style="margin:0 0 16px;font-size:0.85em;color:var(--text-dim);">Choose the language you'd like messages translated into. This will be saved to your settings.</p>
                    <div class="translate-lang-grid" style="display:grid;grid-template-columns:1fr 1fr;gap:6px;max-height:320px;overflow-y:auto;padding-right:4px;">
                        ${languages.map(l => `<button class="translate-lang-option" data-lang="${l.code}" style="
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
                    translationEl.innerHTML = `<span class="translation-icon">🌐</span> <span class="translation-error">Already in ${this.escapeHtml(targetLang)} (nothing to translate)</span>`;
                } else {
                    const langLabel = detectedLang !== 'auto' && detectedLang !== targetLang
                        ? `<span class="translation-lang">${detectedLang} → ${targetLang}</span>` : '';
                    translationEl.innerHTML = `<span class="translation-icon">🌐</span> ${this.escapeHtml(translatedText).replace(/\n/g, '<br>')} ${langLabel}`;
                }
            } else if (isNoop) {
                this.displaySystemMessage(`Nothing to translate (already in ${targetLang}).`);
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
                if (!this._isCloudflareHost) this._fallbackToLocal();
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

    // Set up the translate input button and dropdown in the message input area.
    setupTranslateInput() {
        const btn = document.getElementById('translateInputBtn');
        const dropdown = document.getElementById('translateInputDropdown');
        if (!btn || !dropdown) return;

        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            dropdown.classList.toggle('active');
        });

        dropdown.querySelectorAll('.translate-dropdown-item').forEach(item => {
            item.addEventListener('click', (e) => {
                e.stopPropagation();
                const lang = item.dataset.lang;
                dropdown.classList.remove('active');
                this.translateInputText(lang);
            });
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
