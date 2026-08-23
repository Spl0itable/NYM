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
    /// Cap on a single prefetch sweep, so opening a large group does not fire
    /// one subscription per member.
    const PQ_PREFETCH_MAX = 60;
    const PQ_REPUBLISH_SEC = 24 * 3600;
    // Devices unseen for this long drop off the roster shown in settings.
    const PQ_DEVICE_STALE_SEC = 30 * 24 * 3600;

    Object.assign(NYM.prototype, {

        PQ_D_TAG,
        PQ_TTL_SEC,

        // --- capability + policy -------------------------------------------

        /// Whether the ML-KEM implementation loaded at all.
        pqSupported() {
            return !!(window.NymCrypto && window.NymCrypto.pqAvailable && window.NymCrypto.pqAvailable());
        },

        /// Whether we can RECEIVE post-quantum messages, and therefore whether
        /// we announce an ML-KEM key for peers to encapsulate to.
        ///
        /// Needs the nsec: the ML-KEM keypair is derived from it, and opening a
        /// message means decapsulating with its secret half. An extension or
        /// NIP-46 signer holds the nsec and will not do ML-KEM, so those logins
        /// cannot receive — not by choice, and not fixable from this side.
        pqCapable() {
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

        // --- our own key ----------------------------------------------------

        _pqEpoch() {
            try { return parseInt(localStorage.getItem('nym_pq_epoch') || '0', 10) || 0; }
            catch (_) { return 0; }
        },

        /// Our ML-KEM keypair, derived from the nsec and cached per
        /// (pubkey, epoch) so a key change or rotation invalidates it.
        pqSelfKeys() {
            if (!this.pqCapable()) return null;
            const epoch = this._pqEpoch();
            const basis = `${this.pubkey}:${epoch}`;
            if (this._pqSelfCache && this._pqSelfCache.basis === basis) {
                return this._pqSelfCache.keys;
            }
            let keys;
            try { keys = window.NymCrypto.pqKeypairFromPrivkey(this.privkey, epoch); }
            catch (_) { return null; }
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

        /// Ordered decrypt candidates for our own ML-KEM keys: the current
        /// epoch first, then a bounded window of previous ones, so a wrap sent
        /// just before a rotation still opens.
        pqSelfCandidates() {
            if (!this.pqCapable()) return [];
            const out = [];
            const epoch = this._pqEpoch();
            for (let e = epoch; e >= Math.max(0, epoch - 3); e--) {
                try {
                    const k = window.NymCrypto.pqKeypairFromPrivkey(this.privkey, e);
                    out.push({ kemSk: k.secretKey, kemPk: k.publicKey });
                } catch (_) { }
            }
            return out;
        },

        // --- announcement ---------------------------------------------------

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
        /// dropping entries not seen for PQ_DEVICE_STALE_SEC. The roster is
        /// informational only — it never gates decryption — but it is what lets
        /// the settings screen say which devices have actually been seen
        /// running a PQ-capable build.
        _pqMergeDeviceRoster(nowSec) {
            const id = this._pqDeviceId();
            const prev = (this._pqSelfAnnouncement && Array.isArray(this._pqSelfAnnouncement.devices))
                ? this._pqSelfAnnouncement.devices : [];
            const out = prev.filter(d => d && d.id !== id && (nowSec - (d.ts || 0)) < PQ_DEVICE_STALE_SEC);
            out.push({ id, ver: this._pqAppVersion(), ts: nowSec });
            out.sort((a, b) => (b.ts || 0) - (a.ts || 0));
            return out.slice(0, 16);
        },

        /// Publishes our capability announcement.
        ///
        /// EVERY Nymchat client publishes this, not only post-quantum-capable
        /// ones. Its mere presence is signed, unforgeable proof that a pubkey
        /// runs Nymchat — which is what lets the send path skip the
        /// speculative Bitchat wrap for peers who demonstrably are not on
        /// Bitchat. The ML-KEM key rides along only when post-quantum is both
        /// possible and switched on, so the two claims stay independent:
        ///
        ///   announcement + `pk`  -> Nymchat, post-quantum
        ///   announcement, no pk  -> Nymchat, classical (PQ off, or an
        ///                           extension / NIP-46 login that cannot seal
        ///                           a hybrid message at all)
        ///   no announcement      -> unknown; could be Bitchat or any other
        ///                           Nostr client
        async publishPqAnnouncement() {
            try {
                if (!this.connected || !this.pubkey) return false;
                // A KEM key only when we can actually use one.
                // A KEM key only when we can actually decapsulate with it.
                const keys = this.pqSelfEnabled() ? this.pqSelfKeys() : null;

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
                    v: 1,
                    alg: PQ_ALG,
                    // Marks this as a Nymchat client regardless of whether a
                    // KEM key is present. Parsed separately from `pk` so
                    // "Nymchat without post-quantum" is distinguishable from a
                    // retraction.
                    nym: 1,
                    epoch: this._pqEpoch(),
                    ...(keys ? { pk: window.NymCrypto._b64uEncode(keys.publicKey) } : {}),
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
                this._pqRecord(this.pubkey, keys ? keys.publicKey : null, exp, payload.epoch);
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

        // --- peer keys ------------------------------------------------------

        /// Records a capability entry. `pk` may be null — that still means
        /// "this pubkey runs Nymchat", which is the signal the send path uses
        /// to skip the Bitchat wrap.
        _pqRecord(pubkey, pk, exp, epoch) {
            if (!this.pqKeys) this.pqKeys = new Map();
            this.pqKeys.set(pubkey, { pk: pk || null, exp, epoch });
            // Every write goes through this one bound. Map preserves insertion
            // order, so the evicted entry is the earliest-recorded one.
            while (this.pqKeys.size > 5000) {
                this.pqKeys.delete(this.pqKeys.keys().next().value);
            }
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
                let pk = null;
                if (payload.pk != null) {
                    try { pk = window.NymCrypto._b64uDecode(payload.pk); } catch (_) { return; }
                    if (!(pk instanceof Uint8Array) || pk.length !== 1184) return;
                }

                this._pqRecord(event.pubkey, pk, exp, parseInt(payload.epoch, 10) || 0);
                if (event.pubkey === this.pubkey) this._pqSelfAnnouncement = payload;
            } catch (_) { }
        },

        /// Fetches a peer's capability announcement if we do not already hold a
        /// live one.
        ///
        /// The standing subscription for these (relays.js,
        /// _buildCriticalFilters) is scoped to the peers in `pmConversations`
        /// and the groups we are in. That list does get rebuilt when a
        /// conversation is added (`_scheduleCriticalResubscribe`), but the
        /// rebuild is debounced 750ms, and — the part that actually bit — the
        /// entry for a brand new conversation is not created until AFTER the
        /// first message has been sent (pms.js, addPMConversation from within
        /// sendPM). So at the moment the send path asked pqKeyFor() for a new
        /// peer, that peer had never been in a filter, the answer was null, and
        /// the message went classical with no shield. Waiting on a rebuild that
        /// has not been scheduled yet is not something the send path can do.
        ///
        /// Resolves either way. A peer with no announcement is a normal
        /// outcome, not an error: they may be on Bitchat, or on a build without
        /// post-quantum.
        ensurePqAnnouncement(pubkey) {
            if (!pubkey || !this.pqEnabled()) return Promise.resolve(null);
            if (this._pqEntry(pubkey)) return Promise.resolve(this._pqEntry(pubkey));
            if (!this._pqFetches) this._pqFetches = new Map();

            const inflight = this._pqFetches.get(pubkey);
            // A miss is cached for a while too: without that, every keystroke's
            // worth of send-path checks would re-ask the relays for an
            // announcement that does not exist.
            if (inflight) {
                if (inflight.promise) return inflight.promise;
                if (Date.now() - inflight.at < PQ_REFETCH_MS) return Promise.resolve(null);
            }

            const subId = 'nym-pq-' + Math.random().toString(36).slice(2);
            if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();

            let settle;
            const promise = new Promise((res) => { settle = res; });
            let done = false;
            const finish = () => {
                if (done) return;
                done = true;
                this._subscriptionHandlers.delete(subId);
                try { this.closeFewRelaysSub(subId); } catch (_) { }
                if (typeof this._oneShotReqDone === 'function') this._oneShotReqDone();
                this._pqFetches.set(pubkey, { at: Date.now() });
                settle(this._pqEntry(pubkey));
            };

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
                    finish();
                }
            });

            this._pqFetches.set(pubkey, { at: Date.now(), promise });
            const req = ['REQ', subId, {
                kinds: [30078], '#t': [PQ_D_TAG], authors: [pubkey], limit: 1
            }];
            const run = () => {
                try { this.sendRequestToFewRelays(req); } catch (_) { finish(); return; }
                setTimeout(finish, PQ_FETCH_TIMEOUT_MS);
            };
            if (typeof this._oneShotReqAcquire === 'function') this._oneShotReqAcquire(run);
            else run();
            return promise;
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
        /// Null unless we can decapsulate, which is not the same question as
        /// whether a key exists. A second device holding the nsec may have
        /// announced one for this npub; encapsulating to it from an extension
        /// or NIP-46 login — which cannot derive its secret half — would lock
        /// THIS device out of its own history. Outbound messages have no such
        /// hazard, because the recipient is the one who decapsulates.
        pqSelfKeyFor() {
            if (!this.pqSelfEnabled()) return null;
            return this.pqKeyFor(this.pubkey);
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
        /// There is no setting here. Nymchat-to-Nymchat is post-quantum;
        /// anyone we cannot prove is on Nymchat gets exactly what they got
        /// before post-quantum existed. The whole rule is one question — has
        /// this peer published a capability announcement? — because that
        /// announcement is signed and cannot be faked, whereas inferring the
        /// client from public activity would occasionally be wrong, and being
        /// wrong here means sending someone a message their app cannot open,
        /// with no error and no retry.
        ///
        /// Note a post-quantum wrap is never accompanied by a Bitchat copy of
        /// the same plaintext: it would hand a future quantum attacker the
        /// easier target and make the shield badge a lie, and it buys no
        /// reach, because a peer with an ML-KEM key is demonstrably not on
        /// Bitchat. That falls out of the rule below rather than being a
        /// special case — holding a key implies holding the announcement.
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

            return {
                pq: !!kemPk,
                kemPk: kemPk || null,
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
        _recordGroupPqCoverage(sharedId, pqCount, total) {
            if (!sharedId || !total) return;
            if (!this.pqGroupCoverage) this.pqGroupCoverage = new Map();
            this.pqGroupCoverage.set(sharedId, { pq: pqCount, total });
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

        /// Shows the upgrade notice once, if this install was upgraded into
        /// post-quantum rather than starting with it.
        ///
        /// Purely informational — there is no switch to offer. The point is to
        /// explain a confusing symptom BEFORE it happens: a second device on
        /// the same npub running an older build will quietly stop receiving
        /// messages until it updates, and that device publishes nothing, so it
        /// cannot be detected and warned directly.
        async maybeShowPqUpgradeNotice() {
            if (!this.pqUpgradeNoticePending()) return;
            if (!this.pqCapable()) { this.dismissPqUpgradeNotice(); return; }
            this.dismissPqUpgradeNotice();
            try {
                await window.showAppAlert(
                    'Your private messages and group chats with other Nymchat users are now '
                    + 'encrypted with an added post-quantum key exchange (ML-KEM-768), so traffic '
                    + 'recorded today can\u2019t be decrypted later by a quantum computer.\n\n'
                    + 'If you use this same account on another device, update it too \u2014 an '
                    + 'older version can\u2019t read the new format and will stop receiving your '
                    + 'messages until it does.\n\n'
                    + 'Bitchat users and other Nostr clients are unaffected.',
                    { title: 'Quantum-resistant encryption is on', okLabel: 'Got it' }
                );
            } catch (_) { /* dialog unavailable; the notice is not load-bearing */ }
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
