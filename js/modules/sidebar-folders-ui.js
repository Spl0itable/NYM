(function () {
    const F = () => window.NymFolders;
    const N = () => window.NymChatNav;
    const nowSec = () => Math.floor(Date.now() / 1000);
    const SYNC_DEBOUNCE_MS = 1500;
    const JOIN_WAIT_MS = 8000;
    const HOLD_MS = 500;
    const MOVE_PX = 10;
    const svg = (p, w) => `<svg width="${w || 16}" height="${w || 16}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${p}</svg>`;
    const ICONS = {
        folder: '<svg class="sb-folder-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
        folderItem: svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'),
        plus: svg('<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>'),
        move: svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="11 10 14 13 11 16"/><line x1="7" y1="13" x2="14" y2="13"/>'),
        remove: svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><line x1="9" y1="13" x2="15" y2="13"/>'),
        rename: svg('<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/>'),
        trash: svg('<polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/>'),
        up: '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="18 15 12 9 6 15"></polyline></svg>',
        down: '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"></polyline></svg>',
        chevron: '<svg viewBox="0 0 24 24" aria-hidden="true"><polyline points="6 9 12 15 18 9"></polyline></svg>',
    };
    const dots = () => (window.NymMenuDotsIcon && typeof window.NymMenuDotsIcon.svg === 'function'
        ? window.NymMenuDotsIcon.svg({ size: 16 })
        : svg('<circle cx="12" cy="5" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="12" cy="19" r="1"/>'));
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const KEEP_CLASSES = ['active', 'has-unread', 'has-preview', 'pinned', 'chat-pinned'];

    Object.assign(NYM.prototype, {

        _sf(text, vars) {
            if (typeof this._cn === 'function') return this._cn(text, vars);
            return F().fill(text, vars);
        },

        _sfLocal() {
            return typeof this.savedMode === 'function' && this.savedMode() === 'local';
        },

        _sfVaultOn() {
            return typeof this.vaultEnabled === 'function' && this.vaultEnabled();
        },

        _sfState() {
            if (this._sfLocal()) return this._sfMem || (this._sfMem = F().emptyFolders());
            if (this._sfCache && this._sfCache.pk === this.pubkey) return this._sfCache.state;
            return F().emptyFolders();
        },

        _sfReady() {
            if (this._sfLocal()) return true;
            return !!(this.pubkey && this._sfCache && this._sfCache.pk === this.pubkey && this._sfCache.loaded);
        },

        _sfHasFolders() {
            return this._sfReady() && Object.keys(this._sfState().folders).length > 0;
        },

        async _sfLoad() {
            this._sfStart();
            if (this._sfLocal()) {
                if (!this._sfMem) this._sfMem = F().emptyFolders();
                this._sfRenderSoon(true);
                return true;
            }
            const pk = this.pubkey;
            if (!pk) return false;
            if (this._sfReady()) return true;
            let raw = null;
            try { raw = localStorage.getItem(F().KEYS.state + pk); } catch (_) { return false; }
            let migrate = false;
            if (raw && String(raw).startsWith('enc:v1:')) {
                if (!(this._sfVaultOn() && this._vaultKey)) return false;
                try { raw = await this._vaultDecrypt(raw); } catch (_) { raw = null; }
            } else if (raw && this._sfVaultOn()) {
                if (!this._vaultKey) return false;
                migrate = true;
            }
            if (this.pubkey !== pk || this._sfReady()) return this._sfReady();
            let state = F().emptyFolders();
            try { if (raw) state = F().normalizeFolders(JSON.parse(raw), Date.now()); } catch (_) { state = F().emptyFolders(); }
            this._sfCache = { pk, state, loaded: true };
            if (migrate) this._sfPersist(state);
            const queued = this._sfQueued && this._sfQueued.pk === pk ? this._sfQueued.state : null;
            this._sfQueued = null;
            if (queued) this.applySyncedFolders(queued);
            this._sfRenderSoon(true);
            if (this._sfPending()) this._sfSyncSoon(0);
            return true;
        },

        _sfPersist(state) {
            if (this._sfLocal()) { this._sfMem = state; return; }
            const pk = this.pubkey;
            if (!pk) return;
            this._sfCache = { pk, state, loaded: true };
            const name = F().KEYS.state + pk;
            const json = JSON.stringify(state);
            if (this._sfVaultOn()) {
                if (!this._vaultKey || typeof this._vaultEncrypt !== 'function') return;
                const seq = (this._sfSaveSeq = (this._sfSaveSeq || 0) + 1);
                this._vaultEncrypt(json).then((blob) => {
                    if (seq !== this._sfSaveSeq || this.pubkey !== pk) return;
                    try { localStorage.setItem(name, blob); } catch (_) { }
                }).catch(() => { });
                return;
            }
            try { localStorage.setItem(name, json); } catch (_) { }
        },

        _sfPending() {
            if (this._sfLocal() || !this.pubkey) return false;
            try { return localStorage.getItem(F().KEYS.pending + this.pubkey) === '1'; } catch (_) { return false; }
        },

        _sfSetPending(on) {
            if (this._sfLocal() || !this.pubkey) return;
            try {
                if (on) localStorage.setItem(F().KEYS.pending + this.pubkey, '1');
                else localStorage.removeItem(F().KEYS.pending + this.pubkey);
            } catch (_) { }
        },

        _sfCollapsed() {
            if (this._sfLocal()) return new Set(this._sfMemCollapsed || []);
            if (!this.pubkey) return new Set();
            try {
                const v = JSON.parse(localStorage.getItem(F().KEYS.collapsed + this.pubkey) || '[]');
                return new Set(Array.isArray(v) ? v.filter((id) => F().validFid(id)) : []);
            } catch (_) { return new Set(); }
        },

        _sfSetCollapsed(set) {
            const live = this._sfState().folders;
            const list = [...set].filter((id) => F().validFid(id) && live[id]).sort();
            if (this._sfLocal()) { this._sfMemCollapsed = list; return; }
            if (!this.pubkey) return;
            const key = F().KEYS.collapsed + this.pubkey;
            try {
                if (list.length) localStorage.setItem(key, JSON.stringify(list));
                else localStorage.removeItem(key);
            } catch (_) { }
        },

        toggleFolderCollapse(fid) {
            const set = this._sfCollapsed();
            if (set.has(fid)) set.delete(fid); else set.add(fid);
            this._sfSetCollapsed(set);
            this._sfApplyCollapse();
        },

        _sfCommit(state, opts) {
            if (!this._sfReady()) return false;
            this._sfPersist(state);
            this._sfRev = (this._sfRev || 0) + 1;
            if (!this._sfLocal()) this._sfSetPending(true);
            this._sfRenderSoon(true);
            if (opts && opts.joinSettings && !this._sfLocal()) {
                if (this._sfSyncTimer) { clearTimeout(this._sfSyncTimer); this._sfSyncTimer = null; }
                this._sfJoin = true;
                this._sfJoinAt = Date.now();
            } else {
                this._sfSyncSoon();
            }
            return true;
        },

        _sfSyncSoon(ms) {
            if (this._sfLocal()) return;
            if (this._sfSyncTimer) clearTimeout(this._sfSyncTimer);
            this._sfSyncTimer = setTimeout(() => { this._sfSyncTimer = null; this._sfSync(); }, ms === undefined ? SYNC_DEBOUNCE_MS : ms);
        },

        _sfCanPublish() {
            if (this._sfLocal() || !this._sfReady() || !this._sfPending()) return false;
            const online = typeof this._ctOnline === 'function' ? this._ctOnline() : !!this.connected;
            return !!(this.pubkey && online && this._settingsHydrated && !this._acctGoing);
        },

        async _sfPublishRow(now) {
            const payload = { [F().KEYS.payload]: JSON.parse(JSON.stringify(F().publishable(this._sfState()))) };
            const dTag = F().KEYS.dTag;
            if (!this._publishedSectionJson) this._publishedSectionJson = {};
            if (this._publishedSectionJson[dTag] === JSON.stringify(payload)) return { ok: true, changed: false };
            if (typeof this._publishCategoryWrap !== 'function') return { ok: false, changed: false };
            const changed = await this._publishCategoryWrap(payload, dTag, now, [F().trimFoldersPayload]);
            return { ok: !!changed || this._publishedSectionJson[dTag] === JSON.stringify(payload), changed: !!changed };
        },

        async _sfSync() {
            if (this._sfLocal()) return 'local';
            if (!this._sfPending()) return 'synced';
            if (!this._sfCanPublish()) return 'pending';
            if (this._sfSyncing) { this._sfResync = true; return 'pending'; }
            this._sfSyncing = true;
            this._sfResync = false;
            this._sfJoin = false;
            const rev = this._sfRev || 0;
            let ok = false;
            try {
                const now = nowSec();
                const r = await this._sfPublishRow(now);
                ok = r.ok;
                if (r.changed && typeof this._publishSettingsChangedPing === 'function') {
                    await this._publishSettingsChangedPing([F().KEYS.section], now);
                }
            } catch (_) {
                ok = false;
            } finally {
                this._sfSyncing = false;
            }
            if (ok && rev === (this._sfRev || 0)) this._sfSetPending(false);
            if (this._sfResync || (ok && rev !== (this._sfRev || 0))) {
                this._sfResync = false;
                return this._sfSync();
            }
            return this._sfPending() ? 'pending' : 'synced';
        },

        async _sfJoinSettingsPing(changed, now) {
            if (!this._sfJoin) return;
            this._sfJoin = false;
            if (!this._sfCanPublish() || this._sfSyncing) { this._sfSyncSoon(); return; }
            this._sfSyncing = true;
            const rev = this._sfRev || 0;
            let ok = false;
            try {
                const r = await this._sfPublishRow(now);
                ok = r.ok;
                if (r.changed && Array.isArray(changed) && changed.indexOf(F().KEYS.section) < 0) changed.push(F().KEYS.section);
            } catch (_) {
                ok = false;
            } finally {
                this._sfSyncing = false;
            }
            if (ok && rev === (this._sfRev || 0)) this._sfSetPending(false);
            else this._sfSyncSoon();
        },

        applySyncedFolders(remote) {
            if (!remote || typeof remote !== 'object' || this._sfLocal()) return;
            const now = Date.now();
            if (!this._sfReady()) {
                const pk = this.pubkey;
                const prev = this._sfQueued && this._sfQueued.pk === pk ? this._sfQueued.state : null;
                this._sfQueued = { pk, state: prev ? F().mergeFolders(prev, remote, now) : F().normalizeFolders(remote, now) };
                return;
            }
            const local = this._sfState();
            const rep = F().capRepair(F().mergeFolders(local, remote, now), now);
            const merged = rep.state;
            if (JSON.stringify(merged) !== JSON.stringify(local)) {
                this._sfPersist(merged);
                this._sfRev = (this._sfRev || 0) + 1;
                this._sfRenderSoon(true);
            }
            const mine = JSON.stringify(F().publishable(merged));
            const theirs = JSON.stringify(F().publishable(F().normalizeFolders(remote, now)));
            if (mine !== theirs) {
                this._sfSetPending(true);
                this._sfSyncSoon(0);
            }
        },

        _sfNewId() {
            const used = this._sfState();
            for (let i = 0; i < 20; i++) {
                const bytes = new Uint8Array(32);
                crypto.getRandomValues(bytes);
                const id = F().folderIdFrom(bytes);
                if (id && !used.folders[id] && used.deleted[id] === undefined) return id;
            }
            return '';
        },

        _sfToast(text) {
            if (typeof this.showToast === 'function') this.showToast(text, { kind: 'info' });
            else if (typeof this._cnNotice === 'function') this._cnNotice(text);
        },

        _sfError(code) {
            const S = F().STRINGS;
            const L = F().LIMITS;
            const msg = {
                folders: [S.capFolders, L.folders], cap: [S.capItems, L.perFolder], total: [S.capTotal, L.total],
                long: [S.nameLong, L.nameMax], name: [S.nameEmpty, 0], size: [S.capSize, 0],
            }[code];
            if (msg) this._sfToast(this._sf(msg[0], { n: msg[1] }));
            return false;
        },

        _sfHomeRows() {
            const map = new Map();
            const add = (list) => {
                if (!list) return;
                for (const row of list.querySelectorAll('.channel-item, .pm-item')) {
                    const ref = this._pinKeyForItem(row);
                    if (ref && F().validRef(ref) && !map.has(ref)) map.set(ref, row);
                }
            };
            add(document.getElementById('channelList'));
            add(document.getElementById('pmList'));
            return map;
        },

        _sfHomeRow(ref) {
            return this._sfHomeRows().get(ref) || null;
        },

        _sfVisCtx(refs, homes) {
            const ctx = { exists: [], hidden: [], blocked: [], locked: [], filtered: [], active: '', pmOnly: !!(this.settings && this.settings.groupChatPMOnlyMode) };
            for (const r of refs) {
                const row = homes.get(r);
                if (!row) continue;
                ctx.exists.push(r);
                if (row.classList.contains('cl-locked-row')) ctx.locked.push(r);
                if (row.classList.contains('cf-hidden-row')) ctx.filtered.push(r);
                if (row.classList.contains('active')) ctx.active = r;
                const id = r.slice(2);
                if (r[0] === 'c') {
                    if (this.hiddenChannels && this.hiddenChannels.has(id)) ctx.hidden.push(r);
                    if ((this.blockedChannels && this.blockedChannels.has(id)) || (typeof this._channelNameHidden === 'function' && this._channelNameHidden(id))) ctx.blocked.push(r);
                } else if (r[0] === 'd') {
                    if (this.blockedUsers && this.blockedUsers.has(id)) ctx.blocked.push(r);
                    if (typeof this._pmPeerHidden === 'function' && this._pmPeerHidden(id)) ctx.filtered.push(r);
                }
            }
            return ctx;
        },

        _sfActivity(ref, row) {
            let v = 0;
            if (ref[0] === 'c') {
                v = (this.channelLastActivity && (this.channelLastActivity.get(ref.slice(2)) || this.channelLastActivity.get('#' + ref.slice(2)))) || 0;
            } else if (row) {
                v = parseInt(row.dataset.lastMessageTime || '0', 10) || 0;
            }
            return v > 1e11 ? Math.floor(v / 1000) : Math.floor(v);
        },

        _sfRowCount(row) {
            if (!row || !row.classList.contains('has-unread')) return 0;
            const b = row.querySelector('.unread-badge');
            const t = b ? b.textContent.trim() : '';
            return t === '99+' ? 100 : (parseInt(t, 10) || 0);
        },

        _sfLabel(ref, row) {
            if (ref[0] === 'c') return '#' + ref.slice(2);
            const el = row && row.querySelector('.pm-name');
            if (!el) return ref.slice(2, 10);
            const c = el.cloneNode(true);
            c.querySelectorAll('.group-member-count').forEach((n) => n.remove());
            return (c.textContent || '').replace(/\s+/g, ' ').trim() || ref.slice(2, 10);
        },

        _sfCloneRow(ref, home) {
            const c = home.cloneNode(true);
            for (const n of [c, ...c.querySelectorAll('*')]) {
                n.removeAttribute('id');
                for (const a of [...n.attributes]) {
                    if (a.name === 'data-action' || a.name.indexOf('data-on-') === 0 || a.name === 'onclick') n.removeAttribute(a.name);
                }
            }
            for (const k of Object.keys(c.dataset)) delete c.dataset[k];
            c.removeAttribute('style');
            c.className = 'sb-frow ' + (ref[0] === 'c' ? 'sb-frow-c' : 'sb-frow-p') + KEEP_CLASSES.filter((k) => home.classList.contains(k)).map((k) => ' ' + k).join('');
            c.dataset.folderRef = ref;
            c.setAttribute('role', 'button');
            c.tabIndex = 0;
            const mb = c.querySelector('.row-menu-btn');
            if (mb) mb.dataset.sfRowmenu = '1';
            return c;
        },

        _sfBuildFolderEl(fid) {
            const S = F().STRINGS;
            const el = document.createElement('div');
            el.className = 'nav-section sb-folder';
            el.dataset.folder = fid;
            const listId = 'sbfl-' + fid;
            el.innerHTML =
                `<div class="nav-title sb-folder-head">` +
                `<span class="section-reorder-arrows">` +
                `<button type="button" class="section-reorder-btn" data-folder-move="up" aria-label="${esc(this._sf(S.moveUp))}">${ICONS.up}</button>` +
                `<button type="button" class="section-reorder-btn" data-folder-move="down" aria-label="${esc(this._sf(S.moveDown))}">${ICONS.down}</button>` +
                `</span>` +
                `<button type="button" class="sb-folder-toggle" aria-expanded="true" aria-controls="${listId}">${ICONS.folder}<span class="nav-title-text sb-folder-name"></span><span class="unread-badge sb-folder-badge" hidden></span></button>` +
                `<button type="button" class="section-icon-btn sb-folder-menu" aria-haspopup="menu" aria-label="${esc(this._sf(S.options))}">${dots()}</button>` +
                `<button type="button" class="collapse-icon section-icon-btn sb-folder-collapse" tabindex="-1" aria-hidden="true">${ICONS.chevron}</button>` +
                `</div>` +
                `<div class="sb-folder-list" id="${listId}"></div>`;
            const head = el.querySelector('.sb-folder-head');
            let timer = null, sx = 0, sy = 0, held = false;
            const cancel = () => { if (timer) { clearTimeout(timer); timer = null; } };
            const start = (x, y, target) => {
                if (target.closest('.section-reorder-arrows, .sb-folder-menu')) return;
                sx = x; sy = y; held = false;
                cancel();
                timer = setTimeout(() => {
                    timer = null;
                    held = true;
                    this._setSidebarReorderMode(!document.body.classList.contains('sidebar-reorder-mode'));
                }, HOLD_MS);
            };
            head.addEventListener('mousedown', (e) => { if (e.button === 0) start(e.clientX, e.clientY, e.target); });
            head.addEventListener('touchstart', (e) => { const t = e.touches && e.touches[0]; if (t) start(t.clientX, t.clientY, e.target); }, { passive: true });
            const moved = (x, y) => { if (timer && (Math.abs(x - sx) > MOVE_PX || Math.abs(y - sy) > MOVE_PX)) cancel(); };
            head.addEventListener('mousemove', (e) => moved(e.clientX, e.clientY));
            head.addEventListener('touchmove', (e) => { const t = e.touches && e.touches[0]; if (t) moved(t.clientX, t.clientY); }, { passive: true });
            for (const ev of ['mouseup', 'mouseleave', 'touchend', 'touchcancel']) head.addEventListener(ev, cancel);
            head.addEventListener('click', (e) => {
                if (held) { held = false; e.preventDefault(); e.stopPropagation(); return; }
                const mv = e.target.closest('.section-reorder-btn');
                if (mv) {
                    e.stopPropagation();
                    if (!mv.disabled) this._moveSidebarSection(el, mv.dataset.folderMove);
                    return;
                }
                if (e.target.closest('.sb-folder-menu')) {
                    e.stopPropagation();
                    const r = e.target.closest('.sb-folder-menu').getBoundingClientRect();
                    this._sfFolderMenu(fid, r.left + r.width / 2, r.bottom);
                    return;
                }
                if (e.target.closest('.sb-folder-toggle, .sb-folder-collapse')) {
                    e.stopPropagation();
                    this.toggleFolderCollapse(fid);
                }
            });
            const footer = document.getElementById('sidebarFooter');
            const sidebar = document.getElementById('sidebar');
            sidebar.insertBefore(el, footer && footer.parentNode === sidebar ? footer : null);
            return el;
        },

        _sfEmptyEl(fid) {
            const S = F().STRINGS;
            const d = document.createElement('div');
            d.className = 'sb-folder-empty';
            d.innerHTML = `<span>${esc(this._sf(S.empty))}</span><button type="button" class="sb-folder-add">${esc(this._sf(S.addChats))}</button>`;
            d.querySelector('.sb-folder-add').addEventListener('click', (e) => { e.stopPropagation(); this._sfOpenPicker(fid); });
            return d;
        },

        _sfHeadLabel(el, name, unread) {
            const S = F().STRINGS;
            const btn = el.querySelector('.sb-folder-toggle');
            if (!btn) return;
            const label = unread && unread.n > 0 ? this._sf(S.headLabelUnread, { name, n: unread.label }) : this._sf(S.headLabel, { name });
            if (btn.getAttribute('aria-label') !== label) btn.setAttribute('aria-label', label);
        },

        _sfFillFolder(el, f, homes, ctx, pins, dirty) {
            const nameEl = el.querySelector('.sb-folder-name');
            if (nameEl.textContent !== f.name) nameEl.textContent = f.name;
            el._sfName = f.name;
            const vis = F().visibleRefs(f.refs, ctx);
            const activity = {};
            for (const r of vis) activity[r] = this._sfActivity(r, homes.get(r));
            const order = F().folderSort(vis, { pins, activity });
            const list = el.querySelector('.sb-folder-list');
            const focused = document.activeElement && list.contains(document.activeElement) ? document.activeElement.closest('.sb-frow') : null;
            const focusRef = focused ? focused.dataset.folderRef : '';
            const old = new Map();
            if (dirty) for (const c of list.children) if (c.dataset && c.dataset.folderRef) old.set(c.dataset.folderRef, c);
            const rows = [];
            const counts = [];
            let refocus = null;
            for (const r of order) {
                const home = homes.get(r);
                let row = old.get(r);
                if (!row || dirty.has(r)) row = this._sfCloneRow(r, home);
                if (r === focusRef) refocus = row;
                rows.push(row);
                counts.push(this._sfRowCount(home));
            }
            const now = list.children;
            const same = rows.length > 0 && rows.length === now.length && rows.every((row, i) => row === now[i]);
            if (!same) {
                if (rows.length) list.replaceChildren(...rows);
                else if (!(now.length === 1 && now[0].classList.contains('sb-folder-empty'))) list.replaceChildren(this._sfEmptyEl(f.id));
                if (refocus && document.activeElement !== refocus) refocus.focus({ preventScroll: true });
            }
            el._sfUnread = F().folderUnread(counts);
            this._sfHeadLabel(el, f.name, el._sfUnread);
        },

        _sfRenderSoon(full) {
            if (full) this._sfFull = true;
            if (this._sfRaf) return;
            this._sfRaf = true;
            const run = () => {
                this._sfRaf = false;
                const all = this._sfFull;
                const dirty = this._sfDirty;
                this._sfFull = false;
                this._sfDirty = null;
                try { this._sfRender(all ? null : dirty); } catch (_) { }
            };
            if (typeof requestAnimationFrame === 'function' && !(typeof document !== 'undefined' && document.hidden)) requestAnimationFrame(run);
            else setTimeout(run, 16);
        },

        _sfRender(dirty) {
            const sidebar = document.getElementById('sidebar');
            if (!sidebar) return;
            const folders = this._sfReady() ? F().folderList(this._sfState()) : [];
            const ids = new Set(folders.map((f) => f.id));
            for (const el of sidebar.querySelectorAll(':scope > [data-folder]')) if (!ids.has(el.dataset.folder)) el.remove();
            const refFolder = new Map();
            for (const f of folders) for (const r of f.refs) refFolder.set(r, f.id);
            this._sfRefFolder = refFolder;
            if (folders.length) {
                const homes = refFolder.size ? this._sfHomeRows() : new Map();
                const ctx = this._sfVisCtx([...refFolder.keys()], homes);
                const pins = typeof this.pinnedChatKeys === 'function' ? this.pinnedChatKeys() : [];
                for (const f of folders) {
                    let el = sidebar.querySelector(`:scope > [data-folder="${f.id}"]`);
                    const fresh = !el;
                    if (!el) el = this._sfBuildFolderEl(f.id);
                    if (!fresh && dirty && el._sfName === f.name && !f.refs.some((r) => dirty.has(r))) continue;
                    this._sfFillFolder(el, f, homes, ctx, pins, fresh ? null : dirty);
                }
            }
            this._sfPlaceSlots();
            this._sfObserve(refFolder.size > 0);
            this._sfApplyCollapse();
            if (!dirty) this._refreshSidebarReorderButtons();
        },

        _sfSlotEls() {
            const sidebar = document.getElementById('sidebar');
            return sidebar ? Array.from(sidebar.querySelectorAll(':scope > [data-section], :scope > [data-folder]')) : [];
        },

        _sfPlaceSlots(layout) {
            const sidebar = document.getElementById('sidebar');
            if (!sidebar || !sidebar.querySelector(':scope > [data-folder]')) return;
            const want = layout || F().effectiveLayout(this._sfState(), this._getSidebarSectionOrder());
            const byToken = new Map(this._sfSlotEls().map((el) => [el.dataset.folder ? 'f:' + el.dataset.folder : el.dataset.section, el]));
            const order = want.filter((t) => byToken.has(t));
            for (const t of byToken.keys()) if (order.indexOf(t) < 0) order.push(t);
            const now = this._sfSlotEls().map((el) => (el.dataset.folder ? 'f:' + el.dataset.folder : el.dataset.section));
            if (now.join('\n') === order.join('\n')) return;
            const footer = sidebar.querySelector(':scope > .sidebar-footer');
            for (const t of order) sidebar.insertBefore(byToken.get(t), footer);
        },

        _sfApplyCollapse() {
            const S = F().STRINGS;
            const set = this._sfCollapsed();
            const sidebar = document.getElementById('sidebar');
            if (!sidebar) return;
            for (const el of sidebar.querySelectorAll(':scope > [data-folder]')) {
                const closed = set.has(el.dataset.folder);
                el.classList.toggle('section-collapsed', closed);
                const btn = el.querySelector('.sb-folder-toggle');
                if (btn) btn.setAttribute('aria-expanded', closed ? 'false' : 'true');
                const chev = el.querySelector('.sb-folder-collapse');
                if (chev) chev.title = this._sf(closed ? S.expand : S.collapse);
                const badge = el.querySelector('.sb-folder-badge');
                const u = el._sfUnread || { n: 0, label: '' };
                if (badge) {
                    const show = closed && u.n > 0;
                    if (badge.textContent !== u.label) badge.textContent = u.label;
                    badge.hidden = !show;
                    badge.style.display = show ? 'inline-block' : 'none';
                }
            }
        },

        _sfObserve(on) {
            if (!on) {
                if (this._sfMo) { this._sfMo.disconnect(); this._sfMo = null; }
                return;
            }
            if (this._sfMo || typeof MutationObserver === 'undefined') return;
            const lists = ['channelList', 'pmList'].map((id) => document.getElementById(id)).filter(Boolean);
            if (!lists.length) return;
            this._sfMo = new MutationObserver((recs) => this._sfOnMutations(recs));
            for (const l of lists) {
                this._sfMo.observe(l, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['class', 'style', 'src', 'title', 'aria-label', 'data-last-message-time'] });
            }
        },

        _sfOnMutations(recs) {
            const map = this._sfRefFolder;
            if (!map || !map.size) return;
            const dirty = this._sfDirty || new Set();
            let any = false;
            const note = (node) => {
                const el = node && (node.nodeType === 1 ? node : node.parentElement);
                const row = el && el.closest ? el.closest('.channel-item, .pm-item') : null;
                if (!row) return;
                const r = this._pinKeyForItem(row);
                if (r && map.has(r)) { dirty.add(r); any = true; }
            };
            for (const m of recs) {
                if (m.type === 'childList' && (m.target.id === 'channelList' || m.target.id === 'pmList')) {
                    m.addedNodes.forEach(note);
                    m.removedNodes.forEach(note);
                } else {
                    note(m.target);
                }
            }
            if (any) {
                this._sfDirty = dirty;
                this._sfRenderSoon(false);
            }
        },

        _sfMoveToken(token, delta) {
            const before = this._getSidebarSectionOrder();
            const r = F().layoutMove(this._sfState(), token, delta, Date.now(), before);
            if (r.error) return false;
            const builtins = r.layout.filter((t) => F().BUILTIN.indexOf(t) >= 0);
            const builtinMoved = builtins.join() !== F().builtinOrder(before).join();
            this._sfPlaceSlots(r.layout);
            this._sfCommit(r.state, { joinSettings: builtinMoved });
            this._refreshSidebarReorderButtons();
            if (builtinMoved) this._saveSidebarSectionOrder();
            return true;
        },

        _sfMenuItems(itemEl) {
            if (!this._sfReady() || !itemEl) return [];
            const S = F().STRINGS;
            const ref = this._pinKeyForItem(itemEl);
            if (!ref || !F().validRef(ref)) return [];
            const fid = F().folderOf(this._sfState(), ref);
            if (!fid) return [{ label: this._sf(S.addTo), svg: ICONS.folderItem, action: () => this._sfChooser(ref, '') }];
            return [
                { label: this._sf(S.moveTo), svg: ICONS.move, action: () => this._sfChooser(ref, fid) },
                { label: this._sf(S.removeFrom), svg: ICONS.remove, action: () => this._sfRemoveRef(ref, fid) },
            ];
        },

        _sfMenuAt() {
            const xy = this._sfMenuXY;
            return xy || [Math.round(window.innerWidth / 2), Math.round(window.innerHeight / 3)];
        },

        _sfChooser(ref, from) {
            const S = F().STRINGS;
            const items = F().folderList(this._sfState()).filter((f) => f.id !== from).map((f) => ({
                label: f.name, svg: ICONS.folderItem, cls: 'sb-folder-pick', action: () => this._sfMoveRef(ref, f.id, from),
            }));
            items.push({ label: this._sf(S.newFolder) + '…', svg: ICONS.plus, action: () => this.sfNewFolder([ref]) });
            const [x, y] = this._sfMenuAt();
            setTimeout(() => this._showSidebarActionMenu(items, x, y), 0);
        },

        _sfMoveRef(ref, to, from) {
            const S = F().STRINGS;
            const state = this._sfState();
            const r = F().folderAdd(state, to, [ref], Date.now());
            if (r.error) return this._sfError(r.error);
            this._sfCommit(r.state);
            const name = r.state.folders[to] ? r.state.folders[to].name : '';
            const undo = () => {
                const cur = this._sfState();
                if (from && cur.folders[from]) this._sfCommit(F().folderAdd(cur, from, [ref], Date.now()).state);
                else if (cur.folders[to]) this._sfCommit(F().folderRemove(cur, to, [ref], Date.now()).state);
            };
            if (typeof this.showUndoToast === 'function') this.showUndoToast(this._sf(from ? S.moved : S.added, { folder: name }), undo);
            return true;
        },

        _sfRemoveRef(ref, fid) {
            const S = F().STRINGS;
            const state = this._sfState();
            if (!state.folders[fid]) return false;
            const name = state.folders[fid].name;
            this._sfCommit(F().folderRemove(state, fid, [ref], Date.now()).state);
            const undo = () => {
                const cur = this._sfState();
                if (!cur.folders[fid]) return;
                const r = F().folderAdd(cur, fid, [ref], Date.now());
                if (r.error) return this._sfError(r.error);
                this._sfCommit(r.state);
            };
            if (typeof this.showUndoToast === 'function') this.showUndoToast(this._sf(S.removedFrom, { folder: name }), undo);
            return true;
        },

        _sfDropRef(ref) {
            if (!ref || !this._sfReady()) return;
            const state = this._sfState();
            const fid = F().folderOf(state, ref);
            if (fid) this._sfCommit(F().folderRemove(state, fid, [ref], Date.now()).state);
        },

        async _sfPromptName(title, okLabel, def) {
            const S = F().STRINGS;
            if (typeof window.showAppPrompt !== 'function') return null;
            const v = await window.showAppPrompt(this._sf(S.folderName), {
                title: this._sf(title), okLabel: this._sf(okLabel), cancelLabel: this._sf(S.cancel),
                defaultValue: def || '', placeholder: this._sf(S.folderName), maxLength: F().LIMITS.nameMax, countCodePoints: true,
            });
            if (v === null || v === undefined || v === false) return null;
            const c = F().cleanFolderName(String(v));
            if (c.error) { this._sfError(c.error); return null; }
            return c.name;
        },

        async sfNewFolder(refs, opts) {
            if (!this._sfReady()) return '';
            const S = F().STRINGS;
            const name = await this._sfPromptName(S.newFolder, S.create, '');
            if (name === null) return '';
            const id = this._sfNewId();
            const r = F().folderCreate(this._sfState(), id, name, Date.now(), refs || [], this._getSidebarSectionOrder());
            if (r.error) { this._sfError(r.error); return ''; }
            this._sfCommit(r.state);
            if (refs && refs.length) this._sfToast(this._sf(S.added, { folder: name }));
            if (opts && opts.picker) setTimeout(() => this._sfOpenPicker(id), 60);
            return id;
        },

        async _sfRename(fid) {
            const S = F().STRINGS;
            const f = this._sfState().folders[fid];
            if (!f) return;
            const name = await this._sfPromptName(S.renameFolder, S.rename, f.name);
            if (name === null) return;
            const r = F().folderRename(this._sfState(), fid, name, Date.now());
            if (r.error) return this._sfError(r.error);
            this._sfCommit(r.state);
        },

        async _sfDeleteFolder(fid) {
            const S = F().STRINGS;
            if (!this._sfState().folders[fid]) return;
            if (typeof window.showAppConfirm === 'function') {
                const ok = await window.showAppConfirm(this._sf(S.deleteConfirm), { danger: true, okLabel: this._sf(S.del), cancelLabel: this._sf(S.cancel) });
                if (!ok) return;
            }
            const cur = this._sfState();
            const f = cur.folders[fid];
            if (!f) return;
            const snap = { name: f.name, refs: Object.keys(f.items), index: F().effectiveLayout(cur, this._getSidebarSectionOrder()).indexOf('f:' + fid) };
            const wasClosed = this._sfCollapsed().has(fid);
            this._sfCommit(F().folderDelete(cur, fid, Date.now()).state);
            const undo = () => {
                const id = this._sfNewId();
                const r = F().folderRestore(this._sfState(), id, snap.name, snap.refs, snap.index, Date.now());
                if (r.error) return this._sfError(r.error);
                this._sfCommit(r.state);
                if (wasClosed) { const set = this._sfCollapsed(); set.add(id); this._sfSetCollapsed(set); }
            };
            if (typeof this.showUndoToast === 'function') this.showUndoToast(this._sf(S.deleted), undo);
        },

        _sfFolderMenu(fid, x, y) {
            const S = F().STRINGS;
            this._showSidebarActionMenu([
                { label: this._sf(S.addChats), svg: ICONS.plus, action: () => this._sfOpenPicker(fid) },
                { label: this._sf(S.renameFolder), svg: ICONS.rename, action: () => this._sfRename(fid) },
                { label: this._sf(S.deleteFolder), svg: ICONS.trash, cls: 'danger', action: () => this._sfDeleteFolder(fid) },
            ], x, y);
        },

        _sfOpenPicker(fid) {
            const S = F().STRINGS;
            const L = F().LIMITS;
            const state = this._sfState();
            const folder = state.folders[fid];
            if (!folder) return;
            document.querySelectorAll('.sb-picker-modal').forEach((m) => m.remove());
            const opener = document.activeElement;
            const homes = this._sfHomeRows();
            const ctx = this._sfVisCtx([...homes.keys()], homes);
            const rows = F().visibleRefs([...homes.keys()], ctx).map((ref) => {
                const other = F().folderOf(state, ref);
                return { ref, label: this._sfLabel(ref, homes.get(ref)), other: other && other !== fid ? state.folders[other].name : '', checked: folder.items[ref] !== undefined };
            });
            const sel = new Set(rows.filter((r) => r.checked).map((r) => r.ref));
            const modal = document.createElement('div');
            modal.className = 'modal active sb-picker-modal';
            modal.setAttribute('role', 'dialog');
            modal.setAttribute('aria-modal', 'true');
            modal.setAttribute('aria-labelledby', 'sbPickerTitle');
            modal.innerHTML =
                `<div class="modal-content">` +
                `<button type="button" class="modal-close sb-picker-x" aria-label="${esc(this._sf(S.cancel))}">&#x2715;</button>` +
                `<div class="modal-header" id="sbPickerTitle">${esc(this._sf(S.addChats))}</div>` +
                `<div class="modal-body">` +
                `<input type="search" class="form-input sb-picker-search" autocomplete="off" placeholder="${esc(this._sf(S.searchChats))}" aria-label="${esc(this._sf(S.searchChats))}">` +
                `<div class="sb-picker-cap" hidden>${esc(this._sf(S.capItems, { n: L.perFolder }))}</div>` +
                `<div class="sb-picker-list" role="group" aria-labelledby="sbPickerTitle"></div>` +
                `</div>` +
                `<div class="modal-actions"><button type="button" class="icon-btn sb-picker-cancel">${esc(this._sf(S.cancel))}</button>` +
                `<button type="button" class="send-btn sb-picker-done">${esc(this._sf(S.done))}</button></div>` +
                `</div>`;
            document.body.appendChild(modal);
            const listEl = modal.querySelector('.sb-picker-list');
            const input = modal.querySelector('.sb-picker-search');
            const capEl = modal.querySelector('.sb-picker-cap');
            const render = () => {
                const q = input.value.trim().toLowerCase();
                const full = sel.size >= L.perFolder;
                capEl.hidden = !full;
                listEl.replaceChildren();
                const shown = rows.filter((r) => !q || r.label.toLowerCase().indexOf(q) >= 0);
                if (!shown.length) {
                    const e = document.createElement('div');
                    e.className = 'sb-picker-empty';
                    e.textContent = this._sf(S.empty);
                    listEl.appendChild(e);
                    return;
                }
                for (const r of shown) {
                    const row = document.createElement('label');
                    const on = sel.has(r.ref);
                    const off = !on && full;
                    row.className = 'sb-picker-row' + (off ? ' is-disabled' : '');
                    row.dataset.ref = r.ref;
                    row.innerHTML = `<input type="checkbox"${on ? ' checked' : ''}${off ? ' disabled' : ''}><span class="sb-picker-name"></span>` +
                        (r.other ? `<span class="sb-picker-in"></span>` : '');
                    row.querySelector('.sb-picker-name').textContent = r.label;
                    if (r.other) row.querySelector('.sb-picker-in').textContent = this._sf(S.inFolder, { folder: r.other });
                    row.querySelector('input').addEventListener('change', (e) => {
                        if (e.target.checked) sel.add(r.ref); else sel.delete(r.ref);
                        const wasFull = full;
                        if ((sel.size >= L.perFolder) !== wasFull) {
                            render();
                            const again = listEl.querySelector(`.sb-picker-row[data-ref="${r.ref.replace(/["\\]/g, '\\$&')}"] input`);
                            if (again) again.focus();
                        }
                    });
                    listEl.appendChild(row);
                }
            };
            const close = () => {
                modal.remove();
                document.removeEventListener('keydown', onKey, true);
                if (opener && typeof opener.focus === 'function' && document.contains(opener)) opener.focus();
            };
            const done = () => {
                const cur = this._sfState();
                if (!cur.folders[fid]) { close(); return; }
                const now = Date.now();
                const toRemove = rows.filter((r) => r.checked && !sel.has(r.ref)).map((r) => r.ref);
                const toAdd = rows.filter((r) => !r.checked && sel.has(r.ref)).map((r) => r.ref);
                let next = cur;
                if (toRemove.length) next = F().folderRemove(next, fid, toRemove, now).state;
                if (toAdd.length) {
                    const r = F().folderAdd(next, fid, toAdd, now);
                    if (r.error) { this._sfError(r.error); return; }
                    next = r.state;
                }
                if (next !== cur) this._sfCommit(next);
                close();
            };
            const onKey = (e) => {
                if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
            };
            document.addEventListener('keydown', onKey, true);
            modal.addEventListener('click', (e) => {
                if (e.target === modal || e.target.closest('.sb-picker-x, .sb-picker-cancel')) { e.preventDefault(); close(); return; }
                if (e.target.closest('.sb-picker-done')) { e.preventDefault(); done(); }
            });
            input.addEventListener('input', render);
            render();
            setTimeout(() => input.focus(), 30);
        },

        _sfRowMenu(row, x, y) {
            const home = this._sfHomeRow(row.dataset.folderRef);
            if (!home) return;
            const items = this._buildSidebarMenuItems(home);
            if (items && items.length) this._showSidebarActionMenu(items, x, y);
        },

        _sfBindRows() {
            const sidebar = document.getElementById('sidebar');
            if (!sidebar || this._sfRowsBound) return;
            this._sfRowsBound = true;
            let timer = null, sx = 0, sy = 0, fired = false;
            const cancel = () => { if (timer) { clearTimeout(timer); timer = null; } };
            const rowOf = (t) => (t && t.closest ? t.closest('[data-folder] .sb-frow') : null);
            const start = (row, x, y, target) => {
                if (target.closest('.row-menu-btn')) return;
                sx = x; sy = y; fired = false;
                cancel();
                timer = setTimeout(() => {
                    timer = null;
                    fired = true;
                    if (window.nymHaptic) window.nymHaptic('selection');
                    this._sfRowMenu(row, x, y);
                }, HOLD_MS);
            };
            sidebar.addEventListener('mousedown', (e) => { const row = rowOf(e.target); if (row && e.button === 0) start(row, e.clientX, e.clientY, e.target); });
            sidebar.addEventListener('touchstart', (e) => { const row = rowOf(e.target); const t = e.touches && e.touches[0]; if (row && t) start(row, t.clientX, t.clientY, e.target); }, { passive: true });
            const moved = (x, y) => { if (timer && (Math.abs(x - sx) > MOVE_PX || Math.abs(y - sy) > MOVE_PX)) cancel(); };
            sidebar.addEventListener('mousemove', (e) => moved(e.clientX, e.clientY));
            sidebar.addEventListener('touchmove', (e) => { const t = e.touches && e.touches[0]; if (t) moved(t.clientX, t.clientY); }, { passive: true });
            sidebar.addEventListener('mouseup', cancel);
            sidebar.addEventListener('touchcancel', cancel);
            sidebar.addEventListener('touchend', (e) => { cancel(); if (fired && rowOf(e.target)) { e.preventDefault(); fired = false; } });
            sidebar.addEventListener('contextmenu', (e) => {
                const row = rowOf(e.target);
                if (!row) return;
                e.preventDefault();
                e.stopPropagation();
                this._sfRowMenu(row, e.clientX, e.clientY);
            });
            sidebar.addEventListener('click', (e) => {
                const row = rowOf(e.target);
                if (!row) return;
                e.preventDefault();
                e.stopPropagation();
                if (fired) { fired = false; return; }
                const btn = e.target.closest('.row-menu-btn');
                if (btn) {
                    const r = btn.getBoundingClientRect();
                    this._sfRowMenu(row, r.left + r.width / 2, r.bottom);
                    return;
                }
                const home = this._sfHomeRow(row.dataset.folderRef);
                if (home) home.click();
            }, true);
            sidebar.addEventListener('keydown', (e) => {
                const row = rowOf(e.target);
                if (!row || e.target !== row) return;
                if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    const home = this._sfHomeRow(row.dataset.folderRef);
                    if (home) home.click();
                } else if (e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey)) {
                    e.preventDefault();
                    const r = row.getBoundingClientRect();
                    this._sfRowMenu(row, r.left + 24, r.bottom);
                }
            });
        },

        _sfStart() {
            if (this._sfStarted || typeof document === 'undefined') return;
            const sidebar = document.getElementById('sidebar');
            if (!sidebar) return;
            this._sfStarted = true;
            this._sfBindRows();
            const btn = document.getElementById('sidebarNewFolderBtn');
            if (btn) btn.addEventListener('click', (e) => { e.preventDefault(); this.sfNewFolder([], { picker: true }); });
            setInterval(() => {
                try {
                    if (!this._sfReady()) { this._sfLoad(); return; }
                    if (this._sfJoin && Date.now() - (this._sfJoinAt || 0) < JOIN_WAIT_MS) return;
                    if (this._sfPending()) this._sfSync();
                } catch (_) { }
            }, 10000);
            if (typeof window !== 'undefined' && window.addEventListener) {
                window.addEventListener('online', () => setTimeout(() => { this._sfSync(); }, 1500));
            }
        },
    });

    const wrap = (name, fn) => {
        const orig = NYM.prototype[name];
        if (typeof orig !== 'function') return;
        NYM.prototype[name] = function (...args) { return fn.call(this, orig, ...args); };
    };
    const after = (name, fn) => wrap(name, function (orig, ...args) {
        const out = orig.apply(this, args);
        Promise.resolve(out).then(() => { try { fn.apply(this, args); } catch (_) { } }, () => { });
        return out;
    });

    wrap('_buildSidebarMenuItems', function (orig, itemEl) {
        const items = orig.call(this, itemEl) || [];
        if (!items.length) return items;
        try {
            const extra = this._sfMenuItems(itemEl);
            if (extra.length) {
                const at = items.findIndex((i) => i && i.cls === 'danger');
                items.splice(at < 0 ? items.length : at, 0, ...extra);
            }
        } catch (_) { }
        return items;
    });

    wrap('_showSidebarActionMenu', function (orig, items, x, y) {
        this._sfMenuXY = [x, y];
        return orig.call(this, items, x, y);
    });

    wrap('_moveSidebarSection', function (orig, sectionEl, direction) {
        if (!this._sfHasFolders() || !sectionEl) return orig.call(this, sectionEl, direction);
        const token = sectionEl.dataset.folder ? 'f:' + sectionEl.dataset.folder : sectionEl.dataset.section;
        return this._sfMoveToken(token, direction === 'up' ? -1 : 1);
    });

    wrap('_applySidebarSectionOrder', function (orig, order) {
        const out = orig.call(this, order);
        if (this._sfHasFolders()) {
            this._sfPlaceSlots(F().effectiveLayout(this._sfState(), this._getSidebarSectionOrder()));
            this._refreshSidebarReorderButtons();
        }
        return out;
    });

    wrap('_refreshSidebarReorderButtons', function (orig) {
        const sidebar = typeof document !== 'undefined' && document.getElementById('sidebar');
        if (!sidebar || !sidebar.querySelector(':scope > [data-folder]')) return orig.call(this);
        const els = this._sfSlotEls();
        els.forEach((el, idx) => {
            const up = el.querySelector('.section-reorder-btn[data-section-move="up"], .section-reorder-btn[data-folder-move="up"]');
            const down = el.querySelector('.section-reorder-btn[data-section-move="down"], .section-reorder-btn[data-folder-move="down"]');
            if (up) up.disabled = idx === 0;
            if (down) down.disabled = idx === els.length - 1;
        });
    });

    function dropWhenGone(nym, ref) {
        let tries = 0;
        const check = () => {
            if (!ref) return;
            if (!nym._sfHomeRow(ref)) { nym._sfDropRef(ref); return; }
            if (++tries < 40) setTimeout(check, 250);
        };
        setTimeout(check, 0);
    }

    after('deletePM', function (pubkey) {
        dropWhenGone(this, N().pinKey('dm', pubkey));
    });

    after('deleteGroup', function (groupId) {
        dropWhenGone(this, N().pinKey('group', groupId));
    });

    after('blockChannel', function (channel, geohash) {
        this._sfDropRef(N().pinKey('channel', geohash || channel));
    });

    for (const name of ['applyGroupChatPMOnlyMode', 'toggleBlockUserByPubkey', '_contentFiltersChanged']) {
        after(name, function () { if (this._sfRefFolder && this._sfRefFolder.size) this._sfRenderSoon(true); });
    }
})();
