// message-format.js - Pure content->HTML formatter shared by the main thread

(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const RX_FORMAT_TRIGGERS = /[^\x20-\x7E\n]|[*_~`#>@:;/\\&<>"]/;
    const GEOHASH = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
    const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;' };

    function escapeHtml(text) {
        return String(text).replace(/[&<>"']/g, m => ESC[m]);
    }

    function proxied(url, base) {
        if (!base) return url;
        return `${base}?url=${encodeURIComponent(url)}`;
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

    function sanitizeGroupName(name) {
        return (name || '').replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40);
    }

    function format(content, ctx) {
        ctx = ctx || {};
        if (!RX_FORMAT_TRIGGERS.test(content)) {
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

        formatted = formatted.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
        formatted = formatted.replace(/(?<!\w)__(.+?)__(?!\w)/g, '<strong>$1</strong>');
        formatted = formatted.replace(/(?<![:/])\*([^*\s][^*]*)\*/g, '<em>$1</em>');
        formatted = formatted.replace(/(?<![:/\w])_([^_\s][^_]*)_(?!\w)/g, '<em>$1</em>');
        formatted = formatted.replace(/~~(.+?)~~/g, '<del>$1</del>');
        formatted = formatted.replace(/^&gt; (.+)$/gm, '<blockquote>$1</blockquote>');
        formatted = formatted.replace(/^### (.+)$/gm, '<h3>$1</h3>');
        formatted = formatted.replace(/^## (.+)$/gm, '<h2>$1</h2>');
        formatted = formatted.replace(/^# (.+)$/gm, '<h1>$1</h1>');

        const mediaPlaceholders = [];
        const buildFallbackAttr = (url) => {
            const mirrors = ctx.mediaFallbacks ? ctx.mediaFallbacks[url] : null;
            if (!mirrors || !mirrors.length) return '';
            const list = mirrors.map(m => proxied(m, ctx.proxyBase));
            return ` data-media-fallbacks="${escapeHtml(list.join('|'))}"`;
        };
        formatted = formatted.replace(
            /(https?:\/\/[^\s]+\.(mp4|webm|ogg|mov)(\?[^\s]*)?)/gi,
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
            /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp)(\?[^\s]*)?)/gi,
            (match, url) => {
                const proxiedUrl = proxied(url, ctx.proxyBase);
                const fbAttr = buildFallbackAttr(url);
                const idx = mediaPlaceholders.length;
                mediaPlaceholders.push({
                    kind: 'image',
                    html: `<img src="${proxiedUrl}" alt="Image" class="msg-img" data-action="expandImageFromData"${fbAttr} />`
                });
                return `﷒${idx}﷓`;
            }
        );

        formatted = formatted.replace(
            /https?:\/\/app\.nym\.bar\/#([egc]):([^\s<>"]+)/gi,
            (match, prefix, channelId) => {
                return `<span class="channel-link" data-action="channelLink" data-channel-ref="${prefix}:${escapeHtml(channelId)}">${match}</span>`;
            }
        );

        formatted = formatted.replace(
            /https?:\/\/[^\s<>"]*#gjoin=([A-Za-z0-9_-]+)/g,
            (match, token) => {
                const invite = parseGroupInvite(token);
                if (!invite) return match;
                const name = escapeHtml(sanitizeGroupName(invite.n || '') || 'group');
                const groupSvg = `<svg class="inline-group-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
                return `<span class="channel-link group-invite-chip" data-action="joinGroupFromInvite" data-invite="${escapeHtml(token)}">${groupSvg}Join ${name}</span>`;
            }
        );

        formatted = formatted.replace(
            /(https?:\/\/[^\s]+)(?![^<]*>)(?!__)/g,
            '<a href="$1" target="_blank" rel="noopener">$1</a>'
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

        formatted = formatted.replace(
            /(?:(@[^@#\n]*?(?<!\s)#[0-9a-f]{4}\b)|(@[^@\s][^@\s]*)|(^|\s)(#[a-z0-9_-]+)(?=\s|$|[.,!?]))(?![^<]*>)/gi,
            (match, mentionWithSuffix, simpleMention, whitespace, channel) => {
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

        formatted = formatted.replace(/:([a-zA-Z0-9_]+):/g, (match, code) => {
            const emoji = ctx.emojiMap ? ctx.emojiMap[code.toLowerCase()] : null;
            if (emoji) return emoji;
            if (ctx.customEmojis && ctx.customEmojis[code]) {
                return renderCustomEmojiImg(code, ctx) || match;
            }
            return match;
        });

        formatted = formatted.replace(/(^|\s):\)($|\s)/g, '$1😊$2');
        formatted = formatted.replace(/(^|\s):\(($|\s)/g, '$1😢$2');
        formatted = formatted.replace(/(^|\s):D($|\s)/g, '$1😃$2');
        formatted = formatted.replace(/(^|\s):P($|\s)/g, '$1😛$2');
        formatted = formatted.replace(/(^|\s);-?\)($|\s)/g, '$1😉$2');
        formatted = formatted.replace(/(^|\s):o($|\s)/gi, '$1😮$2');
        formatted = formatted.replace(/(^|\s):\|($|\s)/g, '$1😐$2');
        formatted = formatted.replace(/(^|\s)&lt;3($|\s)/g, '$1❤️$2');
        formatted = formatted.replace(/(^|\s)\/\\($|\s)/g, '$1⚠️$2');

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

        // Enrich @name#suffix mentions with the mentioned user's avatar (prefix)
        // and flair (suffix) as a final pass, so this HTML isn't touched by the
        // emoji/shortcode passes above. Both are resolved on the main thread into
        // ctx.mentionInfo (keyed by suffix), mirroring how quoted authors render.
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
                if (text) html += format(text, ctx);
            }
        }

        if (!html) return format(content, ctx);
        return html;
    }

    // Quoted-author names (at every quote depth, matching formatWithQuotes) whose
    // flair must be resolved on the main thread.
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

    // Suffixes (the 4 hex chars of @name#xxxx mentions) whose flair must be
    // resolved on the main thread, mirroring extractQuoteAuthors for quotes.
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

    G.NymFormat = { format, formatWithQuotes, extractQuoteAuthors, extractMentions };
})();
