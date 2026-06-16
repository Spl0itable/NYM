// Apply color mode immediately to prevent flash of wrong theme.
// Loaded as an external script so we can drop 'unsafe-inline' from CSP.
(function () {
    var mode = localStorage.getItem('nym_color_mode') || 'auto';
    var isLight = mode === 'light' || (mode === 'auto' && window.matchMedia('(prefers-color-scheme: light)').matches);
    if (isLight) document.body.classList.add('light-mode');
    if (localStorage.getItem('nym_transparency_enabled') !== 'true') {
        document.body.classList.add('solid-ui');
    }
    // Hide ASCII art logos in NymchatApp shell to prevent flash
    if (/NymchatApp\//i.test(navigator.userAgent)) document.body.classList.add('nymchat-app');
    // Apply the columns layout up front so a column-view user doesn't see the
    // single chat view flash before columns activate after connection.
    if (localStorage.getItem('nym_chat_view_mode') === 'columns') {
        document.body.classList.add('columns-mode');
    }
})();
