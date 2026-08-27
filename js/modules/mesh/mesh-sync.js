// mesh-sync.js - Gossip-synced public history.

(function () {
    const G = typeof globalThis !== 'undefined' ? globalThis : self;

    // 6h: how long a public message stays sync-able. This is the window that
    // makes a device a town crier rather than a live relay.
    const PUBLIC_MAX_AGE_MS = 6 * 60 * 60 * 1000;
    // Announces are presence, not history — a stale one advertises a peer who
    // walked away 20 minutes ago.
    const ANNOUNCE_MAX_AGE_MS = 15 * 60 * 1000;
    // Prekey bundles live longest — 24h, matching bitchat. Their whole
    // purpose is to be available while the owner is away.
    const PREKEY_BUNDLE_MAX_AGE_MS = 24 * 60 * 60 * 1000;
    const CAPACITY = 1000;
    const GCS_MAX_BYTES = 400;
    const GCS_TARGET_FPR = 0.01;
    const SYNC_INTERVAL_MS = 15 * 1000;
    // A response can replay the whole store, so this bounds what one peer can
    // make us spend however fast it asks.
    const RESPONSE_RATE_LIMIT_MS = 30 * 1000;
    const MAX_ACCEPT_FILTER_BYTES = 1024;
    const MAX_P = 32;

    // bit IO (MSB-first) 
    class BitWriter {
        constructor() { this.buf = []; this.cur = 0; this.n = 0; }
        bit(b) {
            this.cur = ((this.cur << 1) | (b & 1)) & 0xFF;
            if (++this.n === 8) { this.buf.push(this.cur); this.cur = 0; this.n = 0; }
        }
        ones(c) { for (let i = 0; i < c; i++) this.bit(1); }
        bits(v, c) { for (let i = c - 1; i >= 0; i--) this.bit(Number((v >> BigInt(i)) & 1n)); }
        bytes() {
            if (this.n > 0) { this.buf.push((this.cur << (8 - this.n)) & 0xFF); this.cur = 0; this.n = 0; }
            return new Uint8Array(this.buf);
        }
    }

    class BitReader {
        constructor(data) {
            this.data = data; this.idx = 0; this.cur = data.length ? data[0] : 0;
            this.left = data.length ? 8 : 0;
        }
        bit() {
            if (this.idx >= this.data.length) return null;
            const b = (this.cur >> 7) & 1;
            this.cur = (this.cur << 1) & 0xFF;
            if (--this.left === 0) {
                this.idx++;
                if (this.idx < this.data.length) { this.cur = this.data[this.idx]; this.left = 8; }
            }
            return b;
        }
        unary() {
            let q = 0;
            for (;;) { const b = this.bit(); if (b === null) return null; if (b === 1) q++; else return q; }
        }
        bits(count) {
            let v = 0n;
            for (let i = 0; i < count; i++) {
                const b = this.bit();
                if (b === null) return null;
                v = (v << 1n) | BigInt(b);
            }
            return v;
        }
    }

    // SHA-256 has to be async in the browser (WebCrypto), so ids are computed
    // once when a packet is stored and carried alongside it — never recomputed
    // inside the encode loop.
    async function sha256(bytes) {
        const d = await crypto.subtle.digest('SHA-256', bytes);
        return new Uint8Array(d);
    }

    function beU64(n) {
        const out = new Uint8Array(8);
        let v = BigInt(n);
        for (let i = 7; i >= 0; i--) { out[i] = Number(v & 0xFFn); v >>= 8n; }
        return out;
    }

    /// The 16-byte deterministic id gossip sync keys a packet on.
    async function packetId(packet) {
        const ts = beU64(packet.timestamp);
        const buf = new Uint8Array(1 + packet.senderID.length + 8 + packet.payload.length);
        let o = 0;
        buf[o++] = packet.type & 0xFF;
        buf.set(packet.senderID, o); o += packet.senderID.length;
        buf.set(ts, o); o += 8;
        buf.set(packet.payload, o);
        return (await sha256(buf)).slice(0, 16);
    }

    /// First 8 bytes of SHA-256 over the id, top bit cleared so the value stays
    /// positive in every language's signed 64-bit integer.
    async function h64(id16) {
        const d = await sha256(id16);
        let x = 0n;
        for (let i = 0; i < 8; i++) x = (x << 8n) | BigInt(d[i]);
        return x & 0x7fffffffffffffffn;
    }

    function mapHash(hash, modulo) {
        if (modulo <= 1n) return 0n;
        const v = hash % modulo;
        return v === 0n ? 1n : v;
    }

    // filter 
    function deriveP(targetFpr) {
        const f = Math.max(0.000001, Math.min(0.25, targetFpr));
        return Math.max(1, Math.ceil(Math.log2(1.0 / f)));
    }

    function estimateMaxElements(sizeBytes, p) {
        const bits = Math.max(8, sizeBytes * 8);
        const per = Math.max(3, p + 2);
        return Math.max(1, Math.floor(bits / per));
    }

    function hashRange(count, p) {
        if (count <= 0) return 1;
        if (p >= 32) return 0xFFFFFFFF;
        const mult = 2 ** p;
        if (count > Math.floor(0xFFFFFFFF / mult)) return 0xFFFFFFFF;
        const prod = count * mult;
        return prod === 0 ? 1 : (prod > 0xFFFFFFFF ? 0xFFFFFFFF : prod);
    }

    // Clamps into range and drops duplicates so the sequence is strictly
    // increasing — the encoder emits deltas, and a zero delta is not
    // representable.
    function normalize(values, modulo) {
        if (modulo <= 1n || !values.length) return [];
        const out = [];
        let last = 0n;
        for (const v of values) {
            const n = v < modulo - 1n ? v : modulo - 1n;
            if (n > last) { out.push(n); last = n; }
        }
        return out;
    }

    function encodeGolomb(sorted, p) {
        const w = new BitWriter();
        let prev = 0n;
        const P = BigInt(p);
        const mask = (1n << P) - 1n;
        for (const v of sorted) {
            const x = v - prev;
            prev = v;
            const q = (x - 1n) >> P;
            const r = (x - 1n) & mask;
            if (q > 0n) w.ones(Number(q));
            w.bit(0);
            w.bits(r, p);
        }
        return w.bytes();
    }

    /// Builds a filter over `mapped` hashes, passed NEWEST-FIRST.
    ///
    /// The modulus is fixed to the initial candidate count so `m` stays stable
    /// while the tail is trimmed to fit the byte budget — a peer decoding the
    /// filter must compute the same buckets, and all it has is `m`.
    ///
    /// `includedCount` is how many inputs the filter actually covers. Trimming
    /// drops from the tail, so with ids newest-first the covered set is always
    /// a contiguous newest-prefix — which is what makes a since-cursor exact
    /// rather than an arbitrary hash-order subset.
    function buildFilter(hashes, maxBytes, targetFpr) {
        const p = deriveP(targetFpr);
        if (!hashes.length) return { p, m: 1, data: new Uint8Array(0), includedCount: 0 };
        const cap = estimateMaxElements(maxBytes, p);
        const range = Math.max(1, hashRange(Math.min(hashes.length, cap), p));
        const modulo = BigInt(range);
        const encodeFirst = (count) => {
            const mapped = hashes.slice(0, count).map(h => mapHash(h, modulo)).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
            const norm = normalize(mapped, modulo);
            return norm.length ? encodeGolomb(norm, p) : new Uint8Array(0);
        };
        let count = Math.min(hashes.length, cap);
        let enc = encodeFirst(count);
        while (enc.length > maxBytes && count > 1) {
            count = Math.max(1, Math.floor((count * 9) / 10));
            enc = encodeFirst(count);
        }
        if (enc.length > maxBytes) return { p, m: range, data: new Uint8Array(0), includedCount: 0 };
        return { p, m: range, data: enc, includedCount: enc.length ? count : 0 };
    }

    /// Decodes a wire filter to its sorted bucket values.
    ///
    /// Out-of-range parameters are REFUSED rather than decoded into garbage:
    /// callers read an empty result as "the peer holds nothing" and send
    /// everything, which is the safe direction — wasted airtime, never a
    /// silently dropped message.
    function decodeToSortedSet(p, m, data) {
        if (p < 1 || p > MAX_P || m <= 1) return [];
        const out = [];
        const r = new BitReader(data);
        let acc = 0n;
        const M = BigInt(m);
        for (;;) {
            const q = r.unary();
            if (q === null) break;
            const rem = r.bits(p);
            if (rem === null) break;
            const x = (BigInt(q) << BigInt(p)) + rem + 1n;
            acc += x;
            if (acc >= M) break;
            out.push(acc);
        }
        return out;
    }

    function containsBucket(sorted, candidate) {
        let lo = 0, hi = sorted.length - 1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const v = sorted[mid];
            if (v === candidate) return true;
            if (v < candidate) lo = mid + 1; else hi = mid - 1;
        }
        return false;
    }

    // Bit index → mesh packet type, matching bitchat exactly. The types NOT
    // listed are deliberate: anything directed (handshakes, encrypted
    // transport, courier envelopes) must never spread by gossip, REQUEST_SYNC
    // itself would loop, and our 0x5x extensions have no bit bitchat agrees on.
    const SYNC_BIT_TO_TYPE = { 0: 0x01, 1: 0x02, 2: 0x03, 3: 0x10, 4: 0x11, 5: 0x20, 6: 0x21, 7: 0x22, 9: 0x24 };
    const SYNC_KNOWN_MASK = Object.keys(SYNC_BIT_TO_TYPE).reduce((m, b) => m | (1 << Number(b)), 0);
    // Announces (which carry the signing keys everything else is verified
    // against) plus public messages, plus prekey bundles — which have to travel
    // while their owner is AWAY, since that is precisely when their mail is
    // being couriered.
    const SYNC_PUBLIC = (1 << 0) | (1 << 1) | (1 << 9);

    function syncFlagsContains(raw, meshType) {
        for (const [bit, type] of Object.entries(SYNC_BIT_TO_TYPE)) {
            if (type === meshType) return (raw & (1 << Number(bit))) !== 0;
        }
        return false;
    }

    // Little-endian, trailing zero bytes trimmed, at least one byte.
    function encodeSyncFlags(raw) {
        const masked = raw & SYNC_KNOWN_MASK;
        const out = [];
        let v = masked;
        for (let i = 0; i < 8; i++) { out.push(v & 0xFF); v = Math.floor(v / 256); }
        while (out.length > 1 && out[out.length - 1] === 0) out.pop();
        return new Uint8Array(out);
    }

    function decodeSyncFlags(bytes) {
        if (!bytes.length || bytes.length > 8) return null;
        let raw = 0;
        for (let i = bytes.length - 1; i >= 0; i--) raw = raw * 256 + bytes[i];
        return raw & SYNC_KNOWN_MASK;
    }

    function encodeRequestSync({ p, m, data, types, sinceTimestamp }) {
        const parts = [];
        const tlv = (t, v) => { parts.push(new Uint8Array([t, (v.length >> 8) & 0xFF, v.length & 0xFF]), v); };
        tlv(0x01, new Uint8Array([p & 0xFF]));
        const mb = new Uint8Array(4);
        new DataView(mb.buffer).setUint32(0, m >>> 0, false);
        tlv(0x02, mb);
        tlv(0x03, data);
        if (types !== undefined && types !== null) tlv(0x04, encodeSyncFlags(types));
        if (sinceTimestamp) tlv(0x05, beU64(sinceTimestamp));
        let len = 0;
        for (const p2 of parts) len += p2.length;
        const out = new Uint8Array(len);
        let o = 0;
        for (const p2 of parts) { out.set(p2, o); o += p2.length; }
        return out;
    }

    // Returns null for a payload that is malformed, or claims parameters a
    // decoder would have to guess at. Unknown TLVs are skipped, not fatal —
    // that is what lets a newer bitchat widen the format without cutting us off.
    function decodeRequestSync(data, maxAcceptBytes = MAX_ACCEPT_FILTER_BYTES) {
        let off = 0, p = null, m = null, payload = null, types = null, since = null;
        while (off + 3 <= data.length) {
            const t = data[off]; off += 1;
            if (off + 2 > data.length) return null;
            const len = (data[off] << 8) | data[off + 1]; off += 2;
            if (off + len > data.length) return null;
            const v = data.subarray(off, off + len); off += len;
            if (t === 0x01) { if (len === 1) p = v[0]; }
            else if (t === 0x02) { if (len === 4) { m = 0; for (const b of v) m = m * 256 + b; } }
            else if (t === 0x03) { if (len > maxAcceptBytes) return null; payload = new Uint8Array(v); }
            else if (t === 0x04) { const f = decodeSyncFlags(v); if (f !== null) types = f; }
            else if (t === 0x05) { if (len === 8) { let ts = 0n; for (const b of v) ts = ts * 256n + BigInt(b); since = Number(ts); } }
        }
        if (p === null || m === null || payload === null) return null;
        if (p < 1 || p > MAX_P || m < 1) return null;
        return { p, m, data: payload, types, sinceTimestamp: since };
    }

    /// Whether a packet type is worth replaying to a peer that missed it.
    function isSyncable(type) {
        return type === 0x01 /* announce */
            || type === 0x02 /* public message */
            || type === 0x54 /* nymChannelMessage */
            // A bundle has to reach senders while its owner is away — the one
            // time it matters. Signed, so gossip cannot forge one.
            || type === 0x24 /* prekeyBundle */;
    }

    /// A bounded, freshness-filtered store of recent public packets, plus the
    /// reconciliation over it. Kept free of the radio: the caller owns sending.
    class GossipSync {
        constructor(opts) {
            opts = opts || {};
            this.now = opts.now || (() => Date.now());
            this.capacity = opts.capacity || CAPACITY;
            this.publicMaxAgeMs = opts.publicMaxAgeMs || PUBLIC_MAX_AGE_MS;
            this.announceMaxAgeMs = opts.announceMaxAgeMs || ANNOUNCE_MAX_AGE_MS;
            // A bundle stays useful far longer than a message: its owner is
            // away, and stale prekeys are refused by the owner rather than
            // being dangerous.
            this.prekeyBundleMaxAgeMs = opts.prekeyBundleMaxAgeMs || PREKEY_BUNDLE_MAX_AGE_MS;
            this.gcsMaxBytes = opts.gcsMaxBytes || GCS_MAX_BYTES;
            this.gcsTargetFpr = opts.gcsTargetFpr || GCS_TARGET_FPR;
            this.syncIntervalMs = opts.syncIntervalMs || SYNC_INTERVAL_MS;
            this.responseRateLimitMs = opts.responseRateLimitMs || RESPONSE_RATE_LIMIT_MS;
            // idHex -> { packet, hash }
            this.messages = new Map();
            // senderHex -> { packet, hash }
            this.announces = new Map();
            // senderHex -> { packet, hash }; at most one bundle per device, and
            // only the newest is kept.
            this.prekeyBundles = new Map();
            this.lastAsked = new Map();
            this.lastAnswered = new Map();
        }

        _fresh(packet) {
            const maxAge = packet.type === 0x01 ? this.announceMaxAgeMs
                : packet.type === 0x24 ? this.prekeyBundleMaxAgeMs
                    : this.publicMaxAgeMs;
            const age = this.now() - packet.timestamp;
            // A packet stamped in the future is clock skew, not a time
            // traveller: keep it rather than discard a good message.
            if (age < 0) return true;
            return age <= maxAge;
        }

        /// Records a public packet seen on the air (received OR sent by us).
        /// Directed packets are refused — this store is public history, never
        /// anybody's private mail.
        async onPublicPacketSeen(packet, isBroadcastFn) {
            if (isBroadcastFn && !isBroadcastFn(packet)) return false;
            if (!isSyncable(packet.type)) return false;
            if (!this._fresh(packet)) return false;
            const id = await packetId(packet);
            const hash = await h64(id);
            if (packet.type === 0x01) {
                this.announces.set(hexOf(packet.senderID), { packet, hash });
                return true;
            }
            if (packet.type === 0x24) {
                // Newest wins: an older bundle would resurrect keys its owner
                // has already deleted.
                const key = hexOf(packet.senderID);
                const held = this.prekeyBundles.get(key);
                if (held && held.packet.timestamp >= packet.timestamp) return false;
                this.prekeyBundles.set(key, { packet, hash });
                return true;
            }
            const key = hexOf(id);
            if (this.messages.has(key)) return false;
            this.messages.set(key, { packet, hash });
            while (this.messages.size > this.capacity) {
                this.messages.delete(this.messages.keys().next().value);
            }
            return true;
        }

        /// Drops what has aged out. Returns whether anything went.
        prune() {
            const size = () => this.messages.size + this.announces.size + this.prekeyBundles.size;
            const before = size();
            for (const [k, v] of [...this.messages]) if (!this._fresh(v.packet)) this.messages.delete(k);
            for (const [k, v] of [...this.announces]) if (!this._fresh(v.packet)) this.announces.delete(k);
            for (const [k, v] of [...this.prekeyBundles]) if (!this._fresh(v.packet)) this.prekeyBundles.delete(k);
            return size() !== before;
        }

        get messageList() {
            return [...this.messages.values()]
                .filter(v => this._fresh(v.packet))
                .sort((a, b) => b.packet.timestamp - a.packet.timestamp);
        }

        shouldAsk(peerID) { return this.now() - (this.lastAsked.get(peerID) || 0) >= this.syncIntervalMs; }
        markAsked(peerID) { this.lastAsked.set(peerID, this.now()); }
        shouldAnswer(peerID) {
            const last = this.lastAnswered.get(peerID);
            return last === undefined || this.now() - last >= this.responseRateLimitMs;
        }
        markAnswered(peerID) { this.lastAnswered.set(peerID, this.now()); }
        forgetPeer(peerID) { this.lastAsked.delete(peerID); this.lastAnswered.delete(peerID); }

        /// Builds the REQUEST_SYNC payload advertising what we already hold.
        buildRequest(types) {
            const want = types === undefined ? SYNC_PUBLIC : types;
            const candidates = [];
            if (syncFlagsContains(want, 0x01)) {
                for (const v of this.announces.values()) if (this._fresh(v.packet)) candidates.push(v);
            }
            if (syncFlagsContains(want, 0x02)) {
                for (const v of this.messages.values()) if (this._fresh(v.packet)) candidates.push(v);
            }
            if (syncFlagsContains(want, 0x24)) {
                for (const v of this.prekeyBundles.values()) if (this._fresh(v.packet)) candidates.push(v);
            }
            candidates.sort((a, b) => b.packet.timestamp - a.packet.timestamp);
            if (!candidates.length) {
                return encodeRequestSync({
                    p: deriveP(this.gcsTargetFpr), m: 1, data: new Uint8Array(0), types: want,
                });
            }
            const p = deriveP(this.gcsTargetFpr);
            const nMax = estimateMaxElements(this.gcsMaxBytes, p);
            const included = candidates.slice(0, Math.min(candidates.length, nMax));
            const params = buildFilter(included.map(v => v.hash), this.gcsMaxBytes, this.gcsTargetFpr);
            // When the filter cannot cover everything, tell the responder how
            // far back it reaches. Without the cursor the responder re-sends
            // that whole tail every round, forever.
            const covered = params.includedCount;
            const since = (covered < candidates.length && covered > 0)
                ? included[covered - 1].packet.timestamp : null;
            return encodeRequestSync({
                p: params.p, m: params.m, data: params.data, types: want, sinceTimestamp: since,
            });
        }

        /// The packets a requester is missing — the whole reconciliation, as a
        /// pure function of the store and the request.
        ///
        /// Announces are exempt from the since-cursor: they carry the signing
        /// keys everything else is verified against, there is at most one per
        /// peer, and a peer that cannot verify anything is worse off than the
        /// negligible cost of resending them.
        packetsMissingFrom(request) {
            const want = request.types === null || request.types === undefined ? SYNC_PUBLIC : request.types;
            const sorted = decodeToSortedSet(request.p, request.m, request.data);
            const M = BigInt(Math.max(1, request.m));
            const mightContain = (hash) => containsBucket(sorted, mapHash(hash, M));
            const out = [];
            if (syncFlagsContains(want, 0x01)) {
                for (const v of this.announces.values()) {
                    if (!this._fresh(v.packet)) continue;
                    if (mightContain(v.hash)) continue;
                    out.push({ ...v.packet, ttl: 0 });
                }
            }
            if (syncFlagsContains(want, 0x02)) {
                const since = request.sinceTimestamp;
                for (const v of this.messageList) {
                    if (since && v.packet.timestamp < since) continue;
                    if (mightContain(v.hash)) continue;
                    out.push({ ...v.packet, ttl: 0 });
                }
            }
            if (syncFlagsContains(want, 0x24)) {
                // Exempt from the cursor, like announces: there is at most one
                // per device, and a sender without it falls back to the
                // non-forward-secret static seal — a real loss for a
                // negligible resend.
                for (const v of this.prekeyBundles.values()) {
                    if (!this._fresh(v.packet)) continue;
                    if (mightContain(v.hash)) continue;
                    out.push({ ...v.packet, ttl: 0 });
                }
            }
            return out;
        }
    }

    function hexOf(bytes) {
        let s = '';
        for (const b of bytes) s += b.toString(16).padStart(2, '0');
        return s;
    }

    G.NymMeshSync = {
        GossipSync, isSyncable, packetId, h64, mapHash,
        deriveP, estimateMaxElements, buildFilter, decodeToSortedSet, containsBucket,
        encodeRequestSync, decodeRequestSync, encodeSyncFlags, decodeSyncFlags,
        syncFlagsContains, SYNC_PUBLIC,
        PUBLIC_MAX_AGE_MS, ANNOUNCE_MAX_AGE_MS, PREKEY_BUNDLE_MAX_AGE_MS, CAPACITY,
        GCS_MAX_BYTES, GCS_TARGET_FPR, SYNC_INTERVAL_MS, RESPONSE_RATE_LIMIT_MS, MAX_P,
    };
})();
