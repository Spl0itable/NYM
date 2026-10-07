(function () {
    'use strict';

    var MODALS = '.modal, .shop-modal, .geohash-explorer-modal';
    var CLOSERS = '.modal-close, .shop-close';
    var FALLBACK_CLOSERS = '[data-action="closeModal"]';
    var HEADERS = '.modal-header, .shop-title, .geohash-explorer-title, .ct-modal-header';
    var PANELS = '.modal-content, .shop-content, .geohash-explorer-content';
    var FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';
    var SKIP = '#imageModal';
    var ANNOUNCE_GAP_MS = 2000;
    var ANNOUNCE_FRESH_S = 120;

    var open = [];
    var lastOutside = null;
    var titleSeq = 0;

    function text(s) {
        var n = window.nym;
        if (n && typeof n.uiText === 'function') {
            try { return n.uiText(s) || s; } catch (_) { }
        }
        return s;
    }

    function shown(el) {
        if (!el || !el.isConnected || el.classList.contains('nm-hidden')) return false;
        var cs = getComputedStyle(el);
        return cs.display !== 'none' && cs.visibility !== 'hidden';
    }

    function visible(el) {
        return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length) && getComputedStyle(el).visibility !== 'hidden';
    }

    function candidate(el) {
        return !!(el && el.nodeType === 1 && el.matches && el.matches(MODALS) && !el.matches(SKIP));
    }

    function panelOf(modal) {
        var kids = modal.children;
        for (var i = 0; i < kids.length; i++) {
            if (kids[i].matches(PANELS)) return kids[i];
        }
        return modal.querySelector(PANELS) || modal;
    }

    function label(modal) {
        if (!modal.hasAttribute('role')) modal.setAttribute('role', 'dialog');
        if (modal.getAttribute('aria-modal') !== 'true') modal.setAttribute('aria-modal', 'true');
        if (!modal.hasAttribute('aria-labelledby') && !modal.hasAttribute('aria-label')) {
            var h = modal.querySelector(HEADERS);
            if (h) {
                if (!h.id) h.id = 'nymDialogTitle' + (++titleSeq);
                modal.setAttribute('aria-labelledby', h.id);
            }
        }
        var closers = modal.querySelectorAll(CLOSERS);
        for (var i = 0; i < closers.length; i++) {
            var c = closers[i];
            if (!c.hasAttribute('aria-label')) c.setAttribute('aria-label', text('Close'));
            if (!c.hasAttribute('title')) c.setAttribute('title', text('Close'));
            if (c.tagName === 'BUTTON' && !c.hasAttribute('type')) c.setAttribute('type', 'button');
        }
    }

    function entryOf(modal) {
        for (var i = 0; i < open.length; i++) if (open[i].modal === modal) return open[i];
        return null;
    }

    function top() {
        for (var i = open.length - 1; i >= 0; i--) {
            if (shown(open[i].modal)) return open[i].modal;
        }
        return null;
    }

    function focusInto(modal) {
        if (modal.contains(document.activeElement)) return;
        var panel = panelOf(modal);
        if (!panel.hasAttribute('tabindex')) panel.setAttribute('tabindex', '-1');
        panel.setAttribute('data-dialog-panel', '');
        try { panel.focus({ preventScroll: true }); } catch (_) { }
    }

    function restore(entry) {
        var a = document.activeElement;
        var lost = !a || a === document.body || a === document.documentElement || entry.modal.contains(a) || !a.isConnected;
        if (!lost) return;
        var t = top();
        var target = entry.opener;
        if (t && !(target && t.contains(target))) target = null;
        if (target && target.isConnected && visible(target)) {
            try { target.focus({ preventScroll: true }); } catch (_) { }
        } else if (t) {
            focusInto(t);
        }
    }

    function opened(modal) {
        label(modal);
        var a = document.activeElement;
        var opener = a && a !== document.body && !modal.contains(a) ? a : lastOutside;
        open.push({ modal: modal, opener: opener });
        setTimeout(function () {
            if (shown(modal) && !modal.classList.contains('is-sheet')) focusInto(modal);
        }, 30);
    }

    function closed(entry) {
        open = open.filter(function (e) { return e !== entry; });
        restore(entry);
    }

    function sync(modal) {
        if (!candidate(modal)) return;
        var e = entryOf(modal);
        var isOpen = shown(modal);
        if (isOpen && !e) opened(modal);
        else if (!isOpen && e) closed(e);
    }

    function sweep() {
        open.slice().forEach(function (e) { if (!shown(e.modal)) closed(e); });
    }

    function closerOf(modal) {
        var panel = panelOf(modal);
        var list = panel.querySelectorAll(CLOSERS);
        for (var i = 0; i < list.length; i++) if (visible(list[i])) return list[i];
        list = panel.querySelectorAll(FALLBACK_CLOSERS);
        for (var j = 0; j < list.length; j++) if (visible(list[j])) return list[j];
        return null;
    }

    function onKey(e) {
        if (e.defaultPrevented) return;
        var modal = top();
        if (!modal || modal.classList.contains('is-sheet')) return;
        if (e.key === 'Escape') {
            var closer = closerOf(modal);
            if (!closer) return;
            e.preventDefault();
            closer.click();
            setTimeout(sweep, 0);
            return;
        }
        if (e.key !== 'Tab') return;
        var panel = panelOf(modal);
        var items = Array.prototype.filter.call(panel.querySelectorAll(FOCUSABLE), visible);
        if (!items.length) { e.preventDefault(); return; }
        var first = items[0];
        var last = items[items.length - 1];
        var a = document.activeElement;
        if (!panel.contains(a) || a === panel) {
            e.preventDefault();
            (e.shiftKey ? last : first).focus();
        } else if (e.shiftKey && a === first) {
            e.preventDefault();
            last.focus();
        } else if (!e.shiftKey && a === last) {
            e.preventDefault();
            first.focus();
        }
    }

    function onActivate(e) {
        if (e.defaultPrevented || (e.key !== 'Enter' && e.key !== ' ' && e.key !== 'Spacebar')) return;
        var t = e.target;
        if (!t || !t.matches || !t.matches('[role="button"]') || t.matches('button, a, input, select, textarea, [contenteditable="true"]')) return;
        e.preventDefault();
        t.click();
    }

    function onFocusIn(e) {
        var t = e.target;
        if (t && t.closest && !t.closest(MODALS)) lastOutside = t;
    }

    function start() {
        var obs = new MutationObserver(function (muts) {
            var seen = new Set();
            var removed = false;
            muts.forEach(function (m) {
                if (m.type === 'attributes' && m.target === document.documentElement) {
                    document.querySelectorAll(MODALS).forEach(function (x) { if (candidate(x)) seen.add(x); });
                    return;
                }
                if (m.type === 'attributes') { if (candidate(m.target)) seen.add(m.target); return; }
                m.addedNodes.forEach(function (n) {
                    if (n.nodeType !== 1) return;
                    if (candidate(n)) seen.add(n);
                    if (n.firstElementChild && n.querySelectorAll) n.querySelectorAll(MODALS).forEach(function (x) { if (candidate(x)) seen.add(x); });
                });
                if (m.removedNodes.length) removed = true;
            });
            seen.forEach(sync);
            if (removed && open.length) sweep();
        });
        obs.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'style'] });
        obs.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
        document.querySelectorAll(MODALS).forEach(function (m) { if (candidate(m)) { label(m); sync(m); } });
        document.addEventListener('focusin', onFocusIn, true);
        window.addEventListener('keydown', onKey, false);
        document.addEventListener('keydown', onActivate, false);
        ensureAnnouncer();
    }

    function ensureAnnouncer() {
        var el = document.getElementById('messageAnnouncer');
        if (el) return el;
        el = document.createElement('div');
        el.id = 'messageAnnouncer';
        el.className = 'visually-hidden';
        el.setAttribute('role', 'status');
        el.setAttribute('aria-live', 'polite');
        el.setAttribute('aria-atomic', 'true');
        document.body.appendChild(el);
        return el;
    }

    window.nymA11y = { isDialogOpen: function () { return !!top(); }, top: top, label: label };

    if (typeof NYM !== 'undefined') {
        Object.assign(NYM.prototype, {
            _canHover() {
                if (!window.matchMedia) return window.innerWidth > 768;
                return window.matchMedia('(hover: hover)').matches;
            },

            _announceNewMessage(message, el) {
                if (!message || message.isHistorical || message.isOwn || message._threadRender || this._bulkAppending) return;
                if (!el || !el.parentNode || document.hidden) return;
                for (let n = el.nextElementSibling; n; n = n.nextElementSibling) {
                    if (n.hasAttribute('data-message-id') || n.querySelector('[data-message-id]')) return;
                }
                const conv = this.inPMMode ? (this.currentGroup || this.currentPM || '') : (this.currentGeohash || this.currentChannel || '');
                if (conv !== this._a11yConv) {
                    this._a11yConv = conv;
                    this._a11yQuietUntil = Date.now() + 1500;
                }
                if (Date.now() < (this._a11yQuietUntil || 0)) return;
                const at = message.created_at || 0;
                if (!at || Date.now() / 1000 - at > ANNOUNCE_FRESH_S) return;
                const key = message.id || message.nymMessageId;
                if (!key) return;
                const done = this._a11yAnnounced || (this._a11yAnnounced = new Set());
                if (done.has(key)) return;
                done.add(key);
                if (done.size > 500) done.delete(done.values().next().value);
                const shown = typeof this.resolveDisplayNym === 'function' ? this.resolveDisplayNym(message.pubkey, message.author) : message.author;
                const nym = typeof this.parseNymFromDisplay === 'function' ? this.parseNymFromDisplay(shown || '') : (shown || '');
                const body = String(message.content || '').replace(/\s+/g, ' ').trim().slice(0, 160);
                const q = this._a11yQueue || (this._a11yQueue = []);
                q.push({ nym: nym, body: body });
                if (this._a11yTimer) return;
                const wait = Math.max(0, (this._a11yLastAt || 0) + ANNOUNCE_GAP_MS - Date.now());
                if (!wait) { this._a11yFlush(); return; }
                this._a11yTimer = setTimeout(() => { this._a11yTimer = null; this._a11yFlush(); }, wait);
            },

            _a11yFlush() {
                const q = this._a11yQueue || [];
                this._a11yQueue = [];
                if (!q.length) return;
                const el = ensureAnnouncer();
                const one = q[0];
                const msg = q.length === 1
                    ? (one.nym ? one.nym + ': ' : '') + one.body
                    : this.uiText(q.length + ' new messages');
                this._a11yLastAt = Date.now();
                el.textContent = '';
                setTimeout(() => { el.textContent = msg; }, 50);
            }
        });
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
    else start();
})();
