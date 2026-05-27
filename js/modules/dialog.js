// dialog.js - In-app replacements for window.confirm / window.alert
(function () {
    'use strict';

    var pending = null;
    var built = false;

    function ensureModal() {
        if (built) return;
        var wrap = document.createElement('div');
        wrap.innerHTML =
            '<div class="modal app-dialog" id="appDialogModal" role="dialog" aria-modal="true" aria-labelledby="appDialogTitle">' +
                '<div class="modal-content app-dialog-content">' +
                    '<div class="modal-header" id="appDialogTitle">Confirm</div>' +
                    '<div class="modal-body"><div class="app-dialog-message" id="appDialogMessage"></div></div>' +
                    '<div class="modal-actions">' +
                        '<button type="button" class="icon-btn" id="appDialogCancelBtn" data-action="appDialogCancel">Cancel</button>' +
                        '<button type="button" class="send-btn" id="appDialogOkBtn" data-action="appDialogOk">OK</button>' +
                    '</div>' +
                '</div>' +
            '</div>';
        document.body.appendChild(wrap.firstChild);
        built = true;
    }

    function onKey(e) {
        if (!pending) return;
        if (e.key === 'Escape') {
            e.preventDefault();
            settle(pending.alertOnly ? undefined : false);
        } else if (e.key === 'Enter') {
            e.preventDefault();
            settle(pending.alertOnly ? undefined : true);
        }
    }

    function settle(result) {
        if (!pending) return;
        var p = pending;
        pending = null;
        var modal = document.getElementById('appDialogModal');
        if (modal) modal.classList.remove('active');
        document.removeEventListener('keydown', onKey, true);
        try { p.resolve(result); } catch (_) {}
    }

    function open(opts) {
        ensureModal();
        if (pending) settle(pending.alertOnly ? undefined : false);
        return new Promise(function (resolve) {
            pending = { resolve: resolve, alertOnly: !!opts.alertOnly };
            document.getElementById('appDialogTitle').textContent =
                opts.title || (opts.alertOnly ? 'Notice' : 'Confirm');
            document.getElementById('appDialogMessage').textContent = opts.message || '';
            var okBtn = document.getElementById('appDialogOkBtn');
            var cancelBtn = document.getElementById('appDialogCancelBtn');
            okBtn.textContent = opts.okLabel || 'OK';
            cancelBtn.textContent = opts.cancelLabel || 'Cancel';
            cancelBtn.style.display = opts.alertOnly ? 'none' : '';
            okBtn.classList.toggle('danger', !!opts.danger);
            document.getElementById('appDialogModal').classList.add('active');
            document.addEventListener('keydown', onKey, true);
            setTimeout(function () { try { okBtn.focus(); } catch (_) {} }, 30);
        });
    }

    window.showAppConfirm = function (message, opts) {
        opts = opts || {};
        return open({
            message: message,
            title: opts.title,
            okLabel: opts.okLabel,
            cancelLabel: opts.cancelLabel,
            danger: opts.danger
        });
    };

    window.showAppAlert = function (message, opts) {
        opts = opts || {};
        return open({
            alertOnly: true,
            message: message,
            title: opts.title,
            okLabel: opts.okLabel
        });
    };

    var ACTIONS = (window.NYM_ACTIONS = window.NYM_ACTIONS || {});
    ACTIONS.appDialogOk = function () { settle(pending && pending.alertOnly ? undefined : true); };
    ACTIONS.appDialogCancel = function () { settle(pending && pending.alertOnly ? undefined : false); };
})();
