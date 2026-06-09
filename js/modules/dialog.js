// dialog.js - In-app replacements for window.confirm / window.alert / window.prompt
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
                    '<div class="modal-body">' +
                        '<div class="app-dialog-message" id="appDialogMessage"></div>' +
                        '<input type="text" class="form-input app-dialog-input nm-hidden" id="appDialogInput" autocomplete="off">' +
                    '</div>' +
                    '<div class="modal-actions">' +
                        '<button type="button" class="icon-btn" id="appDialogCancelBtn" data-action="appDialogCancel">Cancel</button>' +
                        '<button type="button" class="send-btn" id="appDialogOkBtn" data-action="appDialogOk">OK</button>' +
                    '</div>' +
                '</div>' +
            '</div>';
        document.body.appendChild(wrap.firstChild);
        built = true;
    }

    function resultFor(ok) {
        if (!pending) return undefined;
        if (pending.alertOnly) return undefined;
        if (pending.prompt) return ok ? (document.getElementById('appDialogInput').value || '') : null;
        return ok;
    }

    function onKey(e) {
        if (!pending) return;
        if (e.key === 'Escape') {
            e.preventDefault();
            settle(resultFor(false));
        } else if (e.key === 'Enter') {
            e.preventDefault();
            settle(resultFor(true));
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
        if (pending) settle(resultFor(false));
        return new Promise(function (resolve) {
            pending = { resolve: resolve, alertOnly: !!opts.alertOnly, prompt: !!opts.prompt };
            document.getElementById('appDialogTitle').textContent =
                opts.title || (opts.alertOnly ? 'Notice' : 'Confirm');
            document.getElementById('appDialogMessage').textContent = opts.message || '';
            var input = document.getElementById('appDialogInput');
            if (opts.prompt) {
                input.classList.remove('nm-hidden');
                input.value = opts.defaultValue || '';
                input.placeholder = opts.placeholder || '';
                if (opts.maxLength) input.maxLength = opts.maxLength; else input.removeAttribute('maxlength');
            } else {
                input.classList.add('nm-hidden');
            }
            var okBtn = document.getElementById('appDialogOkBtn');
            var cancelBtn = document.getElementById('appDialogCancelBtn');
            okBtn.textContent = opts.okLabel || 'OK';
            cancelBtn.textContent = opts.cancelLabel || 'Cancel';
            cancelBtn.style.display = opts.alertOnly ? 'none' : '';
            okBtn.classList.toggle('danger', !!opts.danger);
            document.getElementById('appDialogModal').classList.add('active');
            document.addEventListener('keydown', onKey, true);
            setTimeout(function () {
                try { (opts.prompt ? input : okBtn).focus(); if (opts.prompt) input.select(); } catch (_) {}
            }, 30);
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

    // Resolves to the entered string on OK, or null on cancel.
    window.showAppPrompt = function (message, opts) {
        opts = opts || {};
        return open({
            prompt: true,
            message: message,
            title: opts.title,
            okLabel: opts.okLabel,
            cancelLabel: opts.cancelLabel,
            defaultValue: opts.defaultValue,
            placeholder: opts.placeholder,
            maxLength: opts.maxLength
        });
    };

    var ACTIONS = (window.NYM_ACTIONS = window.NYM_ACTIONS || {});
    ACTIONS.appDialogOk = function () { settle(resultFor(true)); };
    ACTIONS.appDialogCancel = function () { settle(resultFor(false)); };
})();
