// pq.js — hybrid post-quantum key announcement, discovery, and policy.

(function () {
    const PQ_D_TAG = 'nym-pq';
    const PQ_ALG = 'mlkem768';
    // Announcements expire so a downgraded or abandoned device stops attracting
    // PQ messages it cannot read. Republished well inside the window.
    const PQ_TTL_SEC = 7 * 24 * 3600;
    /// How long a "this peer has no announcement" result is trusted before we
    /// ask again. Long enough that the send path is not re-querying constantly,
    /// short enough that a peer who upgrades mid-conversation is picked up.
    const PQ_REFETCH_MS = 10 * 60 * 1000;
    /// A one-shot lookup gives up after this and the message goes classical,
    /// which is the pre-existing behaviour rather than a new failure.
    const PQ_FETCH_TIMEOUT_MS = 2500;
    /// How long to keep listening after the FIRST relay says it has nothing.
    /// The request goes to several at once and they answer at their own pace,
    /// so one relay's "done" is not the answer — it is one vote out of five.
    const PQ_EOSE_GRACE_MS = 600;
    /// Cap on a single prefetch sweep, so opening a large group does not fire
    /// one subscription per member.
    const PQ_PREFETCH_MAX = 60;
    const PQ_REPUBLISH_SEC = 24 * 3600;
    /// How long after connecting we wait before announcing. Matches the DM
    /// catch-up window, so our own existing announcement has arrived and its
    /// device roster is merged rather than clobbered.
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

        /// Whether we can RECEIVE post-quantum messages, and therefore whether
        /// we announce an ML-KEM key for peers to encapsulate to.
        ///
        /// The root is enough on its own: under pq2 the decapsulation key is
        /// derived from it, and the inner NIP-44 is performed by whatever holds
        /// the identity key — a signer included. An nsec still qualifies, for
        /// the legacy pq1 keys it derives.
        pqCapable() {
            return this.pqSupported() && (this.pqHasRoot() || !!this.privkey);
        },

        /// Whether we can open the LEGACY combined format. It mixes the raw
        /// ECDH output into the key, which no signer will return, so this one
        /// really does need the nsec.
        pq1Capable() {
            return this.pqSupported() && !!this.privkey;
        },

        /// Whether we can SEND post-quantum, which is a weaker requirement.
        ///
        /// A NIP-17 message is two nested encryptions: a SEAL under our own
        /// identity key, and a WRAP under a throwaway key we generate ourselves
        /// on every send. Only the seal needs the signer, so an extension or
        /// NIP-46 login can still hybridize the wrap — and the wrap is the layer
        /// that matters here. What a recorder stores is the wrap; reaching the
        /// seal at all means breaking it first, so a hybrid wrap already defeats
        /// harvest-now-decrypt-later. The seal's classical encryption only
        /// matters to someone who has ALREADY broken the post-quantum layer.
        ///
        /// This is deliberately not symmetric with pqCapable(): such a login
        /// sends post-quantum but still receives classical, because it cannot
        /// decapsulate. Half a conversation, and worth having — a recorded
        /// outbound message is still a recorded message.
        pqSendCapable() {
            return this.pqSupported();
        },

        /// Whether we send post-quantum to peers who can receive it.
        ///
        /// There is no user setting: post-quantum is simply how Nymchat talks
        /// to Nymchat, exactly as NIP-44 is how it talks to everything else.
        /// The only thing that can turn it off is not being able to do it, and
        /// that is a property of the login, not a preference.
        pqEnabled() {
            return this.pqSendCapable() && this._pqMode() !== 'off';
        },

        /// Whether OUR OWN copies — self-wraps, the archive, synced settings —
        /// can be post-quantum. They are addressed to us, so this is the
        /// receive-side question: encapsulating to a key we cannot decapsulate
        /// with would lock us out of our own history.
        pqSelfEnabled() {
            return this.pqCapable() && this._pqMode() !== 'off';
        },

        /// Reads an UNDOCUMENTED escape hatch, absent by default.
        ///
        /// This is not a setting and there is no UI for it. It exists so that
        /// a field bug in the post-quantum path can be defused by telling
        /// affected users to set `nym_pq_mode` to 'off' in storage, instead of
        /// everyone waiting on an emergency release. Nothing in the app ever
        /// writes it.
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

        /// Marks an upgrade so the one-time notice fires once. Called at boot.
        ///
        /// `nym_last_online_ts` is written by every prior version, so its
        /// presence distinguishes an upgrade from a fresh install. Only an
        /// upgrade warrants the notice: a fresh install has no older device on
        /// the same npub to strand.
        _pqMarkUpgradeIfNeeded() {
            try {
                if (localStorage.getItem('nym_pq_upgrade_seen')) return;
                localStorage.setItem('nym_pq_upgrade_seen', '1');
                if (localStorage.getItem('nym_last_online_ts')) {
                    localStorage.setItem('nym_pq_upgrade_notice', 'pending');
                }
            } catch (_) { }
        },

        // our own key
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

        /// The root we may derive keys FROM, as distinct from the bytes we
        /// happen to store. A locked device holds a root that does not open
        /// this account's record — a stale one from a reset identity — and
        /// sealing our own copies to it would write history the account's real
        /// devices cannot open. The announcement is already withheld while
        /// locked (see publishPqAnnouncement); this withholds the key itself.
        pqUsableRoot() {
            if (this._pqRootLocked) return null;
            return this.pqRoot();
        },

        /// The `nympq1...` code, for the reveal/copy surface beside the nsec.
        pqRootCode() {
            // The usable one: a locked device must not present a stale root as
            // "your recovery code" and invite the user to copy it onto their
            // other devices. It gets the link prompt instead.
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

        /// Whether §6 has run. Until it has, this device does not yet know
        /// whether the account has a root, so any key it could announce is
        /// nsec-derived by default rather than by decision.
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
        /// do not announce) or 'generated'.
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

            // No record, but we hold a root already (the write has not
            // landed yet). Keep it rather than rolling a second one.
            if (mine) {
                this._pqRootLocked = false;
                return 'adopted';
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

        /// Merges this device into the roster carried by our announcement,
        /// dropping entries not seen for PQ_DEVICE_STALE_SEC.
        ///
        /// The roster lets the settings screen say which devices have actually
        /// been seen running a PQ-capable build, and its `pq` flag decides
        /// whether copies addressed to the account may be sealed hybrid at all
        /// (pqAllDevicesCapable). It never gates DECRYPTION — anything already
        /// sealed stays readable.
        _pqMergeDeviceRoster(nowSec) {
            const id = this._pqDeviceId();
            const prev = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            const out = prev.filter(d => d && d.id !== id && (nowSec - (d.ts || 0)) < PQ_DEVICE_STALE_SEC);
            // `pq` says whether this device can DECAPSULATE, which decides
            // whether copies addressed to the account can go hybrid at all —
            // see pqAllDevicesCapable.
            out.push({
                id, ver: this._pqAppVersion(), ts: nowSec,
                pq: this.pqCapable() ? 1 : 0,
                // Separate from `pq`: a signer login can open the layered
                // format but never the combined one, so a self-copy sealed
                // pq1 would lock it out of its own settings and archive.
                pq2: this.pqCapable() ? 1 : 0
            });
            out.sort((a, b) => (b.ts || 0) - (a.ts || 0));
            return out.slice(0, 16);
        },

        /// Publishes our capability announcement.
        ///
        /// EVERY Nymchat client publishes this, not only post-quantum-capable
        /// ones: its presence is signed proof that a pubkey runs Nymchat,
        /// which is what lets the send path skip the speculative Bitchat
        /// wrap. The ML-KEM key rides along only when usable, so the two
        /// claims stay independent:
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
                // A KEM key only when we can actually decapsulate with it —
                // and only once §6 has decided where it comes from.
                //
                // On a fresh account the settings load that generates the root
                // has not finished when this first fires. Announcing anyway
                // published an nsec-derived key, and a peer who cached it kept
                // sealing to it for the whole TTL. Two accounts created minutes
                // apart therefore exchanged genuinely legacy-sealed messages,
                // which is what the badge was correctly reporting.
                //
                // `nym: 1` still goes out, so we remain a known Nymchat client
                // and peers skip the Bitchat wrap; they just have no key to
                // encapsulate to yet, which reads as classical rather than as
                // false post-quantum. A keyless entry does not end their
                // lookup (see ensurePqAnnouncement), so the republish below is
                // picked up promptly rather than after the TTL.
                const keys = (this.pqSelfEnabled() && this.pqRootSettled())
                    ? this.pqSelfKeys() : null;
                // Only true when the key we are publishing IS root-derived.
                const rootSeeded = !!keys && this.pqRootSeeded();

                // Kind 30078 is addressable (NIP-01): the relay keeps one event
                // per (kind, pubkey, d-tag), so this replaces our previous
                // announcement in place rather than adding a second one.
                //
                // Replacement is decided by created_at, and on a TIE the relay
                // keeps the lexically-lower event id — so a republish landing
                // in the same second as the last one can be silently dropped,
                // leaving peers on a stale key. rotatePqKey() immediately after
                // a boot publish is exactly that case. Same monotonic floor the
                // kind-0 profile save uses (nostr-core.js:182).
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
                    // Marks this as a Nymchat client regardless of whether a
                    // KEM key is present. Parsed separately from `pk` so
                    // "Nymchat without post-quantum" is distinguishable from a
                    // retraction.
                    nym: 1,
                    epoch: this._pqEpoch(),
                    // Two claims, because they are not the same claim.
                    //
                    // `pk` means "seal to this with EITHER format". Only a
                    // login holding the nsec can say it, because the legacy
                    // combined format needs the raw ECDH output to open.
                    //
                    // `pk2` means "seal to this with the layered format only".
                    // A signer login says just this, and an older build — which
                    // has never heard of pk2 — reads the announcement as a
                    // Nymchat client with no post-quantum key and sends plain
                    // NIP-44, which a signer CAN read. That degrade is the
                    // whole point of splitting them: the alternative is an
                    // older peer sealing pq1 to a login that can never open it.
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
                this._pqLastPublishAt = Date.now();
                // Record our own entry so self-addressed wraps resolve through
                // the same lookup as everyone else's.
                this._pqRecord(this.pubkey, keys ? keys.publicKey : null, exp, payload.epoch, rootSeeded);
                return true;
            } catch (_) {
                return false;
            }
        },

        /// Stops advertising a post-quantum key without withdrawing the
        /// Nymchat claim.
        ///
        /// Republishing WITHOUT a `pk` is the retraction: peers stop
        /// encapsulating to us immediately, but still know we are a Nymchat
        /// client, so they keep skipping the Bitchat wrap. Publishing an
        /// expired announcement instead would throw that away and send us back
        /// to being indistinguishable from a Bitchat user.
        async retractPqAnnouncement() {
            return this.publishPqAnnouncement();
        },

        /// Schedules our announcement for shortly after connecting, at most
        /// once per pending window.
        schedulePqAnnouncement() {
            if (this._pqAnnounceTimer) return;
            this._pqAnnounceTimer = setTimeout(() => {
                this._pqAnnounceTimer = null;
                try {
                    if (!this.pubkey) return;
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
        _pqRecord(pubkey, pk, exp, epoch, root, fmt) {
            if (!this.pqKeys) this.pqKeys = new Map();
            // Absent `fmt` means an entry recorded before the split (or by our
            // own self-record): assume the legacy format only, which is what
            // every such entry actually was.
            this.pqKeys.set(pubkey, {
                pk: pk || null, exp, epoch, root: !!root,
                pq1: fmt ? !!fmt.pq1 : true,
                pq2: fmt ? !!fmt.pq2 : false
            });
            // Ride the same debounced write the other dedup sets use, so a
            // reload does not start from nothing and send the next message
            // classically while it looks every peer up again. Restoring is
            // bounded by the announcement's own expiry — see _hydratePqKeys.
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

        /// Same question, but able to answer "I don't know yet".
        ///
        /// The first message from a new peer arrives before their announcement
        /// does, and treating that absence as legacy marked every opening
        /// message of every conversation legacy until a second one arrived.
        /// Unknown is not legacy; it is a lookup that has not landed.
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
                // all. Nothing emits one today — turning post-quantum off
                // republishes without a key instead — but a peer that does
                // must be honoured.
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
                    { pq1: pk1 !== undefined, pq2: pk2 !== undefined });
                if (event.pubkey === this.pubkey) this._pqSelfAnnouncement = payload;
            } catch (_) { }
        },

        /// Fetches a peer's capability announcement if we do not already hold a
        /// live one.
        ///
        /// The standing subscription (relays.js, _buildCriticalFilters) covers
        /// existing conversations only, and a new one is not added until AFTER
        /// its first message is sent — so without this the first message to a
        /// new peer always went classical.
        ///
        /// Resolves either way: a peer with no announcement is normal, not an
        /// error.
        ensurePqAnnouncement(pubkey) {
            if (!pubkey || !this.pqEnabled()) return Promise.resolve(null);
            const known = this._pqEntry(pubkey);
            // Only an entry WITH A KEY ends the search. A keyless one is
            // cached for a week, so a peer who has since published a key would
            // stay classical for the rest of it. Not having one is a reason to
            // look again, not to stop.
            if (known && known.pk) return Promise.resolve(known);
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
            this._pqFetches.set(pubkey, { at: Date.now(), promise: viaD1 });
            return viaD1;
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

            // An EOSE means ONE relay has finished, not that the answer is in.
            // The request fans out to several, and the ones that do not carry
            // the announcement are exactly the ones that answer instantly — so
            // finishing on the first EOSE ended the wait before the relay that
            // actually had the key could deliver it. That is a race the empty
            // answer usually wins, which is why two Nymchat users who had both
            // published kept messaging each other classically.
            //
            // An EVENT still finishes immediately: that IS the answer. An EOSE
            // only starts a short grace period for a slower relay to speak up.
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
            // The deadline starts NOW, not when the request goes out. The
            // one-shot pool queues past four concurrent lookups, and the send
            // path awaits this promise — so a deadline that only started once
            // a slot freed would let a busy queue hold up a message
            // indefinitely rather than letting it go classical and move on.
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

        /// Asks D1 for a peer's announcement, or null when there is nothing to
        /// ask or nothing there.
        ///
        /// Tried BEFORE the relays because it has no race in it. A relay
        /// request fans out to five and the first "nothing here" ends the
        /// wait — which the relays without the announcement always win,
        /// having nothing to look up. One query to one place cannot lose that
        /// race because there is no race.
        ///
        /// D1 is a cache, not an authority. The signature on the event is
        /// verified here exactly as it is for a relay event, and that
        /// signature is what binds the ML-KEM key to the Nostr identity: our
        /// own backend cannot substitute a key it would then be able to read
        /// messages with, it would have to forge secp256k1 to do it.
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

        /// A peer's usable ML-KEM public key, or null. Null is the signal to
        /// send classical NIP-17 — every caller treats it that way, so a
        /// missing, expired, or KEM-less announcement degrades cleanly instead
        /// of failing a send.
        pqKeyFor(pubkey) {
            if (!this.pqEnabled()) return null;
            const rec = this._pqEntry(pubkey);
            return (rec && rec.pk) || null;
        },

        /// Our own ML-KEM key, for copies addressed to OURSELVES — self-wraps,
        /// the D1 archive, synced settings.
        ///
        /// Null unless we can decapsulate: sealing to a key another device
        /// announced would lock THIS one out of its own history. Outbound
        /// messages have no such hazard — the recipient decapsulates.
        /// Whether EVERY device on this account can open a hybrid copy
        /// addressed to the account. A device that cannot runs on defaults
        /// forever, silently.
        ///
        /// An unknown device counts as incapable: guessing capable is what
        /// locks one out, and guessing the other way only falls back to
        /// classical until it updates.
        ///
        /// An empty roster means no second device, not a missing answer.
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

        pqSelfKeyFor() {
            if (!this.pqSelfEnabled()) return null;
            // Sealing to a key another of our own devices cannot derive locks
            // that device out of its own settings, and the failure is silent
            // and total. Better to protect the account's copies with what all
            // of it can read.
            if (!this.pqAllDevicesCapable()) return null;
            // DERIVED, not read from the registry: the announced epoch may be
            // another device's, and decryption only walks our own candidates.
            // Sealing to a key we cannot open fails silently and for good.
            // Deriving keeps the two sides on the same key by construction, and
            // has the side benefit of working from the first save rather than
            // only after the announcement lands.
            const keys = this.pqSelfKeys();
            return (keys && keys.publicKey) || null;
        },

        /// Whether a peer has published a live capability announcement, i.e.
        /// whether they are provably running Nymchat.
        ///
        /// Deliberately NOT gated on our own post-quantum setting: it answers
        /// "which client is this?", not "should we use post-quantum?". A peer
        /// stays a known Nymchat client whether or not either side has
        /// post-quantum switched on.
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

        /// Post-quantum decrypt candidates for `event`, given our secret keys
        /// ordered with the p-tag match first.
        ///
        /// A group wrap's two legs use DIFFERENT keys: the classical ECDH goes
        /// to the member's rotating ephemeral pubkey (preserving the metadata
        /// protection that rotation buys), while the KEM leg encapsulates to
        /// their long-lived identity ML-KEM key. So each candidate pairs a
        /// secp secret key with our ML-KEM keypair rather than assuming both
        /// come from the same place.
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
            return this.pqKeyFor(memberRealPubkey);
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
        ///     classical otherwise).
        ///
        /// No setting. The whole rule is one question — has this peer
        /// published a signed capability announcement? — because inferring
        /// the client from public activity would sometimes be wrong, and
        /// wrong here means a message their app cannot open, silently.
        ///
        /// A post-quantum wrap never carries a Bitchat copy of the same
        /// plaintext: that would hand a quantum attacker the easier target
        /// and buys no reach. It falls out of the rule rather than being a
        /// special case.
        pqPmPlan(recipientPubkey) {
            const kemPk = this.pqKeyFor(recipientPubkey);
            const provenNym = this.isKnownNymchatClient(recipientPubkey);
            const knownBitchat = !!(this.bitchatUsers && this.bitchatUsers.has(recipientPubkey));
            const knownNym = !!(this.nymUsers && this.nymUsers.has(recipientPubkey));
            const unknown = !knownBitchat && !knownNym;

            // The Bitchat wrap exists to reach someone who MIGHT be running
            // Bitchat. A live announcement proves they are not, so it is
            // dropped; without one we cannot tell, so it is sent.
            const bitchat = (knownBitchat || unknown) && !provenNym;

            const rec = this._pqEntry(recipientPubkey);
            return {
                pq: !!kemPk,
                kemPk: kemPk || null,
                // Which wrap to build. The layered format whenever the peer
                // accepts it, because it is the one a signer login on either
                // end can open; the combined one only for peers that predate
                // it. Never a format the recipient cannot open.
                pq2: !!kemPk && !!(rec && rec.pq2),
                // Root-seeded peer key, for the badge. Not used for routing:
                // a legacy peer still gets a post-quantum wrap.
                rootSeeded: !!kemPk && this.pqPeerIsRootSeeded(recipientPubkey),
                bitchat,
                // Invariant: a message must always leave in SOME format. The
                // other terms happen to cover every case today, but a silent
                // no-send is such a bad failure — no error, no retry, the
                // message simply never exists — that the guard stays.
                nym: !bitchat || knownNym || unknown || provenNym || !!kemPk,
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

        /// Shows the post-quantum notice once, if this install was upgraded
        /// into post-quantum rather than starting with it.
        ///
        /// Suppressed while the tutorial is still pending: the tour covers the
        /// same ground beside the nsec, and two explanations of the same thing
        /// back to back is worse than one. It is dismissed rather than
        /// deferred, so a user who takes the tour never sees it twice.
        ///
        /// The copy branches on what this device actually needs. A device that
        /// holds the root is told to save the code; one that does not is told
        /// to link, because for that device nothing is protected until it
        /// does, and saying "you're covered" would be false.
        async maybeShowPqUpgradeNotice() {
            if (!this.pqUpgradeNoticePending()) return;
            if (!this.pqCapable()) { this.dismissPqUpgradeNotice(); return; }
            if (this._pqTutorialPending()) { this.dismissPqUpgradeNotice(); return; }
            this.dismissPqUpgradeNotice();
            const linkNeeded = this.pqRootLinkNeeded();
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
            // Shown in the notice itself: the one moment the user is told the
            // code matters is the moment to let them copy it, rather than
            // sending them to look for it and hoping they do.
            const code = linkNeeded ? null : (this.pqRootCode ? this.pqRootCode() : null);
            try {
                // A device that needs the code can paste it here. Telling it
                // where to go and then making it navigate is a step for no
                // reason — the notice already has the user's attention.
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
        }
    });
})();
