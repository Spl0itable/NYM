// mesh-service.js - the mesh above the radio

(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const P = () => G.NymMeshProtocol;
    const C = () => G.NymMeshCrypto;

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
            this.log = opts.log || (() => { });

            this.identity = null;
            this.realIdentity = null;
            this.noise = null;
            this.seen = new (P().SeenPackets)();
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
            await this._broadcastAnnounce();
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
            await this.transport.stop();
            this.noise = this.identity ? new (C().NoiseSessionManager)(this.identity) : null;
            this.seen.clear();
            this.reassembler.clear();
            this.peers.clear();
            this.pendingPlaintext.clear();
            this.pendingEncrypted.clear();
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

        // sending 
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
        async sendPublicMessage(content, channel) {
            if (!this.running) throw new Error('mesh not running');
            if (channel) {
                const payload = P().encodeBitchatMessage({
                    id: randomHex(8),
                    sender: this._displayNickname(),
                    content,
                    timestampMs: Date.now(),
                    senderPeerID: this.identity.peerID,
                    channel,
                });
                await this._send(await this._buildPacket({
                    type: P().MsgType.nymChannelMessage,
                    payload,
                    recipientID: P().BROADCAST_RECIPIENT,
                    sign: true,
                }));
                return;
            }
            // bitchat's public mesh chat carries the RAW UTF-8 content, not a
            // TLV; the nickname comes from the peer's announce.
            await this._send(await this._buildPacket({
                type: P().MsgType.message,
                payload: P().utf8.encode(content),
                recipientID: P().BROADCAST_RECIPIENT,
                sign: true,
            }));
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
                default: break;
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
