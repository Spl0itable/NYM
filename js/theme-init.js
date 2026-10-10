// Applies color mode before paint; external script so CSP can drop 'unsafe-inline'.
(function () {
    var mode = localStorage.getItem('nym_color_mode') || 'auto';
    var isLight = mode === 'light' || (mode === 'auto' && window.matchMedia('(prefers-color-scheme: light)').matches);
    if (isLight) document.body.classList.add('light-mode');
    if (localStorage.getItem('nym_transparency_enabled') !== 'true') {
        document.body.classList.add('solid-ui');
    }
    if (/NymchatApp\//i.test(navigator.userAgent)) document.body.classList.add('nymchat-app');
    if (localStorage.getItem('nym_large_targets') === '1') document.body.classList.add('a11y-targets');
    if (localStorage.getItem('nym_high_contrast') === '1') document.body.classList.add('a11y-contrast');
    // Apply the columns layout up front so column-view users don't see the single view flash first.
    if (localStorage.getItem('nym_chat_view_mode') === 'columns') {
        document.body.classList.add('columns-mode');
    }
})();
