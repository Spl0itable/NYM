// highlight-worker.js - Off-main-thread syntax highlighting for fenced code

importScripts('/js/modules/syntax-highlight.js');

self.onmessage = (e) => {
    const d = e.data || {};
    let html = null;
    try {
        // lang arrives pre-normalized from the main thread.
        if (self.NymHighlight && d.lang) html = self.NymHighlight.highlight(d.code, d.lang);
    } catch (_) { html = null; }
    self.postMessage({ seq: d.seq, html });
};
