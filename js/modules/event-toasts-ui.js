(function () {
    const E = () => window.NymEventToasts;
    const STORE_KEY = 'nym_event_toasts';
    const EVERYONE_RE = /(^|[^\w@])@(everyone|here)\b/i;
    const ONCE_LABELS = ['View-once photo', 'View-once video', 'View-once voice message'];

    function lsGet(k) { try { return localStorage.getItem(k); } catch (_) { return null; } }
    function lsSet(k, v) { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (_) { } }

    Object.assign(NYM.prototype, {
        eventToastSettings() {
            if (!E()) return null;
            let raw = null;
            try { raw = JSON.parse(lsGet(STORE_KEY) || 'null'); } catch (_) { raw = null; }
            return E().normalizeSettings(raw);
        },

        eventToastSettingsForSync() {
            if (!E() || !lsGet(STORE_KEY)) return null;
            return this.eventToastSettings();
        },

        applyEventToastSettings(raw) {
            if (!E() || !raw || typeof raw !== 'object') return;
            lsSet(STORE_KEY, JSON.stringify(E().normalizeSettings(raw)));
            this._etSyncPrefs();
        },

        setEventToastSetting(patch) {
            if (!E()) return;
            lsSet(STORE_KEY, JSON.stringify(E().patchSettings(this.eventToastSettings(), patch)));
            this._etSyncPrefs();
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
        },

        _etTr(s, params) {
            const t = typeof this.uiText === 'function' ? this.uiText(s) : s;
            return E().fill(t, params);
        },

        _etKey(info, entry) {
            const triple = typeof this._clNotifRoute === 'function'
                ? this._clNotifRoute(info || {})
                : [String((info && info.type) || ''), '', (entry && entry.senderPubkey) || ''];
            const LM = window.NymLayoutModel;
            if (LM && typeof LM.notifGroupKey === 'function') return LM.notifGroupKey(triple[0], triple[1], triple[2]);
            return triple.join(':');
        },

        _etKind(entry) {
            const info = entry.channelInfo || {};
            const evId = String(info.eventId || '');
            const body = String(entry.body || '');
            if (info.type === 'reaction') return body.trim().startsWith('⚡') || info.zapMessageId ? 'zap' : 'reaction';
            if (info.type === 'call') return evId.startsWith('call-link-') ? 'invite' : (info.isGroup ? 'group' : 'pm');
            if (info.type === 'group') {
                if (evId.startsWith('join-req-') || evId.startsWith('join-declined-')) return 'invite';
                if (/^Group invite: /.test(String(entry.title || ''))) return 'invite';
                return 'group';
            }
            if (info.type === 'pm') return 'pm';
            return 'channel';
        },

        _etChat(info) {
            const i = info || {};
            const groupName = (id) => {
                const g = id && this.groupConversations && this.groupConversations.get(id);
                return g && g.name ? g.name : this._etTr('Group');
            };
            if (i.type === 'geohash' || i.type === 'channel') return '#' + (i.geohash || i.channel || '');
            if (i.type === 'group') return groupName(i.groupId || String(i.id || '').replace(/^group-/, ''));
            if (i.type === 'call' && i.isGroup) return groupName(i.groupId);
            if (i.type === 'reaction') {
                if (i.sourceType === 'group') return groupName(i.sourceGroupId);
                if (i.sourceType === 'geohash') return '#' + (i.sourceGeohash || i.sourceChannel || '');
            }
            return '';
        },

        _etSender(entry) {
            const pk = entry.senderPubkey || '';
            if (!pk) return String(entry.title || '');
            const info = entry.channelInfo || {};
            const known = typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(pk) : '';
            const hint = info.type === 'pm' && info.nym ? info.nym : (known || 'nym');
            const base = typeof this.resolveDisplayNym === 'function' ? this.resolveDisplayNym(pk, hint) : hint;
            const clean = typeof this.parseNymFromDisplay === 'function' ? this.parseNymFromDisplay(base) : base;
            const suffix = typeof this.getPubkeySuffix === 'function' ? this.getPubkeySuffix(pk) : '';
            return clean + (suffix ? '#' + suffix : '');
        },

        _etViewOnce(body) {
            const s = String(body || '').trim();
            return ONCE_LABELS.some((l) => s.startsWith(l) || s.startsWith(this._etTr(l)));
        },

        _etEvent(entry, backlog) {
            const info = entry.channelInfo || {};
            const kind = this._etKind(entry);
            const body = String(entry.body || '');
            const locked = !!entry.locked;
            const mentioned = !locked && typeof this.isMentioned === 'function' && this.isMentioned(body);
            if (!this._etEntries) this._etEntries = new Map();
            this._etSeq = (this._etSeq || 0) + 1;
            const token = 'et' + this._etSeq;
            this._etEntries.set(token, entry);
            return {
                kind,
                key: this._etKey(info, entry),
                sender: locked ? '' : this._etSender(entry),
                chat: locked ? '' : this._etChat(info),
                body: locked ? '' : body,
                mention: kind === 'channel' ? !info.inThread || mentioned : mentioned,
                everyone: !locked && kind === 'group' && EVERYONE_RE.test(body),
                thread: !!info.inThread,
                seen: this._etSees(entry),
                locked,
                viewOnce: !locked && this._etViewOnce(body),
                backlog: !!backlog,
                identity: this.pubkey || '',
                eventId: token,
            };
        },

        _etSees(entry) {
            const info = (entry && entry.channelInfo) || {};
            return typeof this._notifSees === 'function' && !!this._notifSees(info, true);
        },

        _etTopDialog() {
            if (typeof document === 'undefined') return null;
            if (window.nymA11y && typeof window.nymA11y.top === 'function') {
                try { const t = window.nymA11y.top(); if (t) return t; } catch (_) { }
            }
            const all = document.querySelectorAll('.modal, .shop-modal, .geohash-explorer-modal');
            for (let i = all.length - 1; i >= 0; i--) {
                const m = all[i];
                if (m.id === 'imageModal') continue;
                const cs = getComputedStyle(m);
                if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0) continue;
                const r = m.getBoundingClientRect();
                if (r.width > 0 && r.height > 0) return m;
            }
            return null;
        },

        _toastShouldHold() {
            const d = this._etTopDialog();
            if (!d) return false;
            const act = this._toastLastAct;
            return !(act && Date.now() - act.at < 1500 && act.target && d.contains(act.target));
        },

        _toastWatchHeld() {
            if (this._toastHeldTimer) return;
            this._toastHeldTimer = setInterval(() => this._toastReleaseHeld(), 300);
        },

        _toastReleaseHeld() {
            const held = this._toastHeld || [];
            if (held.length && this._etTopDialog()) return;
            clearInterval(this._toastHeldTimer);
            this._toastHeldTimer = null;
            this._toastHeld = [];
            if (!held.length) return;
            const now = Date.now();
            for (const h of held) {
                const undo = !!(h.opts.action && typeof h.opts.onAction === 'function');
                if (!undo && window.NymToasts) {
                    const kind = h.opts.kind || window.NymToasts.classify(h.content);
                    if (now - h.at > window.NymToasts.durationFor(h.content, kind)) continue;
                }
                this.showToast(h.content, Object.assign({}, h.opts, { _released: true }));
            }
        },

        _etSheetOpen() {
            return !!this._etTopDialog();
        },

        _etView() {
            return {
                foreground: typeof document !== 'undefined' && !document.hidden,
                call: !!this.activeCall,
                sheet: this._etSheetOpen(),
                identity: this.pubkey || '',
            };
        },

        _etConsider(entry, backlog) {
            if (!E() || !entry) return null;
            let d;
            try {
                const ev = this._etEvent(entry, backlog);
                d = E().decide(ev, this._etView(), this.eventToastSettings());
                if (d.toast === 'show') this._etApply(E().add(this._etState || E().emptyState(), ev, Date.now()));
                else if (d.toast === 'hold') this._etHold(ev, d.reason);
                else this._etEntries.delete(ev.eventId);
            } catch (_) {
                return null;
            }
            return d;
        },

        _etHold(ev, reason) {
            if (!this._etHeld) this._etHeld = [];
            this._etHeld.push(ev);
            ev.heldAt = Date.now();
            ev.heldFor = reason || '';
            if (ev.backlog) {
                if (!this._etBacklogFirst) this._etBacklogFirst = Date.now();
                this._etBacklogAt = Date.now();
            }
            if (this._etHeldTimer) return;
            this._etHeldTimer = setInterval(() => this._etTryFlush(), 500);
        },

        _etTryFlush() {
            const held = this._etHeld || [];
            if (!held.length) {
                clearInterval(this._etHeldTimer);
                this._etHeldTimer = null;
                return;
            }
            const view = this._etView();
            if (!view.foreground || view.call || view.sheet) return;
            if (held.some((e) => e.backlog)
                && Date.now() - (this._etBacklogAt || 0) < E().CONFIG.backlogQuietMs
                && Date.now() - (this._etBacklogFirst || 0) < E().CONFIG.backlogMaxMs) return;
            this._etHeld = [];
            this._etBacklogFirst = 0;
            clearInterval(this._etHeldTimer);
            this._etHeldTimer = null;
            const s = this.eventToastSettings();
            const now = Date.now();
            const fresh = held.filter((e) => {
                const n = this._etEntries && this._etEntries.get(e.eventId);
                if (!n || n.viewed) return false;
                if (!e.backlog && e.heldFor !== 'sheet' && now - (e.heldAt || now) > E().CONFIG.durationMs) return false;
                const d = E().decide(Object.assign({}, e, { backlog: false, seen: this._etSees(n) }), Object.assign({}, view, { call: false, sheet: false }), s);
                return d.toast === 'show';
            });
            for (const e of held) if (!fresh.includes(e) && this._etEntries) this._etEntries.delete(e.eventId);
            if (fresh.length) this._etApply(E().addMany(this._etState || E().emptyState(), fresh, Date.now()));
        },

        _etApply(r) {
            this._etState = r.state;
            this._etRender();
            this._etArm();
        },

        _etStack() {
            if (typeof document === 'undefined' || !document.body) return null;
            let stack = document.getElementById('nymToastStack');
            if (!stack) {
                stack = document.createElement('div');
                stack.id = 'nymToastStack';
                stack.className = 'nym-toast-stack';
                document.body.appendChild(stack);
                const again = () => this._etPlace();
                window.addEventListener('resize', again);
                const main = document.querySelector('.main-content');
                if (main && typeof ResizeObserver === 'function') new ResizeObserver(again).observe(main);
                if (typeof MutationObserver === 'function') new MutationObserver(again).observe(stack, { childList: true, subtree: true });
            }
            let sys = document.getElementById('nymToasts');
            if (!sys) {
                sys = document.createElement('div');
                sys.id = 'nymToasts';
                sys.className = 'nym-toasts';
            }
            if (sys.parentNode !== stack) stack.insertBefore(sys, stack.firstChild);
            return stack;
        },

        _etHost() {
            const stack = this._etStack();
            if (!stack) return null;
            let host = document.getElementById('nymEventToasts');
            if (!host) {
                host = document.createElement('div');
                host.id = 'nymEventToasts';
                host.className = 'nym-event-toasts';
            }
            if (host.parentNode !== stack) stack.appendChild(host);
            return host;
        },

        _etSafeTop() {
            let probe = document.getElementById('nymSafeTopProbe');
            if (!probe) {
                probe = document.createElement('div');
                probe.id = 'nymSafeTopProbe';
                probe.className = 'nym-safe-top-probe';
                probe.setAttribute('aria-hidden', 'true');
                document.body.appendChild(probe);
            }
            const cs = getComputedStyle(probe);
            return { top: parseFloat(cs.paddingTop) || 0, left: parseFloat(cs.paddingLeft) || 0, right: parseFloat(cs.paddingRight) || 0 };
        },

        _etPlace() {
            const host = document.getElementById('nymToastStack');
            if (!host || !E()) return;
            const shown = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 ? r : null; };
            const main = shown(document.querySelector('.main-content'));
            const header = shown(document.querySelector('.main-content > .chat-header'));
            const composer = shown(document.querySelector('.main-content .input-container'));
            const vw = window.innerWidth || document.documentElement.clientWidth;
            const vh = window.innerHeight || document.documentElement.clientHeight;
            const safe = this._etSafeTop();
            const p = E().place({
                vw, vh,
                safeTop: safe.top,
                safeLeft: safe.left,
                safeRight: safe.right,
                headerBottom: header ? header.bottom : 0,
                chatLeft: main ? main.left : 0,
                chatRight: main ? main.right : vw,
                composerTop: composer ? composer.top : vh,
            });
            const d = this._etTopDialog();
            this._etPlacedFor = 0;
            if (d) {
                const panel = shown(d.querySelector('.modal-content, .shop-content, .geohash-explorer-content')) || shown(d);
                if (panel) {
                    this._etPlacedFor = 1;
                    const safe2 = safe.top;
                    const above = panel.top - safe2 - 16;
                    const below = vh - panel.bottom - 16;
                    if (above >= below) {
                        p.top = Math.round(safe2 + 8);
                        p.maxHeight = Math.max(0, Math.round(panel.top - 8 - p.top));
                    } else {
                        p.top = Math.round(panel.bottom + 8);
                        p.maxHeight = Math.max(0, Math.round(vh - 8 - p.top));
                    }
                }
            }
            host.style.top = p.top + 'px';
            host.style.left = p.left + 'px';
            host.style.width = p.width + 'px';
            host.style.maxHeight = p.maxHeight + 'px';
            host.dataset.align = p.align;
        },

        _etRender() {
            const host = this._etHost();
            if (!host) return;
            this._etPlace();
            const state = this._etState || E().emptyState();
            const live = new Set(state.toasts.map((t) => String(t.id)));
            host.querySelectorAll('.nym-toast-event').forEach((el) => {
                if (!live.has(el.dataset.eventToastId) && !el.classList.contains('leaving')) this._etRemoveEl(el);
            });
            const prefs = { hidePreviews: lsGet('nym_hide_previews') === '1' };
            const tr = (s, p) => this._etTr(s, p);
            state.toasts.forEach((t, i) => {
                const p = E().present(t, prefs, tr);
                let el = host.querySelector('.nym-toast-event:not(.leaving)[data-event-toast-id="' + t.id + '"]');
                const fresh = !el;
                if (fresh) el = this._etBuild(t.id);
                el.dataset.target = p.target;
                el.dataset.count = String(t.count);
                el.dataset.kind = t.kind;
                el.dataset.key = t.key || '';
                el.classList.toggle('nym-toast-summary', t.kind === 'summary');
                el.classList.toggle('nym-toast-locked', !!t.locked);
                const set = (sel, text) => {
                    const n = el.querySelector(sel);
                    if (n.textContent !== text) n.textContent = text;
                    n.classList.toggle('nm-hidden', !text);
                };
                this._etTitle(el.querySelector('.nym-toast-title'), p.title, t.locked || !t.last ? '' : String(t.last.sender || ''));
                set('.nym-toast-meta', p.meta);
                set('.nym-toast-body', p.body);
                if (fresh) {
                    const firstEvent = host.querySelector('.nym-toast-event:not(.leaving)');
                    if (i === 0 && firstEvent) host.insertBefore(el, firstEvent);
                    else host.appendChild(el);
                    requestAnimationFrame(() => el.classList.add('visible'));
                }
            });
            this._etPrune();
        },

        _etTitle(node, title, sender) {
            const m = /^(.*\S)(#[0-9a-f]{4})$/i.exec(sender || '');
            const at = m ? title.lastIndexOf(sender) : -1;
            const key = title + '\u0000' + (at >= 0 ? sender : '');
            node.classList.toggle('nm-hidden', !title);
            if (node.dataset.shown === key) return;
            node.dataset.shown = key;
            node.textContent = '';
            if (at < 0) { node.textContent = title; return; }
            const cut = at + m[1].length;
            node.appendChild(document.createTextNode(title.slice(0, cut)));
            const dim = document.createElement('span');
            dim.className = 'nym-suffix';
            dim.textContent = m[2];
            node.appendChild(dim);
            if (cut + m[2].length < title.length) node.appendChild(document.createTextNode(title.slice(cut + m[2].length)));
        },

        _etBuild(id) {
            const el = document.createElement('div');
            el.className = 'nym-toast nym-toast-event';
            el.dataset.eventToastId = String(id);
            el.setAttribute('role', 'status');
            el.setAttribute('aria-live', 'polite');
            el.setAttribute('aria-atomic', 'true');
            const open = document.createElement('button');
            open.type = 'button';
            open.className = 'nym-toast-open nym-toast-text';
            open.innerHTML = '<span class="nym-toast-title"></span><span class="nym-toast-meta"></span><span class="nym-toast-body"></span>';
            const close = document.createElement('button');
            close.type = 'button';
            close.className = 'nym-toast-close';
            const label = this._etTr('Dismiss');
            close.setAttribute('aria-label', label);
            close.title = label;
            close.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg>';
            el.appendChild(open);
            el.appendChild(close);
            this._etWire(el, id);
            return el;
        },

        _etWire(el, id) {
            const pause = () => {
                if (!this._etState) return;
                this._etState = E().pause(this._etState, id, Date.now());
                this._etArm();
            };
            const resume = () => {
                if (!this._etState || el.matches(':hover') || el.contains(document.activeElement)) return;
                this._etState = E().resume(this._etState, id, Date.now());
                this._etArm();
            };
            el.addEventListener('mouseenter', pause);
            el.addEventListener('mouseleave', () => setTimeout(resume, 0));
            el.addEventListener('focusin', pause);
            el.addEventListener('focusout', () => setTimeout(resume, 0));
            el.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') { e.preventDefault(); this.dismissEventToast(id); }
            });
            let start = null;
            let dx = 0;
            el.addEventListener('pointerdown', (e) => {
                if (e.button !== undefined && e.button !== 0) return;
                start = { x: e.clientX, y: e.clientY, id: e.pointerId };
                dx = 0;
            });
            el.addEventListener('pointermove', (e) => {
                if (!start || e.pointerId !== start.id) return;
                dx = e.clientX - start.x;
                if (Math.abs(dx) > 6 && Math.abs(dx) > Math.abs(e.clientY - start.y)) {
                    el.classList.add('dragging');
                    el.style.transform = 'translateX(' + dx + 'px)';
                    el.style.opacity = String(Math.max(0.2, 1 - Math.abs(dx) / 200));
                }
            });
            const end = (e) => {
                if (!start || (e && e.pointerId !== start.id)) return;
                start = null;
                el.classList.remove('dragging');
                if (Math.abs(dx) >= E().CONFIG.swipeDismissPx) {
                    el.dataset.swiped = '1';
                    this.dismissEventToast(id);
                    return;
                }
                el.style.transform = '';
                el.style.opacity = '';
            };
            el.addEventListener('pointerup', end);
            el.addEventListener('pointercancel', end);
            el.addEventListener('click', (e) => {
                if (el.dataset.swiped) return;
                if (Math.abs(dx) > 6) { dx = 0; return; }
                if (e.target.closest('.nym-toast-close')) { this.dismissEventToast(id); return; }
                this.openEventToast(id);
            });
        },

        dismissEventToast(id) {
            if (!this._etState) return;
            this._etState = E().dismiss(this._etState, id);
            this._etRender();
            this._etArm();
        },

        openEventToast(id) {
            const t = this._etState && this._etState.toasts.find((x) => x.id === id);
            if (!t) return;
            this.dismissEventToast(id);
            if (t.kind === 'summary') {
                if (typeof this.openNotificationsModal === 'function') this.openNotificationsModal();
                return;
            }
            const entries = t.events.map((tok) => this._etEntries && this._etEntries.get(tok)).filter(Boolean);
            this._etMarkViewed(entries);
            const last = entries[entries.length - 1];
            if (last && typeof this._openNotificationTarget === 'function') this._openNotificationTarget(last);
        },

        _etMarkViewed(entries) {
            let changed = false;
            for (const n of entries) {
                if (!n || n.viewed) continue;
                n.viewed = true;
                if (typeof this._rememberNotificationSeen === 'function') this._rememberNotificationSeen(n, false);
                changed = true;
            }
            if (!changed) return;
            if (typeof this._saveSeenNotificationKeys === 'function') this._saveSeenNotificationKeys();
            if (typeof this._saveNotificationHistory === 'function') this._saveNotificationHistory();
            if (typeof this._updateNotificationBadge === 'function') this._updateNotificationBadge();
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
        },

        _etPrune() {
            if (!this._etEntries || this._etEntries.size < 200) return;
            const keep = new Set();
            for (const t of (this._etState ? this._etState.toasts : [])) for (const tok of t.events) keep.add(tok);
            for (const e of (this._etHeld || [])) keep.add(e.eventId);
            for (const k of Array.from(this._etEntries.keys())) if (!keep.has(k)) this._etEntries.delete(k);
        },

        _etRemoveEl(el) {
            el.classList.remove('visible');
            el.classList.add('leaving');
            el.setAttribute('aria-hidden', 'true');
            const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
            if (reduce) { el.remove(); return; }
            setTimeout(() => el.remove(), 200);
        },

        _etArm() {
            clearTimeout(this._etTimer);
            this._etTimer = null;
            if (!this._etState) return;
            const next = E().nextExpiry(this._etState);
            if (next === null) return;
            this._etTimer = setTimeout(() => {
                this._etTimer = null;
                const r = E().expire(this._etState, Date.now());
                this._etState = r.state;
                if (r.expired.length) this._etRender();
                this._etArm();
            }, Math.max(0, next - Date.now()) + 5);
        },

        _etSyncPrefs() {
            if (typeof document === 'undefined' || !E()) return;
            const s = this.eventToastSettings();
            const master = document.getElementById('eventToastsCheckbox');
            if (master) master.checked = s.enabled;
            const mode = document.getElementById('eventToastsForeground');
            if (mode) mode.value = s.foreground;
            const types = document.getElementById('eventToastTypes');
            if (types) types.classList.toggle('et-off', !s.enabled || s.foreground === 'system');
            for (const k of E().TYPES) {
                const box = document.getElementById('eventToastType-' + k);
                if (box) {
                    box.checked = !!s.types[k];
                    box.disabled = !s.enabled || s.foreground === 'system';
                }
            }
        },

        _etBuildPrefs() {
            if (typeof document === 'undefined' || !E()) return;
            const prefs = document.getElementById('notifPrefs');
            if (!prefs || document.getElementById('eventToastPrefs')) return;
            const wrap = document.createElement('div');
            wrap.id = 'eventToastPrefs';
            wrap.className = 'et-prefs';
            const tr = (s) => this._etTr(s);
            const S = E().STRINGS;
            const modes = E().FOREGROUND_MODES.map((m) => '<option value="' + m + '">' + this.escapeHtml(tr(E().FOREGROUND_LABELS[m])) + '</option>').join('');
            const types = E().TYPES.map((k) => '<label class="et-type"><input type="checkbox" class="nm-h-79" id="eventToastType-' + k + '" data-et-type="' + k + '"> ' + this.escapeHtml(tr(E().SETTING_LABELS[k])) + '</label>').join('');
            wrap.innerHTML =
                '<label class="et-row et-master"><input type="checkbox" class="nm-h-79" id="eventToastsCheckbox"> ' + this.escapeHtml(tr(S.master)) + '</label>' +
                '<label class="et-row et-mode" for="eventToastsForeground"><span>' + this.escapeHtml(tr(S.whileOpen)) + '</span>' +
                '<select id="eventToastsForeground" class="form-select">' + modes + '</select></label>' +
                '<fieldset class="et-types" id="eventToastTypes"><legend>' + this.escapeHtml(tr(S.typesHeading)) + '</legend>' + types + '</fieldset>';
            prefs.appendChild(wrap);
            wrap.addEventListener('change', (e) => {
                const t = e.target;
                if (t.id === 'eventToastsCheckbox') this.setEventToastSetting({ enabled: t.checked });
                else if (t.id === 'eventToastsForeground') this.setEventToastSetting({ foreground: t.value });
                else if (t.dataset && t.dataset.etType) this.setEventToastSetting({ types: { [t.dataset.etType]: t.checked } });
            });
            this._etSyncPrefs();
        },
    });

    if (typeof document !== 'undefined') {
        const note = (e) => { const n = window.nym; if (n) n._toastLastAct = { at: Date.now(), target: e.target }; };
        document.addEventListener('pointerdown', note, true);
        document.addEventListener('keydown', note, true);
        const replace = () => {
            const n = window.nym;
            const stack = document.getElementById('nymToastStack');
            if (!n || !stack || typeof n._etPlace !== 'function') return;
            if (!stack.querySelector('.nym-toast:not(.leaving)')) return;
            const d = n._etTopDialog() ? 1 : 0;
            if (d === n._etPlacedFor) return;
            n._etPlace();
            requestAnimationFrame(() => { n._etPlace(); requestAnimationFrame(() => n._etPlace()); });
            setTimeout(() => n._etPlace(), 250);
        };
        const watch = () => {
            if (!document.body || typeof MutationObserver !== 'function') return;
            new MutationObserver(replace).observe(document.body, { attributes: true, attributeFilter: ['class', 'style'], subtree: true });
        };
        if (document.body) watch();
        else document.addEventListener('DOMContentLoaded', watch);
        const boot = () => {
            const n = window.nym;
            if (n && typeof n._etBuildPrefs === 'function') n._etBuildPrefs();
            else setTimeout(boot, 300);
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
        else boot();
    }
})();
