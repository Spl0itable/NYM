// rich-compose.js - Optional WYSIWYG formatting toolbar for the composer

const NYM_FORMAT_TOOLS = [
    {
        id: 'bold', wrap: '**', title: 'Bold', key: 'b',
        html: '<span class="ft-glyph ft-bold">B</span>'
    },
    {
        id: 'italic', wrap: '*', title: 'Italic', key: 'i',
        html: '<span class="ft-glyph ft-italic">I</span>'
    },
    {
        id: 'strike', wrap: '~~', title: 'Strikethrough',
        html: '<span class="ft-glyph ft-strike">S</span>'
    },
    {
        id: 'code', wrap: '`', title: 'Inline code', key: 'e',
        html: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"></polyline><polyline points="8 6 2 12 8 18"></polyline></svg>'
    },
    {
        id: 'codeblock', block: '```', title: 'Code block',
        html: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"></rect><polyline points="9 15 7 12 9 9"></polyline><polyline points="15 9 17 12 15 15"></polyline></svg>'
    },
    {
        id: 'quote', prefix: '> ', title: 'Quote',
        html: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="5" x2="4" y2="19"></line><line x1="9" y1="7" x2="20" y2="7"></line><line x1="9" y1="12" x2="20" y2="12"></line><line x1="9" y1="17" x2="16" y2="17"></line></svg>'
    },
    {
        id: 'h1', prefix: '# ', exclusive: ['### ', '## ', '# '], title: 'Heading 1',
        html: '<span class="ft-glyph ft-heading">H<sub>1</sub></span>'
    },
    {
        id: 'h2', prefix: '## ', exclusive: ['### ', '## ', '# '], title: 'Heading 2',
        html: '<span class="ft-glyph ft-heading">H<sub>2</sub></span>'
    },
    {
        id: 'h3', prefix: '### ', exclusive: ['### ', '## ', '# '], title: 'Heading 3',
        html: '<span class="ft-glyph ft-heading">H<sub>3</sub></span>'
    }
];

const NYM_FORMAT_TOOLS_BY_ID = NYM_FORMAT_TOOLS.reduce((m, t) => { m[t.id] = t; return m; }, {});

// Image/video URLs the formatter turns into inline media. Kept in sync with the
// media regexes in message-format.js so the composer previews exactly the set of
// attachments the recipients will see rendered.
const NYM_COMPOSER_MEDIA_RX = /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?[^\s]*)?)/gi;
const NYM_COMPOSER_VIDEO_EXTS = ['mp4', 'webm', 'ogg', 'mov'];

Object.assign(NYM.prototype, {

    // formatting toolbar 
    // Build the toolbar once and wire the toggle button, tool clicks and the
    // keyboard shortcuts. Called from initialize().
    setupFormatToolbar() {
        const btn = document.getElementById('formatInputBtn');
        const toolbar = document.getElementById('formatToolbar');
        const input = document.getElementById('messageInput');
        if (!btn || !toolbar || !input) return;

        toolbar.innerHTML =
            NYM_FORMAT_TOOLS.map(t =>
                `<button type="button" class="format-tool" data-format-tool="${t.id}" title="${this.escapeHtml(t.title)}" aria-label="${this.escapeHtml(t.title)}">${t.html}</button>`
            ).join('') +
            '<span class="format-tool-sep" aria-hidden="true"></span>' +
            '<button type="button" class="format-tool format-preview-toggle" data-format-tool="preview" title="Preview formatting" aria-label="Preview formatting" aria-pressed="false">' +
            '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7z"></path><circle cx="12" cy="12" r="3"></circle></svg>' +
            '</button>';

        // mousedown (not click) so the caret/selection in the contenteditable is
        // still intact when the tool runs — clicking a button would otherwise
        // blur the input and collapse the selection first.
        toolbar.addEventListener('mousedown', (e) => {
            const tool = e.target.closest('.format-tool');
            if (!tool) return;
            e.preventDefault();
            e.stopPropagation();
            if (tool.dataset.formatTool === 'preview') this.toggleFormatPreview();
            else this.applyInputFormat(tool.dataset.formatTool);
        });
        toolbar.addEventListener('click', (e) => e.preventDefault());

        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            this.toggleFormatToolbar();
        });

        // Ctrl/Cmd shortcuts. contenteditable would otherwise apply the browser's
        // own execCommand bold/italic and inject foreign HTML into the input.
        input.addEventListener('keydown', (e) => {
            if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
            const key = (e.key || '').toLowerCase();
            if (key === 'x' && e.shiftKey) {
                e.preventDefault();
                this.applyInputFormat('strike');
                return;
            }
            if (e.shiftKey) return;
            const tool = NYM_FORMAT_TOOLS.find(t => t.key === key);
            if (!tool) return;
            e.preventDefault();
            this.applyInputFormat(tool.id);
        });

        this.formatToolbarOpen = false;
        try {
            this.formatToolbarOpen = localStorage.getItem('nym_format_toolbar') === 'true';
        } catch (_) { }
        try {
            this.formatPreviewOpen = localStorage.getItem('nym_format_preview') === 'true';
        } catch (_) { }
        this._applyFormatToolbarState();
    },

    toggleFormatToolbar() {
        this.formatToolbarOpen = !this.formatToolbarOpen;
        try { localStorage.setItem('nym_format_toolbar', String(this.formatToolbarOpen)); } catch (_) { }
        this._applyFormatToolbarState();
        if (this.formatToolbarOpen) {
            const input = document.getElementById('messageInput');
            if (input && !input.disabled) input.focus();
        }
    },

    toggleFormatPreview() {
        this.formatPreviewOpen = !this.formatPreviewOpen;
        try { localStorage.setItem('nym_format_preview', String(this.formatPreviewOpen)); } catch (_) { }
        this._applyFormatToolbarState();
    },

    _applyFormatToolbarState() {
        const btn = document.getElementById('formatInputBtn');
        const toolbar = document.getElementById('formatToolbar');
        const preview = document.getElementById('formatPreview');
        if (!btn || !toolbar) return;
        const open = !!this.formatToolbarOpen;
        toolbar.classList.toggle('nm-hidden', !open);
        btn.classList.toggle('active', open);
        btn.setAttribute('aria-pressed', open ? 'true' : 'false');
        const previewBtn = toolbar.querySelector('.format-preview-toggle');
        const previewOn = open && !!this.formatPreviewOpen;
        if (previewBtn) {
            previewBtn.classList.toggle('active', previewOn);
            previewBtn.setAttribute('aria-pressed', previewOn ? 'true' : 'false');
        }
        if (preview) preview.classList.toggle('nm-hidden', !previewOn);
        this.updateFormatPreview();
        this._refreshComposerOffsets();
    },

    // Render the composer draft through the very same formatter the message list
    // uses, so the preview is a faithful "what you get".
    updateFormatPreview() {
        const preview = document.getElementById('formatPreview');
        if (!preview) return;
        if (!this.formatToolbarOpen || !this.formatPreviewOpen) {
            if (preview.dataset.rendered) {
                preview.textContent = '';
                delete preview.dataset.rendered;
            }
            return;
        }
        const input = document.getElementById('messageInput');
        const text = input ? (input.value || '') : '';
        if (!text.trim()) {
            preview.innerHTML = '<span class="format-preview-empty">Nothing to preview yet</span>';
            preview.dataset.rendered = '1';
            return;
        }
        let html;
        try {
            html = this.formatMessage(text);
        } catch (_) {
            html = this.escapeHtml(text);
        }
        preview.innerHTML = html;
        preview.dataset.rendered = '1';
    },

    // Apply one toolbar tool to the current selection (or the word under the
    // caret when nothing is selected).
    applyInputFormat(id) {
        const tool = NYM_FORMAT_TOOLS_BY_ID[id];
        const input = document.getElementById('messageInput');
        if (!tool || !input || input.disabled) return;

        if (tool.wrap) this._wrapInputSelection(input, tool.wrap, tool.wrap);
        else if (tool.block) this._toggleInputCodeBlock(input, tool.block);
        else if (tool.prefix != null) this._toggleInputLinePrefix(input, tool.prefix, tool.exclusive);

        // Same signal a keystroke sends: keeps autocomplete, the send button,
        // auto-resize, the preview and the media strip in step.
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.focus();
    },

    // The [start, end) of the word under `pos`, or a zero-width range when the
    // caret sits on whitespace.
    _wordRangeAt(v, pos) {
        const isWord = (ch) => ch && !/\s/.test(ch);
        let start = pos, end = pos;
        while (start > 0 && isWord(v[start - 1])) start--;
        while (end < v.length && isWord(v[end])) end++;
        return { start, end };
    },

    // Toggle `before…after` around the selection. Recognises an existing wrap
    // both inside the selection ("**bold**" selected) and just outside it
    // ("bold" selected between the asterisks), so a second click always undoes.
    _wrapInputSelection(el, before, after) {
        const v = el.value;
        let s = el.selectionStart;
        let e = el.selectionEnd;
        if (s > e) { const t = s; s = e; e = t; }
        if (s === e) {
            const w = this._wordRangeAt(v, s);
            s = w.start;
            e = w.end;
        }
        // Never swallow the whitespace at the edges of a selection — markdown
        // delimiters must hug the text or the formatter won't match them.
        while (e > s && /\s/.test(v[e - 1])) e--;
        while (s < e && /\s/.test(v[s])) s++;

        const sel = v.slice(s, e);
        const bl = before.length, al = after.length;

        if (sel.length > bl + al - 1 && sel.startsWith(before) && sel.endsWith(after)) {
            const inner = sel.slice(bl, sel.length - al);
            el.value = v.slice(0, s) + inner + v.slice(e);
            el.setSelectionRange(s, s + inner.length);
            return;
        }
        if (s >= bl && v.slice(s - bl, s) === before && v.slice(e, e + al) === after) {
            el.value = v.slice(0, s - bl) + sel + v.slice(e + al);
            el.setSelectionRange(s - bl, s - bl + sel.length);
            return;
        }
        el.value = v.slice(0, s) + before + sel + after + v.slice(e);
        el.setSelectionRange(s + bl, s + bl + sel.length);
    },

    // The full-line span covering the selection, so line-oriented tools operate
    // on whole lines the way markdown does.
    _selectedLineSpan(v, s, e) {
        const start = v.lastIndexOf('\n', s - 1) + 1;
        let end = v.indexOf('\n', e);
        if (end === -1) end = v.length;
        return { start, end };
    },

    _toggleInputCodeBlock(el, fence) {
        const v = el.value;
        let s = el.selectionStart, e = el.selectionEnd;
        if (s > e) { const t = s; s = e; e = t; }
        const span = this._selectedLineSpan(v, s, e);
        const block = v.slice(span.start, span.end);
        const fenceRx = new RegExp('^' + fence + '[^\\n]*\\n?([\\s\\S]*?)\\n?' + fence + '$');
        const m = block.trim().match(fenceRx);
        if (m) {
            const inner = m[1];
            el.value = v.slice(0, span.start) + inner + v.slice(span.end);
            el.setSelectionRange(span.start, span.start + inner.length);
            return;
        }
        const wrapped = fence + '\n' + block + '\n' + fence;
        el.value = v.slice(0, span.start) + wrapped + v.slice(span.end);
        const innerStart = span.start + fence.length + 1;
        el.setSelectionRange(innerStart, innerStart + block.length);
    },

    // Add/remove `prefix` on every line the selection touches. When all touched
    // lines already carry it the click removes it, mirroring how the bold/italic
    // toggles behave.
    _toggleInputLinePrefix(el, prefix, exclusive) {
        const v = el.value;
        let s = el.selectionStart, e = el.selectionEnd;
        if (s > e) { const t = s; s = e; e = t; }
        const span = this._selectedLineSpan(v, s, e);
        const lines = v.slice(span.start, span.end).split('\n');
        const allHave = lines.every(l => l.startsWith(prefix));
        const stripRx = exclusive && exclusive.length
            ? new RegExp('^(?:' + exclusive.map(p => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')')
            : null;
        const out = lines.map(l => {
            if (allHave) return l.slice(prefix.length);
            return prefix + (stripRx ? l.replace(stripRx, '') : l);
        }).join('\n');
        el.value = v.slice(0, span.start) + out + v.slice(span.end);
        el.setSelectionRange(span.start, span.start + out.length);
    },

    // The formatting toggle shares an absolutely-positioned action row with the
    // translate button, which only exists while the draft has text. Reserve
    // exactly as much right padding inside the input as the visible buttons
    // occupy so text never runs underneath them.
    syncComposerInlineActions() {
        const input = document.getElementById('messageInput');
        const row = document.getElementById('inputInlineActions');
        if (!input || !row) return;
        const visible = Array.from(row.children)
            .filter(b => getComputedStyle(b).display !== 'none').length;
        // 8px gutter + 26px per button + 2px gaps + 4px breathing room.
        input.style.paddingRight = visible
            ? (8 + visible * 26 + (visible - 1) * 2 + 4) + 'px'
            : '';
    },

    // attachment previews 
    // Every media URL currently in the draft, with the offsets needed to remove
    // one precisely (the same URL can legitimately appear twice).
    _composerMediaMatches(value) {
        const out = [];
        if (!value) return out;
        NYM_COMPOSER_MEDIA_RX.lastIndex = 0;
        let m;
        while ((m = NYM_COMPOSER_MEDIA_RX.exec(value)) !== null) {
            const ext = (m[2] || '').toLowerCase();
            out.push({
                url: m[1],
                start: m.index,
                end: m.index + m[1].length,
                kind: NYM_COMPOSER_VIDEO_EXTS.includes(ext) ? 'video' : 'image'
            });
        }
        return out;
    },

    // Local object URLs for files this session uploaded, keyed by their hosted
    // URL. Previewing from the local blob avoids re-downloading what the user
    // just sent up, and shows a thumbnail instantly even if the Blossom server
    // is slow to serve the fresh blob back.
    _rememberComposerMediaBlob(url, file) {
        if (!url || !file) return;
        if (!this._composerMediaBlobs) this._composerMediaBlobs = new Map();
        if (this._composerMediaBlobs.has(url)) return;
        try {
            this._composerMediaBlobs.set(url, URL.createObjectURL(file));
        } catch (_) { }
    },

    // Drop object URLs for media no longer referenced by the draft. URLs still
    // "held" (uploaded but not yet appended to the draft) are exempt, otherwise
    // the blob would be revoked in the window between upload and append.
    _releaseComposerMediaBlobs(activeUrls) {
        if (!this._composerMediaBlobs || !this._composerMediaBlobs.size) return;
        const keep = new Set(activeUrls || []);
        for (const url of (this._composerMediaBlobHold || [])) keep.add(url);
        for (const [url, objectUrl] of Array.from(this._composerMediaBlobs.entries())) {
            if (keep.has(url)) continue;
            try { URL.revokeObjectURL(objectUrl); } catch (_) { }
            this._composerMediaBlobs.delete(url);
        }
    },

    // Placeholder thumbnails rendered from the local files while their upload is
    // still in flight, so the strip appears the instant a file is picked.
    setComposerUploadPreviews(files) {
        this.clearComposerUploadPreviews();
        this._composerUploadPreviews = (files || []).map(f => {
            let objectUrl = '';
            try { objectUrl = URL.createObjectURL(f); } catch (_) { }
            return {
                objectUrl,
                kind: (f.type || '').startsWith('video/') ? 'video' : 'image'
            };
        }).filter(p => p.objectUrl);
        this.updateComposerMediaPreviews();
    },

    // Retire the oldest in-flight placeholder once its upload resolves, handing
    // its object URL over to the hosted URL so the thumbnail never flickers.
    resolveComposerUploadPreview(url, file) {
        const pending = this._composerUploadPreviews || [];
        const done = pending.shift();
        if (done) {
            if (!this._composerMediaBlobs) this._composerMediaBlobs = new Map();
            if (url && !this._composerMediaBlobs.has(url)) this._composerMediaBlobs.set(url, done.objectUrl);
            else { try { URL.revokeObjectURL(done.objectUrl); } catch (_) { } }
        } else {
            this._rememberComposerMediaBlob(url, file);
        }
        if (url) {
            if (!this._composerMediaBlobHold) this._composerMediaBlobHold = new Set();
            this._composerMediaBlobHold.add(url);
        }
        this.updateComposerMediaPreviews();
    },

    clearComposerUploadPreviews() {
        for (const p of (this._composerUploadPreviews || [])) {
            try { URL.revokeObjectURL(p.objectUrl); } catch (_) { }
        }
        this._composerUploadPreviews = [];
        // The draft has been written by now (or the batch failed), so held blobs
        // are either referenced by it or genuinely orphaned.
        if (this._composerMediaBlobHold) this._composerMediaBlobHold.clear();
    },

    // Rebuild the thumbnail strip from the draft. Cheap to call on every
    // keystroke: it re-renders only when the set of attachments actually
    // changed, otherwise a keystroke would restart every <video> preload.
    updateComposerMediaPreviews() {
        const strip = document.getElementById('mediaPreviewStrip');
        const input = document.getElementById('messageInput');
        if (!strip || !input) return;

        const matches = this._composerMediaMatches(input.value || '');
        const pending = this._composerUploadPreviews || [];
        this._releaseComposerMediaBlobs(matches.map(m => m.url));

        if (!matches.length && !pending.length) {
            if (strip.dataset.sig !== '') {
                strip.textContent = '';
                strip.dataset.sig = '';
                strip.classList.add('nm-hidden');
                this._refreshComposerOffsets();
            }
            return;
        }

        const proxyBase = typeof this._getProxyBaseUrl === 'function' ? this._getProxyBaseUrl() : null;
        const src = (url) => {
            const local = this._composerMediaBlobs && this._composerMediaBlobs.get(url);
            if (local) return local;
            return proxyBase ? `${proxyBase}?url=${encodeURIComponent(url)}` : url;
        };

        const sig = matches.map(m => m.kind + ':' + m.url).join('|') + '#' + pending.map(p => p.objectUrl).join('|');
        if (strip.dataset.sig === sig) return;

        const thumbs = matches.map((m, i) => {
            const s = this.escapeHtml(src(m.url));
            const media = m.kind === 'video'
                ? `<video class="media-preview-thumb" src="${s}" muted playsinline preload="metadata"></video><span class="media-preview-play" aria-hidden="true">▶</span>`
                : `<img class="media-preview-thumb" src="${s}" alt="" decoding="async">`;
            return `<div class="media-preview-item" data-media-index="${i}" data-media-kind="${m.kind}">
                ${media}
                <button type="button" class="media-preview-remove" data-media-remove="${i}" title="Remove attachment" aria-label="Remove attachment">
                    <svg viewBox="0 0 24 24" width="12" height="12" stroke="currentColor" stroke-width="2.5" fill="none" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                </button>
            </div>`;
        });

        const placeholders = pending.map(p => {
            const s = this.escapeHtml(p.objectUrl);
            const media = p.kind === 'video'
                ? `<video class="media-preview-thumb" src="${s}" muted playsinline preload="metadata"></video>`
                : `<img class="media-preview-thumb" src="${s}" alt="" decoding="async">`;
            return `<div class="media-preview-item uploading">${media}<span class="media-preview-spinner" aria-hidden="true"></span></div>`;
        });

        strip.innerHTML = thumbs.join('') + placeholders.join('');
        strip.dataset.sig = sig;
        strip.classList.remove('nm-hidden');
        this._refreshComposerOffsets();
    },

    // Delegated handlers for the strip (bound once from initialize()).
    setupComposerMediaPreviews() {
        const strip = document.getElementById('mediaPreviewStrip');
        if (!strip || strip._nymBound) return;
        strip._nymBound = true;
        strip.addEventListener('click', (e) => {
            const remove = e.target.closest('.media-preview-remove');
            if (remove) {
                e.preventDefault();
                e.stopPropagation();
                this.removeComposerMedia(parseInt(remove.dataset.mediaRemove, 10));
                return;
            }
            const item = e.target.closest('.media-preview-item');
            if (!item || item.classList.contains('uploading')) return;
            const idx = parseInt(item.dataset.mediaIndex, 10);
            const input = document.getElementById('messageInput');
            const match = this._composerMediaMatches(input ? input.value : '')[idx];
            if (!match) return;
            const proxyBase = typeof this._getProxyBaseUrl === 'function' ? this._getProxyBaseUrl() : null;
            const full = proxyBase ? `${proxyBase}?url=${encodeURIComponent(match.url)}` : match.url;
            if (match.kind === 'video') this.expandVideo(full);
            else this.expandImage(full);
        });
    },

    // Drop one attachment: strip its URL (and the whitespace it brought with it)
    // back out of the draft.
    removeComposerMedia(index) {
        const input = document.getElementById('messageInput');
        if (!input || !Number.isInteger(index)) return;
        const v = input.value || '';
        const match = this._composerMediaMatches(v)[index];
        if (!match) return;
        let { start, end } = match;
        // Swallow one trailing space, else one leading space, so removing a
        // middle attachment doesn't leave a double space behind.
        if (v[end] === ' ') end++;
        else if (start > 0 && v[start - 1] === ' ') start--;
        const caret = Math.min(start, v.length);
        input.value = v.slice(0, start) + v.slice(end);
        input.setSelectionRange(caret, caret);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.focus();
    }

});
