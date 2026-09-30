// Decide before first paint so the logged-out app doesn't flash before the setup modal.
(function () {
    var needsSetup;
    try {
        needsSetup = localStorage.getItem('nym_nostr_login_method') === null
            && localStorage.getItem('nym_auto_ephemeral') !== 'true';
    } catch (e) {
        needsSetup = true;
    }
    if (!needsSetup) return;
    document.documentElement.classList.add('nym-needs-setup');
    document.addEventListener('DOMContentLoaded', function () {
        var modal = document.getElementById('setupModal');
        if (modal) modal.classList.add('active');
        document.documentElement.classList.remove('nym-needs-setup');
    });
})();
