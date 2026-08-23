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

// live input formatting 
const NYM_RICH_FENCE_RX = /```[\s\S]*?```|```[\s\S]*$/g;

const NYM_RICH_LINE_PREFIXES = [
    { type: 'h3', mark: '### ' },
    { type: 'h2', mark: '## ' },
    { type: 'h1', mark: '# ' },
    { type: 'quote', mark: '> ' }
];

// Ordered by precedence: when two constructs start at the same offset the
// earlier entry wins, which reproduces the sequential replace order the
// message formatter uses.
const NYM_RICH_INLINE = [
    { type: 'code', rx: /`([^`]+?)`/g, open: '`', close: '`', leaf: true },
    { type: 'bold', rx: /\*\*(.+?)\*\*/g, open: '**', close: '**' },
    { type: 'bold', rx: /(?<!\w)__(.+?)__(?!\w)/g, open: '__', close: '__' },
    { type: 'italic', rx: /(?<![:/])\*([^*\s][^*]*)\*/g, open: '*', close: '*' },
    { type: 'italic', rx: /(?<![:/\w])_([^_\s][^_]*)_(?!\w)/g, open: '_', close: '_' },
    { type: 'strike', rx: /~~(.+?)~~/g, open: '~~', close: '~~' }
];

// Nesting past this depth is left as plain text. Four covers every combination
// the toolbar can produce and bounds the work done on every keystroke.
const NYM_RICH_MAX_DEPTH = 4;

// First match of `rx` lying wholly inside [from, to). Matching runs against the
// whole draft rather than a slice so the lookbehinds above still see the real
// preceding character.
function nymRichFirstMatch(text, from, to, rx) {
    rx.lastIndex = from;
    let m;
    while ((m = rx.exec(text)) !== null) {
        if (m.index >= to) break;
        if (m.index + m[0].length <= to) return m;
        rx.lastIndex = m.index + 1;
    }
    return null;
}

function nymRichParseInline(text, from, to, depth) {
    const out = [];
    let pos = from;
    while (pos < to) {
        let best = null, spec = null;
        if (depth < NYM_RICH_MAX_DEPTH) {
            for (const s of NYM_RICH_INLINE) {
                const m = nymRichFirstMatch(text, pos, to, s.rx);
                if (m && (!best || m.index < best.index)) { best = m; spec = s; }
            }
        }
        if (!best) {
            out.push({ kind: 'text', start: pos, end: to });
            break;
        }
        if (best.index > pos) out.push({ kind: 'text', start: pos, end: best.index });
        const start = best.index;
        const end = start + best[0].length;
        const innerStart = start + spec.open.length;
        const innerEnd = end - spec.close.length;
        out.push({
            kind: 'inline', type: spec.type, start, end,
            open: spec.open, close: spec.close,
            // Nothing reveals. Revealing the whole span put the markers back on
            // screen for as long as the caret was anywhere inside the run —
            // which, while you are typing it, is always.
            reveal: [],
            children: spec.leaf
                ? (innerEnd > innerStart ? [{ kind: 'text', start: innerStart, end: innerEnd }] : [])
                : nymRichParseInline(text, innerStart, innerEnd, depth + 1)
        });
        pos = end;
    }
    return out;
}

// Everything outside a fenced code block: line prefixes first (they only count
// at a real line start), then inline constructs within each line.
function nymRichParseFlow(text, from, to, out) {
    let pos = from;
    while (pos < to) {
        let nl = text.indexOf('\n', pos);
        if (nl === -1 || nl >= to) nl = to;
        const lineStart = pos, lineEnd = nl;
        let handled = false;
        if (lineStart === 0 || text[lineStart - 1] === '\n') {
            for (const p of NYM_RICH_LINE_PREFIXES) {
                if (lineEnd - lineStart <= p.mark.length) continue;
                if (!text.startsWith(p.mark, lineStart)) continue;
                out.push({
                    kind: 'line', type: p.type, start: lineStart, end: lineEnd,
                    open: p.mark, close: '',
                    // Block markers never reveal: what a heading or a quote is
                    // reads off its own styling, and showing the prefix again
                    // would shift the line every time the caret passed the
                    // start of it. Backspace at the start of the body removes
                    // the prefix instead (nymRichMarkerDelete).
                    reveal: [],
                    children: nymRichParseInline(text, lineStart + p.mark.length, lineEnd, 0)
                });
                handled = true;
                break;
            }
        }
        if (!handled && lineEnd > lineStart) {
            const kids = nymRichParseInline(text, lineStart, lineEnd, 0);
            for (let i = 0; i < kids.length; i++) out.push(kids[i]);
        }
        if (lineEnd < to) out.push({ kind: 'text', start: lineEnd, end: lineEnd + 1 });
        pos = lineEnd + 1;
    }
}

// The edit a Backspace/Delete next to a hidden marker should make.
function nymRichMarkerDelete(text, caret, forward) {
    if (!text || caret < 0 || caret > text.length) return null;
    const cut = (ranges) => {
        // Highest offset first so the earlier ranges keep their indices.
        const sorted = ranges.slice().sort((a, b) => b[0] - a[0]);
        let out = text;
        for (const [a, b] of sorted) out = out.slice(0, a) + out.slice(b);
        return out;
    };

    // Innermost first, so the tightest formatting at the caret is the one that
    // comes off: in "***x***" a Backspace should drop one level, not both.
    const nodes = [];
    const walk = (list) => {
        for (const n of list) {
            if (n.children) walk(n.children);
            nodes.push(n);
        }
    };
    walk(nymRichParseFormat(text));

    for (const n of nodes) {
        if (n.kind === 'line') {
            const markEnd = n.start + n.open.length;
            const hit = forward ? caret === n.start : caret === markEnd;
            if (hit) return { text: cut([[n.start, markEnd]]), caret: n.start };
        } else if (n.kind === 'fence' || n.kind === 'inline') {
            if (!n.open) continue;
            const openEnd = n.start + n.open.length;
            const closeStart = n.close ? n.end - n.close.length : n.end;
            // The caret sits at one of the run's two inner edges (the only two
            // places a hidden marker is adjacent to visible text), or just
            // outside it.
            const atEnd = forward ? caret === closeStart : caret === n.end;
            const atStart = forward ? caret === n.start : caret === openEnd;
            if (!atStart && !(n.close && atEnd)) continue;
            const ranges = [[n.start, openEnd]];
            if (n.close) ranges.push([closeStart, n.end]);
            // Keep the caret where the text it was against ended up.
            const caretOut = atEnd ? n.start + (closeStart - openEnd) : n.start;
            return { text: cut(ranges), caret: caretOut };
        }
    }
    return null;
}

function nymRichParseFormat(text) {
    const out = [];
    if (!text) return out;
    NYM_RICH_FENCE_RX.lastIndex = 0;
    let pos = 0, m;
    while ((m = NYM_RICH_FENCE_RX.exec(text)) !== null) {
        if (m.index > pos) nymRichParseFlow(text, pos, m.index, out);
        const start = m.index, end = start + m[0].length;
        // The formatter also renders an unterminated trailing fence, which has
        // no closing marker to hide.
        const closed = m[0].length >= 6 && m[0].endsWith('```');
        const innerEnd = closed ? end - 3 : end;
        out.push({
            kind: 'fence', type: 'codeblock', start, end,
            open: '```', close: closed ? '```' : '',
            // Never revealed, like the line prefixes above — a code block is
            // unmistakable from its own rendering, and revealing the fence the
            // instant the caret reached it would undo the empty block the user
            // just opened by typing it.
            reveal: [],
            // No body yet: the block still has to be visible, or three
            // backticks would look like they did nothing.
            emptyBody: innerEnd <= start + 3,
            children: innerEnd > start + 3 ? [{ kind: 'text', start: start + 3, end: innerEnd }] : []
        });
        pos = end;
    }
    if (pos < text.length) nymRichParseFlow(text, pos, text.length, out);
    return out;
}

Object.assign(NYM.prototype, {

    // The parse tree for a draft, consumed by the input renderer in
    // ui-context.js. Exposed on the prototype so the renderer can stay
    // agnostic about the grammar.
    _richParseFormat(text) {
        return nymRichParseFormat(text);
    },

    _richMarkerDelete(text, caret, forward) {
        return nymRichMarkerDelete(text, caret, forward);
    },

    // formatting toolbar 
    // Build the toolbar once and wire the toggle button, tool clicks and the
    // keyboard shortcuts. Called from initialize().
    setupFormatToolbar() {
        const btn = document.getElementById('formatInputBtn');
        const toolbar = document.getElementById('formatToolbar');
        const input = document.getElementById('messageInput');
        if (!btn || !toolbar || !input) return;

        // No preview toggle: the input itself renders the formatting.
        toolbar.innerHTML = NYM_FORMAT_TOOLS.map(t =>
            `<button type="button" class="format-tool" data-format-tool="${t.id}" title="${this.escapeHtml(t.title)}" aria-label="${this.escapeHtml(t.title)}">${t.html}</button>`
        ).join('');

        // mousedown (not click) so the caret/selection in the contenteditable is
        // still intact when the tool runs — clicking a button would otherwise
        // blur the input and collapse the selection first.
        toolbar.addEventListener('mousedown', (e) => {
            const tool = e.target.closest('.format-tool');
            if (!tool) return;
            e.preventDefault();
            e.stopPropagation();
            this.applyInputFormat(tool.dataset.formatTool);
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

    _applyFormatToolbarState() {
        const btn = document.getElementById('formatInputBtn');
        const toolbar = document.getElementById('formatToolbar');
        if (!btn || !toolbar) return;
        const open = !!this.formatToolbarOpen;
        toolbar.classList.toggle('nm-hidden', !open);
        btn.classList.toggle('active', open);
        btn.setAttribute('aria-pressed', open ? 'true' : 'false');
        this._refreshComposerOffsets();
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
        // auto-resize, the live formatting and the media strip in step.
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

    // Placeholder thumbnails rendered from the local files

    _composerAttachmentSeq: 0,

    // Registers freshly-picked files as uploading tiles, so the user sees what
    // they chose before a byte is up. Returns the new records.
    addComposerAttachments(files) {
        if (!this._composerAttachments) this._composerAttachments = [];
        const added = [];
        for (const f of (files || [])) {
            let objectUrl = '';
            try { objectUrl = URL.createObjectURL(f); } catch (_) { }
            if (!objectUrl) continue;
            const rec = {
                id: 'att' + (++this._composerAttachmentSeq),
                kind: (f.type || '').startsWith('video/') ? 'video' : 'image',
                objectUrl,
                status: 'uploading',
                url: '',
                file: f,
                error: '',
            };
            this._composerAttachments.push(rec);
            added.push(rec);
        }
        this.updateComposerMediaPreviews();
        return added;
    },

    composerAttachmentById(id) {
        return (this._composerAttachments || []).find(a => a.id === id) || null;
    },

    updateComposerAttachment(id, patch) {
        const rec = this.composerAttachmentById(id);
        if (!rec) return null;
        Object.assign(rec, patch || {});
        // The local object URL keeps standing in for the hosted one, so the
        // thumbnail never flickers and we do not re-fetch what we just sent.
        if (rec.status === 'done' && rec.url) {
            if (!this._composerMediaBlobs) this._composerMediaBlobs = new Map();
            if (!this._composerMediaBlobs.has(rec.url)) {
                this._composerMediaBlobs.set(rec.url, rec.objectUrl);
            }
            if (!this._composerMediaBlobHold) this._composerMediaBlobHold = new Set();
            this._composerMediaBlobHold.add(rec.url);
        }
        this.updateComposerMediaPreviews();
        return rec;
    },

    removeComposerAttachment(id) {
        const list = this._composerAttachments || [];
        const idx = list.findIndex(a => a.id === id);
        if (idx < 0) return;
        const [rec] = list.splice(idx, 1);
        // Safe to revoke only while nothing else points at it: once uploaded,
        // the blob map is standing in for the hosted URL.
        if (rec && rec.status !== 'done') {
            try { URL.revokeObjectURL(rec.objectUrl); } catch (_) { }
        }
        this.updateComposerMediaPreviews();
    },

    // The hosted URLs to append to the outgoing message, in the order added.
    // A still-uploading or failed tile contributes nothing.
    composerAttachmentUrls() {
        return (this._composerAttachments || [])
            .filter(a => a.status === 'done' && a.url)
            .map(a => a.url);
    },

    composerHasPendingUploads() {
        return (this._composerAttachments || []).some(a => a.status === 'uploading');
    },

    // Called once the message carrying these attachments has gone out.
    clearComposerAttachments() {
        for (const a of (this._composerAttachments || [])) {
            if (a.status !== 'done') {
                try { URL.revokeObjectURL(a.objectUrl); } catch (_) { }
            }
        }
        this._composerAttachments = [];
        if (this._composerMediaBlobHold) this._composerMediaBlobHold.clear();
        this.updateComposerMediaPreviews();
    },

    // changed, otherwise a keystroke would restart every <video> preload.
    updateComposerMediaPreviews() {
        const strip = document.getElementById('mediaPreviewStrip');
        const input = document.getElementById('messageInput');
        if (!strip || !input) return;

        const matches = this._composerMediaMatches(input.value || '');
        const attachments = this._composerAttachments || [];
        this._releaseComposerMediaBlobs(matches.map(m => m.url)
            .concat(attachments.map(a => a.url).filter(Boolean)));

        if (!matches.length && !attachments.length) {
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

        const sig = matches.map(m => m.kind + ':' + m.url).join('|') + '#'
            + attachments.map(a => a.id + ':' + a.status).join('|');
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

        const closeSvg = '<svg viewBox="0 0 24 24" width="12" height="12" stroke="currentColor" '
            + 'stroke-width="2.5" fill="none" stroke-linecap="round">'
            + '<line x1="18" y1="6" x2="6" y2="18"></line>'
            + '<line x1="6" y1="6" x2="18" y2="18"></line></svg>';
        const retrySvg = '<svg viewBox="0 0 24 24" width="16" height="16" stroke="currentColor" '
            + 'stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round">'
            + '<polyline points="1 4 1 10 7 10"></polyline>'
            + '<path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"></path></svg>';

        // One tile per attachment. The wheel IS the progress indicator, per
        // file and in place, instead of one bar for the whole batch that could
        // not say which file it was talking about.
        const tiles = attachments.map(a => {
            const s = this.escapeHtml(a.objectUrl);
            const media = a.kind === 'video'
                ? `<video class="media-preview-thumb" src="${s}" muted playsinline preload="metadata"></video>`
                : `<img class="media-preview-thumb" src="${s}" alt="" decoding="async">`;
            const id = this.escapeHtml(a.id);
            let overlay = '';
            let title = '';
            if (a.status === 'uploading') {
                overlay = '<span class="media-preview-spinner" aria-hidden="true"></span>';
                title = 'Uploading\u2026';
            } else if (a.status === 'failed') {
                overlay = `<span class="media-preview-retry" aria-hidden="true">${retrySvg}</span>`;
                title = (a.error ? a.error + ' \u2014 ' : '') + 'Tap to retry';
            } else if (a.kind === 'video') {
                overlay = '<span class="media-preview-play" aria-hidden="true">\u25B6</span>';
            }
            return `<div class="media-preview-item ${a.status}" data-attachment-id="${id}" data-media-kind="${a.kind}" title="${this.escapeHtml(title)}">
                ${media}${overlay}
                <button type="button" class="media-preview-remove" data-attachment-remove="${id}" title="Remove attachment" aria-label="Remove attachment">${closeSvg}</button>
            </div>`;
        });

        strip.innerHTML = thumbs.join('') + tiles.join('');
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
                if (remove.dataset.attachmentRemove) {
                    this.removeComposerAttachment(remove.dataset.attachmentRemove);
                } else {
                    this.removeComposerMedia(parseInt(remove.dataset.mediaRemove, 10));
                }
                return;
            }
            const tile = e.target.closest('.media-preview-item[data-attachment-id]');
            if (tile) {
                e.preventDefault();
                const rec = this.composerAttachmentById(tile.dataset.attachmentId);
                if (!rec) return;
                // A failed tile IS the retry button: the file is still held, so
                // one failure never costs the user the rest of the batch.
                if (rec.status === 'failed') this.retryComposerAttachment(rec.id);
                else if (rec.status === 'done') {
                    if (rec.kind === 'video') this.expandVideo(rec.objectUrl);
                    else this.expandImage(rec.objectUrl);
                }
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
