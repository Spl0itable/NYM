/**
 * fips.js — FIPS-inspired offline messaging for Nymchat
 *
 * Ports key concepts from the FIPS (Free Internetworking Peering System) protocol
 * (https://github.com/jmcorgan/fips, originally written in Rust) to vanilla JavaScript
 * for integration into a browser-based Nostr messenger.
 *
 * Ported / adapted concepts
 * ─────────────────────────
 *  • secp256k1 node identity   — Nostr-native; reuses the app's existing keypair.
 *  • Multi-transport abstraction — Nostr relay (store-and-forward) + WebRTC DataChannel
 *    (direct, lower-latency P2P), mirroring FIPS's transport abstraction over UDP,
 *    Bluetooth, serial, etc.
 *  • Persistent outbox queue   — IndexedDB-backed with TTL and exponential-backoff retry;
 *    the browser equivalent of FIPS store-and-forward routing.
 *  • Per-link metrics (RTT, delivery ratio) — inspired by FIPS's Metrics Measurement
 *    Protocol (MMP); used to score transports and pick the best next hop.
 *  • Bloom filter peer tracking — lightweight probabilistic peer discovery, analogous to
 *    FIPS's Bloom filter discovery without requiring global topology knowledge.
 *  • Routing table with scored next-hop selection — inspired by FIPS's spanning-tree +
 *    greedy coordinate routing; simplified to two transport types.
 *
 * Browser limitations vs. the Rust original
 * ──────────────────────────────────────────
 *  - No raw UDP / TCP / Bluetooth / serial transports (browser sandbox).
 *  - No IPv6 TUN interface (kernel-level; inaccessible from a browser).
 *  - Noise IK/XK replaced with NIP-44 (ChaCha20-Poly1305 + HMAC-SHA256).
 *  - No background daemon; Service Worker could approximate this in future.
 *
 * Nostr event kind used for FIPS WebRTC signaling: 25050
 * (distinct from the app's existing P2P file-transfer signaling on kind 25051)
 */

// ─── Bloom Filter ───────────────────────────────────────────────────────────────
// Lightweight probabilistic data structure for peer discovery without maintaining
// a full peer list. Mirrors FIPS's Bloom filter discovery mechanism.

class FIPSBloomFilter {
    constructor(size = 2048, hashCount = 4) {
        this.size = size;
        this.hashCount = hashCount;
        this.bits = new Uint8Array(Math.ceil(size / 8));
    }

    _hash(str, seed) {
        let h = seed ^ 0xdeadbeef;
        for (let i = 0; i < str.length; i++) {
            h = Math.imul(h ^ str.charCodeAt(i), 0x9e3779b1);
            h ^= h >>> 16;
        }
        return Math.abs(h) % this.size;
    }

    add(item) {
        for (let i = 0; i < this.hashCount; i++) {
            const idx = this._hash(item, i * 0x12345678);
            this.bits[idx >> 3] |= (1 << (idx & 7));
        }
    }

    has(item) {
        for (let i = 0; i < this.hashCount; i++) {
            const idx = this._hash(item, i * 0x12345678);
            if (!(this.bits[idx >> 3] & (1 << (idx & 7)))) return false;
        }
        return true;
    }

    clear() { this.bits.fill(0); }
}


// ─── Link Metrics ───────────────────────────────────────────────────────────────
// Per-transport link quality, inspired by FIPS's Metrics Measurement Protocol.
// Tracks RTT and delivery ratio using exponential weighted moving averages.

class FIPSLinkMetrics {
    constructor() {
        this.rtt       = 0;   // EWMA RTT in ms (0 = no data yet)
        this.delivered = 0;
        this.attempts  = 0;
        this.lastSeen  = 0;
        this._alpha    = 0.2; // EWMA smoothing factor
    }

    recordSuccess(rttMs) {
        this.rtt = this.rtt === 0
            ? rttMs
            : this._alpha * rttMs + (1 - this._alpha) * this.rtt;
        this.delivered++;
        this.attempts++;
        this.lastSeen = Date.now();
    }

    recordFailure() { this.attempts++; }

    get deliveryRatio() {
        return this.attempts === 0 ? 0 : this.delivered / this.attempts;
    }

    // Score in [0, 1]: higher = better link.
    // Weights: 40% RTT score, 60% delivery ratio.
    get score() {
        const rttScore = this.rtt === 0 ? 1 : Math.max(0, 1 - this.rtt / 5000);
        return rttScore * 0.4 + this.deliveryRatio * 0.6;
    }
}


// ─── Routing Table ──────────────────────────────────────────────────────────────
// Tracks known peers and their per-transport link quality. Inspired by FIPS's
// spanning-tree construction and greedy coordinate routing — simplified to relay
// vs. WebRTC transport scoring for two-hop-max browser routing.

class FIPSRoutingTable {
    constructor() {
        this.peers = new Map(); // pubkey → { transports: Map<id, FIPSLinkMetrics>, firstSeen, lastSeen }
        this.bloom = new FIPSBloomFilter();
    }

    seePeer(pubkey, transportId = 'relay') {
        if (!this.peers.has(pubkey)) {
            this.peers.set(pubkey, {
                transports: new Map(),
                firstSeen: Date.now(),
                lastSeen: Date.now()
            });
        }
        const peer = this.peers.get(pubkey);
        if (!peer.transports.has(transportId)) {
            peer.transports.set(transportId, new FIPSLinkMetrics());
        }
        peer.lastSeen = Date.now();
        this.bloom.add(pubkey);
        return peer;
    }

    // Return the transport ID with the highest link score for a peer.
    bestTransport(pubkey) {
        const peer = this.peers.get(pubkey);
        if (!peer) return null;
        let best = null, bestScore = -1;
        for (const [id, metrics] of peer.transports) {
            if (metrics.score > bestScore) { bestScore = metrics.score; best = id; }
        }
        return best;
    }

    recordDelivery(pubkey, transportId, rttMs) {
        this.seePeer(pubkey, transportId)
            .transports.get(transportId).recordSuccess(rttMs);
    }

    recordFailure(pubkey, transportId) {
        this.seePeer(pubkey, transportId)
            .transports.get(transportId).recordFailure();
    }

    isKnown(pubkey) {
        return this.bloom.has(pubkey) && this.peers.has(pubkey);
    }

    get size() { return this.peers.size; }
}


// ─── Outbox (IndexedDB-backed persistent message queue) ─────────────────────────
// Implements FIPS store-and-forward semantics: signed Nostr events are persisted
// locally and delivered when a viable transport becomes available, surviving
// page reloads and browser restarts.

class FIPSOutbox {
    static DB_NAME    = 'fips_outbox_v1';
    static DB_VERSION = 1;
    static STORE      = 'messages';
    static DEFAULT_TTL = 7 * 24 * 60 * 60 * 1000; // 7 days
    static MAX_RETRIES = 10;

    constructor() {
        this.db = null;
        this._ready = this._open();
    }

    _open() {
        return new Promise((resolve) => {
            const req = indexedDB.open(FIPSOutbox.DB_NAME, FIPSOutbox.DB_VERSION);

            req.onupgradeneeded = (e) => {
                const db = e.target.result;
                if (!db.objectStoreNames.contains(FIPSOutbox.STORE)) {
                    const store = db.createObjectStore(FIPSOutbox.STORE, {
                        keyPath: 'id', autoIncrement: true
                    });
                    store.createIndex('status',    'status',    { unique: false });
                    store.createIndex('expiresAt', 'expiresAt', { unique: false });
                }
            };

            req.onsuccess = (e) => {
                this.db = e.target.result;
                this._purgeExpired();
                resolve(true);
            };

            req.onerror = () => {
                // Fallback: in-memory queue (messages lost on reload but better than nothing)
                console.warn('[FIPS] IndexedDB unavailable, using in-memory outbox');
                this._mem = [];
                this.enqueue       = async (msg) => { this._mem.push({ ...msg, id: Date.now() + Math.random() }); };
                this.dequeueReady  = async () => { const r = [...this._mem]; this._mem = []; return r; };
                this.markDelivered = async () => {};
                this.markFailed    = async () => {};
                this.count         = async () => this._mem.length;
                resolve(false);
            };
        });
    }

    async enqueue(message) {
        await this._ready;
        if (!this.db) return;
        const entry = {
            ...message,
            status:      'pending',
            enqueuedAt:  Date.now(),
            expiresAt:   Date.now() + (message.ttl || FIPSOutbox.DEFAULT_TTL),
            retries:     0,
            nextRetryAt: Date.now()
        };
        return new Promise((resolve, reject) => {
            const tx  = this.db.transaction(FIPSOutbox.STORE, 'readwrite');
            const req = tx.objectStore(FIPSOutbox.STORE).add(entry);
            req.onsuccess = () => resolve(req.result);
            req.onerror   = () => reject(req.error);
        });
    }

    // Return all pending messages whose retry window has elapsed and TTL hasn't expired.
    async dequeueReady() {
        await this._ready;
        if (!this.db) return [];
        const now = Date.now();
        return new Promise((resolve) => {
            const tx  = this.db.transaction(FIPSOutbox.STORE, 'readonly');
            const req = tx.objectStore(FIPSOutbox.STORE).index('status').getAll('pending');
            req.onsuccess = () => {
                resolve((req.result || []).filter(m => m.nextRetryAt <= now && m.expiresAt > now));
            };
            req.onerror = () => resolve([]);
        });
    }

    async markDelivered(id) {
        await this._ready;
        if (!this.db) return;
        return this._update(id, { status: 'delivered', deliveredAt: Date.now() });
    }

    async markFailed(id) {
        await this._ready;
        if (!this.db) return;
        return new Promise((resolve) => {
            const tx    = this.db.transaction(FIPSOutbox.STORE, 'readwrite');
            const store = tx.objectStore(FIPSOutbox.STORE);
            const req   = store.get(id);
            req.onsuccess = () => {
                const entry = req.result;
                if (!entry) { resolve(); return; }
                entry.retries = (entry.retries || 0) + 1;
                if (entry.retries >= FIPSOutbox.MAX_RETRIES) {
                    entry.status = 'failed';
                } else {
                    // Exponential backoff: 5 s → 10 s → 20 s → … capped at 30 min
                    const delay = Math.min(5000 * Math.pow(2, entry.retries), 30 * 60 * 1000);
                    entry.nextRetryAt = Date.now() + delay;
                }
                store.put(entry);
                resolve();
            };
            req.onerror = () => resolve();
        });
    }

    async count() {
        await this._ready;
        if (!this.db) return this._mem ? this._mem.length : 0;
        return new Promise((resolve) => {
            const tx  = this.db.transaction(FIPSOutbox.STORE, 'readonly');
            const req = tx.objectStore(FIPSOutbox.STORE).index('status').count('pending');
            req.onsuccess = () => resolve(req.result);
            req.onerror   = () => resolve(0);
        });
    }

    async _update(id, updates) {
        return new Promise((resolve) => {
            const tx    = this.db.transaction(FIPSOutbox.STORE, 'readwrite');
            const store = tx.objectStore(FIPSOutbox.STORE);
            const req   = store.get(id);
            req.onsuccess = () => {
                if (req.result) store.put({ ...req.result, ...updates });
                resolve();
            };
            req.onerror = () => resolve();
        });
    }

    async _purgeExpired() {
        if (!this.db) return;
        const now = Date.now();
        return new Promise((resolve) => {
            const tx    = this.db.transaction(FIPSOutbox.STORE, 'readwrite');
            const store = tx.objectStore(FIPSOutbox.STORE);
            store.openCursor().onsuccess = (e) => {
                const cursor = e.target.result;
                if (!cursor) { resolve(); return; }
                const { expiresAt, status } = cursor.value;
                if (expiresAt < now || status === 'delivered') cursor.delete();
                cursor.continue();
            };
        });
    }
}


// ─── WebRTC Transport ───────────────────────────────────────────────────────────
// FIPS multi-transport concept applied to the browser: direct peer-to-peer
// DataChannel connection for low-latency message delivery, falling back to
// Nostr relay transport automatically.
//
// Signaling uses Nostr kind 25050 (ephemeral), encrypted with NIP-44.
// This is separate from the app's existing file-transfer P2P (kind 25051).

class FIPSWebRTCTransport {
    static SIGNAL_KIND = 25050;

    constructor({ localPubkey, localPrivkey, iceServers, sendToRelay, onMessage }) {
        this.localPubkey = localPubkey;
        this.localPrivkey = localPrivkey;
        this.iceServers = iceServers || [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' }
        ];
        this.sendToRelay = sendToRelay;
        this.onMessage   = onMessage;
        this.peers       = new Map(); // pubkey → { pc, dc, state }
        this._iceBuf     = new Map(); // pubkey → [RTCIceCandidate] (pre-remote-description buffer)

        this.onPeerConnected    = null;
        this.onPeerDisconnected = null;
    }

    // Initiate a WebRTC connection to a remote peer.
    async connect(remotePubkey) {
        const existing = this.peers.get(remotePubkey);
        if (existing && (existing.state === 'connected' || existing.state === 'connecting')) {
            return existing;
        }

        const pc = new RTCPeerConnection({ iceServers: this.iceServers });
        const dc = pc.createDataChannel('fips-msg', { ordered: true, maxRetransmits: 5 });
        const peer = { pc, dc, state: 'connecting' };
        this.peers.set(remotePubkey, peer);

        this._wireDataChannel(dc, remotePubkey);
        this._wirePeerConnection(pc, remotePubkey, peer);

        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        await this._signal(remotePubkey, { type: 'offer', sdp: offer.sdp });
        return peer;
    }

    // Handle an incoming FIPS signaling Nostr event (kind 25050).
    async handleSignalEvent(event) {
        if (event.kind !== FIPSWebRTCTransport.SIGNAL_KIND) return;
        if (!event.tags.some(t => t[0] === 'p' && t[1] === this.localPubkey)) return;

        let signal;
        try {
            const NT = window.NostrTools;
            const ck = NT.nip44.getConversationKey(this.localPrivkey, event.pubkey);
            signal   = JSON.parse(NT.nip44.decrypt(event.content, ck));
        } catch (_) { return; }

        const from = event.pubkey;

        if (signal.type === 'offer') {
            const pc   = new RTCPeerConnection({ iceServers: this.iceServers });
            const peer = { pc, dc: null, state: 'connecting' };
            this.peers.set(from, peer);

            pc.ondatachannel = (e) => {
                peer.dc = e.channel;
                this._wireDataChannel(e.channel, from);
            };
            this._wirePeerConnection(pc, from, peer);

            await pc.setRemoteDescription({ type: 'offer', sdp: signal.sdp });
            const answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);
            await this._signal(from, { type: 'answer', sdp: answer.sdp });

            // Flush buffered ICE candidates
            for (const c of (this._iceBuf.get(from) || [])) {
                try { await pc.addIceCandidate(c); } catch (_) {}
            }
            this._iceBuf.delete(from);

        } else if (signal.type === 'answer') {
            const peer = this.peers.get(from);
            if (peer) await peer.pc.setRemoteDescription({ type: 'answer', sdp: signal.sdp });

        } else if (signal.type === 'ice') {
            const peer = this.peers.get(from);
            if (!peer || !peer.pc.remoteDescription) {
                if (!this._iceBuf.has(from)) this._iceBuf.set(from, []);
                this._iceBuf.get(from).push(signal.candidate);
                return;
            }
            try { await peer.pc.addIceCandidate(signal.candidate); } catch (_) {}
        }
    }

    // Send structured data directly over the DataChannel.
    send(remotePubkey, data) {
        const peer = this.peers.get(remotePubkey);
        if (!peer || peer.state !== 'connected' || !peer.dc) return false;
        try { peer.dc.send(JSON.stringify(data)); return true; }
        catch (_) { return false; }
    }

    isConnected(remotePubkey) {
        const peer = this.peers.get(remotePubkey);
        return !!(peer && peer.state === 'connected');
    }

    close(remotePubkey) {
        const peer = this.peers.get(remotePubkey);
        if (!peer) return;
        try { peer.dc && peer.dc.close(); } catch (_) {}
        try { peer.pc && peer.pc.close(); } catch (_) {}
        this.peers.delete(remotePubkey);
    }

    closeAll() {
        for (const pk of [...this.peers.keys()]) this.close(pk);
    }

    _wireDataChannel(dc, remotePubkey) {
        dc.onopen = () => {
            const peer = this.peers.get(remotePubkey);
            if (peer) peer.state = 'connected';
            if (this.onPeerConnected) this.onPeerConnected(remotePubkey);
        };
        dc.onclose = () => {
            const peer = this.peers.get(remotePubkey);
            if (peer) peer.state = 'disconnected';
            if (this.onPeerDisconnected) this.onPeerDisconnected(remotePubkey);
        };
        dc.onmessage = (e) => {
            try {
                if (this.onMessage) this.onMessage(remotePubkey, JSON.parse(e.data));
            } catch (_) {}
        };
        dc.onerror = () => {
            const peer = this.peers.get(remotePubkey);
            if (peer) peer.state = 'error';
        };
    }

    _wirePeerConnection(pc, remotePubkey, peer) {
        pc.onicecandidate = async ({ candidate }) => {
            if (candidate) await this._signal(remotePubkey, { type: 'ice', candidate });
        };
        pc.onconnectionstatechange = () => {
            if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
                peer.state = 'disconnected';
                this.peers.delete(remotePubkey);
            }
        };
    }

    // Send a NIP-44-encrypted signaling event (kind 25050) via relay.
    async _signal(remotePubkey, signal) {
        if (!this.localPrivkey || !window.NostrTools) return;
        try {
            const NT      = window.NostrTools;
            const ck      = NT.nip44.getConversationKey(this.localPrivkey, remotePubkey);
            const content = NT.nip44.encrypt(JSON.stringify(signal), ck);
            const event   = NT.finalizeEvent({
                kind:       FIPSWebRTCTransport.SIGNAL_KIND,
                created_at: Math.floor(Date.now() / 1000),
                tags:       [['p', remotePubkey]],
                content,
                pubkey:     this.localPubkey
            }, this.localPrivkey);
            this.sendToRelay(['EVENT', event]);
        } catch (_) {}
    }
}


// ─── BLE Transport ─────────────────────────────────────────────────────────────
// FIPS multi-transport concept extended to Bluetooth Low Energy.
//
// Two paths depending on runtime:
//
//  1. Flutter WebView path (full capability)
//     fips.js delegates BLE operations to the native Flutter layer via
//     flutter_inappwebview JavaScript handlers. The Flutter layer uses
//     bluetooth_low_energy to act as both CENTRAL (scan + connect) and
//     PERIPHERAL (advertise + host GATT service), enabling fully offline
//     device-to-device messaging between any two Flutter app users.
//
//  2. Web Bluetooth path (Chrome / Chromium, CENTRAL ONLY)
//     Uses navigator.bluetooth.requestDevice() — requires a user gesture
//     and shows the browser's BLE device picker. The browser can connect
//     to a Flutter app that is advertising, but two browser tabs cannot
//     discover each other (neither can advertise). No internet needed once
//     the BLE connection is established.
//
// Capability matrix:
//   Flutter ↔ Flutter  — fully offline, auto-discover, both roles
//   Chrome  ↔ Flutter  — no internet needed once connected; Chrome user
//                         must manually open the scanner picker
//   Chrome  ↔ Chrome   — NOT possible via BLE (both central-only)
//
// GATT service layout (all UUIDs are 128-bit custom UUIDs):
//   FIPS Service         4e796d43-6861-7400-0000-000000000001
//     PeerID   (read)    4e796d43-6861-7400-0000-000000000002  — node's hex pubkey
//     MsgTX    (write)   4e796d43-6861-7400-0000-000000000003  — central writes here
//     MsgRX    (notify)  4e796d43-6861-7400-0000-000000000004  — peripheral notifies here
//
// Message framing (binary, over MsgTX/MsgRX):
//   [msgId: 4B][chunkIdx: 2B][totalChunks: 2B][payload: ≤180B]
//   Payload is a NIP-44 encrypted JSON string, UTF-8 encoded, then chunked.
//   180-byte payload fits in a default iOS MTU (185B) without negotiation.

class FIPSBLETransport {
    static SERVICE_UUID  = '4e796d43-6861-7400-0000-000000000001';
    static PEER_ID_UUID  = '4e796d43-6861-7400-0000-000000000002'; // read: pubkey
    static MSG_TX_UUID   = '4e796d43-6861-7400-0000-000000000003'; // write (central→peripheral)
    static MSG_RX_UUID   = '4e796d43-6861-7400-0000-000000000004'; // notify (peripheral→central)
    static CHUNK_PAYLOAD = 180; // safe BLE payload before MTU negotiation
    static MAX_REASSEMBLY_BUFFERS = 64;

    constructor({ localPubkey, localPrivkey, onMessage }) {
        this.localPubkey  = localPubkey;
        this.localPrivkey = localPrivkey;
        this.onMessage    = onMessage;

        // deviceId → { deviceId, pubkey, txChar } (Web BT path)
        this.connections  = new Map();
        // `${pubkey}:${msgId}` → { chunks[], received, total }
        this._reassembly  = new Map();

        // flutter_inappwebview exposes this global before the page is ready
        this._isFlutter   = false;
        this._flutterReady = false;

        this.onPeerConnected    = null; // (pubkey) => {}
        this.onPeerDisconnected = null; // (pubkey) => {}

        // Register reverse-call targets so Flutter can push data into JS
        window._fipsBLEOnMessage = (fromPubkey, encryptedPayload) => {
            this._receiveFromFlutter(fromPubkey, encryptedPayload);
        };
        window._fipsBLEOnPeerConnected = (pubkey) => {
            if (this.onPeerConnected) this.onPeerConnected(pubkey);
        };
        window._fipsBLEOnPeerDisconnected = (pubkey) => {
            if (this.onPeerDisconnected) this.onPeerDisconnected(pubkey);
        };

        // Detect Flutter WebView after platform is ready
        window.addEventListener('flutterInAppWebViewPlatformReady', () => {
            this._isFlutter   = !!window.flutter_inappwebview;
            this._flutterReady = this._isFlutter;
        });
        // Synchronous fallback check (already ready when script runs)
        if (window.flutter_inappwebview) {
            this._isFlutter    = true;
            this._flutterReady = true;
        }
    }

    // ── Capability detection ───────────────────────────────────────────────────

    get isAvailable() {
        return this._isFlutter || ('bluetooth' in navigator);
    }

    // Only Flutter can advertise; Web BT is central-only
    get canAdvertise() { return this._isFlutter; }

    // ── Discovery & advertising ───────────────────────────────────────────────

    // Start advertising this node as a FIPS peripheral (Flutter only).
    // Called automatically when the FIPS node attaches to the app.
    async startAdvertising() {
        if (!this._isFlutter) return false;
        return this._flutter('fipsBLEAdvertise', { pubkey: this.localPubkey });
    }

    // Stop advertising.
    async stopAdvertising() {
        if (!this._isFlutter) return;
        return this._flutter('fipsBLEStopAdvertise');
    }

    // Scan for nearby FIPS nodes.
    // Flutter: starts a background scan; results arrive via _fipsBLEOnPeerConnected.
    // Web BT:  opens the browser's BLE device picker (requires a user gesture).
    async scan() {
        if (this._isFlutter) {
            return this._flutter('fipsBleScan');
        }
        if (!navigator.bluetooth) {
            throw new Error('Web Bluetooth is not supported in this browser. Use Chrome or a Chromium-based browser.');
        }
        const device = await navigator.bluetooth.requestDevice({
            filters: [{ services: [FIPSBLETransport.SERVICE_UUID] }]
        });
        await this._webBTConnect(device);
    }

    // ── Web Bluetooth connection (central path) ───────────────────────────────

    async _webBTConnect(device) {
        device.addEventListener('gattserverdisconnected', () => {
            const conn = [...this.connections.values()].find(c => c.deviceId === device.id);
            if (conn) {
                this.connections.delete(device.id);
                if (this.onPeerDisconnected) this.onPeerDisconnected(conn.pubkey);
            }
        });

        const server  = await device.gatt.connect();
        const service = await server.getPrimaryService(FIPSBLETransport.SERVICE_UUID);

        // Read peer's Nostr pubkey
        const peerIdChar  = await service.getCharacteristic(FIPSBLETransport.PEER_ID_UUID);
        const peerIdBytes = await peerIdChar.readValue();
        const peerPubkey  = new TextDecoder().decode(peerIdBytes).trim();

        // TX characteristic: we WRITE to send messages to the peripheral
        const txChar = await service.getCharacteristic(FIPSBLETransport.MSG_TX_UUID);

        // RX characteristic: we subscribe to NOTIFICATIONS to receive messages
        const rxChar = await service.getCharacteristic(FIPSBLETransport.MSG_RX_UUID);
        await rxChar.startNotifications();
        rxChar.addEventListener('characteristicvaluechanged', (e) => {
            this._onChunk(peerPubkey, new Uint8Array(e.target.value.buffer));
        });

        this.connections.set(device.id, { deviceId: device.id, pubkey: peerPubkey, txChar });
        if (this.onPeerConnected) this.onPeerConnected(peerPubkey);
        return peerPubkey;
    }

    // ── Send ──────────────────────────────────────────────────────────────────

    async send(recipientPubkey, signedEvent) {
        const encrypted = this._encrypt(recipientPubkey, { type: 'fips_msg', payload: signedEvent });
        if (!encrypted) return false;

        if (this._isFlutter) {
            return this._flutter('fipsBLESend', { pubkey: recipientPubkey, data: encrypted });
        }

        // Web BT path: find connection and write chunks
        const conn = [...this.connections.values()].find(c => c.pubkey === recipientPubkey);
        if (!conn) return false;

        const bytes  = new TextEncoder().encode(encrypted);
        const msgId  = (Math.random() * 0xFFFFFFFF) >>> 0;
        const chunks = this._chunk(bytes);

        for (let i = 0; i < chunks.length; i++) {
            const frame = this._frame(msgId, i, chunks.length, chunks[i]);
            try {
                // writeValueWithoutResponse is faster; fall back to writeValue on error
                await conn.txChar.writeValueWithoutResponse(frame);
            } catch (_) {
                try { await conn.txChar.writeValue(frame); } catch (_) { return false; }
            }
        }
        return true;
    }

    isConnected(pubkey) {
        if (this._isFlutter) return false; // Flutter tracks connections natively
        return [...this.connections.values()].some(c => c.pubkey === pubkey);
    }

    // ── Receive (Flutter → JS bridge) ─────────────────────────────────────────

    // Called by Flutter when a BLE message arrives for this node.
    _receiveFromFlutter(fromPubkey, encryptedData) {
        const data = this._decrypt(fromPubkey, encryptedData);
        if (data && this.onMessage) this.onMessage(fromPubkey, data);
    }

    // ── Crypto helpers ────────────────────────────────────────────────────────

    _encrypt(recipientPubkey, data) {
        try {
            const NT = window.NostrTools;
            const ck = NT.nip44.getConversationKey(this.localPrivkey, recipientPubkey);
            return NT.nip44.encrypt(JSON.stringify(data), ck);
        } catch (_) { return null; }
    }

    _decrypt(senderPubkey, encryptedData) {
        try {
            const NT = window.NostrTools;
            const ck = NT.nip44.getConversationKey(this.localPrivkey, senderPubkey);
            return JSON.parse(NT.nip44.decrypt(encryptedData, ck));
        } catch (_) { return null; }
    }

    // ── Chunking & framing ────────────────────────────────────────────────────

    _chunk(bytes) {
        const out = [];
        for (let i = 0; i < bytes.length; i += FIPSBLETransport.CHUNK_PAYLOAD) {
            out.push(bytes.slice(i, i + FIPSBLETransport.CHUNK_PAYLOAD));
        }
        return out.length ? out : [new Uint8Array(0)];
    }

    _frame(msgId, idx, total, payload) {
        const f = new Uint8Array(8 + payload.length);
        const v = new DataView(f.buffer);
        v.setUint32(0, msgId,  false);
        v.setUint16(4, idx,    false);
        v.setUint16(6, total,  false);
        f.set(payload, 8);
        return f;
    }

    _onChunk(fromPubkey, frame) {
        if (frame.length < 8) return;
        const v     = new DataView(frame.buffer);
        const msgId = v.getUint32(0, false);
        const idx   = v.getUint16(4, false);
        const total = v.getUint16(6, false);
        const pay   = frame.slice(8);
        const key   = `${fromPubkey}:${msgId}`;

        if (!this._reassembly.has(key)) {
            // Evict oldest entry if at capacity
            if (this._reassembly.size >= FIPSBLETransport.MAX_REASSEMBLY_BUFFERS) {
                this._reassembly.delete(this._reassembly.keys().next().value);
            }
            this._reassembly.set(key, { chunks: new Array(total).fill(null), received: 0, total });
        }

        const state = this._reassembly.get(key);
        if (state.chunks[idx] === null) {
            state.chunks[idx] = pay;
            state.received++;
        }

        if (state.received === state.total) {
            this._reassembly.delete(key);
            const full = new Uint8Array(state.chunks.reduce((n, c) => n + c.length, 0));
            let off = 0;
            for (const c of state.chunks) { full.set(c, off); off += c.length; }
            const text = new TextDecoder().decode(full);
            const data = this._decrypt(fromPubkey, text);
            if (data && this.onMessage) this.onMessage(fromPubkey, data);
        }
    }

    // ── Flutter JS handler helper ─────────────────────────────────────────────

    async _flutter(handler, args) {
        if (!this._flutterReady || !window.flutter_inappwebview) return null;
        try {
            return await window.flutter_inappwebview.callHandler(handler, args ?? {});
        } catch (_) { return null; }
    }
}



// Main coordinator: binds identity, transports, routing table, and outbox.
// Attach to the NymChat app instance via fips.attach(app) after login.

class FIPSNode {
    constructor() {
        this.pubkey       = null;
        this.privkey      = null;
        this.outbox       = new FIPSOutbox();
        this.routing      = new FIPSRoutingTable();
        this.webrtc       = null;
        this._app         = null;
        this._flushTimer  = null;
        this._isOnline    = navigator.onLine;

        window.addEventListener('online',  () => { this._isOnline = true;  this._scheduleFlush(500); });
        window.addEventListener('offline', () => { this._isOnline = false; });
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────────

    attach(app) {
        this._app    = app;
        this.pubkey  = app.pubkey;
        this.privkey = app.privkey;

        this.webrtc = new FIPSWebRTCTransport({
            localPubkey:  this.pubkey,
            localPrivkey: this.privkey,
            iceServers:   app.p2pIceServers,
            sendToRelay:  app.sendToRelay.bind(app),
            onMessage:    (from, data) => this._handleP2PMessage(from, data)
        });

        this.webrtc.onPeerConnected = (pubkey) => {
            this.routing.seePeer(pubkey, 'webrtc');
            this._flushToPeer(pubkey);
        };

        this.webrtc.onPeerDisconnected = (pubkey) => {
            this.routing.recordFailure(pubkey, 'webrtc');
        };

        // Initialize BLE transport if available in this runtime
        this.ble = new FIPSBLETransport({
            localPubkey:  this.pubkey,
            localPrivkey: this.privkey,
            onMessage:    (from, data) => this._handleP2PMessage(from, data)
        });

        this.ble.onPeerConnected = (pubkey) => {
            this.routing.seePeer(pubkey, 'ble');
            this._flushToPeer(pubkey);
            if (app.displaySystemMessage) {
                const nick = app.getNymFromPubkey?.(pubkey) || pubkey.slice(0, 8) + '…';
                app.displaySystemMessage(`Nearby user connected via Bluetooth: ${nick}`);
            }
        };

        this.ble.onPeerDisconnected = (pubkey) => {
            this.routing.recordFailure(pubkey, 'ble');
        };

        // Flutter: start advertising immediately so nearby users can discover us
        if (this.ble.canAdvertise) this.ble.startAdvertising().catch(() => {});

        // Flush any messages that were queued before this session connected
        this._scheduleFlush(1500);
    }

    // Trigger a BLE scan. In Web Bluetooth this requires a user gesture (button click).
    // In the Flutter app it starts a passive background scan.
    async scanBLE() {
        if (!this.ble?.isAvailable) {
            throw new Error('Bluetooth is not available in this browser. Use Chrome or open the app.');
        }
        return this.ble.scan();
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    // Queue a signed Nostr event for delivery when a transport is available.
    // message: { signedEvent, recipient (pubkey|null), type ('channel'|'pm'), ttl (ms) }
    async queueMessage(message) {
        await this.outbox.enqueue(message);
        this._updateBadge();
        if (this._isOnline && this._app?.connected) this._scheduleFlush(100);
    }

    // Attempt delivery of all pending outbox messages now.
    async flush() {
        if (!this._app) return;
        const pending = await this.outbox.dequeueReady();
        for (const msg of pending) {
            try {
                const ok = await this._deliver(msg);
                if (ok) await this.outbox.markDelivered(msg.id);
                else    await this.outbox.markFailed(msg.id);
            } catch (_) {
                await this.outbox.markFailed(msg.id);
            }
        }
        this._updateBadge();
    }

    // Initiate a WebRTC connection to a peer (call when opening a PM).
    connectToPeer(pubkey) {
        if (!this.webrtc || !this.privkey) return;
        this.webrtc.connect(pubkey).catch(() => {});
    }

    // Route incoming Nostr events; call from handleEvent for kind 25050.
    async handleSignalEvent(event) {
        if (!this.webrtc || !this.privkey) return;
        await this.webrtc.handleSignalEvent(event);
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    // Deliver a single queued message via the best available transport.
    // Priority (FIPS multi-transport): BLE → WebRTC → Nostr relay
    //   BLE    — works offline, no internet, ~10-100m range
    //   WebRTC — direct P2P, low latency, needs internet for signaling
    //   Relay  — store-and-forward, needs internet, highest reliability
    async _deliver(msg) {
        const { signedEvent, recipient } = msg;
        if (!signedEvent) return false;

        // 1. BLE — offline-capable direct delivery
        if (recipient && this.ble?.isConnected(recipient)) {
            const t0   = Date.now();
            const sent = await this.ble.send(recipient, signedEvent);
            if (sent) {
                this.routing.recordDelivery(recipient, 'ble', Date.now() - t0);
                return true;
            }
        }

        // 2. WebRTC — direct P2P when both peers are online
        if (recipient && this.webrtc?.isConnected(recipient)) {
            const t0   = Date.now();
            const sent = this.webrtc.send(recipient, { type: 'fips_msg', payload: signedEvent });
            if (sent) {
                this.routing.recordDelivery(recipient, 'webrtc', Date.now() - t0);
                return true;
            }
        }

        // 3. Nostr relay — store-and-forward (needs internet)
        if (this._app?.connected) {
            const t0 = Date.now();
            this._app.sendToRelay(['EVENT', signedEvent]);
            if (recipient) this.routing.recordDelivery(recipient, 'relay', Date.now() - t0);
            return true;
        }

        return false;
    }

    // Flush outbox entries addressed to a specific peer (called on any transport connect).
    async _flushToPeer(pubkey) {
        const pending = await this.outbox.dequeueReady();
        for (const msg of pending) {
            if (msg.recipient !== pubkey) continue;
            const ok = await this._deliver(msg);
            if (ok) await this.outbox.markDelivered(msg.id);
        }
    }

    // Inject P2P-delivered events into the app as if received from a relay.
    _handleP2PMessage(fromPubkey, data) {
        if (data?.type === 'fips_msg' && data.payload && this._app) {
            try { this._app.handleEvent(data.payload); } catch (_) {}
        }
    }

    _scheduleFlush(delayMs = 1000) {
        if (this._flushTimer) clearTimeout(this._flushTimer);
        this._flushTimer = setTimeout(async () => {
            this._flushTimer = null;
            await this.flush();
        }, delayMs);
    }

    async _updateBadge() {
        const n     = await this.outbox.count();
        const badge = document.getElementById('fipsQueueBadge');
        if (!badge) return;
        badge.textContent = n > 0 ? `${n} queued` : '';
        badge.style.display = n > 0 ? 'inline' : 'none';
    }

    get isOnline() { return this._isOnline; }

    stats() {
        return {
            peers:       this.routing.size,
            webrtcPeers: this.webrtc?.peers.size ?? 0,
            blePeers:    this.ble?.connections.size ?? 0,
            bleAvailable: this.ble?.isAvailable ?? false,
            online:      this._isOnline,
            attached:    !!this._app
        };
    }
}

// ─── Global singleton ──────────────────────────────────────────────────────────
window.FIPSNode               = FIPSNode;
window.FIPSOutbox             = FIPSOutbox;
window.FIPSRoutingTable       = FIPSRoutingTable;
window.FIPSBloomFilter        = FIPSBloomFilter;
window.FIPSWebRTCTransport    = FIPSWebRTCTransport;
window.fips                   = new FIPSNode();
