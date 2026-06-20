// format-worker.js - Off-main-thread message content formatting.
importScripts('/js/modules/syntax-highlight.js');
importScripts('/js/modules/message-format.js');

let emojiMap = null;

function workerHighlight(rawCode, normLang, trimmed) {
    try {
        if (self.NymHighlight && normLang) {
            return { codeHtml: self.NymHighlight.highlight(rawCode, normLang), hlAttr: '' };
        }
    } catch (_) { }
    return { codeHtml: trimmed, hlAttr: '' };
}

self.onmessage = (e) => {
    const d = e.data || {};
    if (d.op === 'init') {
        emojiMap = d.emojiMap || null;
        self.postMessage({ seq: d.seq, ok: true });
        return;
    }
    const shared = d.ctx || {};
    if (!shared.emojiMap) shared.emojiMap = emojiMap;
    shared.highlightCode = workerHighlight;
    const items = d.items || [];
    const results = [];
    for (let i = 0; i < items.length; i++) {
        const it = items[i];
        let html = null;
        try {
            const ctx = it.quoteFlair ? Object.assign({}, shared, { quoteFlair: it.quoteFlair }) : shared;
            html = self.NymFormat.formatWithQuotes(it.content, ctx, 0);
        } catch (_) { html = null; }
        results.push({ key: it.key, html });
    }
    self.postMessage({ seq: d.seq, results });
};
