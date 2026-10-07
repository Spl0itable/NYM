(function () {
    const G = typeof self !== 'undefined' ? self : window;
    const PATHS = '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/>'
        + '<path d="M16.6 7.4l2.8-2.8" stroke-width="1.75"/>'
        + '<path d="M17.3 3.5l.5-.5a2.05 2.05 0 0 1 2.9 2.9l-.5.5" stroke-width="1.75"/>'
        + '<path d="M18.7 8.5l-.5.5a2.05 2.05 0 0 1-2.9-2.9l.5-.5" stroke-width="1.75"/>';

    function svg(opts) {
        const o = opts || {};
        const size = o.size ? ` width="${o.size}" height="${o.size}"` : '';
        const cls = o.cls ? ` class="${o.cls}"` : '';
        return `<svg viewBox="0 0 24 24"${size}${cls} fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${PATHS}</svg>`;
    }

    function fill(root) {
        if (!root || !root.querySelectorAll) return;
        root.querySelectorAll('svg[data-call-link-icon]').forEach((el) => {
            const t = el.ownerDocument.createElement('template');
            t.innerHTML = svg({ size: el.getAttribute('width'), cls: el.getAttribute('class') });
            el.replaceWith(t.content.firstChild);
        });
    }

    G.NymCallLinkIcon = { svg, fill };
    if (typeof document !== 'undefined') fill(document);
})();
