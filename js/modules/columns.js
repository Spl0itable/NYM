// columns.js - Optional multi-column chat view

Object.assign(NYM.prototype, {

    _cvColKey(desc) {
        if (!desc) return null;
        if (desc.type === 'channel') return desc.geohash ? `#${desc.geohash}` : desc.channel;
        if (desc.type === 'pm') return this.getPMConversationKey(desc.pubkey);
        if (desc.type === 'group') return this.getGroupConversationKey(desc.groupId);
        return null;
    },

    _cvListForKey(key) {
        if (!key || !this._cvKeyToList) return null;
        return this._cvKeyToList.get(key) || null;
    },

    applyChatViewMode(mode) {
        if (mode === 'columns') this._cvEnable();
        else this._cvDisable();
    },

    _cvEnable() {
        if (this._cvActive) { this._cvSeedIfNeeded(); return; }
        this._cvColumns = this._cvColumns || [];
        this._cvKeyToList = this._cvKeyToList || new Map();
        this._cvBuildStrip();
        document.body.classList.add('columns-mode');
        this._cvActive = true;
        // Clear the (now hidden) single-view container so its stale message
        // nodes don't trip the global dedupe and leave columns empty.
        const mc = document.getElementById('messagesContainer');
        if (mc) { mc.innerHTML = ''; mc.dataset.lastChannel = ''; }
        this._cvSeedIfNeeded();
        if (!this._cvColumns.length) this._cvSeedDefaults();
        this._cvRenderAll();
        const firstChannel = this._cvColumns.find(c => c.type === 'channel');
        this._cvPrimaryId = firstChannel ? firstChannel.id : null;
        const first = this._cvColumns[0];
        if (first) this._cvFocusColumn(first.id);
        this._cvRefreshPager();
    },

    _cvDisable() {
        if (!this._cvActive) return;
        const focused = this._cvColumns.find(c => c.id === this._cvFocusedId) || this._cvColumns[0];
        this._cvActive = false;
        document.body.classList.remove('columns-mode');
        // Tear down in-memory column state (but keep the saved layout) so a later
        // re-enable rebuilds the same columns from storage instead of reusing
        // stale objects whose DOM was removed with the strip.
        for (const c of (this._cvColumns || [])) { if (c._observer) c._observer.disconnect(); }
        if (this._cvStrip) { this._cvStrip.remove(); this._cvStrip = null; }
        if (this._cvPager) { this._cvPager.remove(); this._cvPager = null; }
        this._cvKeyToList && this._cvKeyToList.clear();
        this._cvColumns = [];
        this._cvSeeded = false;
        this._cvPrimaryId = null;
        this._cvFocusedId = null;
        // Reset active-conversation state so the reopened conversation does a
        // full render instead of being skipped as "already current".
        this.inPMMode = false;
        this.currentChannel = null; this.currentGeohash = null;
        this.currentPM = null; this.currentGroup = null;
        const mc = document.getElementById('messagesContainer');
        if (mc) mc.dataset.lastChannel = '';
        // Restore the single view by reopening the previously focused conversation
        if (focused) this._cvOpenInSingleView(focused);
        else this.switchChannel('nymchat', 'nymchat');
    },

    _cvOpenInSingleView(desc) {
        if (desc.type === 'channel') this.switchChannel(desc.channel, desc.geohash || '');
        else if (desc.type === 'pm') this.openPM(desc.nym, desc.pubkey);
        else if (desc.type === 'group') this.openGroup(desc.groupId);
    },

    _cvBuildStrip() {
        const anchor = document.getElementById('messagesScroller');
        if (!anchor || this._cvStrip) return;

        const strip = document.createElement('div');
        strip.id = 'columnsStrip';
        strip.className = 'cv-strip';
        const addBtn = document.createElement('button');
        addBtn.className = 'cv-add-column';
        addBtn.type = 'button';
        addBtn.textContent = '+ Add column';
        strip.appendChild(addBtn);
        anchor.parentNode.insertBefore(strip, anchor.nextSibling);
        this._cvStrip = strip;

        const pager = document.createElement('div');
        pager.id = 'columnsPager';
        pager.className = 'cv-pager';
        strip.parentNode.insertBefore(pager, strip.nextSibling);
        this._cvPager = pager;

        // Message swipe / double-click reply work inside every column via
        // delegation on the strip.
        this.setupSwipeToReply(strip);
        this.setupDoubleClickToReply(strip);

        strip.addEventListener('click', (e) => {
            const move = e.target.closest('.cv-col-move');
            if (move) { e.stopPropagation(); this._cvMoveColumn(move.dataset.colId, move.dataset.dir === 'right' ? 1 : -1); return; }
            const close = e.target.closest('.cv-col-close');
            if (close && !close.classList.contains('cv-picker-close')) {
                e.stopPropagation(); this.cvRequestRemoveColumn(close.dataset.colId); return;
            }
            if (e.target.closest('.cv-add-column')) { this._cvOpenAddColumn(); return; }
            if (e.target.closest('.cv-picker')) return;
            const colEl = e.target.closest('.cv-column');
            if (colEl && colEl.dataset.colId && colEl.dataset.colId !== this._cvFocusedId) {
                const col = this._cvColumns.find(c => c.id === colEl.dataset.colId);
                if (col) this._cvOpenConversation(this._cvDescForSave(col));
            }
        });

        let pendingScroll = false;
        strip.addEventListener('scroll', () => {
            if (pendingScroll) return;
            pendingScroll = true;
            requestAnimationFrame(() => { pendingScroll = false; this._cvOnStripScroll(); });
        }, { passive: true });

        pager.addEventListener('click', (e) => {
            const dot = e.target.closest('.cv-pager-dot');
            if (!dot) return;
            if (dot.dataset.add) { this._cvOpenAddColumn(); return; }
            this._cvScrollToIndex(parseInt(dot.dataset.idx, 10));
        });

        this._cvSetupPagerScrub(pager);
    },

    _cvSetupPagerScrub(pager) {
        let timer = null, active = false, lastX = 0;
        const clearTimer = () => { if (timer) { clearTimeout(timer); timer = null; } };
        const dotAt = (x) => {
            let best = null, bestDist = Infinity;
            pager.querySelectorAll('.cv-pager-dot').forEach((d) => {
                const r = d.getBoundingClientRect();
                const dist = Math.abs((r.left + r.right) / 2 - x);
                if (dist < bestDist) { bestDist = dist; best = d; }
            });
            return best;
        };
        const labelFor = (dot) => {
            if (!dot) return '';
            if (dot.dataset.add) return 'Add column';
            const col = this._cvColumns[parseInt(dot.dataset.idx, 10)];
            if (!col) return '';
            return col.type === 'channel' ? '#' + (col.geohash || col.channel) : this._cvColTitle(col);
        };
        const showLabel = (dot) => {
            if (!this._cvPagerLabel) {
                this._cvPagerLabel = document.createElement('div');
                this._cvPagerLabel.className = 'cv-pager-label';
                document.body.appendChild(this._cvPagerLabel);
            }
            const lbl = this._cvPagerLabel;
            lbl.textContent = labelFor(dot);
            const pr = pager.getBoundingClientRect();
            lbl.style.left = Math.max(8, Math.min(window.innerWidth - 8, lastX)) + 'px';
            lbl.style.bottom = (window.innerHeight - pr.top + 8) + 'px';
            lbl.classList.add('visible');
            pager.querySelectorAll('.cv-pager-dot.scrub').forEach(d => d.classList.remove('scrub'));
            if (dot) dot.classList.add('scrub');
        };
        const hideLabel = () => {
            if (this._cvPagerLabel) this._cvPagerLabel.classList.remove('visible');
            pager.querySelectorAll('.cv-pager-dot.scrub').forEach(d => d.classList.remove('scrub'));
        };
        pager.addEventListener('touchstart', (e) => {
            lastX = e.touches[0].clientX;
            clearTimer();
            active = false;
            timer = setTimeout(() => {
                active = true;
                if (window.nymHapticTap) window.nymHapticTap();
                showLabel(dotAt(lastX));
            }, 300);
        }, { passive: true });
        pager.addEventListener('touchmove', (e) => {
            lastX = e.touches[0].clientX;
            if (!active) return;
            e.preventDefault();
            showLabel(dotAt(lastX));
        }, { passive: false });
        pager.addEventListener('touchend', (e) => {
            clearTimer();
            if (!active) return;
            active = false;
            const dot = dotAt(lastX);
            hideLabel();
            if (!dot) return;
            e.preventDefault();
            if (dot.dataset.add) { this._cvOpenAddColumn(); return; }
            const col = this._cvColumns[parseInt(dot.dataset.idx, 10)];
            if (col) { this._cvScrollToIndex(this._cvColumns.indexOf(col)); this._cvFocusColumn(col.id); }
        });
        pager.addEventListener('touchcancel', () => { clearTimer(); active = false; hideLabel(); });
    },

    _cvSeedIfNeeded() {
        if (this._cvSeeded) return;
        const saved = this._cvLoadLayout();
        if (saved && saved.length) {
            this._cvColumns = [];
            for (const d of saved) this.cvAddColumn(d, { render: false, save: false, focus: false });
            this._cvSeeded = true;
        }
    },

    _cvSeedDefaults() {
        const descs = [{ type: 'channel', channel: 'nymchat', geohash: 'nymchat' }];
        const pm = this._cvMostRecent(this.pmConversations);
        if (pm) descs.push({ type: 'pm', pubkey: pm.key, nym: pm.val.nym });
        const grp = this._cvMostRecent(this.groupConversations);
        if (grp) descs.push({ type: 'group', groupId: grp.key });
        for (const d of descs) this.cvAddColumn(d, { render: false, save: false, focus: false });
        this._cvSeeded = true;
        this._cvSaveLayout();
    },

    _cvMostRecent(map) {
        if (!map || !map.size) return null;
        let best = null, max = -1;
        for (const [key, val] of map) {
            const t = (val && val.lastMessageTime) || 0;
            if (t > max) { max = t; best = { key, val }; }
        }
        return best;
    },

    cvAddColumn(desc, opts = {}) {
        const { render = true, save = true, focus = true } = opts;
        const key = this._cvColKey(desc);
        if (!key) return;
        const existing = this._cvColumns.find(c => c.key === key);
        if (existing) { if (focus) this._cvFocusColumn(existing.id); return; }
        const col = { id: 'cvc_' + Math.random().toString(36).slice(2, 9), key, ...desc };
        this._cvColumns.push(col);
        if (desc.type === 'channel') this._cvSubscribeChannel(desc.channel, desc.geohash);
        this._cvBuildColumnEl(col);
        this._cvKeyToList.set(key, col.listEl);
        if (render) { this._cvRenderColumn(col); this._cvRefreshPager(); }
        if (save) this._cvSaveLayout();
        if (focus) this._cvFocusColumn(col.id);
    },

    // Confirm before removing a column, with an opt-out the user can persist.
    cvRequestRemoveColumn(id) {
        const col = this._cvColumns.find(c => c.id === id);
        if (!col) return;
        if (localStorage.getItem('nym_columns_skip_delete_confirm') === 'true' || typeof window.showAppConfirm !== 'function') {
            this.cvRemoveColumn(id);
            return;
        }
        const title = this._cvColTitle(col);
        Promise.resolve(window.showAppConfirm(`Remove the "${title}" column? You can add it back anytime.`, {
            title: 'Remove column', okLabel: 'Remove', danger: true, checkboxLabel: "Don't ask again"
        })).then((res) => {
            const confirmed = (res && typeof res === 'object') ? res.confirmed : res;
            if (!confirmed) return;
            if (res && typeof res === 'object' && res.checked) {
                try { localStorage.setItem('nym_columns_skip_delete_confirm', 'true'); } catch (_) { }
            }
            this.cvRemoveColumn(id);
        });
    },

    cvRemoveColumn(id) {
        const idx = this._cvColumns.findIndex(c => c.id === id);
        if (idx < 0) return;
        const col = this._cvColumns[idx];
        this._cvKeyToList.delete(col.key);
        if (col._observer) col._observer.disconnect();
        if (col.el) col.el.remove();
        this._cvColumns.splice(idx, 1);
        if (this._cvPrimaryId === id) this._cvPrimaryId = null;
        if (this._cvFocusedId === id) {
            const next = this._cvColumns[Math.min(idx, this._cvColumns.length - 1)];
            if (next) this._cvFocusColumn(next.id);
        }
        this._cvSaveLayout();
        this._cvRefreshPager();
    },

    // Central entry point for opening a conversation in column view. Existing
    // column -> focus it; channel with a live primary column -> navigate that
    // column; otherwise add a new column. Mirrors single-view nav history so
    // the back/forward buttons drive column navigation too.
    _cvOpenConversation(desc, opts = {}) {
        const key = this._cvColKey(desc);
        if (!key) return;
        const existing = this._cvColumns.find(c => c.key === key);
        if (existing) {
            this._cvFocusColumn(existing.id);
            this._cvScrollToCol(existing);
        } else if (!opts.forceNew && desc.type === 'channel' &&
            this._cvColumns.some(c => c.id === this._cvPrimaryId && c.type === 'channel')) {
            const primary = this._cvColumns.find(c => c.id === this._cvPrimaryId);
            this._cvNavigateColumn(primary, desc);
            this._cvFocusColumn(primary.id);
            this._cvScrollToCol(primary);
        } else {
            this.cvAddColumn(desc, { focus: true });
            const created = this._cvColumns.find(c => c.key === key);
            if (created) this._cvScrollToCol(created);
        }
        if (!this._navigating && typeof this._pushNavigation === 'function') {
            this._pushNavigation(this._cvNavEntry(desc));
        }
    },

    _cvNavEntry(desc) {
        if (desc.type === 'pm') return { type: 'pm', nym: desc.nym, pubkey: desc.pubkey };
        if (desc.type === 'group') return { type: 'group', groupId: desc.groupId };
        return { type: 'channel', channel: desc.channel, geohash: desc.geohash || '' };
    },

    _cvScrollToCol(col) {
        const idx = this._cvColumns.indexOf(col);
        if (idx >= 0) this._cvScrollToIndex(idx);
    },

    // Repurpose an existing column to show a different conversation in place.
    _cvNavigateColumn(col, desc) {
        this._cvKeyToList.delete(col.key);
        col.type = desc.type;
        col.channel = desc.channel; col.geohash = desc.geohash || '';
        col.pubkey = desc.pubkey || null; col.nym = desc.nym || null; col.groupId = desc.groupId || null;
        col.key = this._cvColKey(col);
        this._cvKeyToList.set(col.key, col.listEl);
        if (col.type === 'channel') this._cvSubscribeChannel(col.channel, col.geohash);
        const iconEl = col.headerEl.querySelector('.cv-col-icon');
        const titleEl = col.headerEl.querySelector('.cv-col-title');
        if (iconEl) iconEl.innerHTML = this._cvColIcon(col);
        if (titleEl) titleEl.textContent = this._cvColTitle(col);
        col.listEl.innerHTML = '';
        this._cvRenderColumn(col);
        this._cvSaveLayout();
    },

    // Move a column one slot left/right (mobile reorder, no drag).
    _cvMoveColumn(id, dir) {
        const from = this._cvColumns.findIndex(c => c.id === id);
        if (from < 0) return;
        const to = from + dir;
        if (to < 0 || to >= this._cvColumns.length) return;
        const [moved] = this._cvColumns.splice(from, 1);
        this._cvColumns.splice(to, 0, moved);
        const addBtn = this._cvStrip.querySelector('.cv-add-column');
        for (const c of this._cvColumns) this._cvStrip.insertBefore(c.el, addBtn || null);
        this._cvSaveLayout();
        this._cvRefreshPager();
        this._cvScrollToCol(moved);
    },

    // Reset columns back to the seeded defaults.
    cvResetColumns() {
        try { localStorage.removeItem('nym_columns_layout'); } catch (_) { }
        this.columnsLayout = [];
        this._cvSeeded = false;
        if (!this._cvActive) {
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
            return;
        }
        for (const c of [...this._cvColumns]) { if (c._observer) c._observer.disconnect(); if (c.el) c.el.remove(); }
        this._cvColumns = [];
        this._cvKeyToList.clear();
        this._cvSeedDefaults();
        this._cvRenderAll();
        const firstChannel = this._cvColumns.find(c => c.type === 'channel');
        this._cvPrimaryId = firstChannel ? firstChannel.id : null;
        const first = this._cvColumns[0];
        if (first) this._cvFocusColumn(first.id);
        this._cvRefreshPager();
    },

    _cvBuildColumnEl(col) {
        const el = document.createElement('div');
        el.className = 'cv-column';
        el.dataset.colId = col.id;
        el.draggable = false;

        const header = document.createElement('div');
        header.className = 'cv-column-header';
        header.innerHTML =
            `<span class="cv-drag-handle" title="Drag to reorder"><svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><circle cx="9" cy="6" r="1.4"/><circle cx="15" cy="6" r="1.4"/><circle cx="9" cy="12" r="1.4"/><circle cx="15" cy="12" r="1.4"/><circle cx="9" cy="18" r="1.4"/><circle cx="15" cy="18" r="1.4"/></svg></span>` +
            `<span class="cv-col-icon">${this._cvColIcon(col)}</span>` +
            `<span class="cv-col-title">${this.escapeHtml(this._cvColTitle(col))}</span>` +
            `<span class="cv-col-unread"></span>` +
            `<button class="cv-col-move cv-col-move-left" data-col-id="${col.id}" data-dir="left" title="Move left" aria-label="Move left"><svg viewBox="0 0 24 24" width="16" height="16" stroke="currentColor" stroke-width="2" fill="none"><polyline points="15 18 9 12 15 6"/></svg></button>` +
            `<button class="cv-col-move cv-col-move-right" data-col-id="${col.id}" data-dir="right" title="Move right" aria-label="Move right"><svg viewBox="0 0 24 24" width="16" height="16" stroke="currentColor" stroke-width="2" fill="none"><polyline points="9 18 15 12 9 6"/></svg></button>` +
            `<button class="cv-col-close" data-col-id="${col.id}" title="Remove column" aria-label="Remove column"><svg viewBox="0 0 24 24" width="16" height="16" stroke="currentColor" stroke-width="2" fill="none"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button>`;

        const scroller = document.createElement('div');
        scroller.className = 'cv-column-scroller messages-container cv-scroller';
        const list = document.createElement('div');
        list.className = 'cv-column-list messages-list cv-list';
        scroller.appendChild(list);

        el.appendChild(header);
        el.appendChild(scroller);

        const typing = document.createElement('div');
        typing.className = 'typing-indicator cv-typing';
        typing.innerHTML = '<div class="typing-indicator-avatars"></div><div class="typing-indicator-dots"><span></span><span></span><span></span></div><div class="typing-indicator-text"></div>';
        el.appendChild(typing);

        const addBtn = this._cvStrip.querySelector('.cv-add-column');
        this._cvStrip.insertBefore(el, addBtn || null);

        col.el = el;
        col.headerEl = header;
        col.scrollerEl = scroller;
        col.listEl = list;
        col.typingEl = typing;
        col.typingAvatarsEl = typing.querySelector('.typing-indicator-avatars');
        col.typingTextEl = typing.querySelector('.typing-indicator-text');
        col._atBottom = true;

        this._cvAttachColumnScroll(col);
        this._cvAttachAutoScroll(col);
        this._cvAttachDnd(col);
    },

    // Pin a column to the latest message when new ones arrive and the user is
    // already at the bottom (mirrors single-view autoscroll, per column).
    _cvAttachAutoScroll(col) {
        if (typeof MutationObserver === 'undefined') return;
        let pending = false;
        col._observer = new MutationObserver((mutations) => {
            if (this.settings && this.settings.autoscroll === false) return;
            if (!col._atBottom || pending) return;
            if (!mutations.some(m => m.addedNodes && m.addedNodes.length)) return;
            pending = true;
            requestAnimationFrame(() => {
                pending = false;
                if (col._atBottom && col.scrollerEl) col.scrollerEl.scrollTop = 0;
            });
        });
        col._observer.observe(col.listEl, { childList: true });
    },

    _cvColIcon(col) {
        if (col.type === 'pm' && col.pubkey) {
            const src = this.getAvatarUrl(col.pubkey);
            return `<img class="avatar-pm" src="${this.escapeHtml(src)}" data-avatar-pubkey="${this._safePubkey(col.pubkey)}" alt="" width="20" height="20" decoding="async" loading="lazy">`;
        }
        if (col.type === 'group') {
            const g = this.groupConversations && this.groupConversations.get(col.groupId);
            if (g && g.avatar) {
                return `<img class="avatar-pm" src="${this.escapeHtml(g.avatar)}" alt="" width="20" height="20" decoding="async" loading="lazy">`;
            }
            return `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
        }
        return '#';
    },

    _cvColTitle(col) {
        if (col.type === 'channel') return col.geohash || col.channel;
        if (col.type === 'pm') {
            const conv = this.pmConversations && this.pmConversations.get(col.pubkey);
            return (conv && conv.nym) || col.nym || (this.getDisplayNym && this.getDisplayNym(col.pubkey)) || 'Direct message';
        }
        if (col.type === 'group') {
            const g = this.groupConversations && this.groupConversations.get(col.groupId);
            return (g && g.name) || 'Group chat';
        }
        return 'Column';
    },

    _cvRenderColumn(col) {
        if (!col.listEl) return;
        const isPM = col.type !== 'channel';
        this.renderMessagesWithVirtualScroll(col.listEl, col.key, false, isPM);
        if (col.scrollerEl) col.scrollerEl.scrollTop = 0;
    },

    _cvRenderAll() {
        for (const col of this._cvColumns) this._cvRenderColumn(col);
    },

    _cvSubscribeChannel(channel, geohash) {
        const key = geohash || channel;
        if (!key) return;
        if (this.channels && !this.channels.has(key) && typeof this.addChannel === 'function') {
            this.addChannel(channel, geohash || '');
        }
        if (this.userJoinedChannels && geohash) this.userJoinedChannels.add(geohash);
        if (typeof this.channelRestoreFromD1 === 'function') this.channelRestoreFromD1(key);
        if (geohash) {
            if (typeof this.connectToGeoRelays === 'function') this.connectToGeoRelays(geohash);
            if (typeof this.startGeoRelayKeepAlive === 'function') this.startGeoRelayKeepAlive(geohash);
        }
        if (typeof this.ensureDefaultRelaysConnected === 'function') this.ensureDefaultRelaysConnected();
        if (typeof this.loadChannelFromRelays === 'function') {
            const channelType = (geohash && this.isValidGeohash(geohash)) ? 'geohash' : 'non-geohash';
            this.loadChannelFromRelays(key, channelType);
            if (typeof this._ensureChannelTypingSub === 'function') {
                this._ensureChannelTypingSub(key, channelType, true);
            }
        }
    },

    _cvFocusColumn(id) {
        const col = this._cvColumns.find(c => c.id === id);
        if (!col) return;
        this._cvFocusedId = id;
        for (const c of this._cvColumns) c.el && c.el.classList.toggle('focused', c.id === id);

        this._saveCurrentDraft && this._saveCurrentDraft();
        if (col.type === 'channel') {
            this.inPMMode = false; this.currentPM = null; this.currentGroup = null;
            this.currentChannel = col.channel; this.currentGeohash = col.geohash || '';
        } else if (col.type === 'pm') {
            this.inPMMode = true; this.currentPM = col.pubkey; this.currentGroup = null;
            this.currentChannel = null; this.currentGeohash = null;
        } else {
            this.inPMMode = true; this.currentGroup = col.groupId; this.currentPM = null;
            this.currentChannel = null; this.currentGeohash = null;
        }
        this.clearQuoteReply && this.clearQuoteReply();
        if (this.pendingEdit && this.cancelEditMessage) this.cancelEditMessage();
        this._cvSetComposeHeader(col);
        this._restoreDraftForContext && this._restoreDraftForContext();
        if (col.type === 'group' && typeof this._markVisibleGroupMessagesRead === 'function') {
            this._markVisibleGroupMessagesRead();
        } else if (col.type === 'channel' && typeof this.markVisibleChannelMessagesRead === 'function') {
            this.markVisibleChannelMessagesRead();
        }
    },

    _cvTypingKey(col) {
        if (col.type === 'group') return this.getGroupConversationKey(col.groupId);
        if (col.type === 'pm') return this.getPMConversationKey(col.pubkey);
        if (col.type === 'channel' && col.geohash) return `channel-${col.geohash}`;
        return null;
    },

    _cvRenderTyping() {
        const g = document.getElementById('typingIndicator');
        if (g) g.classList.remove('active');
        for (const col of this._cvColumns) {
            if (col.typingEl && typeof this._renderTypingInto === 'function') {
                this._renderTypingInto(col.typingEl, col.typingAvatarsEl, col.typingTextEl, this._cvTypingKey(col));
            }
        }
    },

    // Mirror the single-view header for the focused column's conversation type.
    _cvSetComposeHeader(col) {
        if (col.type === 'channel') {
            this._renderChannelTitle(col.channel, col.geohash || '');
            const shareBtn = document.getElementById('shareChannelBtn');
            if (shareBtn) shareBtn.style.display = 'block';
            const favBtn = document.getElementById('favoriteChannelBtn');
            if (favBtn) favBtn.style.display = '';
            if (this._refreshFavoriteChannelBtn) this._refreshFavoriteChannelBtn();
            if (this._refreshCallButtons) this._refreshCallButtons();
            if (this.updateUserList) this.updateUserList();
        } else if (col.type === 'pm') {
            this._renderPMHeader(col.nym, col.pubkey);
        } else if (col.type === 'group') {
            this._renderGroupHeader(col.groupId);
        }
    },

    _cvFocusedListEl() {
        const col = this._cvColumns && this._cvColumns.find(c => c.id === this._cvFocusedId);
        return col ? col.listEl : null;
    },

    _cvAttachColumnScroll(col) {
        let pending = false;
        const handler = () => {
            const sc = col.scrollerEl;
            const distanceFromBottom = Math.abs(sc.scrollTop);
            col._atBottom = distanceFromBottom < 120;
            const distanceFromTop = (sc.scrollHeight - sc.clientHeight) - distanceFromBottom;
            if (distanceFromTop <= 5 && !col._loadingOlder) {
                const isPM = col.type !== 'channel';
                const startMap = isPM ? this.pmRenderedStart : this.channelRenderedStart;
                const startIdx = startMap.get(col.key);
                if (startIdx !== undefined && startIdx > 0) {
                    col._loadingOlder = true;
                    this._cvLoadCtx = { container: col.listEl, scroller: col.scrollerEl };
                    requestAnimationFrame(() => {
                        if (isPM) this.loadOlderPMMessages(col.key);
                        else this.loadOlderChannelMessages(col.key);
                        this._cvLoadCtx = null;
                        col._loadingOlder = false;
                    });
                }
            }
        };
        col.scrollerEl.addEventListener('scroll', () => {
            if (pending) return;
            pending = true;
            requestAnimationFrame(() => { pending = false; handler(); });
        }, { passive: true });
    },

    _cvAttachDnd(col) {
        const el = col.el, header = col.headerEl;
        header.addEventListener('mousedown', () => { el.draggable = true; });
        header.addEventListener('mouseup', () => { el.draggable = false; });
        el.addEventListener('dragstart', (e) => {
            this._cvDragId = col.id;
            el.classList.add('cv-dragging');
            e.dataTransfer.effectAllowed = 'move';
            try { e.dataTransfer.setData('text/plain', col.id); } catch (_) { }
        });
        el.addEventListener('dragend', () => {
            el.draggable = false;
            el.classList.remove('cv-dragging');
            this._cvStrip.querySelectorAll('.cv-drag-over').forEach(c => c.classList.remove('cv-drag-over'));
            this._cvDragId = null;
        });
        el.addEventListener('dragover', (e) => {
            if (!this._cvDragId || this._cvDragId === col.id) return;
            e.preventDefault();
            el.classList.add('cv-drag-over');
        });
        el.addEventListener('dragleave', () => el.classList.remove('cv-drag-over'));
        el.addEventListener('drop', (e) => {
            e.preventDefault();
            el.classList.remove('cv-drag-over');
            if (!this._cvDragId || this._cvDragId === col.id) return;
            const rect = el.getBoundingClientRect();
            const after = (e.clientX - rect.left) > rect.width / 2;
            this._cvReorder(this._cvDragId, col.id, after);
        });
    },

    _cvReorder(dragId, targetId, after) {
        const from = this._cvColumns.findIndex(c => c.id === dragId);
        if (from < 0) return;
        const [moved] = this._cvColumns.splice(from, 1);
        let to = this._cvColumns.findIndex(c => c.id === targetId);
        if (to < 0) { this._cvColumns.splice(from, 0, moved); return; }
        if (after) to += 1;
        this._cvColumns.splice(to, 0, moved);
        const addBtn = this._cvStrip.querySelector('.cv-add-column');
        for (const c of this._cvColumns) this._cvStrip.insertBefore(c.el, addBtn || null);
        this._cvSaveLayout();
        this._cvRefreshPager();
    },

    // Add-column picker (a column-shaped panel inside the strip)
    _cvOpenAddColumn() {
        if (this._cvStrip.querySelector('.cv-picker')) return;
        const panel = document.createElement('div');
        panel.className = 'cv-column cv-picker';
        panel.innerHTML =
            `<div class="cv-column-header"><span class="cv-col-title">Add a column</span>` +
            `<button class="cv-col-close cv-picker-close" title="Cancel" aria-label="Cancel"><svg viewBox="0 0 24 24" width="16" height="16" stroke="currentColor" stroke-width="2" fill="none"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></div>` +
            `<div class="cv-picker-search"><input type="text" class="form-input cv-picker-input" placeholder="Search conversations…" autocomplete="off"></div>` +
            `<div class="cv-picker-list"></div>`;
        const addBtn = this._cvStrip.querySelector('.cv-add-column');
        this._cvStrip.insertBefore(panel, addBtn || null);
        if (addBtn) addBtn.style.display = 'none';

        const listEl = panel.querySelector('.cv-picker-list');
        const input = panel.querySelector('.cv-picker-input');
        const close = () => { panel.remove(); if (addBtn) addBtn.style.display = ''; };
        panel.querySelector('.cv-picker-close').addEventListener('click', close);

        const rows = this._cvAvailableConversations();
        const renderRows = (filter) => {
            const f = (filter || '').toLowerCase();
            listEl.innerHTML = '';
            const shown = rows.filter(r => !f || r.label.toLowerCase().includes(f));
            if (!shown.length) { listEl.innerHTML = '<div class="cv-picker-empty">No conversations</div>'; return; }
            for (const r of shown) {
                const row = document.createElement('button');
                row.className = 'cv-picker-row';
                row.type = 'button';
                row.innerHTML = `<span class="cv-picker-row-icon">${r.icon}</span><span class="cv-picker-row-label">${this.escapeHtml(r.label)}</span>`;
                row.addEventListener('click', () => {
                    this.cvAddColumn(r.desc, { focus: true });
                    close();
                    this._cvScrollToIndex(this._cvColumns.length - 1);
                });
                listEl.appendChild(row);
            }
        };
        renderRows('');
        input.addEventListener('input', () => renderRows(input.value));
        setTimeout(() => input.focus(), 30);
        this._cvScrollToEnd();
    },

    _cvAvailableConversations() {
        const open = new Set(this._cvColumns.map(c => c.key));
        const out = [];
        if (this.channels) {
            for (const [, ch] of this.channels) {
                const desc = { type: 'channel', channel: ch.channel, geohash: ch.geohash || '' };
                if (open.has(this._cvColKey(desc))) continue;
                out.push({ label: `#${ch.geohash || ch.channel}`, icon: '#', desc });
            }
        }
        if (this.pmConversations) {
            for (const [pubkey, conv] of this.pmConversations) {
                const desc = { type: 'pm', pubkey, nym: conv.nym };
                if (open.has(this._cvColKey(desc))) continue;
                const src = this.getAvatarUrl(pubkey);
                out.push({ label: conv.nym || 'Direct message', icon: `<img class="avatar-pm" src="${this.escapeHtml(src)}" alt="" width="20" height="20">`, desc });
            }
        }
        if (this.groupConversations) {
            for (const [groupId, g] of this.groupConversations) {
                const desc = { type: 'group', groupId };
                if (open.has(this._cvColKey(desc))) continue;
                const gicon = g.avatar
                    ? `<img class="avatar-pm" src="${this.escapeHtml(g.avatar)}" alt="" width="20" height="20">`
                    : '◧';
                out.push({ label: g.name || 'Group chat', icon: gicon, desc });
            }
        }
        return out;
    },

    // Mobile pager (snap-scroll, one column per screen)
    _cvRefreshPager() {
        if (!this._cvPager) return;
        const n = this._cvColumns.length;
        this._cvPager.innerHTML = '';
        for (let i = 0; i < n; i++) {
            const dot = document.createElement('span');
            dot.className = 'cv-pager-dot';
            dot.dataset.idx = i;
            this._cvPager.appendChild(dot);
        }
        // Trailing "+" dot opens the add-column view.
        const add = document.createElement('span');
        add.className = 'cv-pager-dot cv-pager-add';
        add.dataset.add = '1';
        add.innerHTML = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>';
        add.title = 'Add column';
        this._cvPager.appendChild(add);
        this._cvUpdatePagerActive();
    },

    _cvActiveIndex() {
        if (!this._cvStrip || !this._cvColumns.length) return 0;
        const w = this._cvStrip.clientWidth || 1;
        return Math.round(this._cvStrip.scrollLeft / w);
    },

    _cvUpdatePagerActive() {
        if (!this._cvPager) return;
        const active = this._cvActiveIndex();
        const onAdd = active >= this._cvColumns.length;
        this._cvPager.querySelectorAll('.cv-pager-dot').forEach((d, i) => {
            if (d.dataset.add) d.classList.toggle('active', onAdd);
            else d.classList.toggle('active', i === active);
        });
    },

    _cvOnStripScroll() {
        this._cvUpdatePagerActive();
        // On mobile, focusing the snapped column targets the shared input at it.
        if (window.innerWidth <= 768) {
            const col = this._cvColumns[this._cvActiveIndex()];
            if (col && col.id !== this._cvFocusedId) this._cvFocusColumn(col.id);
        }
    },

    _cvScrollToIndex(idx) {
        if (!this._cvStrip || idx < 0 || idx >= this._cvColumns.length) return;
        const col = this._cvColumns[idx];
        if (!col || !col.el) return;
        if (window.innerWidth <= 768) {
            col.el.scrollIntoView({ behavior: 'smooth', inline: 'start', block: 'nearest' });
            return;
        }
        // Desktop: columns sit side by side, so only scroll when the target is
        // partly off-screen (keeps the strip's edge padding) — never nudge a
        // column that's already fully visible.
        const strip = this._cvStrip;
        const cr = col.el.getBoundingClientRect();
        const sr = strip.getBoundingClientRect();
        if (cr.left < sr.left) strip.scrollBy({ left: cr.left - sr.left - 12, behavior: 'smooth' });
        else if (cr.right > sr.right) strip.scrollBy({ left: cr.right - sr.right + 12, behavior: 'smooth' });
    },

    _cvScrollToEnd() {
        if (this._cvStrip) this._cvStrip.scrollTo({ left: this._cvStrip.scrollWidth, behavior: 'smooth' });
    },

    // Persistence
    _cvDescForSave(col) {
        if (col.type === 'channel') return { type: 'channel', channel: col.channel, geohash: col.geohash || '' };
        if (col.type === 'pm') return { type: 'pm', pubkey: col.pubkey, nym: col.nym };
        return { type: 'group', groupId: col.groupId };
    },

    _cvSaveLayout() {
        const data = this._cvColumns.map(c => this._cvDescForSave(c));
        try { localStorage.setItem('nym_columns_layout', JSON.stringify(data)); } catch (_) { }
        this.columnsLayout = data;
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _cvLoadLayout() {
        if (Array.isArray(this.columnsLayout) && this.columnsLayout.length) return this.columnsLayout;
        try {
            const raw = localStorage.getItem('nym_columns_layout');
            if (raw) return JSON.parse(raw);
        } catch (_) { }
        return null;
    },

});
