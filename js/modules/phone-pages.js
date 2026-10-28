(function () {
    'use strict';

    var PHONE_MAX = 768;
    var LAST_VIEW_KEY = 'nym_last_view';
    var mq = window.matchMedia ? window.matchMedia('(max-width: ' + PHONE_MAX + 'px)') : null;
    var ignorePops = 0;
    var listWasOpen = null;
    var allowClose = 0;
    var layerWasOpen = false;
    var LAYERS = '.modal.active, .shop-modal.active, .geohash-explorer-modal.active, [data-sheet].active';
    var STYLE_LAYERS = '#geohashExplorerModal, #shopModal, .modal[data-sheet]';
    var NAV = ['switchChannel', 'openPM', 'openUserPM', 'openGroup', 'navigateToLatestPMOrGroup'];
    var HOME = 'nymchat';
    var lastPlace = null;

    function phone() {
        return mq ? mq.matches : window.innerWidth <= PHONE_MAX;
    }

    function sidebar() { return document.getElementById('sidebar'); }
    function main() { return document.querySelector('.main-content'); }
    function groupMenu() { return document.getElementById('groupContextMenu'); }

    function listOpen() {
        var s = sidebar();
        return !!(s && s.classList.contains('open'));
    }

    function groupOpen() {
        var g = groupMenu();
        return !!(g && g.classList.contains('active') && !g.classList.contains('docked'));
    }

    function pageState() {
        var s = history.state;
        return s && typeof s === 'object' ? s._nym_phone || null : null;
    }

    function navIndex() {
        var n = window.nym;
        return n && typeof n.navigationIndex === 'number' ? n.navigationIndex : -1;
    }

    function navId() {
        var n = window.nym;
        var e = n && n.navigationHistory ? n.navigationHistory[n.navigationIndex] : null;
        return e ? e._navId : null;
    }

    function depth() {
        var s = history.state;
        return s && typeof s === 'object' && s._nym_phone ? (s._nym_depth || 1) : 0;
    }

    var gesture = false;
    var pendingKind = null;

    function wanted(kind) {
        if (!phone()) return false;
        if (kind === 'modal') return openLayers().length > 0 && pageState() !== 'modal';
        if (kind === 'info') return groupOpen() && pageState() !== 'info';
        return !listOpen() && pageState() !== 'chat';
    }

    function noteGesture(e) {
        if (!e.isTrusted) return;
        gesture = true;
        if (!pendingKind) return;
        var kind = pendingKind;
        pendingKind = null;
        if (wanted(kind)) pushPage(kind);
    }

    function pushPage(kind) {
        var base = history.state && typeof history.state === 'object' ? history.state : {};
        var fields = { _nym_nav: navIndex(), _nym_nav_id: navId(), _nym_phone: kind };
        if (!gesture) {
            if (pageState() === kind) {
                try { history.replaceState(Object.assign({}, base, fields, { _nym_depth: depth() || 1 }), ''); } catch (_) { }
            } else {
                pendingKind = kind;
            }
            return;
        }
        gesture = false;
        pendingKind = null;
        try { history.pushState(Object.assign({}, base, fields, { _nym_depth: depth() + 1 }), ''); } catch (_) { }
    }

    function popToBase() {
        var d = depth();
        if (d < 1) return;
        ignorePops++;
        try { history.go(-d); } catch (_) { ignorePops--; }
    }

    var pendingJump = null;

    function jumpBack(n, i) {
        if (!n || i < 0 || i >= n.navigationIndex) return;
        var target = n.navigationHistory[i];
        if (!target) return;
        if (pageState() !== 'chat') { pendingJump = target._navId; return; }
        var steps = n.navigationIndex - i;
        var d = depth();
        if (steps <= d - 1) {
            try { history.go(-steps); } catch (_) { }
            return;
        }
        pendingJump = target._navId;
        try { history.go(-d); } catch (_) { pendingJump = null; }
    }

    function syncChatEntry() {
        var n = window.nym;
        if (!n || !phone() || listOpen() || pageState() !== 'chat') return;
        if (pendingJump) {
            var want = pendingJump;
            pendingJump = null;
            var idx = n.navigationHistory.findIndex(function (e) { return e && e._navId === want; });
            if (idx >= 0) { jumpBack(n, idx); return; }
        }
        if (navId() && history.state._nym_nav_id !== navId()) pushPage('chat');
    }

    function stepFromBase(n) {
        var want = pendingJump;
        pendingJump = null;
        var list = n.navigationHistory || [];
        var idx = want ? list.findIndex(function (e) { return e && e._navId === want; }) : n.navigationIndex - 1;
        if (idx < 0 || idx >= n.navigationIndex || !list[idx]) return false;
        n.navigationIndex = idx;
        n._navigateTo(list[idx]);
        if (typeof n._updateNavButtons === 'function') n._updateNavButtons();
        return true;
    }

    function navKey(e) {
        return [e.type, e.channel || '', e.geohash || '', e.pubkey || '', e.groupId || '', e.rootId || ''].join(':');
    }

    function recentIndexes(n) {
        var list = n.navigationHistory || [];
        var cur = list[n.navigationIndex];
        var ck = cur ? navKey(cur) : '';
        var seen = {};
        var out = [];
        for (var i = n.navigationIndex - 1; i >= 0 && out.length < 10; i--) {
            var e = list[i];
            if (!e || e.type === 'mesh') continue;
            var k = navKey(e);
            if (k === ck || seen[k]) continue;
            seen[k] = 1;
            out.push(i);
        }
        return out;
    }

    function navLabel(n, e) {
        var c = e.type === 'thread' && e.ctx ? e.ctx : e;
        var t = e.type === 'thread' ? (c.type || 'channel') : e.type;
        var label;
        if (t === 'pm') {
            label = c.nym || (typeof n.getNymFromPubkey === 'function' ? n.getNymFromPubkey(c.pubkey) : 'nym');
            if (typeof n.stripPubkeySuffix === 'function') label = n.stripPubkeySuffix(label);
        } else if (t === 'group') {
            var g = n.groupConversations ? n.groupConversations.get(c.groupId) : null;
            label = g ? (typeof n._groupLabel === 'function' ? n._groupLabel(g) : (g.name || ui('Group'))) : ui('Group');
        } else {
            label = '#' + (c.geohash || c.channel || '');
        }
        return e.type === 'thread' ? label + ' · ' + ui('Thread') : label;
    }

    function showRecent() {
        var n = window.nym;
        if (!n) return;
        var idx = recentIndexes(n);
        if (!idx.length) return;
        showActionSheet([{ head: ui('Recent chats') }].concat(idx.map(function (i) {
            return { label: navLabel(n, n.navigationHistory[i]), run: function () { jumpBack(n, i); } };
        })), 'Recent chats');
    }

    function armBackButton(btn) {
        var timer = 0;
        var held = false;
        var clear = function () { if (timer) { clearTimeout(timer); timer = 0; } };
        btn.addEventListener('pointerdown', function (e) {
            if (e.button > 0) return;
            held = false;
            clear();
            timer = setTimeout(function () { timer = 0; held = true; showRecent(); }, 500);
        });
        ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (t) { btn.addEventListener(t, clear); });
        btn.addEventListener('contextmenu', function (e) {
            e.preventDefault();
            clear();
            if (held) return;
            held = true;
            showRecent();
        });
        btn.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopPropagation();
            if (held) { held = false; return; }
            var n = window.nym;
            if (n && typeof n.navigateBack === 'function') n.navigateBack();
        });
    }

    function popPage() {
        ignorePops++;
        try { history.back(); } catch (_) { ignorePops--; }
    }

    function syncInert() {
        var m = main();
        if (!m) return;
        var hide = phone() && listOpen();
        if (hide) {
            if (!m.hasAttribute('inert')) m.setAttribute('inert', '');
            if (m.getAttribute('aria-hidden') !== 'true') m.setAttribute('aria-hidden', 'true');
        } else if (m.hasAttribute('inert') || m.hasAttribute('aria-hidden')) {
            m.removeAttribute('inert');
            m.removeAttribute('aria-hidden');
        }
    }

    function onListChange() {
        var open = listOpen();
        var was = listWasOpen;
        listWasOpen = open;
        syncInert();
        if (!phone() || was === null || was === open) return;
        if (open) {
            if (pageState() === 'chat') popToBase();
        } else if (pageState() !== 'chat') {
            pushPage('chat');
        }
    }

    function openList() {
        var n = window.nym;
        if (listOpen() || !n) return;
        if (typeof n.toggleSidebar === 'function') n.toggleSidebar();
    }

    function styleShown(m) {
        var d = m.style && m.style.display;
        return !!d && d !== 'none';
    }

    function openLayers() {
        var seen = [];
        Array.prototype.forEach.call(document.querySelectorAll(LAYERS), function (m) { seen.push(m); });
        Array.prototype.forEach.call(document.querySelectorAll(STYLE_LAYERS), function (m) {
            if (styleShown(m) && seen.indexOf(m) < 0) seen.push(m);
        });
        return seen.filter(function (m) {
            return m.id !== 'appDialogModal' && m.id !== 'setupModal' && m.isConnected;
        });
    }

    function topLayer() {
        var list = openLayers();
        var best = null;
        var bestZ = -Infinity;
        list.forEach(function (m) {
            var z = parseInt(getComputedStyle(m).zIndex, 10);
            if (isNaN(z)) z = 0;
            if (z >= bestZ) { best = m; bestZ = z; }
        });
        return best;
    }

    function closeLayer(m) {
        if (window.nymSheets && window.nymSheets.isSheet(m)) { window.nymSheets.close(m); return; }
        var vis = function (e) { return e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden'; };
        var closer = Array.prototype.find.call(m.querySelectorAll('[data-sheet-close], .modal-close, .shop-close, .geohash-explorer-close'), vis);
        if (closer) { closer.click(); return; }
        try { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); } catch (_) { }
        if (m.classList.contains('active')) m.classList.remove('active');
    }

    function onLayerChange() {
        var open = openLayers().length > 0;
        var was = layerWasOpen;
        layerWasOpen = open;
        if (!phone() || was === open) return;
        if (open) {
            if (pageState() !== 'modal') pushPage('modal');
        } else if (pageState() === 'modal') {
            popPage();
        }
    }

    function onPop() {
        if (!phone()) return false;
        if (ignorePops > 0) {
            ignorePops--;
            setTimeout(syncChatEntry, 0);
            return true;
        }
        var n = window.nym;
        var layer = topLayer();
        if (layer) {
            layerWasOpen = false;
            closeLayer(layer);
            setTimeout(function () {
                layerWasOpen = openLayers().length > 0;
                if (layerWasOpen && pageState() !== 'modal') pushPage('modal');
            }, 450);
            return true;
        }
        if (groupOpen()) {
            groupWasOpen = false;
            if (n && typeof n.closeGroupContextMenu === 'function') n.closeGroupContextMenu();
            return true;
        }
        if (n && n._meshPageOpen && typeof n.closeMeshPage === 'function') n.closeMeshPage();
        else if (n && !listOpen()) {
            if (pageState() === 'chat') {
                if (!n._navPop(history.state)) syncChatEntry();
                return true;
            }
            if (pendingJump && stepFromBase(n)) {
                pushPage('chat');
                return true;
            }
        }
        if (!listOpen()) {
            listWasOpen = true;
            openList();
            syncInert();
            return true;
        }
        return true;
    }

    var groupWasOpen = false;

    function onGroupChange() {
        var open = groupOpen();
        var was = groupWasOpen;
        groupWasOpen = open;
        if (!phone() || was === open) return;
        if (open) {
            if (pageState() !== 'info') pushPage('info');
        } else if (pageState() === 'info') {
            popPage();
        }
    }

    function onSidebarClick(e) {
        if (!phone() || !listOpen()) return;
        var t = e.target;
        if (!t || !t.closest) return;
        var row = t.closest('.channel-item, .pm-item');
        if (!row || !sidebar().contains(row)) return;
        if (t.closest('.row-menu-btn, .pin-btn, .hide-btn, .section-reorder-btn')) return;
        if (document.body.classList.contains('sidebar-reorder-mode')) return;
        setTimeout(closeList, 0);
    }

    function closeList() {
        var n = window.nym;
        if (!listOpen() || !n || typeof n.closeSidebar !== 'function') return;
        allowClose++;
        try { n.closeSidebar(); } finally { allowClose--; }
    }

    function wrapList() {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype.closeSidebar !== 'function' || NYM.prototype.closeSidebar._phone) return;
        var close = NYM.prototype.closeSidebar;
        var deferred = function (self, fn, args) {
            setTimeout(function () {
                if (!phone() || !listOpen() || openLayers().length || groupOpen()) return;
                allowClose++;
                try { fn.apply(self, args); } finally { allowClose--; }
            }, 0);
        };
        var guardedClose = function () {
            if (phone() && listOpen() && !allowClose) { deferred(this, close, arguments); return; }
            return close.apply(this, arguments);
        };
        guardedClose._phone = true;
        NYM.prototype.closeSidebar = guardedClose;
        var toggle = NYM.prototype.toggleSidebar;
        if (typeof toggle === 'function') {
            NYM.prototype.toggleSidebar = function () {
                if (phone() && listOpen() && !allowClose) { deferred(this, toggle, arguments); return; }
                return toggle.apply(this, arguments);
            };
        }
        NAV.forEach(function (name) {
            var orig = NYM.prototype[name];
            if (typeof orig !== 'function') return;
            NYM.prototype[name] = function () {
                var fromList = phone() && listOpen();
                var r;
                allowClose++;
                try { r = orig.apply(this, arguments); } finally { allowClose--; }
                lastPlace = 'chat';
                if (fromList) closeList();
                return r;
            };
        });
    }

    function closeToPlace() {
        var n = window.nym;
        if (!n || !phone() || !listOpen()) return;
        if (lastPlace === 'mesh' && typeof n.openMeshPanel === 'function' && (typeof n.meshPageAvailable !== 'function' || n.meshPageAvailable())) {
            closeList();
            n.openMeshPanel();
            return;
        }
        if (!lastPlace && (n.inPMMode || (n.currentGeohash || n.currentChannel) !== HOME) && typeof n.switchChannel === 'function') {
            n.switchChannel(HOME, HOME);
        }
        closeList();
    }

    function editable(el) {
        return !!(el && el.matches && el.matches('input, textarea, select, [contenteditable=""], [contenteditable="true"]'));
    }

    function armScrollBlur(s) {
        var moved = false;
        var y0 = 0;
        s.addEventListener('touchstart', function (e) {
            moved = false;
            y0 = e.touches && e.touches[0] ? e.touches[0].clientY : 0;
        }, { passive: true });
        s.addEventListener('touchmove', function (e) {
            var t = e.touches && e.touches[0];
            if (t && Math.abs(t.clientY - y0) > 8) moved = true;
        }, { passive: true });
        s.addEventListener('scroll', function () {
            if (!moved || !phone() || !listOpen()) return;
            var a = document.activeElement;
            if (editable(a) && s.contains(a)) a.blur();
        }, { passive: true, capture: true });
    }

    var SWIPE_SLOP = 10;

    function swipeDistance() {
        var n = window.nym;
        return n && n.swipeThreshold > 0 ? n.swipeThreshold : 50;
    }

    function swipeVelocity() {
        var s = window.nymSheets;
        return s && s.closeVelocity > 0 ? s.closeVelocity : 0.7;
    }

    function scrollsSideways(el, root) {
        for (var e = el; e && e !== root && e.nodeType === 1; e = e.parentElement) {
            if (e.scrollWidth > e.clientWidth + 1) {
                var o = getComputedStyle(e).overflowX;
                if (o === 'auto' || o === 'scroll') return true;
            }
        }
        return false;
    }

    function armSwipeBack(s) {
        var d = null;
        var reset = function () {
            s.style.transition = '';
            s.style.transform = '';
        };
        s.addEventListener('touchstart', function (e) {
            d = null;
            if (!phone() || !listOpen() || !e.touches || e.touches.length !== 1) return;
            if (editable(e.target) || scrollsSideways(e.target, s)) return;
            var t = e.touches[0];
            d = { x: t.clientX, y: t.clientY, dx: 0, live: false, dead: false, hist: [[e.timeStamp || performance.now(), 0]] };
        }, { passive: true });
        s.addEventListener('touchmove', function (e) {
            if (!d || d.dead) return;
            var t = e.touches && e.touches[0];
            if (!t || e.touches.length !== 1) { d.dead = true; if (d.live) reset(); return; }
            var dx = t.clientX - d.x;
            var dy = t.clientY - d.y;
            if (!d.live) {
                if (Math.abs(dx) < SWIPE_SLOP && Math.abs(dy) < SWIPE_SLOP) return;
                if (dx < 0 && Math.abs(dx) > Math.abs(dy) * 1.5) {
                    d.live = true;
                    s.style.transition = 'none';
                } else {
                    d.dead = true;
                    return;
                }
            }
            d.dx = Math.min(0, dx);
            var now = e.timeStamp || performance.now();
            d.hist.push([now, d.dx]);
            while (d.hist.length > 2 && now - d.hist[0][0] > 100) d.hist.shift();
            s.style.transform = 'translateX(' + d.dx + 'px)';
        }, { passive: true });
        var end = function (e) {
            var g = d;
            d = null;
            if (!g || !g.live) return;
            var a = g.hist[0];
            var b = g.hist[g.hist.length - 1];
            var v = b[0] > a[0] ? (b[1] - a[1]) / (b[0] - a[0]) : 0;
            var go = e.type !== 'touchcancel' && g.dx < 0 && (-g.dx >= swipeDistance() || -v >= swipeVelocity());
            if (go) {
                s.style.transition = '';
                closeToPlace();
                requestAnimationFrame(function () { s.style.transform = ''; });
            } else {
                reset();
            }
        };
        s.addEventListener('touchend', end, { passive: true });
        s.addEventListener('touchcancel', end, { passive: true });
    }

    function firstIdentity() {
        var A = window.NymAccounts;
        if (!A || typeof A.read !== 'function') return true;
        try {
            var idx = A.read();
            return !(idx.accounts || []).some(function (a) { return a.pubkey && a.id !== A.pageId; });
        } catch (_) {
            return true;
        }
    }

    function landOnList() {
        var tries = 0;
        var go = function () {
            var n = window.nym;
            var booted = n && n.pubkey && (n.navigationHistory && n.navigationHistory.length > 0 || tries >= 25);
            if (!booted) {
                if (++tries < 50) setTimeout(go, 200);
                return;
            }
            if (!phone() || listOpen()) return;
            lastPlace = null;
            openList();
        };
        go();
    }

    function watchSetup() {
        var m = document.getElementById('setupModal');
        if (!m) return;
        var shown = false;
        var first = false;
        var link = false;
        var check = function () {
            var on = m.classList.contains('active');
            if (on && !shown) {
                shown = true;
                first = firstIdentity();
                link = !!(window.pendingChannel || window.pendingGroupInvite || window.pendingCallLink);
            } else if (!on && shown) {
                shown = false;
                if (first && !link) {
                    lastPlace = null;
                    landOnList();
                }
            }
        };
        check();
        new MutationObserver(check).observe(m, { attributes: true, attributeFilter: ['class'] });
    }

    function viewKey(entry) {
        if (!entry) return null;
        if (entry.type === 'channel') {
            var id = entry.geohash || entry.channel;
            return id ? '#' + id : null;
        }
        if (entry.type === 'pm' && entry.pubkey) return 'pm-' + entry.pubkey;
        if (entry.type === 'group' && entry.groupId) return 'group-' + entry.groupId;
        return null;
    }

    function remember(entry) {
        var key = viewKey(entry);
        if (!key) return;
        try {
            if (localStorage.getItem(LAST_VIEW_KEY) !== key) localStorage.setItem(LAST_VIEW_KEY, key);
        } catch (_) { }
    }

    function parseView(raw) {
        if (!raw || typeof raw !== 'string') return null;
        if (raw.charAt(0) === '#' && raw.length > 1) return { type: 'channel', id: raw.slice(1) };
        if (raw.indexOf('pm-') === 0 && raw.length > 3) return { type: 'pm', id: raw.slice(3) };
        if (raw.indexOf('group-') === 0 && raw.length > 6) return { type: 'group', id: raw.slice(6) };
        return null;
    }

    function botKey(n) {
        return n.verifiedBot && n.verifiedBot.pubkey ? n.verifiedBot.pubkey : null;
    }

    function viewReady(n, v) {
        if (v.type === 'channel') return !(n.blockedChannels && n.blockedChannels.has(v.id.toLowerCase()));
        if (v.type === 'pm') {
            if (v.id === botKey(n)) return true;
            if (n.blockedUsers && n.blockedUsers.has(v.id)) return false;
            if (typeof n._pmPeerHidden === 'function' && n._pmPeerHidden(v.id)) return false;
            return !!(n.pmConversations && n.pmConversations.has(v.id));
        }
        if (v.type === 'group') {
            if (n.leftGroups && n.leftGroups.has(v.id)) return false;
            return !!(n.groupConversations && n.groupConversations.has(v.id));
        }
        return false;
    }

    function openView(n, v) {
        if (v.type === 'channel') {
            if (typeof n.isValidGeohash === 'function' && n.isValidGeohash(v.id)) n.addChannel(v.id, v.id);
            n.switchChannel(v.id, v.id);
        } else if (v.type === 'pm') {
            var conv = n.pmConversations && n.pmConversations.get(v.id);
            var name = v.id === botKey(n) ? 'Nymbot' : (conv && conv.nym) || (typeof n.getNymFromPubkey === 'function' ? n.getNymFromPubkey(v.id) : 'nym');
            if (typeof n.stripPubkeySuffix === 'function') name = n.stripPubkeySuffix(name);
            n.openPM(name, v.id);
        } else if (v.type === 'group') {
            n.openGroup(v.id);
        }
    }

    function sameView(n, v) {
        if (v.type === 'channel') return !n.inPMMode && (n.currentGeohash || n.currentChannel) === v.id;
        if (v.type === 'pm') return !!n.inPMMode && !n.currentGroup && n.currentPM === v.id;
        return !!n.inPMMode && n.currentGroup === v.id;
    }

    function restoreLastView() {
        var n = window.nym;
        if (!n || !phone()) return false;
        var raw = null;
        try { raw = localStorage.getItem(LAST_VIEW_KEY); } catch (_) { }
        var v = parseView(raw);
        if (!v) return false;
        if (v.type === 'channel' && n.settings && n.settings.groupChatPMOnlyMode) return false;
        if (v.type === 'channel' && !viewReady(n, v)) {
            try { localStorage.removeItem(LAST_VIEW_KEY); } catch (_) { }
            return false;
        }
        var moves = n.navigationHistory ? n.navigationHistory.length : 0;
        var tries = 0;
        var attempt = function () {
            if (sameView(n, v)) return;
            if (viewReady(n, v)) { openView(n, v); return; }
            if (++tries > 40) return;
            setTimeout(function () {
                var now = n.navigationHistory ? n.navigationHistory.length : 0;
                if (now > moves + 1) return;
                attempt();
            }, 250);
        };
        attempt();
        return true;
    }

    function ui(s, a) {
        var n = window.nym;
        if (n && typeof n.uiText === 'function') {
            try { return n.uiText(s, a) || s; } catch (_) { }
        }
        return s;
    }

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    }

    function closeActionSheet() {
        var m = document.getElementById('actionSheetModal');
        if (m) m.classList.remove('active');
    }

    var GROUP_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>';

    function groupHead(groupId) {
        var n = window.nym;
        var g = n && n.groupConversations ? n.groupConversations.get(groupId) : null;
        if (!g) return '';
        var max = n.MAX_GROUP_MEMBERS || 100;
        var count = (g.members || []).length;
        var countText = ui('{n}/{max} members', { n: count, max: max }).split('{n}').join(String(count)).split('{max}').join(String(max));
        var fullText = count >= max ? ui('Full') : '';
        var avatar = typeof n.getGroupAvatarUrl === 'function' ? n.getGroupAvatarUrl(groupId) : '';
        var icon = avatar ? '<img src="' + esc(avatar) + '" class="group-ctx-custom-avatar" alt="" decoding="async">' : GROUP_SVG;
        return '<div class="context-menu-avatar-header group-sheet-head" data-sheet-handle>'
            + '<div class="group-ctx-icon' + (avatar ? ' has-image' : '') + '">' + icon + '</div>'
            + '<div class="context-menu-avatar-nym">' + esc((typeof n._groupLabel === 'function' ? n._groupLabel(g) : (g.name || 'Group'))) + '</div>'
            + '<div class="ctx-status-row">' + esc(countText) + (fullText ? ' · <span>' + esc(fullText) + '</span>' : '') + '</div>'
            + '</div>'
            + ((typeof n._groupDescription === 'function' ? n._groupDescription(g) : (g.description || '')) ? '<div class="context-menu-bio">' + esc((typeof n._groupDescription === 'function' ? n._groupDescription(g) : (g.description || ''))) + '</div>' : '');
    }

    function showActionSheet(entries, label, opts) {
        var o = opts || {};
        var list = (entries || []).filter(Boolean);
        if (!list.some(function (e) { return !e.head && !e.sep; })) return false;
        var modal = document.getElementById('actionSheetModal');
        if (!modal) {
            modal = document.createElement('div');
            modal.id = 'actionSheetModal';
            modal.setAttribute('data-sheet', '');
            modal.setAttribute('role', 'dialog');
            document.body.appendChild(modal);
        }
        var head = o.group ? groupHead(o.group) : '';
        modal.className = head ? 'modal action-sheet-modal user-sheet-modal group-sheet-modal' : 'modal msg-sheet-modal action-sheet-modal';
        if (head) modal.setAttribute('data-sheet-expand', '');
        else modal.removeAttribute('data-sheet-expand');
        modal.setAttribute('aria-label', ui(label || 'Conversation menu'));
        var html = head
            ? '<div class="modal-content user-sheet action-sheet group-sheet">'
                + '<button type="button" class="modal-close user-sheet-close" data-sheet-close aria-label="' + esc(ui('Close')) + '">✕</button>'
                + head + '<div class="context-menu-actions msg-sheet-actions">'
            : '<div class="modal-content msg-sheet action-sheet">'
                + '<button type="button" class="modal-close msg-sheet-close" data-sheet-close aria-label="' + esc(ui('Close')) + '">✕</button>'
                + '<div class="msg-sheet-actions">';
        list.forEach(function (e, i) {
            if (e.head) html += '<div class="header-more-head action-sheet-head">' + esc(e.head) + '</div>';
            else if (e.sep) html += '<hr class="header-more-sep action-sheet-sep">';
            else html += '<button type="button" class="msg-sheet-action' + (head ? ' context-menu-item' : '') + (e.cls ? ' ' + esc(e.cls) : '') + '" data-idx="' + i + '"' + (e.disabled ? ' disabled' : '') + '>' + (e.svg || '') + '<span>' + esc(e.label) + '</span></button>';
        });
        html += '</div></div>';
        modal.innerHTML = html;
        modal.querySelector('[data-sheet-close]').onclick = closeActionSheet;
        Array.prototype.forEach.call(modal.querySelectorAll('.msg-sheet-action'), function (b) {
            b.onclick = function (ev) {
                ev.stopPropagation();
                var e = list[parseInt(b.getAttribute('data-idx'), 10)];
                closeActionSheet();
                if (e && typeof e.run === 'function') e.run();
            };
        });
        modal.classList.add('active');
        return true;
    }

    var menuRow = null;
    var menuRowAt = 0;

    function wrapMenus() {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype._showSidebarActionMenu !== 'function' || NYM.prototype._showSidebarActionMenu._phone) return;
        var build = NYM.prototype._buildSidebarMenuItems;
        if (typeof build === 'function') {
            NYM.prototype._buildSidebarMenuItems = function (itemEl) {
                menuRow = itemEl || null;
                menuRowAt = Date.now();
                return build.apply(this, arguments);
            };
        }
        var orig = NYM.prototype._showSidebarActionMenu;
        var wrapped = function (items) {
            if (!phone() || !items || !items.length) return orig.apply(this, arguments);
            document.querySelectorAll('.quick-context-menu').forEach(function (el) { el.remove(); });
            var row = menuRow && Date.now() - menuRowAt < 2000 ? menuRow : null;
            menuRow = null;
            var group = row && row.classList && row.classList.contains('group-item') ? row.dataset.groupId : null;
            showActionSheet(items.map(function (it) {
                return { label: it.label, svg: it.svg, cls: it.cls, run: it.action };
            }), 'Conversation menu', { group: group });
        };
        wrapped._phone = true;
        NYM.prototype._showSidebarActionMenu = wrapped;
    }

    function wrapNav() {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype._pushNavigation !== 'function' || NYM.prototype._pushNavigation._phone) return;
        var orig = NYM.prototype._pushNavigation;
        var wrapped = function (entry) {
            remember(entry);
            if (!phone() || this._navigating) return orig.apply(this, arguments);
            var push = history.pushState;
            try {
                history.pushState = function (state, title) {
                    var base = history.state && typeof history.state === 'object' ? history.state : {};
                    var merged = Object.assign({}, state || {});
                    if (base._nym_phone === 'chat' && !listOpen()) {
                        merged._nym_phone = 'chat';
                        if (!gesture) {
                            merged._nym_depth = depth() || 1;
                            return history.replaceState(merged, title);
                        }
                        gesture = false;
                        merged._nym_depth = depth() + 1;
                        return push.call(history, merged, title);
                    }
                    if (base._nym_phone) {
                        merged._nym_phone = base._nym_phone;
                        merged._nym_depth = base._nym_depth || 1;
                    }
                    return history.replaceState(merged, title);
                };
                return orig.apply(this, arguments);
            } finally {
                history.pushState = push;
            }
        };
        wrapped._phone = true;
        NYM.prototype._pushNavigation = wrapped;
        var back = NYM.prototype.navigateBack;
        if (typeof back === 'function') {
            NYM.prototype.navigateBack = function () {
                if (!phone() || listOpen() || pageState() !== 'chat') return back.apply(this, arguments);
                jumpBack(this, this.navigationIndex - 1);
            };
        }
        NYM.prototype._phonePop = function () { return onPop(); };
        NYM.prototype._restoreLastView = restoreLastView;
        NYM.prototype._isPhoneLayout = phone;
        NYM.prototype._closeChatList = closeToPlace;
        NYM.prototype._closeChatListNow = function () {
            if (!listOpen()) return;
            if (phone()) closeList();
            else if (typeof this.closeSidebar === 'function') this.closeSidebar();
        };
    }

    function start() {
        wrapNav();
        wrapMenus();
        window.nymActionSheet = { show: showActionSheet, close: closeActionSheet, phone: phone };
        ['pointerdown', 'keydown', 'touchend', 'mousedown', 'click'].forEach(function (t) { window.addEventListener(t, noteGesture, true); });
        var pb = document.getElementById('phoneBackBtn');
        if (pb) armBackButton(pb);
        var s = sidebar();
        if (s) {
            listWasOpen = listOpen();
            new MutationObserver(onListChange).observe(s, { attributes: true, attributeFilter: ['class'] });
            s.addEventListener('click', onSidebarClick, true);
            armScrollBlur(s);
            armSwipeBack(s);
        }
        var layerQueued = false;
        var layerObs = new MutationObserver(function () {
            if (layerQueued) return;
            layerQueued = true;
            requestAnimationFrame(function () {
                layerQueued = false;
                if (document.body.classList.contains('mesh-page-open')) lastPlace = 'mesh';
                onLayerChange();
            });
        });
        layerObs.observe(document.body, { subtree: true, attributes: true, attributeFilter: ['class'] });
        Array.prototype.forEach.call(document.querySelectorAll(STYLE_LAYERS), function (el) {
            layerObs.observe(el, { attributes: true, attributeFilter: ['style'] });
        });
        var g = groupMenu();
        if (g) {
            groupWasOpen = groupOpen();
            new MutationObserver(onGroupChange).observe(g, { attributes: true, attributeFilter: ['class'] });
        }
        if (mq) {
            var change = function () { syncInert(); };
            if (typeof mq.addEventListener === 'function') mq.addEventListener('change', change);
            else if (typeof mq.addListener === 'function') mq.addListener(change);
        }
        syncInert();
        watchSetup();
        var tries = 0;
        var arm = function () {
            var n = window.nym;
            if (!n || !n.pubkey) {
                if (++tries < 600) setTimeout(arm, 200);
                return;
            }
            if (phone() && !listOpen() && pageState() !== 'chat') pushPage('chat');
        };
        arm();
    }

    wrapNav();
    wrapMenus();
    if (document.readyState !== 'complete') {
        document.addEventListener('DOMContentLoaded', wrapMenus);
        document.addEventListener('DOMContentLoaded', wrapList);
    } else {
        wrapList();
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
    else start();
})();
