(function () {
    const ICONS = Object.freeze({
        shareNodes: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/></svg>',
        bluetooth: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6.5 6.5 17.5 17.5 12 23 12 1 17.5 6.5 6.5 17.5"/></svg>',
        phone: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/></svg>',
        upload: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>',
        composerImage: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>',
        radar: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.75"/><path d="M12 12 L18.36 5.64"/><circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none"/></svg>',
        qrScan: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8V5a2 2 0 0 1 2-2h3"/><path d="M16 3h3a2 2 0 0 1 2 2v3"/><path d="M21 16v3a2 2 0 0 1-2 2h-3"/><path d="M8 21H5a2 2 0 0 1-2-2v-3"/><rect x="7" y="7" width="3" height="3" rx="0.5"/><rect x="14" y="7" width="3" height="3" rx="0.5"/><rect x="7" y="14" width="3" height="3" rx="0.5"/><path d="M14 14h.01"/><path d="M17 14h.01"/><path d="M17 17h.01"/></svg>',
    });
    const ACTIONS = Object.freeze([
        { id: 'share', order: 10, label: 'Share...', icon: 'shareNodes' },
        { id: 'nearby', order: 20, label: 'Share nearby', icon: 'bluetooth' },
        { id: 'tap', order: 30, label: 'Tap to share', icon: 'phone', platforms: ['android'] },
        { id: 'sticker', order: 40, label: 'Write to NFC sticker', icon: 'upload' },
        { id: 'save', order: 50, label: 'Save QR image', icon: 'composerImage' },
        { id: 'scan', order: 60, label: 'Scan a code', icon: 'qrScan' },
        { id: 'app', order: 70, label: 'Share Nymchat app', icon: 'shareNodes' },
    ]);
    const APP_LINK_LABELS = Object.freeze({
        downloadPage: 'Get Nymchat',
        webApp: 'Web app',
        iosTestFlight: 'App Store (TestFlight)',
        googlePlay: 'Google Play',
        zapstore: 'Zapstore',
    });
    const APP_LINKS = Object.freeze({
        android: ['downloadPage', 'webApp', 'iosTestFlight', 'googlePlay', 'zapstore'],
        ios: ['downloadPage', 'webApp', 'iosTestFlight'],
        web: ['downloadPage', 'webApp', 'iosTestFlight', 'googlePlay', 'zapstore'],
    });
    const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    function svg(name, size, cls) {
        const src = ICONS[name];
        if (!src) return '';
        const px = Number(size) > 0 ? Number(size) : 16;
        const extra = cls ? ` class="${esc(cls)}"` : '';
        return src.replace('<svg ', `<svg width="${px}" height="${px}" aria-hidden="true" focusable="false" data-share-icon="${name}"${extra} `);
    }

    function fill(root) {
        const scope = root || document;
        if (!scope || typeof scope.querySelectorAll !== 'function') return;
        scope.querySelectorAll('[data-share-icon-slot]').forEach((el) => {
            const html = svg(el.dataset.shareIconSlot, el.dataset.size, el.getAttribute('class'));
            if (html) el.outerHTML = html;
        });
    }

    function appLinkChoices(platform, links) {
        const order = APP_LINKS[platform] || APP_LINKS.web;
        return order.filter((k) => links && links[k]).map((k) => ({ id: k, label: APP_LINK_LABELS[k], url: links[k] }));
    }

    function nearbyLabel(nickname, peerID) {
        const n = typeof nickname === 'string' ? nickname.replace(/^[\s\u0085]+|[\s\u0085]+$/g, '') : '';
        return n || peerID;
    }

    window.NymShareUi = Object.freeze({ ICONS, ACTIONS, APP_LINK_LABELS, APP_LINKS, svg, fill, appLinkChoices, nearbyLabel });
    if (typeof document !== 'undefined' && document.readyState && document.readyState !== 'loading') fill(document);
    else if (typeof document !== 'undefined' && typeof document.addEventListener === 'function') document.addEventListener('DOMContentLoaded', () => fill(document));
})();
