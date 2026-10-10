(function () {
    const R = () => window.NymRemotePanic;
    const NT = () => window.NostrTools;
    const ENABLED_KEY = 'nym_remote_panic';
    const CLEAR_KEY = 'nym_panic_clear_pending';
    const DELETED_NOTICE_KEY = 'nymnotice:deleted';
    const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    const nowSec = () => Math.floor(Date.now() / 1000);

    const STRINGS = {
        label: 'Panic wipe also erases my other devices',
        hint: 'When you hold "Your Nym" or the wordmark on the unlock screen for 2 seconds, every other device signed in as this identity also wipes this identity the next time it connects. Other identities on those devices are not touched. An encrypted identity that is still locked when you panic from the unlock screen can\'t send this signal.',
        confirmTitle: 'Erase other devices too?',
        confirm: 'A panic wipe will then also erase this identity from every device signed in as it, and that can\'t be undone. Messages protected by your post-quantum recovery code are lost forever if no device keeps it. Save your nsec and your nympq1… recovery code first.',
        confirmOk: 'Turn on',
        confirmBackup: 'Back up first',
    };

    Object.assign(NYM.prototype, {
        _rp(text) { return typeof this.uiText === 'function' ? this.uiText(text) : text; },

        remotePanicEnabled() {
            try { return localStorage.getItem(ENABLED_KEY) === '1'; } catch (_) { return false; }
        },

        _remotePanicStore(on) {
            try { localStorage.setItem(ENABLED_KEY, on ? '1' : '0'); } catch (_) { }
            this.remotePanicRender();
        },

        remotePanicApplySynced(value) {
            if (typeof value !== 'boolean') return;
            if (value === this.remotePanicEnabled()) return;
            this._remotePanicStore(value);
        },

        remotePanicRender() {
            if (typeof document === 'undefined') return;
            const sel = document.getElementById('remotePanicToggle');
            if (!sel) return;
            sel.checked = this.remotePanicEnabled();
            sel.disabled = !!this._remotePanicPending;
        },

        async setRemotePanic(on) {
            if (!on) {
                this._remotePanicStore(false);
                try { await this.saveSyncedSettings(); } catch (_) { }
                return true;
            }
            if (this.remotePanicEnabled()) return true;
            if (this._remotePanicPending) return false;
            this._remotePanicPending = true;
            this.remotePanicRender();
            let ok = false;
            try {
                ok = await window.showAppConfirm(this._rp(STRINGS.confirm), {
                    title: this._rp(STRINGS.confirmTitle),
                    okLabel: this._rp(STRINGS.confirmOk),
                    cancelLabel: this._rp(STRINGS.confirmBackup),
                    danger: true,
                });
            } catch (_) { ok = false; }
            this._remotePanicPending = false;
            if (!ok) {
                this.remotePanicRender();
                try {
                    const act = window.NYM_ACTIONS && window.NYM_ACTIONS.openKeyBackupDetails;
                    if (typeof act === 'function') act();
                } catch (_) { }
                return false;
            }
            this._remotePanicStore(true);
            try { await this.saveSyncedSettings(); } catch (_) { }
            return true;
        },

        remotePanicLoginAt() {
            try {
                const n = parseInt(localStorage.getItem(R().LOGIN_KEY) || '', 10);
                return Number.isInteger(n) && n > 0 ? n : null;
            } catch (_) { return null; }
        },

        remotePanicNoteLogin() {
            try {
                localStorage.setItem(R().LOGIN_KEY, String(nowSec()));
                localStorage.setItem(CLEAR_KEY, '1');
            } catch (_) { }
        },

        _remotePanicEnsureLogin() {
            if (this.remotePanicLoginAt()) return;
            try { localStorage.setItem(R().LOGIN_KEY, String(nowSec())); } catch (_) { }
        },

        async _remotePanicAuth(sign, pubkey, action, body, url) {
            const canonical = {};
            for (const k of Object.keys(body).filter((k) => k !== 'auth').sort()) canonical[k] = body[k];
            const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(canonical)));
            return sign({
                kind: 27235, created_at: nowSec(), pubkey,
                tags: [['domain', 'nymbot-pm'], ['method', 'POST'], ['u', url], ['action', action], ['payload', hex(new Uint8Array(digest))]],
                content: 'nymbot-pm-auth'
            });
        },

        async remotePanicSendMark(sign, pubkey, marker) {
            try {
                const apiHost = this._getApiHost && this._getApiHost();
                if (!apiHost) return false;
                const url = `https://${apiHost}/api/storage`;
                const body = { action: 'panic-mark', pubkey, at: marker.created_at, id: marker.id, sig: marker.sig };
                const auth = await this._remotePanicAuth(sign, pubkey, 'panic-mark', body, url);
                if (!auth || auth.pubkey !== pubkey) return false;
                body.auth = auth;
                const res = await this._edgeFetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body),
                    keepalive: true
                });
                return !!(res && res.ok);
            } catch (_) { return false; }
        },

        remotePanicWrap(secret, pubkey, marker) {
            const T = NT();
            const rumor = R().rumor(marker);
            rumor.id = T.getEventHash(rumor);
            const rumorJson = JSON.stringify(rumor);
            const seal = T.finalizeEvent({
                kind: 13, created_at: typeof this.randomNow === 'function' ? this.randomNow() : nowSec(), tags: [],
                content: T.nip44.encrypt(rumorJson, T.nip44.getConversationKey(secret, pubkey))
            }, secret);
            const eph = T.generateSecretKey();
            return T.finalizeEvent({
                kind: 1059, created_at: typeof this.randomNow === 'function' ? this.randomNow() : nowSec(),
                tags: [['p', pubkey], ['k', 'nym-sync']],
                content: T.nip44.encrypt(JSON.stringify(seal), T.nip44.getConversationKey(eph, pubkey))
            }, eph);
        },

        async remotePanicSignal(sign, pubkey, opts) {
            const o = opts || {};
            const none = { mark: false, wrap: false };
            if (!R().shouldSend(!!o.enabled, !!(sign && pubkey))) return none;
            let marker;
            try { marker = await sign({ ...R().template(nowSec(), !!o.deleted), pubkey }); } catch (_) { return none; }
            if (!R().markerValid(marker, pubkey, (ev) => NT().verifyEvent(ev))) return none;
            let wrap = false;
            if (o.secret) {
                try {
                    const ev = this.remotePanicWrap(o.secret, pubkey, marker);
                    this.sendDMToRelays(['EVENT', ev]);
                    wrap = true;
                } catch (_) { wrap = false; }
            }
            const mark = await this.remotePanicSendMark(sign, pubkey, marker);
            return { mark, wrap };
        },

        async _remotePanicAct(marker, source) {
            if (this._panicking || this._remotePanicWiping) return false;
            const pubkey = this.pubkey;
            if (!pubkey) return false;
            const verdict = R().decide({
                enabled: this.remotePanicEnabled(),
                loginAt: this.remotePanicLoginAt(),
                now: nowSec(),
                pubkey,
                marker
            }, (ev) => NT().verifyEvent(ev));
            if (verdict.action !== 'wipe') return false;
            this._remotePanicWiping = true;
            this._remotePanicSource = source;
            try { await this.remotePanicWipeHere(pubkey, { deleted: verdict.reason === 'deleted' }); } catch (_) { }
            return true;
        },

        async remotePanicCheck() {
            if (!this.pubkey || this._panicking || this._remotePanicWiping) return null;
            if (this._remotePanicChecking) return null;
            this._remotePanicChecking = true;
            try {
                this._remotePanicEnsureLogin();
                let pending = false;
                try { pending = localStorage.getItem(CLEAR_KEY) === '1'; } catch (_) { }
                if (pending) {
                    try {
                        await this._storageApiRequest('panic-clear', {});
                        try { localStorage.removeItem(CLEAR_KEY); } catch (_) { }
                    } catch (_) { }
                }
                const pubkey = this.pubkey;
                let data;
                try { data = await this._storageApiRequest('panic-check', {}); } catch (_) { return null; }
                if (this.pubkey !== pubkey) return null;
                const marker = R().fromRow(pubkey, data && data.mark);
                if (!marker) return null;
                return await this._remotePanicAct(marker, 'server');
            } finally {
                this._remotePanicChecking = false;
            }
        },

        onRemotePanicRumor(rumor) {
            const marker = R().markerFromRumor(rumor);
            if (!marker) return;
            this._remotePanicAct(marker, 'relay');
        },

        _deletedNoticeLabel(pubkey) {
            let nym = '';
            try {
                const A = window.NymAccounts;
                const a = A && typeof A.read === 'function' ? A.read().accounts.find((x) => x.pubkey === pubkey) : null;
                nym = (a && a.nym) || (pubkey === this.pubkey ? this.nym : '') || '';
            } catch (_) { nym = ''; }
            nym = String(nym || '');
            nym = typeof this.stripPubkeySuffix === 'function' ? this.stripPubkeySuffix(nym) : nym.replace(/#[0-9a-f]{4}$/i, '');
            return JSON.stringify({ nym: nym.trim(), suffix: String(pubkey || '').slice(-4) });
        },

        _deletedNoticeHtml(raw) {
            let info = null;
            try { info = JSON.parse(raw); } catch (_) { info = null; }
            const ui = (t) => (typeof this.uiText === 'function' ? this.uiText(t) : t);
            const esc = (t) => (typeof this.escapeHtml === 'function' ? this.escapeHtml(t) : String(t));
            if (!info || !info.nym) return esc(ui('This identity was deleted from another device.'));
            const label = esc(info.nym) + (info.suffix ? '<span class="nym-suffix">#' + esc(info.suffix) + '</span>' : '');
            return esc(ui('{nym} was deleted from another device.')).split('{nym}').join(label);
        },

        showDeletedNotice() {
            let raw = null;
            try { raw = localStorage.getItem(DELETED_NOTICE_KEY); } catch (_) { raw = null; }
            if (!raw) return false;
            try { localStorage.removeItem(DELETED_NOTICE_KEY); } catch (_) { }
            if (typeof this.showToast === 'function') this.showToast(this._deletedNoticeHtml(raw), { html: true });
            return true;
        },

        async remotePanicWipeHere(pubkey, opts) {
            const deleted = !!(opts && opts.deleted);
            const label = deleted ? this._deletedNoticeLabel(pubkey) : null;
            if (deleted) { try { localStorage.setItem(DELETED_NOTICE_KEY, label); } catch (_) { } }
            const A = window.NymAccounts;
            let others = 0;
            try {
                if (typeof this.acctEnabled === 'function' && this.acctEnabled()) {
                    others = A.read().accounts.filter((a) => a.pubkey && a.pubkey !== pubkey).length;
                }
            } catch (_) { others = 0; }
            if (others > 0 && typeof this.acctForget === 'function') {
                try { this._panicShowOverlay(); } catch (_) { }
                try { this._cacheDisabled = true; } catch (_) { }
                try { if (typeof A.pageDb === 'function') await this._panicWipeDb(A.pageDb('nym-cache')); } catch (_) { }
                let gone = false;
                try { gone = await this.acctForget(); } catch (_) { gone = false; }
                if (gone) return;
            }
            if (!deleted) {
                await this.panicWipe({ localOnly: true });
                return;
            }
            await this.panicWipe({
                localOnly: true,
                finish: () => {
                    try { localStorage.setItem(DELETED_NOTICE_KEY, label); } catch (_) { }
                    setTimeout(() => {
                        try { location.replace(location.origin + location.pathname); }
                        catch (_) { try { location.reload(); } catch (_) { } }
                    }, 600);
                }
            });
        },

        remotePanicStart() {
            this.remotePanicRender();
            if (this._remotePanicStarted) return;
            this._remotePanicStarted = true;
            this._remotePanicTimer = setInterval(() => { this.remotePanicCheck(); }, R().CHECK_EVERY_MS);
            if (typeof document !== 'undefined') {
                document.addEventListener('visibilitychange', () => {
                    if (document.visibilityState === 'visible') this.remotePanicCheck();
                });
            }
            if (typeof window !== 'undefined') {
                window.addEventListener('online', () => setTimeout(() => this.remotePanicCheck(), 1500));
            }
        },
    });

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        Object.assign(window.NYM_ACTIONS, {
            onRemotePanicChange: function (_e, t) {
                const n = window.nym;
                if (n) n.setRemotePanic(!!t.checked);
            },
        });
    }

    window.NymRemotePanicStrings = STRINGS;

    if (typeof window !== 'undefined' && typeof document !== 'undefined') {
        let tries = 0;
        const boot = () => {
            const n = window.nym;
            if (n && n.pubkey && n.connected && typeof n.remotePanicStart === 'function') {
                n.remotePanicStart();
                n.showDeletedNotice();
                n.remotePanicCheck();
            } else if (++tries < 600) setTimeout(boot, 1000);
        };
        setTimeout(boot, 1500);
    }
})();
