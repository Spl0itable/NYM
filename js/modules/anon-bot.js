(function () {
    'use strict';

    const VOUCHER_N = BigInt('0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141');
    const VOUCHER_DENOMS = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];
    const VOUCHER_MAX_OUTPUTS = 32;
    const HTC_DOMAIN = 'Nymbot_Voucher_HashToCurve_v1';
    const DLEQ_DOMAIN = 'Nymbot_Voucher_DLEQ_v1';
    const ANON_PREV_MAX = 4;
    const ANON_ANNOUNCE_TTL_SEC = 7 * 24 * 3600;

    const enc = new TextEncoder();

    function NT() { return window.NostrTools; }
    function VPoint() { return NT()._secp256k1.ProjectivePoint; }

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    function unhex(str) {
        const out = new Uint8Array(str.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16);
        return out;
    }

    function cat() {
        let len = 0;
        for (const a of arguments) len += a.length;
        const out = new Uint8Array(len);
        let at = 0;
        for (const a of arguments) { out.set(a, at); at += a.length; }
        return out;
    }

    function le32(n) {
        return new Uint8Array([n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255]);
    }

    function scalarFrom(bytes) {
        return BigInt('0x' + hex(bytes)) % VOUCHER_N;
    }

    function scalarHex(v) {
        return v.toString(16).padStart(64, '0');
    }

    function randomScalar() {
        let v = 0n;
        while (v === 0n) v = scalarFrom(crypto.getRandomValues(new Uint8Array(32)));
        return v;
    }

    function hashToCurve(xBytes) {
        const P = VPoint();
        const sha = NT()._sha256;
        const base = sha(cat(enc.encode(HTC_DOMAIN), xBytes));
        for (let i = 0; i < 512; i++) {
            try {
                return P.fromHex('02' + hex(sha(cat(base, le32(i)))));
            } catch (_) { }
        }
        throw new Error('hash-to-curve failed');
    }

    function splitAmount(amount) {
        const out = [];
        let left = Math.floor(amount);
        for (let i = VOUCHER_DENOMS.length - 1; i >= 0 && left > 0; i--) {
            const d = VOUCHER_DENOMS[i];
            while (left >= d && out.length < VOUCHER_MAX_OUTPUTS) {
                out.push(d);
                left -= d;
            }
        }
        return left === 0 ? out : null;
    }

    Object.assign(NYM.prototype, {

        _botAnonKey() {
            return this.pubkey ? 'nym_botanon_' + this.pubkey : null;
        },

        botAnonEnabled() {
            if (typeof this._botAnonOn === 'boolean') return this._botAnonOn;
            try {
                this._botAnonOn = localStorage.getItem('nym_botanon_enabled') === 'true';
            } catch (_) { this._botAnonOn = false; }
            return this._botAnonOn;
        },

        botAnonReady() {
            return !!(this.botAnonEnabled() && this.pubkey && this._botAnon && this._botAnon.current &&
                this._getApiHost && this._getApiHost());
        },

        botAnonBlockedReason() {
            if (!this.pubkey) return 'Pick a nym first.';
            if (!this._getApiHost || !this._getApiHost()) return 'Anonymous Nymbot chat needs the Nymchat worker, which is unavailable on this host.';
            if (typeof this.vaultEnabled === 'function' && this.vaultEnabled() && !this._vaultKey) {
                return 'Unlock your identity first — the anonymous key is stored encrypted with it.';
            }
            if (!this._botAnonLoaded) return 'Still restoring your anonymous key — try again in a moment.';
            return null;
        },

        botAnonIdentity() {
            return (this._botAnon && this._botAnon.current) || null;
        },

        botAnonPubkey() {
            const id = this.botAnonIdentity();
            return id ? id.pk : null;
        },

        botAnonPubkeys() {
            const st = this._botAnon;
            if (!st) return [];
            const out = [];
            if (st.current) out.push(st.current.pk);
            for (const p of (st.prev || [])) out.push(p.pk);
            return out;
        },

        isBotAnonPubkey(pk) {
            return !!pk && this.botAnonPubkeys().indexOf(pk) >= 0;
        },

        _botAnonNewIdentity() {
            const sk = NT().generateSecretKey();
            return {
                sk,
                pk: NT().getPublicKey(sk),
                root: window.NymCrypto.pqGenerateRoot(),
                createdAt: Date.now()
            };
        },

        _botAnonEnsure() {
            if (this.botAnonBlockedReason()) return null;
            if (!this._botAnon) this._botAnon = { current: null, prev: [], tokens: [], pending: null };
            this._botAnonOwner = this.pubkey;
            if (!this._botAnon.current) {
                this._botAnon.current = this._botAnonNewIdentity();
                this._saveBotAnonState();
                this._botAnonRefreshSubs();
            }
            return this._botAnon.current;
        },

        _botAnonRefreshSubs() {
            try {
                if (typeof this._scheduleEphemeralSubRefresh === 'function') this._scheduleEphemeralSubRefresh();
            } catch (_) { }
        },

        _botAnonKem(entry) {
            if (!entry || !entry.root) return null;
            if (!this._botAnonKemCache) this._botAnonKemCache = new Map();
            const hit = this._botAnonKemCache.get(entry.pk);
            if (hit) return hit;
            let keys = null;
            try { keys = window.NymCrypto.pqKeypairFromRoot(entry.root, 0); } catch (_) { return null; }
            this._botAnonKemCache.set(entry.pk, keys);
            return keys;
        },

        botAnonCandidatesFor(event) {
            const st = this._botAnon;
            if (!st || !st.current) return [];
            const pTag = (event.tags || []).find(t => Array.isArray(t) && t[0] === 'p' && t[1]);
            if (!pTag) return [];
            const all = [st.current, ...(st.prev || [])];
            const match = all.find(e => e && e.pk === pTag[1]);
            if (!match) return [];
            const out = [];
            const kem = this._botAnonKem(match);
            if (kem) out.push({ sk: match.sk, bitchat: false, kemSk: kem.secretKey, kemPk: kem.publicKey });
            out.push({ sk: match.sk, bitchat: false });
            return out;
        },

        _botAnonAnnouncement() {
            const id = this.botAnonIdentity();
            if (!id) return null;
            const kem = this._botAnonKem(id);
            if (!kem) return null;
            const cached = this._botAnonAnnCache;
            const nowSec = Math.floor(Date.now() / 1000);
            if (cached && cached.pk === id.pk && cached.exp > nowSec + 3600) return cached.event;
            const b64 = window.NymCrypto._b64uEncode(kem.publicKey);
            const exp = nowSec + ANON_ANNOUNCE_TTL_SEC;
            const payload = {
                v: 2, src: 'root', alg: 'mlkem768', nym: 1, epoch: 0,
                pk: b64, pk2: b64, exp, devices: []
            };
            const event = NT().finalizeEvent({
                kind: 30078,
                created_at: nowSec,
                tags: [['d', 'nym-pq'], ['t', 'nym-pq'], ['expiration', String(exp)]],
                content: JSON.stringify(payload)
            }, id.sk);
            this._botAnonAnnCache = { pk: id.pk, exp, event };
            return event;
        },

        _botAnonSignAuth(action, endpoint, identity) {
            const id = identity || this.botAnonIdentity();
            if (!id) return null;
            const host = this._getApiHost();
            const url = host ? `https://${host}/api/${endpoint || 'bot'}` : '';
            const tags = [['domain', 'nymbot-pm'], ['method', 'POST']];
            if (url) tags.push(['u', url]);
            if (action) tags.push(['action', action]);
            return NT().finalizeEvent({
                kind: 27235,
                created_at: Math.floor(Date.now() / 1000),
                tags,
                content: 'nymbot-pm-auth'
            }, id.sk);
        },

        async _botAnonPost(endpoint, action, extra, opts) {
            const host = this._getApiHost();
            const id = (opts && opts.identity) || this.botAnonIdentity();
            if (!host || !id) return { status: 0, data: {} };
            const auth = this._botAnonSignAuth(action, endpoint, id);
            const body = Object.assign({ action, pubkey: id.pk, auth }, extra || {});
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), (opts && opts.timeout) || 45000);
            try {
                const resp = await fetch(`https://${host}/api/${endpoint}`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body),
                    signal: controller.signal
                });
                const data = await resp.json().catch(() => ({}));
                return { status: resp.status, data: data || {} };
            } finally {
                clearTimeout(timer);
            }
        },

        botAnonRequest(action, extra, opts) {
            return this._botAnonPost('bot', action, extra, opts);
        },

        _botAnonZapRequest(amountSats, comment, recipientPubkey) {
            const id = this.botAnonIdentity();
            if (!id) return null;
            try {
                return NT().finalizeEvent({
                    kind: 9734,
                    created_at: Math.floor(Date.now() / 1000),
                    tags: [
                        ['p', recipientPubkey],
                        ['amount', (parseInt(amountSats, 10) * 1000).toString()],
                        ['relays', ...this.defaultRelays.slice(0, 5)],
                        ['k', '0']
                    ],
                    content: comment || ''
                }, id.sk);
            } catch (_) {
                return null;
            }
        },

        _botAnonAutoRoute(action) {
            if (!this.botAnonReady()) return false;
            return action === 'pm' || action === 'balance' || action === 'clear-history';
        },

        _botAnonArchive(event) {
            if (!event || typeof event.id !== 'string' || !this.botAnonReady()) return;
            const pk = this.botAnonPubkey();
            const forAnon = (event.tags || []).some(t => Array.isArray(t) && t[0] === 'p' && t[1] === pk);
            if (!forAnon) return;
            if (!this._botAnonArchivedIds) this._botAnonArchivedIds = new Set();
            if (this._botAnonArchivedIds.has(event.id)) return;
            this._botAnonArchivedIds.add(event.id);
            if (this._botAnonArchivedIds.size > 4000) {
                this._botAnonArchivedIds = new Set(Array.from(this._botAnonArchivedIds).slice(-2000));
            }
            if (!this._botAnonArchiveQueue) this._botAnonArchiveQueue = [];
            this._botAnonArchiveQueue.push(event);
            if (this._botAnonArchiveQueue.length > 200) this._botAnonArchiveQueue.shift();
            if (this._botAnonArchiveTimer) return;
            this._botAnonArchiveTimer = setTimeout(() => {
                this._botAnonArchiveTimer = null;
                this._flushBotAnonArchive();
            }, 4000);
        },

        async _flushBotAnonArchive() {
            if (!this._botAnonArchiveQueue || !this._botAnonArchiveQueue.length) return;
            const batch = this._botAnonArchiveQueue.splice(0, 50);
            try { await this._botAnonPost('storage', 'pm-put', { events: batch }); } catch (_) { }
            if (this._botAnonArchiveQueue.length && !this._botAnonArchiveTimer) {
                this._botAnonArchiveTimer = setTimeout(() => {
                    this._botAnonArchiveTimer = null;
                    this._flushBotAnonArchive();
                }, 4000);
            }
        },

        botAnonSuppressSendTo(pubkey) {
            return !!(pubkey && this.botAnonEnabled() && this.isVerifiedBot && this.isVerifiedBot(pubkey));
        },

        _botAnonSenderFor(recipientPubkey) {
            if (!this.isVerifiedBot || !this.isVerifiedBot(recipientPubkey)) return null;
            if (!this.botAnonEnabled()) return null;
            const blocked = this.botAnonBlockedReason();
            if (blocked) throw new Error('Anonymous Nymbot chat: ' + blocked);
            const id = this._botAnonEnsure();
            if (!id) throw new Error('Anonymous Nymbot chat is unavailable right now.');
            return id;
        },

        async _sendAnonBotPM(content, recipientPubkey, options) {
            const id = this._botAnonEnsure();
            if (!id) throw new Error('No anonymous Nymbot identity');
            const nowMs = Date.now();
            const now = Math.floor(nowMs / 1000);
            const nymMessageId = this._generateSharedEventId();
            const threadRoot = (options && options.threadRoot) || null;
            const rumor = {
                kind: 14,
                created_at: now,
                tags: [
                    ['p', recipientPubkey],
                    ['x', nymMessageId],
                    ['ms', String(nowMs)],
                    ...(threadRoot ? [['nymthread', threadRoot]] : []),
                    ...this.customEmojiTagsForContent(content),
                    ...(typeof this.imetaTagsForContent === 'function' ? this.imetaTagsForContent(content) : [])
                ],
                content,
                pubkey: id.pk
            };
            const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
                ? now + this.settings.dmTTLSeconds
                : null;

            if (typeof this.ensurePqAnnouncement === 'function') {
                try { await this.ensurePqAnnouncement(recipientPubkey); } catch (_) { }
            }
            const plan = this.pqPmPlan(recipientPubkey);
            const wrapped = plan.kemPk
                ? await this.pqWrapForPeerAsync(plan.pq2, rumor, id.sk, recipientPubkey, plan.kemPk, expirationTs)
                : await this.nip59WrapEventAsync(rumor, id.sk, recipientPubkey, expirationTs);
            this.sendDMToRelays(['EVENT', wrapped]);
            this._recordGiftWrapId(nymMessageId, wrapped.id);

            const kem = this._botAnonKem(id);
            const selfWrapped = kem
                ? await this.pqWrapForPeerAsync(true, rumor, id.sk, id.pk, kem.publicKey, expirationTs)
                : await this.nip59WrapEventAsync(rumor, id.sk, id.pk, expirationTs);
            this.sendDMToRelays(['EVENT', selfWrapped]);
            this._recordGiftWrapId(nymMessageId, selfWrapped.id);
            this._botAnonArchive(selfWrapped);

            const conversationKey = this.getPMConversationKey(recipientPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);
            const pmList = this.pmMessages.get(conversationKey);
            pmList.push({
                id: wrapped.id,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                created_at: now,
                _ms: nowMs,
                _seq: ++this._msgSeq,
                timestamp: new Date(now * 1000),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                nymMessageId,
                threadRoot: threadRoot || undefined,
                senderVerified: true,
                pqEncrypted: !!plan.kemPk,
                pqRoot: !!plan.kemPk && !!plan.rootSeeded,
                anonSender: true,
                deliveryStatus: 'sent'
            });
            pmList.sort((a, b) => this._compareMessages(a, b));
            if (pmList.length > this.pmStorageLimit) {
                this.pmMessages.set(conversationKey, pmList.slice(-this.pmStorageLimit));
            }
            this.persistPMMessages(conversationKey);
            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);
            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
                this._scheduleScrollToBottom();
            }
            return wrapped.id;
        },

        _saveBotAnonState() {
            const key = this._botAnonKey();
            if (!key || !this._botAnon) return;
            let json;
            try { json = JSON.stringify(this.botAnonSerialize()); } catch (_) { return; }
            try {
                if (typeof this.vaultEnabled === 'function' && this.vaultEnabled()) {
                    if (!this._vaultKey) return;
                    const seq = (this._botAnonSaveSeq = (this._botAnonSaveSeq || 0) + 1);
                    this._vaultEncrypt(json).then(blob => {
                        if (seq !== this._botAnonSaveSeq) return;
                        try { localStorage.setItem(key, blob); } catch (_) { }
                    }).catch(() => { });
                } else {
                    localStorage.setItem(key, json);
                }
            } catch (_) { }
        },

        botAnonSerialize() {
            const st = this._botAnon || {};
            const one = (e) => ({ sk: hex(e.sk), pk: e.pk, root: hex(e.root), createdAt: e.createdAt || 0 });
            return {
                current: st.current ? one(st.current) : null,
                prev: (st.prev || []).slice(0, ANON_PREV_MAX).map(one),
                tokens: (st.tokens || []).slice(0, 200),
                pending: st.pending || null
            };
        },

        botAnonDeserialize(data) {
            if (!data || typeof data !== 'object') return null;
            const one = (e) => {
                if (!e || typeof e.sk !== 'string' || typeof e.pk !== 'string' || typeof e.root !== 'string') return null;
                if (!/^[0-9a-f]{64}$/i.test(e.sk) || !/^[0-9a-f]{64}$/i.test(e.pk) || !/^[0-9a-f]{64}$/i.test(e.root)) return null;
                return { sk: unhex(e.sk), pk: e.pk, root: unhex(e.root), createdAt: e.createdAt || 0 };
            };
            const current = one(data.current);
            if (!current) return null;
            return {
                current,
                prev: (Array.isArray(data.prev) ? data.prev : []).map(one).filter(Boolean).slice(0, ANON_PREV_MAX),
                tokens: Array.isArray(data.tokens) ? data.tokens.slice(0, 200) : [],
                pending: data.pending || null
            };
        },

        async _loadBotAnonState() {
            const key = this._botAnonKey();
            if (!key) return;
            if (this._botAnonOwner && this._botAnonOwner !== this.pubkey) {
                this._botAnon = null;
                this._botAnonKemCache = null;
                this._botAnonAnnCache = null;
            }
            this._botAnonOwner = this.pubkey;
            this._botAnonLoaded = false;
            let migrate = false;
            try {
                let raw = localStorage.getItem(key);
                if (raw) {
                    if (String(raw).startsWith('enc:v1:')) {
                        if (typeof this.vaultEnabled === 'function' && this.vaultEnabled() && this._vaultKey) {
                            raw = await this._vaultDecrypt(raw);
                        } else {
                            raw = null;
                        }
                    } else if (typeof this.vaultEnabled === 'function' && this.vaultEnabled() && this._vaultKey) {
                        migrate = true;
                    }
                }
                if (raw) {
                    const data = JSON.parse(raw);
                    if (this._botAnon && this._botAnon.current) {
                        this.botAnonApplySynced(data);
                    } else {
                        const parsed = this.botAnonDeserialize(data);
                        if (parsed) {
                            this._botAnon = parsed;
                            this._botAnonKemCache = null;
                            this._botAnonAnnCache = null;
                        }
                    }
                }
            } catch (_) { }
            this._botAnonLoaded = true;
            if (migrate) this._saveBotAnonState();
            if (this._botAnon && this._botAnon.current) {
                this._botAnonRefreshSubs();
                this._botAnonFlushVouchers();
            }
        },

        botAnonApplySynced(data) {
            const parsed = this.botAnonDeserialize(data);
            if (!parsed) return;
            if (!this._botAnon) this._botAnon = { current: null, prev: [], tokens: [], pending: null };
            const cur = this._botAnon && this._botAnon.current;
            if (cur && cur.pk === parsed.current.pk) {
                if (!this._botAnon.tokens || !this._botAnon.tokens.length) this._botAnon.tokens = parsed.tokens;
                return;
            }
            if (cur && (cur.createdAt || 0) > (parsed.current.createdAt || 0)) {
                this._botAnonAdoptPrev(parsed.current);
                this._botAnonMergeTokens(parsed.tokens);
                this._saveBotAnonState();
                return;
            }
            if (cur) parsed.prev = [cur, ...parsed.prev].slice(0, ANON_PREV_MAX);
            this._botAnon = parsed;
            this._botAnonKemCache = null;
            this._botAnonAnnCache = null;
            this._saveBotAnonState();
            this._botAnonRefreshSubs();
            if (this.connected && typeof this._recoverEphemeralHistory === 'function') {
                this._recoverEphemeralHistory(this.botAnonPubkeys()).catch(() => { });
            }
            this._botAnonFlushVouchers();
        },

        _botAnonMergeTokens(tokens) {
            if (!Array.isArray(tokens) || !tokens.length || !this._botAnon) return;
            if (!Array.isArray(this._botAnon.tokens)) this._botAnon.tokens = [];
            const have = new Set(this._botAnon.tokens.map(t => t && t.x));
            for (const t of tokens) {
                if (t && t.x && !have.has(t.x)) {
                    have.add(t.x);
                    this._botAnon.tokens.push(t);
                }
            }
        },

        async botAnonSweepPrev() {
            const st = this._botAnon;
            if (!st || !st.current || !(st.prev || []).length) return 0;
            let moved = 0;
            for (const old of st.prev) {
                try {
                    const { status, data } = await this._botAnonPost('bot', 'transfer-credits',
                        { targetPubkey: st.current.pk }, { identity: old });
                    if (status < 400 && data && !data.error) {
                        moved += (data.transferred || 0) + (data.proTransferred || 0);
                    }
                } catch (_) { }
            }
            return moved;
        },

        _botAnonAdoptPrev(entry) {
            if (!entry || !this._botAnon) return;
            if (!Array.isArray(this._botAnon.prev)) this._botAnon.prev = [];
            if (this._botAnon.prev.some(e => e.pk === entry.pk)) return;
            this._botAnon.prev.unshift(entry);
            this._botAnon.prev = this._botAnon.prev.slice(0, ANON_PREV_MAX);
            this._botAnonRefreshSubs();
        },

        async botAnonSetEnabled(on) {
            this._botAnonOn = !!on;
            try { localStorage.setItem('nym_botanon_enabled', on ? 'true' : 'false'); } catch (_) { }
            if (on && !this._botAnonLoaded) await this._loadBotAnonState();
            if (on) {
                this._botAnonEnsure();
                this._botAnonFlushVouchers();
            }
            this._saveBotAnonState();
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(1500);
            this._refreshBotControlBar();
            this._refreshBotCreditMeta();
        },

        async botAnonRotate(sweep) {
            const st = this._botAnon;
            if (st && st.current) this._botAnonAdoptPrev(st.current);
            if (!this._botAnon) this._botAnon = { current: null, prev: [], tokens: [], pending: null };
            this._botAnon.current = this._botAnonNewIdentity();
            this._botAnonKemCache = null;
            this._botAnonAnnCache = null;
            this._saveBotAnonState();
            this._botAnonRefreshSubs();
            let moved = 0;
            if (sweep) moved = await this.botAnonSweepPrev();
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(1500);
            this._refreshBotCreditMeta();
            return moved;
        },

        async _botVoucherKeyset(force) {
            if (this._botVoucherKeys && !force) return this._botVoucherKeys;
            const { status, data } = await this._botMoneyRequest('voucher-keys', {}, { anon: false });
            if (status >= 400 || !data || data.error || !data.keys || !data.keysetId) {
                throw new Error((data && data.error) || 'Voucher keys unavailable');
            }
            let pinned = null;
            try { pinned = localStorage.getItem('nym_botanon_keyset'); } catch (_) { }
            if (pinned && pinned !== data.keysetId) {
                const ok = await window.showAppConfirm(
                    'Nymbot\'s voucher signing keys changed since you last moved credits. That happens on a legitimate key rotation, but it is also what a server would do to tag your vouchers. Continue anyway?',
                    { title: 'Voucher keys changed', okLabel: 'Continue', danger: true });
                if (!ok) throw new Error('Voucher keyset rejected');
            }
            try { localStorage.setItem('nym_botanon_keyset', data.keysetId); } catch (_) { }
            this._botVoucherKeys = data;
            return data;
        },

        _botVoucherVerifyDleq(keyHex, blindedHex, sig) {
            try {
                const P = VPoint();
                const K = P.fromHex(keyHex);
                const B = P.fromHex(blindedHex);
                const C = P.fromHex(sig.C);
                const e = BigInt('0x' + sig.e);
                const s = BigInt('0x' + sig.s);
                if (e <= 0n || e >= VOUCHER_N || s <= 0n || s >= VOUCHER_N) return false;
                const R1 = P.BASE.multiply(s).subtract(K.multiply(e));
                const R2 = B.multiply(s).subtract(C.multiply(e));
                const check = scalarFrom(NT()._sha256(cat(
                    enc.encode(DLEQ_DOMAIN),
                    R1.toRawBytes(true),
                    R2.toRawBytes(true),
                    K.toRawBytes(true),
                    C.toRawBytes(true)
                )));
                return scalarHex(check) === String(sig.e).toLowerCase();
            } catch (_) {
                return false;
            }
        },

        _botVoucherTokens(tier) {
            const st = this._botAnon;
            if (!st || !Array.isArray(st.tokens)) return [];
            return st.tokens.filter(t => t && (t.tier || 'standard') === tier);
        },

        async _botAnonFlushVouchers() {
            if (this._botVoucherFlushing || !this.botAnonReady()) return;
            const st = this._botAnon;
            if (!st) return;
            if (!st.pending && !(st.tokens || []).length) return;
            this._botVoucherFlushing = true;
            try {
                if (st.pending) await this._botVoucherFinishIssue(st.pending);
                for (const tier of ['standard', 'pro']) {
                    while (this._botVoucherTokens(tier).length) await this._botVoucherRedeem(tier);
                }
            } catch (_) {
            } finally {
                this._botVoucherFlushing = false;
            }
        },

        async _botVoucherFinishIssue(pending) {
            const keyset = await this._botVoucherKeyset();
            const { status, data } = await this._botMoneyRequest('voucher-issue', {
                tier: pending.tier,
                reqId: pending.reqId,
                outputs: pending.outputs.map(o => ({ d: o.d, B: o.B }))
            }, { anon: false });
            if (status >= 400 || !data || data.error) {
                if (status >= 400 && status < 500 && !(data && data.insufficient)) {
                    this._botAnon.pending = null;
                    this._saveBotAnonState();
                }
                throw new Error((data && data.error) || 'Could not issue vouchers');
            }
            if (data.insufficient) {
                this._botAnon.pending = null;
                this._saveBotAnonState();
                const err = new Error(`Not enough ${pending.tier === 'pro' ? 'Pro ' : ''}credits on your identity — ${data.balance} left, ${data.required} needed.`);
                err.insufficient = true;
                throw err;
            }
            const sigs = Array.isArray(data.signatures) ? data.signatures : [];
            if (sigs.length !== pending.outputs.length) throw new Error('Voucher response did not match the request');
            const P = VPoint();
            const tokens = [];
            for (let i = 0; i < sigs.length; i++) {
                const out = pending.outputs[i];
                const sig = sigs[i];
                if (!sig || Number(sig.d) !== out.d) throw new Error('Voucher denomination mismatch');
                const keyHex = keyset.keys[pending.tier] && keyset.keys[pending.tier][String(out.d)];
                if (!keyHex) throw new Error('Unknown voucher denomination');
                if (!this._botVoucherVerifyDleq(keyHex, out.B, sig)) {
                    throw new Error('Nymbot returned a voucher signature it could not prove — refusing it, since an unprovable signature can be used to tag you. Nothing was spent anonymously.');
                }
                const K = P.fromHex(keyHex);
                const C = P.fromHex(sig.C).subtract(K.multiply(BigInt('0x' + out.r)));
                tokens.push({ d: out.d, x: out.x, C: C.toHex(true), tier: pending.tier });
            }
            if (!Array.isArray(this._botAnon.tokens)) this._botAnon.tokens = [];
            this._botAnon.tokens = this._botAnon.tokens.concat(tokens);
            this._botAnon.pending = null;
            this._saveBotAnonState();
            return tokens;
        },

        async _botVoucherRedeem(tier) {
            const tokens = this._botVoucherTokens(tier);
            if (!tokens.length) return 0;
            const claimed = tokens.find(t => t.redeemId);
            let redeemId, batch;
            if (claimed) {
                redeemId = claimed.redeemId;
                batch = tokens.filter(t => t.redeemId === redeemId).slice(0, VOUCHER_MAX_OUTPUTS);
            } else {
                redeemId = hex(crypto.getRandomValues(new Uint8Array(32)));
                batch = tokens.slice(0, VOUCHER_MAX_OUTPUTS);
                for (const t of batch) t.redeemId = redeemId;
                this._saveBotAnonState();
            }
            const { status, data } = await this.botAnonRequest('voucher-redeem', {
                tier,
                redeemId,
                tokens: batch.map(t => ({ d: t.d, x: t.x, C: t.C }))
            });
            if (status >= 400 || !data || data.error) {
                if (data && data.alreadySpent) {
                    this._botAnonDropTokens(batch);
                }
                throw new Error((data && data.error) || 'Could not redeem vouchers');
            }
            this._botAnonDropTokens(batch);
            if (typeof data.balance === 'number') {
                if (tier === 'pro') this._setBotProCreditDisplay(data.balance);
                else this._setBotCreditDisplay(data.balance);
            }
            return data.credited || 0;
        },

        _botAnonDropTokens(batch) {
            const gone = new Set(batch.map(t => t.x));
            this._botAnon.tokens = (this._botAnon.tokens || []).filter(t => !gone.has(t.x));
            this._saveBotAnonState();
        },

        async botAnonMoveCredits(amount, tier) {
            amount = Math.floor(Number(amount) || 0);
            tier = tier === 'pro' ? 'pro' : 'standard';
            if (amount <= 0) throw new Error('Enter how many credits to move.');
            const denoms = splitAmount(amount);
            if (!denoms) throw new Error('That amount needs too many vouchers — move a smaller amount.');
            const blocked = this.botAnonBlockedReason();
            if (blocked) throw new Error(blocked);
            if (!this._botAnonEnsure()) throw new Error('Anonymous Nymbot chat is unavailable right now.');
            await this._botVoucherKeyset();
            if (this._botAnon.pending) await this._botVoucherFinishIssue(this._botAnon.pending);
            const P = VPoint();
            const outputs = denoms.map(d => {
                const x = crypto.getRandomValues(new Uint8Array(32));
                const r = randomScalar();
                const B = hashToCurve(x).add(P.BASE.multiply(r));
                return { d, x: hex(x), r: scalarHex(r), B: B.toHex(true) };
            });
            this._botAnon.pending = { tier, reqId: hex(crypto.getRandomValues(new Uint8Array(32))), outputs };
            this._saveBotAnonState();
            await this._botVoucherFinishIssue(this._botAnon.pending);
            let credited = 0;
            while (this._botVoucherTokens(tier).length) credited += await this._botVoucherRedeem(tier);
            if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(2000);
            return credited;
        },

        async botAnonBalances() {
            const out = { anon: null, anonPro: null, identity: null, identityPro: null };
            try {
                const anon = await this._botMoneyRequest('balance', {}, { anon: true });
                if (anon.data && !anon.data.error) {
                    out.anon = anon.data.balance || 0;
                    out.anonPro = anon.data.proBalance || 0;
                }
            } catch (_) { }
            try {
                const real = await this._botMoneyRequest('balance', {}, { anon: false });
                if (real.data && !real.data.error) {
                    out.identity = real.data.balance || 0;
                    out.identityPro = real.data.proBalance || 0;
                }
            } catch (_) { }
            return out;
        },

        openBotAnonModal() {
            const modal = document.getElementById('botAnonModal');
            if (!modal) return;
            const toggle = document.getElementById('botAnonToggle');
            if (toggle) toggle.checked = this.botAnonEnabled();
            const tier = document.getElementById('botAnonTier');
            if (tier) tier.value = this._getBotProModel() ? 'pro' : 'standard';
            this._setBotAnonStatus('');
            this._renderBotAnonBody();
            modal.classList.add('active');
            this._refreshBotAnonBalances();
        },

        _setBotAnonStatus(text, kind) {
            const el = document.getElementById('botAnonStatus');
            if (!el) return;
            el.textContent = text || '';
            el.className = 'bot-git-status' + (kind ? ' ' + kind : '') + (text ? '' : ' nm-hidden');
        },

        _renderBotAnonBody() {
            const on = this.botAnonEnabled();
            const idEl = document.getElementById('botAnonIdentity');
            if (idEl) {
                const pk = this.botAnonPubkey();
                idEl.textContent = on && pk ? pk.slice(0, 16) + '…' + pk.slice(-8) : 'not created yet';
            }
            const body = document.getElementById('botAnonActiveBody');
            if (body) body.classList.toggle('nm-hidden', !on);
        },

        async _refreshBotAnonBalances() {
            const el = document.getElementById('botAnonBalances');
            if (!el) return;
            if (!this.botAnonReady()) { el.textContent = ''; return; }
            el.textContent = 'Checking balances…';
            const b = await this.botAnonBalances();
            const fmt = (v) => (typeof v === 'number' ? String(v) : '—');
            el.textContent = `Anonymous: ${fmt(b.anon)} standard · ${fmt(b.anonPro)} Pro. Your identity: ${fmt(b.identity)} standard · ${fmt(b.identityPro)} Pro.`;
        },

        async botAnonToggleFromModal(on) {
            await this.botAnonSetEnabled(on);
            this._renderBotAnonBody();
            const reason = on ? this.botAnonBlockedReason() : null;
            if (reason) this._setBotAnonStatus(reason, 'warn');
            else this._setBotAnonStatus(on ? 'Anonymous mode on — Nymbot sees only the key above.' : '', on ? 'ok' : '');
            this._refreshBotAnonBalances();
        },

        async botAnonMoveFromModal() {
            const amountEl = document.getElementById('botAnonAmount');
            const tierEl = document.getElementById('botAnonTier');
            const amount = amountEl ? parseInt(amountEl.value, 10) : 0;
            const tier = tierEl && tierEl.value === 'pro' ? 'pro' : 'standard';
            if (!this.botAnonEnabled()) {
                this._setBotAnonStatus('Turn anonymous mode on first.', 'warn');
                return;
            }
            this._setBotAnonStatus('Moving credits…');
            try {
                const credited = await this.botAnonMoveCredits(amount, tier);
                this._setBotAnonStatus(`Moved ${credited} ${tier === 'pro' ? 'Pro ' : ''}credit${credited === 1 ? '' : 's'} to your anonymous key.`, 'ok');
                if (amountEl) amountEl.value = '';
                this._refreshBotAnonBalances();
            } catch (e) {
                this._setBotAnonStatus(e.message || 'Could not move credits.', 'warn');
            }
        },

        async botAnonRotateFromModal() {
            const res = await window.showAppConfirm(
                'A new throwaway key starts an empty conversation. Nymbot cannot tell the new key is the same person as the old one — unless you carry the balance across, which it does see as one anonymous key paying another.',
                {
                    title: 'New anonymous key',
                    okLabel: 'Rotate',
                    danger: true,
                    checkboxLabel: 'Move the old key\'s remaining credits over'
                });
            if (!res || !res.confirmed) return;
            this._setBotAnonStatus('Rotating…');
            const moved = await this.botAnonRotate(!!res.checked);
            this._renderBotAnonBody();
            this._refreshBotAnonBalances();
            this._setBotAnonStatus(moved
                ? `New anonymous key created and ${moved} credit${moved === 1 ? '' : 's'} carried over.`
                : 'New anonymous key created.', 'ok');
        }
    });
})();
