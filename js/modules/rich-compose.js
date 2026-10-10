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
        id: 'underline', wrap: '__', title: 'Underline', key: 'u',
        html: '<span class="ft-glyph ft-underline">U</span>'
    },
    {
        id: 'strike', wrap: '~~', title: 'Strikethrough',
        html: '<span class="ft-glyph ft-strike">S</span>'
    },
    {
        id: 'spoiler', wrap: '||', title: 'Spoiler',
        html: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"></path><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"></path><path d="M14.12 14.12a3 3 0 1 1-4.24-4.24"></path><line x1="1" y1="1" x2="23" y2="23"></line></svg>'
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
        id: 'subtext', prefix: '-# ', title: 'Subtext',
        html: '<span class="ft-glyph ft-subtext">-#</span>'
    },
    {
        id: 'timestamp', picker: true, title: 'Timestamp',
        html: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"></circle><polyline points="12 7 12 12 15 14"></polyline></svg>'
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

// Kept in sync with the media regexes in message-format.js.
const NYM_COMPOSER_MEDIA_RX = /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?[^\s]*)?)/gi;
const NYM_COMPOSER_VIDEO_EXTS = ['mp4', 'webm', 'ogg', 'mov'];

const NYM_RICH_FENCE_RX = /```[\s\S]*?```|```[\s\S]*$/g;

const NYM_RICH_LINE_PREFIXES = [
    { type: 'h3', mark: '### ' },
    { type: 'h2', mark: '## ' },
    { type: 'h1', mark: '# ' },
    { type: 'subtext', mark: '-# ' },
    { type: 'quote', mark: '> ' }
];

const NYM_RICH_LIST_RX = /^(\t| {2,})?([-*]|\d{1,9}\.) (?=\S)/;

function nymRichLinePrefix(text, lineStart, lineEnd) {
    for (const p of NYM_RICH_LINE_PREFIXES) {
        if (lineEnd - lineStart <= p.mark.length) continue;
        if (!text.startsWith(p.mark, lineStart)) continue;
        return { type: p.type, open: p.mark };
    }
    const m = NYM_RICH_LIST_RX.exec(text.slice(lineStart, lineEnd));
    if (!m) return null;
    const nested = m[1] ? '2' : '';
    if (m[2] === '-' || m[2] === '*') return { type: 'ulist' + nested, open: m[0] };
    return { type: 'olist' + nested, open: '', visibleMark: true };
}

const NYM_RICH_TS_RX = /<t:(-?\d{1,17})(?::([tTdDfFR]))?>/g;

function nymRichTimestampLabel(m) {
    const F = (typeof window !== 'undefined' && window.NymFormat) || (typeof self !== 'undefined' && self.NymFormat) || null;
    const sec = Number(m[1]);
    if (!Number.isSafeInteger(sec) || Math.abs(sec) > 8640000000000) return null;
    if (!F || typeof F.formatTimestamp !== 'function') return m[0];
    try { return F.formatTimestamp(sec, m[2] || 'f'); } catch (_) { return null; }
}

// Ordered by precedence: at the same offset the earlier entry wins, matching the formatter's replace order.
const NYM_RICH_INLINE = [
    { type: 'code', rx: /`([^`]+?)`/g, open: '`', close: '`', leaf: true },
    { type: 'timestamp', rx: NYM_RICH_TS_RX, atom: true },
    { type: 'spoiler', rx: /\|\|([^\s|](?:[^\n]*?[^\s|])??)\|\|/g, open: '||', close: '||' },
    { type: 'bold', rx: /\*\*(.+?)\*\*/g, open: '**', close: '**' },
    { type: 'underline', rx: /(?<!\w)__(.+?)__(?!\w)/g, open: '__', close: '__' },
    { type: 'italic', rx: /(?<![:/])\*([^*\s][^*]*)\*/g, open: '*', close: '*' },
    { type: 'italic', rx: /(?<![:/\w])_([^_\s][^_]*)_(?!\w)/g, open: '_', close: '_' },
    { type: 'strike', rx: /~~(.+?)~~/g, open: '~~', close: '~~' }
];

// Nesting past this depth stays plain text; bounds per-keystroke work.
const NYM_RICH_MAX_DEPTH = 4;

// Matches against the whole draft so lookbehinds still see the real preceding character.
function nymRichFirstMatch(text, from, to, rx, accept) {
    rx.lastIndex = from;
    let m;
    while ((m = rx.exec(text)) !== null) {
        if (m.index >= to) break;
        if (m.index + m[0].length <= to && (!accept || accept(m))) return m;
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
                const m = nymRichFirstMatch(text, pos, to, s.rx, s.atom ? (c) => nymRichTimestampLabel(c) != null : null);
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
        if (spec.atom) {
            out.push({
                kind: 'inline', type: spec.type, start, end,
                open: best[0], close: '', reveal: [], children: [],
                label: nymRichTimestampLabel(best)
            });
            pos = end;
            continue;
        }
        const innerStart = start + spec.open.length;
        const innerEnd = end - spec.close.length;
        out.push({
            kind: 'inline', type: spec.type, start, end,
            open: spec.open, close: spec.close,
            // Nothing reveals: revealing would show markers whenever the caret is inside the run.
            reveal: [],
            children: spec.leaf
                ? (innerEnd > innerStart ? [{ kind: 'text', start: innerStart, end: innerEnd }] : [])
                : nymRichParseInline(text, innerStart, innerEnd, depth + 1)
        });
        pos = end;
    }
    return out;
}

// Line prefixes first (they only count at a real line start), then inline constructs.
function nymRichParseFlow(text, from, to, out) {
    let pos = from;
    while (pos < to) {
        let nl = text.indexOf('\n', pos);
        if (nl === -1 || nl >= to) nl = to;
        const lineStart = pos, lineEnd = nl;
        let handled = false;
        if (lineStart === 0 || text[lineStart - 1] === '\n') {
            const p = nymRichLinePrefix(text, lineStart, lineEnd);
            if (p) {
                out.push({
                    kind: 'line', type: p.type, start: lineStart, end: lineEnd,
                    open: p.open, close: '',
                    // Block markers never reveal; Backspace at the start of the body removes the prefix (nymRichMarkerDelete).
                    reveal: [],
                    children: nymRichParseInline(text, lineStart + p.open.length, lineEnd, 0)
                });
                handled = true;
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

function nymRichMarkerDelete(text, caret, forward) {
    if (!text || caret < 0 || caret > text.length) return null;
    const cut = (ranges) => {
        // Highest offset first so the earlier ranges keep their indices.
        const sorted = ranges.slice().sort((a, b) => b[0] - a[0]);
        let out = text;
        for (const [a, b] of sorted) out = out.slice(0, a) + out.slice(b);
        return out;
    };

    // Innermost first: in "***x***" a Backspace should drop one level, not both.
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
            if (!n.open) continue;
            const markEnd = n.start + n.open.length;
            const hit = forward ? caret === n.start : caret === markEnd;
            if (hit) return { text: cut([[n.start, markEnd]]), caret: n.start };
        } else if (n.kind === 'fence' || n.kind === 'inline') {
            if (!n.open) continue;
            const openEnd = n.start + n.open.length;
            const closeStart = n.close ? n.end - n.close.length : n.end;
            const atEnd = forward ? caret === closeStart : caret === n.end;
            const atStart = forward ? caret === n.start : caret === openEnd;
            if (!atStart && !(n.close && atEnd)) continue;
            const ranges = [[n.start, openEnd]];
            if (n.close) ranges.push([closeStart, n.end]);
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
        // The formatter also renders an unterminated trailing fence.
        const closed = m[0].length >= 6 && m[0].endsWith('```');
        const innerEnd = closed ? end - 3 : end;
        out.push({
            kind: 'fence', type: 'codeblock', start, end,
            open: '```', close: closed ? '```' : '',
            // Never revealed, or the fence would reappear and undo the block the user just opened.
            reveal: [],
            // No body yet: the block must stay visible or three backticks would look like nothing happened.
            emptyBody: innerEnd <= start + 3,
            children: innerEnd > start + 3 ? [{ kind: 'text', start: start + 3, end: innerEnd }] : []
        });
        pos = end;
    }
    if (pos < text.length) nymRichParseFlow(text, pos, text.length, out);
    return out;
}

Object.assign(NYM.prototype, {

    // Consumed by the input renderer in ui-context.js.
    _richParseFormat(text) {
        return nymRichParseFormat(text);
    },

    _richMarkerDelete(text, caret, forward) {
        return nymRichMarkerDelete(text, caret, forward);
    },

    setupFormatToolbar() {
        const toolbar = document.getElementById('formatToolbar');
        const input = document.getElementById('messageInput');
        if (!toolbar || !input) return;

        toolbar.querySelectorAll('.format-tool[data-format-tool]').forEach((el) => el.remove());
        toolbar.insertAdjacentHTML('beforeend', NYM_FORMAT_TOOLS.map(t =>
            `<button type="button" class="format-tool" data-format-tool="${t.id}" title="${this.escapeHtml(t.title)}" aria-label="${this.escapeHtml(t.title)}">${t.html}</button>`
        ).join(''));

        toolbar.addEventListener('mousedown', (e) => {
            const tool = e.target.closest('.format-tool');
            if (!tool) return;
            e.preventDefault();
            if (!tool.dataset.formatTool) return;
            e.stopPropagation();
            this.applyInputFormat(tool.dataset.formatTool);
        });
        toolbar.addEventListener('click', (e) => {
            if (e.target.closest('[data-format-tool]')) e.preventDefault();
        });

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

        this._applyFormatToolbarState();
    },

    _applyFormatToolbarState() {
        const toolbar = document.getElementById('formatToolbar');
        if (!toolbar) return;
        const box = toolbar.closest('.input-container');
        const open = !!(box && box.classList.contains('composer-pill'));
        if (toolbar.classList.contains('nm-hidden') !== !open) {
            toolbar.classList.toggle('nm-hidden', !open);
            if (!open) {
                const dropdown = document.getElementById('translateInputDropdown');
                if (dropdown) dropdown.classList.remove('active');
            }
        }
        if (typeof this.syncComposerInlineActions === 'function') this.syncComposerInlineActions();
        this._refreshComposerOffsets();
    },

    applyInputFormat(id) {
        const tool = NYM_FORMAT_TOOLS_BY_ID[id];
        const input = document.getElementById('messageInput');
        if (!tool || !input || input.disabled) return;

        if (tool.picker) { this.openTimestampPicker(); return; }
        if (tool.wrap) this._wrapInputSelection(input, tool.wrap, tool.wrap);
        else if (tool.block) this._toggleInputCodeBlock(input, tool.block);
        else if (tool.prefix != null) this._toggleInputLinePrefix(input, tool.prefix, tool.exclusive);

        // Same signal a keystroke sends, keeping dependent UI in step.
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.focus();
    },

    openTimestampPicker() {
        const input = document.getElementById('messageInput');
        const panels = document.getElementById('composerPanels');
        if (!input || !panels || input.disabled) return;
        const ui = (t) => (typeof this.uiText === 'function' ? this.uiText(t) : t);
        let picker = document.getElementById('timestampPicker');
        if (!picker) {
            picker = document.createElement('div');
            picker.id = 'timestampPicker';
            picker.className = 'ts-picker nm-hidden';
            picker.setAttribute('role', 'dialog');
            picker.innerHTML = `<label class="ts-picker-label"><span class="ts-picker-title"></span>`
                + `<input type="datetime-local" class="ts-picker-input" step="60"></label>`
                + `<button type="button" class="ts-picker-cancel"></button>`
                + `<button type="button" class="ts-picker-insert"></button>`;
            const toolbar = document.getElementById('formatToolbar');
            panels.insertBefore(picker, toolbar || null);
            picker.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') { e.preventDefault(); this.closeTimestampPicker(); }
                else if (e.key === 'Enter') { e.preventDefault(); this._insertPickedTimestamp(); }
            });
            picker.querySelector('.ts-picker-insert').addEventListener('click', () => this._insertPickedTimestamp());
            picker.querySelector('.ts-picker-cancel').addEventListener('click', () => this.closeTimestampPicker());
        }
        picker.setAttribute('aria-label', ui('Insert a timestamp'));
        picker.querySelector('.ts-picker-title').textContent = ui('Date and time');
        picker.querySelector('.ts-picker-insert').textContent = ui('Insert');
        picker.querySelector('.ts-picker-cancel').textContent = ui('Cancel');
        const field = picker.querySelector('.ts-picker-input');
        const now = new Date();
        now.setSeconds(0, 0);
        const pad = (n) => String(n).padStart(2, '0');
        field.value = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}`;
        this._tsPickerSel = { start: input.selectionStart, end: input.selectionEnd };
        picker.classList.remove('nm-hidden');
        this._refreshComposerOffsets();
        field.focus();
    },

    closeTimestampPicker() {
        const picker = document.getElementById('timestampPicker');
        if (!picker || picker.classList.contains('nm-hidden')) return;
        picker.classList.add('nm-hidden');
        this._refreshComposerOffsets();
        const input = document.getElementById('messageInput');
        if (input && !input.disabled) input.focus();
    },

    _insertPickedTimestamp() {
        const picker = document.getElementById('timestampPicker');
        const field = picker && picker.querySelector('.ts-picker-input');
        const ms = field && field.value ? new Date(field.value).getTime() : NaN;
        if (!Number.isFinite(ms)) return;
        this.insertTimestampTag(Math.floor(ms / 1000), this._tsPickerSel);
        this.closeTimestampPicker();
    },

    insertTimestampTag(seconds, sel) {
        const input = document.getElementById('messageInput');
        if (!input || input.disabled || !Number.isSafeInteger(seconds)) return;
        const tag = `<t:${seconds}:f>`;
        const v = input.value || '';
        let s = sel && Number.isInteger(sel.start) ? sel.start : v.length;
        let e = sel && Number.isInteger(sel.end) ? sel.end : s;
        if (s > e) { const t = s; s = e; e = t; }
        s = Math.max(0, Math.min(s, v.length));
        e = Math.max(s, Math.min(e, v.length));
        input.value = v.slice(0, s) + tag + v.slice(e);
        input.setSelectionRange(s + tag.length, s + tag.length);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.focus();
    },

    _wordRangeAt(v, pos) {
        const isWord = (ch) => ch && !/\s/.test(ch);
        let start = pos, end = pos;
        while (start > 0 && isWord(v[start - 1])) start--;
        while (end < v.length && isWord(v[end])) end++;
        return { start, end };
    },

    // Recognizes a wrap inside or just outside the selection, so a second click always undoes.
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
        // Markdown delimiters must hug the text or the formatter won't match them.
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

    syncComposerInlineActions() {
        const input = document.getElementById('messageInput');
        const row = document.getElementById('inputInlineActions');
        if (!input || !row) return;
        const visible = getComputedStyle(row).display === 'none' ? 0 : Array.from(row.children)
            .filter(b => getComputedStyle(b).display !== 'none').length;
        input.style.paddingRight = visible
            ? (8 + visible * 26 + (visible - 1) * 2 + 4) + 'px'
            : '';
    },

    // Includes offsets because the same URL can legitimately appear twice.
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

    // Hosted URL -> local object URL, so previews show instantly without re-downloading.
    _rememberComposerMediaBlob(url, file) {
        if (!url || !file) return;
        if (!this._composerMediaBlobs) this._composerMediaBlobs = new Map();
        if (this._composerMediaBlobs.has(url)) return;
        try {
            this._composerMediaBlobs.set(url, URL.createObjectURL(file));
        } catch (_) { }
    },

    // "Held" URLs are exempt so a blob isn't revoked between upload and append.
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

    _composerAttachmentSeq: 0,

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

    addComposerGif(url, title) {
        if (!url) return null;
        if (!this._composerAttachments) this._composerAttachments = [];
        const rec = {
            id: 'att' + (++this._composerAttachmentSeq),
            kind: 'image',
            gif: true,
            objectUrl: typeof this.getProxiedMediaUrl === 'function' ? this.getProxiedMediaUrl(url) : url,
            status: 'done',
            url,
            alt: title || '',
            error: '',
        };
        this._composerAttachments.push(rec);
        this.updateComposerMediaPreviews();
        return rec;
    },

    pickComposerGif(url, title) {
        if (!url || this.pendingEdit) return false;
        if (!this.inPMMode && typeof this.sendImagesOverMesh === 'function' && typeof this.meshShouldCarry === 'function'
            && this.meshShouldCarry(this.currentGeohash || this.currentChannel)) {
            this.sendGifOverMesh(url);
            return true;
        }
        this.addComposerGif(url, title);
        return true;
    },

    async sendGifOverMesh(url) {
        let file = null;
        try {
            const res = await fetch(typeof this.getProxiedMediaUrl === 'function' ? this.getProxiedMediaUrl(url) : url);
            if (res.ok) file = new File([await res.blob()], 'gif.gif', { type: 'image/gif' });
        } catch (_) { }
        if (!file) {
            if (typeof this.displaySystemMessage === 'function') {
                this.displaySystemMessage(typeof this.uiText === 'function' ? this.uiText('Failed to load GIFs') : 'Failed to load GIFs');
            }
            return;
        }
        await this.sendImagesOverMesh([file]);
    },

    composerAttachmentById(id) {
        return (this._composerAttachments || []).find(a => a.id === id) || null;
    },

    updateComposerAttachment(id, patch) {
        const rec = this.composerAttachmentById(id);
        if (!rec) return null;
        Object.assign(rec, patch || {});
        // The local object URL keeps standing in for the hosted one to avoid flicker and refetch.
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
        if (typeof this._endAttachmentActivity === 'function') this._endAttachmentActivity(rec);
        // Safe to revoke only before upload completes; afterward the blob stands in for the hosted URL.
        if (rec && rec.status !== 'done') {
            try { URL.revokeObjectURL(rec.objectUrl); } catch (_) { }
        }
        this.updateComposerMediaPreviews();
    },

    composerAttachmentUrls() {
        return (this._composerAttachments || [])
            .filter(a => a.status === 'done' && a.url)
            .map(a => (typeof this.attachmentContentFor === 'function' ? this.attachmentContentFor(a) : a.url))
            .filter(Boolean);
    },

    composerHasPendingUploads() {
        return (this._composerAttachments || []).some(a => a.status === 'uploading'
            || (typeof this.attachmentStale === 'function' && this.attachmentStale(a)));
    },

    clearComposerAttachments() {
        for (const a of (this._composerAttachments || [])) {
            if (typeof this._endAttachmentActivity === 'function') this._endAttachmentActivity(a);
            if (a.status !== 'done') {
                try { URL.revokeObjectURL(a.objectUrl); } catch (_) { }
            }
        }
        this._composerAttachments = [];
        if (this._composerMediaBlobHold) this._composerMediaBlobHold.clear();
        this.updateComposerMediaPreviews();
    },

    updateComposerMediaPreviews() {
        const strip = document.getElementById('mediaPreviewStrip');
        const input = document.getElementById('messageInput');
        if (!strip || !input) return;
        if (typeof this._renderMediaOptions === 'function') this._renderMediaOptions();

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

        const proxyBase = typeof this._mediaProxyBase === 'function' ? this._mediaProxyBase() : null;
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

        const tiles = attachments.map(a => {
            const s = this.escapeHtml(a.objectUrl);
            const media = a.kind === 'video'
                ? `<video class="media-preview-thumb" src="${s}" muted playsinline preload="metadata"></video>`
                : `<img class="media-preview-thumb" src="${s}" alt="${this.escapeHtml(a.alt || '')}" decoding="async">`;
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
            const proxyBase = typeof this._mediaProxyBase === 'function' ? this._mediaProxyBase() : null;
            const full = proxyBase ? `${proxyBase}?url=${encodeURIComponent(match.url)}` : match.url;
            if (match.kind === 'video') this.expandVideo(full);
            else this.expandImage(full);
        });
    },

    removeComposerMedia(index) {
        const input = document.getElementById('messageInput');
        if (!input || !Number.isInteger(index)) return;
        const v = input.value || '';
        const match = this._composerMediaMatches(v)[index];
        if (!match) return;
        let { start, end } = match;
        // Swallow one trailing, else one leading, space so no double space remains.
        if (v[end] === ' ') end++;
        else if (start > 0 && v[start - 1] === ' ') start--;
        const caret = Math.min(start, v.length);
        input.value = v.slice(0, start) + v.slice(end);
        input.setSelectionRange(caret, caret);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.focus();
    }

});
