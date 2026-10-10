(function () {
    if (typeof NYM === 'undefined') return;

    const C = () => window.NymComposer;
    const MENUS = { attach: { menu: 'attachMenu', trigger: 'attachBtn' }, send: { menu: 'sendMenu', trigger: 'sendMenuBtn' } };
    const PICKER_TABS = [['emoji', 'Emoji'], ['gif', 'GIF']];

    Object.assign(NYM.prototype, {

        _cx(text) {
            return typeof this.uiText === 'function' ? this.uiText(text) : text;
        },

        _composerSurface() {
            if (!this.inPMMode) return 'channel';
            return this.currentGroup ? 'group' : 'dm';
        },

        _composerRoute() {
            if (typeof this._mediaRoute === 'function') return this._mediaRoute();
            return this.connected ? 'online' : 'offline';
        },

        _composerAttachModel() {
            const round = typeof this.mediaFeatureState === 'function' ? this.mediaFeatureState('round') : { state: 'ok', reason: '' };
            const surface = this._composerSurface();
            const bot = surface === 'dm' && !!this.currentPM && typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(this.currentPM);
            return C().attachItems({ surface, route: this._composerRoute(), round, bot });
        },

        _composerCanSendAnon() {
            const surface = this._composerSurface();
            const mesh = surface === 'channel' && typeof this.meshShouldCarry === 'function'
                && !!this.meshShouldCarry(this.currentGeohash || this.currentChannel);
            return C().canSendAnon({
                loggedIn: !!this.nostrLoginMethod && typeof this.sendMessagePseudonymous === 'function',
                surface,
                editing: !!this.pendingEdit,
                mesh,
            });
        },

        _composerSendModel() {
            return C().sendMenuItems({ canAnon: this._composerCanSendAnon() });
        },

        _composerText() {
            const input = document.getElementById('messageInput');
            if (!input) return '';
            return typeof input.value === 'string' ? input.value : (input.textContent || '');
        },

        refreshComposerPrimary() {
            const send = document.getElementById('sendBtn');
            const more = document.getElementById('sendMenuBtn');
            const mic = document.getElementById('voiceRecordBtn');
            if (!send || !mic) return;
            const action = C().primaryAction({
                text: this._composerText(),
                attachments: (this._composerAttachments || []).length,
                editing: !!this.pendingEdit,
                quoting: !!this.pendingQuote,
                busy: !!this._composerSendQueued,
                recording: !!this._voiceRec,
            });
            const showSend = action === 'send';
            const active = document.activeElement;
            const lostFocus = !!active && ((!showSend && (active === send || active === more)) || (showSend && active === mic));
            const appearing = showSend && send.hidden;
            if (send.hidden === showSend) send.hidden = !showSend;
            if (more && more.hidden === showSend) more.hidden = !showSend;
            if (mic.hidden !== showSend) mic.hidden = showSend;
            if (!showSend && this._composerMenuOpen === 'send') this.closeComposerMenu();
            if (appearing && typeof this._sendAsProbe === 'function') Promise.resolve(this._sendAsProbe()).catch(() => { });
            if (lostFocus) {
                const input = document.getElementById('messageInput');
                if (input) input.focus();
            }
            this._syncComposerPill(showSend);
        },

        _syncComposerPill(on) {
            const input = document.getElementById('messageInput');
            const box = input && input.closest('.input-container');
            const wrap = input && input.closest('.input-wrapper');
            if (!box || !wrap) return;
            if (typeof on === 'boolean' && box.classList.contains('composer-pill') !== on) {
                box.classList.toggle('composer-pill', on);
                if (typeof this._applyFormatToolbarState === 'function') this._applyFormatToolbarState();
                else if (typeof this._refreshComposerOffsets === 'function') this._refreshComposerOffsets();
            }
            const w = wrap.getBoundingClientRect();
            if (!w.width) return;
            const edges = [box.querySelector(':scope > .attach-btn'), box.querySelector(':scope > .input-buttons')]
                .filter((el) => el && el.offsetWidth > 0)
                .map((el) => el.getBoundingClientRect());
            const l = Math.round(Math.max(0, w.left - Math.min(w.left, ...edges.map((r) => r.left)))) + 'px';
            const r = Math.round(Math.max(0, Math.max(w.right, ...edges.map((e) => e.right)) - w.right)) + 'px';
            if (wrap.style.getPropertyValue('--pill-l') !== l) wrap.style.setProperty('--pill-l', l);
            if (wrap.style.getPropertyValue('--pill-r') !== r) wrap.style.setProperty('--pill-r', r);
            this._syncComposerTextStart(box, input);
        },

        _syncComposerTextStart(box, input) {
            const btn = box.classList.contains('composer-pill') ? document.getElementById('translateInputBtn') : null;
            const glyph = btn && btn.offsetWidth > 0 ? (btn.querySelector('svg') || btn) : null;
            if (!glyph) {
                if (input.style.paddingLeft) input.style.paddingLeft = '';
                if (input.style.marginLeft) input.style.marginLeft = '';
                return;
            }
            const bar = btn.closest('.format-toolbar');
            const g = glyph.getBoundingClientRect();
            const i = input.getBoundingClientRect();
            const cs = getComputedStyle(input);
            const border = parseFloat(cs.borderLeftWidth) || 0;
            const base = i.left - (parseFloat(cs.marginLeft) || 0);
            const need = Math.round(g.left + (bar ? bar.scrollLeft : 0) - base - border);
            const pad = Math.max(4, need) + 'px';
            const shift = Math.min(0, need - 4) + 'px';
            if (input.style.paddingLeft !== pad) input.style.paddingLeft = pad;
            if (input.style.marginLeft !== shift) input.style.marginLeft = shift === '0px' ? '' : shift;
        },

        _composerScheduleRefresh() {
            if (this._composerRefreshQueued) return;
            this._composerRefreshQueued = true;
            const run = () => { this._composerRefreshQueued = false; this.refreshComposerPrimary(); };
            if (typeof requestAnimationFrame === 'function') requestAnimationFrame(run);
            else setTimeout(run, 0);
        },

        _composerRenderAttach() {
            const menu = document.getElementById('attachMenu');
            if (!menu) return;
            const model = this._composerAttachModel();
            menu.querySelectorAll('[data-attach-item]').forEach((el) => {
                const it = model.find((m) => m.id === el.dataset.attachItem);
                el.hidden = !it;
                if (!it) return;
                el.setAttribute('aria-disabled', it.enabled ? 'false' : 'true');
                el.classList.toggle('is-disabled', !it.enabled);
                el.classList.toggle('is-warn', it.enabled && !!it.warn);
                el.dataset.detail = it.detail || '';
                const note = el.querySelector('.composer-menu-reason');
                if (note) note.textContent = this._cx(it.enabled ? it.warn : it.reason);
            });
        },

        _composerRenderSend() {
            const menu = document.getElementById('sendMenu');
            if (!menu) return;
            const model = this._composerSendModel();
            menu.querySelectorAll('[data-send-item]').forEach((el) => {
                if (el.dataset.sendItem === 'as') return;
                el.hidden = !model.some((m) => m.id === el.dataset.sendItem);
            });
            this._composerRenderSendAs();
        },

        _composerRenderSendAs() {
            const sep = document.getElementById('sendAsSep');
            const head = document.getElementById('sendAsHeading');
            const group = document.getElementById('sendAsGroup');
            if (!sep || !head || !group) return;
            const sec = typeof this.sendAsSection === 'function' ? this.sendAsSection() : { show: false, rows: [] };
            const active = document.activeElement;
            const focused = active && group.contains(active) && active.dataset ? active.dataset.acctId : null;
            sep.hidden = !sec.show;
            head.hidden = !sec.show;
            group.hidden = !sec.show;
            group.innerHTML = sec.show ? sec.rows.map((r) => this._composerSendAsRow(r)).join('') : '';
            if (focused) {
                const again = [...group.querySelectorAll('[data-acct-id]')].find((el) => el.dataset.acctId === focused);
                if (again) again.focus();
                else {
                    const menu = document.getElementById('sendMenu');
                    const items = menu ? this._composerMenuItems(menu) : [];
                    const first = items.find((el) => el.getAttribute('aria-disabled') !== 'true') || items[0];
                    if (first) first.focus();
                }
            }
        },

        _composerSendAsRow(r) {
            const S = window.NymSendAs;
            const e = (v) => String(v == null ? '' : v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
            const name = r.nym + '#' + r.suffix;
            const label = S ? S.text(this._cx(S.STRINGS.rowLabel), name) : name;
            const reason = r.reason ? this._cx(r.reason) : '';
            const rid = 'sendAsReason-' + r.account;
            const avatar = typeof this._sendAsAvatar === 'function' ? this._sendAsAvatar(r.account) : '';
            const img = avatar
                ? `<img class="send-as-avatar" src="${e(avatar)}" alt="" width="24" height="24" decoding="async">`
                : `<span class="send-as-avatar send-as-avatar-blank" aria-hidden="true">${e(r.nym.slice(0, 1).toUpperCase())}</span>`;
            return `<button type="button" class="composer-menu-item send-as-item${r.enabled ? '' : ' is-disabled'}" role="menuitem" data-send-item="as" data-acct-id="${e(r.account)}" data-state="${e(r.state)}" aria-label="${e(label)}" aria-disabled="${r.enabled ? 'false' : 'true'}"${reason ? ` aria-describedby="${e(rid)}" data-detail="${e(reason)}"` : ''}>`
                + img
                + `<span class="composer-menu-text"><span class="composer-menu-label"><bdi class="send-as-name"><span class="send-as-nym">${e(r.nym)}</span><span class="nym-suffix">#${e(r.suffix)}</span></bdi></span>`
                + `<span class="composer-menu-reason" id="${e(rid)}">${e(reason)}</span></span></button>`;
        },

        _composerMenuItems(menu) {
            return Array.from(menu.querySelectorAll('[role="menuitem"]'))
                .filter((el) => !el.hidden && !el.classList.contains('nm-hidden'));
        },

        _composerBackdrop() {
            let el = document.getElementById('composerMenuBackdrop');
            if (el) return el;
            el = document.createElement('div');
            el.id = 'composerMenuBackdrop';
            el.className = 'composer-menu-backdrop';
            el.hidden = true;
            el.addEventListener('pointerdown', (e) => { e.preventDefault(); this.closeComposerMenu({ restoreFocus: true }); });
            document.body.appendChild(el);
            return el;
        },

        _composerPlaceMenu(kind, menu) {
            const mode = C().presentation(window.innerWidth || 0);
            menu.classList.toggle('is-sheet', mode === 'sheet');
            menu.classList.toggle('is-popover', mode === 'popover');
            const backdrop = this._composerBackdrop();
            backdrop.hidden = mode !== 'sheet';
            menu.style.left = '';
            menu.style.right = '';
            menu.style.bottom = '';
            if (mode === 'sheet') return;
            const anchor = document.getElementById(kind === 'send' ? 'sendSplit' : MENUS[kind].trigger);
            if (!anchor) return;
            const r = anchor.getBoundingClientRect();
            menu.style.bottom = Math.max(8, window.innerHeight - r.top + 8) + 'px';
            if (kind === 'send') menu.style.right = Math.max(8, window.innerWidth - r.right) + 'px';
            else menu.style.left = Math.max(8, r.left) + 'px';
        },

        openComposerMenu(kind) {
            const ids = MENUS[kind];
            const menu = ids && document.getElementById(ids.menu);
            if (!menu) return;
            if (this._composerMenuOpen && this._composerMenuOpen !== kind) this.closeComposerMenu();
            if (kind === 'attach') this._composerRenderAttach();
            else {
                this._composerRenderSend();
                if (typeof this._sendAsProbe === 'function') {
                    Promise.resolve(this._sendAsProbe()).then(() => {
                        if (this._composerMenuOpen === 'send') {
                            this._composerRenderSendAs();
                            this._composerPlaceMenu('send', menu);
                        }
                    }).catch(() => { });
                }
            }
            if (typeof this.closeEnhancedEmojiModal === 'function' && this.enhancedEmojiModal && this._activePickerMode === 'input') this.closeEnhancedEmojiModal({ keepFocus: true });
            const gif = document.getElementById('gifPicker');
            if (gif && gif.classList.contains('active') && typeof this.closeGifPicker === 'function') this.closeGifPicker({ keepFocus: true });
            menu.hidden = false;
            this._composerPlaceMenu(kind, menu);
            this._composerMenuOpen = kind;
            const trigger = document.getElementById(ids.trigger);
            if (trigger) trigger.setAttribute('aria-expanded', 'true');
            const items = this._composerMenuItems(menu);
            const first = items.find((el) => el.getAttribute('aria-disabled') !== 'true') || items[0];
            if (first) first.focus();
        },

        openComposerSendMenu() {
            this.openComposerMenu('send');
        },

        closeComposerMenu(opts) {
            const kind = this._composerMenuOpen;
            if (!kind) return;
            this._composerMenuOpen = null;
            const ids = MENUS[kind];
            const menu = document.getElementById(ids.menu);
            this._composerGrab = null;
            if (menu) {
                menu.hidden = true;
                menu.classList.remove('sheet-dragging');
                if (menu.style.transform) menu.style.transform = '';
            }
            const backdrop = document.getElementById('composerMenuBackdrop');
            if (backdrop) backdrop.hidden = true;
            let trigger = document.getElementById(ids.trigger);
            if (trigger) trigger.setAttribute('aria-expanded', 'false');
            if (opts && opts.restoreFocus) {
                if (trigger && trigger.hidden) trigger = document.getElementById('messageInput');
                if (trigger) trigger.focus();
            }
        },

        _composerMenuKeydown(e, menu) {
            if (e.key === 'Escape' || e.key === 'Tab') {
                e.preventDefault();
                e.stopPropagation();
                this.closeComposerMenu({ restoreFocus: true });
                return;
            }
            const items = this._composerMenuItems(menu);
            const next = C().menuStep(items.length, items.indexOf(document.activeElement), e.key);
            if (next < 0) return;
            e.preventDefault();
            items[next].focus();
        },

        _composerBindMenu(kind) {
            const menu = document.getElementById(MENUS[kind].menu);
            if (!menu || menu._nymBound) return;
            menu._nymBound = true;
            if (menu.parentNode !== document.body) document.body.appendChild(menu);
            this._composerGrabber(menu);
            menu.addEventListener('keydown', (e) => this._composerMenuKeydown(e, menu));
            menu.addEventListener('click', (e) => {
                const item = e.target.closest('[role="menuitem"]');
                if (!item) return;
                if (kind === 'attach') this._composerRenderAttach();
                if (item.getAttribute('aria-disabled') === 'true') {
                    e.preventDefault();
                    e.stopPropagation();
                    this.closeComposerMenu({ restoreFocus: true });
                    if (item.dataset.detail && typeof this.displaySystemMessage === 'function') this.displaySystemMessage(this._cx(item.dataset.detail));
                    return;
                }
                this.closeComposerMenu({ restoreFocus: true });
                if (kind === 'send') this._composerRunSend(item.dataset.sendItem, item.dataset.acctId);
            }, true);
        },

        _composerGrabber(menu) {
            if (menu.querySelector(':scope > .sheet-grabber')) return;
            const g = document.createElement('div');
            g.className = 'sheet-grabber';
            g.setAttribute('role', 'button');
            g.setAttribute('aria-label', this._cx('Close sheet'));
            g.tabIndex = -1;
            g.innerHTML = '<span class="sheet-grabber-bar"></span>';
            menu.insertBefore(g, menu.firstChild);
            g.addEventListener('pointerdown', (e) => this._composerGrabDown(e, menu, g));
            g.addEventListener('pointermove', (e) => this._composerGrabMove(e));
            g.addEventListener('pointerup', (e) => this._composerGrabUp(e));
            g.addEventListener('pointercancel', (e) => this._composerGrabUp(e));
            g.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                if (Date.now() < (this._composerGrabQuiet || 0) || !menu.classList.contains('is-sheet')) return;
                this.closeComposerMenu({ restoreFocus: true });
            });
        },

        _composerGrabDown(e, menu, g) {
            if ((e.button !== undefined && e.button !== 0) || !menu.classList.contains('is-sheet') || menu.hidden) return;
            e.preventDefault();
            const now = performance.now();
            this._composerGrab = { id: e.pointerId, menu, y0: e.clientY, y: e.clientY, t: now, v: 0, moved: false, h: menu.getBoundingClientRect().height || 1 };
            try { g.setPointerCapture(e.pointerId); } catch (_) { }
        },

        _composerGrabMove(e) {
            const d = this._composerGrab;
            if (!d || e.pointerId !== d.id) return;
            const now = performance.now();
            d.v = (e.clientY - d.y) / Math.max(1, now - d.t);
            d.y = e.clientY;
            d.t = now;
            const dy = Math.max(0, e.clientY - d.y0);
            if (!d.moved && dy < 4) return;
            d.moved = true;
            d.menu.classList.add('sheet-dragging');
            d.menu.style.transform = 'translateY(' + dy + 'px)';
            if (e.cancelable) e.preventDefault();
        },

        _composerGrabUp(e) {
            const d = this._composerGrab;
            if (!d || e.pointerId !== d.id) return;
            this._composerGrab = null;
            if (!d.moved) return;
            this._composerGrabQuiet = Date.now() + 350;
            const S = window.nymSheets || {};
            const dy = Math.max(0, e.clientY - d.y0);
            const close = e.type !== 'pointercancel' && (dy > d.h * (S.closeFraction || 0.3) || d.v > (S.closeVelocity || 0.7));
            d.menu.classList.remove('sheet-dragging');
            if (close) this._composerSheetOut(d.menu);
            else d.menu.style.transform = '';
        },

        _composerSheetOut(menu) {
            const kind = this._composerMenuOpen;
            const reduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
            if (reduce) { this.closeComposerMenu({ restoreFocus: true }); return; }
            const out = 'translateY(100%)';
            menu.style.transform = out;
            let done = false;
            const end = () => {
                if (done) return;
                done = true;
                if (this._composerMenuOpen === kind && menu.style.transform === out) this.closeComposerMenu({ restoreFocus: true });
            };
            menu.addEventListener('transitionend', end, { once: true });
            setTimeout(end, 320);
        },

        _composerRunSend(id, acctId) {
            if (id === 'later' && typeof this.openSendLater === 'function') this.openSendLater();
            else if (id === 'anon' && typeof this.sendMessagePseudonymous === 'function') this.sendMessagePseudonymous();
            else if (id === 'as' && acctId && typeof this.sendAs === 'function') this.sendAs(acctId);
        },

        _composerPickerTabs(container, active) {
            if (!container) return;
            container.querySelectorAll('.picker-tabs').forEach((el) => el.remove());
            const bar = document.createElement('div');
            bar.className = 'picker-tabs';
            bar.setAttribute('role', 'tablist');
            bar.setAttribute('aria-label', this._cx('Emoji and GIFs'));
            for (const [id, label] of PICKER_TABS) {
                const tab = document.createElement('button');
                tab.type = 'button';
                tab.className = 'picker-tab' + (id === active ? ' active' : '');
                tab.dataset.pickerTab = id;
                tab.setAttribute('role', 'tab');
                tab.setAttribute('aria-selected', id === active ? 'true' : 'false');
                tab.tabIndex = id === active ? 0 : -1;
                tab.textContent = this._cx(label);
                tab.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this._composerSwitchPicker(id);
                });
                bar.appendChild(tab);
            }
            bar.addEventListener('keydown', (e) => {
                const keys = { ArrowLeft: -1, ArrowRight: 1, Home: 'first', End: 'last' };
                if (!(e.key in keys)) return;
                e.preventDefault();
                e.stopPropagation();
                const i = PICKER_TABS.findIndex(([id]) => id === active);
                const step = keys[e.key];
                const j = step === 'first' ? 0 : step === 'last' ? PICKER_TABS.length - 1 : (i + step + PICKER_TABS.length) % PICKER_TABS.length;
                this._composerSwitchPicker(PICKER_TABS[j][0]);
            });
            container.insertBefore(bar, container.firstChild);
        },

        _composerEmojiButton() {
            const bar = document.getElementById('formatToolbar');
            const inBar = document.getElementById('formatEmojiBtn');
            if (bar && inBar && !bar.classList.contains('nm-hidden') && inBar.offsetWidth > 0) return inBar;
            return document.getElementById('emojiInputBtn');
        },

        _composerSwitchPicker(to) {
            const gif = document.getElementById('gifPicker');
            const gifOpen = !!(gif && gif.classList.contains('active'));
            this._pickerFocusTab = true;
            if (to === 'gif') {
                if (gifOpen) { this._composerFocusTab(gif, 'gif'); return; }
                this.closeEnhancedEmojiModal({ keepFocus: true });
                this.showGifPicker();
                return;
            }
            if (!gifOpen && this.enhancedEmojiModal) { this._composerFocusTab(this.enhancedEmojiModal, 'emoji'); return; }
            this.closeGifPicker({ keepFocus: true });
            const btn = this._composerEmojiButton();
            if (btn) this.showEnhancedEmojiPickerForInput(btn);
        },

        _composerFocusTab(container, id) {
            const tab = container && container.querySelector(`.picker-tab[data-picker-tab="${id}"]`);
            if (tab) tab.focus();
        },

        _composerPickerOpened(container, kind) {
            if (this._composerMenuOpen) this.closeComposerMenu();
            const btn = this._composerEmojiButton();
            if (btn) btn.setAttribute('aria-expanded', 'true');
            if (this._pickerFocusTab) this._composerFocusTab(container, kind);
            this._pickerFocusTab = false;
        },

        _composerPickerClosed() {
            const gif = document.getElementById('gifPicker');
            if (this.enhancedEmojiModal || (gif && gif.classList.contains('active'))) return;
            ['emojiInputBtn', 'formatEmojiBtn'].forEach((id) => {
                const btn = document.getElementById(id);
                if (btn) btn.setAttribute('aria-expanded', 'false');
            });
        },

        _composerInputPickerOpen() {
            const gif = document.getElementById('gifPicker');
            if (gif && gif.classList.contains('active')) return 'gif';
            if (this.enhancedEmojiModal && this._activePickerMode === 'input') return 'emoji';
            return null;
        },

        setupComposerControls() {
            if (this._composerReady || typeof document === 'undefined') return;
            this._composerReady = true;
            this._composerBindMenu('attach');
            this._composerBindMenu('send');

            const attach = document.getElementById('attachBtn');
            if (attach) {
                attach.addEventListener('click', (e) => {
                    e.preventDefault();
                    if (this._composerMenuOpen === 'attach') this.closeComposerMenu({ restoreFocus: true });
                    else this.openComposerMenu('attach');
                });
                attach.addEventListener('keydown', (e) => {
                    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
                    e.preventDefault();
                    this.openComposerMenu('attach');
                    if (e.key === 'ArrowUp') {
                        const items = this._composerMenuItems(document.getElementById('attachMenu'));
                        if (items.length) items[items.length - 1].focus();
                    }
                });
            }

            const more = document.getElementById('sendMenuBtn');
            if (more) {
                more.addEventListener('click', (e) => {
                    e.preventDefault();
                    if (this._composerMenuOpen === 'send') this.closeComposerMenu({ restoreFocus: true });
                    else this.openComposerMenu('send');
                });
            }

            const send = document.getElementById('sendBtn');
            if (send) {
                send.addEventListener('keydown', (e) => {
                    if (!C().isMenuKey(e)) return;
                    e.preventDefault();
                    e.stopPropagation();
                    this.openComposerMenu('send');
                });
            }

            ['emojiInputBtn', 'formatEmojiBtn'].forEach((id) => {
                const emoji = document.getElementById(id);
                if (emoji) emoji.addEventListener('click', (e) => { this._pickerFocusTab = e.detail === 0; });
            });

            document.addEventListener('pointerdown', (e) => {
                const kind = this._composerMenuOpen;
                if (!kind) return;
                const menu = document.getElementById(MENUS[kind].menu);
                const trigger = document.getElementById(MENUS[kind].trigger);
                const t = e.target;
                if (t && t.id === 'composerMenuBackdrop') return;
                if ((menu && menu.contains(t)) || (trigger && trigger.contains(t))) return;
                if (kind === 'send') {
                    const split = document.getElementById('sendSplit');
                    if (split && split.contains(t)) return;
                }
                this.closeComposerMenu();
            }, true);

            document.addEventListener('keydown', (e) => {
                if (e.key !== 'Escape') return;
                if (this._composerMenuOpen) {
                    e.preventDefault();
                    e.stopPropagation();
                    this.closeComposerMenu({ restoreFocus: true });
                    return;
                }
                const picker = this._composerInputPickerOpen();
                if (!picker) return;
                e.preventDefault();
                e.stopPropagation();
                if (picker === 'gif') this.closeGifPicker({ keepFocus: true });
                else this.closeEnhancedEmojiModal({ keepFocus: true });
                const btn = this._composerEmojiButton();
                if (btn) btn.focus();
            }, true);

            window.addEventListener('resize', () => { if (this._composerMenuOpen) this.closeComposerMenu(); });

            const input = document.getElementById('messageInput');
            if (input) input.addEventListener('input', () => this.refreshComposerPrimary());
            const container = document.querySelector('.input-container');
            if (container && typeof MutationObserver === 'function') {
                new MutationObserver(() => this._composerScheduleRefresh()).observe(container, {
                    subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['class'],
                });
            }
            const wrap = input && input.closest('.input-wrapper');
            if (wrap && typeof ResizeObserver === 'function') {
                const ro = new ResizeObserver(() => this._syncComposerPill());
                ro.observe(wrap);
                const buttons = container && container.querySelector(':scope > .input-buttons');
                if (buttons) ro.observe(buttons);
            }
            this.refreshComposerPrimary();
        },
    });

    const A = window.NYM_ACTIONS || (window.NYM_ACTIONS = {});
    Object.assign(A, {
        composerPoll: function () { if (window.nym) window.nym.cmdPoll(); },
        composerEvent: function () { if (window.nym) window.nym.openCreateEvent(); },
    });
})();
