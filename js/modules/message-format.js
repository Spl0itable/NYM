(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const RX_FORMAT_TRIGGERS = /[^\x20-\x7E\n]|[*_~`#>@:;/\\&<>"|]/;
    const RX_BLOCK_TRIGGER = /^[ \t]*(?:[-*]|\d{1,9}\.) \S/m;
    const SPOILER_MASK = '\u2592\u2592\u2592\u2592';
    const SPOILER_LABEL = 'Spoiler, tap to reveal';
    const RX_SPOILER = /\|\|([^\s|](?:[^\n]*?[^\s|])??)\|\|/g;
    const RX_TIMESTAMP_RAW = /<t:(-?\d{1,17})(?::([tTdDfFR]))?>/g;
    const RX_TIMESTAMP_ESC = /&lt;t:(-?\d{1,17})(?::([tTdDfFR]))?&gt;/g;
    const MAX_TS_SECONDS = 8640000000000;
    const RX_LIST_LINE = /^(\t| {2,})?([-*]|\d{1,9}\.) (\S.*)$/;
    const RX_SUBTEXT_LINE = /^-# (\S.*)$/;
    const BLOCK_TAGS = { ul: 1, ol: 1, li: 1, div: 1 };
    const BLOCK_START_LB = '(?<=<li>|<h[1-3]>|<\\/h[1-3]>|<div class="nm-subtext">|<\\/div>|<\\/ul>|<\\/ol>|<blockquote>|<\\/blockquote>)';
    const BLOCK_END_LA = '(?=<\\/li>|<\\/h[1-3]>|<h[1-3]>|<\\/div>|<div class="nm-subtext">|<ul>|<ol[ >]|<\\/blockquote>|<blockquote>)';
    const SMILEYS = {
        ':)': '\u{1F60A}', ':-)': '\u{1F60A}', ':(': '\u{1F622}', ':-(': '\u{1F622}',
        ':D': '\u{1F603}', ':P': '\u{1F61B}', ';)': '\u{1F609}', ';-)': '\u{1F609}',
        ':o': '\u{1F62E}', ':|': '\u{1F610}', '&lt;3': '\u2764\uFE0F', '/\\': '\u26A0\uFE0F'
    };
    const RX_SMILEY = new RegExp(`(<[^>]+>)|(^|\\s|${BLOCK_START_LB})(:-?\\)|:-?\\(|:D|:P|;-?\\)|:o|:O|:\\||&lt;3|\\/\\\\)(?=$|\\s|${BLOCK_END_LA})`, 'g');
    const GEOHASH = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
    const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;' };

    function escapeHtml(text) {
        return String(text).replace(/[&<>"']/g, m => ESC[m]);
    }

    function safeUrl(url) {
        if (typeof url !== 'string') return '';
        const trimmed = url.replace(/[\u0000-\u0020\u00a0\u1680\u2000-\u200d\u2028\u2029\u202f\u205f\u3000\ufeff]/g, '');
        return /^https?:\/\//i.test(trimmed) ? url : '';
    }

    function proxied(url, base) {
        if (!base) return url;
        return `${base}?url=${encodeURIComponent(url)}`;
    }

    const RX_MEDIA_NOTE = /((?:View-once (?:photo|video|voice message): )?)(https?:\/\/[^\s#<>"﷐-﷕]+|nymlocal:[A-Za-z0-9]{1,40})#(nym:[A-Za-z0-9=;:.\/_+-]+)/g;
    const NOTE_PLAY_SVG = '<svg class="nym-ico-play" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M8 5v14l11-7z" fill="currentColor"/></svg>'
        + '<svg class="nym-ico-pause" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M7 5h4v14H7zM13 5h4v14h-4z" fill="currentColor"/></svg>';
    const ONCE_ICONS = {
        photo: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>',
        video: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="6" width="14" height="12" rx="2"/><path d="m22 8-6 4 6 4z"/></svg>',
        voice: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v4"/></svg>',
    };

    function noteSrc(note, ctx) {
        return note.local ? '' : proxied(note.url, ctx.proxyBase);
    }

    function noteCommonAttrs(note, ctx) {
        const localId = note.local ? note.url.slice('nymlocal:'.length) : '';
        return ` data-src="${escapeHtml(noteSrc(note, ctx))}" data-raw="${escapeHtml(note.local ? '' : note.url)}"`
            + ` data-local-id="${escapeHtml(localId)}" data-mime="${escapeHtml(note.mime)}"`
            + ` data-dur="${note.duration == null ? '' : escapeHtml(String(note.duration))}"`;
    }

    function renderMediaNote(note, ctx) {
        const N = G.NymMediaNotes;
        if (note.once) {
            const kind = note.kind === 'round' ? 'video' : note.kind;
            return `<span class="nym-once" data-nym-note="once" data-kind="${kind}" data-once-id="${escapeHtml(note.onceId)}"`
                + ` data-key="${escapeHtml(note.key)}" data-nonce="${escapeHtml(note.nonce)}"${noteCommonAttrs(note, ctx)}>`
                + `<button type="button" class="nym-once-open" data-action="nymOnceOpen">`
                + `<span class="nym-once-icon">${ONCE_ICONS[kind] || ONCE_ICONS.photo}</span>`
                + `<span class="nym-once-text"><span class="nym-once-label">${escapeHtml(N.onceLabel(kind))}</span>`
                + `<span class="nym-once-state">Tap to view</span></span></button></span>`;
        }
        if (note.kind === 'photo' || note.kind === 'video') {
            const tag = note.kind === 'video'
                ? `<video class="message-video nym-local-media" controls playsinline preload="metadata"></video>`
                : `<img class="msg-img nym-local-media" alt="Image" decoding="async">`;
            return `<span class="nym-local" data-nym-note="${note.kind}"${noteCommonAttrs(note, ctx)}>${tag}</span>`;
        }
        if (note.kind === 'round') {
            const src = noteSrc(note, ctx);
            const clock = note.duration == null ? '' : N.formatClock(note.duration);
            return `<span class="nym-round" data-nym-note="round"${noteCommonAttrs(note, ctx)}>`
                + `<video class="nym-round-video" muted loop playsinline autoplay preload="metadata"${src ? ` src="${escapeHtml(src)}"` : ''}></video>`
                + `<span class="nym-round-badge" aria-hidden="true">${clock}</span>`
                + `<button type="button" class="nym-round-hit" data-action="nymRoundToggle" aria-label="Play video note with sound"></button></span>`;
        }
        const levels = note.waveform && note.waveform.length ? note.waveform : new Array(N.LIMITS.waveformBars).fill(8);
        const bars = levels.map((v) => `<span class="nym-voice-bar h${Math.round(Math.max(0, Math.min(63, v)) / 63 * 15)}"></span>`).join('');
        const clock = note.duration == null ? '0:00' : N.formatClock(note.duration);
        return `<span class="nym-voice" data-nym-note="voice"${noteCommonAttrs(note, ctx)}>`
            + `<span class="nym-voice-row"><button type="button" class="nym-voice-play" data-action="nymVoiceToggle" aria-label="Play voice message">${NOTE_PLAY_SVG}</button>`
            + `<span class="nym-voice-wave" data-action="nymVoiceSeek" role="slider" tabindex="0" aria-label="Seek" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">${bars}</span>`
            + `<span class="nym-voice-time">${clock}</span>`
            + `<button type="button" class="nym-voice-speed" data-action="nymVoiceSpeed" aria-label="Playback speed">1×</button></span>`
            + `<span class="nym-voice-foot"><button type="button" class="nym-voice-tx" data-action="nymVoiceTranscribe">Transcribe</button>`
            + `<span class="nym-voice-transcript" hidden></span></span></span>`;
    }

    function proxiedEmoji(url, base) {
        if (!base) return url;
        return `${base}?emoji=1&url=${encodeURIComponent(url)}`;
    }

    function renderCustomEmojiImg(code, ctx) {
        const url = ctx.customEmojis ? ctx.customEmojis[code] : null;
        if (!url) return null;
        const safeUrl = escapeHtml(proxiedEmoji(url, ctx.proxyBase));
        const safeCode = escapeHtml(code);
        return `<img class="custom-emoji" src="${safeUrl}" alt=":${safeCode}:" title=":${safeCode}:" data-emoji-code="${safeCode}" width="30" height="30" decoding="async" loading="lazy" draggable="false">`;
    }

    function geohashValid(str) {
        return GEOHASH.test(String(str).toLowerCase());
    }

    function geohashLocation(geohash) {
        try {
            const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
            let latLo = -90, latHi = 90, lngLo = -180, lngHi = 180, isEven = true;
            for (let i = 0; i < geohash.length; i++) {
                const cd = BASE32.indexOf(geohash[i].toLowerCase());
                if (cd === -1) return '';
                for (let j = 4; j >= 0; j--) {
                    const bit = (cd & (1 << j)) ? 1 : 0;
                    if (isEven) {
                        const mid = (lngLo + lngHi) / 2;
                        if (bit) lngLo = mid; else lngHi = mid;
                    } else {
                        const mid = (latLo + latHi) / 2;
                        if (bit) latLo = mid; else latHi = mid;
                    }
                    isEven = !isEven;
                }
            }
            const lat = (latLo + latHi) / 2, lng = (lngLo + lngHi) / 2;
            const latStr = Math.abs(lat).toFixed(2) + '°' + (lat >= 0 ? 'N' : 'S');
            const lngStr = Math.abs(lng).toFixed(2) + '°' + (lng >= 0 ? 'E' : 'W');
            return `${latStr}, ${lngStr}`;
        } catch (_) { return ''; }
    }

    function b64uDecode(token) {
        let b64 = token.replace(/-/g, '+').replace(/_/g, '/');
        while (b64.length % 4) b64 += '=';
        const bin = atob(b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return new TextDecoder().decode(bytes);
    }

    function parseGroupInvite(token) {
        if (!/^[A-Za-z0-9_-]+$/.test(token)) return null;
        try {
            const obj = JSON.parse(b64uDecode(token));
            if (!obj || obj.v !== 1) return null;
            if (!/^([0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i.test(obj.g || '')) return null;
            if (!/^[0-9a-f]{64}$/i.test(obj.a || '')) return null;
            obj.e = parseInt(obj.e, 10) || 0;
            return obj;
        } catch (_) { return null; }
    }

    function parseCallLinkToken(token) {
        if (!/^[A-Za-z0-9_-]+$/.test(token)) return null;
        try {
            const obj = JSON.parse(b64uDecode(token));
            if (!obj || obj.v !== 1) return null;
            if (!/^[0-9a-f]{16}$/.test(obj.i || '') || !/^[0-9a-f]{64}$/.test(obj.h || '') || !/^[0-9a-f]{32}$/.test(obj.s || '')) return null;
            if (obj.k !== 'audio' && obj.k !== 'video') return null;
            return obj;
        } catch (_) { return null; }
    }

    // NIP-19 entities and bare 64-hex ids at a word boundary outside URLs.
    const NOSTR_BECH32 = /(?<![\w/:.#=&?"'-])(nostr:)?((?:nevent|naddr|nprofile|note|npub)1[023456789acdefghjklmnpqrstuvwxyz]{20,})(?![\w-])(?![^<]*>)/gi;
    const NOSTR_HEX_ID = /(?<![\w/:.#=&?"'-])([0-9a-f]{64})(?![\w-])(?![^<]*>)/gi;

    // NIP-19 entities trip none of RX_FORMAT_TRIGGERS, so the fast path must check them separately.
    const NOSTR_TRIGGER = /(?:nevent|naddr|nprofile|note|npub)1[023456789acdefghjklmnpqrstuvwxyz]{20,}|[0-9a-f]{64}/i;

    function shortenNostrRef(token) {
        return token.length > 20 ? token.slice(0, 12) + '…' + token.slice(-6) : token;
    }

    function sanitizeGroupName(name) {
        return (name || '').replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40);
    }

    function tsValid(raw) {
        if (!/^-?\d{1,17}$/.test(String(raw))) return false;
        const n = Number(raw);
        return Number.isSafeInteger(n) && Math.abs(n) <= MAX_TS_SECONDS;
    }

    function tsLocale(locale) {
        if (locale) {
            try { return Intl.DateTimeFormat.supportedLocalesOf([locale]).length ? locale : undefined; }
            catch (_) { return undefined; }
        }
        if (G.nym && typeof G.nym.getUiLanguage === 'function') {
            try {
                const lang = G.nym.getUiLanguage();
                if (lang && Intl.DateTimeFormat.supportedLocalesOf([lang]).length) return lang;
            } catch (_) { }
        }
        return undefined;
    }

    function tsClean(s) {
        return String(s).replace(/[  ]/g, ' ');
    }

    function tsParts(date, opts, locale) {
        return tsClean(new Intl.DateTimeFormat(locale, opts).format(date));
    }

    const TS_REL_UNITS = [
        ['second', 1, 60],
        ['minute', 60, 60],
        ['hour', 3600, 24],
        ['day', 86400, 30],
        ['month', 2592000, 12],
        ['year', 31536000, Infinity]
    ];

    function tsRelative(seconds, locale, nowMs) {
        const roundHalfUp = (x) => Math.floor(x + 0.5);
        const diff = roundHalfUp((seconds * 1000 - (nowMs == null ? Date.now() : nowMs)) / 1000);
        let unit = 'second', value = diff;
        for (const [name, size, limit] of TS_REL_UNITS) {
            const v = roundHalfUp(diff / size);
            unit = name;
            value = v;
            if (Math.abs(v) < limit) break;
        }
        try {
            return tsClean(new Intl.RelativeTimeFormat(locale, { numeric: 'always' }).format(value, unit));
        } catch (_) {
            return tsClean(new Intl.RelativeTimeFormat('en', { numeric: 'always' }).format(value, unit));
        }
    }

    function formatTimestamp(seconds, style, locale, nowMs) {
        const loc = tsLocale(locale);
        const date = new Date(Number(seconds) * 1000);
        const time = (sec) => tsParts(date, sec
            ? { hour: 'numeric', minute: '2-digit', second: '2-digit' }
            : { hour: 'numeric', minute: '2-digit' }, loc);
        const longDate = (weekday) => tsParts(date, weekday
            ? { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' }
            : { year: 'numeric', month: 'long', day: 'numeric' }, loc);
        switch (style) {
            case 't': return time(false);
            case 'T': return time(true);
            case 'd': return tsParts(date, { year: 'numeric', month: 'numeric', day: 'numeric' }, loc);
            case 'D': return longDate(false);
            case 'F': return longDate(true) + ' ' + time(false);
            case 'R': return tsRelative(Number(seconds), loc, nowMs);
            default: return longDate(false) + ' ' + time(false);
        }
    }

    function renderTimestamp(seconds, style, ctx) {
        const st = style || 'f';
        const loc = tsLocale(ctx && ctx.locale);
        const text = formatTimestamp(seconds, st, loc, ctx && ctx.nowMs);
        const full = formatTimestamp(seconds, 'F', loc);
        const iso = new Date(Number(seconds) * 1000).toISOString();
        return `<time class="nm-ts" datetime="${escapeHtml(iso)}" data-ts="${escapeHtml(String(Number(seconds)))}" data-ts-style="${st}" data-ts-locale="${escapeHtml(loc || '')}" title="${escapeHtml(full)}" tabindex="0">${escapeHtml(text)}</time>`;
    }

    function tagsBalanced(html) {
        const stack = [];
        const rx = /<(\/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>/g;
        let m;
        while ((m = rx.exec(html)) !== null) {
            const name = m[2].toLowerCase();
            if (BLOCK_TAGS[name]) return false;
            if (!m[1]) stack.push(name);
            else if (stack.pop() !== name) return false;
        }
        return stack.length === 0;
    }

    function replaceBalanced(str, rx, build) {
        let out = '', last = 0, m;
        rx.lastIndex = 0;
        while ((m = rx.exec(str)) !== null) {
            if (!tagsBalanced(m[1])) {
                rx.lastIndex = m.index + 1;
                continue;
            }
            out += str.slice(last, m.index) + build(m[1]);
            last = m.index + m[0].length;
            rx.lastIndex = last;
        }
        return out + str.slice(last);
    }

    function applyInlineMarkup(text, ctx) {
        const label = escapeHtml((ctx && ctx.spoilerLabel) || spoilerLabel());
        let s = replaceBalanced(text, RX_SPOILER, (inner) =>
            `<span class="spoiler" role="button" tabindex="0" aria-label="${label}">${inner}</span>`);
        s = replaceBalanced(s, /\*\*(.+?)\*\*/g, (inner) => `<strong>${inner}</strong>`);
        const under = ctx && ctx.commonMark ? 'strong' : 'u';
        s = replaceBalanced(s, /(?<!\w)__(.+?)__(?!\w)/g, (inner) => `<${under}>${inner}</${under}>`);
        s = replaceBalanced(s, /(?<![:/])\*([^*\s][^*]*)\*/g, (inner) => `<em>${inner}</em>`);
        s = replaceBalanced(s, /(?<![:/\w])_([^_\s][^_]*)_(?!\w)/g, (inner) => `<em>${inner}</em>`);
        s = replaceBalanced(s, /~~(.+?)~~/g, (inner) => `<del>${inner}</del>`);
        return s;
    }

    function spoilerLabel() {
        if (G.nym && typeof G.nym.uiText === 'function') {
            try { return G.nym.uiText(SPOILER_LABEL) || SPOILER_LABEL; } catch (_) { }
        }
        return SPOILER_LABEL;
    }

    function renderListSeq(nodes) {
        let html = '';
        let i = 0;
        while (i < nodes.length) {
            const head = nodes[i].item;
            const tag = head.ordered ? 'ol' : 'ul';
            html += head.ordered && head.num !== 1 ? `<ol start="${head.num}">` : `<${tag}>`;
            while (i < nodes.length && nodes[i].item.ordered === head.ordered) {
                const node = nodes[i++];
                html += '<li>' + node.item.text + (node.children.length ? renderListSeq(node.children) : '') + '</li>';
            }
            html += `</${tag}>`;
        }
        return html;
    }

    function renderList(items) {
        const top = [];
        for (const item of items) {
            if (item.level === 1 && top.length) top[top.length - 1].children.push({ item, children: [] });
            else top.push({ item, children: [] });
        }
        return renderListSeq(top);
    }

    function applyBlocks(text, inQuote) {
        const lines = text.split('\n');
        const segs = [];
        let list = null;
        const flushList = () => {
            if (!list) return;
            segs.push({ html: renderList(list), block: true });
            list = null;
        };
        for (const line of lines) {
            const sub = inQuote ? null : RX_SUBTEXT_LINE.exec(line);
            if (sub) {
                flushList();
                segs.push({ html: `<div class="nm-subtext">${sub[1]}</div>`, block: true });
                continue;
            }
            const li = RX_LIST_LINE.exec(line);
            if (li) {
                const marker = li[2];
                const ordered = marker !== '-' && marker !== '*';
                let level = li[1] ? 1 : 0;
                if (!list) { list = []; level = 0; }
                list.push({ level, ordered, num: ordered ? parseInt(marker, 10) : 0, text: li[3] });
                continue;
            }
            flushList();
            segs.push({ html: line, block: false });
        }
        flushList();
        let out = '';
        for (let i = 0; i < segs.length; i++) {
            if (i > 0 && !segs[i - 1].block) out += '\n';
            out += segs[i].html;
        }
        return out;
    }

    function mapOutsideCode(text, fn) {
        const rx = /```[\s\S]*?```|```[\s\S]*$|`[^`\n]+?`/g;
        let out = '', last = 0, m;
        while ((m = rx.exec(text)) !== null) {
            out += fn(text.slice(last, m.index)) + m[0];
            last = m.index + m[0].length;
        }
        return out + fn(text.slice(last));
    }

    function maskSpoilers(text) {
        if (typeof text !== 'string' || text.indexOf('||') === -1) return text;
        return mapOutsideCode(text, (part) => part.replace(RX_SPOILER, SPOILER_MASK));
    }

    function stripForPreview(text, opts) {
        if (typeof text !== 'string' || !text) return text;
        const locale = opts && opts.locale;
        return mapOutsideCode(text, (part) => part
            .replace(RX_SPOILER, SPOILER_MASK)
            .replace(RX_TIMESTAMP_RAW, (m, sec, style) => tsValid(sec) ? formatTimestamp(sec, style || 'f', locale) : m)
            .replace(/(^|\n)-# (?=\S)/g, '$1'));
    }

    function parseTimestampInput(input) {
        const parts = String(input || '').trim().split(/\s+/).filter(Boolean);
        if (!parts.length) return null;
        let style = 'f';
        if (parts.length > 1 && /^[tTdDfFR]$/.test(parts[parts.length - 1])) style = parts.pop();
        const raw = parts.join(' ');
        let seconds = null;
        if (/^-?\d{1,17}$/.test(raw)) {
            seconds = Number(raw);
        } else {
            const m = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?$/.exec(raw);
            if (!m) return null;
            const y = +m[1], mo = +m[2], d = +m[3], h = m[4] != null ? +m[4] : 0, mi = m[5] != null ? +m[5] : 0;
            if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
            const date = new Date(y, mo - 1, d, h, mi, 0, 0);
            if (date.getFullYear() !== y || date.getMonth() !== mo - 1 || date.getDate() !== d) return null;
            seconds = Math.floor(date.getTime() / 1000);
        }
        if (!tsValid(String(seconds))) return null;
        return { seconds, style, tag: `<t:${seconds}:${style}>` };
    }

    function revealSpoiler(el) {
        if (!el || !el.classList || !el.classList.contains('spoiler')) return false;
        if (el.classList.contains('spoiler-revealed')) return false;
        el.classList.add('spoiler-revealed');
        el.removeAttribute('role');
        el.removeAttribute('tabindex');
        el.removeAttribute('aria-label');
        return true;
    }

    function refreshSpoilerLabels(root) {
        if (!root || typeof root.querySelectorAll !== 'function') return 0;
        const label = spoilerLabel();
        let n = 0;
        root.querySelectorAll('.spoiler:not(.spoiler-revealed)').forEach((el) => {
            if (el.getAttribute('aria-label') !== label) { el.setAttribute('aria-label', label); n++; }
        });
        return n;
    }

    function refreshComposerTimestamps(root, opts) {
        if (!root || typeof root.querySelectorAll !== 'function') return 0;
        let n = 0;
        root.querySelectorAll('.rich-md-timestamp').forEach((el) => {
            const mark = el.querySelector('[data-mark]');
            const m = mark ? /^<t:(-?\d{1,17})(?::([tTdDfFR]))?>$/.exec(mark.dataset.mark || '') : null;
            if (!m || !tsValid(m[1])) return;
            const label = formatTimestamp(m[1], m[2] || 'f', opts && opts.locale, opts && opts.nowMs);
            if (el.dataset.label !== label) { el.dataset.label = label; n++; }
        });
        return n;
    }

    function refreshTimestamps(root, opts) {
        if (!root || typeof root.querySelectorAll !== 'function') return 0;
        const locale = tsLocale(opts && opts.locale);
        const want = locale || '';
        let n = 0;
        root.querySelectorAll('time.nm-ts').forEach((el) => {
            const style = el.getAttribute('data-ts-style') || 'f';
            const stale = (el.getAttribute('data-ts-locale') || '') !== want;
            if (style !== 'R' && !stale) return;
            const sec = el.getAttribute('data-ts');
            if (!tsValid(sec)) return;
            const text = formatTimestamp(sec, style, locale, opts && opts.nowMs);
            if (el.textContent !== text) { el.textContent = text; n++; }
            if (stale) {
                el.setAttribute('data-ts-locale', want);
                el.setAttribute('title', formatTimestamp(sec, 'F', locale));
            }
        });
        return n;
    }

    function format(content, ctx, inQuote) {
        ctx = ctx || {};
        if (!RX_FORMAT_TRIGGERS.test(content) && !NOSTR_TRIGGER.test(content) && !RX_BLOCK_TRIGGER.test(content)) {
            return content.indexOf('\n') === -1 ? content : content.replace(/\n/g, '<br>');
        }

        let formatted = content;
        formatted = formatted.replace(/@([^@#\s]+)#([0-9a-f]{4})#\2\b/gi, '@$1#$2');

        formatted = formatted
            .replace(/&(?![a-z]+;|#[0-9]+;|#x[0-9a-f]+;)/gi, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');

        const HL = G.NymHighlight;
        const codePlaceholders = [];
        const splitCodeLang = (body) => {
            const m = body.match(/^[ \t]*([A-Za-z0-9_+#.-]{1,20})[ \t]*\r?\n/);
            return m ? { lang: m[1], body: body.slice(m[0].length) } : { lang: null, body: body };
        };
        const pushCodeBlock = (code) => {
            const { lang, body } = splitCodeLang(code);
            const trimmedCode = body.replace(/^\s*\n/, '').replace(/\s+$/, '');
            const rawCode = trimmedCode
                .replace(/&lt;/g, '<')
                .replace(/&gt;/g, '>')
                .replace(/&quot;/g, '"')
                .replace(/&amp;/g, '&');
            const normLang = HL ? HL.normalize(lang) : null;
            const hc = ctx.highlightCode
                ? ctx.highlightCode(rawCode, normLang, trimmedCode)
                : { codeHtml: trimmedCode, hlAttr: '' };
            const langClass = normLang ? ` class="language-${normLang}"` : '';
            const langLabel = normLang ? `<span class="code-lang-label">${normLang}</span>` : '';
            const encodedRaw = btoa(unescape(encodeURIComponent(rawCode)));
            const idx = codePlaceholders.length;
            codePlaceholders.push(`<div class="code-block-wrapper">${langLabel}<pre><code${langClass}${hc.hlAttr}>${hc.codeHtml}</code></pre><button class="code-copy-btn" data-code="${encodedRaw}" data-action="codeBlockCopy">Copy</button></div>`);
            return `﷐${idx}﷑`;
        };
        formatted = formatted.replace(/```([\s\S]*?)```/g, (match, code) => pushCodeBlock(code));
        formatted = formatted.replace(/```([\s\S]+)$/, (match, code) => pushCodeBlock(code));
        formatted = formatted.replace(/`([^`]+?)`/g, (match, code) => {
            const idx = codePlaceholders.length;
            codePlaceholders.push(`<code>${code}</code>`);
            return `﷐${idx}﷑`;
        });

        if (formatted.indexOf('#nym:') !== -1 && G.NymMediaNotes) {
            formatted = formatted.replace(RX_MEDIA_NOTE, (match, prefix, base, frag) => {
                const note = G.NymMediaNotes.parseMediaUrl(base + '#' + frag);
                if (!note) return match;
                const idx = codePlaceholders.length;
                codePlaceholders.push(renderMediaNote(note, ctx));
                return `﷐${idx}﷑`;
            });
        }

        formatted = formatted.replace(RX_TIMESTAMP_ESC, (match, sec, style) => {
            if (!tsValid(sec)) return match;
            const idx = codePlaceholders.length;
            codePlaceholders.push(renderTimestamp(sec, style, ctx));
            return `\uFDD0${idx}\uFDD1`;
        });

        formatted = applyBlocks(formatted, !!inQuote);
        formatted = applyInlineMarkup(formatted, ctx);
        formatted = formatted.replace(/^&gt; (.+)$/gm, '<blockquote>$1</blockquote>');
        formatted = formatted.replace(/^### (.+)$\n?/gm, '<h3>$1</h3>');
        formatted = formatted.replace(/^## (.+)$\n?/gm, '<h2>$1</h2>');
        formatted = formatted.replace(/^# (.+)$\n?/gm, '<h1>$1</h1>');

        const mediaPlaceholders = [];
        const buildFallbackAttr = (url) => {
            const mirrors = ctx.mediaFallbacks ? ctx.mediaFallbacks[url] : null;
            if (!mirrors || !mirrors.length) return '';
            const list = mirrors.map(m => proxied(m, ctx.proxyBase));
            return ` data-media-fallbacks="${escapeHtml(list.join('|'))}"`;
        };
        // Audio uses its own placeholder so it stays out of image/video gallery grouping; .ogg/.webm stay video.
        const audioPlaceholders = [];
        formatted = formatted.replace(
            /(https?:\/\/[^\s<>"\uFDD0-\uFDD5]+\.(mp3|m4a|aac|wav|flac|opus|oga)(\?[^\s<>"\uFDD0-\uFDD5]*)?)/gi,
            (match, url, ext) => {
                const audioTypes = {
                    mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac',
                    wav: 'audio/wav', flac: 'audio/flac', opus: 'audio/ogg',
                    oga: 'audio/ogg'
                };
                const type = audioTypes[ext.toLowerCase()] || 'audio/mpeg';
                const proxiedUrl = proxied(url, ctx.proxyBase);
                // The proxied URL is same-origin, so `download` works instead of navigating away.
                let name = '';
                try {
                    name = decodeURIComponent((new URL(url).pathname.split('/').pop() || '')).slice(0, 60);
                } catch (e) { name = ''; }
                const idx = audioPlaceholders.length;
                audioPlaceholders.push(
                    `<span class="audio-container" data-action="stopPropagation">` +
                    `<audio controls preload="metadata" class="message-audio">` +
                    `<source src="${proxiedUrl}" type="${type}"></audio>` +
                    `<a class="audio-download" href="${proxiedUrl}" download="${escapeHtml(name)}" ` +
                    `target="_blank" rel="noopener noreferrer">Download${name ? ' ' + escapeHtml(name) : ''}</a>` +
                    `</span>`
                );
                return `\uFDD4${idx}\uFDD5`;
            }
        );

        formatted = formatted.replace(
            /(https?:\/\/[^\s<>"\uFDD0-\uFDD5]+\.(mp4|webm|ogg|mov)(\?[^\s<>"\uFDD0-\uFDD5]*)?)/gi,
            (match, url, ext) => {
                const mimeTypes = { mp4: 'video/mp4', webm: 'video/webm', ogg: 'video/ogg', mov: 'video/mp4' };
                const type = mimeTypes[ext.toLowerCase()] || 'video/mp4';
                const proxiedUrl = proxied(url, ctx.proxyBase);
                const fbAttr = buildFallbackAttr(url);
                const idx = mediaPlaceholders.length;
                mediaPlaceholders.push({
                    kind: 'video',
                    html: `<span class="video-container" data-action="stopPropagation"${fbAttr}><video controls playsinline webkit-playsinline preload="metadata" class="message-video"><source src="${proxiedUrl}" type="${type}"></video><button class="video-expand-btn" data-video-src="${proxiedUrl.replace(/"/g, '&quot;')}" data-action="expandVideoFromContainer">⛶</button></span>`
                });
                return `﷒${idx}﷓`;
            }
        );

        formatted = formatted.replace(
            /(https?:\/\/[^\s<>"\uFDD0-\uFDD5]+\.(jpg|jpeg|png|gif|webp)(\?[^\s<>"\uFDD0-\uFDD5]*)?)/gi,
            (match, url) => {
                const proxiedUrl = proxied(url, ctx.proxyBase);
                const fbAttr = buildFallbackAttr(url);
                const idx = mediaPlaceholders.length;
                mediaPlaceholders.push({
                    kind: 'image',
                    html: `<img src="${proxiedUrl}" alt="Image" class="msg-img" decoding="async" loading="lazy" data-action="expandImageFromData"${fbAttr} />`
                });
                return `﷒${idx}﷓`;
            }
        );

        formatted = formatted.replace(
            /https?:\/\/web\.nymchat\.app\/#([egc]):([^\s<>"\uFDD0-\uFDD5]+)/gi,
            (match, prefix, channelId) => {
                return `<span class="channel-link" data-action="channelLink" data-channel-ref="${prefix}:${escapeHtml(channelId)}">${match}</span>`;
            }
        );

        formatted = formatted.replace(
            /https?:\/\/[^\s<>"\uFDD0-\uFDD5]*#gjoin=([A-Za-z0-9_-]+)/g,
            (match, token) => {
                const invite = parseGroupInvite(token);
                if (!invite) return match;
                const name = escapeHtml(sanitizeGroupName(invite.n || '') || 'group');
                const groupSvg = `<svg class="inline-group-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
                return `<span class="channel-link group-invite-chip" data-action="joinGroupFromInvite" data-invite="${escapeHtml(token)}">${groupSvg}Join ${name}</span>`;
            }
        );

        formatted = formatted.replace(
            /https?:\/\/[^\s<>"\uFDD0-\uFDD5]*#call=([A-Za-z0-9_-]+)/g,
            (match, token) => {
                const link = parseCallLinkToken(token);
                if (!link) return match;
                const name = escapeHtml(String(link.n || '').replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40) || 'call');
                const callSvg = `<svg class="inline-group-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 14l4-4"/><path d="M11 6l1.5-1.5a3.5 3.5 0 0 1 5 5L16 11"/><path d="M13 18l-1.5 1.5a3.5 3.5 0 0 1-5-5L8 13"/></svg>`;
                return `<span class="channel-link call-link-chip" data-action="gtJoinCallLink" data-call-link="${escapeHtml(token)}">${callSvg}${link.k === 'video' ? 'Join video call' : 'Join voice call'}: ${name}</span>`;
            }
        );

        formatted = formatted.replace(
            NOSTR_BECH32,
            (match, scheme, token) => {
                const safeToken = escapeHtml(token);
                return `<span class="nostr-ref" data-action="openNostrRef" data-nostr-ref="${safeToken}" title="${safeToken}">${escapeHtml(shortenNostrRef(token))}</span>`;
            }
        );

        formatted = formatted.replace(
            NOSTR_HEX_ID,
            (match, id) => {
                const safeId = escapeHtml(id.toLowerCase());
                return `<span class="nostr-ref nostr-ref-raw" data-nostr-ref="${safeId}">${escapeHtml(id)}</span>`;
            }
        );

        formatted = formatted.replace(
            /(<[^>]+>)|(https?:\/\/[^\s<>"\uFDD0-\uFDD5]+)(?!__)/g,
            (match, tag, url) => {
                if (tag) return tag;
                const safe = safeUrl(url);
                return safe ? `<a href="${safe}" target="_blank" rel="noopener">${url}</a>` : match;
            }
        );

        formatted = formatted.replace(
            /(?:﷒(\d+)﷓)(?:[ \t\r\n]*﷒(\d+)﷓)+/g,
            (run) => {
                const indices = [];
                run.replace(/﷒(\d+)﷓/g, (_m, idx) => { indices.push(parseInt(idx, 10)); return ''; });
                const inner = indices.map(i => mediaPlaceholders[i].html).join('');
                const count = indices.length;
                const sizeClass = count === 2 ? 'gallery-2' : count === 3 ? 'gallery-3' : 'gallery-4plus';
                return `<div class="message-gallery ${sizeClass}" data-count="${count}">${inner}</div>`;
            }
        );
        formatted = formatted.replace(/﷒(\d+)﷓/g, (_m, idx) => mediaPlaceholders[parseInt(idx, 10)].html);
        formatted = formatted.replace(/\uFDD4(\d+)\uFDD5/g, (_m, idx) => audioPlaceholders[parseInt(idx, 10)]);

        formatted = formatted.replace(
            new RegExp(`(<[^>]+>)|(?:(@[^@#\\n<>]*?(?<!\\s)#[0-9a-f]{4}\\b)|(@[^@\\s<>"][^@\\s<>"]*)|(^|\\s|${BLOCK_START_LB})(#[a-z0-9_-]+)(?=\\s|$|[.,!?]|${BLOCK_END_LA}))(?![^<]*>)`, 'gi'),
            (match, tag, mentionWithSuffix, simpleMention, whitespace, channel) => {
                if (tag) return tag;
                if (mentionWithSuffix) {
                    const suffixIdx = mentionWithSuffix.search(/#[0-9a-f]{4}$/i);
                    const namePart = mentionWithSuffix.substring(0, suffixIdx);
                    const suffixPart = mentionWithSuffix.substring(suffixIdx);
                    return `<span class="nm-mention">${namePart}<span class="nym-suffix">${suffixPart}</span></span>`;
                } else if (simpleMention) {
                    return `<span class="nm-mention">${simpleMention}</span>`;
                } else if (channel) {
                    const channelName = channel.substring(1).trim().toLowerCase();
                    if (!channelName) return match;
                    const isGeohash = geohashValid(channelName);
                    const isActive = isGeohash
                        ? ctx.currentGeohash === channelName
                        : ctx.currentChannel === channelName;
                    const classes = ['channel-reference'];
                    if (isGeohash) classes.push('geohash-reference');
                    if (isActive) classes.push('active-channel');
                    let title;
                    if (isGeohash) {
                        const location = geohashLocation(channelName);
                        title = `Geohash channel`;
                        if (location) title += `: ${escapeHtml(location)}`;
                    } else {
                        title = `Channel: #${channelName}`;
                    }
                    return `${whitespace || ''}<span class="${classes.join(' ')} nm-underline" title="${title}" data-action="channelLink" data-channel-ref="g:${channelName}">${channel}</span>`;
                }
            }
        );

        formatted = formatted.replace(/(<[^>]+>)|:([a-zA-Z0-9_]+):/g, (match, tag, code) => {
            if (tag) return tag;
            const emoji = ctx.emojiMap ? ctx.emojiMap[code.toLowerCase()] : null;
            if (emoji) return emoji;
            if (ctx.customEmojis && ctx.customEmojis[code]) {
                return renderCustomEmojiImg(code, ctx) || match;
            }
            return match;
        });

        formatted = formatted.replace(RX_SMILEY, (match, tag, lead, sym) => tag ? tag : lead + SMILEYS[sym === ':O' ? ':o' : sym]);

        formatted = formatted.replace(
            /(?:<[^>]+>)|((?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)(?:[\u{E0020}-\u{E007E}]+\u{E007F})?)/gu,
            (match, emoji) => {
                if (!emoji) return match;
                return `<span class="emoji">${match}</span>`;
            }
        );

        formatted = formatted.replace(/﷐(\d+)﷑/g, (m, idx) => codePlaceholders[idx]);
        formatted = formatted.replace(/\n\[gc:([A-Za-z0-9+/=]+)\]/g, '<span class="game-token" aria-hidden="true">[gc:$1]</span>');
        formatted = formatted.replace(/\n/g, '<br>');

        // Runs last so the emoji/shortcode passes don't touch the mention avatar/flair HTML.
        if (ctx.mentionInfo) {
            formatted = formatted.replace(
                /(<span class="nm-mention">)(@[^<]*?<span class="nym-suffix">#([0-9a-f]{4})<\/span>)(<\/span>)/gi,
                (m, open, body, sfx, close) => {
                    const info = ctx.mentionInfo[sfx.toLowerCase()];
                    if (!info) return m;
                    return open + (info.avatar || '') + body + (info.flair || '') + close;
                }
            );
        }

        return formatted;
    }

    function cleanQuoteAuthor(rawAuthor) {
        let a = rawAuthor.replace(/<[^>]*>/g, '').replace(/&lt;/g, '').replace(/&gt;/g, '').trim();
        a = a.replace(/^([^#]+)#([0-9a-f]{4})#\2$/i, '$1#$2');
        return a;
    }

    function formatWithQuotes(content, ctx, depth) {
        ctx = ctx || {};
        depth = depth || 0;
        const MAX_QUOTE_DEPTH = 5;
        const lines = content.split('\n');
        let html = '';
        let i = 0;

        while (i < lines.length) {
            if (lines[i].startsWith('>')) {
                const quoteLines = [];
                while (i < lines.length && lines[i].startsWith('>')) {
                    quoteLines.push(lines[i].substring(1).trim());
                    i++;
                }
                if (depth >= MAX_QUOTE_DEPTH) continue;

                const firstLine = quoteLines[0];
                const authorMatch = firstLine.match(/^@([^:]+):\s*(.*)/);
                if (authorMatch) {
                    const messageParts = [];
                    if (authorMatch[2]) messageParts.push(authorMatch[2]);
                    for (let j = 1; j < quoteLines.length; j++) messageParts.push(quoteLines[j]);
                    const quotedMessage = messageParts.join('\n');

                    const cleanAuthor = cleanQuoteAuthor(authorMatch[1].trim());
                    const suffixMatch = cleanAuthor.match(/^(.+)(#[0-9a-f]{4})$/i);
                    const info = (ctx.quoteInfo && ctx.quoteInfo[cleanAuthor]) || null;
                    const avatarHtml = (info && info.avatar) || '';
                    const flairHtml = (info && info.flair) || '';
                    const displayAuthor = suffixMatch
                        ? `${avatarHtml}${escapeHtml(suffixMatch[1])}<span class="nym-suffix">${escapeHtml(suffixMatch[2])}</span>${flairHtml}`
                        : `${avatarHtml}${escapeHtml(cleanAuthor)}${flairHtml}`;

                    html += `<blockquote><span class="quote-author">${displayAuthor}:</span> ${formatWithQuotes(quotedMessage, ctx, depth + 1)}</blockquote>`;
                } else {
                    const quotedMessage = quoteLines.join('\n');
                    html += `<blockquote>${formatWithQuotes(quotedMessage, ctx, depth + 1)}</blockquote>`;
                }
            } else if (lines[i].trim() === '') {
                i++;
            } else {
                const textLines = [];
                while (i < lines.length && !lines[i].startsWith('>')) {
                    textLines.push(lines[i]);
                    i++;
                }
                const text = textLines.join('\n').replace(/^\n+/, '').replace(/\n+$/, '');
                if (text) html += format(text, ctx, depth > 0);
            }
        }

        if (!html) return format(content, ctx, depth > 0);
        return html;
    }

    function extractQuoteAuthors(content, depth, out, seen) {
        depth = depth || 0;
        if (depth === 0) { out = []; seen = new Set(); }
        if (depth >= 5 || !content || content.indexOf('>') === -1) return out;
        const lines = content.split('\n');
        let i = 0;
        while (i < lines.length) {
            if (lines[i].startsWith('>')) {
                const quoteLines = [];
                while (i < lines.length && lines[i].startsWith('>')) {
                    quoteLines.push(lines[i].substring(1).trim());
                    i++;
                }
                const m = quoteLines[0].match(/^@([^:]+):\s*(.*)/);
                if (m) {
                    const a = cleanQuoteAuthor(m[1].trim());
                    if (!seen.has(a)) { seen.add(a); out.push(a); }
                    const messageParts = [];
                    if (m[2]) messageParts.push(m[2]);
                    for (let j = 1; j < quoteLines.length; j++) messageParts.push(quoteLines[j]);
                    extractQuoteAuthors(messageParts.join('\n'), depth + 1, out, seen);
                } else {
                    extractQuoteAuthors(quoteLines.join('\n'), depth + 1, out, seen);
                }
            } else { i++; }
        }
        return out;
    }

    function extractMentions(content) {
        if (!content || content.indexOf('@') === -1) return [];
        const out = [];
        const seen = new Set();
        const rx = /@[^@#\n]*?(?<!\s)#([0-9a-f]{4})\b/gi;
        let m;
        while ((m = rx.exec(content)) !== null) {
            const sfx = m[1].toLowerCase();
            if (!seen.has(sfx)) { seen.add(sfx); out.push(sfx); }
        }
        return out;
    }

    G.NymFormat = {
        format, formatWithQuotes, extractQuoteAuthors, extractMentions, safeUrl,
        maskSpoilers, stripForPreview, formatTimestamp, parseTimestampInput, revealSpoiler, refreshTimestamps, refreshComposerTimestamps, refreshSpoilerLabels,
        SPOILER_MASK, SPOILER_LABEL
    };
})();
