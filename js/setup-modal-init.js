// Show setup modal on first load when no login method is stored
(function () {
    try {
        var loggedIn = localStorage.getItem('nym_nostr_login_method') !== null
            || localStorage.getItem('nym_auto_ephemeral') === 'true';
        if (!loggedIn) {
            document.getElementById('setupModal').classList.add('active');
        }
    } catch (e) {
        document.getElementById('setupModal').classList.add('active');
    }
})();
