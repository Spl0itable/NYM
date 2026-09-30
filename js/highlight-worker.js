importScripts('/js/modules/syntax-highlight.js');

self.onmessage = (e) => {
    const d = e.data || {};
    let html = null;
    try {
        if (self.NymHighlight && d.lang) html = self.NymHighlight.highlight(d.code, d.lang);
    } catch (_) { html = null; }
    self.postMessage({ seq: d.seq, html });
};
