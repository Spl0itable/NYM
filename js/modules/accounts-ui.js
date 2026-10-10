(function () {
    const M = () => window.NymAccounts;
    const GLYPH = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="10" r="3"></circle><path d="M7.5 18a5 5 0 0 1 9 0"></path><path d="M3 12a9 9 0 0 1 15.4-6.4L21 8"></path><polyline points="21 3 21 8 16 8"></polyline><path d="M21 12a9 9 0 0 1-15.4 6.4L3 16"></path><polyline points="3 21 3 16 8 16"></polyline></svg>';
    const CHECK = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="20 6 9 17 4 12"></polyline></svg>';
    const BADGE = { nsec: 'nsec', extension: 'Extension (NIP-07)', nip46: 'Bunker (NIP-46)', ephemeral: 'Ephemeral', anonymous: 'Anonymous' };
    const MEDIA_CACHE = 'nym-media-v1';
    const WATCH_RELAY = 'wss://relay.damus.io';
    const DRAFTS_KEY = 'nym_switch_drafts';

    const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

    Object.assign(NYM.prototype, {
        _ac(text, vars) {
            let s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        acctEnabled() {
            const A = M();
            return !!(A && typeof A.read === 'function');
        },

        acctSetup() {
            if (!this.acctEnabled() || this._acctSetupDone) return;
            this._acctSetupDone = true;
            this._acctWatchers = new Map();
            this._acctRenderButton();
            this._acctRenderAddMode();
            this._acctTimer = setInterval(() => this._acctTick(), 1500);
            setTimeout(() => this._acctTick(), 300);
        },

        _acctLabel(a) {
            const nym = String(a.nym || '').replace(/#[0-9a-f]{4}$/i, '') || this._ac('Unnamed');
            if (a.pubkey && window.NymSuffix) window.NymSuffix.remember(a.pubkey);
            return a.pubkey ? nym + '#' + a.pubkey.slice(-4) : nym;
        },

        _acctRenderButton() {
            const btn = document.getElementById('acctSwitchBtn');
            if (!btn) return;
            const idx = M().read();
            const others = idx.accounts.filter((a) => a.id !== M().pageId);
            const unread = others.reduce((n, a) => n + (a.unread || 0), 0);
            const dot = document.getElementById('acctSwitchDot');
            if (dot) dot.classList.toggle('nm-hidden', !unread);
        },

        _acctRenderAddMode() {
            const A = M();
            const row = document.getElementById('setupAccountBack');
            if (!row) return;
            const idx = A.read();
            const cur = A.activeOf(idx);
            const from = cur && !cur.pubkey && cur.returnTo ? idx.accounts.find((a) => a.id === cur.returnTo) : null;
            const others = idx.accounts.filter((a) => a.pubkey && (!cur || a.id !== cur.id));
            if (!cur || cur.pubkey || !others.length) { row.classList.add('nm-hidden'); return; }
            const label = document.getElementById('setupAccountBackLabel');
            if (label) this.renderNymText(label, from ? this._ac('Back to {nym}', { nym: this._acctLabel(from) }) : this._ac('Back to my identities'), from ? [from.pubkey] : []);
            row.classList.remove('nm-hidden');
        },

        _acctTick() {
            const A = M();
            if (!A || A.frozen) return;
            this._acctRenderButton();
            if (!this.pubkey || !this.connected) return;
            const setup = document.getElementById('setupModal');
            if (setup && setup.classList.contains('active')) return;
            const idx = A.read();
            if (idx.journal || idx.active !== A.pageId) return;
            const reg = this._acctRegister(idx);
            if (reg === 'duplicate') return;
            if (!this._acctBooted && reg === 'ok') {
                this._acctBooted = true;
                this._acctResume();
                this._acctSyncWatchers();
            }
            const now = Date.now();
            if (!this._acctThumbAt || now - this._acctThumbAt > 30000) {
                this._acctThumbAt = now;
                this._acctSnapshotAvatar();
            }
        },

        _acctLiveMethod() {
            let method = '';
            try { method = M().methodFromStorage((k) => localStorage.getItem(k)); } catch (_) { }
            return method || this.nostrLoginMethod || 'ephemeral';
        },

        _acctRegister(idxIn) {
            const A = M();
            if (!this.pubkey || A.frozen) return 'none';
            const idx = idxIn || A.read();
            if (idx.journal || idx.active !== A.pageId) return 'none';
            const method = this._acctLiveMethod();
            const nym = String(this.nym || '');
            const cur = A.activeOf(idx);
            if (cur && cur.pubkey === this.pubkey && cur.method === method && cur.nym === nym) return 'ok';
            const id = A.pageId || A.randomId();
            const r = A.plan(idx, { type: 'register', id, now: Date.now(), pubkey: this.pubkey, method, nym });
            if (r.result === 'duplicate') { this._acctDuplicate(r); return 'duplicate'; }
            if (!r.ok) return 'none';
            const next = Object.assign({}, r.index, { journal: null });
            try { localStorage.setItem(A.INDEX_KEY, JSON.stringify(next)); } catch (_) { return 'none'; }
            const mine = A.activeOf(r.index);
            if (mine) A.adopt(mine);
            this._acctRenderAddMode();
            return 'ok';
        },

        _acctFail(res) {
            const text = res && res.error === 'quota'
                ? this._ac("This device's storage is full, so nothing was changed and you are still on this identity. Free up space or remove an identity, then try again.")
                : this._ac('The identity change could not be saved, so nothing was changed and you are still on this identity. Try again.');
            try {
                if (typeof this.showToast === 'function') this.showToast(text, { kind: 'error' });
                else this.displaySystemMessage(text);
            } catch (_) { }
        },

        async _acctDuplicate(r) {
            if (this._acctDupShown) return;
            this._acctDupShown = true;
            const A = M();
            const other = A.read().accounts.find((a) => a.id === r.existing);
            const name = other ? this._acctLabel(other) : '';
            if (!r.ok) {
                try { this.displaySystemMessage(this._ac('This key is also saved as {nym}. Switch to it from Manage Identities.', { nym: name })); } catch (_) { }
                return;
            }
            try { await window.showAppAlert(this._ac('{nym} is already saved on this device, so the app switches to it.', { nym: name }), { title: this._ac('Identity already added') }); } catch (_) { }
            await this._acctGo(r);
        },

        _acctSnapshotAvatar() {
            const img = document.getElementById('sidebarAvatar');
            if (!img || !img.complete || !img.naturalWidth || /fill='%23222'/.test(img.src || '')) return;
            let url = '';
            try {
                const c = document.createElement('canvas');
                c.width = 32; c.height = 32;
                c.getContext('2d').drawImage(img, 0, 0, 32, 32);
                url = c.toDataURL('image/jpeg', 0.7);
            } catch (_) { url = ''; }
            if (!url || url.length > M().AVATAR_MAX) return;
            M().update((idx) => {
                const a = idx.accounts.find((x) => x.id === M().pageId);
                if (!a || a.avatar === url) return null;
                a.avatar = url;
                return idx;
            });
        },

        _acctDrafts() {
            try {
                if (!this._activeDraftKey && typeof this._getInputContextKey === 'function') this._activeDraftKey = this._getInputContextKey();
                if (typeof this._saveCurrentDraft === 'function') this._saveCurrentDraft();
            } catch (_) { }
            const list = this._inputDrafts ? [...this._inputDrafts.entries()].filter(([k, v]) => k && typeof v === 'string' && v.trim()) : [];
            return list.slice(0, 50);
        },

        _acctUnsent() {
            const signed = (m) => Array.isArray(m) && m[0] === 'EVENT' && m[1] && typeof m[1].id === 'string' && typeof m[1].sig === 'string' && m[1].sig.length > 0;
            const events = [];
            const seen = new Set();
            const add = (m, dm) => {
                if (!signed(m) || seen.has(m[1].id)) return;
                seen.add(m[1].id);
                events.push({ m, dm: !!dm });
            };
            for (const q of this._dmOutbox || []) for (const e of q || []) add(e && e.message, true);
            for (const h of this._heldEvents || []) add(h && h.message, h && h.kind === 'dm');
            for (const v of (this._dmInflight || new Map()).values()) add(v && v.message, true);
            const pending = [];
            for (const [id, p] of this.pendingDMs || new Map()) {
                const wraps = (p && Array.isArray(p.wrappedEvents) ? p.wrappedEvents : []).filter(signed);
                if (wraps.length) pending.push({ id, wraps, to: p.recipientPubkey || '', conv: p.conversationKey || '' });
            }
            return { events: events.slice(-2000), pending: pending.slice(-500) };
        },

        _acctOutboxBusy() {
            const held = (this._heldEvents || []).length;
            const queued = typeof this._dmOutboxSize === 'function' ? this._dmOutboxSize() : 0;
            const inflight = this._dmInflight ? this._dmInflight.size : 0;
            return held + queued + inflight;
        },

        async _acctDrain(ms) {
            const until = Date.now() + ms;
            try { if (typeof this._flushHeldEvents === 'function' && this._anyRelayOpen()) this._flushHeldEvents(); } catch (_) { }
            while (Date.now() < until && this._acctOutboxBusy()) {
                let open = false;
                try { open = this._anyRelayOpen(); } catch (_) { open = false; }
                if (!open) break;
                await new Promise((r) => setTimeout(r, 100));
            }
        },

        async _acctResume() {
            const A = M();
            let carry = null;
            try { carry = await A.carryTake(A.pageId); } catch (_) { carry = null; }
            let legacy = null;
            try { legacy = JSON.parse(localStorage.getItem(DRAFTS_KEY) || 'null'); } catch (_) { legacy = null; }
            try { localStorage.removeItem(DRAFTS_KEY); } catch (_) { }
            if (carry && carry.pubkey && carry.pubkey !== this.pubkey) {
                await A.carryPut(A.pageId, carry);
                carry = null;
            }
            const drafts = [].concat(Array.isArray(legacy) ? legacy : [], carry && Array.isArray(carry.drafts) ? carry.drafts : []);
            this._acctRestoreDrafts(drafts);
            if (carry) this._acctResend(carry);
        },

        _acctResend(carry) {
            for (const p of Array.isArray(carry.pending) ? carry.pending : []) {
                if (!p || typeof p.id !== 'string' || !Array.isArray(p.wraps) || !p.wraps.length) continue;
                try {
                    if (!this.pendingDMs.has(p.id) && typeof this.trackPendingDM === 'function') this.trackPendingDM(p.id, p.wraps, p.to, p.conv);
                } catch (_) { }
                for (const w of p.wraps) { try { this.sendDMToRelays(w); } catch (_) { } }
            }
            for (const e of Array.isArray(carry.events) ? carry.events : []) {
                if (!e || !Array.isArray(e.m)) continue;
                try {
                    if (e.dm) this.sendDMToRelays(e.m);
                    else this.broadcastEvent(e.m);
                } catch (_) { }
            }
        },

        _acctRestoreDrafts(list) {
            if (!Array.isArray(list) || !list.length) return;
            if (!this._inputDrafts) this._inputDrafts = new Map();
            for (const e of list) {
                if (Array.isArray(e) && typeof e[0] === 'string' && typeof e[1] === 'string' && !this._inputDrafts.has(e[0])) this._inputDrafts.set(e[0], e[1]);
            }
            this._activeDraftKey = null;
            try { if (typeof this._restoreDraftForContext === 'function') this._restoreDraftForContext(); } catch (_) { }
        },

        async _acctPrepareLeave() {
            this._acctSnapshotAvatar();
            await this._acctDrain(3000);
            try { if (typeof this.flushPendingGroupReactions === 'function') this.flushPendingGroupReactions(); } catch (_) { }
            try { if (typeof this._persistUnreadCounts === 'function') this._persistUnreadCounts(true); } catch (_) { }
            try {
                if (this._pmDepositPersistTimer) { clearTimeout(this._pmDepositPersistTimer); this._pmDepositPersistTimer = null; }
                if (typeof this._pmDepositPersist === 'function') await Promise.race([this._pmDepositPersist(), new Promise((r) => setTimeout(r, 1500))]);
            } catch (_) { }
            try {
                if (typeof this.flushPendingPersists === 'function') await Promise.race([Promise.resolve(this.flushPendingPersists({ sync: true })), new Promise((r) => setTimeout(r, 2500))]);
            } catch (_) { }
            for (const w of (this._acctWatchers || new Map()).values()) { try { w.stop(); } catch (_) { } }
            if (this._acctWatchers) this._acctWatchers.clear();
        },

        _acctReturnUrl() {
            let hash = '';
            try {
                const ch = this.currentChannel;
                if (!this.inPMMode && ch && typeof ch === 'string' && typeof this.isValidGeohash === 'function' && this.isValidGeohash(ch)) hash = '#' + ch;
            } catch (_) { }
            return location.pathname + hash;
        },

        async _acctGo(r) {
            const A = M();
            if (!r || !r.ok || this._acctGoing) return false;
            const wipes = r.effects.filter((e) => e.startsWith('wipe:'));
            if (r.effects.includes('reload')) {
                this._acctGoing = true;
                const overlay = document.getElementById('acctSwitchOverlay');
                if (overlay) overlay.classList.add('active');
                const leaving = A.pageId;
                let carried = false;
                try {
                    if (typeof this._sendAsLeave === 'function') await this._sendAsLeave(r.index.active);
                    await this._acctPrepareLeave();
                    if (leaving && this.pubkey) {
                        const unsent = this._acctUnsent();
                        carried = await A.carryPut(leaving, { pubkey: this.pubkey, at: Date.now(), drafts: this._acctDrafts(), events: unsent.events, pending: unsent.pending });
                    }
                } catch (_) { }
                let res = null;
                try { res = await A.apply(r, A.read(), { before: () => A.freeze() }); } catch (e) { res = { ok: false, error: A.isQuota(e) ? 'quota' : 'storage' }; }
                if (!res || !res.ok) {
                    A.thaw();
                    if (carried) await A.carryDel(leaving);
                    if (overlay) overlay.classList.remove('active');
                    this._acctGoing = false;
                    this._acctSyncWatchers();
                    this._acctFail(res);
                    return false;
                }
                if (wipes.length) { try { await caches.delete(MEDIA_CACHE); } catch (_) { } }
                if (typeof this._resetAppBadge === 'function') this._resetAppBadge();
                try { history.replaceState(null, '', this._acctReturnUrl()); } catch (_) { }
                location.reload();
                return true;
            }
            let res = null;
            try { res = await A.apply(r, A.read()); } catch (e) { res = { ok: false, error: A.isQuota(e) ? 'quota' : 'storage' }; }
            if (!res || !res.ok) { this._acctFail(res); return false; }
            for (const name of res.dbs) { try { indexedDB.deleteDatabase(name); } catch (_) { } }
            if (wipes.length) { try { await caches.delete(MEDIA_CACHE); } catch (_) { } }
            this._acctSyncWatchers();
            this._acctRenderButton();
            if (document.getElementById('accountSwitcherModal')?.classList.contains('active')) this.openAccountSwitcher();
            return true;
        },

        async openAccountSwitcher() {
            if (!this.acctEnabled()) return;
            const A = M();
            if (this.pubkey && !A.frozen) this._acctRegister();
            this._acctSnapshotAvatar();
            const idx = A.read();
            const list = document.getElementById('acctList');
            if (!list) return;
            if (this.pubkey && !idx.accounts.some((a) => a.id === A.pageId)) {
                idx.accounts.push({ id: A.pageId || 'live', ns: '', pubkey: this.pubkey, method: this._acctLiveMethod(), nym: String(this.nym || ''), avatar: '', addedAt: Date.now(), notifyInactive: false, unread: 0, returnTo: null, live: true });
            }
            const copyable = new Set();
            await Promise.all(idx.accounts.map(async (a) => { if (await this._acctNsecFor(a)) copyable.add(a.id); }));
            const rows = idx.accounts.map((a) => {
                const active = !!a.live || a.id === A.pageId;
                const avatarSrc = active ? ((document.getElementById('sidebarAvatar') || {}).src || a.avatar) : a.avatar;
                const avatar = avatarSrc
                    ? `<img class="acct-avatar" src="${esc(avatarSrc)}" alt="" width="36" height="36">`
                    : `<span class="acct-avatar acct-avatar-blank">${esc((a.nym || '?').slice(0, 1).toUpperCase())}</span>`;
                const nameHtml = a.pubkey
                    ? `<bdi class="acct-nym">${window.NymSuffix.pubkeyHtml(a.nym || this._ac('Unnamed'), a.pubkey)}</bdi>`
                    : esc(this._ac('New identity'));
                const badge = BADGE[a.method] ? `<span class="acct-badge">${esc(this._ac(BADGE[a.method]))}</span>` : '';
                const unread = !active && a.unread > 0 ? `<span class="acct-unread">${a.unread > 99 ? '99+' : a.unread}</span>` : '';
                const check = active ? `<span class="acct-check" title="${esc(this._ac('Active identity'))}">${CHECK}</span>` : '';
                const canNotify = a.pubkey && a.method !== 'anonymous';
                const notify = canNotify ? `<div class="acct-notify"><label class="setting-toggle-row"><span class="form-label" id="acctNotifyLabel-${esc(a.id)}">${esc(this._ac("Notify me for this identity while it's not active"))}</span>`
                    + `<span class="nym-switch"><input type="checkbox" role="switch" id="acctNotify-${esc(a.id)}" data-panel-toggle="notifyInactive" data-on-change="acctNotify" data-acct-id="${esc(a.id)}" aria-labelledby="acctNotifyLabel-${esc(a.id)}" aria-describedby="acctNotifyHint-${esc(a.id)}"${a.notifyInactive ? ' checked' : ''}><span class="nym-switch-track" aria-hidden="true"><span class="nym-switch-thumb"></span></span></span></label>`
                    + `<div class="form-hint" id="acctNotifyHint-${esc(a.id)}">${esc(this._ac('This can let the server see that these identities share a device.'))}</div></div>` : '';
                const copy = copyable.has(a.id) ? `<button type="button" class="acct-row-btn" data-action="acctCopyNsec" data-acct-id="${esc(a.id)}">${esc(this._ac('Copy nsec'))}</button>` : '';
                return `<div class="acct-row${active ? ' is-active' : ''}" data-acct-row="${esc(a.id)}">`
                    + `<button type="button" class="acct-row-main" data-action="acctSwitch" data-acct-id="${esc(a.id)}"${active ? ' aria-current="true"' : ''}>${avatar}<span class="acct-name">${nameHtml}${badge}</span>${unread}${check}</button>`
                    + `<div class="acct-row-tools">${notify}<div class="acct-row-btns">${copy}<button type="button" class="acct-row-btn acct-danger" data-action="acctRemove" data-acct-id="${esc(a.id)}">${esc(this._ac('Remove'))}</button></div></div>`
                    + `</div>`;
            });
            list.innerHTML = rows.join('') || `<div class="form-hint">${esc(this._ac('No saved identities yet.'))}</div>`;
            const add = document.getElementById('acctAddBtn');
            if (add) {
                const full = idx.accounts.length >= A.MAX_ACCOUNTS;
                add.disabled = full;
                add.title = full ? this._ac('You can keep up to {n} identities on this device.', { n: A.MAX_ACCOUNTS }) : '';
            }
            const hint = document.getElementById('acctCapHint');
            if (hint) hint.textContent = this._ac('{n} of {max} identities on this device. Only the active identity stays connected.', { n: idx.accounts.length, max: A.MAX_ACCOUNTS });
            document.getElementById('accountSwitcherModal').classList.add('active');
            try { if (typeof this.closeSidebar === 'function' && window.innerWidth <= 768) this.closeSidebar(); } catch (_) { }
        },

        async _acctNsecFor(a) {
            const A = M();
            const names = a.method === 'nsec' ? ['nym_nostr_login_nsec'] : (a.method === 'ephemeral' ? ['nym_session_nsec'] : []);
            for (const n of names) {
                let v = null;
                if (a.id === A.pageId) { try { v = window.nymSecretGet(n); } catch (_) { v = null; } }
                else v = await A.stashKey(a.id, n);
                if (v && /^nsec1[0-9a-z]+$/.test(v)) return v;
            }
            return null;
        },

        async acctCopyNsec(id) {
            const a = M().read().accounts.find((x) => x.id === id);
            const nsec = a && await this._acctNsecFor(a);
            if (!nsec) return;
            try { await window.copySecretToClipboard(nsec); } catch (_) { }
            try { this.displaySystemMessage(this._ac('nsec copied. Store it somewhere safe.')); } catch (_) { }
        },

        async acctSwitch(id) {
            const A = M();
            if (id === A.pageId) { window.closeModal('accountSwitcherModal'); return; }
            let unread = 0;
            try { unread = typeof this._appBadgeCount === 'function' ? this._appBadgeCount() : 0; } catch (_) { unread = 0; }
            const r = A.plan(A.read(), { type: 'switch', id, unread });
            if (!r.ok) return;
            await this._acctGo(r);
        },

        async acctAdd() {
            const A = M();
            const r = A.plan(A.read(), { type: 'add', id: A.randomId(), now: Date.now() });
            if (!r.ok) {
                if (r.error === 'cap') await window.showAppAlert(this._ac('You can keep up to {n} identities on this device. Remove one to add another.', { n: A.MAX_ACCOUNTS }));
                return;
            }
            await this._acctGo(r);
        },

        async acctCancelAdd() {
            const A = M();
            const r = A.plan(A.read(), { type: 'cancelAdd' });
            if (r.ok) await this._acctGo(r);
        },

        _acctName(a) {
            return a.pubkey ? this._acctLabel(a) : this._ac('New identity');
        },

        _acctLanding(idx, id) {
            const r = M().plan(idx, { type: 'remove', id });
            const land = r.ok && r.index.active ? r.index.accounts.find((x) => x.id === r.index.active) : null;
            if (id !== idx.active) return land ? this._ac('You will stay on {nym}.', { nym: this._acctName(land) }) : '';
            return land ? this._ac('You will switch to {nym}.', { nym: this._acctName(land) }) : this._ac('You will return to the welcome screen.');
        },

        _acctRemoveMessage(a, landing) {
            const local = a.method === 'nsec' || a.method === 'ephemeral' || a.method === 'anonymous';
            const head = this._ac('Remove {nym} from this device? Its messages, settings and caches on this device are deleted.', { nym: this._acctName(a) });
            const keys = local
                ? this._ac('Its key is stored only on this device: back up the nsec first or you lose this identity.')
                : this._ac('Its key stays in your signer; you can add it again later.');
            return [head, keys, landing].filter(Boolean).join('\n\n');
        },

        async acctRemove(id) {
            const A = M();
            const idx = A.read();
            const a = idx.accounts.find((x) => x.id === id);
            if (!a) return;
            const ok = await window.showAppConfirm(this._acctRemoveMessage(a, this._acctLanding(idx, id)), { title: this._ac('Remove identity'), okLabel: this._ac('Remove'), danger: true });
            if (!ok) return;
            const r = A.plan(A.read(), { type: 'remove', id });
            await this._acctGo(r);
        },

        async acctLogout() {
            const A = M();
            const idx = A.read();
            const cur = A.activeOf(idx);
            if (!cur || cur.id !== A.pageId) return false;
            const msg = this._acctRemoveMessage(cur, this._acctLanding(idx, cur.id));
            const ok = await window.showAppConfirm(msg, { title: this._ac('Log out'), okLabel: this._ac('Log out'), danger: true });
            if (!ok) return true;
            await this._acctGo(A.plan(A.read(), { type: 'logout' }));
            return true;
        },

        acctForgetTarget() {
            if (!this.acctEnabled()) return null;
            const A = M();
            const idx = A.read();
            const cur = A.activeOf(idx);
            if (!cur || cur.id !== A.pageId) return null;
            const planned = A.plan(idx, { type: 'logout' });
            const next = planned.ok ? planned.index.accounts.find((a) => a.id === planned.index.active) : null;
            return { from: this._acctLabel(cur), to: next ? this._acctLabel(next) : '' };
        },

        async acctForget() {
            if (!this.acctForgetTarget()) return false;
            const A = M();
            const r = A.plan(A.read(), { type: 'logout' });
            if (!r.ok) return false;
            return await this._acctGo(r);
        },

        async acctLogoutAll() {
            const A = M();
            const idx = A.read();
            const n = idx.accounts.length;
            const welcome = this._ac('You will return to the welcome screen.');
            const msg = n === 1
                ? this._acctRemoveMessage(idx.accounts[0], welcome)
                : [this._ac('Log out of all {n} identities? Every identity and its data on this device is deleted. Back up any nsec you need first.', { n }), idx.accounts.map((a) => this._acctName(a)).join('\n'), welcome].filter(Boolean).join('\n\n');
            const ok = await window.showAppConfirm(msg, { title: this._ac('Log out of all identities'), okLabel: this._ac('Log out of all identities'), danger: true });
            if (!ok) return;
            await this._acctGo(A.plan(A.read(), { type: 'logoutAll' }));
        },

        async acctSetNotify(id, on) {
            const A = M();
            const idx = A.read();
            const r = A.plan(idx, { type: 'notify', id, on: !!on });
            if (!r.ok) return false;
            const res = await A.apply(r, idx);
            if (!res || !res.ok) { this._acctFail(res); return false; }
            if (on && typeof Notification !== 'undefined' && Notification.permission === 'default') {
                try { Notification.requestPermission(); } catch (_) { }
            }
            this._acctSyncWatchers();
            return true;
        },

        _acctSyncWatchers() {
            const A = M();
            if (!A || A.frozen) return;
            if (!this._acctWatchers) this._acctWatchers = new Map();
            const want = new Map();
            for (const a of A.read().accounts) {
                if (a.id !== A.pageId && a.notifyInactive && /^[0-9a-f]{64}$/.test(a.pubkey) && a.method !== 'anonymous') want.set(a.id, a);
            }
            for (const [id, w] of this._acctWatchers) {
                if (!want.has(id) || want.get(id).pubkey !== w.pubkey) { w.stop(); this._acctWatchers.delete(id); }
            }
            for (const [id, a] of want) {
                if (!this._acctWatchers.has(id)) this._acctWatchers.set(id, this._acctWatch(a));
            }
        },

        async _acctWatchRelay(a) {
            const RB = window.NymRelayBlock;
            if (!RB) return WATCH_RELAY;
            let blocked = [];
            try {
                const A = M();
                const vals = A && typeof A.stashKeys === 'function' ? await A.stashKeys(a.id, ['nym_blocked_relays']) : null;
                const raw = vals && vals.nym_blocked_relays != null ? String(vals.nym_blocked_relays) : '';
                if (raw) blocked = RB.list(RB.norm(JSON.parse(raw), Date.now()));
            } catch (_) { blocked = []; }
            const writeOnly = this.writeOnlyRelays instanceof Set ? this.writeOnlyRelays : new Set();
            const others = (this.defaultRelays || []).filter((u) => u !== WATCH_RELAY && u !== this.appRelay && !writeOnly.has(u));
            return RB.usable([WATCH_RELAY, ...others], blocked)[0] || WATCH_RELAY;
        },

        _acctWatch(a) {
            const w = { pubkey: a.pubkey, ws: null, stopped: false, seen: new Set(), timer: null };
            const open = async () => {
                if (w.stopped) return;
                const relay = await this._acctWatchRelay(a);
                if (w.stopped) return;
                let url = relay;
                try { if (typeof this._getProxiedRelayUrl === 'function') url = this._getProxiedRelayUrl(relay); } catch (_) { }
                let ws;
                try { ws = new WebSocket(url); } catch (_) { w.timer = setTimeout(open, this._acctWatchDelay(false)); return; }
                w.ws = ws;
                const sub = 'n' + M().randomId();
                let live = false;
                ws.onopen = () => {
                    try { ws.send(JSON.stringify(['REQ', sub, { kinds: [1059], '#p': [a.pubkey], since: Math.floor(Date.now() / 1000) - 3 * 86400 }])); } catch (_) { }
                };
                ws.onmessage = (ev) => {
                    let m;
                    try { m = JSON.parse(ev.data); } catch (_) { return; }
                    if (!Array.isArray(m) || m[1] !== sub) return;
                    if (m[0] === 'EOSE') { live = true; return; }
                    if (m[0] !== 'EVENT' || !m[2] || typeof m[2].id !== 'string') return;
                    const ptag = (m[2].tags || []).find((t) => t[0] === 'p');
                    if (m[2].kind !== 1059 || !ptag || ptag[1] !== a.pubkey) return;
                    if (w.seen.has(m[2].id)) return;
                    w.seen.add(m[2].id);
                    if (live) this._acctBump(a.id);
                };
                ws.onclose = () => { w.ws = null; if (!w.stopped) w.timer = setTimeout(open, this._acctWatchDelay(false)); };
                ws.onerror = () => { };
            };
            w.stop = () => {
                w.stopped = true;
                if (w.timer) clearTimeout(w.timer);
                try { if (w.ws) w.ws.close(); } catch (_) { }
            };
            w.timer = setTimeout(open, this._acctWatchDelay(true));
            return w;
        },

        _acctWatchDelay(first) {
            return first ? 1000 + Math.floor(Math.random() * 11000) : 30000 + Math.floor(Math.random() * 30000);
        },

        async _acctBump(id) {
            const A = M();
            const next = A.update((idx) => {
                const a = idx.accounts.find((x) => x.id === id);
                if (!a || !a.notifyInactive) return null;
                a.unread = (a.unread || 0) + 1;
                return idx;
            });
            if (!next) return;
            const a = next.accounts.find((x) => x.id === id);
            this._acctRenderButton();
            if (document.getElementById('accountSwitcherModal')?.classList.contains('active')) this.openAccountSwitcher();
            try {
                if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
                let active = null;
                try { active = localStorage.getItem('nym_hide_previews'); } catch (_) { }
                let target = null;
                try {
                    const vals = typeof A.stashKeys === 'function' ? await A.stashKeys(id, ['nym_hide_previews']) : null;
                    target = vals && vals.nym_hide_previews != null ? String(vals.nym_hide_previews) : null;
                } catch (_) { }
                const notice = A.inactiveNotice(id, this._acctLabel(a), active, target);
                const body = notice.nym == null ? this._ac(notice.text) : this._ac(notice.text, { nym: notice.nym });
                const n = new Notification('Nymchat', { body, tag: 'nym-acct-' + notice.group });
                n.onclick = () => { try { window.focus(); } catch (_) { } this.acctSwitch(id); };
            } catch (_) { }
        },

        async acctExtensionMismatch(expected) {
            const A = M();
            const others = A.read().accounts.filter((a) => a.id !== A.pageId && a.pubkey);
            if (window.NymSuffix) window.NymSuffix.remember(String(expected || ''));
            const msg = this._ac('Your browser extension is signed in with a different key than {nym}. Switch the extension to that key and reload, or pick another identity. Nothing was sent.', { nym: (this.nym || 'nym') + '#' + String(expected || '').slice(-4) });
            const reload = await window.showAppConfirm(msg, { title: this._ac('Different key in extension'), okLabel: this._ac('Reload'), cancelLabel: others.length ? this._ac('Switch identity') : this._ac('Cancel') });
            if (reload) { location.reload(); return; }
            if (others.length) this.openAccountSwitcher();
        }
    });
})();
