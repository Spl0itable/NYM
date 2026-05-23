(function () {
    try {
        var loggedIn = localStorage.getItem('nym_nostr_login_method') !== null
            || localStorage.getItem('nym_auto_ephemeral') === 'true';
        if (!loggedIn) {
            var sm = document.getElementById('setupModal');
            if (sm) sm.classList.add('active');
        }
    } catch (e) {
        var sm2 = document.getElementById('setupModal');
        if (sm2) sm2.classList.add('active');
    }
})();

(function () {
    var links = document.querySelectorAll('link[data-defer-media]');
    for (var i = 0; i < links.length; i++) {
        (function (link) {
            var apply = function () { link.media = link.getAttribute('data-defer-media') || 'all'; };
            if (link.sheet) apply();
            else link.addEventListener('load', apply, { once: true });
        })(links[i]);
    }
})();
