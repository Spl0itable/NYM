(function () {
    'use strict';

    var SHEET_MAX = 1024;
    var CLOSE_FRACTION = 0.3;
    var CLOSE_VELOCITY = 0.7;
    var SHEETS = [
        '#newPMModal', '#pollModal', '#p2pTransfersModal', '#relayStatsModal', '#nickEditModal',
        '#accountSwitcherModal', '#eventDetailsModal', '#settingsModal', '#zapModal', '#shareModal',
        '#aboutModal', '#notificationsModal', '#reportModal', '#devNsecModal', '#botModelModal',
        '#botRunsModal', '#botAnonModal', '#shopModal', '#giftShopModal', '#transferModal',
        '#geohashExplorerModal', '#clPromptModal', '.ct-modal', '[data-sheet]'
    ].join(',');
    var PANELS = '.modal-content, .shop-content, .geohash-explorer-content, .cv-tabs-sheet';
    var HANDLES = '.sheet-grabber, .modal-header, .geohash-explorer-header, .shop-header, [data-sheet-handle]';
    var CLOSERS = '.modal-close, .shop-close';
    var TEXT_TYPES = ['', 'text', 'password', 'number', 'email', 'url', 'tel'];
    var IGNORE = '[type="search"], [inputmode="search"], [readonly], [disabled], [data-sheet-ignore], #settingsSearchInput';
    var FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';

    var EXPAND_MAX = 768;
    var HALF = 0.6;
    var mq = window.matchMedia ? window.matchMedia('(max-width: ' + SHEET_MAX + 'px)') : null;
    var phoneMq = window.matchMedia ? window.matchMedia('(max-width: ' + EXPAND_MAX + 'px)') : null;
    var stack = [];
    var drag = null;
    var lastPointer = 0;
    var lastKey = 0;

    function narrow() {
        return mq ? mq.matches : window.innerWidth <= SHEET_MAX;
    }

    function expandable(modal) {
        if (!modal || !modal.hasAttribute || !modal.hasAttribute('data-sheet-expand')) return false;
        return phoneMq ? phoneMq.matches : window.innerWidth <= EXPAND_MAX;
    }

    function sheetState(panel) {
        return panel ? panel.getAttribute('data-sheet-state') || '' : '';
    }

    function setSheetState(panel, st) {
        if (!panel || (!st && !panel.hasAttribute('data-sheet-state'))) return;
        panel.style.height = '';
        panel.style.transform = '';
        if (st) {
            if (panel.getAttribute('data-sheet-state') !== st) panel.setAttribute('data-sheet-state', st);
            if (st === 'half') panel.scrollTop = 0;
        } else if (panel.hasAttribute('data-sheet-state')) {
            panel.removeAttribute('data-sheet-state');
        }
    }

    function reducedMotion() {
        return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    }

    function isOpen(modal) {
        if (!modal || !modal.isConnected) return false;
        if (modal.classList.contains('active')) return true;
        return getComputedStyle(modal).display !== 'none';
    }

    function eligible(modal) {
        return !!(modal && modal.matches && modal.matches(SHEETS));
    }

    function panelOf(modal) {
        var kids = modal.children;
        for (var i = 0; i < kids.length; i++) {
            if (kids[i].matches(PANELS)) return kids[i];
        }
        return modal.querySelector(PANELS);
    }

    function text(s) {
        var n = window.nym;
        if (n && typeof n.uiText === 'function') {
            try { return n.uiText(s) || s; } catch (_) { }
        }
        return s;
    }

    function guardsAll(modal) {
        return modal.id === 'settingsModal' || modal.getAttribute('data-sheet-guard') === 'all';
    }

    function tracked(modal, el) {
        if (!el || !el.matches || el.matches(IGNORE)) return false;
        var tag = el.tagName;
        if (tag === 'TEXTAREA') return true;
        if (tag === 'INPUT') {
            var type = (el.getAttribute('type') || '').toLowerCase();
            if (TEXT_TYPES.indexOf(type) >= 0) return true;
            return guardsAll(modal) && (type === 'checkbox' || type === 'radio' || type === 'range');
        }
        if (tag === 'SELECT') return guardsAll(modal);
        return el.isContentEditable === true;
    }

    function valueOf(el) {
        if (el.isContentEditable) return el.textContent;
        var type = (el.getAttribute('type') || '').toLowerCase();
        if (type === 'checkbox' || type === 'radio') return el.checked ? '1' : '0';
        return el.value;
    }

    function remember(e) {
        var modal = e.target && e.target.closest ? e.target.closest('.modal.is-sheet, .is-sheet') : null;
        if (!modal || !modal._sheet) return;
        var el = e.target;
        if (!tracked(modal, el)) return;
        if (!modal._sheet.orig.has(el)) modal._sheet.orig.set(el, valueOf(el));
    }

    function dirty(modal) {
        var s = modal._sheet;
        if (!s) return false;
        var out = false;
        s.orig.forEach(function (v, el) {
            if (!out && el.isConnected && modal.contains(el) && valueOf(el) !== v) out = true;
        });
        return out;
    }

    function ensureGrabber(panel) {
        if (panel.querySelector(':scope > .sheet-grabber')) return;
        var g = document.createElement('div');
        g.className = 'sheet-grabber';
        g.setAttribute('role', 'button');
        g.setAttribute('aria-label', text('Close sheet'));
        g.tabIndex = -1;
        g.innerHTML = '<span class="sheet-grabber-bar"></span>';
        panel.insertBefore(g, panel.firstChild);
    }

    function attach(modal) {
        var panel = panelOf(modal);
        if (!panel) return;
        if (!modal.classList.contains('is-sheet')) modal.classList.add('is-sheet');
        if (!panel.classList.contains('sheet-panel')) panel.classList.add('sheet-panel');
        ensureGrabber(panel);
        if (!expandable(modal)) setSheetState(panel, '');
        else if (!sheetState(panel)) setSheetState(panel, 'half');
        if (!modal.hasAttribute('role')) modal.setAttribute('role', 'dialog');
        modal.setAttribute('aria-modal', 'true');
        if (!modal._sheet) {
            modal._sheet = { orig: new Map(), opener: document.activeElement };
            panel.classList.remove('sheet-leaving');
            panel.style.transform = '';
            if (!reducedMotion()) {
                panel.classList.remove('sheet-entering');
                void panel.offsetWidth;
                panel.classList.add('sheet-entering');
            }
            if (stack.indexOf(modal) < 0) stack.push(modal);
            setTimeout(function () { focusInto(modal); }, 30);
        }
    }

    function detach(modal, keepState) {
        if (modal.classList.contains('is-sheet')) modal.classList.remove('is-sheet');
        var panel = panelOf(modal);
        if (panel) {
            panel.classList.remove('sheet-panel', 'sheet-entering', 'sheet-leaving', 'sheet-dragging');
            setSheetState(panel, '');
            panel.style.transform = '';
        }
        if (keepState) return;
        var s = modal._sheet;
        modal._sheet = null;
        stack = stack.filter(function (m) { return m !== modal; });
        if (s && s.opener && s.opener.isConnected && typeof s.opener.focus === 'function' && !document.querySelector('.modal.is-sheet')) {
            try { s.opener.focus({ preventScroll: true }); } catch (_) { }
        }
    }

    function sync(modal) {
        if (!eligible(modal)) return;
        var open = isOpen(modal);
        if (open && narrow()) attach(modal);
        else if (open) { if (modal.classList.contains('is-sheet')) detach(modal, true); }
        else if (modal._sheet || modal.classList.contains('is-sheet')) detach(modal, false);
    }

    function syncAll() {
        document.querySelectorAll(SHEETS).forEach(sync);
        stack = stack.filter(function (m) { return m._sheet && m.isConnected; });
    }

    function top() {
        var live = stack.filter(function (m) { return m._sheet && m.isConnected && isOpen(m) && m.classList.contains('is-sheet'); });
        var t = live[live.length - 1] || null;
        if (!t) return null;
        var dlg = document.getElementById('appDialogModal');
        if (dlg && dlg.classList.contains('active')) return null;
        return t;
    }

    function byPointer() {
        return lastKey === 0 || lastPointer > lastKey;
    }

    function focusInto(modal, keyboard) {
        var panel = panelOf(modal);
        if (!panel || panel.contains(document.activeElement)) return;
        if (!panel.hasAttribute('tabindex')) panel.setAttribute('tabindex', '-1');
        if (!panel.hasAttribute('data-dialog-panel')) panel.setAttribute('data-dialog-panel', '');
        var first = !keyboard && byPointer() ? null : Array.prototype.find.call(panel.querySelectorAll(FOCUSABLE), visible);
        try { (first || panel).focus({ preventScroll: true }); } catch (_) { }
    }

    function visible(el) {
        return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length) && getComputedStyle(el).visibility !== 'hidden';
    }

    function finishClose(modal) {
        var panel = panelOf(modal);
        var closer = modal.querySelector('[data-sheet-close]') || (panel && panel.querySelector(':scope > .modal-close, :scope > .shop-close'));
        if (!closer) {
            var all = modal.querySelectorAll(CLOSERS);
            for (var i = 0; i < all.length; i++) { if (visible(all[i])) { closer = all[i]; break; } }
        }
        window._nymSheetClickSuppressUntil = 0;
        if (closer) closer.click();
        if (isOpen(modal) && modal.classList.contains('active')) modal.classList.remove('active');
        if (panel) { panel.classList.remove('sheet-leaving'); panel.style.transform = ''; }
        sync(modal);
    }

    function animateOut(modal) {
        var panel = panelOf(modal);
        if (!panel || reducedMotion()) { finishClose(modal); return; }
        panel.classList.remove('sheet-entering', 'sheet-dragging');
        panel.classList.add('sheet-leaving');
        panel.style.transform = 'translateY(100%)';
        var done = false;
        var end = function () { if (done) return; done = true; finishClose(modal); };
        panel.addEventListener('transitionend', end, { once: true });
        setTimeout(end, 320);
    }

    function snapBack(modal) {
        var panel = panelOf(modal);
        if (!panel) return;
        panel.classList.remove('sheet-dragging');
        panel.style.transform = '';
    }

    function requestClose(modal) {
        if (!modal || !modal._sheet || modal._sheet.asking) return;
        if (!dirty(modal)) { animateOut(modal); return; }
        modal._sheet.asking = true;
        snapBack(modal);
        var ask = typeof window.showAppConfirm === 'function'
            ? window.showAppConfirm(text('You have unsaved input. Close and discard it?'), {
                title: text('Discard changes?'),
                okLabel: text('Discard'),
                cancelLabel: text('Keep'),
                danger: true
            })
            : Promise.resolve(window.confirm(text('Discard changes?')));
        Promise.resolve(ask).then(function (ok) {
            if (modal._sheet) modal._sheet.asking = false;
            if (ok) animateOut(modal);
            else focusInto(modal, true);
        });
    }

    function onPointerDown(e) {
        if (e.button !== undefined && e.button !== 0) return;
        var t = e.target;
        if (!t || !t.closest) return;
        var modal = t.closest('.is-sheet');
        if (!modal || !modal._sheet || modal !== top()) return;
        var panel = panelOf(modal);
        var half = expandable(modal) && sheetState(panel) === 'half';
        var handle = half && panel && panel.contains(t) ? t : t.closest(HANDLES);
        if (!handle || !panel || !panel.contains(handle)) return;
        if (t.closest('button, a, input, select, textarea, [contenteditable="true"]') && !t.closest('.sheet-grabber')) return;
        var h0 = panel.getBoundingClientRect().height || 1;
        drag = { modal: modal, panel: panel, id: e.pointerId, y0: e.clientY, y: e.clientY, t: performance.now(), v: 0, moved: false, h: h0, expand: expandable(modal), from: sheetState(panel), halfH: half ? h0 : Math.round(window.innerHeight * HALF) };
        try { handle.setPointerCapture(e.pointerId); } catch (_) { }
    }

    function onPointerMove(e) {
        if (!drag || e.pointerId !== drag.id) return;
        var now = performance.now();
        var dt = Math.max(1, now - drag.t);
        drag.v = (e.clientY - drag.y) / dt;
        drag.y = e.clientY;
        drag.t = now;
        if (drag.expand) {
            var raw = e.clientY - drag.y0;
            if (!drag.moved && Math.abs(raw) < 4) return;
            drag.moved = true;
            drag.panel.classList.remove('sheet-entering');
            drag.panel.classList.add('sheet-dragging');
            var p = Math.min(window.innerHeight, drag.h - raw);
            if (p >= drag.halfH) {
                drag.panel.style.height = p + 'px';
                drag.panel.style.transform = '';
            } else {
                drag.panel.style.height = drag.halfH + 'px';
                drag.panel.style.transform = 'translateY(' + (drag.halfH - p) + 'px)';
            }
            if (e.cancelable) e.preventDefault();
            return;
        }
        var dy = Math.max(0, e.clientY - drag.y0);
        if (!drag.moved && dy < 4) return;
        drag.moved = true;
        drag.panel.classList.remove('sheet-entering');
        drag.panel.classList.add('sheet-dragging');
        drag.panel.style.transform = 'translateY(' + dy + 'px)';
        if (e.cancelable) e.preventDefault();
    }

    function onPointerUp(e) {
        if (!drag || e.pointerId !== drag.id) return;
        var d = drag;
        drag = null;
        if (!d.moved) {
            if (e.type === 'pointerup' && e.target && e.target.closest && e.target.closest('.sheet-grabber')) requestClose(d.modal);
            return;
        }
        window._nymSheetClickSuppressUntil = Date.now() + 350;
        if (d.expand) { settleExpand(d, e); return; }
        var dy = Math.max(0, e.clientY - d.y0);
        if (e.type !== 'pointercancel' && (dy > d.h * CLOSE_FRACTION || d.v > CLOSE_VELOCITY)) requestClose(d.modal);
        else snapBack(d.modal);
    }

    function settleExpand(d, e) {
        var p = Math.min(window.innerHeight, d.h - (e.clientY - d.y0));
        var full = window.innerHeight;
        var target;
        if (e.type === 'pointercancel') target = d.from || 'half';
        else if (d.v < -0.5) target = 'full';
        else if (d.v > CLOSE_VELOCITY) target = p > d.halfH + 1 ? 'half' : 'close';
        else if (p >= (d.halfH + full) / 2) target = 'full';
        else if (p >= d.halfH * (1 - CLOSE_FRACTION)) target = 'half';
        else target = 'close';
        d.panel.classList.remove('sheet-dragging');
        if (target === 'close') {
            requestClose(d.modal);
            if (d.modal._sheet && d.modal._sheet.asking) setSheetState(d.panel, d.from || 'half');
            return;
        }
        setSheetState(d.panel, target);
    }

    function onFocusIn(e) {
        var t = e.target;
        if (!t || !t.closest) return;
        var modal = t.closest('.is-sheet');
        if (!modal || !modal._sheet || !expandable(modal)) return;
        var panel = panelOf(modal);
        if (!panel || sheetState(panel) !== 'half' || !panel.contains(t) || t === panel) return;
        var r = t.getBoundingClientRect();
        var pr = panel.getBoundingClientRect();
        if (r.bottom > pr.bottom + 0.5 || r.top < pr.top - 0.5) setSheetState(panel, 'full');
    }

    function onClick(e) {
        if (e.isTrusted && window._nymSheetClickSuppressUntil && Date.now() < window._nymSheetClickSuppressUntil) {
            var m = e.target && e.target.closest ? e.target.closest('.is-sheet') : null;
            if (m) { e.stopPropagation(); e.preventDefault(); return; }
        }
        var modal = e.target;
        if (!modal || !modal.classList || !modal.classList.contains('is-sheet') || !modal._sheet) return;
        if (modal !== top()) return;
        e.stopPropagation();
        e.preventDefault();
        requestClose(modal);
    }

    function onKey(e) {
        var modal = top();
        if (!modal) return;
        if (e.key === 'Escape') {
            e.preventDefault();
            e.stopImmediatePropagation();
            var owned = false;
            try {
                var ev = new CustomEvent('nym-sheet-escape', { cancelable: true });
                owned = !modal.dispatchEvent(ev);
            } catch (_) { }
            if (!owned) requestClose(modal);
            return;
        }
        if (e.key !== 'Tab') return;
        var panel = panelOf(modal);
        if (!panel) return;
        var items = Array.prototype.filter.call(panel.querySelectorAll(FOCUSABLE), visible);
        if (!items.length) { e.preventDefault(); return; }
        var first = items[0];
        var last = items[items.length - 1];
        var a = document.activeElement;
        if (!panel.contains(a)) { e.preventDefault(); first.focus(); return; }
        if (a === panel) { e.preventDefault(); (e.shiftKey ? last : first).focus(); return; }
        if (e.shiftKey && a === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && a === last) { e.preventDefault(); first.focus(); }
    }

    function start() {
        var obs = new MutationObserver(function (muts) {
            var seen = new Set();
            muts.forEach(function (m) {
                if (m.type === 'attributes') { if (eligible(m.target)) seen.add(m.target); return; }
                m.addedNodes.forEach(function (n) {
                    if (n.nodeType !== 1) return;
                    if (eligible(n)) seen.add(n);
                    if (n.querySelectorAll) n.querySelectorAll(SHEETS).forEach(function (x) { seen.add(x); });
                });
                m.removedNodes.forEach(function (n) {
                    if (n.nodeType === 1 && n._sheet) detach(n, false);
                });
            });
            seen.forEach(sync);
        });
        obs.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
        document.querySelectorAll(SHEETS).forEach(function (el) {
            obs.observe(el, { attributes: true, attributeFilter: ['style'] });
        });
        window.addEventListener('pointerdown', function () { lastPointer = performance.now(); }, true);
        window.addEventListener('touchstart', function () { lastPointer = performance.now(); }, { capture: true, passive: true });
        window.addEventListener('keydown', function (e) {
            if (e.key === 'Tab' || e.key === 'Enter' || e.key === ' ' || e.key.indexOf('Arrow') === 0 || e.key === 'Escape') lastKey = performance.now();
        }, true);
        document.addEventListener('focusin', remember, true);
        document.addEventListener('focusin', onFocusIn);
        document.addEventListener('pointerdown', remember, true);
        document.addEventListener('keydown', remember, true);
        window.addEventListener('pointerdown', onPointerDown, true);
        window.addEventListener('pointermove', onPointerMove, { capture: true, passive: false });
        window.addEventListener('pointerup', onPointerUp, true);
        window.addEventListener('pointercancel', onPointerUp, true);
        window.addEventListener('click', onClick, true);
        window.addEventListener('keydown', onKey, true);
        [mq, phoneMq].forEach(function (q) {
            if (!q) return;
            var change = function () { syncAll(); };
            if (typeof q.addEventListener === 'function') q.addEventListener('change', change);
            else if (typeof q.addListener === 'function') q.addListener(change);
        });
        syncAll();
    }

    window.nymSheets = {
        closeVelocity: CLOSE_VELOCITY,
        isSheet: function (modal) { return !!(modal && modal.classList && modal.classList.contains('is-sheet')); },
        isDirty: function (modal) { return dirty(modal); },
        close: function (modal) { requestClose(modal); },
        selectors: SHEETS
    };

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
    else start();
})();
