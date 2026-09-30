(function () {
    // Mirror js/theme-init.js; 'auto' is left to the stylesheet's prefers-color-scheme.
    try {
        var mode = localStorage.getItem('nym_color_mode');
        if (mode === 'light') document.body.classList.add('nf-light');
        else if (mode === 'dark') document.body.classList.add('nf-dark');
    } catch (_) { }

    var QUIPS = [
        'Nothing here is stored, logged, or found. Two of those are on purpose.',
        'That page was ephemeral. Aggressively ephemeral.',
        'No relay has ever heard of this URL.',
        "You've reached geohash nowhere. Population: you.",
        'This link was gift-wrapped to absolutely nobody.',
        'We asked the mesh. The mesh said no.',
        'Even Nymbot has no idea what this is, and Nymbot has an idea about everything.',
        '404 nyms are typing. None of them exist.',
        'Delivered to /dev/null with end-to-end encryption.',
        'This page guarded its privacy so well that we lost it too.'
    ];

    var quip = document.getElementById('nfQuip');
    if (quip) quip.textContent = QUIPS[Math.floor(Math.random() * QUIPS.length)];

    // textContent, never innerHTML: the path is attacker-controlled.
    var path = document.getElementById('nfPath');
    if (path) {
        var asked = location.pathname + location.search;
        if (asked.length > 48) asked = asked.slice(0, 47) + '…';
        path.textContent = asked;
    }

    var back = document.getElementById('nfBack');
    if (back && history.length > 1) {
        back.hidden = false;
        back.addEventListener('click', function () { history.back(); });
    }
})();
