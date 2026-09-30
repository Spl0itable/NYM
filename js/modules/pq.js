// pq.js — hybrid post-quantum key announcement, discovery, and policy.

(function () {
    const PQ_D_TAG = 'nym-pq';
    const PQ_ALG = 'mlkem768';
    // Expiring announcements stop attracting PQ messages to a downgraded or abandoned device.
    const PQ_TTL_SEC = 7 * 24 * 3600;
    // How long "this peer has no announcement" is trusted before asking again.
    const PQ_REFETCH_MS = 10 * 60 * 1000;
    const PQ_RETRY_SOON_MS = 15 * 1000;
    const PQ_FRESH_KEYLESS_SEC = 10 * 60;
    // A one-shot lookup gives up after this and the message goes classical.
    const PQ_FETCH_TIMEOUT_MS = 2500;
    // How long a send may wait on a lookup; shorter than the relay deadline.
    const PQ_SEND_LOOKUP_BUDGET_MS = 1500;
    // Keep listening after the first EOSE: one relay's "done" is not the answer.
    const PQ_EOSE_GRACE_MS = 600;
    // Cap on a prefetch sweep, so a large group is not one sub per member.
    const PQ_PREFETCH_MAX = 60;
    const PQ_REPUBLISH_SEC = 24 * 3600;
    // Matches the DM catch-up window so our own roster is merged before announcing.
    const PQ_ANNOUNCE_DELAY_MS = 3000;
    // Devices unseen for this long drop off the roster shown in settings.
    const PQ_DEVICE_STALE_SEC = 30 * 24 * 3600;
    // The root's bech32 code on this device, in _VAULT_KEYS (spec §5.3).
    const PQ_ROOT_LS_KEY = 'nym_pq_root';
    const PQ_ROOT_LEGACY_SLOT = 'legacy';
    const PQ_ROOT_RETRY_MS = [15000, 30000, 60000, 120000];

    Object.assign(NYM.prototype, {

        PQ_D_TAG,
        PQ_TTL_SEC,
        PQ_ROOT_LS_KEY,

        pqSupported() {
            return !!(window.NymCrypto && window.NymCrypto.pqAvailable && window.NymCrypto.pqAvailable());
        },

        // Can receive PQ: the root suffices (signers included); an nsec also qualifies for legacy pq1 keys.
        pqCapable() {
            return this.pqSupported() && (this.pqHasRoot() || !!this.privkey);
        },

        // The legacy combined format mixes in raw ECDH output, which no signer returns, so it needs the nsec.
        pq1Capable() {
            return this.pqSupported() && !!this.privkey;
        },

        // Only the seal needs the signer, so extension/NIP-46 logins can still hybridize the wrap.
        pqSendCapable() {
            return this.pqSupported();
        },

        // No user setting: only inability turns it off.
        pqEnabled() {
            return this.pqSendCapable() && this._pqMode() !== 'off';
        },

        // Self copies need a key we can decapsulate, or we lock ourselves out of our history.
        pqSelfEnabled() {
            return this.pqCapable() && this._pqMode() !== 'off';
        },

        // Undocumented escape hatch: users can set `nym_pq_mode` to 'off' to defuse a field bug.
        _pqMode() {
            try { return localStorage.getItem('nym_pq_mode') || 'on'; }
            catch (_) { return 'on'; }
        },

        pqUpgradeNoticePending() {
            try { return localStorage.getItem('nym_pq_upgrade_notice') === 'pending'; }
            catch (_) { return false; }
        },

        dismissPqUpgradeNotice() {
            try { localStorage.removeItem('nym_pq_upgrade_notice'); } catch (_) { }
        },

        // Keyed per account and cleared once shown; aimed at fresh installs joining an account with a root.
        pqRootLinkPromptPending() {
            if (!this.pqRootLinkNeeded()) return false;
            try {
                return localStorage.getItem(`nym_pq_link_prompt_${this.pubkey}`) !== 'shown';
            } catch (_) { return false; }
        },

        dismissPqRootLinkPrompt() {
            try { localStorage.setItem(`nym_pq_link_prompt_${this.pubkey}`, 'shown'); } catch (_) { }
        },

        // `nym_last_online_ts` exists on every prior version, so its presence marks an upgrade.
        _pqMarkUpgradeIfNeeded() {
            try {
                if (localStorage.getItem('nym_pq_upgrade_seen')) return;
                localStorage.setItem('nym_pq_upgrade_seen', '1');
                if (localStorage.getItem('nym_last_online_ts')) {
                    localStorage.setItem('nym_pq_upgrade_notice', 'pending');
                }
            } catch (_) { }
        },

        _pqEpoch() {
            try { return parseInt(localStorage.getItem('nym_pq_epoch') || '0', 10) || 0; }
            catch (_) { return 0; }
        },

        // How far back to look for the epoch our own announcement is at.
        _PQ_EPOCH_SCAN: 12,

        // Puts this device on the epoch the account is on.
        _pqAdoptAnnouncedEpoch() {
            try {
                const NC = window.NymCrypto;
                if (!NC) return false;
                const root = this.pqRoot();
                // Same seed choice as pqSelfKeys.
                const derive = root
                    ? (e) => NC.pqKeypairFromRoot(root, e)
                    : (this.privkey ? (e) => NC.pqKeypairFromPrivkey(this.privkey, e) : null);
                if (!derive) return false;
                const mine = this._pqEntry(this.pubkey);
                const announced = mine && mine.pk;
                if (!announced) return false;
                const here = this._pqEpoch();
                const same = (a, b) => {
                    if (!a || !b || a.length !== b.length) return false;
                    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
                    return true;
                };
                let at = null;
                try { at = derive(here); } catch (_) { at = null; }
                if (at && same(at.publicKey, announced)) return false;
                // The announced epoch first, then a scan.
                const tried = new Set([here]);
                const order = [];
                if (Number.isInteger(mine.epoch) && mine.epoch >= 0) order.push(mine.epoch);
                for (let e = 0; e <= this._PQ_EPOCH_SCAN; e++) order.push(e);
                for (const epoch of order) {
                    if (tried.has(epoch)) continue;
                    tried.add(epoch);
                    let keys;
                    try { keys = derive(epoch); } catch (_) { continue; }
                    if (!keys || !same(keys.publicKey, announced)) continue;
                    try { localStorage.setItem('nym_pq_epoch', String(epoch)); } catch (_) { }
                    this._pqSelfCache = null;
                    return true;
                }
                return false;
            } catch (_) { return false; }
        },

        // The root secret: docs/PQ-ROOT-SPEC.md.

        _pqRootRawStored() {
            try {
                if (typeof window !== 'undefined' && typeof window.nymSecretGet === 'function') {
                    return window.nymSecretGet(PQ_ROOT_LS_KEY);
                }
            } catch (_) { }
            try { return localStorage.getItem(PQ_ROOT_LS_KEY); } catch (_) { return null; }
        },

        _pqRootRawStore(value) {
            try {
                if (typeof window !== 'undefined' && typeof window.nymSecretSet === 'function') {
                    window.nymSecretSet(PQ_ROOT_LS_KEY, value);
                    return;
                }
            } catch (_) { }
            try { localStorage.setItem(PQ_ROOT_LS_KEY, value); } catch (_) { }
        },

        _pqRootStoredMap() {
            const raw = this._pqRootRawStored();
            const out = { byPubkey: {}, legacy: null, unreadable: false };
            if (!raw || typeof raw !== 'string') return out;
            const s = raw.trim();
            if (s.startsWith('{')) {
                try {
                    const obj = JSON.parse(s);
                    if (obj && typeof obj === 'object') {
                        for (const [k, v] of Object.entries(obj)) {
                            if (typeof v !== 'string' || !v) continue;
                            if (k === PQ_ROOT_LEGACY_SLOT) out.legacy = v;
                            else if (/^[0-9a-f]{64}$/.test(k)) out.byPubkey[k] = v;
                        }
                    }
                } catch (_) { out.unreadable = true; }
                return out;
            }
            try {
                window.NymCrypto.pqRootDecode(s);
                out.legacy = s;
            } catch (_) { out.unreadable = true; }
            return out;
        },

        _pqRootWriteMap(map) {
            const obj = {};
            for (const [k, v] of Object.entries(map.byPubkey || {})) obj[k] = v;
            if (map.legacy) obj[PQ_ROOT_LEGACY_SLOT] = map.legacy;
            if (Object.keys(obj).length === 0) {
                try {
                    if (typeof window !== 'undefined' && typeof window.nymSecretRemove === 'function') {
                        window.nymSecretRemove(PQ_ROOT_LS_KEY);
                        return;
                    }
                } catch (_) { }
                try { localStorage.removeItem(PQ_ROOT_LS_KEY); } catch (_) { }
                return;
            }
            this._pqRootRawStore(JSON.stringify(obj));
        },

        _pqRootStoredCode() {
            if (!this.pubkey) return null;
            return this._pqRootStoredMap().byPubkey[this.pubkey] || null;
        },

        _pqRootStoreCode(code) {
            if (!this.pubkey) return;
            const map = this._pqRootStoredMap();
            map.byPubkey[this.pubkey] = code;
            this._pqRootWriteMap(map);
        },

        _pqRootLegacyBytes() {
            const code = this._pqRootStoredMap().legacy;
            if (!code) return null;
            try { return window.NymCrypto.pqRootDecode(code); } catch (_) { return null; }
        },

        _pqRootDropLegacy() {
            const map = this._pqRootStoredMap();
            if (!map.legacy) return;
            map.legacy = null;
            this._pqRootWriteMap(map);
        },

        pqRoot() {
            if (this._pqRootBytes
                && (this._pqRootBytesFor === undefined || this._pqRootBytesFor === this.pubkey)) {
                return this._pqRootBytes;
            }
            this._pqRootBytes = null;
            this._pqRootBytesFor = this.pubkey;
            const map = this._pqRootStoredMap();
            this._pqRootUnreadable = !!map.unreadable;
            const code = this.pubkey ? (map.byPubkey[this.pubkey] || null) : null;
            if (!code) return null;
            try {
                const bytes = window.NymCrypto.pqRootDecode(code);
                this._pqRootBytes = bytes;
                this._pqRootUnreadable = false;
                return bytes;
            } catch (_) {
                this._pqRootUnreadable = true;
                return null;
            }
        },

        pqHasRoot() { return !!this.pqUsableRoot(); },

        // A locked device's root doesn't open the account record; sealing to it writes unreadable history.
        pqUsableRoot() {
            if (this._pqRootLocked) return null;
            return this.pqRoot();
        },

        // The `nympq1...` code, for the reveal/copy surface beside the nsec.
        pqRootCode() {
            // A locked device must not offer a stale root as "your recovery code".
            const r = this.pqUsableRoot();
            if (!r) return null;
            try { return window.NymCrypto.pqRootEncode(r); } catch (_) { return null; }
        },

        pqRootFingerprint() {
            const r = this.pqRoot();
            if (!r) return null;
            try { return window.NymCrypto.pqRootFingerprint(r); } catch (_) { return null; }
        },

        // Every install path funnels through here so caches clear in one place.
        pqRootAdopt(rootBytes) {
            const NC = window.NymCrypto;
            if (!NC || !NC.pqIsRoot(rootBytes)) return false;
            const code = NC.pqRootEncode(rootBytes);
            this._pqRootBytes = rootBytes;
            this._pqRootBytesFor = this.pubkey;
            this._pqRootUnreadable = false;
            this._pqRootStoreCode(code);
            this._pqRootLocked = false;
            this._pqSelfCache = null;
            return true;
        },

        // Panic wipe and forget-identity call this: a root must not outlive its identity.
        pqRootWipe() {
            this._pqRootBytes = null;
            this._pqRootBytesFor = null;
            this._pqRootUnreadable = false;
            this._pqSelfCache = null;
            this._pqRootLocked = false;
            this._pqRootRecord = null;
            this._pqRootRowUnreadable = false;
            try {
                if (typeof window !== 'undefined' && typeof window.nymSecretRemove === 'function') {
                    window.nymSecretRemove(PQ_ROOT_LS_KEY);
                    return;
                }
            } catch (_) { }
            try { localStorage.removeItem(PQ_ROOT_LS_KEY); } catch (_) { }
        },

        // A record exists that this device cannot open; it must not generate or announce (spec §7).
        pqRootLocked() { return !!this._pqRootLocked; },

        // Until §6 runs, any announced key is nsec-derived by default rather than by decision.
        pqRootSettled() { return !!this._pqRootSettled; },

        pqRootLinkNeeded() { return this.pqRootLocked(); },

        // Whether we may announce `v:2, src:"root"`.
        pqRootSeeded() { return this.pqCapable() && this.pqHasRoot(); },

        // `wraps` may be empty: the record still says a root exists, which silences other devices.
        pqRootBuildRecord(wraps) {
            const r = this.pqRoot();
            if (!r) return null;
            return {
                v: 2,
                fp: window.NymCrypto.pqRootFingerprint(r),
                wraps: Array.isArray(wraps) ? wraps : [],
                ts: Math.floor(Date.now() / 1000)
            };
        },

        // A stored record only counts if it is actually a v2 root record.
        _pqRootValidRecord(record) {
            return !!(record && typeof record === 'object'
                && record.v === 2 && typeof record.fp === 'string' && record.fp);
        },

        pqRootRecordWraps() {
            const rec = this._pqRootRecord;
            return (rec && Array.isArray(rec.wraps)) ? rec.wraps : [];
        },

        // Spec §6: 'unavailable'|'adopted'|'locked'|'publish-record'|'generated'; rowPresent alone blocks generating.
        pqRootEnsure(record, rowPresent, existingCode) {
            const preset = existingCode === undefined ? this._pqRootTakePreset() : existingCode;
            // pqSupported, not pqCapable: for a signer the root is what makes it capable (avoids a deadlock).
            if (!this.pqSupported()) return 'unavailable';
            this._pqRootClearRetry();
            if (this._pqThrowawayIdentity()) {
                this._pqRootSettled = true;
                this._pqRootRecord = null;
                this._pqRootRowUnreadable = false;
                this._pqRootLocked = false;
                return 'skipped';
            }
            this._pqRootSettled = true;
            this._pqRootRecord = this._pqRootValidRecord(record) ? record : null;
            this._pqRootRowUnreadable = !!rowPresent && !this._pqRootRecord;
            const NC = window.NymCrypto;
            const mine = this.pqRoot();
            const legacy = mine ? null : this._pqRootLegacyBytes();

            if (this._pqRootRecord) {
                if (mine && NC.pqRootFingerprint(mine) === this._pqRootRecord.fp) {
                    this._pqRootLocked = false;
                    return 'adopted';
                }
                if (!mine && legacy && NC.pqRootFingerprint(legacy) === this._pqRootRecord.fp
                    && this.pqRootAdopt(legacy)) {
                    this._pqRootDropLegacy();
                    return 'adopted';
                }
                // Nothing, or a stale root from a reset identity: both mean "cannot open this record".
                this._pqRootLocked = true;
                return 'locked';
            }

            if (rowPresent) {
                this._pqRootLocked = true;
                if (!this.privkey) {
                    this._pqRootSettled = false;
                    this._pqRootScheduleRetry();
                }
                return 'locked';
            }

            // No record row but we hold a root; the caller must re-publish or other devices mint a rival root (§6.4).
            if (mine) {
                this._pqRootLocked = false;
                return 'publish-record';
            }
            if (this._pqRootUnreadable) {
                this._pqRootLocked = true;
                return 'locked';
            }
            const given = this._pqRootDecodeCode(preset);
            if (given && this.pqRootAdopt(given)) {
                try { localStorage.setItem('nym_pq_root_reveal', 'pending'); } catch (_) { }
                return 'generated';
            }
            if (legacy && this.pqRootAdopt(legacy)) {
                this._pqRootDropLegacy();
                return 'publish-record';
            }

            let fresh;
            try { fresh = NC.pqGenerateRoot(); } catch (_) { return 'unavailable'; }
            if (!this.pqRootAdopt(fresh)) return 'unavailable';
            // Surfaced to the user once (spec §9).
            try { localStorage.setItem('nym_pq_root_reveal', 'pending'); } catch (_) { }
            return 'generated';
        },

        _pqRootDecodeCode(code) {
            if (typeof code !== 'string' || !code) return null;
            const NC = window.NymCrypto;
            try {
                const bytes = NC.pqRootDecode(code.trim());
                return NC.pqIsRoot(bytes) ? bytes : null;
            } catch (_) { return null; }
        },

        pqRootPresetFor(pubkey, code, fresh) {
            if (!pubkey || !this._pqRootDecodeCode(code)) return false;
            this._pqRootPreset = { pubkey, code: code.trim(), fresh: !!fresh };
            if (pubkey === this.pubkey) this._pqRootApplyPreset();
            return true;
        },

        pqRootPresetNew() {
            if (!this.pubkey || !this.pqSupported() || this._pqThrowawayIdentity()) return null;
            if (this.pqRoot()) return null;
            let code;
            try { code = window.NymCrypto.pqRootEncode(window.NymCrypto.pqGenerateRoot()); } catch (_) { return null; }
            return this.pqRootPresetFor(this.pubkey, code, true) ? code : null;
        },

        _pqRootApplyPreset() {
            const p = this._pqRootPreset;
            if (!p || !p.fresh || p.pubkey !== this.pubkey) return false;
            this._pqRootPreset = null;
            if (this.pqRoot()) return false;
            const bytes = this._pqRootDecodeCode(p.code);
            if (!bytes || !this.pqRootAdopt(bytes)) return false;
            this._pqRootSettled = true;
            try { localStorage.setItem('nym_pq_root_reveal', 'pending'); } catch (_) { }
            return true;
        },

        _pqRootTakePreset() {
            const p = this._pqRootPreset;
            if (!p || p.pubkey !== this.pubkey) return null;
            this._pqRootPreset = null;
            return p.code;
        },

        _pqThrowawayIdentity() {
            if (this.connectionMode !== 'ephemeral') return false;
            try {
                const mode = localStorage.getItem('nym_keypair_mode')
                    || (localStorage.getItem('nym_random_keypair_per_session') === 'true' ? 'random' : 'persistent');
                return mode === 'random' || mode === 'hardcore';
            } catch (_) { return false; }
        },

        pqRootRowUnreadable() { return !!this._pqRootRowUnreadable; },

        _pqRootScheduleRetry() {
            if (this._pqRootRetryTimer) return;
            const n = this._pqRootRetryCount || 0;
            if (n >= PQ_ROOT_RETRY_MS.length) return;
            this._pqRootRetryCount = n + 1;
            this._pqRootRetryTimer = setTimeout(async () => {
                this._pqRootRetryTimer = null;
                if (this.pqRootSettled()) return;
                if (typeof this.settingsLoadFromD1 !== 'function') return;
                try { await this.settingsLoadFromD1(); } catch (_) { }
            }, PQ_ROOT_RETRY_MS[n]);
        },

        _pqRootClearRetry() {
            if (this._pqRootRetryTimer) {
                clearTimeout(this._pqRootRetryTimer);
                this._pqRootRetryTimer = null;
            }
        },

        pqResetIdentityState() {
            this._pqRootClearRetry();
            this._pqRootRetryCount = 0;
            this._pqRootRetryAt = 0;
            this._pqRootBytes = null;
            this._pqRootBytesFor = null;
            this._pqRootUnreadable = false;
            this._pqRootLocked = false;
            this._pqRootSettled = false;
            this._pqRootRecord = null;
            this._pqRootRowUnreadable = false;
            this._pqSelfCache = null;
            this._pqSelfAnnouncement = null;
            this._pqSelfSignedAnnouncement = null;
            this._pqLastPublishAt = 0;
            this._pqLastPublishTs = 0;
            this._pqRootWaiters = [];
            if (this._pqRootWaitTimer) {
                clearTimeout(this._pqRootWaitTimer);
                this._pqRootWaitTimer = null;
            }
            this._pqRootApplyPreset();
            if (this._pqAnnounceTimer) {
                clearTimeout(this._pqAnnounceTimer);
                this._pqAnnounceTimer = null;
            }
            this._settingsRestoreUnreadable = false;
            this._lastInboundSections = null;
        },

        pqRootRevealPending() {
            try { return localStorage.getItem('nym_pq_root_reveal') === 'pending'; }
            catch (_) { return false; }
        },

        dismissPqRootReveal() {
            try { localStorage.removeItem('nym_pq_root_reveal'); } catch (_) { }
        },

        // Root-seeded when we hold a root, nsec-seeded otherwise; cached per (pubkey, epoch, seed source).
        pqSelfKeys() {
            if (!this.pqCapable()) return null;
            const epoch = this._pqEpoch();
            const root = this.pqUsableRoot();
            const NC = window.NymCrypto;
            const src = root ? NC.pqRootFingerprint(root) : 'nsec';
            const basis = `${this.pubkey}:${epoch}:${src}`;
            if (this._pqSelfCache && this._pqSelfCache.basis === basis) {
                return this._pqSelfCache.keys;
            }
            let keys;
            try {
                if (root) keys = NC.pqKeypairFromRoot(root, epoch);
                else if (this.privkey) keys = NC.pqKeypairFromPrivkey(this.privkey, epoch);
                else return null;
            } catch (_) { return null; }
            this._pqSelfCache = { basis, keys };
            return keys;
        },

        // In-flight messages stay readable because the previous keypair is still derivable at the old epoch.
        async rotatePqKey() {
            const next = this._pqEpoch() + 1;
            try { localStorage.setItem('nym_pq_epoch', String(next)); } catch (_) { }
            this._pqSelfCache = null;
            if (this.pqSelfEnabled()) await this.publishPqAnnouncement();
        },

        // Spec §4: root epochs then nsec epochs; the nsec half is permanent (v1 needs it), not a migration window.
        pqSelfCandidates() {
            if (!this.pqCapable()) return [];
            const NC = window.NymCrypto;
            const out = [];
            const epoch = this._pqEpoch();
            const floor = Math.max(0, epoch - 3);
            const root = this.pqRoot();
            if (root) {
                for (let e = epoch; e >= floor; e--) {
                    try {
                        const k = NC.pqKeypairFromRoot(root, e);
                        out.push({ kemSk: k.secretKey, kemPk: k.publicKey, root: true });
                    } catch (_) { }
                }
            }
            for (let e = epoch; e >= floor; e--) {
                try {
                    const k = NC.pqKeypairFromPrivkey(this.privkey, e);
                    out.push({ kemSk: k.secretKey, kemPk: k.publicKey, root: false });
                } catch (_) { }
            }
            return out;
        },

        _pqDeviceId() {
            let id = null;
            try { id = localStorage.getItem('nym_pq_device_id'); } catch (_) { }
            if (!id) {
                const b = crypto.getRandomValues(new Uint8Array(4));
                id = Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('');
                try { localStorage.setItem('nym_pq_device_id', id); } catch (_) { }
            }
            return id;
        },

        _pqAppVersion() {
            return (typeof NYMCHAT_VERSION !== 'undefined') ? NYMCHAT_VERSION : '';
        },

        // `pq` gates hybrid self-copies (pqAllDevicesCapable), never decryption.
        _pqMergeDeviceRoster(nowSec) {
            const id = this._pqDeviceId();
            const prev = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            const out = prev.filter(d => d && d.id !== id && (nowSec - (d.ts || 0)) < PQ_DEVICE_STALE_SEC);
            out.push({
                id, ver: this._pqAppVersion(), ts: nowSec,
                pq: this.pqCapable() ? 1 : 0,
                // Separate from `pq`: a signer opens the layered format but never the combined one.
                pq2: this.pqCapable() ? 1 : 0
            });
            out.sort((a, b) => (b.ts || 0) - (a.ts || 0));
            return out.slice(0, 16);
        },

        // Every client announces: `pk` = PQ Nymchat, no pk = classical Nymchat, none = unknown (maybe Bitchat).
        async publishPqAnnouncement() {
            try {
                if (!this.connected || !this.pubkey) return false;
                // Spec §7: the announcement is replaceable, so a locked device would clobber the real one.
                if (this.pqRootLocked()) return false;
                // The root travels in the recovery code; the epoch does not.
                this._pqAdoptAnnouncedEpoch();
                // Withhold the key until §6 settles so peers aren't pinned to an nsec-derived key for the whole TTL.
                const keys = (this.pqSelfEnabled() && this.pqRootSettled())
                    ? this.pqSelfKeys() : null;
                // Only true when the key we are publishing is root-derived.
                const rootSeeded = !!keys && this.pqRootSeeded();

                // Addressable ties keep the lower id, so keep created_at strictly monotonic (as the kind-0 save does).
                const nowSec = Math.max(
                    Math.floor(Date.now() / 1000),
                    (this._pqLastPublishTs || 0) + 1
                );
                this._pqLastPublishTs = nowSec;
                const exp = nowSec + PQ_TTL_SEC;
                const payload = {
                    // v:2 + src:"root" claims root-seeded entropy; without a root we are v1 (spec §3).
                    v: rootSeeded ? 2 : 1,
                    ...(rootSeeded ? { src: 'root' } : {}),
                    alg: PQ_ALG,
                    // Parsed separately from `pk` so "Nymchat, no PQ" is distinguishable from a retraction.
                    nym: 1,
                    epoch: this._pqEpoch(),
                    // `pk` = either format (nsec only); `pk2` = layered only, which older builds degrade to plain NIP-44.
                    ...(keys && this.pq1Capable()
                        ? { pk: window.NymCrypto._b64uEncode(keys.publicKey) } : {}),
                    ...(keys ? { pk2: window.NymCrypto._b64uEncode(keys.publicKey) } : {}),
                    exp,
                    devices: this._pqMergeDeviceRoster(nowSec)
                };

                const event = {
                    kind: 30078,
                    created_at: nowSec,
                    tags: [
                        ['d', PQ_D_TAG],
                        ['t', PQ_D_TAG],
                        // NIP-40 so relays can drop a stale announcement too.
                        ['expiration', String(exp)]
                    ],
                    content: JSON.stringify(payload),
                    pubkey: this.pubkey
                };
                const signed = await this.signEvent(event);
                this.sendToRelay(['EVENT', signed]);
                this._pqSelfAnnouncement = payload;
                // Kept for the Nymbot worker, which seals its reply to our KEM key from this signed event.
                this._pqSelfSignedAnnouncement = signed;
                this._pqLastPublishAt = Date.now();
                // Self-addressed wraps resolve through the same lookup as everyone else's.
                this._pqRecord(this.pubkey, keys ? keys.publicKey : null, exp, payload.epoch, rootSeeded);
                return true;
            } catch (_) {
                return false;
            }
        },

        // Republishing without `pk` retracts the key but keeps the Nymchat claim.
        async retractPqAnnouncement() {
            return this.publishPqAnnouncement();
        },

        // At most once per pending window.
        schedulePqAnnouncement() {
            if (this._pqAnnounceTimer) return;
            this._pqAnnounceTimer = setTimeout(async () => {
                this._pqAnnounceTimer = null;
                try {
                    if (!this.pubkey) return;
                    // A failed boot settings read leaves §6 unsettled; every connect is a chance to settle it.
                    await this.pqRootRetryIfUnsettled();
                    // Not gated on pqEnabled(): the announcement also tells peers to skip the Bitchat wrap.
                    if (!this._pqLastPublishAt) this.publishPqAnnouncement();
                    else this.maybeRepublishPqAnnouncement();
                    this._pqMarkUpgradeIfNeeded();
                    this.maybeShowPqUpgradeNotice();
                    if (typeof this.ensureAttestBadge === 'function') this.ensureAttestBadge();
                    if (typeof this.ensureFilterPacksLoaded === 'function') this.ensureFilterPacksLoaded();
                } catch (_) { }
            }, PQ_ANNOUNCE_DELAY_MS);
        },

        // Bounded to one attempt a minute so an unreachable API is not hammered.
        async pqRootRetryIfUnsettled() {
            if (typeof this.pqRootSettled !== 'function' || this.pqRootSettled()) return false;
            if (typeof this.settingsLoadFromD1 !== 'function') return false;
            const now = Date.now();
            if (this._pqRootRetryAt && now - this._pqRootRetryAt < 60000) return false;
            this._pqRootRetryAt = now;
            try { await this.settingsLoadFromD1(); } catch (_) { }
            return this.pqRootSettled();
        },

        // Daily cadence keeps the 7-day expiry alive; a lapsed announcement would attract Bitchat wraps.
        maybeRepublishPqAnnouncement() {
            if (!this.pubkey) return;
            const since = Date.now() - (this._pqLastPublishAt || 0);
            if (since < PQ_REPUBLISH_SEC * 1000) return;
            this.publishPqAnnouncement();
        },

        // Null `pk` still means "runs Nymchat"; `root` is the §3 claim (v:2 AND src=="root").
        _pqRecord(pubkey, pk, exp, epoch, root, fmt, at) {
            if (!this.pqKeys) this.pqKeys = new Map();
            // Absent `fmt` means a pre-split entry: legacy format only.
            this.pqKeys.set(pubkey, {
                pk: pk || null, exp, epoch, root: !!root,
                pq1: fmt ? !!fmt.pq1 : true,
                pq2: fmt ? !!fmt.pq2 : false,
                // Announcement time for the send plan (`_pqPmPlan`); derived as exp - TTL for older entries.
                at: at || (exp ? exp - PQ_TTL_SEC : 0)
            });
            // Persisted so a reload doesn't send classically while re-looking up keys; bounded by expiry.
            if (typeof this._persistDedupSets === 'function') this._persistDedupSets();
            // Map preserves insertion order, so the earliest-recorded entry is evicted.
            while (this.pqKeys.size > 5000) {
                this.pqKeys.delete(this.pqKeys.keys().next().value);
            }
        },

        // Spec §3: `v` is the number 2 and `src` the string "root"; everything else is legacy.
        _pqAnnouncementIsRootSeeded(payload) {
            return !!payload && payload.v === 2 && payload.src === 'root';
        },

        pqPeerIsRootSeeded(pubkey) {
            const rec = this._pqEntry(pubkey);
            return !!(rec && rec.pk && rec.root);
        },

        // Fully PQ only when both ends' KEM keys are root-seeded; one nsec-derived copy suffices for an attacker.
        pqSealIsRootSeeded(peerPubkey) {
            return this.pqHasRoot() && this.pqPeerIsRootSeeded(peerPubkey);
        },

        // Can return null ("unknown yet"): a new peer's first message precedes their announcement.
        pqSealRootVerdict(peerPubkey) {
            // Before §6 settles, "no root" just means the load hasn't finished.
            if (!this.pqSupported()) return false;
            if (this.pqRootSettled() && !this.pqHasRoot()) return false;
            if (!this.pqRootSettled()) return null;
            const rec = this._pqEntry(peerPubkey);
            // A keyless pre-split row proves Nymchat but not the key, so ask rather than read it as legacy.
            if (!rec || !rec.pk) return null;
            return !!rec.root;
        },

        // No-op when we already know.
        pqResolveRootVerdict(peerPubkey, nymMessageId, apply) {
            if (this.pqSealRootVerdict(peerPubkey) !== null) return;
            const settle = () => {
                const v = this.pqSealRootVerdict(peerPubkey);
                if (v === null) return false;
                apply(v);
                if (typeof this.refreshMessagePqBadge === 'function') {
                    this.refreshMessagePqBadge(nymMessageId);
                }
                return true;
            };
            Promise.resolve(this.ensurePqAnnouncement(peerPubkey))
                .then(() => {
                    if (settle()) return;
                    this._pqWhenRootSettles(settle);
                })
                .catch(() => { });
        },

        // Polls, because settling happens inside the settings load with no event to subscribe to.
        _pqWhenRootSettles(fn) {
            if (this.pqRootSettled()) { try { fn(); } catch (_) { } return; }
            if (!Array.isArray(this._pqRootWaiters)) this._pqRootWaiters = [];
            if (this._pqRootWaiters.length >= 500) return;
            this._pqRootWaiters.push(fn);
            if (this._pqRootWaitTimer) return;
            let tries = 0;
            const tick = () => {
                this._pqRootWaitTimer = null;
                if (!this.pqRootSettled()) {
                    if (++tries > 60) { this._pqRootWaiters = []; return; }
                    this._pqRootWaitTimer = setTimeout(tick, 1000);
                    return;
                }
                const waiters = this._pqRootWaiters || [];
                this._pqRootWaiters = [];
                for (const w of waiters) { try { w(); } catch (_) { } }
            };
            this._pqRootWaitTimer = setTimeout(tick, 1000);
        },

        // Signature verification upstream binds the ML-KEM key to the Nostr identity.
        handlePqAnnouncement(event) {
            try {
                if (!event || !event.pubkey) return;
                let payload;
                try { payload = JSON.parse(event.content || '{}'); } catch (_) { return; }
                if (!payload || payload.alg !== PQ_ALG) return;

                const nowSec = Math.floor(Date.now() / 1000);
                // Nothing emits a retraction today, but a peer that does must be honored.
                if (payload.retracted) {
                    if (this.pqKeys) this.pqKeys.delete(event.pubkey);
                    if (event.pubkey === this.pubkey) this._pqSelfAnnouncement = null;
                    return;
                }
                const exp = parseInt(payload.exp, 10) || 0;
                if (exp <= nowSec) {
                    if (this.pqKeys) this.pqKeys.delete(event.pubkey);
                    return;
                }

                // Addressable: the newest wins, not the last to arrive (late keyless copies must not replace a key).
                const at = parseInt(event.created_at, 10) || 0;
                const held = this._pqEntry(event.pubkey);
                if (held && held.at > 0 && at > 0 && at < held.at) return;

                // No `pk` is still valid: it stops us sending a pointless Bitchat wrap.
                const readKey = (raw) => {
                    if (raw == null) return undefined;
                    let k;
                    try { k = window.NymCrypto._b64uDecode(raw); } catch (_) { return null; }
                    return (k instanceof Uint8Array && k.length === 1184) ? k : null;
                };
                const pk1 = readKey(payload.pk);
                const pk2 = readKey(payload.pk2);
                // A malformed key leaves the peer classical rather than half-configured.
                if (pk1 === null || pk2 === null) return;
                const pk = pk2 !== undefined ? pk2 : (pk1 !== undefined ? pk1 : null);

                this._pqRecord(event.pubkey, pk, exp, parseInt(payload.epoch, 10) || 0,
                    this._pqAnnouncementIsRootSeeded(payload),
                    // pk2 alone means the layered format only (a signer login).
                    { pq1: pk1 !== undefined, pq2: pk2 !== undefined },
                    at);
                if (event.pubkey === this.pubkey) {
                    this._pqSelfAnnouncement = payload;
                    // Our own announcement tells a freshly linked device which epoch the account is on.
                    this._pqAdoptAnnouncedEpoch();
                }
            } catch (_) { }
        },

        // The standing subscription (relays.js) covers existing conversations only; resolves either way.
        ensurePqAnnouncement(pubkey) {
            if (!pubkey || !this.pqEnabled()) return Promise.resolve(null);
            const known = this._pqEntry(pubkey);
            // Only a sendable (`pq2`) key ends the search; keyless or stale-vs-Bitchat entries ask again (rate-limited).
            const staleVsBitchat = known && known.at > 0
                && this.bitchatFormatSeenAt(pubkey) > known.at;
            if (known && known.pk && known.pq2 && !staleVsBitchat) {
                return Promise.resolve(known);
            }
            if (!this._pqFetches) this._pqFetches = new Map();

            const inflight = this._pqFetches.get(pubkey);
            // Rate-limited so a peer with no key isn't re-queried on every send.
            if (inflight) {
                if (inflight.promise) return inflight.promise;
                const nowSec = Math.floor(Date.now() / 1000);
                const keylessFresh = !!(known && !known.pk && known.at > 0 && nowSec - known.at < PQ_FRESH_KEYLESS_SEC);
                const wait = (inflight.miss || keylessFresh) ? PQ_RETRY_SOON_MS : PQ_REFETCH_MS;
                if (Date.now() - inflight.at < wait) return Promise.resolve(known || null);
            }

            // D1 first (see _pqAnnouncementFromD1); relays only when it has nothing.
            const viaD1 = this._pqAnnouncementFromD1(pubkey).then((entry) => {
                if (entry && entry.pk) {
                    this._pqFetches.set(pubkey, { at: Date.now() });
                    return entry;
                }
                return this._pqAnnouncementFromRelays(pubkey);
            });

            let settle;
            const bound = new Promise((res) => { settle = res; });
            const timer = setTimeout(() => settle(this._pqEntry(pubkey)), PQ_SEND_LOOKUP_BUDGET_MS);
            const bounded = Promise.race([viaD1, bound])
                .catch(() => this._pqEntry(pubkey))
                .then((v) => {
                    clearTimeout(timer);
                    // Stop later callers attaching to a settled promise, or the refetch window could never reopen.
                    const cur = this._pqFetches.get(pubkey);
                    if (cur && cur.promise === bounded) this._pqFetches.set(pubkey, { at: cur.at });
                    return v;
                });
            this._pqFetches.set(pubkey, { at: Date.now(), promise: bounded });
            return bounded;
        },

        _pqAnnouncementFromRelays(pubkey) {
            const subId = 'nym-pq-' + Math.random().toString(36).slice(2);
            if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();

            let settle;
            const promise = new Promise((res) => { settle = res; });
            let done = false;
            let answered = false;
            // Armed by the first EOSE; see the handler below.
            let grace = null;
            const finish = () => {
                if (done) return;
                done = true;
                if (grace !== null) { clearTimeout(grace); grace = null; }
                this._subscriptionHandlers.delete(subId);
                try { this.closeFewRelaysSub(subId); } catch (_) { }
                if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
                this._pqFetches.set(pubkey, answered ? { at: Date.now() } : { at: Date.now(), miss: true });
                settle(this._pqEntry(pubkey));
            };

            // An EOSE only starts a short grace period; an EVENT finishes immediately.
            this._subscriptionHandlers.set(subId, (type, data) => {
                if (type === 'EVENT' && data[0] === subId) {
                    const event = data[1];
                    // handleEvent ingests it; this only stops waiting.
                    if (event && event.kind === 30078 && event.pubkey === pubkey) {
                        answered = true;
                        try { this.handlePqAnnouncement(event); } catch (_) { }
                        finish();
                    }
                } else if (type === 'EOSE' && data[0] === subId) {
                    answered = true;
                    if (this._pqEntry(pubkey)) { finish(); return; }
                    if (grace === null) grace = setTimeout(finish, PQ_EOSE_GRACE_MS);
                }
            });

            this._pqFetches.set(pubkey, { at: Date.now(), promise });
            const req = ['REQ', subId, {
                kinds: [30078], '#t': [PQ_D_TAG], authors: [pubkey], limit: 1
            }];
            // The deadline starts now, not at the slot, so a busy one-shot queue can't hold a send indefinitely.
            setTimeout(finish, PQ_FETCH_TIMEOUT_MS);
            const run = () => {
                if (done) { // gave up before a slot came free
                    if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
                    return;
                }
                try { this.sendRequestToFewRelays(req); } catch (_) { finish(); }
            };
            if (typeof this._oneShotReqAcquire === 'function') this._oneShotReqAcquire(run);
            else run();
            return promise;
        },

        // D1 is a cache, not an authority: the signature is verified here exactly as for a relay event.
        async _pqAnnouncementFromD1(pubkey) {
            if (!this._getApiHost || !this._getApiHost()) return null;
            const fromWorker = await this._pqAnnouncementFromWorker(pubkey);
            if (fromWorker !== undefined) {
                return fromWorker ? this._pqAcceptArchived(pubkey, fromWorker) : null;
            }
            if (typeof this._storageApiStream !== 'function') return null;
            if (typeof this._readNdjsonStream !== 'function') return null;
            let found = null;
            try {
                const resp = await this._storageApiStream(
                    'channel-get', { channel: PQ_D_TAG, authors: [pubkey] }, false);
                await this._readNdjsonStream(resp, (ev) => {
                    if (!ev || ev.kind !== 30078 || ev.pubkey !== pubkey) return;
                    if (found && (found.created_at || 0) >= (ev.created_at || 0)) return;
                    found = ev;
                });
            } catch (_) { return null; }
            if (!found) return null;
            return this._pqAcceptArchived(pubkey, found);
        },

        async _pqAnnouncementFromWorker(pubkey) {
            if (typeof this._edgeFetch !== 'function') return undefined;
            const apiHost = this._getApiHost();
            const ctrl = typeof AbortController === 'function' ? new AbortController() : null;
            const timer = ctrl ? setTimeout(() => ctrl.abort(), PQ_FETCH_TIMEOUT_MS) : null;
            try {
                const resp = await this._edgeFetch(`https://${apiHost}/api/bot`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'pq-key', pubkey }),
                    ...(ctrl ? { signal: ctrl.signal } : {})
                });
                if (!resp || !resp.ok) return undefined;
                const data = await resp.json();
                if (!data || typeof data !== 'object' || !('event' in data)) return undefined;
                const ev = data.event;
                if (!ev || typeof ev !== 'object') return null;
                if (ev.kind !== 30078 || ev.pubkey !== pubkey) return null;
                return ev;
            } catch (_) {
                return undefined;
            } finally {
                if (timer) clearTimeout(timer);
            }
        },

        async _pqAcceptArchived(pubkey, ev) {
            try {
                const ok = typeof this._verifyRelayEventAsync === 'function'
                    ? await this._verifyRelayEventAsync(ev)
                    : (typeof this._verifyRelayEvent === 'function'
                        ? this._verifyRelayEvent(ev) : false);
                if (!ok) return null;
            } catch (_) { return null; }
            try { this.handlePqAnnouncement(ev); } catch (_) { return null; }
            return this._pqEntry(pubkey);
        },

        prefetchPqAnnouncements(pubkeys) {
            if (!pubkeys || !this.pqEnabled()) return;
            let n = 0;
            for (const pk of pubkeys) {
                if (!pk || !this._isNostrHex64 || !this._isNostrHex64(pk)) continue;
                if (++n > PQ_PREFETCH_MAX) break;
                this.ensurePqAnnouncement(pk);
            }
        },

        // Shared by both lookups so expiry is enforced in one place.
        _pqEntry(pubkey) {
            if (!pubkey || !this.pqKeys) return null;
            const rec = this.pqKeys.get(pubkey);
            if (!rec) return null;
            if (rec.exp <= Math.floor(Date.now() / 1000)) {
                this.pqKeys.delete(pubkey);
                return null;
            }
            return rec;
        },

        // The single send-path accessor: layered format only; null means send classical NIP-17.
        pqLayeredKeyFor(pubkey) {
            const rec = this._pqEntry(pubkey);
            if (!rec || !rec.pk || !rec.pq2) return null;
            return this.pqEnabled() ? rec.pk : null;
        },

        // 0 also means expired or never seen.
        pqAnnouncedAt(pubkey) {
            const rec = this._pqEntry(pubkey);
            return (rec && rec.at) || 0;
        },

        // Only the send plan needs the time; an entry with none reads as 0, the safe direction.
        bitchatFormatSeenAt(pubkey) {
            if (!pubkey || !this._bitchatSeenAt) return 0;
            return this._bitchatSeenAt.get(pubkey) || 0;
        },

        noteBitchatFormatSeen(pubkey, atSec) {
            if (!pubkey) return;
            if (!this.bitchatUsers) this.bitchatUsers = new Set();
            this.bitchatUsers.add(pubkey);
            if (!this._bitchatSeenAt) this._bitchatSeenAt = new Map();
            const ts = parseInt(atSec, 10) || 0;
            if (ts > (this._bitchatSeenAt.get(pubkey) || 0)) {
                this._bitchatSeenAt.set(pubkey, ts);
            }
            while (this._bitchatSeenAt.size > 5000) {
                this._bitchatSeenAt.delete(this._bitchatSeenAt.keys().next().value);
            }
        },

        pqKeyFor(pubkey) {
            if (!this.pqEnabled()) return null;
            const rec = this._pqEntry(pubkey);
            return (rec && rec.pk) || null;
        },

        // An unknown device counts as incapable; an empty roster means no second device.
        pqAllDevicesCapable() {
            const devices = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            if (devices.length === 0) return true;
            const nowSec = Math.floor(Date.now() / 1000);
            const selfId = this._pqDeviceId();
            for (const d of devices) {
                if (!d || d.id === selfId) continue;
                if ((nowSec - (d.ts || 0)) >= PQ_DEVICE_STALE_SEC) continue;
                if (d.pq !== 1) return false;
            }
            return true;
        },

        // Withheld unless every device can open the layered format.
        pqSelfKeyFor() {
            if (!this.pqSelfUsesPq2()) return null;
            if (!this.pqSelfEnabled()) return null;
            // Sealing to a key another of our devices can't derive locks it out of its settings.
            if (!this.pqAllDevicesCapable()) return null;
            // Derived, not read from the registry, so both sides use the same key from the first save.
            const keys = this.pqSelfKeys();
            return (keys && keys.publicKey) || null;
        },

        // Not gated on our own PQ setting: it answers "which client is this?".
        isKnownNymchatClient(pubkey) {
            return !!this._pqEntry(pubkey);
        },

        // The p-tag match is ordered first, so pairing more would multiply ML-KEM decapsulations for nothing.
        PQ_SK_PAIRING_LIMIT: 2,

        // A group wrap's ECDH and KEM legs use different keys, so pair each secp secret with our ML-KEM keypair.
        pqUnwrapCandidates(orderedSks) {
            if (!this.pqCapable()) return [];
            const epochs = this.pqSelfCandidates();
            if (!epochs.length) return [];
            const out = [];
            for (const sk of orderedSks.slice(0, this.PQ_SK_PAIRING_LIMIT)) {
                if (!sk) continue;
                for (const k of epochs) {
                    out.push({ sk, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk });
                }
            }
            return out;
        },

        // Keyed by the real pubkey: the announcement comes from the identity, not an ephemeral key.
        pqGroupKeyFor(memberRealPubkey) {
            // Layered only, like every other send path.
            return this.pqLayeredKeyFor(memberRealPubkey);
        },

        // A self-copy has to be readable by every device on the account.
        pqSelfUsesPq2() {
            const devices = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            const nowSec = Math.floor(Date.now() / 1000);
            const selfId = this._pqDeviceId();
            for (const d of devices) {
                if (!d || d.id === selfId) continue;
                if ((nowSec - (d.ts || 0)) >= PQ_DEVICE_STALE_SEC) continue;
                // Absent on builds that predate the split: those are pq1-only.
                if (d.pq2 !== 1) return false;
            }
            return true;
        },

        pqGroupUsesPq2(memberRealPubkey) {
            const rec = this._pqEntry(memberRealPubkey);
            return !!(rec && rec.pk && rec.pq2);
        },

        // Returns { pq, kemPk, bitchat, nym }; no announcement -> NIP-44 + Bitchat, `pk2` -> pq2 alone, else NIP-44.
        pqPmPlan(recipientPubkey) {
            // Choosing a format is an optimization; nothing here may fail the send.
            try {
                return this._pqPmPlan(recipientPubkey);
            } catch (e) {
                try { console.error('[PQ] send plan failed, falling back to dual-send', e); } catch (_) { }
                return {
                    pq: false, kemPk: null, pq2: false, rootSeeded: false,
                    bitchat: true, nym: true, provenNym: false
                };
            }
        },

        _pqPmPlan(recipientPubkey) {
            // Only ever the layered format; a pk-only peer gets ordinary NIP-44.
            const announced = this.pqLayeredKeyFor(recipientPubkey);
            const provenNym = this.isKnownNymchatClient(recipientPubkey);

            // Decrypted Bitchat-format evidence vs announcement: the newer one decides (`nymUsers` is deliberately ignored).
            const bitchatAt = this.bitchatFormatSeenAt(recipientPubkey);
            const announcedAt = this.pqAnnouncedAt(recipientPubkey);
            const knownBitchat = bitchatAt > 0 && !(announcedAt > 0 && announcedAt >= bitchatAt);

            // A live sealable key settles it: the Bitchat app cannot publish a kind-30078 announcement.
            const bitchat = announced ? false : (knownBitchat || !provenNym);

            // Never pair a PQ wrap with a Bitchat copy of the same plaintext; the copy is the easier target.
            const kemPk = bitchat ? null : announced;

            const rec = this._pqEntry(recipientPubkey);
            return {
                pq: !!kemPk,
                kemPk: kemPk || null,
                // The layered format whenever the peer accepts it; never a format the recipient cannot open.
                pq2: !!kemPk && !!(rec && rec.pq2),
                // Root-seeded peer key, for the badge only; not used for routing.
                rootSeeded: !!kemPk && this.pqPeerIsRootSeeded(recipientPubkey),
                bitchat,
                // Always: layered when the peer can open it, ordinary NIP-44 otherwise.
                nym: true,
                // Surfaced for tests and diagnostics; not used for routing.
                provenNym
            };
        },

        // Keyed by the shared Nymchat message id, bounded like the other per-message caches.
        _recordGroupPqCoverage(sharedId, pqCount, total, rootCount) {
            if (!sharedId || !total) return;
            if (!this.pqGroupCoverage) this.pqGroupCoverage = new Map();
            this.pqGroupCoverage.set(sharedId, {
                pq: pqCount, total, root: rootCount || 0
            });
            while (this.pqGroupCoverage.size > 2000) {
                this.pqGroupCoverage.delete(this.pqGroupCoverage.keys().next().value);
            }
        },

        pqGroupCoverageFor(sharedId) {
            return (this.pqGroupCoverage && this.pqGroupCoverage.get(sharedId)) || null;
        },

        // Sizes the group coverage readout and gates post-quantum self-archives.
        pqKnownPeers() {
            if (!this.pqKeys) return [];
            const nowSec = Math.floor(Date.now() / 1000);
            const out = [];
            for (const [pk, rec] of this.pqKeys) {
                // Only entries with a KEM key count; a KEM-less one is just a Nymchat client.
                if (rec.exp > nowSec && rec.pk) out.push(pk);
            }
            return out;
        },

        // Once, for upgraded installs; suppressed while the tutorial is pending.
        async maybeShowPqUpgradeNotice() {
            const linkPending = this.pqRootLinkPromptPending();
            const revealPending = this.pqRootRevealPending() && this.pqHasRoot();
            if (!this.pqUpgradeNoticePending() && !linkPending && !revealPending) return;
            if (this._pqNoticeOpen) return;
            // A locked device is not `pqCapable`, so the capability gate must not swallow its prompt.
            if (!linkPending && !this.pqCapable()) { this.dismissPqUpgradeNotice(); return; }
            if (this._pqTutorialPending()) { this.dismissPqUpgradeNotice(); return; }
            this.dismissPqUpgradeNotice();
            const linkNeeded = this.pqRootLinkNeeded();
            if (linkNeeded) this.dismissPqRootLinkPrompt();
            else if (revealPending) this.dismissPqRootReveal();
            this._pqNoticeOpen = true;
            const body = linkNeeded
                ? 'This account already has a post-quantum recovery code, and this '
                  + 'device does not have it yet.\n\nUntil you add it, this device '
                  + 'keeps working normally but cannot read the quantum-resistant '
                  + 'messages your other devices can.\n\nPaste the nympq1\u2026 code '
                  + 'from a device that has it \u2014 you will find it there under '
                  + 'View or Edit Nym\u2019s Details. You can also do this later, '
                  + 'in that same panel.'
                : 'Your private messages and group chats with other Nymchat users are now '
                  + 'encrypted with an added post-quantum key exchange (ML-KEM-768), so traffic '
                  + 'recorded today can\u2019t be decrypted later by a quantum computer.\n\n'
                  + 'This uses a recovery code, not your nsec. Save the code below '
                  + 'alongside your nsec \u2014 you will need it to read these messages on '
                  + 'another device, and if every device holding it is lost, they cannot be '
                  + 'recovered. It is always available in your Nym\u2019s details.\n\n'
                  + 'Bitchat users and other Nostr clients are unaffected.';
            const code = linkNeeded ? null : (this.pqRootCode ? this.pqRootCode() : null);
            try {
                if (linkNeeded) {
                    const pasted = await window.showAppPrompt(body, {
                        title: 'Add your post-quantum recovery code',
                        okLabel: 'Link this device',
                        cancelLabel: 'Later',
                        placeholder: 'nympq1\u2026'
                    });
                    const trimmed = (pasted || '').trim();
                    if (!trimmed) return;
                    const ok = typeof this.pqRootLinkWithCode === 'function'
                        && this.pqRootLinkWithCode(trimmed);
                    if (ok) {
                        try { await this.publishPqAnnouncement(); } catch (_) { }
                        if (typeof this.reloadSettingsAfterPqLink === 'function') {
                            try { await this.reloadSettingsAfterPqLink(); } catch (_) { }
                        }
                    }
                    await window.showAppAlert(ok
                        ? 'Linked. This device can now read your quantum-resistant messages.'
                        : 'That code does not match this account. Check it and try again \u2014 you can also paste it in View or Edit Nym\u2019s Details.',
                        { title: ok ? 'Linked' : 'That code did not match', okLabel: 'Got it' });
                    return;
                }
                await window.showAppAlert(body, {
                    title: 'Quantum-resistant encryption is on',
                    okLabel: 'Got it',
                    copyValue: code || undefined,
                    copyLabel: 'Copy code',
                    copySecret: true
                });
            } catch (_) { /* dialog unavailable; the notice is not load-bearing */ }
            finally { this._pqNoticeOpen = false; }
        },

        /// Whether the tutorial is still ahead of this user.
        _pqTutorialPending() {
            try { return localStorage.getItem('nym_tutorial_seen') !== 'true'; }
            catch (_) { return false; }
        },

        // Newest first; informational only.
        pqDeviceRoster() {
            const devices = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            const selfId = this._pqDeviceId();
            return devices.map(d => ({ ...d, isSelf: d.id === selfId }));
        },

        // Names the first failing term of `_pqPmPlan`, in evaluation order.
        pqPeerDiagnosis(pubkey) {
            if (!pubkey) return 'no pubkey';
            if (!this.pqSupported()) return 'ML-KEM did not load on this device';
            if (this._pqMode() === 'off') return 'nym_pq_mode is off in local storage';
            const rec = this._pqEntry(pubkey);
            if (!rec) {
                const f = this._pqFetches && this._pqFetches.get(pubkey);
                if (f && f.promise) return 'their announcement is being looked up now';
                if (f) {
                    const age = Math.round((Date.now() - f.at) / 1000);
                    return `no announcement found (looked ${age}s ago; retries after `
                        + `${Math.round(PQ_REFETCH_MS / 1000)}s)`;
                }
                return 'no announcement held, and none has been looked up yet';
            }
            if (!rec.pk) return 'their announcement carries no ML-KEM key';
            if (!rec.pq2) {
                return 'their announcement offers only the legacy format '
                    + '(pk without pk2), which is never sent';
            }
            // A live layered key settles it, since the Bitchat app cannot publish an announcement.
            return 'post-quantum';
        },

        pqDiagnostics() {
            const nowSec = Math.floor(Date.now() / 1000);
            const self = {
                supported: this.pqSupported(),
                capable: this.pqCapable(),
                sendCapable: this.pqSendCapable(),
                enabled: this.pqEnabled(),
                pq1Capable: this.pq1Capable(),
                mode: this._pqMode(),
                rootHeld: this.pqHasRoot(),
                rootSettled: this.pqRootSettled(),
                rootLocked: this.pqRootLocked(),
                rootFingerprint: this.pqRootFingerprint() || null,
                epoch: this._pqEpoch(),
                lastPublishAgoSec: this._pqLastPublishAt
                    ? Math.round((Date.now() - this._pqLastPublishAt) / 1000) : null,
                lastPublishHadKey: !!(this._pqSelfAnnouncement
                    && (this._pqSelfAnnouncement.pk2 || this._pqSelfAnnouncement.pk)),
                devices: this.pqDeviceRoster().length
            };
            const peers = [];
            const seen = new Set();
            const add = (pk) => {
                if (!pk || seen.has(pk) || pk === this.pubkey) return;
                seen.add(pk);
                const rec = this._pqEntry(pk);
                const plan = this.pqPmPlan(pk);
                peers.push({
                    pubkey: pk,
                    nym: this.getNymFromPubkey ? this.getNymFromPubkey(pk) : pk.slice(-8),
                    entry: rec ? {
                        key: !!rec.pk, pq1: !!rec.pq1, pq2: !!rec.pq2, root: !!rec.root,
                        expiresInSec: rec.exp - nowSec, announcedAgoSec: rec.at ? nowSec - rec.at : null
                    } : null,
                    bitchatSeenAgoSec: this.bitchatFormatSeenAt(pk)
                        ? nowSec - this.bitchatFormatSeenAt(pk) : null,
                    plan: { pq: !!plan.pq, pq2: !!plan.pq2, bitchat: !!plan.bitchat, provenNym: !!plan.provenNym },
                    why: this.pqPeerDiagnosis(pk)
                });
            };
            if (this.pmConversations) for (const pk of this.pmConversations.keys()) add(pk);
            peers.sort((a, b) => (a.plan.pq === b.plan.pq) ? 0 : (a.plan.pq ? 1 : -1));
            return { self, peers };
        },

        // Read on demand: a stale readout is worse than none.
        refreshPqDiagnostics() {
            const el = document.getElementById('pqDiagnosticsBody');
            if (!el) return;
            let text;
            try {
                const d = this.pqDiagnostics();
                const s = d.self;
                const lines = [
                    `supported=${s.supported} capable=${s.capable} sendCapable=${s.sendCapable} enabled=${s.enabled}`,
                    `pq1Capable=${s.pq1Capable} mode=${s.mode} epoch=${s.epoch} devices=${s.devices}`,
                    `root: held=${s.rootHeld} settled=${s.rootSettled} locked=${s.rootLocked} fp=${s.rootFingerprint || '-'}`,
                    `announced: ${s.lastPublishAgoSec === null ? 'never this session' : s.lastPublishAgoSec + 's ago'}`
                        + ` withKey=${s.lastPublishHadKey}`,
                    '',
                    `${d.peers.length} PM contact${d.peers.length === 1 ? '' : 's'}:`
                ];
                for (const p of d.peers) {
                    const e = p.entry;
                    lines.push(
                        `  ${p.nym} ${p.pubkey.slice(0, 8)}… -> ${p.plan.pq ? 'POST-QUANTUM' : 'classical'}`,
                        `    ${p.why}`,
                        `    entry=${e ? `key=${e.key} pq1=${e.pq1} pq2=${e.pq2} root=${e.root}`
                            + ` expiresIn=${e.expiresInSec}s announced=${e.announcedAgoSec}s ago` : 'none'}`,
                        `    bitchatSeen=${p.bitchatSeenAgoSec === null ? 'never' : p.bitchatSeenAgoSec + 's ago'}`
                            + ` plan(bitchat=${p.plan.bitchat} provenNym=${p.plan.provenNym})`
                    );
                }
                text = lines.join('\n');
            } catch (e) {
                text = 'diagnostics failed: ' + (e && e.message);
            }
            el.textContent = text;
        },

        copyPqDiagnostics() {
            const el = document.getElementById('pqDiagnosticsBody');
            if (!el || !el.textContent) return;
            const done = () => { if (typeof this.showToast === 'function') this.showToast('Diagnostics copied'); };
            try { navigator.clipboard.writeText(el.textContent).then(done).catch(() => { }); }
            catch (_) { }
        }
    });
})();
