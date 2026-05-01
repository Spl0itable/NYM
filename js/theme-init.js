// Apply color mode immediately to prevent flash of wrong theme.
// Loaded as an external script so we can drop 'unsafe-inline' from CSP.
(function () {
    var mode = localStorage.getItem('nym_color_mode') || 'auto';
    var isLight = mode === 'light' || (mode === 'auto' && window.matchMedia('(prefers-color-scheme: light)').matches);
    if (isLight) document.body.classList.add('light-mode');
    // Hide ASCII art logos in NymchatApp shell to prevent flash
    if (/NymchatApp\//i.test(navigator.userAgent)) document.body.classList.add('nymchat-app');
})();
