(function () {
    'use strict';
    const G = typeof window !== 'undefined' ? window : typeof self !== 'undefined' ? self : globalThis;

    const CLASS = 'nym-suffix';
    const LABEL_CLASS = 'nym-l';
    const SEG_CLASS = 'nym-seg';
    const BIDI = /[\u200e\u200f\u061c\u202a-\u202e\u2066-\u2069]/;
    const BIDI_ALL = new RegExp(BIDI.source, 'g');
    const BREAKS = /[\t\n\v\f\r\u0085\u2028\u2029]/g;
    const ISOLATE_MARK = /[\u2066-\u2069]/g;
    const AFTER_ISOLATE = /^#[0-9a-f]{4}(?![0-9a-z_])/i;
    const LABEL = /^([\s\S]*[^\s#])(#[0-9a-f]{4})$/i;
    const MENTION = /@[^@#\n]*?(?<!\s)#[0-9a-f]{4}\b/gi;
    const GLUED = /(?<=[^\s#@(\[{\/\\"'`<>=?&:;,.!])#([0-9a-f]{4})(?![0-9a-z_])/gi;
    const seen = new Set();

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;' }[c]));
    }

    function tail(v) {
        const s = String(v == null ? '' : v);
        const m = /#([0-9a-f]{4})$/i.exec(s) || /^([0-9a-f]{4})$/i.exec(s) || /^[0-9a-f]{60}([0-9a-f]{4})$/i.exec(s);
        return m ? m[1].toLowerCase() : '';
    }

    function remember(v) {
        const t = tail(v);
        if (t) seen.add(t);
        return t;
    }

    function known() {
        return new Set(seen);
    }

    function suffixOf(pubkey) {
        const t = tail(pubkey);
        return t ? '#' + t : '';
    }

    function split(label) {
        const m = LABEL.exec(String(label == null ? '' : label));
        return m ? { base: m[1], suffix: m[2] } : null;
    }

    function strip(name) {
        return String(name == null ? '' : name).replace(/#[0-9a-f]{4}$/i, '');
    }

    const MAX = 20;
    const CAPPED = /^([\s\S]*)#([0-9a-f]{4})$/i;

    const LONE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;
    const LONE_ONE = new RegExp(LONE.source);
    const JOINS = /^(?:\p{M}|[\u200d\u{1f3fb}-\u{1f3ff}\u{e0020}-\u{e007f}])/u;
    const PICT = /^\p{Extended_Pictographic}/u;
    const RI = /^[\u{1f1e6}-\u{1f1ff}]/u;
    let cutSegmenter = null;

    function wellFormed(v) {
        return String(v == null ? '' : v).replace(LONE, '');
    }

    function boundary(s, i) {
        if (i <= 0 || i >= s.length) return true;
        const c = s.charCodeAt(i);
        if (c >= 0xdc00 && c <= 0xdfff && s.charCodeAt(i - 1) >= 0xd800 && s.charCodeAt(i - 1) <= 0xdbff) return false;
        const at = s.slice(i, i + 2);
        if (JOINS.test(at)) return false;
        if (s.charCodeAt(i - 1) === 0x200d && PICT.test(at)) return false;
        if (RI.test(at)) {
            let n = 0;
            for (let j = i - 2; j >= 0 && RI.test(s.slice(j, j + 2)); j -= 2) n++;
            if (n % 2 === 1) return false;
        }
        return true;
    }

    function cutAt(text, max) {
        const s = String(text == null ? '' : text);
        const room = Math.max(0, Math.floor(max));
        if (s.length <= room) return s.length;
        if (G.Intl && typeof G.Intl.Segmenter === 'function') {
            if (!cutSegmenter) cutSegmenter = new G.Intl.Segmenter(undefined, { granularity: 'grapheme' });
            let end = 0;
            for (const g of cutSegmenter.segment(s)) {
                const next = g.index + g.segment.length;
                if (next > room) break;
                end = next;
            }
            return end;
        }
        let i = room;
        while (i > 0 && !boundary(s, i)) i--;
        return i;
    }

    function capBase(base) {
        const s = wellFormed(base);
        if (s.length <= MAX) return s;
        return s.slice(0, cutAt(s, MAX)).replace(/\s+$/, '');
    }

    function fitInsert(value, start, end, data, max) {
        const v = String(value == null ? '' : value);
        const limit = max == null ? MAX : max;
        const a = Math.max(0, Math.min(v.length, start == null ? v.length : start));
        const b = Math.max(a, Math.min(v.length, end == null ? a : end));
        const raw = String(data == null ? '' : data);
        const text = wellFormed(raw.replace(/[\r\n]+/g, ''));
        const room = limit - a - (v.length - b);
        if (text.length <= room && !LONE_ONE.test(raw)) return null;
        const put = text.slice(0, cutAt(text, room));
        return { value: v.slice(0, a) + put + v.slice(b), caret: a + put.length };
    }

    function fitComposed(before, after, data, from, max) {
        const b = String(before == null ? '' : before);
        const v = String(after == null ? '' : after);
        const d = String(data == null ? '' : data).replace(/[\r\n]+/g, '');
        const limit = max == null ? MAX : max;
        const keep = b.length - Math.max(0, Math.min(b.length, from == null ? b.length : from));
        let s = 0;
        while (s < keep && s < v.length && b.charCodeAt(b.length - 1 - s) === v.charCodeAt(v.length - 1 - s)) s++;
        const e = v.length - s;
        let k = Math.min(d.length, e);
        while (k > 0 && v.slice(e - k, e) !== d.slice(0, k)) k--;
        if (k === 0) return null;
        const a = e - k;
        const rest = v.slice(0, a) + v.slice(e);
        return fitInsert(rest, a, a, d, limit);
    }

    const composing = new WeakMap();

    function isNymField(el) {
        return !!el && typeof el.hasAttribute === 'function' && el.hasAttribute('data-nym-input');
    }

    function refitComposed(el, data) {
        const snap = composing.get(el);
        if (!snap || data == null) return;
        const max = parseInt(el.getAttribute('maxlength') || String(MAX), 10) || MAX;
        const fit = fitComposed(snap.before, el.value, data, snap.from, max);
        if (!fit || fit.value === el.value) return;
        el.value = fit.value;
        try { el.setSelectionRange(fit.caret, fit.caret); } catch (_) { }
        el.dispatchEvent(new Event('input', { bubbles: true }));
    }

    function onNymCompositionStart(e) {
        const el = e.target;
        if (!isNymField(el)) return;
        composing.set(el, { before: String(el.value || ''), from: el.selectionEnd == null ? String(el.value || '').length : el.selectionEnd });
    }

    function onNymCompositionEnd(e) {
        if (isNymField(e.target)) refitComposed(e.target, e.data);
    }

    function onNymInput(e) {
        if (e.isComposing || !isNymField(e.target) || !/^(insertCompositionText|insertFromComposition)$/.test(e.inputType || '')) return;
        refitComposed(e.target, e.data);
    }

    function onNymBeforeInput(e) {
        const el = e.target;
        if (!el || typeof el.hasAttribute !== 'function' || !el.hasAttribute('data-nym-input') || e.isComposing) return;
        const t = e.inputType || '';
        if (!/^insert(Text|FromPaste|FromDrop|ReplacementText|FromYank)$/.test(t)) return;
        const data = e.data != null ? e.data : (e.dataTransfer && typeof e.dataTransfer.getData === 'function' ? e.dataTransfer.getData('text/plain') : '');
        const max = parseInt(el.getAttribute('maxlength') || String(MAX), 10) || MAX;
        const fit = fitInsert(el.value, el.selectionStart, el.selectionEnd, data, max);
        if (!fit) return;
        e.preventDefault();
        el.value = fit.value;
        try { el.setSelectionRange(fit.caret, fit.caret); } catch (_) { }
        el.dispatchEvent(new Event('input', { bubbles: true }));
    }

    if (G.document && typeof G.document.addEventListener === 'function') {
        G.document.addEventListener('beforeinput', onNymBeforeInput, true);
        G.document.addEventListener('compositionstart', onNymCompositionStart, true);
        G.document.addEventListener('compositionend', onNymCompositionEnd, true);
        G.document.addEventListener('input', onNymInput, true);
    }

    function cap(name) {
        const s = String(name == null ? '' : name);
        const m = CAPPED.exec(s);
        return m ? capBase(m[1]) + '#' + m[2] : capBase(s);
    }

    function labelText(label) {
        const s = String(label == null ? '' : label);
        const base = s.replace(/#[0-9a-f]{4}$/i, '');
        if (base.trim()) return base;
        return s.trim() ? s : 'nym';
    }

    let segmenter = null;
    function graphemes(s) {
        if (G.Intl && typeof G.Intl.Segmenter === 'function') {
            if (!segmenter) segmenter = new G.Intl.Segmenter(undefined, { granularity: 'grapheme' });
            return Array.from(segmenter.segment(s), (g) => g.segment);
        }
        return Array.from(s);
    }

    function initial(v) {
        const s = wellFormed(v);
        return s ? graphemes(s)[0] : '';
    }

    const GUARD_MEMO_MAX = 2000;
    const guardMemo = new Map();
    let measureCtx = null;
    let measureFamily = null;
    let familyReadAt = -Infinity;
    let familyQueued = false;

    function readFamily(doc) {
        familyReadAt = Date.now();
        const fam = G.getComputedStyle(doc.body).fontFamily || 'sans-serif';
        if (fam !== measureFamily) {
            measureFamily = fam;
            measureCtx.font = '100px ' + fam;
            guardMemo.clear();
        }
    }

    function queueFamily(doc) {
        if (familyQueued) return;
        if (typeof G.requestAnimationFrame !== 'function' || typeof G.setTimeout !== 'function') { readFamily(doc); return; }
        familyQueued = true;
        G.requestAnimationFrame(() => {
            G.setTimeout(() => {
                familyQueued = false;
                try { if (measureCtx && doc.body) readFamily(doc); } catch (e) { }
            }, 0);
        });
    }

    function measurer() {
        const doc = G.document;
        if (!doc || !doc.body || typeof doc.createElement !== 'function' || typeof G.getComputedStyle !== 'function') return null;
        try {
            if (!measureCtx) {
                const canvas = doc.createElement('canvas');
                measureCtx = canvas && typeof canvas.getContext === 'function' ? canvas.getContext('2d') : null;
                if (!measureCtx) { measureCtx = false; return null; }
            }
            if (measureCtx === false) return null;
            if (measureFamily === null) readFamily(doc);
            else if (Date.now() - familyReadAt >= 1000) queueFamily(doc);
            return measureCtx;
        } catch (e) {
            return null;
        }
    }

    function guard(base) {
        const b = String(base == null ? '' : base);
        const g = graphemes(b);
        if (g.length < 2) return '';
        const m = measurer();
        if (!m) return g.length > 2 ? g[0] : '';
        const hit = guardMemo.get(b);
        if (hit !== undefined) return hit;
        let out;
        try {
            out = m.measureText(b).width > m.measureText(g[0] + '…').width ? g[0] : '';
        } catch (e) {
            out = g.length > 2 ? g[0] : '';
        }
        if (guardMemo.size >= GUARD_MEMO_MAX) guardMemo.clear();
        guardMemo.set(b, out);
        return out;
    }

    function shown(name) {
        return String(name == null ? '' : name).replace(BIDI_ALL, '').replace(BREAKS, ' ');
    }

    function balanced(text) {
        let open = 0;
        const out = String(text).replace(ISOLATE_MARK, (c) => {
            if (c !== '\u2069') { open++; return c; }
            if (!open) return '';
            open--;
            return c;
        });
        return open ? out + '\u2069'.repeat(open) : out;
    }

    function sqRaw(baseHtml, suffixHtml, firstLetter, baseClass) {
        const f = firstLetter ? ' data-f="' + esc(firstLetter) + '"' : '';
        return '<span class="nym-sq"' + f + '><span class="nym-b' + (baseClass ? ' ' + esc(baseClass) : '') + '">' + shown(baseHtml) + '</span>' + (suffixHtml ? '<span class="' + CLASS + '">' + suffixHtml + '</span>' : '') + '</span>';
    }

    function sqHtml(base, suffix, baseClass) {
        const b = capBase(shown(base));
        const m = /^#?([0-9a-f]{4})$/i.exec(String(suffix == null ? '' : suffix));
        return sqRaw(esc(b), m ? '#' + m[1] : '', guard(b), baseClass);
    }

    function sqLabelHtml(label) {
        const p = split(label);
        return p ? sqHtml(p.base, p.suffix) : sqHtml(label, '');
    }

    function sqPubkeyHtml(name, pubkey) {
        const t = remember(pubkey);
        if (!t) return sqLabelHtml(name);
        return sqHtml(strip(name), '#' + t);
    }

    function squeeze(el, base, suffix) {
        if (el) el.innerHTML = sqHtml(base, suffix);
        return el;
    }

    function html(base, suffix) {
        const m = /^#?([0-9a-f]{4})$/i.exec(String(suffix == null ? '' : suffix));
        if (!m) return '<bdi>' + esc(shown(base)) + '</bdi>';
        return '<span class="' + LABEL_CLASS + '"><bdi>' + esc(shown(base)) + '</bdi><span class="' + CLASS + '">#' + m[1] + '</span></span>';
    }

    function labelHtml(label) {
        const p = split(label);
        return p ? html(p.base, p.suffix) : esc(label);
    }

    function pubkeyHtml(name, pubkey) {
        const t = remember(pubkey);
        if (!t) return labelHtml(name);
        return html(strip(name), '#' + t);
    }

    function listHtml(labels, sep) {
        return (labels || []).map((l) => (split(l) ? labelHtml(l) : '<bdi>' + esc(shown(l)) + '</bdi>')).join(esc(sep == null ? ', ' : sep));
    }

    function knownSet(k) {
        if (k === true) return known();
        const out = new Set();
        if (!k) return out;
        for (const v of k) {
            const t = tail(v);
            if (t) out.add(t);
        }
        return out;
    }

    function inLink(s, at) {
        let i = at;
        while (i > 0 && !/\s/.test(s.charAt(i - 1))) i--;
        return s.slice(i, at).indexOf('/') >= 0;
    }

    function ranges(text, knownSuffixes) {
        const s = String(text == null ? '' : text);
        const out = [];
        if (!s) return out;
        for (const m of s.matchAll(MENTION)) {
            const end = m.index + m[0].length;
            out.push([end - 5, end]);
        }
        const any = knownSuffixes === '*';
        const k = any ? null : knownSet(knownSuffixes);
        if (any || k.size) {
            for (const m of s.matchAll(GLUED)) {
                if (!any && !k.has(m[1].toLowerCase())) continue;
                const at = m.index;
                if (inLink(s, at) || out.some((r) => r[0] === at)) continue;
                out.push([at, at + 5]);
            }
        }
        return out.sort((a, b) => a[0] - b[0]);
    }

    function isoRuns(s) {
        const out = [];
        if (s.indexOf('\u2068') < 0) return out;
        const open = [];
        for (let i = 0; i < s.length; i++) {
            const c = s.charCodeAt(i);
            if (c >= 0x2066 && c <= 0x2068) open.push(i);
            else if (c === 0x2069 && open.length) {
                const a = open.pop();
                if (!open.length && s.charCodeAt(a) === 0x2068) out.push([a, i + 1]);
            }
        }
        return out;
    }

    function pieces(text, knownSuffixes, labels, nested) {
        const s = String(text == null ? '' : text);
        const marks = [];
        const taken = (a, b) => marks.some((m) => a < m.to && b > m.from);
        for (const [a, b] of nested ? [] : isoRuns(s)) {
            const inner = s.slice(a + 1, b - 1);
            if (!shown(inner).trim()) continue;
            const one = pieces(inner, knownSuffixes, labels, true);
            let lab = one.length === 1 && one[0].base ? one[0] : null;
            if (!lab && one.length === 2 && one[0].text !== undefined && one[0].text.trim() && !one[1].base && one[1].suffix) lab = { base: one[0].text, suffix: one[1].suffix };
            const tag = lab && lab.suffix ? null : AFTER_ISOLATE.exec(s.slice(b, b + 6));
            marks.push({ from: a, to: b + (tag ? tag[0].length : 0), base: lab ? lab.base : inner, suffix: lab && lab.suffix ? lab.suffix : (tag ? tag[0] : '') });
        }
        const list = Array.from(new Set((labels || []).map((l) => String(l == null ? '' : l)))).filter((l) => {
            const m = CAPPED.exec(l);
            return !!m && !!m[1].trim();
        }).sort((a, b) => b.length - a.length);
        for (const l of list) {
            for (let i = s.indexOf(l); i >= 0; i = s.indexOf(l, i + 1)) {
                const end = i + l.length;
                if (!/[0-9a-z_]/i.test(s.charAt(end)) && !/[\p{L}\p{N}_]/u.test(s.charAt(i - 1)) && !inLink(s, i) && !taken(i, end)) marks.push({ from: i, cut: end - 5, to: end });
            }
        }
        for (const m of s.matchAll(MENTION)) {
            const end = m.index + m[0].length;
            if (!taken(m.index + 1, end)) marks.push({ from: m.index + 1, cut: end - 5, to: end });
        }
        for (const r of ranges(s, knownSuffixes)) {
            if (!taken(r[0], r[1])) marks.push({ from: r[0], cut: r[0], to: r[1] });
        }
        marks.sort((a, b) => a.from - b.from);
        const out = [];
        let at = 0;
        for (const m of marks) {
            if (m.from > at) out.push({ text: s.slice(at, m.from) });
            out.push(m.base !== undefined ? { base: m.base, suffix: m.suffix } : { base: s.slice(m.from, m.cut), suffix: s.slice(m.cut, m.to) });
            at = m.to;
        }
        if (at < s.length) out.push({ text: s.slice(at) });
        return out;
    }

    function textHtml(text, knownSuffixes, labels) {
        let out = '';
        for (const p of pieces(text, knownSuffixes, labels)) {
            if (p.text !== undefined) out += BIDI.test(p.text) ? '<span class="' + SEG_CLASS + '">' + esc(balanced(p.text)) + '</span>' : esc(p.text);
            else if (p.base) out += '<span class="' + LABEL_CLASS + '"><bdi>' + esc(shown(p.base)) + '</bdi>' + (p.suffix ? '<span class="' + CLASS + '">' + esc(p.suffix) + '</span>' : '') + '</span>';
            else out += '<span class="' + CLASS + '">' + esc(p.suffix) + '</span>';
        }
        return out;
    }

    function dimHtml(html, knownSuffixes) {
        const any = knownSuffixes === '*';
        const k = any ? new Set() : knownSet(knownSuffixes);
        const src = String(html == null ? '' : html);
        if (!any && !k.size) return src;
        let skip = 0;
        return src.split(/(<[^>]*>)/).map((part) => {
            if (part.charAt(0) === '<') {
                const m = /^<(\/?)([a-z0-9]+)/i.exec(part);
                if (m && /^(code|pre|a)$/i.test(m[2]) && !/\/>$/.test(part)) skip = Math.max(0, skip + (m[1] ? -1 : 1));
                return part;
            }
            if (skip || part.indexOf('#') < 0) return part;
            return part.replace(GLUED, (all, hex, at) => (!inLink(part, at) && (any || k.has(hex.toLowerCase())) ? '<span class="' + CLASS + '">' + all + '</span>' : all));
        }).join('');
    }

    function render(el, text, knownSuffixes, labels) {
        if (!el) return el;
        const doc = el.ownerDocument || G.document;
        const span = (cls, t) => {
            const n = doc.createElement('span');
            n.className = cls;
            if (t !== undefined) n.textContent = t;
            return n;
        };
        el.textContent = '';
        for (const p of pieces(text, knownSuffixes, labels)) {
            if (p.text !== undefined) {
                el.appendChild(BIDI.test(p.text) ? span(SEG_CLASS, balanced(p.text)) : doc.createTextNode(p.text));
            } else if (p.base) {
                const label = span(LABEL_CLASS);
                const bdi = doc.createElement('bdi');
                bdi.textContent = shown(p.base);
                label.appendChild(bdi);
                if (p.suffix) label.appendChild(span(CLASS, p.suffix));
                el.appendChild(label);
            } else {
                el.appendChild(span(CLASS, p.suffix));
            }
        }
        return el;
    }

    G.NymSuffix = { CLASS, MAX, cap, capBase, cutAt, fitInsert, fitComposed, wellFormed, initial, labelText, guard, shown, sqRaw, sqHtml, sqLabelHtml, sqPubkeyHtml, squeeze, split, strip, suffixOf, remember, known, html, labelHtml, pubkeyHtml, listHtml, ranges, textHtml, dimHtml, render };
})();
