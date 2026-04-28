// translate.js - Message and input translation (auto-detect, language selection)
// Methods are attached to NYM.prototype.

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

        // Strip HTML tags for translation (send plain text)
        let plainText = content.replace(/<[^>]+>/g, '').trim();
        if (!plainText) {
            this.displaySystemMessage('No text to translate.');
            return;
        }

        // Strip trailing timestamp (e.g. "12:34 PM", "3:05 AM", "23:59")
        plainText = plainText.replace(/\s*\d{1,2}:\d{2}\s*(AM|PM)?\s*$/i, '').trim();

        // Protect emoji from being stripped by the translation API
        const { text: shieldedText, emojis: savedEmojis } = this._shieldEmojis(plainText);

        // Protect @mentions from being mangled by the translation API
        const mentions = [];
        const mentionShielded = shieldedText.replace(/@[^\s@]+(?:#[0-9a-f]{4})?/gi, (match) => {
            const idx = mentions.length;
            mentions.push(match);
            return `MNT${idx}MNT`;
        });

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
            let translatedText, detectedLang;

            const base = this._getProxyBaseUrl();
            if (base) {
                try {
                    // Proxied path (CF-hosted): translate via our worker
                    const resp = await fetch(`${base}?action=translate`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ text: mentionShielded, source: 'auto', target: targetLang }),
                    });
                    const contentType = (resp.headers.get('content-type') || '').toLowerCase();
                    if (!contentType.includes('application/json')) {
                        throw new Error(`Proxy returned non-JSON response (${resp.status})`);
                    }
                    const data = await resp.json();
                    if (data.error) throw new Error(data.error);
                    translatedText = this._restoreMentions(this._restoreEmojis(data.translatedText, savedEmojis), mentions);
                    detectedLang = data.detectedLanguage || 'auto';
                } catch (proxyErr) {
                    // Proxy failed — fall back to direct translation
                    if (!this._isCloudflareHost) this._fallbackToLocal();
                    const result = await this._translateDirect(mentionShielded, targetLang);
                    translatedText = this._restoreMentions(this._restoreEmojis(result.translatedText, savedEmojis), mentions);
                    detectedLang = result.detectedLanguage || 'auto';
                }
            } else {
                // Direct path: call Google Translate directly
                const result = await this._translateDirect(mentionShielded, targetLang);
                translatedText = this._restoreMentions(this._restoreEmojis(result.translatedText, savedEmojis), mentions);
                detectedLang = result.detectedLanguage || 'auto';
            }

            if (msgEl) {
                let translationEl = msgEl.querySelector('.message-translation');
                if (!translationEl) {
                    translationEl = document.createElement('div');
                    translationEl.className = 'message-translation';
                    const contentEl = msgEl.querySelector('.message-content') || msgEl;
                    contentEl.after(translationEl);
                }
                const langLabel = detectedLang !== 'auto' && detectedLang !== targetLang
                    ? `<span class="translation-lang">${detectedLang} → ${targetLang}</span>` : '';
                translationEl.innerHTML = `<span class="translation-icon">🌐</span> ${this.escapeHtml(translatedText).replace(/\n/g, '<br>')} ${langLabel}`;
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

    _restoreMentions(text, mentions) {
        return text.replace(/MNT(\d+)MNT/g, (_, idx) => mentions[parseInt(idx)] || '');
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

        // Protect emoji from being stripped by the translation API
        const { text: shieldedText, emojis: savedEmojis } = this._shieldEmojis(text);

        const btn = document.getElementById('translateInputBtn');
        if (btn) btn.classList.add('translating');

        try {
            let translatedText;
            const base = this._getProxyBaseUrl();
            if (base) {
                try {
                    const resp = await fetch(`${base}?action=translate`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ text: shieldedText, source: 'auto', target: targetLang }),
                    });
                    const contentType = (resp.headers.get('content-type') || '').toLowerCase();
                    if (!contentType.includes('application/json')) {
                        throw new Error(`Proxy returned non-JSON response (${resp.status})`);
                    }
                    const data = await resp.json();
                    if (data.error) throw new Error(data.error);
                    translatedText = this._restoreEmojis(data.translatedText, savedEmojis);
                } catch (proxyErr) {
                    if (!this._isCloudflareHost) this._fallbackToLocal();
                    const result = await this._translateDirect(shieldedText, targetLang);
                    translatedText = this._restoreEmojis(result.translatedText, savedEmojis);
                }
            } else {
                const result = await this._translateDirect(shieldedText, targetLang);
                translatedText = this._restoreEmojis(result.translatedText, savedEmojis);
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
