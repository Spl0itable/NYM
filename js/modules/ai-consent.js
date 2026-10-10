(function () {
    'use strict';

    const KEY = 'nym_ai_consent';
    const TRANSLATE_KEY = 'nym_ai_translate_consent';
    const PRIVACY_URL = 'https://nymchat.app/privacy/';
    const BOT_PM_LOCAL = /^\s*\?(help|commands|balance|buy|clear|transfer|gift|model|anon|git|github)\b/i;

    const STRINGS = {
        title: 'Allow Nymbot to use AI services?',
        what: 'What is sent: to answer you, Nymbot sends what you ask it to AI services. That is your question or message, earlier messages in that Nymbot conversation, images and links you include and your nym. For a question in a channel it also sends the channel\'s recent messages from other people and the channel\'s approximate location. Allowing this also turns on AI translation, which sends text you choose to translate to our servers.',
        who: 'Who receives it: the Nymbot service run by 21 Million LLC, which processes it on our servers. If you pick a Pro model or an image or video generator, it also goes to that model\'s maker, such as OpenAI, Anthropic, Google, xAI, Moonshot AI, Alibaba or MiniMax.',
        later: 'Nothing is sent unless you allow it. You can change this at any time in Settings → Privacy & Security.',
        privacyLink: 'Privacy Policy',
        allow: 'Allow',
        deny: 'Don\'t Allow',
        offNotice: 'Nothing was sent. This message goes to Nymbot, so it needs Nymbot AI processing. Send it again and choose Allow, or turn it on in Settings → Privacy & Security.',
        translateTitle: 'Allow AI translation?',
        translateWhat: 'What is sent: only the text you choose to translate, such as a message, a poll or your draft, and the language to translate it into.',
        translateWho: 'Who receives it: the Nymchat service run by 21 Million LLC, which translates it with AI models on our servers and sends the translation back. A translation may be cached for up to a day so repeats are faster, and it is not used for anything else.',
        translateOff: 'Nothing was translated. AI translation is off. Translate again and choose Allow, or turn it on in Settings → Privacy & Security.',
    };

    function read(key) {
        try { return localStorage.getItem(key || KEY) || ''; } catch (_) { return ''; }
    }

    function render() {
        if (typeof document === 'undefined') return;
        const sel = document.getElementById('aiConsentToggle');
        if (sel) sel.checked = read(KEY) === 'allowed';
        const tsel = document.getElementById('aiTranslateToggle');
        if (tsel) tsel.checked = read(TRANSLATE_KEY) === 'allowed';
    }

    function write(allow, key) {
        const k = key || KEY;
        try {
            localStorage.setItem(k, allow ? 'allowed' : 'declined');
            if (allow && k === KEY && localStorage.getItem(TRANSLATE_KEY) == null) {
                localStorage.setItem(TRANSLATE_KEY, 'allowed');
            }
        } catch (_) { }
        render();
    }

    const KINDS = {
        nymbot: { key: KEY, title: 'title', paragraphs: ['what', 'who', 'later'] },
        translate: { key: TRANSLATE_KEY, title: 'translateTitle', paragraphs: ['translateWhat', 'translateWho', 'later'] },
    };

    Object.assign(NYM.prototype, {
        _aiText(text) { return typeof this.uiText === 'function' ? this.uiText(text) : text; },

        aiConsentAllowed(kind) { return read((KINDS[kind] || KINDS.nymbot).key) === 'allowed'; },

        aiConsentSet(allow, kind) { write(!!allow, (KINDS[kind] || KINDS.nymbot).key); },

        aiConsentNeededForPM(content, pubkey) {
            return typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(pubkey)
                && !BOT_PM_LOCAL.test(String(content || ''));
        },

        aiConsentNeededForChannel(rawInput, botQuote) {
            const text = String(rawInput || '');
            if (text.startsWith('/')) return false;
            if (text.startsWith('?') || /@nymbot(?:#[a-f0-9]{4})?(?:\s|$)/i.test(text)) return true;
            return !!(botQuote && /^nymbot(?:#[a-f0-9]{4})?$/i.test(botQuote.author || ''));
        },

        async aiConsentEnsure(kind) {
            const k = KINDS[kind] ? kind : 'nymbot';
            const spec = KINDS[k];
            if (this.aiConsentAllowed(k)) return true;
            if (!this._aiConsentAsking) this._aiConsentAsking = {};
            if (!this._aiConsentAsking[k]) {
                const t = (s) => this._aiText(s);
                const message = spec.paragraphs.map((p) => t(STRINGS[p]))
                    .concat([t(STRINGS.privacyLink) + ': ' + PRIVACY_URL]).join('\n\n');
                const ask = typeof window.showAppConfirm === 'function'
                    ? window.showAppConfirm(message, {
                        title: t(STRINGS[spec.title]),
                        okLabel: t(STRINGS.allow),
                        cancelLabel: t(STRINGS.deny),
                    })
                    : Promise.resolve(false);
                this._aiConsentAsking[k] = Promise.resolve(ask).then((v) => {
                    if (v) return true;
                    const modal = document.getElementById('appDialogModal');
                    return modal && modal.classList.contains('active') ? null : false;
                }, () => false);
            }
            const pending = this._aiConsentAsking[k];
            let answer = false;
            try { answer = await pending; } finally {
                if (this._aiConsentAsking[k] === pending) this._aiConsentAsking[k] = null;
            }
            if (answer === null) return false;
            if (!this.aiConsentAllowed(k)) write(answer, spec.key);
            return answer;
        },

        aiConsentBlocked(kind) {
            if (typeof this.displaySystemMessage === 'function') {
                this.displaySystemMessage(this._aiText(kind === 'translate' ? STRINGS.translateOff : STRINGS.offNotice));
            }
        },
    });

    if (typeof window !== 'undefined') {
        window.NymAiConsentStrings = STRINGS;
        if (window.NYM_ACTIONS) {
            Object.assign(window.NYM_ACTIONS, {
                onAiConsentChange: function (_e, t) { write(!!(t && t.checked), KEY); },
                onAiTranslateChange: function (_e, t) { write(!!(t && t.checked), TRANSLATE_KEY); },
            });
        }
        if (typeof document !== 'undefined') {
            if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', render);
            else render();
            window.addEventListener('storage', (e) => { if (e.key === KEY || e.key === TRANSLATE_KEY) render(); });
        }
    }
})();
