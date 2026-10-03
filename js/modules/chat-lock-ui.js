(function () {
    const L = () => window.NymChatLock;
    const ICON_LOCK = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2"></rect><path d="M8 11V7a4 4 0 0 1 8 0v4"></path></svg>';
    const ICON_UNLOCK = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2"></rect><path d="M8 11V7a4 4 0 0 1 7.5-2"></path></svg>';
    const MESSAGE_INPUTS = '#messageInput, #pmInitialMessage, #callChatInput, .message-input';

    Object.assign(NYM.prototype, {
        _cl(text, vars) {
            let s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _clNotice(text) {
            if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(text);
        },

        _clGet(k) {
            try { return localStorage.getItem(k); } catch (_) { return null; }
        },

        _clSet(k, v) {
            try {
                if (v === null || v === undefined) localStorage.removeItem(k);
                else localStorage.setItem(k, String(v));
            } catch (_) { }
        },

        _clStorageKey() {
            return L().KEYS.locked + ':' + (this.pubkey || 'anon');
        },

        _clPendingKey() {
            return L().KEYS.lockedPending + ':' + (this.pubkey || 'anon');
        },

        _clState() {
            if (this._clCache && this._clCache.pk === this.pubkey) return this._clCache.state;
            let state = L().emptyLocks();
            try {
                const raw = this._clGet(this._clStorageKey());
                if (raw) state = L().normalizeLocks(JSON.parse(raw));
            } catch (_) { state = L().emptyLocks(); }
            this._clCache = { pk: this.pubkey, state };
            return state;
        },

        _clPersist(state) {
            this._clCache = { pk: this.pubkey, state };
            this._clSet(this._clStorageKey(), JSON.stringify(state));
        },

        _clPending() {
            return this._clGet(this._clPendingKey()) === '1';
        },

        _clSetPending(on) {
            this._clSet(this._clPendingKey(), on ? '1' : null);
        },

        _clSyncAllowed() {
            return typeof this.savedMode !== 'function' || this.savedMode() === 'sync';
        },

        lockedChatKeys() {
            return L().lockList(this._clState());
        },

        isChatLocked(lockKey) {
            return L().isLocked(this._clState(), lockKey);
        },

        isConversationLocked(chatKey) {
            return L().isLocked(this._clState(), L().lockKeyForChat(chatKey, this.pubkey));
        },

        _clLockKeyForItem(itemEl) {
            if (!itemEl || !itemEl.dataset) return '';
            if (itemEl.classList && itemEl.classList.contains('channel-item')) return L().lockKey('channel', itemEl.dataset.geohash || itemEl.dataset.channel);
            if (itemEl.dataset.groupId) return L().lockKey('group', itemEl.dataset.groupId);
            if (itemEl.dataset.pubkey) return L().lockKey('dm', itemEl.dataset.pubkey);
            return '';
        },

        _clChatKeyFor(lockKey) {
            const p = L().lockParse(lockKey);
            if (!p) return '';
            if (p.kind === 'dm') return typeof this.getPMConversationKey === 'function' ? this.getPMConversationKey(p.id) : 'pm-' + p.id;
            if (p.kind === 'group') return typeof this.getGroupConversationKey === 'function' ? this.getGroupConversationKey(p.id) : 'group-' + p.id;
            return this._clIsGeohash(p.id) ? '#' + p.id : p.id;
        },

        _clIsGeohash(id) {
            if (typeof this.isValidGeohash === 'function') {
                try { return !!this.isValidGeohash(id); } catch (_) { return false; }
            }
            return false;
        },

        _clCurrentKey() {
            if (typeof this._cnSingleKey === 'function') {
                try { return this._cnSingleKey(); } catch (_) { return null; }
            }
            return null;
        },

        async toggleLockChat(lockKey) {
            const C = L();
            if (!C.lockParse(lockKey)) return false;
            if (lockKey === 'c:nymchat') {
                this._clNotice(this._cl(C.STRINGS.defaultLocked));
                return false;
            }
            const ok = await this.chatLockAuthenticate();
            if (!ok) return false;
            const now = Date.now();
            let state = this._clState();
            if (C.isLocked(state, lockKey)) {
                state = C.lockRemove(state, lockKey, now);
                this._clCommit(state);
                this._clNotice(this._cl(C.STRINGS.unlocked));
                return true;
            }
            const r = C.lockAdd(state, lockKey, now);
            if (r.error === 'cap') {
                this._clNotice(this._cl(C.STRINGS.lockCap, { n: C.LIMITS.lockMax }));
                return false;
            }
            if (r.error) return false;
            this._clSessionEvent({ t: 'unlock', now });
            this._clCommit(r.state);
            this._clRedactHistory();
            this._clNotice(this._cl(C.STRINGS.locked));
            return true;
        },

        _clCommit(state) {
            this._clPersist(state);
            this._clRev = (this._clRev || 0) + 1;
            this._clSetPending(this._clSyncAllowed());
            this._clApply();
            this._clSync();
        },

        _clApply() {
            this._clMarkRows();
            this._clRenderEntry();
            if (typeof this._updateNotificationBadge === 'function') {
                try { this._updateNotificationBadge(); } catch (_) { }
            }
            this._clRenderLockedModal();
            this._clUpdateShield();
        },

        async _clSync() {
            if (!this._clSyncAllowed()) return 'local';
            if (!this._clPending()) return 'synced';
            const online = typeof this._ctOnline === 'function' ? this._ctOnline() : !!this.connected;
            if (!this.pubkey || !online || !this._settingsHydrated) return 'pending';
            if (this._clSyncing) { this._clResync = true; return 'pending'; }
            this._clSyncing = true;
            this._clResync = false;
            const rev = this._clRev || 0;
            let ok = false;
            try {
                const dTag = L().KEYS.lockedDTag;
                const payload = { lockedChats: JSON.parse(JSON.stringify(this._clState())) };
                if (!this._publishedSectionJson) this._publishedSectionJson = {};
                ok = this._publishedSectionJson[dTag] === JSON.stringify(payload);
                if (!ok && typeof this._publishCategoryWrap === 'function') {
                    const now = Math.floor(Date.now() / 1000);
                    const changed = await this._publishCategoryWrap(payload, dTag, now, [L().trimLockedPayload]);
                    ok = !!changed || this._publishedSectionJson[dTag] === JSON.stringify(payload);
                    if (changed && typeof this._publishSettingsChangedPing === 'function') {
                        await this._publishSettingsChangedPing(['locked'], now);
                    }
                }
            } catch (_) {
                ok = false;
            } finally {
                this._clSyncing = false;
            }
            if (ok && rev === (this._clRev || 0)) this._clSetPending(false);
            if (this._clResync || (ok && rev !== (this._clRev || 0))) {
                this._clResync = false;
                return this._clSync();
            }
            return this._clPending() ? 'pending' : 'synced';
        },

        applySyncedLocked(remote) {
            if (!remote || typeof remote !== 'object') return;
            const C = L();
            const merged = C.mergeLocks(this._clState(), remote, Date.now());
            const remoteNorm = C.mergeLocks(remote, null, Date.now());
            this._clPersist(merged);
            this._clRev = (this._clRev || 0) + 1;
            if (JSON.stringify(merged) !== JSON.stringify(remoteNorm) && this._clSyncAllowed()) {
                this._clSetPending(true);
                setTimeout(() => { this._clSync(); }, 0);
            }
            this._clApply();
            this._clRedactHistory();
            const cur = this._clCurrentKey();
            if (cur && this._clBlocks(cur)) this._clLeaveLocked();
        },

        chatLockRelockMinutes() {
            return L().normalizeRelock(this._clGet(L().KEYS.relock));
        },

        setChatLockRelockMinutes(n) {
            this._clSet(L().KEYS.relock, L().normalizeRelock(n));
        },

        screenSecurityEnabled() {
            return this._clGet(L().KEYS.screenSecurity) === '1';
        },

        setScreenSecurity(on) {
            this._clSet(L().KEYS.screenSecurity, on ? '1' : null);
            this._clUpdateShield();
        },

        incognitoKeyboardEnabled() {
            return this._clGet(L().KEYS.incognitoKeyboard) === '1';
        },

        setIncognitoKeyboard(on) {
            this._clSet(L().KEYS.incognitoKeyboard, on ? '1' : null);
            this._clApplyIncognito();
        },

        _clSessionState() {
            if (!this._clSession) this._clSession = L().sessionIdle();
            return this._clSession;
        },

        chatLockUnlocked() {
            return !!this._clSessionState().unlocked;
        },

        _clSessionEvent(ev) {
            const before = this._clSessionState();
            const next = L().sessionStep(before, Object.assign({ relock: this.chatLockRelockMinutes() }, ev));
            this._clSession = next;
            if (before.unlocked && !next.unlocked) this._clOnRelock(ev && ev.t);
            this._clUpdateShield();
            return next;
        },

        lockChatsNow() {
            this._clSessionEvent({ t: 'lock' });
        },

        _clOnRelock(reason) {
            if (this._ctCloseModal) this._ctCloseModal('lockedChatsModal');
            if (reason !== 'leave') this._clLeaveLocked();
        },

        _clLeaveLocked() {
            if (this._cvActive && Array.isArray(this._cvColumns) && typeof this.cvRemoveColumn === 'function') {
                for (const col of this._cvColumns.slice()) {
                    if (col && col.key && this._clBlocks(col.key)) {
                        try { this.cvRemoveColumn(col.id); } catch (_) { }
                    }
                }
            }
            const cur = this._clCurrentKey();
            if (cur && this._clBlocks(cur) && typeof this.switchChannel === 'function') {
                this._clBypass = true;
                try { this.switchChannel('nymchat', 'nymchat'); } catch (_) { } finally { this._clBypass = false; }
            }
        },

        _clBlocks(chatKey) {
            if (!chatKey) return false;
            return !L().sessionAllows(this._clSessionState(), this._clState(), chatKey, this.pubkey);
        },

        _clBeforeOpen(nextKey, go) {
            if (this._clBypass || !nextKey) return true;
            if (this._clBlocks(nextKey)) {
                if (!this._clCurrentKey() && !this._clStarted && nextKey !== 'nymchat') {
                    setTimeout(() => {
                        this._clBypass = true;
                        try { this.switchChannel('nymchat', 'nymchat'); } catch (_) { } finally { this._clBypass = false; }
                    }, 0);
                    return false;
                }
                if (this._clAuthing) return false;
                this._clAuthing = true;
                Promise.resolve(this.chatLockAuthenticate()).then((ok) => {
                    this._clAuthing = false;
                    if (!ok) return;
                    this._clSessionEvent({ t: 'unlock', now: Date.now() });
                    this._clBypass = true;
                    try { go(); } finally { this._clBypass = false; }
                }, () => { this._clAuthing = false; });
                return false;
            }
            const prev = this._clCurrentKey();
            const modalOpen = typeof document !== 'undefined' && !!document.querySelector('#lockedChatsModal.active');
            if (prev && !modalOpen && !this._cvActive && L().leavesLocked(this._clState(), prev, nextKey, this.pubkey)) {
                this._clSessionEvent({ t: 'leave' });
            }
            return true;
        },

        _clAfterOpen() {
            this._clUpdateShield();
            this._clApplyIncognito();
        },

        _clVaultMethod() {
            try {
                if (typeof this.vaultEnabled === 'function' && this.vaultEnabled()) return typeof this.vaultMethod === 'function' ? this.vaultMethod() : 'password';
            } catch (_) { }
            return '';
        },

        _clPasscodeRecord() {
            try {
                const raw = this._clGet(L().KEYS.passcode);
                const rec = raw ? JSON.parse(raw) : null;
                return rec && rec.salt && rec.hash ? rec : null;
            } catch (_) { return null; }
        },

        async _clDeviceAvailable() {
            const vault = this._clVaultMethod();
            if (typeof this._vaultIsWebAuthn === 'function' && this._vaultIsWebAuthn(vault)) return true;
            if (typeof this.biometricAvailable === 'function') {
                try { return !!(await this.biometricAvailable()); } catch (_) { return false; }
            }
            return false;
        },

        async _clFactorOpts() {
            const vault = this._clVaultMethod();
            return { device: await this._clDeviceAvailable(), vault: vault === 'password' ? 'password' : vault, passcode: !!this._clPasscodeRecord() };
        },

        async chatLockAuthenticate() {
            if (typeof window !== 'undefined' && typeof window.nymChatLockAuthOverride === 'function') {
                try { return !!(await window.nymChatLockAuthOverride()); } catch (_) { return false; }
            }
            const C = L();
            const opts = await this._clFactorOpts();
            const factor = C.unlockFactor(opts);
            if (factor === 'device') {
                const r = await this._clDeviceAuth();
                if (r === true) return true;
                const fb = C.fallbackFactor(opts);
                if (fb) return this._clPasscodeFlow(fb, true);
                if (r === false) await this._clAlert(this._cl(C.STRINGS.deviceFailed));
                return false;
            }
            if (factor === 'setup') return this._clSetupPasscode();
            return this._clPasscodeFlow(factor, false);
        },

        async _clDeviceAuth() {
            const vault = this._clVaultMethod();
            try {
                if (typeof this._vaultIsWebAuthn === 'function' && this._vaultIsWebAuthn(vault) && typeof this.testVaultUnlock === 'function') {
                    return !!(await this.testVaultUnlock());
                }
                return await this._clWebAuthnAssert();
            } catch (e) {
                return e && e.name === 'NotAllowedError' ? null : false;
            }
        },

        async _clWebAuthnAssert() {
            const C = L();
            if (typeof navigator === 'undefined' || !navigator.credentials || typeof navigator.credentials.get !== 'function') return false;
            const rpId = typeof this._webauthnRpId === 'function' ? this._webauthnRpId() : location.hostname;
            let credId = this._clGet(C.KEYS.credential);
            if (!credId) {
                const cred = await navigator.credentials.create({ publicKey: {
                    challenge: crypto.getRandomValues(new Uint8Array(32)),
                    rp: { name: 'Nymchat', id: rpId },
                    user: { id: crypto.getRandomValues(new Uint8Array(16)), name: 'nym-chat-lock', displayName: 'Nymchat chat lock' },
                    pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
                    authenticatorSelection: { authenticatorAttachment: 'platform', userVerification: 'required', residentKey: 'discouraged' },
                    timeout: 60000,
                } });
                if (!cred || !cred.rawId) return false;
                credId = C.b64(new Uint8Array(cred.rawId));
                this._clSet(C.KEYS.credential, credId);
                return true;
            }
            const assertion = await navigator.credentials.get({ publicKey: {
                challenge: crypto.getRandomValues(new Uint8Array(32)),
                rpId,
                allowCredentials: [{ id: C.b64d(credId), type: 'public-key' }],
                userVerification: 'required',
                timeout: 60000,
            } });
            if (!assertion) return false;
            const flags = assertion.response && assertion.response.authenticatorData ? new Uint8Array(assertion.response.authenticatorData)[32] : 4;
            return (flags & 4) === 4;
        },

        _clAlert(text) {
            if (typeof window !== 'undefined' && typeof window.showAppAlert === 'function') return window.showAppAlert(text);
            return Promise.resolve();
        },

        _clAttempts() {
            try { return JSON.parse(this._clGet(L().KEYS.attempts) || 'null') || L().attemptsIdle(); } catch (_) { return L().attemptsIdle(); }
        },

        async _clVerifyCode(factor, code) {
            if (factor === 'vaultPasscode') return typeof this._verifyPassword === 'function' ? !!(await this._verifyPassword(code)) : false;
            return L().passcodeVerify(this._clPasscodeRecord(), code);
        },

        async _clPasscodeFlow(factor, afterDevice) {
            const C = L();
            let error = '';
            for (let guard = 0; guard < 50; guard++) {
                const wait = C.attemptWait(this._clAttempts(), Date.now());
                if (wait > 0) error = this._cl(C.STRINGS.passcodeWait, { n: wait });
                const res = await this._clPromptModal({
                    title: this._cl(C.STRINGS.unlockTitle),
                    body: this._cl(factor === 'vaultPasscode' ? C.STRINGS.unlockVaultBody : C.STRINGS.unlockPasscodeBody),
                    fields: [{ id: 'clCode', label: this._cl(C.STRINGS.passcode) }],
                    ok: this._cl(C.STRINGS.unlock),
                    alt: afterDevice ? this._cl(C.STRINGS.useDevice) : '',
                    error,
                });
                if (!res) return false;
                if (res.alt) {
                    const r = await this._clDeviceAuth();
                    if (r === true) return true;
                    error = this._cl(C.STRINGS.deviceFailed);
                    continue;
                }
                if (C.attemptWait(this._clAttempts(), Date.now()) > 0) continue;
                const ok = await this._clVerifyCode(factor, res.values.clCode || '');
                const next = C.attemptStep(this._clAttempts(), ok, Date.now());
                this._clSet(C.KEYS.attempts, ok ? null : JSON.stringify(next));
                if (ok) return true;
                error = this._cl(C.STRINGS.passcodeWrong);
            }
            return false;
        },

        async _clSetupPasscode() {
            const C = L();
            let error = '';
            for (let guard = 0; guard < 50; guard++) {
                const res = await this._clPromptModal({
                    title: this._cl(C.STRINGS.setupTitle),
                    body: this._cl(C.STRINGS.setupBody),
                    fields: [{ id: 'clNew', label: this._cl(C.STRINGS.passcode) }, { id: 'clConfirm', label: this._cl(C.STRINGS.passcodeConfirm) }],
                    ok: this._cl(C.STRINGS.unlock),
                    error,
                });
                if (!res) return false;
                const code = res.values.clNew || '';
                const bad = C.passcodeCheck(code, res.values.clConfirm || '');
                if (bad) { error = C.passcodeError(bad, (s) => this._cl(s)); continue; }
                const rec = await C.passcodeRecord(code);
                this._clSet(C.KEYS.passcode, JSON.stringify(rec));
                return true;
            }
            return false;
        },

        _clPromptModal(o) {
            return new Promise((resolve) => {
                if (typeof document === 'undefined') { resolve(null); return; }
                const ov = document.createElement('div');
                ov.className = 'modal active nm-vault-overlay cl-overlay';
                ov.id = 'clPromptModal';
                const box = document.createElement('div');
                box.className = 'modal-content nm-vault-box';
                const esc = (s) => this.escapeHtml ? this.escapeHtml(String(s)) : String(s);
                box.innerHTML = `<div class="modal-header">${esc(o.title)}</div>
                    <div class="modal-body"><p class="form-hint nm-vault-text">${esc(o.body)}</p>
                    ${o.fields.map((f) => `<div class="form-group"><input id="${f.id}" type="password" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="${esc(f.label)}" aria-label="${esc(f.label)}" class="form-input"></div>`).join('')}
                    <p class="form-hint cl-error" role="alert">${esc(o.error || '')}</p></div>
                    <div class="modal-actions">
                    <button type="button" class="icon-btn" data-cl="cancel">${esc(this._cl('Cancel'))}</button>
                    ${o.alt ? `<button type="button" class="icon-btn" data-cl="alt">${esc(o.alt)}</button>` : ''}
                    <button type="button" class="send-btn" data-cl="ok">${esc(o.ok)}</button></div>`;
                ov.appendChild(box);
                document.body.appendChild(ov);
                const done = (v) => { try { ov.remove(); } catch (_) { } resolve(v); };
                const values = () => {
                    const out = {};
                    for (const f of o.fields) { const el = box.querySelector('#' + f.id); out[f.id] = el ? el.value : ''; }
                    return out;
                };
                box.querySelector('[data-cl="cancel"]').onclick = () => done(null);
                box.querySelector('[data-cl="ok"]').onclick = () => done({ values: values() });
                const alt = box.querySelector('[data-cl="alt"]');
                if (alt) alt.onclick = () => done({ alt: true, values: {} });
                const inputs = box.querySelectorAll('input');
                inputs.forEach((el) => { el.onkeydown = (e) => { if (e.key === 'Enter') done({ values: values() }); else if (e.key === 'Escape') done(null); }; });
                if (inputs[0]) inputs[0].focus();
            });
        },

        _clUnreadEntries() {
            const out = [];
            if (this.unreadCounts && typeof this.unreadCounts.forEach === 'function') {
                this.unreadCounts.forEach((n, key) => { out.push({ key, n }); });
            }
            return out;
        },

        chatLockBadges() {
            return L().badges(this._clUnreadEntries(), this._clState(), this.pubkey, !!this._clRevealed);
        },

        _clEnsureEntry() {
            if (typeof document === 'undefined') return null;
            let el = document.getElementById('lockedChatsEntry');
            if (el) return el;
            const list = document.getElementById('pmList');
            const section = list && list.parentElement;
            const title = section && section.querySelector('.nav-title');
            if (!title) return null;
            el = document.createElement('span');
            el.id = 'lockedChatsEntry';
            el.className = 'search-icon cl-entry nm-hidden';
            el.dataset.action = 'openLockedChats';
            el.title = this._cl(L().STRINGS.lockedChats);
            el.setAttribute('aria-label', this._cl(L().STRINGS.lockedChats));
            el.setAttribute('role', 'button');
            el.innerHTML = ICON_LOCK + '<span class="cl-entry-badge nm-hidden"></span>';
            const anchor = title.querySelector('.new-pm-btn');
            if (anchor) title.insertBefore(el, anchor);
            else title.appendChild(el);
            return el;
        },

        _clRenderEntrySoon() {
            if (this._clRenderTimer) return;
            this._clRenderTimer = setTimeout(() => {
                this._clRenderTimer = null;
                try { this._clRenderEntry(); } catch (_) { }
            }, 60);
        },

        _clRenderEntry() {
            const el = this._clEnsureEntry();
            if (!el) return;
            const show = L().entryVisible(this._clState(), !!this._clRevealed);
            el.classList.toggle('nm-hidden', !show);
            const badge = el.querySelector('.cl-entry-badge');
            if (!show) {
                if (badge) badge.classList.add('nm-hidden');
                return;
            }
            const b = this.chatLockBadges();
            if (badge) {
                badge.textContent = b.shown > 99 ? '99+' : String(b.shown);
                badge.classList.toggle('nm-hidden', !(show && b.shown > 0));
            }
        },

        async openLockedChats() {
            if (!this.chatLockUnlocked()) {
                const ok = await this.chatLockAuthenticate();
                if (!ok) return false;
                this._clSessionEvent({ t: 'unlock', now: Date.now() });
            }
            this._clRevealed = true;
            this._ctModal('lockedChatsModal', this._cl(L().STRINGS.lockedChats));
            const modal = document.getElementById('lockedChatsModal');
            if (modal && !modal._clBound) {
                modal._clBound = true;
                const obs = new MutationObserver(() => {
                    if (!modal.classList.contains('active')) this._clOnLockedModalClosed();
                });
                obs.observe(modal, { attributes: true, attributeFilter: ['class'] });
            }
            this._clRenderLockedModal();
            this._clRenderEntry();
            this._clUpdateShield();
            return true;
        },

        _clOnLockedModalClosed() {
            if (this._clOpeningFromModal) return;
            this._clRevealed = false;
            this._clRenderEntry();
            const cur = this._clCurrentKey();
            if (!cur || !this.isConversationLocked(cur)) this._clSessionEvent({ t: 'leave' });
            this._clUpdateShield();
        },

        _clChatLabel(lockKey) {
            const p = L().lockParse(lockKey);
            if (!p) return lockKey;
            if (p.kind === 'dm') {
                const nym = typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(p.id) : '';
                const suffix = typeof this.getPubkeySuffix === 'function' ? this.getPubkeySuffix(p.id) : p.id.slice(-4);
                return (this.parseNymFromDisplay ? this.parseNymFromDisplay(nym || '') : nym) + '#' + suffix;
            }
            if (p.kind === 'group') {
                const g = this.groupConversations && this.groupConversations.get(p.id);
                return (g && g.name) || this._cl('Group');
            }
            return '#' + p.id;
        },

        _clChatUnread(lockKey) {
            const k = this._clChatKeyFor(lockKey);
            const p = L().lockParse(lockKey);
            if (!this.unreadCounts || !p) return 0;
            const alt = p.kind === 'channel' ? (k.charAt(0) === '#' ? p.id : '#' + p.id) : '';
            return Math.max(this.unreadCounts.get(k) || 0, alt ? (this.unreadCounts.get(alt) || 0) : 0);
        },

        _clOpenLocked(lockKey) {
            const p = L().lockParse(lockKey);
            if (!p) return;
            if (!this.chatLockUnlocked()) { this.openLockedChats(); return; }
            this._clOpeningFromModal = true;
            try {
                if (this._ctCloseModal) this._ctCloseModal('lockedChatsModal');
                if (p.kind === 'dm') this.openPM(typeof this.getNymFromPubkey === 'function' ? this.getNymFromPubkey(p.id) : '', p.id);
                else if (p.kind === 'group') this.openGroup(p.id);
                else this.switchChannel(p.id, this._clIsGeohash(p.id) ? p.id : '');
            } finally {
                this._clOpeningFromModal = false;
            }
            this._clRevealed = false;
            this._clRenderEntry();
            this._clUpdateShield();
        },

        _clRenderLockedModal() {
            const modal = typeof document !== 'undefined' ? document.getElementById('lockedChatsModal') : null;
            if (!modal || !modal.classList.contains('active')) return;
            const body = modal.querySelector('.ct-modal-body');
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const keys = this.lockedChatKeys();
            const rows = keys.map((k) => {
                const n = this._clChatUnread(k);
                return `<div class="cl-row" data-cl-key="${esc(k)}">
                    <button type="button" class="cl-row-open" data-action="clOpenLocked" data-cl-key="${esc(k)}">${ICON_LOCK}<span class="cl-row-name">${esc(this._clChatLabel(k))}</span>${n > 0 ? `<span class="cl-row-badge">${n > 99 ? '99+' : n}</span>` : ''}</button>
                    <button type="button" class="ct-btn" data-action="clRemoveLock" data-cl-key="${esc(k)}">${ICON_UNLOCK}${esc(this._cl(L().STRINGS.unlockChat))}</button>
                </div>`;
            }).join('');
            body.innerHTML = (rows || `<div class="ct-empty">${esc(this._cl(L().STRINGS.lockedEmpty))}</div>`) +
                `<div class="cl-footer"><button type="button" class="ct-btn" data-action="openChatLockSettings">${esc(this._cl(L().STRINGS.settingsButton))}</button>
                <button type="button" class="ct-btn" data-action="clLockNow">${esc(this._cl(L().STRINGS.lockNow))}</button></div>`;
        },

        _clMarkRows() {
            if (typeof document === 'undefined') return;
            const state = this._clState();
            if (!Object.keys(state.items || {}).length) {
                document.querySelectorAll('#pmList .cl-locked-row, #channelList .cl-locked-row').forEach((row) => row.classList.remove('cl-locked-row'));
                return;
            }
            document.querySelectorAll('#pmList .pm-item, #channelList .channel-item').forEach((row) => {
                const k = this._clLockKeyForItem(row);
                row.classList.toggle('cl-locked-row', !!k && L().isLocked(state, k));
            });
        },

        _clObserveLists() {
            if (typeof document === 'undefined' || typeof MutationObserver === 'undefined' || this._clObserved) return;
            const lists = ['pmList', 'channelList'].map((id) => document.getElementById(id)).filter(Boolean);
            if (!lists.length) return;
            this._clObserved = true;
            let queued = false;
            const obs = new MutationObserver(() => {
                if (queued) return;
                queued = true;
                Promise.resolve().then(() => { queued = false; this._clMarkRows(); this._clRenderEntrySoon(); });
            });
            for (const list of lists) obs.observe(list, { childList: true });
        },

        _clBindSearch() {
            if (typeof document === 'undefined' || this._clSearchBound) return;
            this._clSearchBound = true;
            document.addEventListener('input', (e) => {
                const t = e.target;
                if (!t || !t.classList || !t.classList.contains('search-input')) return;
                if (!L().secretMatches(this._clState(), t.value)) return;
                t.value = '';
                try { t.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true })); } catch (_) { }
                this.openLockedChats();
            }, true);
        },

        _clNotifRoute(info) {
            const i = info || {};
            if (i.type === 'pm') return ['pm', i.pubkey || '', i.pubkey || ''];
            if (i.type === 'group') return ['group', i.groupId || String(i.id || '').replace(/^group-/, ''), i.pubkey || ''];
            if (i.type === 'geohash' || i.type === 'channel') return ['channel', i.geohash || i.channel || '', i.pubkey || ''];
            if (i.type === 'reaction') {
                if (i.sourceType === 'pm') return ['pm', i.sourcePubkey || '', i.sourcePubkey || ''];
                if (i.sourceType === 'group') return ['group', i.sourceGroupId || '', ''];
                if (i.sourceType === 'geohash') return ['channel', i.sourceGeohash || i.sourceChannel || '', ''];
                return ['reaction', '', i.pubkey || ''];
            }
            if (i.type === 'call') return i.isGroup ? ['group', i.groupId || '', i.pubkey || ''] : ['pm', i.pubkey || '', i.pubkey || ''];
            return [String(i.type || ''), '', i.pubkey || ''];
        },

        _clNotifLocked(channelInfo) {
            if (!channelInfo) return false;
            const [type, route, sender] = this._clNotifRoute(channelInfo);
            const state = this._clState();
            return L().notificationLockKeys(type, route, sender).some((k) => L().isLocked(state, k));
        },

        _clRedactText() {
            return L().notificationText('', '', true, (s) => this._cl(s));
        },

        _clRedactHistory() {
            if (!Array.isArray(this.notificationHistory)) return;
            const r = this._clRedactText();
            let changed = false;
            for (const n of this.notificationHistory) {
                if (!n || n.locked || !this._clNotifLocked(n.channelInfo)) continue;
                n.title = r.title;
                n.body = r.body;
                n.senderNym = '';
                n.locked = true;
                changed = true;
            }
            if (changed && typeof this._saveNotificationHistory === 'function') {
                try { this._saveNotificationHistory(); } catch (_) { }
            }
        },

        _clNotifHidden(n) {
            return !!(n && (n.locked || this._clNotifLocked(n.channelInfo)));
        },

        _clShieldWanted() {
            const cur = this._clCurrentKey();
            const lockedOpen = (!!cur && this.isConversationLocked(cur)) || (typeof document !== 'undefined' && !!document.querySelector('#lockedChatsModal.active'));
            const viewOnce = typeof document !== 'undefined' && !!document.querySelector('.once-viewer');
            return L().obscureWanted({ setting: this.screenSecurityEnabled(), lockedOpen, viewOnce });
        },

        _clEnsureShield() {
            if (typeof document === 'undefined') return null;
            let el = document.getElementById('clShield');
            if (el) return el;
            el = document.createElement('div');
            el.id = 'clShield';
            el.className = 'cl-shield nm-hidden';
            el.setAttribute('aria-hidden', 'true');
            el.innerHTML = `<div class="cl-shield-inner">${ICON_LOCK}<span></span></div>`;
            el.querySelector('span').textContent = this._cl(L().STRINGS.hidden);
            document.body.appendChild(el);
            return el;
        },

        _clShieldEvent(ev) {
            if (ev === 'blur' && typeof document !== 'undefined' && document.activeElement && document.activeElement.tagName === 'IFRAME') return;
            this._clShielded = L().shieldStep(!!this._clShielded, ev, this._clShieldWanted());
            const el = this._clEnsureShield();
            if (el) el.classList.toggle('nm-hidden', !this._clShielded);
            if (typeof document !== 'undefined' && document.body) document.body.classList.toggle('cl-shielded', !!this._clShielded);
        },

        _clUpdateShield() {
            if (!this._clShieldWanted() && this._clShielded) this._clShieldEvent('focus');
        },

        _clBindShield() {
            if (typeof window === 'undefined' || typeof document === 'undefined' || this._clShieldBound) return;
            this._clShieldBound = true;
            document.addEventListener('visibilitychange', () => {
                this._clShieldEvent(document.hidden ? 'hidden' : 'visible');
                this._clSessionEvent({ t: document.hidden ? 'background' : 'foreground', now: Date.now() });
            });
            window.addEventListener('blur', () => this._clShieldEvent('blur'));
            window.addEventListener('focus', () => this._clShieldEvent('focus'));
            window.addEventListener('pagehide', () => this._clShieldEvent('pagehide'));
            window.addEventListener('pageshow', () => this._clShieldEvent('pageshow'));
            document.addEventListener('freeze', () => this._clShieldEvent('freeze'));
            document.addEventListener('resume', () => this._clShieldEvent('resume'));
        },

        _clApplyIncognito() {
            if (typeof document === 'undefined') return;
            const attrs = L().inputAttrs(this.incognitoKeyboardEnabled());
            const names = ['autocomplete', 'autocorrect', 'autocapitalize', 'spellcheck'];
            document.querySelectorAll(MESSAGE_INPUTS).forEach((el) => {
                for (const a of names) {
                    if (attrs[a] !== undefined) el.setAttribute(a, attrs[a]);
                    else el.removeAttribute(a);
                }
            });
        },

        _clPlatform() {
            return 'web';
        },

        _clRenderSettings() {
            if (typeof document === 'undefined') return;
            const C = L();
            const ss = document.getElementById('screenSecuritySelect');
            if (ss) ss.value = this.screenSecurityEnabled() ? 'on' : 'off';
            const ik = document.getElementById('incognitoKeyboardSelect');
            if (ik) ik.value = this.incognitoKeyboardEnabled() ? 'on' : 'off';
            const sh = document.getElementById('screenSecurityHint');
            if (sh) sh.textContent = this._cl(C.screenSecurityHint(this._clPlatform()));
            const ih = document.getElementById('incognitoKeyboardHint');
            if (ih) ih.textContent = this._cl(C.incognitoSupport(this._clPlatform()).hint);
        },

        async openChatLockSettings() {
            if (this.lockedChatKeys().length && !this.chatLockUnlocked()) {
                const ok = await this.chatLockAuthenticate();
                if (!ok) return false;
                this._clSessionEvent({ t: 'unlock', now: Date.now() });
            }
            this._ctModal('chatLockSettingsModal', this._cl(L().STRINGS.settingsTitle));
            this._clRenderLockSettings();
            return true;
        },

        _clRenderLockSettings() {
            const modal = typeof document !== 'undefined' ? document.getElementById('chatLockSettingsModal') : null;
            if (!modal || !modal.classList.contains('active')) return;
            const C = L();
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            const s = this._clState();
            const relock = this.chatLockRelockMinutes();
            const body = modal.querySelector('.ct-modal-body');
            body.innerHTML = `<p class="form-hint">${esc(this._cl(C.STRINGS.settingsHint))}</p>
                <div class="form-group"><label class="form-label">${esc(this._cl(C.STRINGS.relockAfter))}</label>
                <select class="form-select" id="clRelockSelect" data-on-change="clRelockChange">${C.relockOptions((x) => this._cl(x)).map((o) => `<option value="${o.value}"${o.value === relock ? ' selected' : ''}>${esc(o.label)}</option>`).join('')}</select></div>
                <div class="form-group"><label class="form-label cl-check"><input type="checkbox" id="clHideEntry"${s.hide.on ? ' checked' : ''}> ${esc(this._cl(C.STRINGS.hideEntry))}</label>
                <div class="form-hint">${esc(this._cl(C.STRINGS.hideEntryHint))}</div>
                <input type="password" class="form-input" id="clSecretCode" autocomplete="off" spellcheck="false" placeholder="${esc(this._cl(C.STRINGS.secretCode))}" aria-label="${esc(this._cl(C.STRINGS.secretCode))}" value="${esc(s.hide.code)}">
                <p class="form-hint cl-error" id="clSettingsError" role="alert"></p>
                <button type="button" class="ct-btn" data-action="clSaveHide">${esc(this._cl('Save'))}</button></div>
                ${this._clPasscodeRecord() ? `<div class="form-group"><button type="button" class="ct-btn" data-action="clChangePasscode">${esc(this._cl(C.STRINGS.resetPasscode))}</button></div>` : ''}
                <div class="form-group"><button type="button" class="ct-btn" data-action="clLockNow">${esc(this._cl(C.STRINGS.lockNow))}</button></div>`;
        },

        chatLockSaveHide(on, code) {
            const C = L();
            const r = C.setHidden(this._clState(), !!on, code, Date.now());
            if (r.error) return C.codeError((s) => this._cl(s));
            this._clCommit(r.state);
            return '';
        },

        async chatLockChangePasscode() {
            const ok = await this.chatLockAuthenticate();
            if (!ok) return false;
            this._clSet(L().KEYS.passcode, null);
            return this._clSetupPasscode();
        },

        _clStart() {
            if (this._clStarted) return;
            this._clStarted = true;
            this._clEnsureEntry();
            this._clObserveLists();
            this._clBindSearch();
            this._clBindShield();
            this._clMarkRows();
            this._clRenderEntry();
            this._clApplyIncognito();
            this._clRenderSettings();
            this._clRedactHistory();
            this._clLeaveLocked();
            setInterval(() => { try { if (this._clPending()) this._clSync(); } catch (_) { } }, 10000);
            if (typeof window !== 'undefined' && window.addEventListener) {
                window.addEventListener('online', () => setTimeout(() => { this._clSync(); }, 1500));
            }
        },
    });

    const gate = (name, keyOf) => {
        const orig = NYM.prototype[name];
        if (typeof orig !== 'function') return;
        NYM.prototype[name] = function () {
            const args = arguments;
            let key = null;
            try { key = keyOf.apply(this, args); } catch (_) { key = null; }
            let allowed = true;
            try { allowed = this._clBeforeOpen(key, () => NYM.prototype[name].apply(this, args)); } catch (_) { allowed = true; }
            if (!allowed) return undefined;
            const r = orig.apply(this, args);
            try { this._clAfterOpen(); } catch (_) { }
            return r;
        };
    };

    gate('switchChannel', function (channel, geohash) { return geohash ? `#${geohash}` : channel; });
    gate('openPM', function (_nym, pubkey) { return pubkey && pubkey !== this.pubkey ? this.getPMConversationKey(pubkey) : null; });
    gate('openGroup', function (groupId) { return groupId ? this.getGroupConversationKey(groupId) : null; });

    const origBadge = NYM.prototype._appBadgeCount;
    if (typeof origBadge === 'function') {
        NYM.prototype._appBadgeCount = function () {
            const total = origBadge.apply(this, arguments);
            let hidden = 0;
            try {
                if (!Object.keys(this._clState().items || {}).length) return Math.max(0, total);
                for (const e of this._clUnreadEntries()) {
                    const k = String(e.key || '');
                    if ((k.startsWith('pm-') || k.startsWith('group-')) && e.n > 0 && this.isConversationLocked(k)) hidden += e.n;
                }
            } catch (_) { hidden = 0; }
            return Math.max(0, total - hidden);
        };
    }

    const origUnread = NYM.prototype._unreadNotifications;
    if (typeof origUnread === 'function') {
        NYM.prototype._unreadNotifications = function () {
            const list = origUnread.apply(this, arguments) || [];
            if (!Object.keys(this._clState().items || {}).length) return list.filter((n) => !(n && n.locked));
            return list.filter((n) => !this._clNotifHidden(n));
        };
    }

    const origRender = NYM.prototype._renderUnreadBadge;
    if (typeof origRender === 'function') {
        NYM.prototype._renderUnreadBadge = function () {
            const r = origRender.apply(this, arguments);
            try { this._clRenderEntrySoon(); } catch (_) { }
            return r;
        };
    }

    const origMenu = NYM.prototype._buildSidebarMenuItems;
    if (typeof origMenu === 'function') {
        NYM.prototype._buildSidebarMenuItems = function (itemEl) {
            const base = origMenu.apply(this, arguments) || [];
            let k = '';
            try { k = this._clLockKeyForItem(itemEl); } catch (_) { k = ''; }
            if (!base.length || !k || k === 'c:nymchat') return base;
            const locked = this.isChatLocked(k);
            let at = base.length;
            try { if (typeof this._pinMenuItems === 'function') at = Math.min(base.length, this._pinMenuItems(itemEl).length); } catch (_) { at = base.length; }
            const out = base.slice();
            out.splice(at, 0, { label: this._cl(locked ? L().STRINGS.unlockChat : L().STRINGS.lockChat), svg: locked ? ICON_UNLOCK : ICON_LOCK, action: () => this.toggleLockChat(k) });
            return out;
        };
    }

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        const nym = () => window.nym;
        Object.assign(window.NYM_ACTIONS, {
            openLockedChats: function () { nym().openLockedChats(); },
            clOpenLocked: function (_e, t) { nym()._clOpenLocked(t.dataset.clKey); },
            clRemoveLock: function (_e, t) { nym().toggleLockChat(t.dataset.clKey); },
            clLockNow: function () {
                const n = nym();
                n._ctCloseModal('chatLockSettingsModal');
                n.lockChatsNow();
            },
            openChatLockSettings: function () { nym().openChatLockSettings(); },
            clRelockChange: function (_e, t) { nym().setChatLockRelockMinutes(parseInt(t.value, 10)); },
            clSaveHide: function () {
                const n = nym();
                const on = !!(document.getElementById('clHideEntry') || {}).checked;
                const code = (document.getElementById('clSecretCode') || {}).value || '';
                const err = n.chatLockSaveHide(on, code);
                const el = document.getElementById('clSettingsError');
                if (el) el.textContent = err;
            },
            clChangePasscode: function () { nym().chatLockChangePasscode(); },
            onScreenSecurityChange: function (_e, t) { nym().setScreenSecurity(t.value === 'on'); },
            onIncognitoKeyboardChange: function (_e, t) { nym().setIncognitoKeyboard(t.value === 'on'); },
        });
        let tries = 0;
        const boot = () => {
            const n = window.nym;
            if (n && n.pubkey && typeof n._clStart === 'function') n._clStart();
            else if (++tries < 120) setTimeout(boot, 1000);
        };
        setTimeout(boot, 1300);
    }
})();
