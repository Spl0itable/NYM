(function () {
    const G = typeof self !== 'undefined' ? self : window;
    const CENTERS = [[12, 5], [12, 12], [12, 19]];

    function svg(opts) {
        const o = opts || {};
        const size = o.size ? ` width="${o.size}" height="${o.size}"` : '';
        const cls = o.cls ? ` class="${o.cls}"` : '';
        const r = o.outline ? 1 : 1.8;
        const dots = CENTERS.map((c) => `<circle cx="${c[0]}" cy="${c[1]}" r="${r}"/>`).join('');
        const paint = o.outline
            ? 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
            : 'fill="currentColor"';
        return `<svg viewBox="0 0 24 24"${size}${cls} ${paint} aria-hidden="true">${dots}</svg>`;
    }

    function fill(root) {
        if (!root || !root.querySelectorAll) return;
        root.querySelectorAll('svg[data-menu-dots-icon]').forEach((el) => {
            const t = el.ownerDocument.createElement('template');
            t.innerHTML = svg({ size: el.getAttribute('width'), cls: el.getAttribute('class'), outline: el.getAttribute('data-menu-dots-icon') === 'outline' });
            el.replaceWith(t.content.firstChild);
        });
    }

    G.NymMenuDotsIcon = { svg, fill };
    if (typeof document !== 'undefined') fill(document);
})();
