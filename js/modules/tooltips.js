(function () {
    'use strict';

    var DELAY = 150;
    var WARM = 600;
    var EDGE = 8;
    var GAP = 6;
    var tip = null;
    var owner = null;
    var timer = 0;
    var keyboard = false;
    var warmUntil = 0;

    function hoverCapable() {
        try { return !window.matchMedia || window.matchMedia('(hover: hover), (any-hover: hover)').matches; } catch (_) { return true; }
    }

    function layer() {
        if (tip && tip.isConnected) return tip;
        tip = document.createElement('div');
        tip.className = 'nym-tooltip';
        tip.id = 'nymTooltip';
        tip.setAttribute('role', 'tooltip');
        tip.setAttribute('aria-hidden', 'true');
        document.body.appendChild(tip);
        return tip;
    }

    var CONTROL = 'button, [role="button"], a[data-action], summary, [data-tip]';

    function ui(s) {
        var n = window.nym;
        try { return n && typeof n.uiText === 'function' ? n.uiText(s) : s; } catch (_) { return s; }
    }

    function iconOnly(el) {
        var text = (el.innerText != null ? el.innerText : el.textContent || '').replace(/[\s\u200b]+/g, '');
        if (!text) return true;
        if (/^[0-9+·•]+$/.test(text) && el.querySelector('svg, img, .icon, i')) return true;
        return text.length <= 2 && !/[A-Za-z0-9]/.test(text);
    }

    var NAMES = [
        ['.reaction-btn[data-action="reactionShowPicker"]', 'Add reaction'],
        ['.video-expand-btn', 'Expand video'],
        ['.pm-chip-remove', 'Remove recipient'],
        ['.modal-close', 'Close'],
        ['.shop-close', 'Close']
    ];

    function fallbackName(el) {
        for (var i = 0; i < NAMES.length; i++) {
            try { if (el.matches(NAMES[i][0])) return ui(NAMES[i][1]); } catch (_) { }
        }
        return '';
    }

    function adopt(el) {
        if (!el || el.nodeType !== 1 || el.hasAttribute('data-no-tip') || el.closest('.nym-tooltip')) return;
        var explicit = el.getAttribute('data-tip');
        var title = el.getAttribute('title');
        if (!explicit && !title && !el.getAttribute('aria-label')) {
            var fb = fallbackName(el);
            if (fb) el.setAttribute('aria-label', fb);
        }
        if (explicit) {
            if (title != null) el.removeAttribute('title');
            if (!el.getAttribute('aria-description')) el.setAttribute('aria-description', ui(explicit));
            return;
        }
        if (!iconOnly(el)) return;
        if (title) {
            el.setAttribute('aria-label', title);
            el.removeAttribute('title');
        } else if (title != null) {
            el.removeAttribute('title');
        }
        if (el.getAttribute('aria-label')) {
            if (!el.hasAttribute('data-tip')) el.setAttribute('data-tip', '');
        }
    }

    function scan(root) {
        if (!root || root.nodeType !== 1) return;
        if (root.matches && root.matches(CONTROL)) adopt(root);
        var list = root.querySelectorAll ? root.querySelectorAll(CONTROL) : [];
        for (var i = 0; i < list.length; i++) adopt(list[i]);
    }

    function boot() {
        scan(document.body);
        if (typeof MutationObserver === 'undefined') return;
        new MutationObserver(function (records) {
            for (var i = 0; i < records.length; i++) {
                var r = records[i];
                if (r.type === 'childList') {
                    for (var j = 0; j < r.addedNodes.length; j++) scan(r.addedNodes[j]);
                } else if (r.attributeName === 'title' && r.target.getAttribute('title') != null) {
                    var el = r.target.closest ? r.target.closest(CONTROL) : null;
                    if (el === r.target) adopt(el);
                } else if (r.type === 'characterData' || r.attributeName === 'aria-label') {
                    if (owner && (owner === r.target || owner.contains(r.target))) show(owner);
                }
            }
        }).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['title', 'aria-label'] });
    }

    function textFor(el) {
        var explicit = el.getAttribute('data-tip');
        var label = explicit ? ui(explicit) : (el.getAttribute('aria-label') || '');
        var key = el.getAttribute('data-tip-key') || '';
        return { label: label, key: key };
    }

    function place(el) {
        var t = layer();
        var r = el.getBoundingClientRect();
        var vw = document.documentElement.clientWidth || window.innerWidth;
        var vh = document.documentElement.clientHeight || window.innerHeight;
        var w = t.offsetWidth;
        var h = t.offsetHeight;
        var left = r.left + r.width / 2 - w / 2;
        left = Math.max(EDGE, Math.min(left, vw - w - EDGE));
        var top = r.bottom + GAP;
        if (top + h > vh - EDGE) top = r.top - GAP - h;
        top = Math.max(EDGE, top);
        t.style.left = Math.round(left) + 'px';
        t.style.top = Math.round(top) + 'px';
    }

    function show(el) {
        clearTimeout(timer);
        var parts = textFor(el);
        if (!parts.label || !el.isConnected || !(el.offsetWidth || el.offsetHeight)) return hide();
        var t = layer();
        t.textContent = '';
        var span = document.createElement('span');
        span.textContent = parts.label;
        t.appendChild(span);
        if (parts.key) {
            var k = document.createElement('kbd');
            k.textContent = parts.key;
            t.appendChild(k);
        }
        owner = el;
        t.classList.add('show');
        place(el);
    }

    function hide(warm) {
        clearTimeout(timer);
        if (warm !== true) warmUntil = 0;
        else if (owner) warmUntil = Date.now() + WARM;
        owner = null;
        if (tip) tip.classList.remove('show');
    }

    function tipTarget(node) {
        if (!node || !node.closest) return null;
        var ctl = node.closest(CONTROL);
        if (ctl && !ctl.hasAttribute('data-tip')) adopt(ctl);
        return node.closest('[data-tip]');
    }

    function onOver(e) {
        if (!hoverCapable() || e.pointerType === 'touch') return;
        var el = tipTarget(e.target);
        if (!el) {
            if (owner && !owner.contains(e.target)) hide(true);
            return;
        }
        if (el === owner) return;
        clearTimeout(timer);
        if (owner) hide(true);
        if (Date.now() < warmUntil) show(el);
        else timer = setTimeout(function () { show(el); }, DELAY);
    }

    function onOut(e) {
        var el = tipTarget(e.target);
        if (!el) return;
        if (e.relatedTarget && el.contains(e.relatedTarget)) return;
        if (el === owner || !owner) hide(true);
    }

    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && owner) { hide(); return; }
        if (e.key === 'Tab' || e.key.indexOf('Arrow') === 0) keyboard = true;
    }, true);
    document.addEventListener('pointerdown', function () { keyboard = false; hide(); }, true);
    document.addEventListener('pointerover', onOver, true);
    document.addEventListener('pointerout', onOut, true);
    document.addEventListener('focusin', function (e) {
        var el = tipTarget(e.target);
        if (!el || el !== e.target) return;
        var visible = keyboard;
        try { visible = visible || e.target.matches(':focus-visible'); } catch (_) { }
        if (visible && hoverCapable()) show(el);
    }, true);
    document.addEventListener('focusout', function (e) {
        if (owner && e.target === owner) hide();
    }, true);
    window.addEventListener('scroll', function () { if (owner) place(owner); }, true);
    window.addEventListener('resize', function () { hide(); });
    window.addEventListener('blur', function () { hide(); });

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
    else boot();

    window.NymTooltip = { show: show, hide: hide, scan: scan };
})();
