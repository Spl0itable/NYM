// sidebar-sections.js - Long-press reordering of the sidebar sections

Object.assign(NYM.prototype, {

    _sidebarSectionIds: ['channels', 'pms', 'nyms'],

    _getSidebarSectionEls() {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar) return [];
        return Array.from(sidebar.querySelectorAll(':scope > [data-section]'));
    },

    _getSidebarSectionOrder() {
        const els = this._getSidebarSectionEls();
        if (els.length) return els.map(el => el.dataset.section);
        try {
            const stored = JSON.parse(localStorage.getItem('nym_sidebar_section_order') || 'null');
            if (Array.isArray(stored)) return stored;
        } catch (_) { }
        return this._sidebarSectionIds.slice();
    },

    _applySidebarSectionOrder(order) {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar || !Array.isArray(order)) return;
        const byId = new Map(this._getSidebarSectionEls().map(el => [el.dataset.section, el]));
        // Keep any sections missing from the saved order at their tail position.
        const finalOrder = order.filter(id => byId.has(id));
        for (const id of this._sidebarSectionIds) {
            if (!finalOrder.includes(id) && byId.has(id)) finalOrder.push(id);
        }
        for (const id of finalOrder) sidebar.appendChild(byId.get(id));
        this._refreshSidebarReorderButtons();
    },

    _saveSidebarSectionOrder() {
        const order = this._getSidebarSectionOrder();
        localStorage.setItem('nym_sidebar_section_order', JSON.stringify(order));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _moveSidebarSection(sectionEl, direction) {
        const sidebar = document.getElementById('sidebar');
        if (!sidebar || !sectionEl) return;
        if (direction === 'up') {
            const prev = sectionEl.previousElementSibling;
            if (prev && prev.dataset.section) sidebar.insertBefore(sectionEl, prev);
        } else {
            const next = sectionEl.nextElementSibling;
            if (next && next.dataset.section) sidebar.insertBefore(next, sectionEl);
        }
        this._refreshSidebarReorderButtons();
        this._saveSidebarSectionOrder();
    },

    // Disable the up arrow on the first section and the down arrow on the last.
    _refreshSidebarReorderButtons() {
        const els = this._getSidebarSectionEls();
        els.forEach((el, idx) => {
            const up = el.querySelector('.section-reorder-btn[data-section-move="up"]');
            const down = el.querySelector('.section-reorder-btn[data-section-move="down"]');
            if (up) up.disabled = idx === 0;
            if (down) down.disabled = idx === els.length - 1;
        });
    },

    _setSidebarReorderMode(on) {
        document.body.classList.toggle('sidebar-reorder-mode', !!on);
        if (on) this._refreshSidebarReorderButtons();
    },

    _getCollapsedSidebarSections() {
        try {
            const stored = JSON.parse(localStorage.getItem('nym_sidebar_section_collapsed') || '[]');
            return Array.isArray(stored) ? stored : [];
        } catch (_) { return []; }
    },

    _saveCollapsedSidebarSections(list) {
        localStorage.setItem('nym_sidebar_section_collapsed', JSON.stringify(list));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _applySidebarSectionCollapse() {
        const collapsed = new Set(this._getCollapsedSidebarSections());
        for (const el of this._getSidebarSectionEls()) {
            el.classList.toggle('section-collapsed', collapsed.has(el.dataset.section));
            const btn = el.querySelector('.collapse-icon');
            if (btn) {
                const isCollapsed = collapsed.has(el.dataset.section);
                btn.title = isCollapsed ? 'Expand section' : 'Collapse section';
                btn.setAttribute('aria-label', btn.title);
            }
        }
    },

    toggleSidebarSectionCollapse(sectionId) {
        if (!sectionId) return;
        const list = this._getCollapsedSidebarSections();
        const idx = list.indexOf(sectionId);
        if (idx >= 0) list.splice(idx, 1); else list.push(sectionId);
        this._saveCollapsedSidebarSections(list);
        this._applySidebarSectionCollapse();
    },

    setupSidebarSectionCollapse() {
        this._applySidebarSectionCollapse();
    },

    // Render a generic long-press action menu (reuses the message context menu styling).
    _showSidebarActionMenu(items, clientX, clientY) {
        document.querySelectorAll('.quick-context-menu').forEach(el => el.remove());
        if (!items.length) return;

        const menu = document.createElement('div');
        menu.className = 'quick-context-menu';
        menu.innerHTML = items.map((item, i) =>
            `<button class="quick-context-item${item.cls ? ' ' + item.cls : ''}" data-idx="${i}">${item.svg}<span>${this.escapeHtml(item.label)}</span></button>`
        ).join('');

        menu.style.position = 'fixed';
        menu.style.visibility = 'hidden';
        document.body.appendChild(menu);
        const w = menu.offsetWidth;
        const h = menu.offsetHeight;
        menu.style.visibility = '';

        let left = Math.max(10, Math.min(clientX, window.innerWidth - w - 10));
        let top = clientY;
        if (top + h > window.innerHeight - 10) top = Math.max(10, window.innerHeight - h - 10);
        menu.style.left = left + 'px';
        menu.style.top = top + 'px';

        requestAnimationFrame(() => menu.classList.add('active'));

        const openedAt = Date.now();
        const close = () => {
            menu.remove();
            document.removeEventListener('mousedown', onOutside);
            document.removeEventListener('touchstart', onOutside);
        };
        const onOutside = (ev) => {
            if (menu.contains(ev.target)) return;
            if (Date.now() - openedAt < 400) return;
            close();
        };
        const run = (ev) => {
            const btn = ev.target.closest('.quick-context-item');
            if (!btn) return;
            ev.preventDefault();
            ev.stopPropagation();
            const item = items[parseInt(btn.dataset.idx, 10)];
            close();
            if (item && typeof item.action === 'function') item.action();
        };
        menu.addEventListener('click', run);
        menu.addEventListener('touchend', run);
        document.addEventListener('mousedown', onOutside);
        document.addEventListener('touchstart', onOutside);
    },

    _buildSidebarMenuItems(itemEl) {
        const favSvg = '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>';
        const hideSvg = '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46A11.8 11.8 0 0 0 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>';
        const blockSvg = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><line x1="5.6" y1="5.6" x2="18.4" y2="18.4"/></svg>';
        const leaveSvg = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>';

        // Public channel
        if (itemEl.classList.contains('channel-item')) {
            const channel = itemEl.dataset.channel;
            const geohash = itemEl.dataset.geohash;
            const key = geohash || channel;
            if (key === 'nymchat') return [];
            const isFavorited = this.pinnedChannels.has(key);
            const isHidden = this.hiddenChannels.has(key);
            return [
                {
                    label: isFavorited ? 'Unfavorite channel' : 'Favorite channel',
                    svg: favSvg,
                    action: () => this.togglePin(channel, geohash)
                },
                {
                    label: isHidden ? 'Unhide channel' : 'Hide channel',
                    svg: hideSvg,
                    action: () => this.toggleHideChannel(channel, geohash)
                },
                {
                    label: 'Block channel',
                    svg: blockSvg,
                    cls: 'danger',
                    action: () => {
                        const name = geohash || channel;
                        if (!confirm(`Block channel #${name}? Messages to it will be dropped.`)) return;
                        this.blockChannel(channel, geohash);
                        this.displaySystemMessage(`Blocked channel #${name}`);
                        if (typeof this.updateBlockedChannelsList === 'function') this.updateBlockedChannelsList();
                    }
                }
            ];
        }

        // Group conversation
        if (itemEl.classList.contains('group-item')) {
            const groupId = itemEl.dataset.groupId;
            return [
                {
                    label: 'Leave conversation',
                    svg: leaveSvg,
                    cls: 'danger',
                    action: () => this.deleteGroup(groupId)
                }
            ];
        }

        // 1:1 private message
        if (itemEl.classList.contains('pm-item')) {
            const pubkey = itemEl.dataset.pubkey;
            if (!pubkey) return [];
            const isBlocked = this.blockedUsers.has(pubkey);
            return [
                {
                    label: isBlocked ? 'Unblock user' : 'Block user',
                    svg: blockSvg,
                    cls: isBlocked ? '' : 'danger',
                    action: () => this.toggleBlockUserByPubkey(pubkey)
                },
                {
                    label: 'Leave conversation',
                    svg: leaveSvg,
                    cls: 'danger',
                    action: () => this.deletePM(pubkey)
                }
            ];
        }

        return [];
    },

    setupSidebarItemMenus() {
        const MOVE_THRESHOLD = 10;
        let pressTimer = null;
        let startX = 0, startY = 0;
        let fired = false;

        const cancel = () => {
            if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
        };

        const onStart = (itemEl, x, y) => {
            startX = x; startY = y;
            fired = false;
            cancel();
            pressTimer = setTimeout(() => {
                pressTimer = null;
                const items = this._buildSidebarMenuItems(itemEl);
                if (!items.length) return;
                fired = true;
                window.nymHapticTap && window.nymHapticTap();
                this._showSidebarActionMenu(items, x, y);
            }, 500);
        };

        const attach = (listId) => {
            const list = document.getElementById(listId);
            if (!list) return;

            list.addEventListener('mousedown', (e) => {
                if (e.button !== 0) return;
                const itemEl = e.target.closest('.channel-item, .pm-item');
                if (!itemEl || !list.contains(itemEl)) return;
                onStart(itemEl, e.clientX, e.clientY);
            });
            list.addEventListener('touchstart', (e) => {
                const itemEl = e.target.closest('.channel-item, .pm-item');
                if (!itemEl || !list.contains(itemEl)) return;
                const t = e.touches && e.touches[0];
                if (t) onStart(itemEl, t.clientX, t.clientY);
            }, { passive: true });

            list.addEventListener('mousemove', (e) => {
                if (!pressTimer) return;
                if (Math.abs(e.clientX - startX) > MOVE_THRESHOLD ||
                    Math.abs(e.clientY - startY) > MOVE_THRESHOLD) cancel();
            });
            list.addEventListener('touchmove', (e) => {
                if (!pressTimer) return;
                const t = e.touches && e.touches[0];
                if (t && (Math.abs(t.clientX - startX) > MOVE_THRESHOLD ||
                    Math.abs(t.clientY - startY) > MOVE_THRESHOLD)) cancel();
            }, { passive: true });

            list.addEventListener('mouseup', cancel);
            list.addEventListener('mouseleave', cancel);
            list.addEventListener('touchend', (e) => {
                cancel();
                if (fired) { e.preventDefault(); fired = false; }
            });
            list.addEventListener('touchcancel', cancel);
            // Suppress the click that opens the conversation when the menu fired
            list.addEventListener('click', (e) => {
                if (fired) { e.preventDefault(); e.stopPropagation(); fired = false; }
            }, true);
        };

        attach('channelList');
        attach('pmList');
    },

    setupSidebarSectionReorder() {
        const els = this._getSidebarSectionEls();
        if (!els.length) return;

        // Restore a previously saved order
        try {
            const stored = JSON.parse(localStorage.getItem('nym_sidebar_section_order') || 'null');
            if (Array.isArray(stored)) this._applySidebarSectionOrder(stored);
        } catch (_) { }
        this._refreshSidebarReorderButtons();

        let pressTimer = null;
        let startX = 0, startY = 0;
        const MOVE_THRESHOLD = 10;

        const cancelPress = () => {
            if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
        };

        for (const sectionEl of els) {
            const title = sectionEl.querySelector('.nav-title');
            if (!title) continue;

            const startPress = (x, y) => {
                startX = x; startY = y;
                cancelPress();
                pressTimer = setTimeout(() => {
                    pressTimer = null;
                    this._setSidebarReorderMode(!document.body.classList.contains('sidebar-reorder-mode'));
                }, 500);
            };

            title.addEventListener('mousedown', (e) => {
                if (e.button !== 0 || e.target.closest('.section-reorder-arrows')) return;
                startPress(e.clientX, e.clientY);
            });
            title.addEventListener('touchstart', (e) => {
                if (e.target.closest('.section-reorder-arrows')) return;
                const t = e.touches && e.touches[0];
                if (t) startPress(t.clientX, t.clientY);
            }, { passive: true });

            title.addEventListener('mousemove', (e) => {
                if (!pressTimer) return;
                if (Math.abs(e.clientX - startX) > MOVE_THRESHOLD ||
                    Math.abs(e.clientY - startY) > MOVE_THRESHOLD) cancelPress();
            });
            title.addEventListener('touchmove', (e) => {
                if (!pressTimer) return;
                const t = e.touches && e.touches[0];
                if (t && (Math.abs(t.clientX - startX) > MOVE_THRESHOLD ||
                    Math.abs(t.clientY - startY) > MOVE_THRESHOLD)) cancelPress();
            }, { passive: true });

            title.addEventListener('mouseup', cancelPress);
            title.addEventListener('mouseleave', cancelPress);
            title.addEventListener('touchend', cancelPress);
            title.addEventListener('touchcancel', cancelPress);

            const arrows = title.querySelector('.section-reorder-arrows');
            if (arrows) {
                arrows.addEventListener('click', (e) => {
                    const moveBtn = e.target.closest('.section-reorder-btn');
                    if (!moveBtn || moveBtn.disabled) return;
                    e.stopPropagation();
                    this._moveSidebarSection(sectionEl, moveBtn.dataset.sectionMove);
                });
            }
        }
    },

});
