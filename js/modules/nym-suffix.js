(function () {
    'use strict';
    const G = typeof window !== 'undefined' ? window : globalThis;

    const CLASS = 'nym-suffix';
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

    function html(base, suffix) {
        const m = /^#?([0-9a-f]{4})$/i.exec(String(suffix == null ? '' : suffix));
        if (!m) return esc(base);
        return esc(base) + '<span class="' + CLASS + '">#' + m[1] + '</span>';
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
        return (labels || []).map((l) => '<bdi>' + labelHtml(l) + '</bdi>').join(esc(sep == null ? ', ' : sep));
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

    function ranges(text, knownSuffixes) {
        const s = String(text == null ? '' : text);
        const out = [];
        if (!s) return out;
        for (const m of s.matchAll(MENTION)) {
            const end = m.index + m[0].length;
            out.push([end - 5, end]);
        }
        const k = knownSet(knownSuffixes);
        if (k.size) {
            for (const m of s.matchAll(GLUED)) {
                if (!k.has(m[1].toLowerCase())) continue;
                const at = m.index;
                if (out.some((r) => r[0] === at)) continue;
                out.push([at, at + 5]);
            }
        }
        return out.sort((a, b) => a[0] - b[0]);
    }

    function textHtml(text, knownSuffixes) {
        const s = String(text == null ? '' : text);
        let out = '';
        let at = 0;
        for (const r of ranges(s, knownSuffixes)) {
            out += esc(s.slice(at, r[0])) + '<span class="' + CLASS + '">' + esc(s.slice(r[0], r[1])) + '</span>';
            at = r[1];
        }
        return out + esc(s.slice(at));
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
            return part.replace(GLUED, (all, hex) => (any || k.has(hex.toLowerCase()) ? '<span class="' + CLASS + '">' + all + '</span>' : all));
        }).join('');
    }

    function render(el, text, knownSuffixes) {
        if (!el) return el;
        const s = String(text == null ? '' : text);
        const doc = el.ownerDocument || G.document;
        el.textContent = '';
        let at = 0;
        for (const r of ranges(s, knownSuffixes)) {
            if (r[0] > at) el.appendChild(doc.createTextNode(s.slice(at, r[0])));
            const span = doc.createElement('span');
            span.className = CLASS;
            span.textContent = s.slice(r[0], r[1]);
            el.appendChild(span);
            at = r[1];
        }
        if (at < s.length) el.appendChild(doc.createTextNode(s.slice(at)));
        return el;
    }

    G.NymSuffix = { CLASS, split, strip, suffixOf, remember, known, html, labelHtml, pubkeyHtml, listHtml, ranges, textHtml, dimHtml, render };
})();
