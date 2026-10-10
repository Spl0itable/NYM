(function () {
    'use strict';

    var ACTIONS = (window.NYM_ACTIONS = window.NYM_ACTIONS || {});

    function moreMenu() { return document.getElementById('headerMoreMenu'); }
    function moreBtn() { return document.getElementById('headerMoreBtn'); }

    function closeHeaderMore(restoreFocus) {
        var menu = moreMenu();
        var btn = moreBtn();
        if (!menu || menu.classList.contains('nm-hidden')) return;
        menu.classList.add('nm-hidden');
        if (btn) {
            btn.setAttribute('aria-expanded', 'false');
            if (restoreFocus) { try { btn.focus(); } catch (_) { } }
        }
    }

    function placeHeaderMore() {
        var menu = moreMenu();
        var btn = moreBtn();
        if (!menu || !btn || menu.classList.contains('nm-hidden')) return;
        if (!btn.offsetWidth) { closeHeaderMore(false); return; }
        var gap = 4;
        var edge = 8;
        var r = btn.getBoundingClientRect();
        var w = menu.offsetWidth;
        var h = menu.offsetHeight;
        var vw = document.documentElement.clientWidth || window.innerWidth;
        var vh = document.documentElement.clientHeight || window.innerHeight;
        var left = Math.min(Math.max(edge, r.right - w), Math.max(edge, vw - w - edge));
        var top = r.bottom + gap;
        if (top + h > vh - edge && r.top - gap - h >= edge) top = r.top - gap - h;
        top = Math.max(edge, Math.min(top, vh - h - edge));
        menu.style.left = Math.round(left) + 'px';
        menu.style.top = Math.round(top) + 'px';
    }

    function headerMoreSheet(menu) {
        var sheet = window.nymActionSheet;
        if (!sheet || !sheet.phone()) return false;
        var entries = [];
        Array.prototype.forEach.call(menu.children, function (el) {
            if (el.classList.contains('header-more-head')) entries.push({ head: el.textContent });
            else if (el.classList.contains('header-more-sep')) entries.push({ sep: true });
            else if (el.getAttribute('role') === 'menuitem' && !el.classList.contains('nm-hidden')) {
                var icon = el.querySelector('svg');
                var text = el.querySelector('span');
                entries.push({ label: text ? text.textContent : el.textContent, svg: icon ? icon.outerHTML : '', disabled: el.disabled, cls: el.dataset.uhId ? 'uh-chat-item uh-act-' + el.dataset.uhId : (el.classList.contains('uh-chat-item') ? 'uh-chat-item' : ''), run: function () { el.click(); } });
            }
        });
        var n = window.nym;
        var group = n && !meshMode() && n.inPMMode && n.currentGroup ? n.currentGroup : null;
        return sheet.show(entries, 'More', { group: group });
    }

    function openHeaderMore() {
        var menu = moreMenu();
        var btn = moreBtn();
        if (!menu) return;
        if (menu.parentNode !== document.body) document.body.appendChild(menu);
        buildChatMenu(menu);
        if (headerMoreSheet(menu)) return;
        menu.classList.remove('nm-hidden');
        placeHeaderMore();
        if (btn) btn.setAttribute('aria-expanded', 'true');
        var first = menu.querySelector('[role="menuitem"]');
        if (first) { try { first.focus(); } catch (_) { } }
    }

    ACTIONS.toggleHeaderMore = function () {
        var menu = moreMenu();
        if (!menu) return;
        if (menu.classList.contains('nm-hidden')) openHeaderMore();
        else closeHeaderMore(false);
    };

    document.addEventListener('click', function (e) {
        var menu = moreMenu();
        if (!menu || menu.classList.contains('nm-hidden')) return;
        var btn = moreBtn();
        if (btn && btn.contains(e.target)) return;
        closeHeaderMore(false);
    }, false);

    document.addEventListener('keydown', function (e) {
        var menu = moreMenu();
        if (!menu || menu.classList.contains('nm-hidden')) return;
        if (e.key === 'Escape') {
            e.stopPropagation();
            closeHeaderMore(true);
            return;
        }
        if (e.key === 'Tab' && menu.contains(document.activeElement)) {
            e.preventDefault();
            closeHeaderMore(true);
            return;
        }
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            var items = Array.prototype.slice.call(menu.querySelectorAll('[role="menuitem"]'));
            if (!items.length) return;
            e.preventDefault();
            var i = items.indexOf(document.activeElement);
            var next = e.key === 'ArrowDown' ? (i + 1) % items.length : (i - 1 + items.length) % items.length;
            items[next].focus();
        }
    }, true);

    window.addEventListener('resize', placeHeaderMore);
    document.addEventListener('scroll', placeHeaderMore, true);


    var LM = function () { return window.NymLayoutModel; };
    var HIDE_KEY = 'nym_hide_previews';

    function lsGet(k) { try { return localStorage.getItem(k); } catch (_) { return null; } }
    function lsSet(k, v) { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (_) { } }

    function previewsHidden() { return lsGet(HIDE_KEY) === '1'; }

    function rowConversation(n, item) {
        if (!item || !item.dataset) return null;
        if (item.classList.contains('channel-item')) {
            var gh = item.dataset.geohash || '';
            var ch = item.dataset.channel || '';
            if (!gh && !ch) return null;
            return { kind: 'channel', list: n.messages && n.messages.get(gh ? '#' + gh : ch) };
        }
        if (item.dataset.groupId && typeof n.getGroupConversationKey === 'function') {
            return { kind: 'group', list: n.pmMessages && n.pmMessages.get(n.getGroupConversationKey(item.dataset.groupId)) };
        }
        if (item.dataset.pubkey && typeof n.getPMConversationKey === 'function') {
            return { kind: 'pm', list: n.pmMessages && n.pmMessages.get(n.getPMConversationKey(item.dataset.pubkey)) };
        }
        return null;
    }

    function lastShown(n, list) {
        if (!Array.isArray(list) || typeof n._previewMessage !== 'function') return null;
        return n._previewMessage(list);
    }

    function rowLocked(n, item) {
        try {
            var key = typeof n._clLockKeyForItem === 'function' ? n._clLockKeyForItem(item) : '';
            if (key && window.NymChatLock && typeof n._clState === 'function' && window.NymChatLock.isLocked(n._clState(), key)) return true;
        } catch (_) { }
        try {
            var conv = item.dataset.groupId ? n.getGroupConversationKey(item.dataset.groupId)
                : item.dataset.pubkey ? n.getPMConversationKey(item.dataset.pubkey) : '';
            return !!(conv && typeof n.isConversationLocked === 'function' && n.isConversationLocked(conv));
        } catch (_) { return false; }
    }

    function ensurePreviewEls(item) {
        var name = item.querySelector('.channel-name, .pm-name');
        if (!name) return null;
        var wrap = name.parentElement && name.parentElement.classList.contains('row-text') ? name.parentElement : null;
        if (!wrap) {
            wrap = document.createElement('div');
            wrap.className = 'row-text';
            name.parentNode.insertBefore(wrap, name);
            wrap.appendChild(name);
        }
        var pv = wrap.querySelector(':scope > .row-preview');
        if (!pv) {
            pv = document.createElement('span');
            pv.className = 'row-preview';
            wrap.appendChild(pv);
        }
        var badges = item.querySelector('.channel-badges');
        var tm = badges ? badges.querySelector(':scope > .row-time') : null;
        if (badges && !tm) {
            tm = document.createElement('span');
            tm.className = 'row-time';
            badges.insertBefore(tm, badges.firstChild);
        }
        return { pv: pv, tm: tm };
    }

    function fillDimmed(el, text, dim, from, to) {
        var at = from;
        for (var i = 0; i < dim.length; i++) {
            var a = Math.max(dim[i][0], from);
            var b = Math.min(dim[i][1], to);
            if (b <= a) continue;
            if (a > at) el.appendChild(document.createTextNode(text.slice(at, a)));
            var sfx = document.createElement('span');
            sfx.className = 'nym-suffix';
            sfx.textContent = text.slice(a, b);
            el.appendChild(sfx);
            at = b;
        }
        if (at < to) el.appendChild(document.createTextNode(text.slice(at, to)));
        return el;
    }

    function previewPart(tag, cls) {
        var el = document.createElement(tag);
        el.className = cls;
        return el;
    }

    function paintPreview(pv, text, dim, sender, bodyAt) {
        var at = bodyAt > 1 && bodyAt <= text.length ? bodyAt : 0;
        var sig = text + '\u0000' + JSON.stringify(dim) + '\u0000' + (sender ? sender.join(',') : '') + '\u0000' + at;
        if (pv._lySig === sig) return;
        pv._lySig = sig;
        pv.classList.toggle('has-sender', at > 0);
        var frag = document.createDocumentFragment();
        if (at > 0) {
            var nameEnd = sender ? sender[0] : at - 2;
            var name = previewPart('bdi', 'row-preview-name');
            name.textContent = text.slice(0, nameEnd);
            frag.appendChild(name);
            frag.appendChild(fillDimmed(previewPart('span', 'row-preview-tag'), text, dim, nameEnd, at));
        }
        if (text) {
            var body = fillDimmed(previewPart('span', 'row-preview-body'), text, dim, at, text.length);
            body.setAttribute('dir', 'auto');
            frag.appendChild(body);
        }
        pv.textContent = '';
        pv.appendChild(frag);
    }

    function paintRow(n, item, now, hide, ui) {
        var conv = rowConversation(n, item);
        if (!conv) return;
        var m = lastShown(n, conv.list);
        var els = ensurePreviewEls(item);
        if (!els) return;
        var locked = rowLocked(n, item);
        var text = '';
        var dim = [];
        var sender = null;
        var bodyAt = 0;
        if (m) {
            var body = m.content;
            try { body = typeof n._previewBody === 'function' ? n._previewBody(body) : n._notifPreviewText(body); } catch (_) { }
            var author = m.author || '';
            try {
                if (typeof n.resolveDisplayNym === 'function') author = n.resolveDisplayNym(m.pubkey, m.author);
                else if (typeof n.parseNymFromDisplay === 'function') author = n.parseNymFromDisplay(author);
            } catch (_) { }
            var redacted = '';
            if (locked) { try { redacted = n._clRedactText().body; } catch (_) { redacted = ui('New message'); } }
            var parts = LM().rowPreviewParts({ kind: conv.kind, author: author, pubkey: m.pubkey, self: !!m.isOwn, text: body, hide: hide, locked: locked, redacted: redacted }, ui);
            text = parts.text;
            dim = parts.dim;
            sender = parts.sender || null;
            bodyAt = parts.bodyAt || 0;
        }
        paintPreview(els.pv, text, dim, sender, bodyAt);
        item.classList.toggle('has-preview', !!text);
        var ts = m ? (m._ms || (m.created_at ? m.created_at * 1000 : (m.timestamp instanceof Date ? m.timestamp.getTime() : 0))) : 0;
        var when = ts ? LM().relativeTime(now, ts, ui) : '';
        if (els.tm) {
            if (els.tm.textContent !== when) els.tm.textContent = when;
        }
    }

    var sweepTimer = null;
    function sweepPreviews() {
        sweepTimer = null;
        var n = window.nym;
        if (!n || !LM() || typeof document === 'undefined') return;
        var ui = function (s) { return typeof n.uiText === 'function' ? n.uiText(s) : s; };
        var hide = previewsHidden();
        var now = Date.now();
        var rows = document.querySelectorAll('#channelList .channel-item, #pmList .pm-item');
        for (var i = 0; i < rows.length; i++) {
            try { paintRow(n, rows[i], now, hide, ui); } catch (_) { }
        }
    }

    function schedulePreviews() {
        if (sweepTimer) return;
        sweepTimer = setTimeout(sweepPreviews, 120);
    }

    function wrapPersist(name) {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype[name] !== 'function' || NYM.prototype[name]._lyWrapped) return;
        var orig = NYM.prototype[name];
        var wrapped = function () {
            var r = orig.apply(this, arguments);
            schedulePreviews();
            return r;
        };
        wrapped._lyWrapped = true;
        NYM.prototype[name] = wrapped;
    }

    function bootPreviews() {
        wrapPersist('persistChannelMessages');
        wrapPersist('persistPMMessages');
        var watch = function (id) {
            var el = document.getElementById(id);
            if (!el || el._lyObserved || typeof MutationObserver === 'undefined') return;
            el._lyObserved = true;
            new MutationObserver(function (records) {
                for (var i = 0; i < records.length; i++) {
                    var t = records[i].target;
                    if (t && t.classList && (t.classList.contains('row-preview') || t.classList.contains('row-time'))) continue;
                    schedulePreviews();
                    return;
                }
            }).observe(el, { childList: true, subtree: true });
        };
        watch('channelList');
        watch('pmList');
        setInterval(schedulePreviews, 30000);
        schedulePreviews();
    }


    var OPEN_KEY = 'nym_info_panel_open';
    var PANELS = ['groupContextMenu', 'contextMenu'];
    var lastPanel = null;

    function dockWide() { return LM() ? LM().infoPanelMode(window.innerWidth) === 'docked' : window.innerWidth >= 1280; }
    function panelEl(id) { return document.getElementById(id); }
    function activePanels() { return PANELS.map(panelEl).filter(function (p) { return p && p.classList.contains('active'); }); }

    function currentConv(n) {
        if (!n || !n.inPMMode) return null;
        if (n.currentGroup) return { kind: 'group', id: n.currentGroup };
        if (n.currentPM) return { kind: 'pm', id: n.currentPM };
        return null;
    }

    function panelForConv(n, conv) {
        if (!conv) return null;
        if (conv.kind === 'group') {
            var g = panelEl('groupContextMenu');
            return g && g.classList.contains('active') && n._groupCtxGroupId === conv.id ? g : null;
        }
        var u = panelEl('contextMenu');
        return u && u.classList.contains('active') && n.contextMenuData && n.contextMenuData.pubkey === conv.id ? u : null;
    }

    function openForConv(n, conv) {
        if (!conv) return;
        if (conv.kind === 'group') {
            if (typeof n.showGroupContextMenu === 'function') n.showGroupContextMenu(conv.id);
            return;
        }
        if (typeof n.showContextMenu !== 'function') return;
        var fake = { preventDefault: function () { }, stopPropagation: function () { }, stopImmediatePropagation: function () { } };
        var nymName = typeof n.getNymFromPubkey === 'function' ? n.getNymFromPubkey(conv.id) : 'nym';
        var base = typeof n.stripPubkeySuffix === 'function' ? n.stripPubkeySuffix(nymName) : nymName;
        var suffix = typeof n.getPubkeySuffix === 'function' ? n.getPubkeySuffix(conv.id) : '';
        n.showContextMenu(fake, base + '#' + suffix, conv.id, null, null, true);
    }

    function closePanels(n) {
        try { if (typeof n.closeGroupContextMenu === 'function') n.closeGroupContextMenu(); } catch (_) { }
        try { if (typeof n.closeContextMenu === 'function') n.closeContextMenu(); } catch (_) { }
    }

    function syncInfoBtn() {
        var btn = document.getElementById('infoPanelBtn');
        var n = window.nym;
        if (!btn || !n) return;
        scheduleHeader();
        var conv = currentConv(n);
        btn.classList.toggle('nm-hidden', !conv);
        btn.setAttribute('aria-pressed', conv && panelForConv(n, conv) ? 'true' : 'false');
    }

    function applyDock() {
        var act = activePanels();
        if (act.length > 1 && dockWide()) {
            var older = act.filter(function (p) { return p !== lastPanel; })[0];
            var n = window.nym;
            if (older && n) {
                if (older.id === 'groupContextMenu') { try { n.closeGroupContextMenu(); } catch (_) { } }
                else { try { n.closeContextMenu(); } catch (_) { } }
            }
            act = activePanels();
        }
        var p = act[0] || null;
        var dock = !!p && dockWide() && !p.classList.contains('in-sheet');
        document.documentElement.classList.toggle('info-docked', dock);
        PANELS.forEach(function (id) {
            var el = panelEl(id);
            if (!el) return;
            var on = dock && el === p;
            if (el.classList.contains('docked') !== on) el.classList.toggle('docked', on);
        });
        syncInfoBtn();
    }

    function followConversation() {
        var n = window.nym;
        if (!n) return;
        scheduleHeader();
        syncInfoBtn();
        if (!dockWide() || lsGet(OPEN_KEY) !== '1') return;
        var conv = currentConv(n);
        if (!conv) {
            if (document.documentElement.classList.contains('info-docked')) closePanels(n);
            return;
        }
        if (!panelForConv(n, conv)) openForConv(n, conv);
    }

    ACTIONS.toggleInfoPanel = function () {
        var n = window.nym;
        var conv = currentConv(n);
        if (!conv) return;
        var open = panelForConv(n, conv);
        if (open) {
            if (open.id === 'groupContextMenu') n.closeGroupContextMenu();
            else n.closeContextMenu();
            lsSet(OPEN_KEY, '0');
        } else {
            openForConv(n, conv);
            if (dockWide()) lsSet(OPEN_KEY, '1');
        }
        syncInfoBtn();
    };

    function wrapAfter(name, fn) {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype[name] !== 'function' || NYM.prototype[name]['_ly' + name]) return;
        var orig = NYM.prototype[name];
        var wrapped = function () {
            var r = orig.apply(this, arguments);
            try { setTimeout(fn, 0); } catch (_) { }
            return r;
        };
        wrapped['_ly' + name] = true;
        NYM.prototype[name] = wrapped;
    }

    function bootDock() {
        PANELS.forEach(function (id) {
            var el = panelEl(id);
            if (!el || typeof MutationObserver === 'undefined') return;
            var was = el.classList.contains('active');
            new MutationObserver(function () {
                var now = el.classList.contains('active');
                if (now && !was) lastPanel = el;
                was = now;
                applyDock();
            }).observe(el, { attributes: true, attributeFilter: ['class'] });
        });
        ['openGroup', 'openPM', 'switchChannel'].forEach(function (name) { wrapAfter(name, followConversation); });
        document.addEventListener('click', function (e) {
            if (!document.documentElement.classList.contains('info-docked')) return;
            var t = e.target;
            if (t && t.closest && t.closest('#grpCtxCloseBtn, #ctxCloseBtn')) lsSet(OPEN_KEY, '0');
        }, true);
        document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape' && document.documentElement.classList.contains('info-docked')) lsSet(OPEN_KEY, '0');
        }, true);
        var rt = null;
        window.addEventListener('resize', function () {
            if (rt) return;
            rt = setTimeout(function () { rt = null; applyDock(); }, 100);
        });
        applyDock();
        setTimeout(followConversation, 0);
    }


    var stPane = 'appearance';

    function settingsModal() { return document.getElementById('settingsModal'); }

    function settingsSections(m) {
        return Array.prototype.slice.call(m.querySelectorAll('.settings-section[data-section-key]'));
    }

    function buildSettingsNav(m) {
        var content = m.querySelector('.modal-content');
        if (!content || content.querySelector(':scope > .settings-nav')) return;
        var nav = document.createElement('nav');
        nav.className = 'settings-nav';
        nav.id = 'settingsNav';
        var n = window.nym;
        var ui = function (s) { return n && typeof n.uiText === 'function' ? n.uiText(s) : s; };
        nav.setAttribute('aria-label', ui('Settings sections'));
        settingsSections(m).forEach(function (sec) {
            if (sec.classList.contains('mobile-only')) return;
            var span = sec.querySelector('.settings-section-header span');
            var b = document.createElement('button');
            b.type = 'button';
            b.className = 'settings-nav-item';
            b.dataset.action = 'settingsNavSelect';
            b.dataset.stKey = sec.dataset.sectionKey;
            b.textContent = span ? span.textContent : sec.dataset.sectionKey;
            nav.appendChild(b);
        });
        content.insertBefore(nav, content.firstChild);
    }

    function selectSettingsPane(key) {
        var m = settingsModal();
        if (!m) return;
        var secs = settingsSections(m).filter(function (s) { return !s.classList.contains('mobile-only'); });
        if (!secs.some(function (s) { return s.dataset.sectionKey === key; })) key = secs.length ? secs[0].dataset.sectionKey : '';
        stPane = key;
        secs.forEach(function (s) { s.classList.toggle('st-active', s.dataset.sectionKey === key); });
        m.querySelectorAll('.settings-nav-item').forEach(function (b) {
            var on = b.dataset.stKey === key;
            b.classList.toggle('active', on);
            if (on) b.setAttribute('aria-current', 'true'); else b.removeAttribute('aria-current');
        });
    }

    function applySettingsMode() {
        var m = settingsModal();
        if (!m || !LM()) return;
        var mode = LM().settingsMode(window.innerWidth);
        m.classList.toggle('st-two-pane', mode === 'two-pane');
        m.classList.toggle('st-page', mode === 'page');
        if (mode === 'two-pane') {
            buildSettingsNav(m);
            selectSettingsPane(stPane);
        }
        var input = document.getElementById('settingsSearchInput');
        m.classList.toggle('st-searching', !!(input && input.value.trim()));
    }

    function revealSetting(target) {
        var m = settingsModal();
        if (!m || !target) return;
        var sec = m.querySelector('.settings-section[data-section-key="' + target + '"]');
        var el = null;
        if (!sec) {
            el = document.getElementById(target);
            if (!el && /Select$/.test(target)) el = document.getElementById(target.replace(/Select$/, 'Toggle'));
            sec = el && m.contains(el) ? el.closest('.settings-section[data-section-key]') : null;
        }
        if (!sec) return;
        var input = document.getElementById('settingsSearchInput');
        if (input && input.value) {
            input.value = '';
            if (typeof window.filterSettings === 'function') window.filterSettings('');
        }
        sec.classList.remove('collapsed');
        var hdr = sec.querySelector('.settings-section-header');
        if (hdr) hdr.setAttribute('aria-expanded', 'true');
        if (typeof window.persistSettingsSectionState === 'function') window.persistSettingsSectionState(sec.dataset.sectionKey, false);
        selectSettingsPane(sec.dataset.sectionKey);
        applySettingsMode();
        var group = el ? (el.classList.contains('form-group') ? el : el.closest('.form-group')) : null;
        if (group && typeof group.scrollIntoView === 'function') {
            group.scrollIntoView({ block: 'center' });
            group.classList.add('setting-flash');
            setTimeout(function () { group.classList.remove('setting-flash'); }, 1600);
        } else if (typeof sec.scrollIntoView === 'function') {
            sec.scrollIntoView({ block: 'start' });
        }
    }

    window.openSettingsAt = function (target) {
        var m = settingsModal();
        if (!m) return;
        if (!m.classList.contains('active') && typeof window.showSettings === 'function') {
            Promise.resolve(window.showSettings()).then(function () { setTimeout(function () { revealSetting(target); }, 60); });
        } else {
            revealSetting(target);
        }
    };

    ACTIONS.settingsNavSelect = function (_e, t) {
        var input = document.getElementById('settingsSearchInput');
        if (input && input.value) {
            input.value = '';
            if (typeof window.filterSettings === 'function') window.filterSettings('');
        }
        selectSettingsPane(t && t.dataset.stKey);
        applySettingsMode();
        var m = settingsModal();
        var body = m && m.querySelector('.modal-body');
        if (body) body.scrollTop = 0;
    };

    function bootSettings() {
        var m = settingsModal();
        if (!m) return;
        if (typeof MutationObserver !== 'undefined') {
            var was = m.classList.contains('active');
            new MutationObserver(function () {
                var now = m.classList.contains('active');
                if (now && !was) applySettingsMode();
                was = now;
            }).observe(m, { attributes: true, attributeFilter: ['class'] });
        }
        document.addEventListener('input', function (e) {
            if (e.target && e.target.id === 'settingsSearchInput') applySettingsMode();
        }, false);
        window.addEventListener('resize', function () { applySettingsMode(); });
        applySettingsMode();
    }


    function paintRinging(n) {
        var grid = document.getElementById('callGrid');
        var ac = n && n.activeCall;
        if (!grid) return;
        var want = [];
        if (ac && ac.status === 'outgoing' && Array.isArray(ac.members)) {
            want = ac.members.filter(function (pk) {
                return pk && pk !== n.pubkey && !(ac.peers && ac.peers.has(pk)) && !(n.blockedUsers && n.blockedUsers.has(pk));
            });
        }
        var keep = {};
        want.forEach(function (pk) {
            var id = 'ring-' + (typeof n._safePubkey === 'function' ? n._safePubkey(pk) : pk);
            keep[id] = true;
            var tile = grid.querySelector('[data-tile="' + id + '"]');
            if (!tile) {
                tile = document.createElement('div');
                tile.className = 'call-tile ringing no-video';
                tile.dataset.tile = id;
                var av = document.createElement('img');
                av.className = 'call-tile-avatar';
                av.alt = '';
                var name = document.createElement('div');
                name.className = 'call-tile-name';
                var badge = document.createElement('div');
                badge.className = 'call-tile-ringing';
                badge.textContent = typeof n.uiText === 'function' ? n.uiText('Ringing…') : 'Ringing…';
                tile.appendChild(av);
                tile.appendChild(name);
                tile.appendChild(badge);
                grid.appendChild(tile);
                try { av.src = n.getAvatarUrl(pk); } catch (_) { }
                try { name.innerHTML = n._callNymHtml(pk); } catch (_) { name.textContent = ''; }
            }
        });
        Array.prototype.slice.call(grid.querySelectorAll('.call-tile.ringing')).forEach(function (t) {
            if (!keep[t.dataset.tile]) t.remove();
        });
        grid.dataset.count = String(grid.children.length);
    }

    function bootCalls() {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype._renderCallGrid !== 'function' || NYM.prototype._renderCallGrid._lyRing) return;
        var orig = NYM.prototype._renderCallGrid;
        var wrapped = function () {
            var r = orig.apply(this, arguments);
            try { paintRinging(this); } catch (_) { }
            return r;
        };
        wrapped._lyRing = true;
        NYM.prototype._renderCallGrid = wrapped;
        if (typeof NYM.prototype._setCallStatus === 'function' && !NYM.prototype._setCallStatus._lyRing) {
            var origStatus = NYM.prototype._setCallStatus;
            var ws = function () {
                var r = origStatus.apply(this, arguments);
                try { paintRinging(this); } catch (_) { }
                return r;
            };
            ws._lyRing = true;
            NYM.prototype._setCallStatus = ws;
        }
    }


    ACTIONS.toggleNotifPrefs = function () {
        var panel = document.getElementById('notifPrefs');
        var btn = document.getElementById('notifPrefsBtn');
        if (!panel) return;
        var open = panel.classList.contains('nm-hidden');
        panel.classList.toggle('nm-hidden', !open);
        if (btn) btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    };

    function notifTriple(n, entry) {
        var info = entry && entry.channelInfo;
        if (!info) return ['', '', entry && entry.senderPubkey || ''];
        if (typeof n._clNotifRoute === 'function') {
            try { return n._clNotifRoute(info); } catch (_) { }
        }
        return [info.type || '', info.groupId || info.geohash || info.channel || info.pubkey || '', info.pubkey || ''];
    }

    function notifGroupTitle(n, key, entry, ui) {
        try { if (entry && typeof n._clNotifHidden === 'function' && n._clNotifHidden(entry)) return n._clRedactText().title; } catch (_) { }
        var i = key.indexOf(':');
        var kind = i > 0 ? key.slice(0, i) : key;
        var id = i > 0 ? key.slice(i + 1) : '';
        if (kind === 'channel') return '#' + id;
        if (kind === 'group') {
            var g = n.groupConversations && n.groupConversations.get(id);
            return g ? (typeof n._groupLabel === 'function' ? n._groupLabel(g) : (g.name || 'Group')) : ui('Group');
        }
        if (kind === 'pm') {
            var nymName = typeof n.getNymFromPubkey === 'function' ? n.getNymFromPubkey(id) : '';
            var base = typeof n.stripPubkeySuffix === 'function' ? n.stripPubkeySuffix(nymName) : nymName;
            var suffix = typeof n.getPubkeySuffix === 'function' ? n.getPubkeySuffix(id) : '';
            return base + (suffix ? '#' + suffix : '');
        }
        return ui('Other');
    }

    function groupNotificationList() {
        var n = window.nym;
        var body = document.getElementById('notificationsModalBody');
        if (!n || !body || !LM()) return;
        var ui = function (s) { return typeof n.uiText === 'function' ? n.uiText(s) : s; };
        var items = Array.prototype.slice.call(body.querySelectorAll(':scope > .notification-item'));
        if (!items.length) return;
        var keys = items.map(function (el) {
            var t = notifTriple(n, el._notif);
            return LM().notifGroupKey(t[0], t[1], t[2]);
        });
        var groups = LM().groupNotifications(keys);
        var frag = document.createDocumentFragment();
        groups.forEach(function (g) {
            var wrap = document.createElement('section');
            wrap.className = 'notif-group';
            wrap.dataset.groupKey = g.key;
            var title = document.createElement('div');
            title.className = 'notif-group-title';
            var first = items[g.items[0]];
            var label = notifGroupTitle(n, g.key, first && first._notif, ui);
            if (g.key.indexOf('pm:') === 0 && typeof n.nymLabelHtml === 'function') title.innerHTML = '<bdi>' + n.nymLabelHtml(label) + '</bdi>';
            else title.textContent = label;
            var unread = g.items.filter(function (i) { return !items[i]._notif || !items[i]._notif.viewed; }).length;
            if (unread) {
                var dot = document.createElement('span');
                dot.className = 'notif-group-unread';
                dot.textContent = String(unread);
                dot.setAttribute('aria-label', ui('{n} unread').replace('{n}', String(unread)));
                title.appendChild(dot);
            }
            wrap.appendChild(title);
            g.items.forEach(function (i) { wrap.appendChild(items[i]); });
            frag.appendChild(wrap);
        });
        body.appendChild(frag);
    }

    function bootNotifications() {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype.openNotificationsModal !== 'function' || NYM.prototype.openNotificationsModal._lyGroup) return;
        var orig = NYM.prototype.openNotificationsModal;
        var wrapped = function () {
            var r = orig.apply(this, arguments);
            try { groupNotificationList(); } catch (_) { }
            return r;
        };
        wrapped._lyGroup = true;
        NYM.prototype.openNotificationsModal = wrapped;
        if (typeof NYM.prototype.markAllNotificationsRead === 'function' && !NYM.prototype.markAllNotificationsRead._lyGroup) {
            var origMark = NYM.prototype.markAllNotificationsRead;
            var mark = function () {
                var r = origMark.apply(this, arguments);
                document.querySelectorAll('#notificationsModalBody .notif-group-unread').forEach(function (d) { d.remove(); });
                return r;
            };
            mark._lyGroup = true;
            NYM.prototype.markAllNotificationsRead = mark;
        }
    }


    function composerOverlayOpen(n) {
        if (n && n.enhancedEmojiModal) return true;
        var gif = document.getElementById('gifPicker');
        if (gif && gif.classList.contains('active')) return true;
        var tr = document.getElementById('translateInputDropdown');
        if (tr && tr.classList.contains('active')) return true;
        var ts = document.getElementById('timestampPicker');
        return !!(ts && !ts.classList.contains('nm-hidden'));
    }

    function applyToolbarFocus(n) {
        var toolbar = document.getElementById('formatToolbar');
        var input = document.getElementById('messageInput');
        if (!toolbar || !input || !LM()) return;
        var box = toolbar.closest('.input-container');
        var draft = !!(box && box.classList.contains('composer-pill'));
        var focused = !!(box && box.contains(document.activeElement));
        var show = LM().formatToolbarVisible({ draft: draft, focused: focused, overlay: composerOverlayOpen(n) });
        if (toolbar.classList.contains('nm-hidden') !== !show) {
            toolbar.classList.toggle('nm-hidden', !show);
            if (typeof n._refreshComposerOffsets === 'function') n._refreshComposerOffsets();
        }
    }

    function bootToolbar() {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype._applyFormatToolbarState !== 'function' || NYM.prototype._applyFormatToolbarState._lyFocus) return;
        var orig = NYM.prototype._applyFormatToolbarState;
        var wrapped = function () {
            var r = orig.apply(this, arguments);
            try { applyToolbarFocus(this); } catch (_) { }
            return r;
        };
        wrapped._lyFocus = true;
        NYM.prototype._applyFormatToolbarState = wrapped;
        var later = function () {
            setTimeout(function () {
                var n = window.nym;
                if (n) { try { applyToolbarFocus(n); } catch (_) { } }
            }, 0);
        };
        document.addEventListener('focusin', later, true);
        document.addEventListener('focusout', later, true);
        document.addEventListener('selectionchange', later);
    }


    var SECTION_TITLES = { owner: 'Owner', admins: 'Admins', mods: 'Mods', members: 'Members' };

    function sectionGroupMembers(n) {
        var list = document.getElementById('grpCtxMembers');
        if (!list || !LM() || n._groupCtxTransferMode) return;
        var ui = function (s) { return typeof n.uiText === 'function' ? n.uiText(s) : s; };
        var rows = Array.prototype.slice.call(list.querySelectorAll(':scope > .group-ctx-member'));
        if (!rows.length) return;
        var roles = rows.map(function (r) {
            var b = r.querySelector('.group-ctx-role');
            if (!b) return 'member';
            if (b.classList.contains('owner')) return 'owner';
            if (b.classList.contains('admin')) return 'admin';
            if (b.classList.contains('mod')) return 'mod';
            return 'member';
        });
        var groupId = n._groupCtxGroupId;
        var canMod = false;
        try { canMod = typeof n._canModerate === 'function' && n._canModerate(groupId, n.pubkey); } catch (_) { }
        rows.forEach(function (r) {
            var pk = r.dataset.pubkey;
            if (!r.querySelector('.presence-dot')) {
                var status = '';
                try { status = LM().presenceClass(n.getEffectiveUserStatus(pk)); } catch (_) { }
                if (status) {
                    var dot = document.createElement('span');
                    dot.className = 'presence-dot presence-' + status;
                    dot.setAttribute('role', 'img');
                    dot.setAttribute('aria-label', ui(status === 'online' ? 'Online' : status === 'away' ? 'Away' : 'Offline'));
                    var av = r.querySelector('.group-ctx-member-avatar');
                    var wrap = document.createElement('span');
                    wrap.className = 'group-ctx-avatar-wrap';
                    if (av) { av.parentNode.insertBefore(wrap, av); wrap.appendChild(av); }
                    wrap.appendChild(dot);
                }
            }
            if (canMod && pk !== n.pubkey && !r.querySelector('.group-ctx-more')) {
                var more = document.createElement('button');
                more.type = 'button';
                more.className = 'group-ctx-more';
                more.title = ui('Member actions');
                more.setAttribute('aria-label', ui('Member actions'));
                more.innerHTML = NymMenuDotsIcon.svg({ size: 16 });
                r.appendChild(more);
            }
        });
        var frag = document.createDocumentFragment();
        LM().memberSections(roles).forEach(function (sec) {
            var h = document.createElement('div');
            h.className = 'group-ctx-section-title';
            h.dataset.section = sec.key;
            h.textContent = ui(SECTION_TITLES[sec.key]) + ' · ' + sec.items.length;
            frag.appendChild(h);
            sec.items.forEach(function (i) { frag.appendChild(rows[i]); });
        });
        list.appendChild(frag);
        var title = document.getElementById('grpCtxMembersTitle');
        if (title) title.classList.add('nm-hidden');
    }

    function bootGroupPanel() {
        if (typeof NYM === 'undefined' || !NYM.prototype || typeof NYM.prototype.showGroupContextMenu !== 'function' || NYM.prototype.showGroupContextMenu._lySections) return;
        var orig = NYM.prototype.showGroupContextMenu;
        var wrapped = function () {
            var title = document.getElementById('grpCtxMembersTitle');
            if (title) title.classList.remove('nm-hidden');
            var r = orig.apply(this, arguments);
            try { sectionGroupMembers(this); } catch (_) { }
            return r;
        };
        wrapped._lySections = true;
        NYM.prototype.showGroupContextMenu = wrapped;
        if (typeof NYM.prototype.groupCtxTransferOwner === 'function' && !NYM.prototype.groupCtxTransferOwner._lySections) {
            var origT = NYM.prototype.groupCtxTransferOwner;
            var t = function () {
                var title = document.getElementById('grpCtxMembersTitle');
                if (title) title.classList.remove('nm-hidden');
                return origT.apply(this, arguments);
            };
            t._lySections = true;
            NYM.prototype.groupCtxTransferOwner = t;
        }
    }


    function syncSidebarEdit() {
        var btn = document.getElementById('sidebarEditBtn');
        if (!btn) return;
        var on = document.body.classList.contains('sidebar-reorder-mode');
        var n = window.nym;
        var ui = function (s) { return n && typeof n.uiText === 'function' ? n.uiText(s) : s; };
        var name = on ? ui('Done') : ui('Edit sidebar');
        if (btn.getAttribute('aria-label') !== name) btn.setAttribute('aria-label', name);
        if (btn.hasAttribute('title')) btn.removeAttribute('title');
        var label = btn.querySelector('.sidebar-edit-label');
        var text = on ? ui('Done') : '';
        if (label && label.textContent !== text) label.textContent = text;
        btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    }

    ACTIONS.toggleSidebarEdit = function () {
        var n = window.nym;
        if (!n || typeof n._setSidebarReorderMode !== 'function') return;
        n._setSidebarReorderMode(!document.body.classList.contains('sidebar-reorder-mode'));
        syncSidebarEdit();
    };

    function bootSidebarEdit() {
        if (typeof MutationObserver === 'undefined' || !document.body) return;
        new MutationObserver(syncSidebarEdit).observe(document.body, { attributes: true, attributeFilter: ['class'] });
        syncSidebarEdit();
    }


    function px(v) { return Math.round(v * 10) / 10 + 'px'; }

    function syncSidebarChrome() {
        var root = document.documentElement;
        var header = document.querySelector('.chat-header');
        if (header && header.offsetHeight && !getComputedStyle(root).getPropertyValue('--chat-header-h').trim()) {
            var hv = px(header.getBoundingClientRect().height);
            if (root.style.getPropertyValue('--sidebar-head-h') !== hv) root.style.setProperty('--sidebar-head-h', hv);
        }
        var box = document.querySelector('.input-container');
        var input = document.getElementById('messageInput');
        var row = box && box.querySelector('.message-input-row');
        if (!box || !row || !input || !box.offsetHeight || !row.offsetHeight) return;
        if ((input.textContent || '').trim() || input.querySelector('img')) return;
        var cs = getComputedStyle(box);
        var rest = box.getBoundingClientRect().bottom - row.getBoundingClientRect().top + parseFloat(cs.paddingTop) + parseFloat(cs.borderTopWidth);
        var fv = px(rest);
        if (root.style.getPropertyValue('--sidebar-foot-h') !== fv) root.style.setProperty('--sidebar-foot-h', fv);
    }

    function statusTip(row, label, extra, hint) {
        if (!row || !label) return;
        var n = window.nym;
        var ui = function (s) { return n && typeof n.uiText === 'function' ? n.uiText(s) : s; };
        var clipped = label.scrollWidth > label.clientWidth + 1;
        var full = (label.textContent || '').trim() + (extra && extra.textContent ? ' · ' + extra.textContent.trim() : '');
        var tip = clipped ? full : ui(hint);
        if (row.getAttribute('data-tip') !== tip) row.setAttribute('data-tip', tip);
    }

    function syncStatusTips() {
        statusTip(document.querySelector('#sidebar .status-indicator'), document.getElementById('connectionStatus'), null, 'View network stats');
        statusTip(document.getElementById('meshStatusRow'), document.getElementById('meshStatusLabel'), document.getElementById('meshStatusLinks'), 'Bluetooth mesh');
    }

    function bootSidebarChrome() {
        var queued = false;
        var run = function () {
            if (queued) return;
            queued = true;
            requestAnimationFrame(function () { queued = false; syncSidebarChrome(); syncStatusTips(); });
        };
        run();
        window.addEventListener('resize', run);
        document.addEventListener('input', function (e) { if (e.target && e.target.id === 'messageInput') run(); }, true);
        if (typeof ResizeObserver !== 'undefined') {
            var ro = new ResizeObserver(run);
            ['.chat-header', '.input-container', '#sidebarFooter'].forEach(function (sel) {
                var el = document.querySelector(sel);
                if (el) ro.observe(el);
            });
        }
        var footer = document.getElementById('sidebarFooter');
        if (footer && typeof MutationObserver !== 'undefined') {
            new MutationObserver(run).observe(footer, { subtree: true, childList: true, characterData: true });
        }
    }


    var SIDEBAR_KEY = 'nym_sidebar_width';

    function setSidebarWidth(w, save) {
        if (!LM()) return;
        var px = LM().clampSidebarWidth(w);
        document.documentElement.style.setProperty('--sidebar-w', px + 'px');
        var r = document.getElementById('sidebarResizer');
        if (r) {
            r.setAttribute('aria-valuenow', String(px));
            r.setAttribute('aria-valuemin', String(LM().SIDEBAR_MIN));
            r.setAttribute('aria-valuemax', String(LM().SIDEBAR_MAX));
        }
        if (save) lsSet(SIDEBAR_KEY, String(px));
        return px;
    }

    function bootSidebarResize() {
        var r = document.getElementById('sidebarResizer');
        var side = document.getElementById('sidebar');
        if (!r || !side || !LM()) return;
        var saved = lsGet(SIDEBAR_KEY);
        setSidebarWidth(saved ? Number(saved) : LM().SIDEBAR_DEFAULT, false);
        var drag = null;
        r.addEventListener('pointerdown', function (e) {
            if (e.button !== 0) return;
            e.preventDefault();
            drag = { x: e.clientX, w: side.getBoundingClientRect().width };
            try { r.setPointerCapture(e.pointerId); } catch (_) { }
            document.documentElement.classList.add('sidebar-resizing');
        });
        r.addEventListener('pointermove', function (e) {
            if (!drag) return;
            setSidebarWidth(drag.w + e.clientX - drag.x, false);
        });
        var end = function (e) {
            if (!drag) return;
            var w = drag.w + e.clientX - drag.x;
            drag = null;
            document.documentElement.classList.remove('sidebar-resizing');
            setSidebarWidth(w, true);
        };
        r.addEventListener('pointerup', end);
        r.addEventListener('pointercancel', end);
        r.addEventListener('dblclick', function () { setSidebarWidth(LM().SIDEBAR_DEFAULT, true); });
        r.addEventListener('keydown', function (e) {
            if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
            e.preventDefault();
            var w = side.getBoundingClientRect().width + (e.key === 'ArrowRight' ? 16 : -16);
            setSidebarWidth(w, true);
        });
    }


    var COLUMN_KEY = 'nym_column_width';

    function setColumnWidth(w, save) {
        if (!LM()) return 0;
        var px = LM().clampColumnWidth(w);
        document.documentElement.style.setProperty('--cv-col-w', px + 'px');
        if (save) lsSet(COLUMN_KEY, String(px));
        return px;
    }

    function addColumnResizers(strip) {
        var n = window.nym;
        var ui = function (s) { return n && typeof n.uiText === 'function' ? n.uiText(s) : s; };
        strip.querySelectorAll(':scope > .cv-column').forEach(function (col) {
            if (col.querySelector(':scope > .cv-column-resizer')) return;
            var h = document.createElement('div');
            h.className = 'cv-column-resizer';
            h.setAttribute('role', 'separator');
            h.setAttribute('aria-orientation', 'vertical');
            h.setAttribute('aria-label', ui('Resize columns'));
            h.title = ui('Drag to resize columns');
            h.tabIndex = 0;
            col.appendChild(h);
        });
    }

    function bootColumnResize() {
        var saved = lsGet(COLUMN_KEY);
        setColumnWidth(saved ? Number(saved) : (LM() ? LM().COLUMN_DEFAULT : 360), false);
        var watchStrip = function () {
            var strip = document.getElementById('columnsStrip');
            if (!strip || strip._lyResize || typeof MutationObserver === 'undefined') return;
            strip._lyResize = true;
            addColumnResizers(strip);
            new MutationObserver(function () { addColumnResizers(strip); }).observe(strip, { childList: true });
        };
        watchStrip();
        if (typeof MutationObserver !== 'undefined') {
            new MutationObserver(watchStrip).observe(document.body, { childList: true, subtree: true });
        }
        var drag = null;
        document.addEventListener('pointerdown', function (e) {
            var h = e.target && e.target.closest && e.target.closest('.cv-column-resizer');
            if (!h || e.button !== 0) return;
            e.preventDefault();
            e.stopPropagation();
            drag = { x: e.clientX, w: h.parentElement.getBoundingClientRect().width, h: h };
            try { h.setPointerCapture(e.pointerId); } catch (_) { }
            document.documentElement.classList.add('cv-resizing');
        }, true);
        document.addEventListener('pointermove', function (e) {
            if (!drag) return;
            setColumnWidth(drag.w + e.clientX - drag.x, false);
        }, true);
        var end = function (e) {
            if (!drag) return;
            var w = drag.w + e.clientX - drag.x;
            drag = null;
            document.documentElement.classList.remove('cv-resizing');
            setColumnWidth(w, true);
        };
        document.addEventListener('pointerup', end, true);
        document.addEventListener('pointercancel', end, true);
        document.addEventListener('keydown', function (e) {
            var h = e.target && e.target.classList && e.target.classList.contains('cv-column-resizer') ? e.target : null;
            if (!h || (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight')) return;
            e.preventDefault();
            setColumnWidth(h.parentElement.getBoundingClientRect().width + (e.key === 'ArrowRight' ? 16 : -16), true);
        }, true);
    }

    function setHidePreviews(on) {
        lsSet(HIDE_KEY, on ? '1' : null);
        var sel = document.getElementById('hidePreviewsToggle');
        if (sel) sel.checked = !!on;
        sweepPreviews();
        var n = window.nym;
        if (n && typeof n._refreshNotificationsModalIfOpen === 'function') n._refreshNotificationsModalIfOpen();
    }

    function notePref(name) {
        var n = window.nym;
        if (n && typeof n.notePrefChanged === 'function') n.notePrefChanged(name);
    }

    ACTIONS.onHidePreviewsChange = function (_e, t) { setHidePreviews(!!(t && t.checked)); notePref('hidePreviews'); };

    var COLORFUL_KEY = 'nym_colorful_messages';

    function colorful() { return lsGet(COLORFUL_KEY) === '1'; }

    function applyColorful() {
        if (document.body) document.body.classList.toggle('colorful-messages', colorful());
        var sel = document.getElementById('colorfulMessagesToggle');
        if (sel) sel.checked = colorful();
    }

    function setColorful(on) {
        lsSet(COLORFUL_KEY, on ? '1' : null);
        applyColorful();
    }

    ACTIONS.onColorfulMessagesChange = function (_e, t) {
        setColorful(!!(t && t.checked));
        notePref('colorfulMessages');
    };

    var TARGETS_KEY = 'nym_large_targets';
    var CONTRAST_KEY = 'nym_high_contrast';

    function applyA11y() {
        var t = lsGet(TARGETS_KEY) === '1';
        var c = lsGet(CONTRAST_KEY) === '1';
        if (document.body) {
            document.body.classList.toggle('a11y-targets', t);
            document.body.classList.toggle('a11y-contrast', c);
        }
        var tb = document.getElementById('a11yTargetsToggle');
        if (tb) tb.checked = t;
        var cb = document.getElementById('a11yContrastToggle');
        if (cb) cb.checked = c;
    }

    function setLargeTargets(on) {
        lsSet(TARGETS_KEY, on ? '1' : null);
        applyA11y();
    }

    function setHighContrast(on) {
        lsSet(CONTRAST_KEY, on ? '1' : null);
        applyA11y();
    }

    ACTIONS.onLargeTargetsChange = function (_e, t) {
        setLargeTargets(!!(t && t.checked));
        notePref('largeTargets');
    };

    ACTIONS.onHighContrastChange = function (_e, t) {
        setHighContrast(!!(t && t.checked));
        notePref('highContrast');
    };

    function syncSettings() {
        var sel = document.getElementById('hidePreviewsToggle');
        if (sel) sel.checked = previewsHidden();
        applyColorful();
        applyA11y();
    }


    var PEOPLE_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path><circle cx="9" cy="7" r="4"></circle><path d="M23 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16 3.13a4 4 0 0 1 0 7.75"></path></svg>';
    var EXPLORE_SVG = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle><polygon points="16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76"></polygon></svg>';

    function headerKind(n) {
        if (n.inPMMode && n.currentGroup) return 'group';
        if (n.inPMMode && n.currentPM) return n.verifiedBotPubkeys && n.verifiedBotPubkeys.has(n.currentPM) ? 'bot' : 'pm';
        return geoKey(n) ? 'geohash' : 'channel';
    }

    function geoKey(n) {
        if (!n || n.inPMMode) return '';
        return typeof n.channelGeohashKey === 'function' ? n.channelGeohashKey(n.currentChannel, n.currentGeohash) : '';
    }

    function uiT(n, s) { return n && typeof n.uiText === 'function' ? n.uiText(s) : s; }

    function textOf(el) { return el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : ''; }

    function joinSub(parts) {
        return parts.filter(function (x) { return !!x; }).join(' · ');
    }

    function renderHeader() {
        var n = window.nym;
        var src = document.getElementById('currentChannel');
        var meta = document.getElementById('channelMeta');
        var av = document.getElementById('chatHeaderAvatar');
        var title = document.getElementById('chatHeaderTitle');
        var badges = document.getElementById('chatHeaderBadges');
        var sub = document.getElementById('chatHeaderSub');
        var mid = document.getElementById('chatTitleBtn');
        if (!n || !src || !av || !title || !sub || !mid) return;
        var kind = headerKind(n);
        var enc = uiT(n, 'end-to-end encrypted');
        var subText = '';
        var dot = false;
        av.className = 'uh-avatar';
        av.replaceChildren();
        title.replaceChildren();
        if (badges) badges.replaceChildren();
        if (kind === 'pm' || kind === 'bot') {
            var row = src.querySelector('.pm-header-row');
            var img = row && row.querySelector('.pm-header-avatar img');
            if (img) { av.appendChild(img.cloneNode(true)); av.classList.add('round'); }
            if (row) {
                Array.prototype.forEach.call(row.childNodes, function (c) {
                    if (c.nodeType === 1 && c.classList.contains('pm-header-avatar')) return;
                    var named = c.nodeType !== 1 || c.classList.contains('pm-name-text') || c.classList.contains('nym-suffix');
                    (named || !badges ? title : badges).appendChild(c.cloneNode(true));
                });
            }
            var seen = textOf(src.querySelector('.pm-last-seen'));
            dot = !!(n.getEffectiveUserStatus && n.getEffectiveUserStatus(n.currentPM) === 'online');
            subText = kind === 'bot' ? (textOf(meta) || joinSub([seen, enc])) : joinSub([seen, enc]);
            if (kind === 'bot') dot = false;
        } else if (kind === 'group') {
            var g = n.groupConversations && n.groupConversations.get(n.currentGroup);
            var gimg = src.querySelector('.group-header-custom-avatar');
            if (gimg) av.appendChild(gimg.cloneNode(true));
            else av.innerHTML = PEOPLE_SVG;
            title.textContent = g ? (typeof n._groupLabel === 'function' ? n._groupLabel(g) : (g.name || 'Group')) : textOf(src.querySelector('.group-name-text'));
            var count = g ? (typeof n.abbreviateNumber === 'function' ? n.abbreviateNumber(g.members.length) : g.members.length) : '';
            var desc = g && window.NymGroupTools ? window.NymGroupTools.descriptionLine((typeof n._groupDescription === 'function' ? n._groupDescription(g) : (g.description || ''))) : '';
            subText = joinSub([count !== '' ? uiT(n, count + ' members') : '', desc || enc]);
        } else if (kind === 'geohash') {
            av.innerHTML = n._channelGlyphSvg(true, 18);
            title.textContent = '#' + geoKey(n);
            var place = textOf(src.querySelector('.channel-location'));
            subText = joinSub([place, textOf(meta)]);
        } else {
            av.innerHTML = n._channelGlyphSvg(false, 18);
            title.textContent = textOf(src.querySelector('.channel-title-line')) || ('#' + (n.currentChannel || ''));
            subText = textOf(meta);
        }
        if (dot) {
            var d = document.createElement('span');
            d.className = 'uh-dot';
            d.setAttribute('aria-hidden', 'true');
            sub.replaceChildren(d, document.createTextNode(subText));
        } else {
            sub.textContent = subText;
        }
        var label = kind === 'geohash' ? uiT(n, 'Show this location on the map') : (kind === 'channel' ? '' : uiT(n, 'Conversation info'));
        mid.classList.toggle('uh-clickable', !!label);
        if (label) {
            mid.setAttribute('role', 'button');
            mid.setAttribute('tabindex', '0');
            mid.setAttribute('aria-label', label);
            mid.setAttribute('data-tip', '');
            if (kind !== 'geohash') mid.setAttribute('aria-expanded', panelForConv(n, currentConv(n)) ? 'true' : 'false');
            else mid.removeAttribute('aria-expanded');
        } else {
            ['role', 'tabindex', 'aria-label', 'data-tip', 'aria-expanded'].forEach(function (k) { mid.removeAttribute(k); });
        }
        mid.dataset.kind = kind;
        applyActionOverflow();
    }

    var HEADER_IDS = { shareChannelBtn: 'share', favoriteChannelBtn: 'favorite', rejoinCallBtn: 'rejoin', audioCallBtn: 'audio', videoCallBtn: 'video', meshGhostBtn: 'ghost', meshAddBtn: 'addDevice' };

    function actionsIn(sel) {
        var box = document.querySelector('header.chat-header ' + sel);
        if (!box) return [];
        return Array.prototype.filter.call(box.children, function (b) {
            return b.tagName === 'BUTTON' && b.id !== 'infoPanelBtn';
        });
    }

    function chatActions() { return actionsIn('.channel-action-buttons'); }

    function meshActions() { return actionsIn('.mesh-hdr-actions'); }

    function meshMode() {
        var main = document.querySelector('.main-content');
        return !!(main && main.classList.contains('mesh-mode'));
    }

    function liveAction(b) {
        return b.style.display !== 'none' && !b.hidden && !b.classList.contains('nm-call-hidden') && !b.classList.contains('nm-hidden');
    }

    function shownEl(el) {
        if (!el || !el.getClientRects().length) return false;
        var cs = getComputedStyle(el);
        return cs.display !== 'none' && cs.visibility !== 'hidden';
    }

    function titleRoom(mid) {
        var row = mid && mid.querySelector('.uh-title-row');
        var title = row && row.querySelector('.uh-title');
        if (!row || !title || !shownEl(row)) return null;
        var used = 0;
        var count = 0;
        Array.prototype.forEach.call(row.children, function (c) {
            if (c === title || !shownEl(c)) return;
            var cs = getComputedStyle(c);
            used += c.getBoundingClientRect().width + (parseFloat(cs.marginLeft) || 0) + (parseFloat(cs.marginRight) || 0);
            count++;
        });
        return Math.round(row.getBoundingClientRect().width - used - count * (parseFloat(getComputedStyle(row).columnGap) || 0));
    }

    function markHeaderEnds(head, gap, mid) {
        var t = mid && shownEl(mid) ? mid.getBoundingClientRect() : null;
        var list = Array.prototype.filter.call(head.querySelectorAll('.uh-phone-menu, .uh-left .channel-nav-btn, .uh-actions > button, .header-icon-btn, .mobile-header-actions > button'), shownEl)
            .map(function (b) { return { b: b, r: b.getBoundingClientRect() }; })
            .filter(function (x) { return x.r.width > 0; })
            .sort(function (a, b) { return a.r.left - b.r.left; });
        list.forEach(function (x, i) {
            var prev = list[i - 1];
            var next = list[i + 1];
            var start = !prev || x.r.left - prev.r.right > gap + 0.5;
            var end = !next || next.r.left - x.r.right > gap + 0.5;
            var titleL = start && !!t && t.right <= x.r.left + 0.5 && (!prev || prev.r.right <= t.left + 0.5);
            var titleR = end && !!t && t.left >= x.r.right - 0.5 && (!next || next.r.left >= t.right - 0.5);
            if (x.b.classList.contains('uh-end-l') !== start) x.b.classList.toggle('uh-end-l', start);
            if (x.b.classList.contains('uh-end-r') !== end) x.b.classList.toggle('uh-end-r', end);
            if (x.b.classList.contains('uh-title-l') !== titleL) x.b.classList.toggle('uh-title-l', titleL);
            if (x.b.classList.contains('uh-title-r') !== titleR) x.b.classList.toggle('uh-title-r', titleR);
        });
    }

    function applyActionOverflow() {
        var head = document.querySelector('header.chat-header');
        var n = window.nym;
        var M = LM();
        if (!head || !n || !M || typeof M.headerOverflow !== 'function') return;
        var phone = window.innerWidth <= 768;
        var mesh = meshMode();
        var cs = getComputedStyle(head);
        var gap = parseFloat(cs.getPropertyValue('--uh-gap')) || 2;
        var step = (parseFloat(cs.getPropertyValue('--uh-box')) || 40) + gap;
        (mesh ? chatActions() : meshActions()).forEach(function (b) { if (b.classList.contains('uh-over')) b.classList.remove('uh-over'); });
        var live = [];
        var capped = [];
        (mesh ? meshActions() : chatActions()).forEach(function (b) {
            if (!liveAction(b)) {
                if (b.classList.contains('uh-over')) b.classList.remove('uh-over');
                return;
            }
            if (!phone && live.length >= 3) capped.push(b);
            else live.push(b);
        });
        var mid = head.querySelector(mesh ? '#meshHeaderMid' : '#chatTitleBtn');
        var room = head.getBoundingClientRect().width > 0 ? titleRoom(mid) : null;
        var moved = [];
        var more = false;
        if (room !== null) {
            var was = live.filter(function (b) { return b.classList.contains('uh-over'); }).length;
            var base = room - was * step + (phone && head.classList.contains('uh-more-on') ? step : 0);
            var kind = mesh ? 'mesh' : (M.HEADER_KINDS[headerKind(n)] || 'channel');
            var plan = M.headerOverflow({ kind: kind, actions: live.map(function (b) { return HEADER_IDS[b.id] || b.id; }).concat('bell'), base: base, step: step, more: !phone });
            moved = plan.moved;
            more = phone && plan.more;
        } else {
            moved = live.filter(function (b) { return b.classList.contains('uh-over'); }).map(function (b) { return HEADER_IDS[b.id] || b.id; });
            more = phone && head.classList.contains('uh-more-on');
        }
        live.forEach(function (b) {
            var want = moved.indexOf(HEADER_IDS[b.id] || b.id) >= 0;
            if (b.classList.contains('uh-over') !== want) b.classList.toggle('uh-over', want);
        });
        capped.forEach(function (b) { if (!b.classList.contains('uh-over')) b.classList.add('uh-over'); });
        var empty = live.length === moved.length;
        var box = head.querySelector(mesh ? '.mesh-hdr-actions' : '.channel-action-buttons');
        if (box && box.classList.contains('uh-empty') !== empty) box.classList.toggle('uh-empty', empty);
        var other = head.querySelector(mesh ? '.channel-action-buttons' : '.mesh-hdr-actions');
        if (other && other.classList.contains('uh-empty')) other.classList.remove('uh-empty');
        if (head.classList.contains('uh-acts-empty') !== empty) head.classList.toggle('uh-acts-empty', empty);
        if (head.classList.contains('uh-more-on') !== more) head.classList.toggle('uh-more-on', more);
        if (room !== null) markHeaderEnds(head, gap, mid);
    }

    var overflowTimer = 0;
    function scheduleOverflow() {
        if (overflowTimer) return;
        overflowTimer = setTimeout(function () { overflowTimer = 0; try { applyActionOverflow(); } catch (_) { } }, 0);
    }

    function buildChatMenu(menu) {
        var n = window.nym;
        Array.prototype.slice.call(menu.querySelectorAll('.uh-chat-item, .header-more-head, .header-more-sep')).forEach(function (x) { x.remove(); });
        if (!n) return;
        applyActionOverflow();
        var mesh = meshMode();
        var items = [];
        (mesh ? meshActions() : chatActions()).forEach(function (b) {
            if (!b.classList.contains('uh-over')) return;
            items.push({ id: HEADER_IDS[b.id] || '', label: b.getAttribute('aria-label') || '', svg: b.querySelector('svg'), run: function () { b.click(); }, disabled: b.disabled, filled: b.id === 'favoriteChannelBtn' && b.classList.contains('active') });
        });
        var kind = mesh ? 'mesh' : headerKind(n);
        if (kind === 'geohash') {
            var gh = geoKey(n);
            items.push({ label: uiT(n, 'Open in explorer'), html: EXPLORE_SVG, run: function () { if (typeof n.showGeohashExplorer === 'function') n.showGeohashExplorer(gh); } });
        }
        var first = menu.firstChild;
        if (items.length) {
            var head = document.createElement('div');
            head.className = 'header-more-head';
            head.textContent = kind === 'mesh' ? uiT(n, 'Bluetooth mesh') : kind === 'group' ? uiT(n, 'Group') : (kind === 'pm' || kind === 'bot' ? uiT(n, 'Private message') : uiT(n, 'Channel'));
            menu.insertBefore(head, first);
            items.forEach(function (it) {
                var btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'header-more-item uh-chat-item';
                btn.setAttribute('role', 'menuitem');
                if (it.id) btn.dataset.uhId = it.id;
                if (it.disabled) btn.disabled = true;
                if (it.svg) {
                    var c = it.svg.cloneNode(true);
                    c.setAttribute('width', '16');
                    c.setAttribute('height', '16');
                    if (it.filled) c.setAttribute('fill', 'currentColor');
                    btn.appendChild(c);
                } else if (it.html) {
                    btn.insertAdjacentHTML('beforeend', it.html);
                }
                var sp = document.createElement('span');
                sp.textContent = it.label;
                btn.appendChild(sp);
                btn.addEventListener('click', function () { closeHeaderMore(false); it.run(); });
                menu.insertBefore(btn, first);
            });
            var sep = document.createElement('hr');
            sep.className = 'header-more-sep';
            menu.insertBefore(sep, first);
            var app = document.createElement('div');
            app.className = 'header-more-head';
            app.textContent = uiT(n, 'More');
            menu.insertBefore(app, first);
        }
    }

    var headerTimer = 0;
    function scheduleHeader() {
        if (headerTimer) return;
        headerTimer = setTimeout(function () { headerTimer = 0; try { renderHeader(); } catch (_) { } }, 0);
    }

    function bootHeader() {
        var mid = document.getElementById('chatTitleBtn');
        var src = document.getElementById('currentChannel');
        var meta = document.getElementById('channelMeta');
        if (!mid || !src || mid._lyHeader) return;
        mid._lyHeader = true;
        var activate = function () {
            var n = window.nym;
            if (!n || !mid.classList.contains('uh-clickable')) return;
            if (mid.dataset.kind === 'geohash') {
                if (typeof n.showGeohashExplorer === 'function') n.showGeohashExplorer(geoKey(n));
                return;
            }
            ACTIONS.toggleInfoPanel();
            scheduleHeader();
        };
        mid.addEventListener('click', function (e) {
            if (!mid.classList.contains('uh-clickable')) return;
            e.preventDefault();
            activate();
        });
        mid.addEventListener('keydown', function (e) {
            if (e.target !== mid || !mid.classList.contains('uh-clickable')) return;
            if (e.key !== 'Enter' && e.key !== ' ' && e.key !== 'Spacebar') return;
            e.preventDefault();
            activate();
        });
        if (typeof MutationObserver !== 'undefined') {
            var mo = new MutationObserver(scheduleHeader);
            mo.observe(src, { childList: true, subtree: true, characterData: true, attributes: true });
            if (meta) mo.observe(meta, { childList: true, subtree: true, characterData: true });
            chatActions().concat(meshActions()).forEach(function (b) { mo.observe(b, { attributes: true, attributeFilter: ['class', 'style', 'disabled', 'aria-label', 'hidden'] }); });
            var main = document.querySelector('.main-content');
            if (main) mo.observe(main, { attributes: true, attributeFilter: ['class'] });
            var bodyMo = new MutationObserver(scheduleOverflow);
            bodyMo.observe(document.body, { attributes: true, attributeFilter: ['class'] });
        }
        if (typeof ResizeObserver !== 'undefined') {
            var ro = new ResizeObserver(scheduleOverflow);
            var head = document.querySelector('header.chat-header');
            if (head) ro.observe(head);
            ['chatTitleBtn', 'meshHeaderMid', 'chatHeaderBadges'].forEach(function (id) {
                var el = document.getElementById(id);
                if (el) ro.observe(el);
            });
        }
        window.addEventListener('resize', scheduleHeader);
        scheduleHeader();
    }

    if (typeof document !== 'undefined') {
        var start = function () {
            syncSettings();
            bootPreviews();
            bootDock();
            bootSettings();
            bootCalls();
            bootNotifications();
            bootToolbar();
            bootGroupPanel();
            bootSidebarEdit();
            bootSidebarChrome();
            bootSidebarResize();
            bootColumnResize();
            bootHeader();
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
        else start();
    }

    window.NymLayout = Object.assign(window.NymLayout || {}, {
        closeHeaderMore: closeHeaderMore,
        refreshPreviews: sweepPreviews,
        setHidePreviews: setHidePreviews,
        setColorful: setColorful,
        setLargeTargets: setLargeTargets,
        setHighContrast: setHighContrast,
        applyA11y: applyA11y,
        previewsHidden: previewsHidden,
        applyDock: applyDock,
        applySettingsMode: applySettingsMode,
        followConversation: followConversation,
        renderHeader: renderHeader
    });
})();
