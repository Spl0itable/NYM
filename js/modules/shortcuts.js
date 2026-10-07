(function () {
    const G = typeof self !== 'undefined' ? self : window;

    const SHEET = Object.freeze([
        { action: 'search', label: 'Search and switch chats', mac: ['⌘', 'K'], other: ['Ctrl', 'K'] },
        { action: 'prevChat', label: 'Previous chat', mac: ['⌥', '↑'], other: ['Alt', '↑'] },
        { action: 'nextChat', label: 'Next chat', mac: ['⌥', '↓'], other: ['Alt', '↓'] },
        { action: 'nextUnread', label: 'Next unread chat', mac: ['⌥', '⇧', '↓'], other: ['Alt', 'Shift', '↓'] },
        { action: 'back', label: 'Go back', mac: ['⌥', '←'], other: ['Alt', '←'] },
        { action: 'forward', label: 'Go forward', mac: ['⌥', '→'], other: ['Alt', '→'] },
        { action: 'editLast', label: 'Edit your last message (empty composer)', mac: ['↑'], other: ['↑'] },
        { action: 'escape', label: 'Close the top layer', mac: ['Esc'], other: ['Esc'] },
        { action: 'settings', label: 'Open Settings', mac: ['⌘', ','], other: ['Ctrl', ','] },
        { action: 'help', label: 'Show keyboard shortcuts', mac: ['?'], other: ['?'] },
    ]);

    function match(e) {
        const x = e || {};
        const raw = String(x.key || '');
        const key = raw.length === 1 ? raw.toLowerCase() : raw;
        if (key === 'Escape') return !x.ctrl && !x.meta && !x.alt && !x.shift ? 'escape' : null;
        const primary = x.mac ? !!x.meta : !!x.ctrl;
        const secondary = x.mac ? !!x.ctrl : !!x.meta;
        if (secondary) return null;
        if (primary) {
            if (x.alt || x.shift) return null;
            if (key === 'k') return 'search';
            if (key === ',' && !x.inText) return 'settings';
            return null;
        }
        if (x.alt) {
            if (x.inText) return null;
            if (key === 'ArrowDown') return x.shift ? 'nextUnread' : 'nextChat';
            if (x.shift) return null;
            if (key === 'ArrowUp') return 'prevChat';
            if (key === 'ArrowLeft') return 'back';
            if (key === 'ArrowRight') return 'forward';
            return null;
        }
        if (key === 'ArrowUp') return !x.shift && x.inText && x.inComposer && x.composerEmpty ? 'editLast' : null;
        if (key === '?' && !x.inText) return 'help';
        return null;
    }

    function navTarget(order, current, dir, unread) {
        const list = Array.isArray(order) ? order : [];
        const n = list.length;
        if (!n) return null;
        const i = list.indexOf(current);
        if (dir === 'nextUnread') {
            const want = Array.isArray(unread) ? unread : [];
            for (let s = 1; s <= n; s++) {
                const k = list[i < 0 ? (s - 1) % n : (i + s) % n];
                if (k !== current && want.indexOf(k) >= 0) return k;
            }
            return null;
        }
        if (i < 0) return dir === 'next' ? list[0] : list[n - 1];
        if (n < 2) return null;
        return list[(i + (dir === 'next' ? 1 : -1) + n) % n];
    }

    function sheet() {
        return SHEET.map((r) => ({ action: r.action, label: r.label, mac: r.mac.slice(), other: r.other.slice() }));
    }

    function isMac() {
        const nav = G.navigator || {};
        const p = (nav.userAgentData && nav.userAgentData.platform) || nav.platform || '';
        return /mac|iphone|ipad|ipod/i.test(p);
    }

    function keyLabel(action, mac) {
        const row = SHEET.find((r) => r.action === action);
        if (!row) return '';
        return mac ? row.mac.join('') : row.other.join('+');
    }

    G.NymShortcuts = { match, navTarget, sheet, isMac, keyLabel };

    if (typeof document === 'undefined' || typeof document.querySelectorAll !== 'function') return;

    const nymOf = () => G.nym;
    const tr = (s) => { const n = nymOf(); try { return n && typeof n.uiText === 'function' ? (n.uiText(s) || s) : s; } catch (_) { return s; } };
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    function editable(t) {
        if (!t || t.nodeType !== 1) return false;
        if (t.isContentEditable) return true;
        const tag = t.tagName;
        if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
        if (tag !== 'INPUT') return false;
        return !/^(button|checkbox|radio|range|submit|reset|color|file|image)$/i.test(t.type || '');
    }

    function composerOf(t) {
        return t && t.closest ? t.closest('#messageInput, .cv-composer-input, [data-composer-input]') : null;
    }

    function composerEmpty(el) {
        if (!el) return false;
        const v = 'value' in el && typeof el.value === 'string' ? el.value : el.textContent;
        return !String(v || '').trim();
    }

    function rowKey(el) {
        if (el.dataset.groupId) return 'g:' + el.dataset.groupId;
        if (el.dataset.pubkey) return 'p:' + el.dataset.pubkey;
        return 'c:' + (el.dataset.geohash || el.dataset.channel || '');
    }

    function sidebarRows() {
        return Array.from(document.querySelectorAll('.sidebar .channel-item, .sidebar .pm-item'))
            .filter((el) => el.offsetParent && !el.closest('.nm-hidden'));
    }

    function rowUnread(el) {
        if (el.classList.contains('has-unread')) return true;
        const b = el.querySelector('.unread-badge');
        return !!(b && b.style.display !== 'none' && !b.classList.contains('nm-hidden') && parseInt(b.textContent, 10) > 0);
    }

    function currentKey() {
        const n = nymOf();
        if (!n) return null;
        if (n.inPMMode) return n.currentGroup ? 'g:' + n.currentGroup : (n.currentPM ? 'p:' + n.currentPM : null);
        return 'c:' + (n.currentGeohash || n.currentChannel || '');
    }

    function goChat(dir) {
        const rows = sidebarRows();
        const keys = rows.map(rowKey);
        const want = navTarget(keys, currentKey(), dir, rows.filter(rowUnread).map(rowKey));
        if (!want) return false;
        const row = rows[keys.indexOf(want)];
        if (row) row.click();
        return !!row;
    }

    function lastOwnMessage() {
        const n = nymOf();
        let root = document.getElementById('messagesContainer');
        if (n && n._cvActive && Array.isArray(n._cvColumns)) {
            const col = n._cvColumns.find((c) => c.id === n._cvFocusedId);
            if (col && col.listEl) root = col.listEl;
        }
        if (!root) return null;
        const own = Array.from(root.querySelectorAll('.message.self[data-message-id]'))
            .filter((m) => !m.classList.contains('optimistic-pending') && !m.closest('.thread-view'));
        return own.length ? own[own.length - 1] : null;
    }

    function editLast() {
        const n = nymOf();
        if (!n || n.pendingEdit) return false;
        const el = lastOwnMessage();
        if (!el || typeof n._msgActionContext !== 'function' || typeof n.startEditMessage !== 'function') return false;
        const x = n._msgActionContext(el);
        if (!x.messageId || !x.content || !x.self) return false;
        n.startEditMessage({ messageId: x.messageId, content: x.content, pubkey: x.pubkey });
        return !!n.pendingEdit;
    }

    if (typeof NYM !== 'undefined' && NYM.prototype) {
        NYM.prototype.editLastOwnMessage = function () { return editLast(); };
    }

    function closeTopLayer() {
        const n = nymOf();
        const popups = document.querySelectorAll('.quick-react-popup, .quick-context-menu');
        if (popups.length) {
            popups.forEach((p) => p.remove());
            document.querySelectorAll('.has-long-press-highlight').forEach((el) => el.classList.remove('has-long-press-highlight'));
            document.querySelectorAll('.message.long-press-highlight').forEach((el) => el.classList.remove('long-press-highlight'));
            return true;
        }
        const menu = document.getElementById('contextMenu');
        if (menu && menu.classList.contains('active') && n && typeof n.closeContextMenu === 'function') {
            n.closeContextMenu();
            return true;
        }
        const picker = document.querySelector('.enhanced-emoji-modal.active, .reaction-picker.active');
        if (picker) {
            picker.classList.remove('active');
            return true;
        }
        if (n && n.activeThread && typeof n.closeThreadView === 'function') {
            n.closeThreadView();
            return true;
        }
        return false;
    }

    function openSheet() {
        const mac = isMac();
        let modal = document.getElementById('shortcutsModal');
        if (!modal) {
            modal = document.createElement('div');
            modal.className = 'modal shortcuts-modal';
            modal.id = 'shortcutsModal';
            modal.setAttribute('role', 'dialog');
            modal.setAttribute('aria-labelledby', 'shortcutsTitle');
            document.body.appendChild(modal);
        }
        modal.innerHTML = '<div class="modal-content shortcuts-sheet">'
            + `<button type="button" class="modal-close" data-action="closeModal" data-modal-id="shortcutsModal" aria-label="${esc(tr('Close'))}">✕</button>`
            + `<h2 class="modal-title" id="shortcutsTitle">${esc(tr('Keyboard shortcuts'))}</h2>`
            + '<div class="shortcut-list">'
            + SHEET.map((r) => `<div class="shortcut-row" data-shortcut="${r.action}"><span class="shortcut-label">${esc(tr(r.label))}</span><span class="shortcut-keys">${(mac ? r.mac : r.other).map((k) => `<kbd>${esc(k)}</kbd>`).join('')}</span></div>`).join('')
            + '</div></div>';
        modal.classList.add('active');
        const close = modal.querySelector('.modal-close');
        if (close) close.focus();
    }

    function run(action) {
        const n = nymOf();
        switch (action) {
            case 'help': openSheet(); return true;
            case 'settings':
                if (typeof G.showSettings === 'function') { G.showSettings(); return true; }
                return false;
            case 'prevChat': return goChat('prev');
            case 'nextChat': return goChat('next');
            case 'nextUnread': return goChat('nextUnread');
            case 'back':
                if (n && typeof n.navigateBack === 'function') { n.navigateBack(); return true; }
                return false;
            case 'forward':
                if (n && typeof n.navigateForward === 'function') { n.navigateForward(); return true; }
                return false;
            case 'editLast': return editLast();
            case 'escape': return closeTopLayer();
            default: return false;
        }
    }

    function onKey(e) {
        if (e.defaultPrevented || e.isComposing) return;
        const t = e.target;
        const comp = composerOf(t);
        const action = match({
            key: e.key, ctrl: e.ctrlKey, meta: e.metaKey, alt: e.altKey, shift: e.shiftKey, mac: isMac(),
            inText: editable(t), inComposer: !!comp, composerEmpty: composerEmpty(comp),
        });
        if (!action || action === 'search') return;
        if (document.querySelector('.modal.active')) return;
        if (run(action)) e.preventDefault();
    }

    function tagTips() {
        const mac = isMac();
        const set = (sel, action) => document.querySelectorAll(sel).forEach((el) => el.setAttribute('data-tip-key', keyLabel(action, mac)));
        set('#unifiedSearchBtn', 'search');
        set('[data-action="showSettings"], [data-action="showSettingsAndCloseSidebar"]', 'settings');
        set('#channelBackBtn', 'back');
        set('#channelForwardBtn', 'forward');
        document.querySelectorAll('.us-open-kbd').forEach((k) => { k.textContent = mac ? '⌘K' : 'Ctrl K'; });
        const s = document.getElementById('unifiedSearchBtn');
        if (s) s.setAttribute('aria-keyshortcuts', mac ? 'Meta+K' : 'Control+K');
    }

    document.addEventListener('keydown', onKey);
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', tagTips);
    else tagTips();
})();
