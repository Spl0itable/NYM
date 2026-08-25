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
                        // A value the dialog is ABOUT rather than asking for:
                        // shown selectable, with one-tap copy, so the user is
                        // never told to go find something they are looking at.
                        '<div class="app-dialog-copy nm-hidden" id="appDialogCopyRow">' +
                            '<code class="app-dialog-copy-value" id="appDialogCopyValue"></code>' +
                            '<button type="button" class="pubkey-slideout-copy" id="appDialogCopyBtn">Copy</button>' +
                        '</div>' +
                        '<label class="app-dialog-checkbox nm-hidden" id="appDialogCheckboxRow"><input type="checkbox" id="appDialogCheckbox"><span id="appDialogCheckboxLabel"></span></label>' +
                        '<input type="text" class="form-input app-dialog-input nm-hidden" id="appDialogInput" autocomplete="off">' +
                        '<textarea class="form-textarea app-dialog-textarea nm-hidden" id="appDialogTextarea" rows="4"></textarea>' +
                        '<div class="input-char-count nm-hidden" id="appDialogCharCount"></div>' +
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

    function promptField() {
        return document.getElementById(pending && pending.multiline ? 'appDialogTextarea' : 'appDialogInput');
    }

    function updateDialogCount() {
        var counter = document.getElementById('appDialogCharCount');
        if (!counter || !pending || !pending.maxLength) return;
        var field = promptField();
        var len = (field && field.value) ? field.value.length : 0;
        var max = pending.maxLength;
        counter.textContent = len + '/' + max;
        counter.classList.remove('warning', 'limit');
        if (len >= max) counter.classList.add('limit');
        else if (len >= max * 0.8) counter.classList.add('warning');
    }

    function resultFor(ok) {
        if (!pending) return undefined;
        if (pending.alertOnly) return undefined;
        if (pending.prompt) return ok ? (promptField().value || '') : null;
        if (pending.hasCheckbox) {
            var cb = document.getElementById('appDialogCheckbox');
            return { confirmed: ok, checked: !!(cb && cb.checked) };
        }
        return ok;
    }

    function onKey(e) {
        if (!pending) return;
        if (e.key === 'Escape') {
            e.preventDefault();
            settle(resultFor(false));
        } else if (e.key === 'Enter' && !pending.multiline) {
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
        if (p._countField) { try { p._countField.removeEventListener('input', updateDialogCount); } catch (_) {} }
        try { p.resolve(result); } catch (_) {}
    }

    function open(opts) {
        ensureModal();
        if (pending) settle(resultFor(false));
        return new Promise(function (resolve) {
            pending = { resolve: resolve, alertOnly: !!opts.alertOnly, prompt: !!opts.prompt, multiline: !!opts.multiline, maxLength: opts.maxLength || 0, hasCheckbox: !!opts.checkboxLabel };
            var cbRow = document.getElementById('appDialogCheckboxRow');
            var cb = document.getElementById('appDialogCheckbox');
            if (opts.checkboxLabel) {
                document.getElementById('appDialogCheckboxLabel').textContent = opts.checkboxLabel;
                if (cb) cb.checked = false;
                cbRow.classList.remove('nm-hidden');
            } else {
                cbRow.classList.add('nm-hidden');
            }
            document.getElementById('appDialogTitle').textContent =
                opts.title || (opts.alertOnly ? 'Notice' : 'Confirm');
            document.getElementById('appDialogMessage').textContent = opts.message || '';
            var copyRow = document.getElementById('appDialogCopyRow');
            var copyVal = document.getElementById('appDialogCopyValue');
            var copyBtn = document.getElementById('appDialogCopyBtn');
            if (copyRow && copyVal && copyBtn) {
                if (opts.copyValue) {
                    copyVal.textContent = opts.copyValue;
                    copyBtn.textContent = opts.copyLabel || 'Copy';
                    copyBtn.onclick = function () {
                        try { navigator.clipboard.writeText(opts.copyValue); } catch (_) { }
                        var was = copyBtn.textContent;
                        copyBtn.textContent = 'Copied!';
                        setTimeout(function () { copyBtn.textContent = was; }, 1200);
                    };
                    copyRow.classList.remove('nm-hidden');
                } else {
                    copyVal.textContent = '';
                    copyBtn.onclick = null;
                    copyRow.classList.add('nm-hidden');
                }
            }
            var input = document.getElementById('appDialogInput');
            var textarea = document.getElementById('appDialogTextarea');
            var field = opts.multiline ? textarea : input;
            input.classList.add('nm-hidden');
            textarea.classList.add('nm-hidden');
            var counter = document.getElementById('appDialogCharCount');
            if (counter) counter.classList.add('nm-hidden');
            if (opts.prompt) {
                field.classList.remove('nm-hidden');
                field.value = opts.defaultValue || '';
                field.placeholder = opts.placeholder || '';
                if (opts.maxLength) field.maxLength = opts.maxLength; else field.removeAttribute('maxlength');
                if (opts.maxLength && counter) {
                    counter.classList.remove('nm-hidden');
                    field.addEventListener('input', updateDialogCount);
                    pending._countField = field;
                    updateDialogCount();
                }
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
                try { (opts.prompt ? field : okBtn).focus(); if (opts.prompt) field.select(); } catch (_) {}
            }, 30);
        });
    }

    // With opts.checkboxLabel the promise resolves to { confirmed, checked };
    // otherwise it resolves to a boolean.
    window.showAppConfirm = function (message, opts) {
        opts = opts || {};
        return open({
            message: message,
            title: opts.title,
            okLabel: opts.okLabel,
            cancelLabel: opts.cancelLabel,
            danger: opts.danger,
            checkboxLabel: opts.checkboxLabel
        });
    };

    window.showAppAlert = function (message, opts) {
        opts = opts || {};
        return open({
            alertOnly: true,
            message: message,
            title: opts.title,
            okLabel: opts.okLabel,
            copyValue: opts.copyValue,
            copyLabel: opts.copyLabel
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
            maxLength: opts.maxLength,
            multiline: opts.multiline
        });
    };

    var ACTIONS = (window.NYM_ACTIONS = window.NYM_ACTIONS || {});
    ACTIONS.appDialogOk = function () { settle(resultFor(true)); };
    ACTIONS.appDialogCancel = function () { settle(resultFor(false)); };
})();
