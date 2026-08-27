// mesh-service.js - the mesh above the radio

(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const P = () => G.NymMeshProtocol;
    const C = () => G.NymMeshCrypto;
    const S = () => G.NymMeshSync;
    const X = () => G.NymMeshCourier;
    const E = () => G.NymMeshExtras;

    const GHOST_FLAG_KEY = 'nym_mesh_ghost_mode';
    const GHOST_ROTATE_MS = 15 * 60 * 1000;
    const GHOST_MAX_EPOCHS = 8;

    const randomHex = (n) => P().toHex(crypto.getRandomValues(new Uint8Array(n)));

    // Ghost Mode: the mesh presence is decoupled from the real identity. Every
    // identifier an announce carries is replaced together and rotated on a
    // jittered epoch, so nothing links one epoch to the next or to the npub.
    class GhostMode {
        constructor(onRotate) {
            this.onRotate = onRotate || (() => Promise.resolve());
            this.enabled = false;
            this.epochs = [];
            this.timer = null;
        }
        get current() { return this.epochs[0] || null; }
        get pubkeys() { return this.epochs.map(e => e.nostrPubkey).filter(Boolean); }
        get secretKeys() { return this.epochs.map(e => e.nostrPrivkey).filter(Boolean); }

        async enable() {
            if (this.enabled) return;
            this.enabled = true;
            try { localStorage.setItem(GHOST_FLAG_KEY, '1'); } catch (_) { }
            await this._newEpoch();
            this._arm();
        }

        async disable() {
            this.enabled = false;
            try { localStorage.setItem(GHOST_FLAG_KEY, '0'); } catch (_) { }
            if (this.timer) { clearTimeout(this.timer); this.timer = null; }
            // Drop every key with the mode: it must leave no trail.
            this.epochs = [];
            await this.onRotate();
        }

        // Re-arms a persisted session at boot with a FRESH identity. Deliberately
        // does not fire onRotate — the caller awaits this before it starts, so
        // there is nothing to restart yet.
        async restore() {
            let was = false;
            try { was = localStorage.getItem(GHOST_FLAG_KEY) === '1'; } catch (_) { }
            if (!was || this.enabled) return;
            this.enabled = true;
            this.epochs = [await this._mint()];
            this._arm();
        }

        async rotateNow() {
            if (!this.enabled) return;
            await this._newEpoch();
            this._arm();
        }

        async _mint() {
            const T = G.NostrTools;
            const nostrPrivkey = T.generateSecretKey();
            return {
                identity: await C().MeshIdentity.ephemeral(),
                nostrPrivkey,
                nostrPubkey: T.getPublicKey(nostrPrivkey),
                // Carries no information: deriving it from the key would make
                // the two linkable if either leaked.
                nickname: 'ghost#' + randomHex(2),
                startedAt: Date.now(),
            };
        }

        async _newEpoch() {
            this.epochs = [await this._mint(), ...this.epochs].slice(0, GHOST_MAX_EPOCHS);
            await this.onRotate();
        }

        // Jittered so a rotation cannot be recognised by its period.
        _arm() {
            if (this.timer) clearTimeout(this.timer);
            const jitter = Math.floor(Math.random() * (GHOST_ROTATE_MS / 4));
            this.timer = setTimeout(async () => {
                if (!this.enabled) return;
                await this._newEpoch();
                this._arm();
            }, GHOST_ROTATE_MS + jitter);
        }
    }

    class MeshService {
        constructor(opts) {
            opts = opts || {};
            this.nickname = opts.nickname || (() => 'nym');
            this.nostrLink = opts.nostrLink || (() => null);
            this.onPublicMessage = opts.onPublicMessage || (() => { });
            this.onPrivateMessage = opts.onPrivateMessage || (() => { });
            this.onReceipt = opts.onReceipt || (() => { });
            this.onPeersChanged = opts.onPeersChanged || (() => { });
            this.onGhostChanged = opts.onGhostChanged || (() => { });
            // Gateway mode hands us a Nostr event somebody else signed. The
            // bridge VERIFIES it before publishing or displaying — a gateway is
            // a postbox, not an author.
            this.onNostrCarrier = opts.onNostrCarrier || null;
            // Completed ping probes, for the mesh diagnostics panel.
            this.onPingResult = opts.onPingResult || null;
            // Called when the prekey batch changes, so it can be written down:
            // a private half lost on reload is mail that can never be opened.
            this.onPrekeysChanged = opts.onPrekeysChanged || null;
            this.log = opts.log || (() => { });

            this.identity = null;
            this.realIdentity = null;
            this.noise = null;
            this.seen = new (P().SeenPackets)();
            // Recent public history, reconciled with neighbours so a peer that
            // was out of range — or in another mesh partition — still gets it.
            this.gossip = new (S().GossipSync)();
            this._gossipDirty = false;
            // Mail this device is carrying for other people — sealed messages
            // bound for peers who were not in range when they were sent.
            this.couriers = new (X().CourierStore)();
            // This device's one-time keys, and the batches other devices have
            // published. Sealing to a prekey the recipient DELETES after use is
            // what makes courier mail forward secret.
            this.prekeys = new (E().LocalPrekeys)();
            // ownerStaticKeyHex -> verified bundle
            this.peerPrekeys = new Map();
            // nonceHex -> { peerID, sentAt, ttl }
            this.pendingPings = new Map();
            this.reassembler = new (P().FragmentReassembler)();
            this.peers = new Map();
            this.pendingPlaintext = new Map();
            this.pendingEncrypted = new Map();
            this.running = false;
            this.announceTimer = null;
            this.cleanupTimer = null;

            this.ghost = new GhostMode(async () => {
                await this._applyIdentity();
                this.onGhostChanged(this.ghostEnabled);
            });

            // Injectable so the mesh can be exercised without a radio.
            this.transport = opts.transport || new (G.NymMeshTransport.WebBluetoothTransport)({
                onFrame: (f) => this._onFrame(f),
                onLinkChange: () => this.onPeersChanged(),
                log: this.log,
            });
            if (opts.transport) {
                opts.transport.onFrame = (f) => this._onFrame(f);
                opts.transport.onLinkChange = () => this.onPeersChanged();
            }
        }

        get ghostEnabled() { return this.ghost.enabled; }
        get peerID() { return this.identity ? this.identity.peerID : null; }
        get linkCount() { return this.transport.linkCount; }
        get linkList() { return this.transport.linkList; }
        get peerList() { return [...this.peers.values()]; }

        static isSupported() { return G.NymMeshTransport.isSupported(); }
        static cryptoSupported() { return C().cryptoSupported(); }

        async start() {
            if (this.running) return;
            this.realIdentity = await C().MeshIdentity.loadOrCreate();
            // Settle a persisted Ghost session BEFORE picking an identity, so a
            // restart can never announce the real one first.
            await this.ghost.restore();
            await this._applyIdentity();
            this.running = true;
            await this.transport.start();
            this._scheduleAnnounce();
            this.cleanupTimer = setInterval(() => this._cleanupStalePeers(), 30000);
            // Reconcile public history with whoever is in range. The per-peer
            // schedule lives in GossipSync; this tick just gives it a heartbeat.
            this.syncTimer = setInterval(() => { this._gossipTick().catch(() => { }); }, 5000);
            await this._broadcastAnnounce();
            // Publish our one-time prekeys so senders can seal courier mail to
            // a key we delete after use rather than to our long-lived identity
            // key. Broadcast and gossiped, because it has to reach people while
            // we are AWAY.
            this.publishPrekeyBundle().catch(() => { });
            this.onGhostChanged(this.ghostEnabled);
        }

        async stop() {
            if (!this.running) return;
            this.running = false;
            try {
                await this._send(await this._buildPacket({
                    type: P().MsgType.leave,
                    payload: P().utf8.encode(this.identity.peerID),
                }));
            } catch (_) { }
            if (this.announceTimer) clearTimeout(this.announceTimer);
            if (this._announceSoonTimer) { clearTimeout(this._announceSoonTimer); this._announceSoonTimer = null; }
            if (this.cleanupTimer) clearInterval(this.cleanupTimer);
            if (this.syncTimer) clearInterval(this.syncTimer);
            await this.transport.stop();
            this.noise = this.identity ? new (C().NoiseSessionManager)(this.identity) : null;
            this.seen.clear();
            this.reassembler.clear();
            this.peers.clear();
            this.pendingPlaintext.clear();
            this.pendingEncrypted.clear();
            // Probes cannot be answered once the radio is down, and a nonce
            // held across a restart would complete against a stale reply.
            this.pendingPings.clear();
            this.onPeersChanged();
        }

        async addPeer() {
            const name = await this.transport.addPeer();
            await this._broadcastAnnounce();
            return name;
        }

        forgetPeer(id) { return this.transport.forgetPeer(id); }

        async setGhostMode(on) {
            if (on) await this.ghost.enable();
            else await this.ghost.disable();
            this.onGhostChanged(this.ghostEnabled);
        }

        // Swaps the announced identity (real vs ghost epoch) and resets every
        // session keyed to the old one.
        async _applyIdentity() {
            const epoch = this.ghost.enabled ? this.ghost.current : null;
            this.identity = epoch ? epoch.identity : this.realIdentity;
            this.noise = new (C().NoiseSessionManager)(this.identity);
            this.peers.clear();
            this.pendingEncrypted.clear();
            this.onPeersChanged();
            if (this.running) await this._broadcastAnnounce();
        }

        _displayNickname() {
            const epoch = this.ghost.enabled ? this.ghost.current : null;
            return epoch ? epoch.nickname : this.nickname();
        }

        // Ghost Mode must not advertise the real Nostr identity. The epoch has
        // its own throwaway key, so peers can still reach it without anything
        // resolving to the user's npub.
        async _nostrLinkValue() {
            const epoch = this.ghost.enabled ? this.ghost.current : null;
            if (!epoch) return this.nostrLink();
            try {
                const T = G.NostrTools;
                const msgHex = await C().NostrLink.messageHex(this.identity.staticPublic);
                const sig = T._secp256k1.schnorr.sign(P().fromHex(msgHex), epoch.nostrPrivkey);
                return C().NostrLink.build(epoch.nostrPubkey, P().toHex(sig));
            } catch (_) {
                return null;
            }
        }

        /// Probes `peerID`: are you there, and how many links away?
        ///
        /// A peer list cannot tell the difference between someone in the same
        /// room and someone three relays away. The reply carries the TTL this
        /// packet was LAUNCHED with, so the hop count falls out of comparing it
        /// against the TTL that arrives. The nonce is unguessable, so only a
        /// genuine answer to this probe can complete it.
        async ping(peerID, ttl) {
            const recipient = P().fromHex(peerID);
            if (!recipient || recipient.length !== 8) return false;
            const launch = ttl === undefined ? P().MeshConst.messageTtl : ttl;
            const nonce = crypto.getRandomValues(new Uint8Array(E().PING_NONCE_LENGTH));
            const payload = E().encodePing(nonce, launch);
            if (!payload) return false;
            const key = P().toHex(nonce);
            this.pendingPings.set(key, { peerID, sentAt: Date.now(), ttl: launch });
            try {
                await this._send(await this._buildPacket({
                    type: P().MsgType.ping, payload, recipientID: recipient, ttl: launch,
                }));
                return true;
            } catch (_) {
                this.pendingPings.delete(key);
                return false;
            }
        }

        /// Answers a probe by echoing its nonce, with our own launch TTL so the
        /// far end can measure the return path too.
        async _handlePing(packet, senderPeerID) {
            const probe = E().decodePing(packet.payload);
            if (!probe) return;
            const recipient = P().fromHex(senderPeerID);
            if (!recipient || recipient.length !== 8) return;
            const ttl = P().MeshConst.messageTtl;
            const reply = E().encodePing(probe.nonce, ttl);
            if (!reply) return;
            try {
                await this._send(await this._buildPacket({
                    type: P().MsgType.pong, payload: reply, recipientID: recipient, ttl,
                }));
            } catch (_) { }
        }

        /// Completes a probe. An unknown nonce is dropped in silence: it answers
        /// a probe we never sent, which is a stale reply or somebody guessing.
        _handlePong(packet, senderPeerID) {
            const reply = E().decodePing(packet.payload);
            if (!reply) return;
            const key = P().toHex(reply.nonce);
            const pending = this.pendingPings.get(key);
            if (!pending) return;
            this.pendingPings.delete(key);
            if (pending.peerID !== senderPeerID) return;
            const rtt = Date.now() - pending.sentAt;
            const hops = E().hopCount(reply.originTtl, packet.ttl);
            this.log(`pong from ${senderPeerID} rtt=${rtt}ms hops=${hops === null ? '?' : hops}`);
            if (this.onPingResult) {
                try { this.onPingResult({ peerID: senderPeerID, roundTripMs: rtt, hops }); } catch (_) { }
            }
        }

        /// Asks `gatewayPeerID` to publish a signed Nostr event for us.
        ///
        /// The sender outbox waits for OUR internet to come back. This does
        /// not: one peer with a signal is enough for the whole room. The event
        /// is signed by us before it leaves, so the gateway is a postbox — it
        /// cannot alter or forge what it publishes, and the relays would reject
        /// it if it tried.
        async carryToGateway(gatewayPeerID, geohash, event) {
            const recipient = P().fromHex(gatewayPeerID);
            if (!recipient || recipient.length !== 8) return false;
            const payload = E().encodeCarrier(E().CARRIER_DIRECTION.toGateway,
                geohash, P().utf8.encode(JSON.stringify(event)));
            if (!payload) return false;
            try {
                await this._send(await this._buildPacket({
                    type: P().MsgType.nostrCarrier, payload, recipientID: recipient,
                }));
                return true;
            } catch (_) { return false; }
        }

        /// Rebroadcasts a relay event to mesh-only peers, so they can READ a
        /// geohash channel and not only write to it.
        async broadcastFromGateway(geohash, event) {
            const payload = E().encodeCarrier(E().CARRIER_DIRECTION.fromGateway,
                geohash, P().utf8.encode(JSON.stringify(event)));
            if (!payload) return false;
            try {
                await this._send(await this._buildPacket({
                    type: P().MsgType.nostrCarrier, payload,
                    recipientID: P().BROADCAST_RECIPIENT,
                }));
                return true;
            } catch (_) { return false; }
        }

        _handleNostrCarrier(packet, senderPeerID) {
            const carrier = E().decodeCarrier(packet.payload);
            if (!carrier) return;
            this.log(`nostr carrier dir=${carrier.direction} geo=${carrier.geohash} from ${senderPeerID}`);
            // The bridge verifies the signature before publishing or
            // displaying. A gateway relays; it does not vouch.
            if (this.onNostrCarrier) {
                try { this.onNostrCarrier(carrier, senderPeerID); } catch (_) { }
            }
        }

        /// Signs and broadcasts our current batch of one-time prekeys.
        ///
        /// Broadcast rather than directed, and gossip-synced, because the whole
        /// point is that a bundle reaches senders while we are AWAY. Anyone
        /// holding our announce-verified signing key can check it offline, so it
        /// can spread through devices that have never spoken to us.
        async publishPrekeyBundle() {
            if (!this.identity) return false;
            // Never while ghosted. Courier mail to or from a ghost is refused at
            // both ends (mayDeposit), so the bundle could not deliver anything —
            // it would only be one more thing the epoch broadcasts.
            if (this.ghostEnabled) return false;
            if (await this.prekeys.replenish()) await this._savePrekeys();
            const available = this.prekeys.available;
            if (!available.length) return false;
            const bundle = {
                noiseStaticPublicKey: this.identity.staticPublic,
                prekeys: available.map(k => ({ id: k.id, publicKey: k.publicKey })),
                generatedAtMs: Date.now(),
                signature: new Uint8Array(E().PREKEY_SIGNATURE_LENGTH),
            };
            bundle.signature = await this.identity.sign(E().prekeySignableBytes(bundle));
            const payload = E().encodePrekeyBundle(bundle);
            if (!payload) return false;
            try {
                const pkt = await this._buildPacket({
                    type: P().MsgType.prekeyBundle, payload,
                    recipientID: P().BROADCAST_RECIPIENT,
                });
                await this._send(pkt);
                // Our own bundle never comes back to us on the air, so file it
                // here or we would gossip everyone's batch except our own.
                await this._rememberOwnPublic(pkt);
                return true;
            } catch (_) { return false; }
        }

        /// Files a peer's bundle after verifying it against the signing key
        /// their announce bound to that Noise key.
        ///
        /// Verification is what makes gossip safe: without it anyone could
        /// publish prekeys "for" someone else and harvest mail sealed to keys
        /// they hold.
        async _handlePrekeyBundle(packet, senderPeerID) {
            const bundle = E().decodePrekeyBundle(packet.payload);
            if (!bundle) return;
            const ownerHex = P().toHex(bundle.noiseStaticPublicKey);
            // The signing key comes from the owner's own verified announce, NOT
            // from the packet — a relayed bundle's carrier is not its author.
            const ownerPeerID = await C().derivePeerID(bundle.noiseStaticPublicKey);
            const owner = this.peers.get(ownerPeerID);
            if (!owner || !owner.isVerified || !owner.signingPublicKey) {
                this.log('prekey bundle from unknown/unverified owner — dropped');
                return;
            }
            const existing = this.peerPrekeys.get(ownerHex);
            // A newer bundle replaces an older one; an older one is refused so a
            // replayed bundle cannot resurrect keys its owner already deleted.
            if (existing && existing.generatedAtMs >= bundle.generatedAtMs) return;
            const ok = await C().ed25519Verify(owner.signingPublicKey, bundle.signature,
                E().prekeySignableBytes(bundle));
            if (!ok) {
                this.log('prekey bundle signature FAILED — dropped');
                return;
            }
            this.peerPrekeys.set(ownerHex, bundle);
            this.log(`prekey bundle from ${ownerPeerID}: ${bundle.prekeys.length} key(s)`);
        }

        async _savePrekeys() {
            if (!this.onPrekeysChanged) return;
            try { this.onPrekeysChanged(await this.prekeys.encode()); } catch (_) { }
        }

        /// Restores the batch minted before the last reload. Without it every
        /// restart would orphan the mail already sealed to those keys.
        async restorePrekeys(raw) {
            try { await this.prekeys.decode(raw); } catch (_) { }
        }

        /// Seals `payload` to a peer's static key and hands sealed copies to
        /// nearby peers, who carry it and deliver it if they meet the recipient.
        ///
        /// The last-resort delivery path: the recipient is not in range and,
        /// with no internet, the sender outbox cannot help either. Returns how
        /// many couriers took a copy — zero when the deposit was refused, which
        /// the caller should treat as "no worse off", never as an error.
        ///
        /// Refusal is the important half. `mayDeposit` blocks a ghost-pinned
        /// conversation and a ghosted sender outright: handing an envelope to a
        /// courier tells that courier a message exists and that we sent it, and
        /// a ghost identity exists precisely so no such link is made.
        async depositWithCouriers(recipientStaticKey, payload, copies) {
            const ghosted = !!this.ghostEnabled;
            const pinned = this.isGhostPinned
                ? !!this.isGhostPinned(P().toHex(recipientStaticKey || new Uint8Array(0))) : false;
            if (!X().mayDeposit({
                isGhostPinned: pinned,
                isGhostMode: ghosted,
                hasRecipientStaticKey: !!recipientStaticKey && recipientStaticKey.length === 32,
            })) {
                this.log('courier deposit refused (ghost/no key)');
                return 0;
            }
            const now = Date.now();
            // Prefer a one-time PREKEY over the long-lived static key when the
            // recipient has published one. Both seal the same way; the
            // difference is that they DELETE a prekey after use, so an envelope
            // captured in transit cannot be opened later even if their identity
            // key is compromised. Falling back to the static key keeps mail
            // flowing to a peer whose bundle we have never seen — worse
            // secrecy, but delivered.
            const bundle = this.peerPrekeys.get(P().toHex(recipientStaticKey));
            const prekey = bundle ? this.prekeys.chooseFrom(bundle.prekeys) : null;
            let sealed;
            try {
                sealed = await X().sealCourier(payload,
                    prekey ? prekey.publicKey : recipientStaticKey,
                    this.identity.staticPrivate, this.identity.staticPublic,
                    prekey ? X().prekeyPrologue(prekey.id) : null);
            } catch (err) {
                this.log('courier seal failed: ' + (err && err.message));
                return 0;
            }
            const bytes = X().encodeEnvelope({
                // The TAG is always derived from the identity key, prekey or
                // not: it is how the recipient recognises their own mail, and
                // they cannot look up an envelope by a prekey they may already
                // have retired.
                recipientTag: await X().recipientTagFor(recipientStaticKey, X().epochDayFor(now)),
                expiryMs: now + X().MAX_LIFETIME_MS,
                ciphertext: sealed,
                copies: copies === undefined ? 4 : copies,
                prekeyId: prekey ? prekey.id : undefined,
            });
            if (!bytes) return 0;
            // Awaited: derivePeerID is async, and an unresolved promise here
            // would never equal a peerID, so mayCourier's "not the recipient"
            // guard would silently never fire.
            const recipientPeerID = await C().derivePeerID(recipientStaticKey);
            let handed = 0;
            for (const peer of this.peers.values()) {
                if (handed >= this.couriers.maxCouriersPerDeposit) break;
                if (!X().mayCourier({
                    isVerified: peer.isVerified,
                    isSelf: peer.peerID === this.identity.peerID,
                    isRecipient: recipientPeerID && peer.peerID === recipientPeerID,
                })) continue;
                try {
                    await this._send(await this._buildPacket({
                        type: P().MsgType.courierEnvelope,
                        payload: bytes,
                        recipientID: P().fromHex(peer.peerID),
                        ttl: 0,
                    }));
                    handed++;
                } catch (_) {
                    // A courier that will not take it is not a failure.
                }
            }
            this.log(`courier deposit: ${handed} carrier(s)`);
            return handed;
        }

        /// An envelope arrived: either it is ours — open and deliver it — or it
        /// is somebody else's mail we have been asked to carry.
        async _handleCourierEnvelope(packet, senderPeerID) {
            const envelope = X().decodeEnvelope(packet.payload);
            if (!envelope) return;
            const now = Date.now();
            if (now >= envelope.expiryMs) return;

            // Is it for us? Only the recipient can open it, so this is the
            // test. A v2 envelope names the prekey it was sealed to; if that key
            // was never ours (or its grace window has lapsed) the open fails and
            // we simply carry it, exactly as for any other stranger's mail.
            const pkId = envelope.prekeyId;
            const pkPriv = pkId === undefined ? null : this.prekeys.privateKeyFor(pkId);
            const pkPub = pkId === undefined ? null : this.prekeys.publicKeyFor(pkId);
            try {
                if (pkId !== undefined && (!pkPriv || !pkPub)) throw new Error('not our prekey');
                const opened = await X().openCourier(envelope.ciphertext,
                    pkPriv || this.identity.staticPrivate,
                    pkPub || this.identity.staticPublic,
                    pkId === undefined ? null : X().prekeyPrologue(pkId));
                if (pkId !== undefined && this.prekeys.markConsumed(pkId)) {
                    // First open of this key: republish the shrunken batch.
                    // Redeliveries of the same envelope arrive later
                    // (spray-and-wait), so the private half survives a grace
                    // window before it is really deleted.
                    await this._savePrekeys();
                    this.publishPrekeyBundle().catch(() => { });
                }
                // The sender's static key is AUTHENTICATED by the seal's `ss`
                // DH, so this is who really wrote it — not whoever handed it on.
                const originPeerID = await C().derivePeerID(opened.senderStaticKey);
                this.log(`courier envelope OPENED from ${originPeerID} (carried by ${senderPeerID})`);
                await this._dispatchNoisePayload(originPeerID, opened.payload);
                return;
            } catch (_) {
                // Not ours. That is the ordinary case — carry it.
            }

            const key = P().toHex((await C().sha256(envelope.ciphertext)).subarray(0, 16));
            if (this.couriers.accept(envelope, key)) {
                this.log(`carrying courier envelope (copies=${envelope.copies})`);
                this.couriers.markHandedTo(key, senderPeerID);
            }
        }

        /// A peer just became known: hand them any mail we carry for them, and
        /// give them a share of anything that still has budget to spread.
        async _courierEncounter(peer) {
            if (!this.couriers.size) return;
            const recipient = P().fromHex(peer.peerID);
            if (!recipient || recipient.length !== 8) return;
            const now = Date.now();

            if (peer.noisePublicKey && peer.noisePublicKey.length === 32) {
                const tags = await X().candidateTagsFor(peer.noisePublicKey, now);
                for (const [key, held] of this.couriers.forTags(tags)) {
                    const bytes = X().encodeEnvelope(held.envelope);
                    if (!bytes) continue;
                    try {
                        await this._send(await this._buildPacket({
                            type: P().MsgType.courierEnvelope,
                            payload: bytes, recipientID: recipient, ttl: 0,
                        }));
                        // Delivered: stop carrying it. If the peer could not
                        // open it after all, the sender's own retries cover it.
                        this.couriers.drop(key);
                        this.log(`courier delivered to ${peer.peerID}`);
                    } catch (_) { }
                }
            }

            // Spray: hand a share on so the message keeps spreading toward a
            // recipient neither of us has met. Only to a VERIFIED peer — an
            // unverified one is a radio claiming a name, and telling it we carry
            // mail is telling a stranger.
            if (!X().mayCourier({ isVerified: peer.isVerified, isSelf: false, isRecipient: false })) return;
            for (const [key, held] of this.couriers.sprayableTo(peer.peerID)) {
                const share = X().sprayShare(held.envelope.copies);
                if (share <= 0) continue;
                const bytes = X().encodeEnvelope({ ...held.envelope, copies: share });
                if (!bytes) continue;
                try {
                    await this._send(await this._buildPacket({
                        type: P().MsgType.courierEnvelope,
                        payload: bytes, recipientID: recipient, ttl: 0,
                    }));
                    this.couriers.setCopies(key, X().keepShare(held.envelope.copies));
                    this.couriers.markHandedTo(key, peer.peerID);
                } catch (_) { }
            }
        }

        /// Files one of OUR public sends into the gossip store.
        ///
        /// The inbound path never sees our own packets (it drops self-echoes),
        /// so without this a device would carry everyone's history except its
        /// own — and the message a user actually sent in a dead spot would be
        /// the one thing it could not serve to whoever arrived a minute later.
        async _rememberOwnPublic(packet) {
            if (!P().isBroadcast(packet) || !S().isSyncable(packet.type)) return;
            if (await this.gossip.onPublicPacketSeen(packet, P().isBroadcast)) {
                this._gossipDirty = true;
            }
        }

        /// Asks each connected peer, on its own schedule, to reconcile public
        /// history: "here is a compact set of what I hold — send me the rest".
        ///
        /// Directed rather than broadcast, and TTL 0 so it is never relayed: a
        /// sync request is a question for the peer that can hear it, and
        /// flooding it would ask the whole mesh something only neighbours can
        /// answer.
        async _gossipTick() {
            if (!this.running) return;
            if (this.gossip.prune()) this._gossipDirty = true;
            // Mail we are carrying expires too — someone else's message is not
            // worth holding forever.
            this.couriers.prune();
            // Delete consumed prekeys whose grace window has lapsed. This is
            // where forward secrecy actually happens: until the private half is
            // really gone, privateKeyFor only declines to use it.
            if (this.prekeys.prune()) await this._savePrekeys();
            if (this._gossipDirty) {
                this._gossipDirty = false;
                if (this.onGossipArchiveChanged) {
                    try { this.onGossipArchiveChanged(this._encodeGossipArchive()); } catch (_) { }
                }
            }
            for (const peerID of [...this.peers.keys()]) {
                if (!this.gossip.shouldAsk(peerID)) continue;
                this.gossip.markAsked(peerID);
                const recipient = P().fromHex(peerID);
                if (!recipient || recipient.length !== 8) continue;
                try {
                    await this._send(await this._buildPacket({
                        type: P().MsgType.requestSync,
                        payload: this.gossip.buildRequest(),
                        recipientID: recipient,
                        ttl: 0,
                    }));
                } catch (_) {
                    // A failed sync round costs history, never the session.
                }
            }
        }

        /// Answers a peer's reconciliation request with what their filter says
        /// they are missing. Responses go out DIRECTED with TTL 0 — the
        /// requester asked, nobody else did, and a replayed public message
        /// re-entering the flood would go round the mesh a second time.
        async _handleRequestSync(packet, senderPeerID) {
            if (!this.gossip.shouldAnswer(senderPeerID)) return;
            const request = S().decodeRequestSync(packet.payload);
            if (!request) return;
            this.gossip.markAnswered(senderPeerID);
            const missing = this.gossip.packetsMissingFrom(request);
            if (!missing.length) return;
            this.log(`sync -> ${senderPeerID}: ${missing.length} packet(s)`);
            const recipient = P().fromHex(senderPeerID);
            for (const pkt of missing) {
                try {
                    // Re-addressed to the requester: the original was a
                    // broadcast, and re-broadcasting hands it to peers who
                    // already have it.
                    await this._send(P().makePacket({ ...pkt, recipientID: recipient, ttl: 0 }));
                } catch (_) {
                    // One packet failing must not abandon the round.
                }
            }
        }

        _encodeGossipArchive() {
            const rows = [];
            for (const v of this.gossip.messageList) {
                const bytes = P().encodePacket(v.packet, false);
                if (!bytes) continue;
                rows.push(btoa(String.fromCharCode(...bytes)));
            }
            return JSON.stringify(rows);
        }

        /// Restores the carried history. Contents are signed public broadcasts,
        /// already visible to anyone who was in radio range, so they are stored
        /// as-is — nothing private ever reaches this store.
        async restoreGossipArchive(raw) {
            if (!raw) return;
            let rows;
            try { rows = JSON.parse(raw); } catch (_) { return; }
            if (!Array.isArray(rows)) return;
            for (const row of rows) {
                if (typeof row !== 'string') continue;
                try {
                    const bin = atob(row);
                    const bytes = new Uint8Array(bin.length);
                    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                    const pkt = await P().decodePacketAsync(bytes);
                    if (pkt) await this.gossip.onPublicPacketSeen(pkt, P().isBroadcast);
                } catch (_) {
                    // One unreadable row costs one message.
                }
            }
        }

        async _buildPacket(o) {
            const packet = P().makePacket({
                type: o.type,
                senderID: this.identity.peerIdBytes,
                recipientID: o.recipientID || null,
                timestamp: Date.now(),
                payload: o.payload,
                ttl: o.ttl === undefined ? P().MeshConst.messageTtl : o.ttl,
            });
            if (o.sign) {
                const signable = P().packetSigningBytes(packet);
                if (signable) packet.signature = await this.identity.sign(signable);
            }
            return packet;
        }

        async _send(packet, exceptLinkId) {
            const parts = P().fragmentPacket(packet);
            for (let i = 0; i < parts.length; i++) {
                const bytes = P().encodePacket(parts[i], true);
                if (!bytes) continue;
                await this.transport.broadcast(bytes, exceptLinkId);
                // Pace multi-fragment transfers so a peer's bounded send queue
                // doesn't drop fragments, which would make the payload
                // unreassemblable.
                if (i + 1 < parts.length) await new Promise(r => setTimeout(r, P().MeshConst.interFragmentDelayMs));
            }
        }

        async _broadcastAnnounce() {
            if (!this.identity) return;
            const payload = P().encodeAnnouncement({
                nickname: this._displayNickname(),
                noisePublicKey: this.identity.staticPublic,
                signingPublicKey: this.identity.signPublic,
                nostrLink: await this._nostrLinkValue(),
            });
            if (!payload) return;
            await this._send(await this._buildPacket({
                type: P().MsgType.announce,
                payload,
                recipientID: P().BROADCAST_RECIPIENT,
                sign: true,
            }));
        }

        _scheduleAnnounce() {
            if (this.announceTimer) clearTimeout(this.announceTimer);
            const K = P().MeshConst;
            const base = this.peers.size > 0 ? K.announceIntervalMs : K.announceIntervalIdleMs;
            const jitter = Math.floor((Math.random() * 2 - 1) * K.announceJitterMs);
            this.announceTimer = setTimeout(async () => {
                if (!this.running) return;
                await this._broadcastAnnounce();
                this._scheduleAnnounce();
            }, Math.max(5000, base + jitter));
        }

        /// Sends a public message. [channel] null is bitchat's #mesh public chat.
        /// Returns the mesh message id. The sender outbox republishes it as a
        /// `['nymmesh', id]` tag so a peer who already received this over the
        /// radio drops the Nostr copy instead of showing the message twice.
        async sendPublicMessage(content, channel) {
            if (!this.running) throw new Error('mesh not running');
            const msgId = randomHex(8);
            if (channel) {
                const payload = P().encodeBitchatMessage({
                    id: msgId,
                    sender: this._displayNickname(),
                    content,
                    timestampMs: Date.now(),
                    senderPeerID: this.identity.peerID,
                    channel,
                });
                const chanPacket = await this._buildPacket({
                    type: P().MsgType.nymChannelMessage,
                    payload,
                    recipientID: P().BROADCAST_RECIPIENT,
                    sign: true,
                });
                await this._send(chanPacket);
                await this._rememberOwnPublic(chanPacket);
                return msgId;
            }
            // bitchat's public mesh chat carries the RAW UTF-8 content, not a
            // TLV; the nickname comes from the peer's announce. The packet
            // carries no id of its own, so the outbox has none to dedup on —
            // a `#mesh` send is only ever queued when it was made offline, and
            // that channel is not mirrored to Nostr anyway.
            const meshPacket = await this._buildPacket({
                type: P().MsgType.message,
                payload: P().utf8.encode(content),
                recipientID: P().BROADCAST_RECIPIENT,
                sign: true,
            });
            await this._send(meshPacket);
            await this._rememberOwnPublic(meshPacket);
            return null;
        }

        /// Sends a private message to [peerID], handshaking first if needed.
        async sendPrivateMessage(peerID, content) {
            if (!this.running) throw new Error('mesh not running');
            const chunks = this._chunk(content);
            const ids = [];
            for (const chunk of chunks) {
                const id = randomHex(8);
                ids.push(id);
                const body = P().encodePrivateMessage(id, chunk);
                if (!body) continue;
                await this._sendOrQueueEncrypted(peerID, P().encodeNoisePayload(P().NoisePayloadType.privateMessage, body));
            }
            return ids[0];
        }

        _chunk(content) {
            const bytes = P().utf8.encode(content);
            const max = P().PM_MAX_CONTENT_BYTES;
            if (bytes.length <= max) return [content];
            const out = [];
            let start = 0;
            while (start < bytes.length) {
                let end = Math.min(start + max, bytes.length);
                // Don't split a multi-byte character.
                while (end > start && end < bytes.length && (bytes[end] & 0xC0) === 0x80) end--;
                out.push(P().utf8d.decode(bytes.subarray(start, end)));
                start = end;
            }
            return out;
        }

        async _sendOrQueueEncrypted(peerID, plaintext) {
            if (!this.noise.isEstablished(peerID)) {
                const queue = this.pendingPlaintext.get(peerID) || [];
                queue.push(plaintext);
                this.pendingPlaintext.set(peerID, queue);
                if (!this.noise.isHandshaking(peerID)) {
                    const msg = await this.noise.initiateHandshake(peerID);
                    await this._send(await this._buildPacket({
                        type: P().MsgType.noiseHandshake,
                        payload: msg,
                        recipientID: P().fromHex(peerID),
                    }));
                }
                return;
            }
            const ct = this.noise.encrypt(peerID, plaintext);
            await this._send(await this._buildPacket({
                type: P().MsgType.noiseEncrypted,
                payload: ct,
                recipientID: P().fromHex(peerID),
            }));
        }

        async _flushPending(peerID) {
            const queue = this.pendingPlaintext.get(peerID);
            if (!queue) return;
            this.pendingPlaintext.delete(peerID);
            for (const plaintext of queue) await this._sendOrQueueEncrypted(peerID, plaintext);
        }

        // receiving
        async _onFrame(frame) {
            const packet = await P().decodePacketAsync(frame.data);
            if (!packet) return;
            try {
                await this._processPacket(packet, frame.linkId, frame.rssi);
            } catch (err) {
                this.log('packet error: ' + (err && err.message));
            }
        }

        async _processPacket(packet, linkId, rssi, alreadyRelayed) {
            const senderPeerID = P().toHex(packet.senderID);
            if (senderPeerID === this.identity.peerID) return;

            const key = P().SeenPackets.keyFor(packet.type, packet.senderID, packet.timestamp, packet.payload);
            if (!this.seen.checkAndAdd(key)) return;

            const T = P().MsgType;
            const mine = this.identity.peerID;
            const directedToUs = !!packet.recipientID && !P().isBroadcast(packet) &&
                P().toHex(packet.recipientID) === mine;
            const forUs = !packet.recipientID || P().isBroadcast(packet) || directedToUs;

            switch (packet.type) {
                case T.announce: await this._handleAnnounce(packet, senderPeerID, rssi); break;
                case T.message: this._handlePublicMessage(packet, senderPeerID); break;
                case T.nymChannelMessage: this._handleChannelMessage(packet, senderPeerID); break;
                case T.leave: this._removePeer(senderPeerID); break;
                case T.noiseHandshake: if (forUs) await this._handleHandshake(senderPeerID, packet.payload); break;
                case T.noiseEncrypted: if (forUs) await this._handleEncrypted(senderPeerID, packet.payload); break;
                case T.fragment: await this._handleFragment(packet, linkId, rssi); break;
                case T.courierEnvelope:
                    // Directed mail. Try to open it: if it is ours, deliver it;
                    // if not, carry it for whoever it belongs to.
                    if (forUs) await this._handleCourierEnvelope(packet, senderPeerID);
                    break;
                case T.requestSync:
                    // Local-only by design: a sync request is answered by the
                    // peer that heard it and never relayed.
                    if (forUs) await this._handleRequestSync(packet, senderPeerID);
                    break;
                case T.ping: if (forUs) await this._handlePing(packet, senderPeerID); break;
                case T.pong: if (forUs) this._handlePong(packet, senderPeerID); break;
                case T.prekeyBundle:
                    // Broadcast and gossiped: a bundle has to reach senders
                    // while its owner is away, which is exactly when it matters.
                    await this._handlePrekeyBundle(packet, senderPeerID);
                    break;
                case T.nostrCarrier:
                    // Either a mesh-only peer asking us to publish for them, or
                    // a gateway handing the room what the relays said.
                    if (forUs) this._handleNostrCarrier(packet, senderPeerID);
                    break;
                default: break;
            }

            // Remember public traffic so this device can serve it to a peer who
            // was out of range when it went by. Directed packets are refused
            // inside — the store is public history, never anybody's private mail.
            if (P().isBroadcast(packet) && S().isSyncable(packet.type)) {
                if (await this.gossip.onPublicPacketSeen(packet, P().isBroadcast)) {
                    this._gossipDirty = true;
                }
            }

            // Relay the controlled flood, but never a packet addressed only to
            // us, and never back down the hop it arrived on. A reassembled
            // packet is not relayed again: its fragments already were, and
            // re-fragmenting the whole thing would double the air time.
            if (!alreadyRelayed && !directedToUs && packet.ttl > 1 && packet.type !== T.leave) {
                this._scheduleRelay(packet, linkId);
            }
        }

        _scheduleRelay(packet, linkId) {
            const K = P().MeshConst;
            const delay = K.relayJitterMinMs + Math.floor(Math.random() * (K.relayJitterMaxMs - K.relayJitterMinMs));
            setTimeout(() => {
                if (!this.running) return;
                const relayed = P().makePacket({
                    version: packet.version, type: packet.type, senderID: packet.senderID,
                    recipientID: packet.recipientID, timestamp: packet.timestamp,
                    payload: packet.payload, signature: packet.signature,
                    ttl: packet.ttl - 1, route: packet.route,
                });
                this._send(relayed, linkId).catch(() => { });
            }, delay);
        }

        async _handleFragment(packet, linkId, rssi) {
            const fragment = P().decodeFragment(packet.payload);
            if (!fragment) return;
            const full = this.reassembler.accept(fragment);
            if (!full) return;
            const inner = await P().decodePacketAsync(full);
            if (inner) await this._processPacket(inner, linkId, rssi, true);
        }

        async _handleAnnounce(packet, senderPeerID, rssi) {
            const ann = P().decodeAnnouncement(packet.payload);
            if (!ann) return;

            let verified = false;
            // The peerID must be the fingerprint of the announced Noise key, and
            // a signed announcement must verify against the announced Ed25519 key.
            if (await C().matchesClaimedPeerID(senderPeerID, ann.noisePublicKey) && packet.signature) {
                const signable = P().packetSigningBytes(packet);
                verified = !!signable && await C().ed25519Verify(ann.signingPublicKey, packet.signature, signable);
            }

            let peer = this.peers.get(senderPeerID);
            const isNew = !peer;
            if (!peer) { peer = { peerID: senderPeerID }; this.peers.set(senderPeerID, peer); }
            peer.nickname = ann.nickname;
            peer.noisePublicKey = ann.noisePublicKey;
            peer.signingPublicKey = ann.signingPublicKey;
            peer.isVerified = verified;
            peer.rssi = rssi;
            peer.lastSeen = Date.now();

            if (ann.nostrLink) {
                const linked = await C().NostrLink.verify(ann.nostrLink, ann.noisePublicKey);
                if (linked) { peer.nostrPubkey = linked; peer.nostrLinkVerified = true; }
            }
            this.onPeersChanged();
            // A browser cannot advertise, so a peer only learns us from an
            // announce we send. Answer a newly seen one promptly instead of
            // waiting out the idle interval, or the link stays one-way.
            if (isNew) this._announceSoon();
            // Meeting a peer is the moment mail can move: hand them anything we
            // carry for them, and a share of anything still spreading.
            this._courierEncounter(peer).catch(() => { });
        }

        // Debounced + jittered so a room full of peers announcing at once
        // produces one reply, not a storm.
        _announceSoon() {
            if (this._announceSoonTimer) return;
            this._announceSoonTimer = setTimeout(async () => {
                this._announceSoonTimer = null;
                if (!this.running) return;
                await this._broadcastAnnounce();
                this._scheduleAnnounce();
            }, 150 + Math.floor(Math.random() * 500));
        }

        _handlePublicMessage(packet, senderPeerID) {
            const content = P().utf8d.decode(packet.payload);
            if (!content) return;
            const peer = this._touchPeer(senderPeerID);
            this.onPublicMessage({
                senderPeerID,
                senderNickname: (peer && peer.nickname) || senderPeerID,
                senderNostrPubkey: peer && peer.nostrPubkey,
                content,
                timestampMs: packet.timestamp,
                channel: null,
            });
        }

        _handleChannelMessage(packet, senderPeerID) {
            const msg = P().decodeBitchatMessage(packet.payload);
            if (!msg || msg.isEncrypted) return;
            const peer = this._touchPeer(senderPeerID);
            this.onPublicMessage({
                // The sender's outbox republishes this id as a `['nymmesh', id]`
                // tag when their internet returns, so a receiver that already
                // has this message can drop the Nostr copy.
                id: msg.id || null,
                senderPeerID,
                senderNickname: msg.sender || (peer && peer.nickname) || senderPeerID,
                senderNostrPubkey: peer && peer.nostrPubkey,
                content: msg.content,
                timestampMs: msg.timestampMs || packet.timestamp,
                channel: msg.channel,
            });
        }

        async _handleHandshake(senderPeerID, payload) {
            try {
                const response = await this.noise.handleHandshake(senderPeerID, payload);
                if (response) {
                    await this._send(await this._buildPacket({
                        type: P().MsgType.noiseHandshake,
                        payload: response,
                        recipientID: P().fromHex(senderPeerID),
                    }));
                }
                if (this.noise.isEstablished(senderPeerID)) {
                    await this._flushPending(senderPeerID);
                    await this._drainPendingEncrypted(senderPeerID);
                }
            } catch (_) {
                // Handshake failed or the peerID binding was rejected.
            }
        }

        async _handleEncrypted(senderPeerID, payload) {
            if (!this.noise.isEstablished(senderPeerID)) {
                // Still handshaking: hold the frame rather than dropping it.
                const q = this.pendingEncrypted.get(senderPeerID) || [];
                q.push(payload);
                this.pendingEncrypted.set(senderPeerID, q);
                return;
            }
            let plaintext;
            try { plaintext = this.noise.decrypt(senderPeerID, payload); } catch (_) { return; }
            await this._dispatchNoisePayload(senderPeerID, plaintext);
        }

        /// Handles a decrypted transport payload from `senderPeerID`.
        ///
        /// Shared by the live Noise session path and the courier path: an
        /// envelope opened out of a courier's hands yields the SAME plaintext a
        /// session would have, so a message that arrived by mail behaves
        /// exactly like one that arrived over the air.
        async _dispatchNoisePayload(senderPeerID, plaintext) {
            const envelope = P().decodeNoisePayload(plaintext);
            if (!envelope) return;
            const NP = P().NoisePayloadType;

            if (envelope.type === NP.privateMessage) {
                const pm = P().decodePrivateMessage(envelope.data);
                if (!pm) return;
                const peer = this._touchPeer(senderPeerID);
                this.onPrivateMessage({
                    senderPeerID,
                    senderNickname: (peer && peer.nickname) || senderPeerID,
                    senderNostrPubkey: peer && peer.nostrPubkey,
                    messageId: pm.messageID,
                    content: pm.content,
                    timestampMs: Date.now(),
                });
                await this._sendOrQueueEncrypted(senderPeerID,
                    P().encodeNoisePayload(NP.delivered, P().utf8.encode(pm.messageID)));
            } else if (envelope.type === NP.delivered || envelope.type === NP.readReceipt) {
                this.onReceipt({
                    fromPeerID: senderPeerID,
                    messageId: P().utf8d.decode(envelope.data),
                    isRead: envelope.type === NP.readReceipt,
                });
            }
        }

        async _drainPendingEncrypted(peerID) {
            const q = this.pendingEncrypted.get(peerID);
            if (!q) return;
            this.pendingEncrypted.delete(peerID);
            for (const payload of q) await this._handleEncrypted(peerID, payload);
        }

        async sendReadReceipt(peerID, messageId) {
            await this._sendOrQueueEncrypted(peerID,
                P().encodeNoisePayload(P().NoisePayloadType.readReceipt, P().utf8.encode(messageId)));
        }

        _touchPeer(peerID) {
            let peer = this.peers.get(peerID);
            if (!peer) { peer = { peerID }; this.peers.set(peerID, peer); }
            peer.lastSeen = Date.now();
            return peer;
        }

        _removePeer(peerID) {
            if (this.peers.delete(peerID)) {
                this.noise.remove(peerID);
                this.onPeersChanged();
            }
        }

        _cleanupStalePeers() {
            const cutoff = Date.now() - P().MeshConst.stalePeerTimeoutMs;
            let changed = false;
            for (const [id, peer] of this.peers) {
                if ((peer.lastSeen || 0) < cutoff) { this.peers.delete(id); this.noise.remove(id); changed = true; }
            }
            if (changed) this.onPeersChanged();
        }
    }

    G.NymMeshService = { MeshService, GhostMode, GHOST_FLAG_KEY };
})();
