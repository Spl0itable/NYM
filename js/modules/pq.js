// pq.js — hybrid post-quantum key announcement, discovery, and policy.

(function () {
    const PQ_D_TAG = 'nym-pq';
    const PQ_ALG = 'mlkem768';
    // Announcements expire so a downgraded or abandoned device stops attracting
    // PQ messages it cannot read. Republished well inside the window.
    const PQ_TTL_SEC = 7 * 24 * 3600;
    /// How long "this peer has no announcement" is trusted before asking again.
    const PQ_REFETCH_MS = 10 * 60 * 1000;
    /// A one-shot lookup gives up after this and the message goes classical.
    const PQ_FETCH_TIMEOUT_MS = 2500;
    /// How long a SEND may wait on a lookup. Shorter than the relay deadline:
    /// a message that goes classical is a missed upgrade, one that never leaves
    /// is gone.
    const PQ_SEND_LOOKUP_BUDGET_MS = 1500;
    /// How long to keep listening after the FIRST relay says it has nothing —
    /// one relay's "done" is one vote out of five, not the answer.
    const PQ_EOSE_GRACE_MS = 600;
    /// Cap on a prefetch sweep, so a large group is not one sub per member.
    const PQ_PREFETCH_MAX = 60;
    const PQ_REPUBLISH_SEC = 24 * 3600;
    /// Announce delay after connecting. Matches the DM catch-up window, so our
    /// own announcement has arrived and its device roster is merged, not lost.
    const PQ_ANNOUNCE_DELAY_MS = 3000;
    // Devices unseen for this long drop off the roster shown in settings.
    const PQ_DEVICE_STALE_SEC = 30 * 24 * 3600;
    // The root's bech32 code on this device, in _VAULT_KEYS (spec §5.3).
    const PQ_ROOT_LS_KEY = 'nym_pq_root';

    Object.assign(NYM.prototype, {

        PQ_D_TAG,
        PQ_TTL_SEC,
        PQ_ROOT_LS_KEY,

        // capability + policy
        /// Whether the ML-KEM implementation loaded at all.
        pqSupported() {
            return !!(window.NymCrypto && window.NymCrypto.pqAvailable && window.NymCrypto.pqAvailable());
        },

        /// Whether we can RECEIVE post-quantum, and so announce an ML-KEM key.
        /// The root suffices: under pq2 the decapsulation key derives from it,
        /// and the inner NIP-44 is done by whatever holds the identity key, a
        /// signer included. An nsec qualifies too, for the legacy pq1 keys.
        pqCapable() {
            return this.pqSupported() && (this.pqHasRoot() || !!this.privkey);
        },

        /// Whether we can open the LEGACY combined format. It mixes in the raw
        /// ECDH output, which no signer returns, so this one needs the nsec.
        pq1Capable() {
            return this.pqSupported() && !!this.privkey;
        },

        /// Whether we can SEND post-quantum — a weaker requirement. Of NIP-17's
        /// two layers only the seal needs the signer, so an extension or NIP-46
        /// login can still hybridize the wrap, and the wrap is what a recorder
        /// stores. Not symmetric with pqCapable(): such a login sends
        /// post-quantum but receives classical, which is half a conversation
        /// and worth having.
        pqSendCapable() {
            return this.pqSupported();
        },

        /// Whether we send post-quantum to peers who can receive it. No user
        /// setting: it is simply how Nymchat talks to Nymchat, and only being
        /// unable to do it turns it off.
        pqEnabled() {
            return this.pqSendCapable() && this._pqMode() !== 'off';
        },

        /// Whether our own copies — self-wraps, archive, synced settings — can
        /// be post-quantum. Addressed to us, so it is the receive-side
        /// question: a key we cannot decapsulate locks us out of our history.
        pqSelfEnabled() {
            return this.pqCapable() && this._pqMode() !== 'off';
        },

        /// An UNDOCUMENTED escape hatch, absent by default and never written by
        /// the app: a field bug can be defused by telling affected users to set
        /// `nym_pq_mode` to 'off' rather than waiting on a release.
        _pqMode() {
            try { return localStorage.getItem('nym_pq_mode') || 'on'; }
            catch (_) { return 'on'; }
        },

        /// True when this install was upgraded into post-quantum rather than
        /// starting with it, and the user has not been told yet.
        pqUpgradeNoticePending() {
            try { return localStorage.getItem('nym_pq_upgrade_notice') === 'pending'; }
            catch (_) { return false; }
        },

        dismissPqUpgradeNotice() {
            try { localStorage.removeItem('nym_pq_upgrade_notice'); } catch (_) { }
        },

        /// Whether this device still needs to be told to paste the code.
        /// Separate from the upgrade notice, which is armed only for upgrades:
        /// the device that most needs this is a fresh install joining an
        /// account that already has a root. Keyed per account and cleared once
        /// shown, so it is a prompt rather than a nag.
        pqRootLinkPromptPending() {
            if (!this.pqRootLinkNeeded()) return false;
            try {
                return localStorage.getItem(`nym_pq_link_prompt_${this.pubkey}`) !== 'shown';
            } catch (_) { return false; }
        },

        dismissPqRootLinkPrompt() {
            try { localStorage.setItem(`nym_pq_link_prompt_${this.pubkey}`, 'shown'); } catch (_) { }
        },

        /// Marks an upgrade so the one-time notice fires once, at boot.
        /// `nym_last_online_ts` is written by every prior version, so its
        /// presence tells an upgrade from a fresh install — and only an upgrade
        /// has an older device on the same npub to strand.
        _pqMarkUpgradeIfNeeded() {
            try {
                if (localStorage.getItem('nym_pq_upgrade_seen')) return;
                localStorage.setItem('nym_pq_upgrade_seen', '1');
                if (localStorage.getItem('nym_last_online_ts')) {
                    localStorage.setItem('nym_pq_upgrade_notice', 'pending');
                }
            } catch (_) { }
        },

        // our own key epoch
        _pqEpoch() {
            try { return parseInt(localStorage.getItem('nym_pq_epoch') || '0', 10) || 0; }
            catch (_) { return 0; }
        },

        // the root secret — docs/PQ-ROOT-SPEC.md

        /// Reads through the secret accessors so the at-rest vault covers the
        /// root exactly as it covers the nsec.
        _pqRootStoredCode() {
            try {
                if (typeof window !== 'undefined' && typeof window.nymSecretGet === 'function') {
                    return window.nymSecretGet(PQ_ROOT_LS_KEY);
                }
            } catch (_) { }
            try { return localStorage.getItem(PQ_ROOT_LS_KEY); } catch (_) { return null; }
        },

        _pqRootStoreCode(code) {
            try {
                if (typeof window !== 'undefined' && typeof window.nymSecretSet === 'function') {
                    window.nymSecretSet(PQ_ROOT_LS_KEY, code);
                    return;
                }
            } catch (_) { }
            try { localStorage.setItem(PQ_ROOT_LS_KEY, code); } catch (_) { }
        },

        /// The root this device holds, or null. Cached once decoded.
        pqRoot() {
            if (this._pqRootBytes) return this._pqRootBytes;
            const code = this._pqRootStoredCode();
            if (!code) return null;
            try {
                const bytes = window.NymCrypto.pqRootDecode(code);
                this._pqRootBytes = bytes;
                this._pqRootUnreadable = false;
                return bytes;
            } catch (_) {
                // Stored but unreadable (locked vault, corrupt value) is NOT
                // "no root" — generating over it would discard the real one.
                this._pqRootUnreadable = true;
                return null;
            }
        },

        pqHasRoot() { return !!this.pqUsableRoot(); },

        /// The root we may derive keys FROM, not merely the bytes we store. A
        /// locked device holds one that does not open this account's record, so
        /// sealing to it writes history the real devices cannot read. The
        /// announcement is already withheld while locked; this withholds the key.
        pqUsableRoot() {
            if (this._pqRootLocked) return null;
            return this.pqRoot();
        },

        /// The `nympq1...` code, for the reveal/copy surface beside the nsec.
        pqRootCode() {
            // The usable one: a locked device must not offer a stale root as
            // "your recovery code". It gets the link prompt instead.
            const r = this.pqUsableRoot();
            if (!r) return null;
            try { return window.NymCrypto.pqRootEncode(r); } catch (_) { return null; }
        },

        pqRootFingerprint() {
            const r = this.pqRoot();
            if (!r) return null;
            try { return window.NymCrypto.pqRootFingerprint(r); } catch (_) { return null; }
        },

        /// The only way a root is installed — generation, pasted code and
        /// every unwrap path funnel through here so caches clear in one place.
        pqRootAdopt(rootBytes) {
            const NC = window.NymCrypto;
            if (!NC || !NC.pqIsRoot(rootBytes)) return false;
            const code = NC.pqRootEncode(rootBytes);
            this._pqRootBytes = rootBytes;
            this._pqRootStoreCode(code);
            this._pqRootLocked = false;
            this._pqSelfCache = null;
            return true;
        },

        /// Destroys the root here. Panic wipe and forget-identity call it:
        /// a root outliving its identity is a liability with no owner.
        pqRootWipe() {
            this._pqRootBytes = null;
            this._pqSelfCache = null;
            this._pqRootLocked = false;
            this._pqRootRecord = null;
            try {
                if (typeof window !== 'undefined' && typeof window.nymSecretRemove === 'function') {
                    window.nymSecretRemove(PQ_ROOT_LS_KEY);
                    return;
                }
            } catch (_) { }
            try { localStorage.removeItem(PQ_ROOT_LS_KEY); } catch (_) { }
        },

        /// A record exists that this device cannot open. It must not
        /// generate a root and must not announce (spec §7).
        pqRootLocked() { return !!this._pqRootLocked; },

        /// Whether §6 has run. Until it has, this device does not know whether
        /// the account has a root, so any key it announces is nsec-derived by
        /// default rather than by decision.
        pqRootSettled() { return !!this._pqRootSettled; },

        /// Same condition, named for the "link this device" prompt.
        pqRootLinkNeeded() { return this.pqRootLocked(); },

        /// Whether our own key is root-seeded, i.e. whether we may announce
        /// `v:2, src:"root"`.
        pqRootSeeded() { return this.pqCapable() && this.pqHasRoot(); },

        /// The `nymchat-pq-root` record. `wraps` may be empty: the record
        /// still says a root EXISTS, which is what silences other devices.
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

        /// A stored record only counts if it is actually a v2 root record.
        _pqRootValidRecord(record) {
            return !!(record && typeof record === 'object'
                && record.v === 2 && typeof record.fp === 'string' && record.fp);
        },

        /// The wraps from the record we last read.
        pqRootRecordWraps() {
            const rec = this._pqRootRecord;
            return (rec && Array.isArray(rec.wraps)) ? rec.wraps : [];
        },

        /// Spec §6. `record` is the decrypted `nymchat-pq-root` payload, or
        /// null when the account has none. Returns 'unavailable' (no local
        /// key), 'adopted', 'locked' (record we cannot open — do not generate,
        /// do not announce), 'publish-record' (we hold the root but the account
        /// has no record row, so the caller must write one) or 'generated'.
        /// `rowPresent` is the D1 row's existence, independent of whether it
        /// decrypted. A row we cannot read is still proof a root exists, and
        /// generating over it splits the account.
        pqRootEnsure(record, rowPresent) {
            // Deliberately pqSupported, not pqCapable: for a signer login the
            // root is what makes it capable, so gating on capability here
            // would be a deadlock — never capable, so never a root.
            if (!this.pqSupported()) return 'unavailable';
            this._pqRootSettled = true;
            this._pqRootRecord = this._pqRootValidRecord(record) ? record : null;
            const NC = window.NymCrypto;
            const mine = this.pqRoot();

            if (this._pqRootRecord) {
                if (mine && NC.pqRootFingerprint(mine) === this._pqRootRecord.fp) {
                    this._pqRootLocked = false;
                    return 'adopted';
                }
                // Nothing, or a different root (a stale one from a reset
                // identity). Both mean "cannot open this record".
                this._pqRootLocked = true;
                return 'locked';
            }

            // No record, but we hold a root: either the write has not landed
            // yet, or an earlier launch's record write failed and nothing ever
            // retried it. The second case strands the account — with no row
            // every other device mints a RIVAL root under §6.4 — so say which
            // case this is and let the caller re-publish.
            if (mine) {
                this._pqRootLocked = false;
                return 'publish-record';
            }
            // Bytes are there, this session just cannot see them.
            if (this._pqRootUnreadable) {
                this._pqRootLocked = true;
                return 'locked';
            }
            // A record exists that we could not open or could not parse.
            if (rowPresent) {
                this._pqRootLocked = true;
                return 'locked';
            }

            let fresh;
            try { fresh = NC.pqGenerateRoot(); } catch (_) { return 'unavailable'; }
            if (!this.pqRootAdopt(fresh)) return 'unavailable';
            // Surfaced to the user once (spec §9).
            try { localStorage.setItem('nym_pq_root_reveal', 'pending'); } catch (_) { }
            return 'generated';
        },

        /// Drives the one-time "here is your recovery code" surface.
        pqRootRevealPending() {
            try { return localStorage.getItem('nym_pq_root_reveal') === 'pending'; }
            catch (_) { return false; }
        },

        dismissPqRootReveal() {
            try { localStorage.removeItem('nym_pq_root_reveal'); } catch (_) { }
        },

        // our own key
        /// Our ML-KEM keypair: root-seeded when we hold a root, nsec-seeded
        /// otherwise. Cached per (pubkey, epoch, seed source).
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

        /// Rotates our ML-KEM key and republishes. Peers pick the new key up
        /// from the replaceable announcement; messages already in flight to the
        /// old key stay readable because the previous keypair is still
        /// derivable from the nsec at the previous epoch.
        async rotatePqKey() {
            const next = this._pqEpoch() + 1;
            try { localStorage.setItem('nym_pq_epoch', String(next)); } catch (_) { }
            this._pqSelfCache = null;
            if (this.pqSelfEnabled()) await this.publishPqAnnouncement();
        },

        /// Decrypt candidates (spec §4): root-derived epoch..epoch-3, then
        /// nsec-derived epoch..epoch-3. The nsec half is PERMANENT, not a
        /// migration window — everything sealed under v1 needs it. Dropping
        /// it is a data-loss bug, not a cleanup.
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

        // announcement
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

        /// Merges this device into the roster our announcement carries,
        /// dropping entries unseen for PQ_DEVICE_STALE_SEC. Its `pq` flag says
        /// whether this device can DECAPSULATE, which decides whether copies
        /// addressed to the account may be sealed hybrid at all
        /// (pqAllDevicesCapable); it never gates DECRYPTION.
        _pqMergeDeviceRoster(nowSec) {
            const id = this._pqDeviceId();
            const prev = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            const out = prev.filter(d => d && d.id !== id && (nowSec - (d.ts || 0)) < PQ_DEVICE_STALE_SEC);
            out.push({
                id, ver: this._pqAppVersion(), ts: nowSec,
                pq: this.pqCapable() ? 1 : 0,
                // Separate from `pq`: a signer opens the layered format but
                // never the combined one, so a pq1 self-copy would lock it out
                // of its own settings and archive.
                pq2: this.pqCapable() ? 1 : 0
            });
            out.sort((a, b) => (b.ts || 0) - (a.ts || 0));
            return out.slice(0, 16);
        },

        /// Publishes our capability announcement. EVERY Nymchat client does,
        /// not only post-quantum-capable ones: its presence is signed proof
        /// that a pubkey runs Nymchat, which is what lets the send path skip
        /// the speculative Bitchat wrap. The key rides along only when usable,
        /// so the two claims stay independent:
        ///
        ///   announcement + `pk`  -> Nymchat, post-quantum
        ///   announcement, no pk  -> Nymchat, classical (PQ off, or a device
        ///                           not yet linked to the root)
        ///   no announcement      -> unknown; could be Bitchat or any other
        ///                           Nostr client
        async publishPqAnnouncement() {
            try {
                if (!this.connected || !this.pubkey) return false;
                // Spec §7: the announcement is replaceable, so a device that
                // cannot open the account's root would clobber the real one.
                if (this.pqRootLocked()) return false;
                // A KEM key only when we can decapsulate with it, and only once
                // §6 has decided where it comes from: on a fresh account the
                // settings load that generates the root has not finished when
                // this first fires, and announcing anyway pins peers to an
                // nsec-derived key for the whole TTL. `nym: 1` still goes out,
                // so we stay a known Nymchat client that simply has no key yet,
                // and a keyless entry does not end their lookup — see
                // ensurePqAnnouncement.
                const keys = (this.pqSelfEnabled() && this.pqRootSettled())
                    ? this.pqSelfKeys() : null;
                // Only true when the key we are publishing IS root-derived.
                const rootSeeded = !!keys && this.pqRootSeeded();

                // Kind 30078 is addressable (NIP-01): one event per (kind,
                // pubkey, d-tag), replaced by created_at, and on a TIE the relay
                // keeps the lexically-lower id — so a republish in the same
                // second can be dropped silently, leaving peers on a stale key
                // (rotatePqKey right after a boot publish is exactly that). Same
                // monotonic floor the kind-0 profile save uses.
                const nowSec = Math.max(
                    Math.floor(Date.now() / 1000),
                    (this._pqLastPublishTs || 0) + 1
                );
                this._pqLastPublishTs = nowSec;
                const exp = nowSec + PQ_TTL_SEC;
                const payload = {
                    // v:2 + src:"root" claims independently seeded entropy;
                    // without a root we are v1 and must say so (spec §3).
                    v: rootSeeded ? 2 : 1,
                    ...(rootSeeded ? { src: 'root' } : {}),
                    alg: PQ_ALG,
                    // A Nymchat client, with or without a KEM key. Parsed
                    // separately from `pk` so "Nymchat, no post-quantum" is
                    // distinguishable from a retraction.
                    nym: 1,
                    epoch: this._pqEpoch(),
                    // Two different claims. `pk` means "seal with EITHER
                    // format", which only an nsec login can say since the
                    // combined one needs the raw ECDH output to open. `pk2`
                    // means "the layered format only" — a signer login says just
                    // this, and an older build that has never heard of pk2 falls
                    // back to plain NIP-44, which a signer CAN read. That
                    // degrade is the point of the split.
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
                        // NIP-40 so relays can drop a stale announcement on
                        // their own, not just clients.
                        ['expiration', String(exp)]
                    ],
                    content: JSON.stringify(payload),
                    pubkey: this.pubkey
                };
                const signed = await this.signEvent(event);
                this.sendToRelay(['EVENT', signed]);
                this._pqSelfAnnouncement = payload;
                // Kept for the Nymbot worker: the bot PM request carries this
                // signed event, so the reply can seal to our KEM key without
                // depending on a lookup finding it.
                this._pqSelfSignedAnnouncement = signed;
                this._pqLastPublishAt = Date.now();
                // Record our own entry so self-addressed wraps resolve through
                // the same lookup as everyone else's.
                this._pqRecord(this.pubkey, keys ? keys.publicKey : null, exp, payload.epoch, rootSeeded);
                return true;
            } catch (_) {
                return false;
            }
        },

        /// Stops advertising a key without withdrawing the Nymchat claim.
        /// Republishing WITHOUT a `pk` is the retraction: peers stop
        /// encapsulating but still skip the Bitchat wrap. Publishing an expired
        /// announcement would throw that away.
        async retractPqAnnouncement() {
            return this.publishPqAnnouncement();
        },

        /// Schedules our announcement for shortly after connecting, at most
        /// once per pending window.
        schedulePqAnnouncement() {
            if (this._pqAnnounceTimer) return;
            this._pqAnnounceTimer = setTimeout(async () => {
                this._pqAnnounceTimer = null;
                try {
                    if (!this.pubkey) return;
                    // §6 is answered by ONE completed settings read, and until
                    // then publishPqAnnouncement withholds the key. A boot read
                    // that failed left the whole session announcing `nym:1` with
                    // nothing re-asking, so every peer fell back to classical
                    // until a reload got a good read. Every connect is a chance
                    // to settle it.
                    await this.pqRootRetryIfUnsettled();
                    // Not gated on pqEnabled(): every Nymchat client announces
                    // itself, post-quantum or not, because the announcement is
                    // also what tells peers to skip the Bitchat wrap.
                    if (!this._pqLastPublishAt) this.publishPqAnnouncement();
                    else this.maybeRepublishPqAnnouncement();
                    this._pqMarkUpgradeIfNeeded();
                    this.maybeShowPqUpgradeNotice();
                } catch (_) { }
            }, PQ_ANNOUNCE_DELAY_MS);
        },

        /// Re-asks §6 when the boot settings read never answered it.
        /// `pqRootEnsure` runs only from a completed `settingsLoadFromD1`, so a
        /// failed read leaves the whole session unsettled and rootless. Bounded
        /// to one attempt a minute so an unreachable API is not hammered.
        async pqRootRetryIfUnsettled() {
            if (typeof this.pqRootSettled !== 'function' || this.pqRootSettled()) return false;
            if (typeof this.settingsLoadFromD1 !== 'function') return false;
            const now = Date.now();
            if (this._pqRootRetryAt && now - this._pqRootRetryAt < 60000) return false;
            this._pqRootRetryAt = now;
            try { await this.settingsLoadFromD1(); } catch (_) { }
            return this.pqRootSettled();
        },

        /// Republishes on a daily cadence so the 7-day expiry never lapses
        /// while the client is in use. Not gated on post-quantum being on:
        /// letting a KEM-less announcement expire would make us look like a
        /// non-Nymchat client again and start attracting Bitchat wraps.
        maybeRepublishPqAnnouncement() {
            if (!this.pubkey) return;
            const since = Date.now() - (this._pqLastPublishAt || 0);
            if (since < PQ_REPUBLISH_SEC * 1000) return;
            this.publishPqAnnouncement();
        },

        // peer keys
        /// Records a capability entry. `pk` may be null — that still means
        /// "this pubkey runs Nymchat", which is the signal the send path uses
        /// to skip the Bitchat wrap.
        /// `root` is the §3 claim: v:2 AND src=="root". Anything else is
        /// recorded as legacy, because the badge reports the truth.
        _pqRecord(pubkey, pk, exp, epoch, root, fmt, at) {
            if (!this.pqKeys) this.pqKeys = new Map();
            // Absent `fmt` means an entry recorded before the split (or by our
            // own self-record): assume the legacy format only, which is what
            // every such entry actually was.
            this.pqKeys.set(pubkey, {
                pk: pk || null, exp, epoch, root: !!root,
                pq1: fmt ? !!fmt.pq1 : true,
                pq2: fmt ? !!fmt.pq2 : false,
                // WHEN they said it: the send plan weighs this against other
                // evidence from other moments — see `_pqPmPlan`. Derived from
                // the expiry for an entry an older build restored, which is
                // exactly `created_at` since `exp` is stamped `now + TTL`.
                at: at || (exp ? exp - PQ_TTL_SEC : 0)
            });
            // Ride the same debounced write the other dedup sets use, so a
            // reload does not send classically while it looks every peer up
            // again. Restoring is bounded by the expiry — see _hydratePqKeys.
            if (typeof this._persistDedupSets === 'function') this._persistDedupSets();
            // Every write goes through this one bound. Map preserves insertion
            // order, so the evicted entry is the earliest-recorded one.
            while (this.pqKeys.size > 5000) {
                this.pqKeys.delete(this.pqKeys.keys().next().value);
            }
        },

        /// Spec §3. Exact and positive: `v` is the NUMBER 2 and `src` the
        /// STRING "root". Everything else, unknown src included, is legacy.
        _pqAnnouncementIsRootSeeded(payload) {
            return !!payload && payload.v === 2 && payload.src === 'root';
        },

        /// Whether a peer's live announcement is root-seeded, for the badge.
        pqPeerIsRootSeeded(pubkey) {
            const rec = this._pqEntry(pubkey);
            return !!(rec && rec.pk && rec.root);
        },

        /// A seal is fully post-quantum only when BOTH ends' KEM keys are
        /// root-seeded. The same plaintext exists in a copy under each, so one
        /// nsec-derived key is enough for an adversary who breaks secp256k1.
        pqSealIsRootSeeded(peerPubkey) {
            return this.pqHasRoot() && this.pqPeerIsRootSeeded(peerPubkey);
        },

        /// Same question, able to answer "I don't know yet". A new peer's first
        /// message arrives before their announcement, and reading that absence
        /// as legacy marked every opening message legacy. Unknown is not
        /// legacy; it is a lookup that has not landed.
        pqSealRootVerdict(peerPubkey) {
            if (!this.pqHasRoot()) return false;      // our own half settles it
            const rec = this._pqEntry(peerPubkey);
            if (!rec) return null;
            return !!(rec.pk && rec.root);
        },

        /// Resolves a pending verdict once the peer's announcement lands, then
        /// repaints that one row. No-op when we already know.
        pqResolveRootVerdict(peerPubkey, nymMessageId, apply) {
            if (this.pqSealRootVerdict(peerPubkey) !== null) return;
            Promise.resolve(this.ensurePqAnnouncement(peerPubkey))
                .then(() => {
                    const v = this.pqSealRootVerdict(peerPubkey);
                    if (v === null) return;
                    apply(v);
                    if (typeof this.refreshMessagePqBadge === 'function') {
                        this.refreshMessagePqBadge(nymMessageId);
                    }
                })
                .catch(() => { });
        },

        /// Ingests a peer's kind-30078 'nym-pq' announcement. Relay events are
        /// signature-verified upstream, which is what binds the ML-KEM key to
        /// the Nostr identity: an attacker cannot substitute their own KEM key
        /// without also forging a secp256k1 signature.
        handlePqAnnouncement(event) {
            try {
                if (!event || !event.pubkey) return;
                let payload;
                try { payload = JSON.parse(event.content || '{}'); } catch (_) { return; }
                if (!payload || payload.alg !== PQ_ALG) return;

                const nowSec = Math.floor(Date.now() / 1000);
                // An explicit retraction withdraws the whole claim, Nymchat and
                // all. Nothing emits one today, but a peer that does must be
                // honoured.
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

                // Kind 30078 is ADDRESSABLE, so the NEWEST wins, not whichever
                // arrived last. Older copies arrive constantly — reconnect
                // replays, several archive rows, and a peer's own boot publish,
                // which goes out KEYLESS a moment before the one carrying the
                // key — and any of them landing late replaced a live ML-KEM key
                // with `nym:1` and nothing else.
                const at = parseInt(event.created_at, 10) || 0;
                const held = this._pqEntry(event.pubkey);
                if (held && held.at > 0 && at > 0 && at < held.at) return;

                // No `pk` is a valid announcement: a Nymchat client that cannot
                // or will not do post-quantum. Recording it is what stops us
                // sending them a pointless Bitchat wrap.
                const readKey = (raw) => {
                    if (raw == null) return undefined;
                    let k;
                    try { k = window.NymCrypto._b64uDecode(raw); } catch (_) { return null; }
                    return (k instanceof Uint8Array && k.length === 1184) ? k : null;
                };
                const pk1 = readKey(payload.pk);
                const pk2 = readKey(payload.pk2);
                // A malformed key is a malformed announcement: leave the peer
                // classical rather than half-configured.
                if (pk1 === null || pk2 === null) return;
                const pk = pk2 !== undefined ? pk2 : (pk1 !== undefined ? pk1 : null);

                this._pqRecord(event.pubkey, pk, exp, parseInt(payload.epoch, 10) || 0,
                    this._pqAnnouncementIsRootSeeded(payload),
                    // Which formats this peer can open. pk2 alone means the
                    // layered one only — a signer login.
                    { pq1: pk1 !== undefined, pq2: pk2 !== undefined },
                    at);
                if (event.pubkey === this.pubkey) this._pqSelfAnnouncement = payload;
            } catch (_) { }
        },

        /// Fetches a peer's announcement unless we hold a live one. The
        /// standing subscription (relays.js, _buildCriticalFilters) covers
        /// existing conversations only, and a new one is not added until AFTER
        /// its first message is sent. Resolves either way: a peer with no
        /// announcement is normal, not an error.
        ensurePqAnnouncement(pubkey) {
            if (!pubkey || !this.pqEnabled()) return Promise.resolve(null);
            const known = this._pqEntry(pubkey);
            // Only an entry we can actually SEND to ends the search, so `pq2`:
            // a key we would never seal to is no better than none, and testing
            // `pk` alone left a restored PRE-SPLIT row both unusable and
            // unrefreshable. A keyless entry is likewise a reason to look
            // again, not to stop — it is cached for a week and the peer may
            // have published one since.
            //
            // A usable entry still does not end it if it cannot settle the
            // recency question the send plan is about to ask: a cached
            // announcement goes stale by design, so "Bitchat is newer" may be
            // concluding off our own staleness — self-reinforcing, since their
            // client makes the same call about us. Ask again; the refetch is
            // rate-limited below like any other.
            const staleVsBitchat = known && known.at > 0
                && this.bitchatFormatSeenAt(pubkey) > known.at;
            if (known && known.pk && known.pq2 && !staleVsBitchat) {
                return Promise.resolve(known);
            }
            if (!this._pqFetches) this._pqFetches = new Map();

            const inflight = this._pqFetches.get(pubkey);
            // Re-checking is rate-limited rather than free: a peer who really
            // has no key — a Bitchat user, a signer login — must not be
            // re-queried on every send.
            if (inflight) {
                if (inflight.promise) return inflight.promise;
                if (Date.now() - inflight.at < PQ_REFETCH_MS) return Promise.resolve(known || null);
            }

            // D1 first (see _pqAnnouncementFromD1). Only when it has nothing
            // do we pay for the relay fan-out.
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
                    // Stop later callers attaching to a promise that has already
                    // settled, or the refetch window below could never reopen.
                    const cur = this._pqFetches.get(pubkey);
                    if (cur && cur.promise === bounded) this._pqFetches.set(pubkey, { at: cur.at });
                    return v;
                });
            this._pqFetches.set(pubkey, { at: Date.now(), promise: bounded });
            return bounded;
        },

        /// The relay half of the lookup: one short-lived subscription, fanned
        /// out to a few relays.
        _pqAnnouncementFromRelays(pubkey) {
            const subId = 'nym-pq-' + Math.random().toString(36).slice(2);
            if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();

            let settle;
            const promise = new Promise((res) => { settle = res; });
            let done = false;
            // Armed by the first EOSE; see the handler below.
            let grace = null;
            const finish = () => {
                if (done) return;
                done = true;
                if (grace !== null) { clearTimeout(grace); grace = null; }
                this._subscriptionHandlers.delete(subId);
                try { this.closeFewRelaysSub(subId); } catch (_) { }
                if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
                this._pqFetches.set(pubkey, { at: Date.now() });
                settle(this._pqEntry(pubkey));
            };

            // An EOSE means ONE relay finished, not that the answer is in — and
            // the relays without the announcement are exactly the ones that
            // answer instantly, a race the empty answer usually wins. An EVENT
            // still finishes immediately, since that IS the answer; an EOSE only
            // starts a short grace period for a slower relay to speak up.
            this._subscriptionHandlers.set(subId, (type, data) => {
                if (type === 'EVENT' && data[0] === subId) {
                    const event = data[1];
                    // handleEvent ingests it through the same path a pushed
                    // announcement takes; this is only here to stop waiting.
                    if (event && event.kind === 30078 && event.pubkey === pubkey) {
                        try { this.handlePqAnnouncement(event); } catch (_) { }
                        finish();
                    }
                } else if (type === 'EOSE' && data[0] === subId) {
                    if (this._pqEntry(pubkey)) { finish(); return; }
                    if (grace === null) grace = setTimeout(finish, PQ_EOSE_GRACE_MS);
                }
            });

            this._pqFetches.set(pubkey, { at: Date.now(), promise });
            const req = ['REQ', subId, {
                kinds: [30078], '#t': [PQ_D_TAG], authors: [pubkey], limit: 1
            }];
            // The deadline starts NOW, not when the request goes out: the
            // one-shot pool queues past four concurrent lookups and the send
            // path awaits this, so a deadline starting at the slot would let a
            // busy queue hold a message up indefinitely.
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

        /// Asks D1 for a peer's announcement, or null. Tried BEFORE the relays
        /// because one query to one place has no race to lose. D1 is a cache,
        /// not an authority: the signature is verified here exactly as for a
        /// relay event, and it is what binds the ML-KEM key to the identity, so
        /// our own backend would have to forge secp256k1 to substitute a key.
        async _pqAnnouncementFromD1(pubkey) {
            if (!this._getApiHost || !this._getApiHost()) return null;
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
            try {
                const ok = typeof this._verifyRelayEventAsync === 'function'
                    ? await this._verifyRelayEventAsync(found)
                    : (typeof this._verifyRelayEvent === 'function'
                        ? this._verifyRelayEvent(found) : false);
                if (!ok) return null;
            } catch (_) { return null; }
            try { this.handlePqAnnouncement(found); } catch (_) { return null; }
            return this._pqEntry(pubkey);
        },

        /// Warms the announcements for everyone in a conversation, so the key
        /// is already in hand by the time the first message is sent.
        prefetchPqAnnouncements(pubkeys) {
            if (!pubkeys || !this.pqEnabled()) return;
            let n = 0;
            for (const pk of pubkeys) {
                if (!pk || !this._isNostrHex64 || !this._isNostrHex64(pk)) continue;
                if (++n > PQ_PREFETCH_MAX) break;
                this.ensurePqAnnouncement(pk);
            }
        },

        /// The live capability entry for a peer, or null. Shared by both
        /// lookups so expiry is enforced in exactly one place.
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

        /// A peer's ML-KEM key, but ONLY when they accept the layered format —
        /// the single accessor every send path goes through, so "never send
        /// pq1" lives in one place. Null is the signal to send classical
        /// NIP-17, so a missing, expired or KEM-less announcement degrades
        /// cleanly instead of failing a send.
        pqLayeredKeyFor(pubkey) {
            const rec = this._pqEntry(pubkey);
            if (!rec || !rec.pk || !rec.pq2) return null;
            return this.pqEnabled() ? rec.pk : null;
        },

        /// When this peer's live announcement was signed, or 0. Zero also
        /// means "expired or never seen": `_pqEntry` withholds a lapsed one,
        /// and an announcement we do not hold cannot be the newer evidence.
        pqAnnouncedAt(pubkey) {
            const rec = this._pqEntry(pubkey);
            return (rec && rec.at) || 0;
        },

        /// When a bitchat-format wrap from this pubkey last opened, or 0. The
        /// set it accompanies is deliberately kept: a dozen call sites still
        /// ask the membership question. Only the send plan needs WHEN, and an
        /// entry with no time reads as 0 — older than any announcement, which
        /// is the safe direction, since a peer genuinely on Bitchat has no live
        /// announcement and `provenNym` still routes them a copy.
        bitchatFormatSeenAt(pubkey) {
            if (!pubkey || !this._bitchatSeenAt) return 0;
            return this._bitchatSeenAt.get(pubkey) || 0;
        },

        /// Records that a bitchat-format wrap from `pubkey` opened at `atSec`.
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

        /// Whether EVERY device on this account can open a hybrid copy
        /// addressed to the account — one that cannot runs on defaults forever,
        /// silently. An unknown device counts as incapable: guessing capable is
        /// what locks one out, guessing the other way only falls back to
        /// classical until it updates. An empty roster means no second device,
        /// not a missing answer.
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

        /// Our own key for copies addressed to OURSELVES — self-wraps, the D1
        /// archive, synced settings. Withheld unless every device on the account
        /// can open the layered format, since we no longer produce the combined
        /// one; a pq1-only device gets an ordinary NIP-44 copy it can read.
        pqSelfKeyFor() {
            if (!this.pqSelfUsesPq2()) return null;
            if (!this.pqSelfEnabled()) return null;
            // Sealing to a key another of our own devices cannot derive locks
            // that device out of its own settings, silently and for good.
            if (!this.pqAllDevicesCapable()) return null;
            // DERIVED, not read from the registry: the announced epoch may be
            // another device's, and decryption only walks our own candidates.
            // Deriving keeps both sides on the same key by construction, and
            // works from the first save rather than once the announcement lands.
            const keys = this.pqSelfKeys();
            return (keys && keys.publicKey) || null;
        },

        /// Whether a peer has published a live announcement, i.e. is provably
        /// running Nymchat. Deliberately NOT gated on our own post-quantum
        /// setting: it answers "which client is this?", not "should we use
        /// post-quantum?".
        isKnownNymchatClient(pubkey) {
            return !!this._pqEntry(pubkey);
        },

        /// How many secret keys get paired with our ML-KEM epochs when building
        /// decrypt candidates. `_giftWrapIsForMe` has already established the
        /// wrap is addressed to one of our pubkeys and the caller orders the
        /// p-tag match first, so the first pairing is the right one virtually
        /// always. Pairing the whole ephemeral-key history instead would turn
        /// one ML-KEM decapsulation into dozens on every group wrap.
        PQ_SK_PAIRING_LIMIT: 2,

        /// Post-quantum decrypt candidates, given our secret keys ordered with
        /// the p-tag match first. A group wrap's two legs use DIFFERENT keys —
        /// the classical ECDH goes to the member's rotating ephemeral pubkey,
        /// the KEM leg to their long-lived identity key — so each candidate
        /// pairs a secp secret with our ML-KEM keypair rather than assuming
        /// both come from the same place.
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

        /// The ML-KEM key to encapsulate to for a group member. Always keyed by
        /// their REAL pubkey — the announcement is published by the identity,
        /// not by a rotating ephemeral key.
        pqGroupKeyFor(memberRealPubkey) {
            // Layered only, like every other send path.
            return this.pqLayeredKeyFor(memberRealPubkey);
        },

        /// Whether copies addressed to OURSELVES should use the layered
        /// format. True unless some device on this account can only open the
        /// combined one — a self-copy has to be readable by all of them.
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

        /// Whether a member accepts the layered format.
        pqGroupUsesPq2(memberRealPubkey) {
            const rec = this._pqEntry(memberRealPubkey);
            return !!(rec && rec.pk && rec.pq2);
        },

        /// Decides which transports a 1:1 PM to `recipientPubkey` should use.
        /// Both PM send paths (sendNIP17PM and sendEditedPM) go through this so
        /// the rule lives in exactly one place.
        ///
        /// Returns { pq, kemPk, bitchat, nym }:
        ///   * `pq` — send the hybrid post-quantum wrap. Only when we hold the
        ///     recipient's signed ML-KEM key, which is proof they can decrypt
        ///     it.
        ///   * `bitchat` — also send a Bitchat-format wrap.
        ///   * `nym` — send the Nymchat-format wrap (post-quantum when `pq`,
        ///     classical otherwise). Always true: every recipient gets one.
        ///
        /// No setting. The rule is one question — has this peer published a
        /// signed capability announcement? — because inferring the client from
        /// public activity is sometimes wrong, and wrong here means a message
        /// their app cannot open, silently. So:
        ///
        ///   no announcement, or an expired one -> NIP-44 + Bitchat
        ///   live announcement carrying `pk2`   -> pq2 alone
        ///   live announcement, no key or `pk`  -> NIP-44 alone
        ///
        /// A post-quantum wrap never carries a Bitchat copy of the same
        /// plaintext: that would hand a quantum attacker the easier target
        /// and buys no reach. It falls out of the rule rather than being a
        /// special case.
        pqPmPlan(recipientPubkey) {
            // Deciding the format is an optimization. Delivering the message is
            // not, so nothing that goes wrong in here may take the send with it.
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
            // Only ever the LAYERED format. A peer announcing just `pk` opens
            // only the combined one, which excludes every signer login and we
            // no longer produce. Withholding the key sends them ordinary
            // NIP-44, which they can always read: an old peer costs us
            // protection, never delivery.
            const announced = this.pqLayeredKeyFor(recipientPubkey);
            const provenNym = this.isKnownNymchatClient(recipientPubkey);

            // Have we DECRYPTED a bitchat-format wrap from this pubkey, and
            // when? Not inference: the flag is written when a `v2:` payload
            // from them opens, which only their client could have produced.
            // (`nymUsers` is deliberately not consulted — a Bitchat client
            // echoing our `x` tag back sets that one.)
            //
            // Two kinds of evidence about different moments, so the NEWER one
            // decides. Against a bare set membership the comparison had no time
            // in it: `bitchatUsers` never forgets and is rebuilt from cached PM
            // history on every reload, so one wrap from the dual-send era
            // pinned a peer to classical for good.
            const bitchatAt = this.bitchatFormatSeenAt(recipientPubkey);
            const announcedAt = this.pqAnnouncedAt(recipientPubkey);
            const knownBitchat = bitchatAt > 0 && !(announcedAt > 0 && announcedAt >= bitchatAt);

            // ...but a LIVE key we can seal to settles it, because the Bitchat
            // app cannot publish a kind-30078 announcement at all. The `v2:`
            // wrap we decrypted is that same Nymchat client DUAL-SENDING, its
            // plan having found no announcement of ours yet — so reading it as
            // "they run Bitchat" reads our own protocol back as evidence
            // against itself, symmetrically, and each side kept replying in the
            // format that pinned the other to classical.
            //
            // A peer who really moved to Bitchat gets a wrap they cannot open
            // until their announcement lapses. That cost is bounded by an
            // expiry nobody is republishing; the loop above never ended.
            const bitchat = announced ? false : (knownBitchat || !provenNym);

            // A post-quantum wrap never accompanies a Bitchat copy of the same
            // plaintext: the copy is the easier target, so pairing them buys a
            // quantum attacker the message and us nothing. The shield then says
            // classical rather than claiming protection the plaintext lacks.
            const kemPk = bitchat ? null : announced;

            const rec = this._pqEntry(recipientPubkey);
            return {
                pq: !!kemPk,
                kemPk: kemPk || null,
                // Which wrap to build: the layered format whenever the peer
                // accepts it, since a signer login on either end can open it.
                // Never a format the recipient cannot.
                pq2: !!kemPk && !!(rec && rec.pq2),
                // Root-seeded peer key, for the badge. Not used for routing:
                // a legacy peer still gets a post-quantum wrap.
                rootSeeded: !!kemPk && this.pqPeerIsRootSeeded(recipientPubkey),
                bitchat,
                // ALWAYS. Every recipient gets a Nymchat wrap: the layered one
                // when they announced a key they can open it with, an ordinary
                // NIP-44 one when they did not.
                nym: true,
                // Surfaced for tests and diagnostics; not used for routing.
                provenNym
            };
        },

        /// Records how many of a group message's recipients got a
        /// post-quantum wrap, so the badge can say "quantum-resistant to 8 of
        /// 10 members" instead of implying all-or-nothing. Keyed by the shared
        /// Nymchat message id, bounded like the other per-message caches.
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

        /// { pq, total } for a group message we sent, or null.
        pqGroupCoverageFor(sharedId) {
            return (this.pqGroupCoverage && this.pqGroupCoverage.get(sharedId)) || null;
        },

        /// Pubkeys we hold live PQ keys for — used to size the group coverage
        /// readout and to decide whether a self-archive can be post-quantum.
        pqKnownPeers() {
            if (!this.pqKeys) return [];
            const nowSec = Math.floor(Date.now() / 1000);
            const out = [];
            for (const [pk, rec] of this.pqKeys) {
                // Only entries carrying an actual KEM key count as
                // post-quantum peers; a KEM-less one is just a Nymchat client.
                if (rec.exp > nowSec && rec.pk) out.push(pk);
            }
            return out;
        },

        /// Shows the post-quantum notice once, for an install upgraded into
        /// post-quantum rather than starting with it. Suppressed while the
        /// tutorial is pending, since the tour covers the same ground, and
        /// dismissed rather than deferred so it is never seen twice. The copy
        /// branches: a device holding the root is told to save the code, one
        /// without it to link, because nothing is protected until it does.
        async maybeShowPqUpgradeNotice() {
            // Either signal opens this: an upgrade that should save its code,
            // or a device that cannot read the account until it pastes one.
            const linkPending = this.pqRootLinkPromptPending();
            if (!this.pqUpgradeNoticePending() && !linkPending) return;
            // A locked device is not `pqCapable` — that is the whole problem —
            // so the capability gate must not swallow its prompt.
            if (!linkPending && !this.pqCapable()) { this.dismissPqUpgradeNotice(); return; }
            if (this._pqTutorialPending()) { this.dismissPqUpgradeNotice(); return; }
            this.dismissPqUpgradeNotice();
            const linkNeeded = this.pqRootLinkNeeded();
            if (linkNeeded) this.dismissPqRootLinkPrompt();
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
            // Shown in the notice itself: the moment the user is told the code
            // matters is the moment to let them copy it.
            const code = linkNeeded ? null : (this.pqRootCode ? this.pqRootCode() : null);
            try {
                // Pasted here rather than by sending the user to navigate for
                // it — the notice already has their attention.
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
                    copyLabel: 'Copy code'
                });
            } catch (_) { /* dialog unavailable; the notice is not load-bearing */ }
        },

        /// Whether the tutorial is still ahead of this user.
        _pqTutorialPending() {
            try { return localStorage.getItem('nym_tutorial_seen') !== 'true'; }
            catch (_) { return false; }
        },

        /// The device roster from our own announcement, newest first, for the
        /// settings screen. Purely informational.
        pqDeviceRoster() {
            const devices = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            const selfId = this._pqDeviceId();
            return devices.map(d => ({ ...d, isSelf: d.id === selfId }));
        },

        /// Why a conversation is sending classical, in one line. Every term of
        /// `_pqPmPlan` can be false for its own reason and all of them look
        /// identical from outside — one shield reading "Not quantum-resistant"
        /// — so this names the FIRST that failed, in evaluation order.
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
            // Nothing below takes it away: a live layered key settles it, since
            // the Bitchat app cannot publish an announcement. Bitchat traffic
            // only decides for a peer with no usable key, and there the missing
            // key is the nearer reason, reported above.
            return 'post-quantum';
        },

        /// Everything the post-quantum path decided, for the settings readout.
        /// Live values rather than a summary: a stuck conversation always asks
        /// "which of these is not what I think it is", and only values answer.
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

        /// Paints the diagnostics into the settings panel. Read on demand
        /// rather than kept live: every value in it can change on the next
        /// announcement, and a stale readout is worse than none.
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
